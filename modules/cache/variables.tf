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
  description = "Valkey engine version (node mode). Default \"7.2\" is unchanged for existing callers; \"8.2\" opts in (parameter group family default.valkey8)."
}

variable "tags" {
  type    = map(string)
  default = {}
}
