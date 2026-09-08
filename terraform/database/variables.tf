variable "project_id" {
  description = "Workload project that owns the Cloud SQL instance."
  type        = string
}

variable "environment" {
  description = "Environment name (dev | prod). Drives HA and sizing defaults."
  type        = string
}

variable "region" {
  description = "Cloud SQL region. Must match the VPC subnets and the Cloud Run region."
  type        = string
  default     = "us-central1"
}

variable "vpc_id" {
  description = "ID of the VPC from terraform/networking (the instance gets a private IP in the peered producer range)."
  type        = string
}

variable "service_networking_connection_id" {
  description = "ID of the google_service_networking_connection from terraform/networking. Only used to force ordering: the peering must exist before the instance is created."
  type        = string
}

variable "db_password_secret_id" {
  description = "Secret Manager secret_id (from terraform/iam) that receives the generated n8n DB password as a new version."
  type        = string
}

variable "instance_name_suffix" {
  description = "Cloud SQL instance names are reserved for about a week after deletion; bump this to recreate."
  type        = string
  default     = "01"
}

variable "database_version" {
  description = "Postgres major version."
  type        = string
  default     = "POSTGRES_16"

  validation {
    condition     = can(regex("^POSTGRES_1[4-9]$", var.database_version))
    error_message = "Use POSTGRES_14 or newer."
  }
}

variable "tier" {
  description = "Machine tier. db-custom-<vCPU>-<MiB>. n8n is light; 2 vCPU / 8 GiB is plenty for a small team."
  type        = string
  default     = "db-custom-2-8192"
}

variable "availability_type" {
  description = "REGIONAL = HA with synchronous standby in another zone (prod). ZONAL for dev. null = pick by environment."
  type        = string
  default     = null

  validation {
    condition     = var.availability_type == null || contains(["REGIONAL", "ZONAL"], coalesce(var.availability_type, "ZONAL"))
    error_message = "availability_type must be REGIONAL, ZONAL or null."
  }
}

variable "disk_size_gb" {
  description = "Initial disk size; autoresize is on so this is a floor, not a cap."
  type        = number
  default     = 20
}

variable "backup_start_time" {
  description = "Daily automated backup window start (UTC, HH:MM). Pick low-traffic hours for your users."
  type        = string
  default     = "03:00"
}

variable "backup_retained_count" {
  description = "How many daily automated backups to keep."
  type        = number
  default     = 30
}

variable "transaction_log_retention_days" {
  description = "Days of WAL kept for point-in-time recovery (1-7 on ENTERPRISE, up to 35 on ENTERPRISE_PLUS)."
  type        = number
  default     = 7

  validation {
    condition     = var.transaction_log_retention_days >= 1 && var.transaction_log_retention_days <= 35
    error_message = "transaction_log_retention_days must be between 1 and 35."
  }
}

variable "database_name" {
  description = "Database n8n will use (DB_POSTGRESDB_DATABASE)."
  type        = string
  default     = "n8n"
}

variable "database_user" {
  description = "Postgres role n8n connects as (DB_POSTGRESDB_USER). Must match the n8n-db-user secret in terraform/iam."
  type        = string
  default     = "n8n"
}

variable "labels" {
  description = "Labels applied to the instance."
  type        = map(string)
  default     = { managed_by = "terraform", workload = "n8n" }
}
