variable "project_id" {
  description = "Workload project that owns this VPC (one networking module instance per environment project)."
  type        = string
}

variable "environment" {
  description = "Environment name used in resource names and labels (dev | prod)."
  type        = string

  validation {
    condition     = contains(["dev", "prod", "staging"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "region" {
  description = "Region for the regional subnets, Cloud Router and Cloud NAT."
  type        = string
  default     = "us-central1"
}

variable "subnets" {
  description = <<-EOT
    Subnets to create in this VPC. Keys become the subnet name suffix.
    Every subnet has Private Google Access on and flow logs enabled.
    The n8n Cloud Run service uses Direct VPC egress into the `app` subnet;
    the `mgmt` subnet is for the (optional) IAP-only bastion / ops VMs.
  EOT
  type = map(object({
    cidr        = string
    description = optional(string, "")
  }))
  default = {
    app  = { cidr = "10.10.0.0/22", description = "Cloud Run direct VPC egress + private service endpoints" }
    mgmt = { cidr = "10.10.4.0/24", description = "Ops/bastion VMs reached only via IAP TCP forwarding" }
  }
}

variable "cloud_sql_peering_prefix_length" {
  description = "Prefix length of the internal range reserved for Cloud SQL private services access (VPC peering). /20 is the smallest Google recommends for a single-region Cloud SQL footprint."
  type        = number
  default     = 20
}

variable "enable_nat_logging" {
  description = "Log NAT errors (dropped translations). ALL is noisy and costly; ERRORS_ONLY is the usual production setting."
  type        = bool
  default     = true
}
