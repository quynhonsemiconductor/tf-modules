variable "account_id" {
  type        = string
  description = "Cloudflare account ID that owns the R2 bucket. Typically read from infra bootstrap remote state."
}

variable "name" {
  type        = string
  description = "R2 bucket name (e.g. \"rova-develop-attachments\"). Immutable; changing it replaces the bucket."
}

variable "location" {
  type        = string
  default     = null
  description = <<-EOT
    Best-effort bucket location hint. One of apac, eeur, enam, weur, wnam, oc.
    Only honored the first time a bucket of a given name is created. Leave null
    to let Cloudflare choose. Use "apac" to co-locate with the ap-southeast-1
    AWS footprint.
  EOT

  validation {
    condition     = var.location == null || contains(["apac", "eeur", "enam", "weur", "wnam", "oc"], coalesce(var.location, "apac"))
    error_message = "location must be one of apac, eeur, enam, weur, wnam, oc (or null)."
  }
}

variable "storage_class" {
  type        = string
  default     = "Standard"
  description = "Default storage class for newly uploaded objects: Standard or InfrequentAccess."

  validation {
    condition     = contains(["Standard", "InfrequentAccess"], var.storage_class)
    error_message = "storage_class must be Standard or InfrequentAccess."
  }
}

variable "jurisdiction" {
  type        = string
  default     = null
  description = <<-EOT
    Data-residency jurisdiction the bucket is guaranteed to be stored in: default,
    eu, or fedramp. Leave null for the standard (non-jurisdiction-scoped) bucket.
    NOTE: this changes the S3 API endpoint host — keep it in sync with the
    endpoint the app is configured with.
  EOT

  validation {
    condition     = var.jurisdiction == null || contains(["default", "eu", "fedramp"], coalesce(var.jurisdiction, "default"))
    error_message = "jurisdiction must be one of default, eu, fedramp (or null)."
  }
}

variable "cors_rules" {
  type = list(object({
    id              = optional(string)
    allowed_methods = list(string)
    allowed_origins = list(string)
    allowed_headers = optional(list(string))
    expose_headers  = optional(list(string))
    max_age_seconds = optional(number)
  }))
  default     = []
  description = "CORS rules (e.g. for browser presigned PUT uploads). Empty = no CORS config."
}

variable "lifecycle_rules" {
  type = list(object({
    id                              = string
    prefix                          = optional(string, "")
    expiration_days                 = optional(number)
    abort_incomplete_multipart_days = optional(number)
  }))
  default     = []
  description = <<-EOT
    Lifecycle rules. Each may set expiration_days (delete objects older than N
    days under prefix) and/or abort_incomplete_multipart_days (abort multipart
    uploads not completed within N days). Days are converted to R2's second-based
    conditions internally.
  EOT
}

variable "custom_domain" {
  type = object({
    hostname = string
    zone_id  = string
  })
  default = null

  description = <<-EOT
    Attach a Cloudflare custom domain to this bucket, making its objects
    PUBLICLY readable by key over that hostname and cached at the edge.

    ONLY set this for a bucket that holds non-sensitive assets. Attaching a
    domain to a bucket of permission-gated files makes every object readable by
    anyone who can guess or obtain a key, silently bypassing every authorization
    check in the application — there is no error and no log line when that
    happens.

    Leave null (the default) for private buckets.

    NOTE: edge cache TTL is NOT set here — the R2 custom-domain resource has no
    such attribute. Objects are served with Cloudflare's default caching; add a
    cloudflare_ruleset in the edge stack if a specific TTL is required. Keys
    embed a uuid, so a changed asset always gets a new key and stale cache
    entries are not a correctness concern.
  EOT
}
