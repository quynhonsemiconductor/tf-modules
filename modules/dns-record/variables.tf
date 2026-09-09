variable "enabled" {
  type        = bool
  default     = true
  description = <<-EOT
    Whether to create the record. Set false (or leave zone_id empty at the
    caller) to skip DNS while a stack is applied before the Cloudflare zone/token
    are configured.
  EOT
}

variable "zone_id" {
  type        = string
  description = "Cloudflare Zone ID (e.g. the qnsc.vn zone). Typically read from infra bootstrap remote state."
}

variable "name" {
  type        = string
  description = "Record name / subdomain (e.g. \"rova-dev\" for rova-dev.qnsc.vn), or \"@\" for the zone apex."
}

variable "type" {
  type        = string
  default     = "CNAME"
  description = "Record type (CNAME for CloudFront/ALB targets, A for IPs)."

  validation {
    condition     = contains(["CNAME", "A", "AAAA", "TXT"], var.type)
    error_message = "type must be one of CNAME, A, AAAA, TXT."
  }
}

variable "content" {
  type        = string
  description = "Record target (e.g. a CloudFront domain d123.cloudfront.net, or an IP for A records)."
}

variable "proxied" {
  type        = bool
  default     = false
  description = <<-EOT
    Whether Cloudflare proxies (orange-cloud) the record. Keep false for
    CloudFront targets — CloudFront must see the real Host header to match its
    distribution alias, and double-proxying (CF-in-front-of-CloudFront) adds
    latency with no benefit for an already-CDN'd origin.
  EOT
}

variable "ttl" {
  type        = number
  default     = 1
  description = "TTL in seconds (1 = automatic). Ignored when proxied = true (forced to 1)."
}

variable "comment" {
  type        = string
  default     = ""
  description = "Free-text comment shown in the Cloudflare dashboard (e.g. which stack manages this)."
}

variable "allow_overwrite" {
  type        = bool
  default     = true
  description = <<-EOT
    Adopt an existing Cloudflare record of the same name/type on create instead
    of failing with "record already exists". Defaults to true so a rebuild after
    a `state rm` teardown (which leaves the live record orphaned) cleanly takes
    the record over and repoints it, rather than erroring on the create.
  EOT
}
