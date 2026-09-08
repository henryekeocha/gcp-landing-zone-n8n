output "instance_name" {
  description = "Cloud SQL instance name."
  value       = google_sql_database_instance.n8n.name
}

output "instance_connection_name" {
  description = "project:region:instance — what the Cloud SQL Auth Proxy sidecar takes as its argument."
  value       = google_sql_database_instance.n8n.connection_name
}

output "private_ip_address" {
  description = "Private IP of the primary (for the runbook / psql via IAP tunnel). Not used by n8n directly; the proxy resolves it."
  value       = google_sql_database_instance.n8n.private_ip_address
}

output "database_name" {
  description = "Database n8n uses."
  value       = google_sql_database.n8n.name
}

output "database_user" {
  description = "Role n8n connects as."
  value       = google_sql_user.n8n.name
}

output "availability_type" {
  description = "Effective availability type (REGIONAL / ZONAL)."
  value       = local.availability_type
}
