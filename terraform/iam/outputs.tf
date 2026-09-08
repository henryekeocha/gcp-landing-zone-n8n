output "n8n_runtime_service_account_email" {
  description = "Email of the n8n runtime SA (Cloud Run service identity)."
  value       = google_service_account.n8n_runtime.email
}

output "n8n_runtime_service_account_member" {
  description = "IAM member string for the n8n runtime SA."
  value       = google_service_account.n8n_runtime.member
}

output "cicd_deployer_service_account_email" {
  description = "Email of the CI/CD deployer SA (used in the GitHub Actions auth step)."
  value       = google_service_account.cicd_deployer.email
}

output "workload_identity_provider" {
  description = "Full resource name of the WIF provider for google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "secret_ids" {
  description = "Map of logical secret name → Secret Manager secret_id (short name, same project)."
  value       = { for k, s in google_secret_manager_secret.n8n : k => s.secret_id }
}

output "secret_names" {
  description = "Map of logical secret name → full resource name (projects/*/secrets/*)."
  value       = { for k, s in google_secret_manager_secret.n8n : k => s.name }
}
