# =============================================================================
# pages-web — Cloudflare Pages hosting for a single-page web app (SPA).
#
# Replaces the deprecated S3 + CloudFront (`cdn`) module for the WEB surface.
# Cloudflare Pages gives us: global CDN with ZERO egress cost, native SPA
# routing (deep-links fall back to index.html automatically — no CloudFront
# Function / custom-error-response wiring needed), free managed TLS, and a
# custom domain, all on the same Cloudflare account that already serves DNS.
#
# Content is deployed out-of-band with `wrangler pages deploy` from CI — this
# module only provisions the project shell, the custom domain, and the DNS
# CNAME (Pages does NOT create the DNS record for a custom domain itself).
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}
