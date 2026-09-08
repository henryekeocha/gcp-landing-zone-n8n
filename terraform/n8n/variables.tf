variable "project_id" {
  description = "Workload project the Cloud Run service is deployed into."
  type        = string
}

variable "environment" {
  description = "Environment name (dev | prod)."
  type        = string
}

variable "region" {
  description = "Cloud Run region. Must match the VPC subnet and Cloud SQL region."
  type        = string
  default     = "us-central1"
}

variable "image" {
  description = "Fully-qualified n8n image, e.g. us-central1-docker.pkg.dev/lz-n8n-shared-a1/images/n8n:2.37.11. Pinned by digest or version tag, never :latest."
  type        = string
}

variable "cloud_sql_proxy_image" {
  description = "Cloud SQL Auth Proxy v2 image. Pin the version; it's a security boundary."
  type        = string
  default     = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.25.4"
}

variable "service_account_email" {
  description = "n8n runtime service account (terraform/iam output)."
  type        = string
}

variable "vpc_network_id" {
  description = "VPC ID for direct VPC egress (terraform/networking output vpc_id)."
  type        = string
}

variable "vpc_subnet_name" {
  description = "Subnet name for direct VPC egress (terraform/networking output subnet_names[\"app\"])."
  type        = string
}

variable "cloud_sql_instance_connection_name" {
  description = "project:region:instance (terraform/database output instance_connection_name). Change this to repoint n8n after a PITR restore."
  type        = string
}

variable "database_name" {
  description = "Postgres database (terraform/database output database_name)."
  type        = string
  default     = "n8n"
}

variable "secret_ids" {
  description = "Map from terraform/iam output secret_ids: keys n8n-encryption-key, n8n-db-password, n8n-db-user."
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["n8n-encryption-key", "n8n-db-password", "n8n-db-user"] : contains(keys(var.secret_ids), k)])
    error_message = "secret_ids must contain n8n-encryption-key, n8n-db-password and n8n-db-user."
  }
}

variable "public_hostname" {
  description = "Hostname users and webhooks use (e.g. n8n.example.com). Drives N8N_HOST, WEBHOOK_URL and N8N_EDITOR_BASE_URL. Map it with a Cloud Run domain mapping or an HTTPS load balancer."
  type        = string
}

variable "timezone" {
  description = "GENERIC_TIMEZONE for schedule triggers."
  type        = string
  default     = "UTC"
}

variable "executions_max_age_hours" {
  description = "EXECUTIONS_DATA_MAX_AGE: prune execution history older than this many hours. 336 = 14 days."
  type        = number
  default     = 336
}

variable "executions_prune_max_count" {
  description = "EXECUTIONS_DATA_PRUNE_MAX_COUNT: hard cap on stored executions regardless of age."
  type        = number
  default     = 50000
}

variable "cpu" {
  description = "vCPU per instance."
  type        = string
  default     = "1"
}

variable "memory" {
  description = "Memory per instance. n8n idles ~300 MiB; large workflow payloads live in memory during execution."
  type        = string
  default     = "2Gi"
}

variable "allow_unauthenticated" {
  description = <<-EOT
    Grant roles/run.invoker to allUsers so webhooks reach n8n directly. n8n's own
    login protects the editor; webhook paths are authenticated by n8n per-workflow.
    Set false and put an HTTPS load balancer + IAP in front for orgs that enforce
    iam.allowedPolicyMemberDomains (see docs/org-policy-mfa.md).
  EOT
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to the service."
  type        = map(string)
  default     = { managed_by = "terraform", workload = "n8n" }
}
