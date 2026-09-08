# ---------------------------------------------------------------------------
# Networking for one environment project.
#
#   VPC (custom mode, no auto subnets)
#   ├── subnet: <env>-app    (Cloud Run direct VPC egress, PGA on, flow logs)
#   ├── subnet: <env>-mgmt   (ops VMs, IAP-only SSH, PGA on, flow logs)
#   ├── reserved range + Service Networking peering  → Cloud SQL private IP
#   ├── Cloud Router + Cloud NAT                       → egress for private VMs
#   └── firewall
#       ├── deny-all ingress (priority 65534, logged)  ← belt and braces
#       ├── allow IAP TCP forwarding → :22 on tagged VMs (35.235.240.0/20 only)
#       ├── allow Google health checkers → tagged backends
#       └── allow intra-VPC internal traffic
#
# There is intentionally NO rule with source 0.0.0.0/0 for port 22 (or 3389).
# Operators reach VMs with `gcloud compute ssh --tunnel-through-iap`, which
# requires roles/iap.tunnelResourceAccessor (granted in terraform/iam).
# ---------------------------------------------------------------------------

locals {
  name = "${var.environment}-n8n"

  # Google's published source range for IAP TCP forwarding. This is the ONLY
  # range allowed to reach port 22 anywhere in this landing zone.
  # https://cloud.google.com/iap/docs/using-tcp-forwarding#create-firewall-rule
  iap_forwarding_range = "35.235.240.0/20"

  # Google Cloud health-check probers (needed only if you put a load balancer
  # or MIG in front of VMs; harmless otherwise).
  health_check_ranges = ["35.191.0.0/16", "130.211.0.0/22"]

  all_subnet_cidrs = [for s in var.subnets : s.cidr]
}

# --- VPC ----------------------------------------------------------------------

resource "google_compute_network" "vpc" {
  project                         = var.project_id
  name                            = "${local.name}-vpc"
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false
  description                     = "Landing-zone VPC for ${var.environment}"
}

resource "google_compute_subnetwork" "subnet" {
  for_each = var.subnets

  project       = var.project_id
  name          = "${local.name}-${each.key}"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = each.value.cidr
  description   = each.value.description

  # Private Google Access: lets resources without external IPs reach Google
  # APIs (Secret Manager, Artifact Registry, Cloud SQL Admin) over internal routes.
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# --- Private services access (Cloud SQL private IP) ---------------------------
# Cloud SQL private IP lives in a Google-managed producer VPC peered to ours.
# We reserve an internal range for it and create the Service Networking
# connection here so the database module only has to reference the VPC.

resource "google_compute_global_address" "cloud_sql_range" {
  project       = var.project_id
  name          = "${local.name}-cloudsql-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.cloud_sql_peering_prefix_length
  network       = google_compute_network.vpc.id
  description   = "Reserved for Cloud SQL private services access"
}

resource "google_service_networking_connection" "cloud_sql" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.cloud_sql_range.name]

  # Without this, deleting the connection while a Cloud SQL instance still
  # uses it fails with a confusing error; ABANDON leaves the peering in place.
  deletion_policy = "ABANDON"
}

# --- Cloud NAT (egress for resources with no external IP) --------------------

resource "google_compute_router" "router" {
  project = var.project_id
  name    = "${local.name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  project = var.project_id
  name    = "${local.name}-nat"
  router  = google_compute_router.router.name
  region  = var.region

  nat_ip_allocate_option = "AUTO_ONLY"

  # Explicit list rather than ALL_SUBNETWORKS so adding a subnet is a
  # deliberate decision about whether it gets internet egress.
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  dynamic "subnetwork" {
    for_each = google_compute_subnetwork.subnet
    content {
      name                    = subnetwork.value.id
      source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
    }
  }

  min_ports_per_vm                    = 64
  enable_endpoint_independent_mapping = false

  log_config {
    enable = var.enable_nat_logging
    filter = "ERRORS_ONLY"
  }
}

# --- Firewall ---------------------------------------------------------------

# Explicit, logged default-deny. GCP already implies deny-ingress, but an
# explicit rule at 65534 makes the posture visible and gives us drop logs.
resource "google_compute_firewall" "deny_all_ingress" {
  project     = var.project_id
  name        = "${local.name}-deny-all-ingress"
  network     = google_compute_network.vpc.name
  direction   = "INGRESS"
  priority    = 65534
  description = "Explicit logged default deny for all ingress"

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "EXCLUDE_ALL_METADATA"
  }
}

# SSH is reachable ONLY from the IAP TCP-forwarding range, and only on VMs
# that opt in with the `iap-ssh` network tag. Operators run:
#   gcloud compute ssh VM --zone ZONE --tunnel-through-iap
resource "google_compute_firewall" "allow_iap_ssh" {
  project     = var.project_id
  name        = "${local.name}-allow-iap-ssh"
  network     = google_compute_network.vpc.name
  direction   = "INGRESS"
  priority    = 1000
  description = "SSH via IAP TCP forwarding only (no public SSH anywhere)"

  source_ranges = [local.iap_forwarding_range]
  target_tags   = ["iap-ssh"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "allow_health_checks" {
  project     = var.project_id
  name        = "${local.name}-allow-health-checks"
  network     = google_compute_network.vpc.name
  direction   = "INGRESS"
  priority    = 1000
  description = "Google Cloud health checkers to tagged backends"

  source_ranges = local.health_check_ranges
  target_tags   = ["lb-backend"]

  allow {
    protocol = "tcp"
  }
}

resource "google_compute_firewall" "allow_internal" {
  project     = var.project_id
  name        = "${local.name}-allow-internal"
  network     = google_compute_network.vpc.name
  direction   = "INGRESS"
  priority    = 1100
  description = "Intra-VPC traffic between our own subnets"

  source_ranges = local.all_subnet_cidrs

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }
}

# Egress: allow everything by default (GCP implied) but log/deny nothing extra.
# If you need to pin egress to Google APIs + Cloud SQL only, add a deny-all
# egress at 65534 and allow 199.36.153.8/30 (private.googleapis.com) plus the
# Cloud SQL peering range above. Left permissive here so n8n workflows can
# call third-party HTTP APIs, which is the point of n8n.
