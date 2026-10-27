locals {
  # Custom domain is wired only when the domain, its zone, and the record name
  # are all provided — otherwise the SPA is reachable on <name>.pages.dev only.
  custom_domain_enabled = var.domain != "" && var.zone_id != "" && var.record_name != ""
}

# ── Pages project (direct-upload; content pushed by `wrangler pages deploy`) ──
resource "cloudflare_pages_project" "this" {
  account_id        = var.account_id
  name              = var.name
  production_branch = var.production_branch

  deployment_configs = {
    production = {
      # v5 shape: env_vars is a map of {type, value} (plain_text here). Secrets
      # set out-of-band via `wrangler pages secret put` surface inside the SAME
      # env_vars map, so a plan may show them as drift — set them through IaC
      # (type = "secret_text") instead, never by hand.
      env_vars = {
        for k, v in var.production_env_vars : k => { type = "plain_text", value = v }
      }
    }
  }

  # SECRETS ARE NOT THIS MODULE'S. A Pages secret (a Function's signing key, an API token) is set through IaC as an
  # env_vars entry with type = "secret_text", or out of band with `wrangler pages secret put`, because a value written
  # through Terraform as plain_text lands in state in clear text. In v5 there is no separate `secrets` attribute to
  # ignore_changes away: dashboard-set secrets surface inside the SAME env_vars map, so the out-of-band path can read as
  # drift — prefer the secret_text entry in the caller's config.
}

# ── Custom domain attached to the project ─────────────────────────────────────
resource "cloudflare_pages_domain" "this" {
  count = local.custom_domain_enabled ? 1 : 0

  account_id   = var.account_id
  project_name = cloudflare_pages_project.this.name
  name         = var.domain # v5 renamed `domain` to `name`
}

# ── DNS CNAME → <name>.pages.dev ──────────────────────────────────────────────
# Pages does NOT create the record for a custom domain, so we own it here.
# Proxied (orange-cloud) so it's served through Cloudflare's edge + TLS.
resource "cloudflare_dns_record" "this" {
  count = local.custom_domain_enabled ? 1 : 0

  zone_id = var.zone_id
  name    = var.domain # v5 requires the full FQDN; `domain` already is one
  type    = "CNAME"
  content = cloudflare_pages_project.this.subdomain
  proxied = true
  ttl     = 1
  comment = var.comment

  depends_on = [cloudflare_pages_domain.this]
}
