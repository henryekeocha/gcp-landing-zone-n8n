output "landing_zone_folder" {
  description = "Resource name of the top-level landing-zone folder (folders/NNN)."
  value       = google_folder.landing_zone.name
}

output "shared_project_id" {
  description = "Project ID of the shared-services project."
  value       = google_project.shared.project_id
}

output "shared_project_number" {
  description = "Project number of the shared-services project (needed for some IAM member strings)."
  value       = google_project.shared.number
}

output "env_project_ids" {
  description = "Map of environment name → workload project ID."
  value       = { for env, p in google_project.env : env => p.project_id }
}

output "env_project_numbers" {
  description = "Map of environment name → workload project number."
  value       = { for env, p in google_project.env : env => p.number }
}

output "env_folder_ids" {
  description = "Map of environment name → folder resource name."
  value       = { for env, f in google_folder.env : env => f.name }
}
