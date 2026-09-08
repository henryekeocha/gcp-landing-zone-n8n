output "service_name" {
  description = "Cloud Run service name."
  value       = google_cloud_run_v2_service.n8n.name
}

output "service_uri" {
  description = "Default *.run.app URL (map public_hostname to it via domain mapping or a load balancer)."
  value       = google_cloud_run_v2_service.n8n.uri
}

output "service_id" {
  description = "Full resource ID of the Cloud Run service."
  value       = google_cloud_run_v2_service.n8n.id
}

output "latest_ready_revision" {
  description = "Name of the latest ready revision; handy in the deploy step's smoke test."
  value       = google_cloud_run_v2_service.n8n.latest_ready_revision
}
