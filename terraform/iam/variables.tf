variable "project_id" {
  description = "Workload project (dev or prod) in which the service accounts and secrets live."
  type        = string
}

variable "environment" {
  description = "Environment name (dev | prod)."
  type        = string
}

variable "region" {
  description = "Region used for Secret Manager user-managed replication (keeps secret data in-region)."
  type        = string
  default     = "us-central1"
}

variable "github_repository" {
  description = "GitHub repo (owner/name) allowed to impersonate the CI/CD service account via Workload Identity Federation. No long-lived SA keys are ever created."
  type        = string
  default     = "henryekeocha/gcp-landing-zone-n8n"
}

variable "ops_members" {
  description = "IAM members (group:..., user:...) allowed to open IAP SSH tunnels to tagged VMs in this project. Prefer a group."
  type        = set(string)
  default     = []
}

variable "manage_encryption_key_version" {
  description = <<-EOT
    If true, Terraform generates the n8n encryption key with random_password and
    stores it as a secret version. The value then also lives in Terraform state,
    so the state backend MUST be encrypted and access-controlled (GCS bucket with
    uniform access + CMEK is the expected setup). Set false to create the version
    out-of-band: `gcloud secrets versions add n8n-encryption-key --data-file=-`.
  EOT
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to labelable resources."
  type        = map(string)
  default     = { managed_by = "terraform", workload = "n8n" }
}
