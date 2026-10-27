variable "account_id" {
  type        = string
  description = "Cloudflare account ID that owns the Pages project (account-level input, not a secret)."
}

variable "name" {
  type        = string
  description = "Pages project name (e.g. \"rova-develop-web\"). Also the <name>.pages.dev subdomain."
}

variable "production_branch" {
  type        = string
  default     = "main"
  description = "Branch treated as the production deployment. Must match the --branch wrangler deploys with."
}

variable "production_env_vars" {
  type        = map(string)
  default     = {}
  description = "Plain (non-secret) environment variables for the production deployment (e.g. VITE_API_URL)."
}

# ── Custom domain (optional) ──────────────────────────────────────────────────
# When domain + zone_id are set, attach the custom domain to the project and
# create the proxied CNAME → <name>.pages.dev. Leave empty to serve only on the
# default *.pages.dev URL (e.g. before DNS/zone is wired).
variable "domain" {
  type        = string
  default     = ""
  description = "Custom domain to serve the SPA on (e.g. \"rova-dev.qnsc.vn\"). Empty = pages.dev only."
}

variable "zone_id" {
  type        = string
  default     = ""
  description = "Cloudflare Zone ID for the custom domain's zone (e.g. the qnsc.vn zone). Required when domain is set."
}

variable "record_name" {
  type        = string
  default     = ""
  description = "DNS record name / subdomain for the custom domain (e.g. \"rova-dev\"). Required when domain is set."
}

variable "comment" {
  type        = string
  default     = ""
  description = "Free-text comment shown on the DNS record in the Cloudflare dashboard."
}
