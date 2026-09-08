# ---------------------------------------------------------------------------
# n8n on Cloud Run, Postgres-backed, Cloud SQL Auth Proxy as a sidecar
#
#   ┌─ Cloud Run service "n8n-<env>" ─────────────────────────────────────┐
#   │  container "n8n"            container "cloud-sql-proxy" (sidecar)   │
#   │   :5678 (ingress)   ──────►  127.0.0.1:5432  ──TLS──►  Cloud SQL    │
#   │   env from Secret Manager     --private-ip, health on :9090          │
#   │   depends_on = [proxy]        via direct VPC egress into `app` subnet│
#   └─────────────────────────────────────────────────────────────────────┘
#
# Operational choices that are specific to n8n, not generic Cloud Run:
#
#   * DB_TYPE=postgresdb with EXECUTIONS_DATA_* set explicitly, so execution
#     history (not just workflow definitions) persists in Postgres and is
#     pruned on a schedule. Default SQLite would live on the container's
#     in-memory filesystem and vanish on every revision.
#   * Exactly ONE instance (min = max = 1) with CPU always allocated.
#     n8n in "regular" mode runs schedule/polling triggers inside the main
#     process; two instances would fire every cron twice, and CPU throttling
#     between requests would stall them. Scaling out is a queue-mode change
#     (Redis + workers), documented in docs/n8n-operations.md, not a slider.
#   * Proxy is a real sidecar with a startup probe and depends_on, so n8n
#     never boots before 127.0.0.1:5432 is listening. The alternative
#     (/cloudsql unix socket volume) works too but hides the proxy's logs
#     and health, which is exactly what you want visible during an incident.
#   * n8n → proxy is plaintext on localhost inside the instance sandbox;
#     proxy → Cloud SQL is TLS, satisfying ssl_mode = ENCRYPTED_ONLY on the
#     instance. So DB_POSTGRESDB_SSL_ENABLED is deliberately false.
# ---------------------------------------------------------------------------

locals {
  service_name = "n8n-${var.environment}"

  # Non-secret configuration. Anything sensitive is in `secret_env` below and
  # comes from Secret Manager at revision start.
  plain_env = {
    # --- database: Postgres via the sidecar ---
    DB_TYPE                               = "postgresdb"
    DB_POSTGRESDB_HOST                    = "127.0.0.1"
    DB_POSTGRESDB_PORT                    = "5432"
    DB_POSTGRESDB_DATABASE                = var.database_name
    DB_POSTGRESDB_SCHEMA                  = "public"
    DB_POSTGRESDB_SSL_ENABLED             = "false" # TLS is the proxy's job
    DB_POSTGRESDB_POOL_SIZE               = "4"
    DB_POSTGRESDB_CONNECTION_TIMEOUT      = "20000"
    DB_POSTGRESDB_IDLE_CONNECTION_TIMEOUT = "30000"

    # --- execution data: lives in Postgres, pruned ---
    EXECUTIONS_MODE                        = "regular"
    EXECUTIONS_DATA_SAVE_ON_SUCCESS        = "all"
    EXECUTIONS_DATA_SAVE_ON_ERROR          = "all"
    EXECUTIONS_DATA_SAVE_ON_PROGRESS       = "false" # true = a DB write per node; only for debugging
    EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS = "true"
    EXECUTIONS_DATA_PRUNE                  = "true"
    EXECUTIONS_DATA_MAX_AGE                = tostring(var.executions_max_age_hours)
    EXECUTIONS_DATA_PRUNE_MAX_COUNT        = tostring(var.executions_prune_max_count)
    EXECUTIONS_TIMEOUT                     = "3600"
    EXECUTIONS_TIMEOUT_MAX                 = "7200"

    # --- URLs / networking ---
    N8N_HOST            = var.public_hostname
    N8N_PORT            = "5678"
    N8N_LISTEN_ADDRESS  = "0.0.0.0"
    N8N_PROTOCOL        = "https"
    N8N_EDITOR_BASE_URL = "https://${var.public_hostname}/"
    WEBHOOK_URL         = "https://${var.public_hostname}/"
    N8N_PROXY_HOPS      = "1" # Cloud Run's front end terminates TLS; trust X-Forwarded-*

    # --- runtime hygiene ---
    GENERIC_TIMEZONE                      = var.timezone
    N8N_DIAGNOSTICS_ENABLED               = "false"
    N8N_VERSION_NOTIFICATIONS_ENABLED     = "false"
    N8N_RUNNERS_ENABLED                   = "true" # Code nodes run in a separate task-runner process
    N8N_LOG_LEVEL                         = "info"
    N8N_LOG_OUTPUT                        = "console" # Cloud Logging picks up stdout
    N8N_METRICS                           = "true"    # Prometheus at /metrics (scrape with Managed Prometheus if wanted)
    N8N_GRACEFUL_SHUTDOWN_TIMEOUT         = "30"      # < Cloud Run's shutdown grace period
    N8N_USER_FOLDER                       = "/home/node/.n8n"
    N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS = "false" # read-only FS; settings live in env
  }

  # env var → Secret Manager secret_id
  secret_env = {
    N8N_ENCRYPTION_KEY     = var.secret_ids["n8n-encryption-key"]
    DB_POSTGRESDB_USER     = var.secret_ids["n8n-db-user"]
    DB_POSTGRESDB_PASSWORD = var.secret_ids["n8n-db-password"]
  }
}

resource "google_cloud_run_v2_service" "n8n" {
  project  = var.project_id
  name     = local.service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  deletion_protection = true
  labels              = merge(var.labels, { environment = var.environment })

  template {
    service_account       = var.service_account_email
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
    timeout               = "300s" # webhook responses; long workflows keep running async

    # One instance, always warm: see header comment.
    scaling {
      min_instance_count = 1
      max_instance_count = 1
    }

    # Sticky sessions aren't needed with one instance but make the intent
    # explicit if max_instance_count is ever raised in queue mode.
    session_affinity = true

    vpc_access {
      network_interfaces {
        network    = var.vpc_network_id
        subnetwork = var.vpc_subnet_name
      }
      # Only RFC1918 + Cloud SQL private range goes through the VPC (and NAT);
      # public API calls from workflows leave via Cloud Run's own egress.
      egress = "PRIVATE_RANGES_ONLY"
    }

    # --- sidecar: Cloud SQL Auth Proxy ------------------------------------
    containers {
      name  = "cloud-sql-proxy"
      image = var.cloud_sql_proxy_image

      args = [
        "--private-ip",
        "--port=5432",
        "--structured-logs",
        "--health-check",
        "--http-address=0.0.0.0",
        "--http-port=9090",
        "--max-sigterm-delay=30s", # keep serving n8n's in-flight queries during shutdown
        var.cloud_sql_instance_connection_name,
      ]

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = false
      }

      startup_probe {
        http_get {
          path = "/startup"
          port = 9090
        }
        initial_delay_seconds = 0
        period_seconds        = 2
        timeout_seconds       = 2
        failure_threshold     = 15
      }

      liveness_probe {
        http_get {
          path = "/liveness"
          port = 9090
        }
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 3
      }
    }

    # --- main container: n8n ---------------------------------------------
    containers {
      name       = "n8n"
      image      = var.image
      depends_on = ["cloud-sql-proxy"]

      ports {
        name           = "http1"
        container_port = 5678
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = false # cron/polling triggers need CPU between requests
        startup_cpu_boost = true
      }

      dynamic "env" {
        for_each = local.plain_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      # n8n runs DB migrations on boot; give it up to ~2 min before Cloud Run
      # declares the revision dead.
      startup_probe {
        http_get {
          path = "/healthz"
          port = 5678
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        timeout_seconds       = 3
        failure_threshold     = 24
      }

      # /healthz/readiness fails when the DB connection is lost; Cloud Run
      # restarts the instance, which re-establishes the pool via the proxy.
      liveness_probe {
        http_get {
          path = "/healthz/readiness"
          port = 5678
        }
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 3
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    # CI deploys new images with `gcloud run deploy`; Terraform owns everything
    # else. Without this, every Terraform run would fight CI over the tag.
    ignore_changes = [
      template[0].containers[1].image,
      client,
      client_version,
    ]
  }
}

# Webhooks need to reach n8n from the public internet. See variable docs for
# the load-balancer + IAP alternative.
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  count = var.allow_unauthenticated ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.n8n.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
