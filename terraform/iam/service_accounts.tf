# ---------------------------------------------------------------------------
# Two service accounts, deliberately separate:
#
#   n8n-runtime  – identity the Cloud Run service runs as. Can read exactly
#                  the secrets it needs, connect to Cloud SQL, write logs.
#                  Cannot deploy, cannot read other secrets, cannot touch IAM.
#
#   cicd-deployer – identity GitHub Actions assumes (via Workload Identity
#                  Federation, no keys) to push images and roll out Cloud Run
#                  revisions. Can act-as n8n-runtime for deployment ONLY.
#                  Cannot read the n8n secrets' payloads.
#
# A single "deployer that also runs the app" account is the most common
# least-privilege failure in small GCP setups; it means a CI compromise
# equals a production-data compromise. Keeping them apart is the whole point.
# ---------------------------------------------------------------------------

resource "google_service_account" "n8n_runtime" {
  project      = var.project_id
  account_id   = "n8n-runtime-${var.environment}"
  display_name = "n8n runtime (${var.environment})"
  description  = "Identity of the n8n Cloud Run service. Reads its own secrets, connects to Cloud SQL."
}

resource "google_service_account" "cicd_deployer" {
  project      = var.project_id
  account_id   = "cicd-deployer-${var.environment}"
  display_name = "CI/CD deployer (${var.environment})"
  description  = "Assumed by GitHub Actions through Workload Identity Federation to deploy n8n."
}

# --- n8n runtime: project-level roles (all narrow, none grant data access) ----

locals {
  n8n_runtime_project_roles = [
    "roles/cloudsql.client",        # open connections via the Auth Proxy
    "roles/logging.logWriter",      # Cloud Run stdout/stderr → Cloud Logging
    "roles/monitoring.metricWriter" # custom metrics if N8N_METRICS is enabled
  ]

  cicd_deployer_project_roles = [
    "roles/run.developer",   # create/update Cloud Run services & revisions
    "roles/cloudsql.viewer", # read instance connection name for config
    "roles/artifactregistry.writer",
    "roles/logging.viewer" # read deploy logs in CI
  ]
}

resource "google_project_iam_member" "n8n_runtime" {
  for_each = toset(local.n8n_runtime_project_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.n8n_runtime.member
}

# --- CI/CD deployer ------------------------------------------------------------

resource "google_project_iam_member" "cicd_deployer" {
  for_each = toset(local.cicd_deployer_project_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.cicd_deployer.member
}

# Deploying a Cloud Run service that runs as n8n-runtime requires the deployer
# to "act as" that account. Granted on the ONE service account, not the project.
resource "google_service_account_iam_member" "deployer_acts_as_runtime" {
  service_account_id = google_service_account.n8n_runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.cicd_deployer.member
}

# --- Workload Identity Federation for GitHub Actions --------------------------
# GitHub's OIDC token is exchanged for a short-lived GCP token; the attribute
# condition pins it to this one repository so a fork or another repo in the
# org cannot impersonate the deployer.

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-${var.environment}"
  display_name              = "GitHub Actions (${var.environment})"
  description               = "OIDC federation for GitHub Actions deploys"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
  }

  # Only this repo, and (for prod) only the main branch.
  attribute_condition = var.environment == "prod" ? "attribute.repository == \"${var.github_repository}\" && attribute.ref == \"refs/heads/main\"" : "attribute.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_impersonates_deployer" {
  service_account_id = google_service_account.cicd_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# --- Human operators: IAP tunnel access --------------------------------------
# Pairs with the firewall rule in terraform/networking. OS Login ties SSH keys
# to Google identities (and therefore to the org's 2-step verification policy).

resource "google_project_iam_member" "ops_iap_tunnel" {
  for_each = var.ops_members

  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = each.value
}

resource "google_project_iam_member" "ops_os_login" {
  for_each = var.ops_members

  project = var.project_id
  role    = "roles/compute.osLogin"
  member  = each.value
}
