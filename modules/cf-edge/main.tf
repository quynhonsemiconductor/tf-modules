# =============================================================================
# cf-edge — Cloudflare zone-level edge governance (WAF + rate-limiting).
#
# One qnsc.vn zone fronts every product, so this is an ACCOUNT/ZONE-level
# stack (not per-product): the caller configures the cloudflare provider and
# passes the zone_id (read from infra bootstrap remote state, the single
# source of truth — same pattern as dns-record).
#
# Three independent rule phases, each created only when its input is non-empty
# so the module is safe on any Cloudflare plan tier:
#   • http_ratelimit             — rate-limit rules (free tier allows 1 rule)
#   • http_request_firewall_managed — Cloudflare Managed + OWASP rulesets
#                                     (Pro+ only; behind enable_managed_waf,
#                                      default OFF so free zones apply cleanly)
#   • http_request_firewall_custom  — custom expression firewall rules (free)
#
# WAF ownership: if the edge WAF is chosen for prod, DROP the AWS `waf` module
# from runtime-prod — never run both (see IMPLEMENTATION_PLAN_OPTION_A §6).
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

# ── Rate limiting (http_ratelimit) ────────────────────────────────────────────
# Created only when at least one rule is supplied. Free plan permits a single
# rate-limiting rule; Pro+ permits more.
resource "cloudflare_ruleset" "ratelimit" {
  count = length(var.rate_limit_rules) > 0 ? 1 : 0

  zone_id     = var.zone_id
  name        = "qnsc edge rate limiting"
  description = "Zone-level rate limiting for product APIs."
  kind        = "zone"
  phase       = "http_ratelimit"

  dynamic "rules" {
    for_each = var.rate_limit_rules
    content {
      ref         = rules.value.ref
      description = rules.value.description
      expression  = rules.value.expression
      action      = rules.value.action
      enabled     = true

      ratelimit {
        characteristics     = rules.value.characteristics
        period              = rules.value.period
        requests_per_period = rules.value.requests_per_period
        mitigation_timeout  = rules.value.mitigation_timeout
      }
    }
  }
}

# ── Managed WAF (http_request_firewall_managed) — Pro+ only ────────────────────
# Deploys Cloudflare's Managed + OWASP Core rulesets by reference. Gated behind
# enable_managed_waf because managed rulesets require a Pro plan or higher; the
# default (false) keeps this module applicable on the free tier.
resource "cloudflare_ruleset" "managed" {
  count = var.enable_managed_waf ? 1 : 0

  zone_id     = var.zone_id
  name        = "qnsc managed WAF"
  description = "Cloudflare Managed + OWASP Core rulesets."
  kind        = "zone"
  phase       = "http_request_firewall_managed"

  dynamic "rules" {
    for_each = var.managed_ruleset_ids
    content {
      ref         = "execute_${substr(rules.value, 0, 8)}"
      description = "Execute managed ruleset ${rules.value}"
      expression  = "true"
      action      = "execute"
      enabled     = true

      action_parameters {
        id = rules.value
      }
    }
  }
}

# ── Custom firewall rules (http_request_firewall_custom) — free ────────────────
# Expression-based allow/deny/challenge rules. Created only when supplied.
resource "cloudflare_ruleset" "custom" {
  count = length(var.custom_firewall_rules) > 0 ? 1 : 0

  zone_id     = var.zone_id
  name        = "qnsc custom firewall"
  description = "Custom expression firewall rules."
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  dynamic "rules" {
    for_each = var.custom_firewall_rules
    content {
      ref         = rules.value.ref
      description = rules.value.description
      expression  = rules.value.expression
      action      = rules.value.action
      enabled     = true
    }
  }
}
