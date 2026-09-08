# ---------------------------------------------------------------------------
# Monitoring for n8n
#
#   uptime check  →  GET https://<n8n_hostname>/healthz/readiness from 3 regions
#   alert policy  →  fires when the fraction of passing checks drops below 1
#                    for `uptime_failure_window`, to the email channel(s)
#   + Cloud SQL "instance down" alert, because n8n readiness failing tells you
#     *something* is wrong and this tells you *which* thing.
#
# /healthz/readiness rather than /healthz on purpose: readiness fails when
# n8n cannot reach Postgres through the proxy, which is the failure mode that
# matters. A green /healthz with a dead database is a false comfort.
# ---------------------------------------------------------------------------

locals {
  name = "n8n-${var.environment}"
}

resource "google_monitoring_notification_channel" "email" {
  for_each = var.alert_email_addresses

  project      = var.project_id
  display_name = "${local.name} on-call (${each.value})"
  type         = "email"

  labels = {
    email_address = each.value
  }

  enabled = true
}

resource "google_monitoring_uptime_check_config" "n8n" {
  project      = var.project_id
  display_name = "${local.name} readiness"
  timeout      = "10s"
  period       = var.uptime_check_period

  http_check {
    path           = "/healthz/readiness"
    port           = 443
    use_ssl        = true
    validate_ssl   = true
    request_method = "GET"

    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.n8n_hostname
    }
  }

  # Three regions so a single prober region having a bad day doesn't page.
  selected_regions = ["USA", "EUROPE", "ASIA_PACIFIC"]
  checker_type     = "STATIC_IP_CHECKERS"
}

resource "google_monitoring_alert_policy" "n8n_down" {
  project      = var.project_id
  display_name = "${local.name}: readiness check failing"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "uptime check failed from ≥ 2 regions"

    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.n8n.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = var.uptime_failure_window

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.*"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  alert_strategy {
    auto_close = "1800s"

    notification_rate_limit {
      period = "300s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      ## n8n ${var.environment} is failing its readiness check

      `GET https://${var.n8n_hostname}/healthz/readiness` has returned non-2xx
      (or timed out) from at least two prober regions for ${var.uptime_failure_window}.

      Readiness fails when n8n cannot reach Postgres. Triage in this order:

      1. Is the **database-down** alert also firing? → Cloud SQL problem, see `docs/postgres-runbook.md`.
      2. Cloud Run → service `${local.name}` → latest revision healthy? Look at the
         `cloud-sql-proxy` container logs first, then `n8n`.
      3. Was a secret rotated without a new revision? `docs/n8n-operations.md` §4.

      Full triage tree: `docs/handoff-runbook.md`.
    EOT
  }

  user_labels = {
    environment = var.environment
    workload    = "n8n"
  }
}

resource "google_monitoring_alert_policy" "cloud_sql_down" {
  project      = var.project_id
  display_name = "${local.name}: Cloud SQL instance down"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "cloudsql database/up == 0"

    condition_threshold {
      filter          = "metric.type=\"cloudsql.googleapis.com/database/up\" AND resource.type=\"cloudsql_database\" AND resource.label.database_id=\"${var.project_id}:${var.cloud_sql_instance_name}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "120s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "Cloud SQL `${var.cloud_sql_instance_name}` reports down. Check `gcloud sql operations list --instance ${var.cloud_sql_instance_name}` for an in-progress maintenance/failover, then `docs/postgres-runbook.md`."
  }

  user_labels = {
    environment = var.environment
    workload    = "n8n"
  }
}
