variable "project_id" {
  description = "Workload project hosting the n8n service (uptime checks and alert policies live next to the workload)."
  type        = string
}

variable "environment" {
  description = "Environment name (dev | prod)."
  type        = string
}

variable "n8n_hostname" {
  description = "Public hostname of n8n (terraform/n8n public_hostname, or the *.run.app host without scheme)."
  type        = string
}

variable "cloud_sql_instance_name" {
  description = "Cloud SQL instance name (terraform/database output instance_name) for the database-down alert."
  type        = string
}

variable "alert_email_addresses" {
  description = "Email notification channels. Use a shared on-call alias, not a person."
  type        = set(string)
  default     = []
}

variable "uptime_check_period" {
  description = "How often each prober hits the endpoint. 60s is the minimum on the default tier."
  type        = string
  default     = "60s"
}

variable "uptime_failure_window" {
  description = "How long the endpoint must be failing before paging. 300s absorbs a Cloud Run revision rollout."
  type        = string
  default     = "300s"
}
