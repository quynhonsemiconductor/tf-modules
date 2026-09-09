variable "zone_id" {
  type        = string
  description = "Cloudflare Zone ID (the qnsc.vn zone). Read from infra bootstrap remote state."
}

# ── Rate limiting ─────────────────────────────────────────────────────────────
variable "rate_limit_rules" {
  type = list(object({
    ref                 = string
    description         = string
    expression          = string
    period              = number
    requests_per_period = number
    mitigation_timeout  = number
    characteristics     = optional(list(string), ["ip.src", "cf.colo.id"])
    action              = optional(string, "block")
  }))
  default     = []
  description = <<-EOT
    Rate-limiting rules (http_ratelimit phase). Empty (default) creates no
    ruleset. Free plan permits a single rule. `characteristics` defaults to
    per-IP+colo; `action` defaults to "block". `period`/`mitigation_timeout`
    are in seconds.
  EOT
}

# ── Managed WAF (Pro+ only) ───────────────────────────────────────────────────
variable "enable_managed_waf" {
  type        = bool
  default     = false
  description = <<-EOT
    Deploy Cloudflare's Managed + OWASP Core rulesets. Requires a Pro plan or
    higher — leave false on the free tier. If enabled for prod, drop the AWS
    `waf` module from runtime-prod (never run both).
  EOT
}

variable "managed_ruleset_ids" {
  type = list(string)
  default = [
    "efb7b8c949ac4650a09736fc376e9aee", # Cloudflare Managed Ruleset
    "4814384a9e5d4991b9815dcfc25d2f1f", # Cloudflare OWASP Core Ruleset
  ]
  description = "Managed ruleset IDs to execute when enable_managed_waf is true. Defaults to Cloudflare Managed + OWASP Core."
}

# ── Custom firewall rules ─────────────────────────────────────────────────────
variable "custom_firewall_rules" {
  type = list(object({
    ref         = string
    description = string
    expression  = string
    action      = string # block | managed_challenge | js_challenge | skip | log
  }))
  default     = []
  description = "Custom expression firewall rules (http_request_firewall_custom phase). Empty (default) creates no ruleset."
}
