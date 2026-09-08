# ---------------------------------------------------------------------------
# Cloud SQL for PostgreSQL — the n8n backing store
#
# Non-negotiables, all encoded below and none left to "we'll turn it on later":
#   * private IP only            → ipv4_enabled = false, no authorized networks
#   * automated daily backups    → backup_configuration.enabled
#   * point-in-time recovery     → point_in_time_recovery_enabled + WAL retention
#   * deletion protection        → both the Terraform flag and the API flag
#   * TLS required               → ssl_mode = ENCRYPTED_ONLY (the Auth Proxy
#                                  in terraform/n8n satisfies this transparently)
#
# n8n's execution history lives in this database (EXECUTIONS_* env vars in
# terraform/n8n), which is why backups/PITR matter: losing it means losing
# audit trail and any "resume from failed step" data, not just workflows.
# ---------------------------------------------------------------------------

locals {
  name              = "${var.environment}-n8n-pg-${var.instance_name_suffix}"
  availability_type = coalesce(var.availability_type, var.environment == "prod" ? "REGIONAL" : "ZONAL")
}

resource "google_sql_database_instance" "n8n" {
  project          = var.project_id
  name             = local.name
  region           = var.region
  database_version = var.database_version

  # Terraform-side guard: `terraform destroy` / resource removal is refused
  # until this is flipped to false in a deliberate, reviewed change.
  deletion_protection = true

  settings {
    tier              = var.tier
    edition           = "ENTERPRISE"
    availability_type = local.availability_type

    disk_type             = "PD_SSD"
    disk_size             = var.disk_size_gb
    disk_autoresize       = true
    disk_autoresize_limit = 0 # 0 = no cap; set one if you want a hard ceiling

    # API-side guard: even a console user with cloudsql.admin has to clear
    # this flag first. Belt and braces with the Terraform flag above.
    deletion_protection_enabled = true

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = var.vpc_id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
      # No authorized_networks block: with private IP only there is nothing
      # to authorize, and adding one is exactly the drift we want to see in a
      # plan diff.
    }

    backup_configuration {
      enabled                        = true
      start_time                     = var.backup_start_time
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = var.transaction_log_retention_days

      backup_retention_settings {
        retained_backups = var.backup_retained_count
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 4 # 04:00 UTC, after the backup window
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = false
      record_client_address   = false
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    # Log slow queries (>1s). n8n's execution table can grow large; this is
    # the first signal that EXECUTIONS_DATA_PRUNE settings need tuning.
    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"
    }

    database_flags {
      name  = "log_connections"
      value = "on"
    }

    database_flags {
      name  = "log_disconnections"
      value = "on"
    }

    user_labels = merge(var.labels, { environment = var.environment })
  }

  # The private-services-access peering must exist first; referencing the
  # connection ID in lifecycle-neutral metadata is the cleanest way to say so
  # across module boundaries.
  depends_on = [terraform_data.peering_ready]
}

resource "terraform_data" "peering_ready" {
  input = var.service_networking_connection_id
}

# --- Database and role ----------------------------------------------------------

resource "google_sql_database" "n8n" {
  project  = var.project_id
  instance = google_sql_database_instance.n8n.name
  name     = var.database_name

  # Never let a `terraform destroy` of the database resource take the data
  # with it; the instance-level protection covers real deletion.
  deletion_policy = "ABANDON"
}

resource "random_password" "n8n" {
  length  = 32
  special = false

  keepers = {
    # Bump to rotate. Rotation procedure is in docs/postgres-runbook.md.
    rotation = "v1"
  }
}

resource "google_sql_user" "n8n" {
  project  = var.project_id
  instance = google_sql_database_instance.n8n.name
  name     = var.database_user
  password = random_password.n8n.result
  type     = "BUILT_IN"

  deletion_policy = "ABANDON"
}

# The password is handed to n8n exclusively through Secret Manager. The secret
# container and its IAM (runtime SA only) are owned by terraform/iam; this
# module just adds the version.
resource "google_secret_manager_secret_version" "db_password" {
  secret      = "projects/${var.project_id}/secrets/${var.db_password_secret_id}"
  secret_data = random_password.n8n.result

  deletion_policy = "DISABLE"
}
