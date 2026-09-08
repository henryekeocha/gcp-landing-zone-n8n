variable "org_id" {
  description = "Numeric GCP organization ID. All folders and projects in this landing zone hang off this org."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX) attached to every project."
  type        = string
}

variable "prefix" {
  description = "Short, globally-unique prefix used to build project IDs (project IDs are global across all of GCP)."
  type        = string
  default     = "lz-n8n"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,12}$", var.prefix))
    error_message = "prefix must be 2-13 chars, lowercase letters, digits and hyphens, starting with a letter (project IDs are capped at 30 chars)."
  }
}

variable "project_suffix" {
  description = "Random-ish suffix appended to project IDs so re-creating a deleted project (IDs are reserved for 30 days) never collides. Set once per landing zone."
  type        = string
  default     = "a1"
}

variable "environments" {
  description = "Workload environments. One project per environment, each placed under the matching folder."
  type        = set(string)
  default     = ["dev", "prod"]
}

variable "labels" {
  description = "Labels applied to every project (cost allocation, ownership)."
  type        = map(string)
  default = {
    owner      = "platform"
    managed_by = "terraform"
    workload   = "n8n"
  }
}
