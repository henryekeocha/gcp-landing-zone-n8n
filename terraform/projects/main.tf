# ---------------------------------------------------------------------------
# Multi-project landing zone
#
# Layout (folder-based, so IAM and org policies can be inherited per tier):
#
#   organizations/ORG_ID
#   └── folder: "landing-zone"
#       ├── folder: "shared"        → project: <prefix>-shared-<suffix>
#       ├── folder: "dev"           → project: <prefix>-dev-<suffix>
#       └── folder: "prod"          → project: <prefix>-prod-<suffix>
#
# Why folders rather than flat projects:
#   * Org policies (e.g. iam.allowedPolicyMemberDomains, MFA-related access
#     levels, sql.restrictPublicIp) can be set once on a folder and inherited.
#   * IAM for humans is granted at the folder level ("prod viewers"), never
#     project-by-project, which is what keeps least-privilege maintainable.
#   * Shared services (image registry, secrets, monitoring) live in their own
#     project so a compromised workload project cannot alter the supply chain.
# ---------------------------------------------------------------------------

locals {
  shared_project_id = "${var.prefix}-shared-${var.project_suffix}"

  env_project_ids = {
    for env in var.environments : env => "${var.prefix}-${env}-${var.project_suffix}"
  }

  # APIs enabled on every project regardless of role.
  base_apis = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
  ]

  # APIs the workload projects need for the n8n stack.
  workload_apis = [
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "run.googleapis.com",
    "iap.googleapis.com",
    "vpcaccess.googleapis.com",
  ]

  # APIs only the shared-services project needs.
  shared_apis = [
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudkms.googleapis.com",
  ]
}

# --- Folders -----------------------------------------------------------------

resource "google_folder" "landing_zone" {
  display_name = "landing-zone"
  parent       = "organizations/${var.org_id}"
}

resource "google_folder" "shared" {
  display_name = "shared"
  parent       = google_folder.landing_zone.name
}

resource "google_folder" "env" {
  for_each = var.environments

  display_name = each.key
  parent       = google_folder.landing_zone.name
}

# --- Shared-services project ------------------------------------------------

resource "google_project" "shared" {
  name            = "${var.prefix}-shared"
  project_id      = local.shared_project_id
  folder_id       = google_folder.shared.folder_id
  billing_account = var.billing_account

  # The default network is an anti-pattern in a landing zone: it ships with
  # permissive firewall rules and an unplanned CIDR. Every VPC is explicit.
  auto_create_network = false

  # PREVENT is the provider default; spelled out so a reviewer sees it.
  deletion_policy = "PREVENT"

  labels = merge(var.labels, { environment = "shared", tier = "shared-services" })
}

resource "google_project_service" "shared" {
  for_each = toset(concat(local.base_apis, local.shared_apis))

  project = google_project.shared.project_id
  service = each.value

  # Never tear APIs down on destroy: doing so can delete resources created by
  # the API (e.g. disabling compute deletes networks).
  disable_on_destroy         = false
  disable_dependent_services = false
}

# --- Workload projects (one per environment) --------------------------------

resource "google_project" "env" {
  for_each = var.environments

  name            = "${var.prefix}-${each.key}"
  project_id      = local.env_project_ids[each.key]
  folder_id       = google_folder.env[each.key].folder_id
  billing_account = var.billing_account

  auto_create_network = false
  deletion_policy     = "PREVENT"

  labels = merge(var.labels, { environment = each.key, tier = "workload" })
}

resource "google_project_service" "env" {
  for_each = {
    for pair in setproduct(var.environments, concat(local.base_apis, local.workload_apis)) :
    "${pair[0]}/${pair[1]}" => { env = pair[0], api = pair[1] }
  }

  project = google_project.env[each.value.env].project_id
  service = each.value.api

  disable_on_destroy         = false
  disable_dependent_services = false
}
