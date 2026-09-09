variable "account_id" {
  type        = string
  description = "Cloudflare account ID that owns the Turnstile widget. Typically read from infra bootstrap remote state."
}

variable "name" {
  type        = string
  description = "Widget name shown in the Cloudflare dashboard (e.g. \"qnsc-landing\")."
}

variable "domains" {
  type        = list(string)
  description = <<-EOT
    Hostnames the widget is allowed to render on (e.g. ["qnsc.vn", "www.qnsc.vn"]).
    Add "localhost" only for local testing. A request from any other host fails
    verification.
  EOT

  validation {
    condition     = length(var.domains) > 0
    error_message = "domains must list at least one hostname."
  }
}

variable "mode" {
  type        = string
  default     = "managed"
  description = "Challenge mode: managed (Cloudflare decides), non-interactive, or invisible."

  validation {
    condition     = contains(["managed", "non-interactive", "invisible"], var.mode)
    error_message = "mode must be one of managed, non-interactive, invisible."
  }
}

variable "region" {
  type        = string
  default     = "world"
  description = "Widget region. \"world\" unless a specific region is required."
}
