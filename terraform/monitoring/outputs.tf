output "uptime_check_id" {
  description = "ID of the readiness uptime check."
  value       = google_monitoring_uptime_check_config.n8n.uptime_check_id
}

output "alert_policy_ids" {
  description = "Alert policy resource names."
  value = {
    n8n_down       = google_monitoring_alert_policy.n8n_down.name
    cloud_sql_down = google_monitoring_alert_policy.cloud_sql_down.name
  }
}

output "notification_channel_ids" {
  description = "Notification channel IDs, keyed by email."
  value       = { for k, c in google_monitoring_notification_channel.email : k => c.id }
}
