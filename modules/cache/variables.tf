variable "name" {
  type        = string
  description = "Cache name / replication group id."
}

variable "mode" {
  type        = string
  default     = "serverless"
  description = "\"serverless\" (prod, auto-scaling, ~$90/mo floor) or \"node\" (dev, single small node ~$11/mo)."

  validation {
    condition     = contains(["serverless", "node"], var.mode)
    error_message = "mode must be \"serverless\" or \"node\"."
  }
}

variable "subnet_ids" {
  type        = list(string)
  description = "Data-tier subnet IDs."
}

variable "security_group_id" {
  type        = string
  description = "Cache security group."
}

variable "kms_key_arn" {
  type    = string
  default = ""
}

variable "snapshot_retention_days" {
  type    = number
  default = 3
}

# ── Serverless-mode sizing ────────────────────────────────────────────────────
variable "engine_version" {
  type        = string
  default     = "7"
  description = "Valkey major engine version (serverless mode)."
}

variable "max_data_storage_gb" {
  type    = number
  default = 5
}

variable "max_ecpu_per_second" {
  type    = number
  default = 5000
}

# ── Node-mode sizing ──────────────────────────────────────────────────────────
variable "node_type" {
  type        = string
  default     = "cache.t4g.micro"
  description = "Instance type (node mode)."
}

variable "node_engine_version" {
  type        = string
  default     = "7.2"
  description = <<-EOT
    Valkey engine version (node mode). Default "7.2" is unchanged for existing callers.

    "8.1" is the Valkey 8 target and matches the local and CI images. ElastiCache's "8.2" is
    open-source Valkey 8.1 plus the valkey-search module, not a newer Valkey, so there is no
    separate 8.2 target here. AWS selects the default parameter group for the version.
  EOT

  validation {
    condition     = contains(["7.2", "8.0", "8.1"], var.node_engine_version)
    error_message = "node_engine_version must be one of \"7.2\", \"8.0\", \"8.1\"."
  }
}

variable "apply_immediately" {
  type        = bool
  default     = false
  description = "Node mode: apply engine and node changes at once instead of in the maintenance window. Leave false for production; true where a restart is free (develop)."
}

variable "maintenance_window" {
  type        = string
  default     = null
  description = "Node mode: weekly maintenance window, e.g. \"sun:05:00-sun:06:00\". Null keeps the AWS default."
}

variable "tags" {
  type    = map(string)
  default = {}
}
