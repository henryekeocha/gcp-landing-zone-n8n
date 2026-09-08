output "vpc_id" {
  description = "Self-link style ID of the VPC."
  value       = google_compute_network.vpc.id
}

output "vpc_name" {
  description = "VPC name."
  value       = google_compute_network.vpc.name
}

output "subnet_ids" {
  description = "Map of subnet key → subnet ID."
  value       = { for k, s in google_compute_subnetwork.subnet : k => s.id }
}

output "subnet_names" {
  description = "Map of subnet key → subnet name (Cloud Run direct VPC egress wants the name)."
  value       = { for k, s in google_compute_subnetwork.subnet : k => s.name }
}

output "cloud_sql_peering_range_name" {
  description = "Name of the reserved range used for Cloud SQL private services access."
  value       = google_compute_global_address.cloud_sql_range.name
}

output "service_networking_connection" {
  description = "ID of the Service Networking connection; the database module depends on it."
  value       = google_service_networking_connection.cloud_sql.id
}

output "nat_name" {
  description = "Cloud NAT gateway name."
  value       = google_compute_router_nat.nat.name
}
