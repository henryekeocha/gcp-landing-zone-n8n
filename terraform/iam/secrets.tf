# ---------------------------------------------------------------------------
# Secret Manager
#
#   n8n-encryption-key   – N8N_ENCRYPTION_KEY. Encrypts every credential n8n
#                          stores in Postgres. Lose it and every stored
#                          credential is unrecoverable; rotate it and n8n must
#                          re-encrypt (see docs/n8n-operations.md).
#   n8n-db-password      – password for the n8n Postgres role. The *version*
#                          is written by terraform/database (which generates
#                          the password), so only that module and Cloud SQL
#                          ever see it.
#   n8n-db-user          – not truly secret, but kept alongside so the Cloud
#                          Run env block reads everything from one place.
#
# Access is granted per-secret to the n8n runtime SA only. Nothing here uses
# a project-wide roles/secretmanager.secretAccessor.
# ---------------------------------------------------------------------------

locals {
  secrets = {
    "n8n-encryption-key" = "n8n N8N_ENCRYPTION_KEY (${var.environment})"
    "n8n-db-password"    = "Postgres password for the n8n role (${var.environment})"
    "n8n-db-user"        = "Postgres username for n8n (${var.environment})"
  }
}

resource "google_secret_manager_secret" "n8n" {
  for_each = local.secrets

  project   = var.project_id
  secret_id = "${each.key}-${var.environment}"

  labels = merge(var.labels, { environment = var.environment })

  annotations = {
    description = each.value
  }

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_iam_member" "n8n_runtime_accessor" {
  for_each = google_secret_manager_secret.n8n

  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.n8n_runtime.member
}

# --- n8n encryption key: generated once, never rotated by accident -----------
# 32 random bytes hex-encoded is what n8n itself generates on first boot.

resource "random_password" "n8n_encryption_key" {
  count = var.manage_encryption_key_version ? 1 : 0

  length  = 64
  special = false

  # Changing anything in `keepers` mints a new key. Rotation is a deliberate,
  # documented procedure, not a side effect of a plan.
  keepers = {
    rotation = "v1"
  }
}

resource "google_secret_manager_secret_version" "n8n_encryption_key" {
  count = var.manage_encryption_key_version ? 1 : 0

  secret      = google_secret_manager_secret.n8n["n8n-encryption-key"].id
  secret_data = random_password.n8n_encryption_key[0].result

  # Keep old versions around on rotation until n8n has been re-keyed.
  deletion_policy = "DISABLE"
}

resource "google_secret_manager_secret_version" "n8n_db_user" {
  secret      = google_secret_manager_secret.n8n["n8n-db-user"].id
  secret_data = "n8n"
}
