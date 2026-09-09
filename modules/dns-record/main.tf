# =============================================================================
# dns-record — a single Cloudflare DNS record (CNAME/A) for a product surface.
#
# One qnsc.vn zone serves every product, so the zone_id + API token are
# account-level inputs (the token via the cloudflare provider the CALLER
# configures; the zone_id read from infra bootstrap's remote state).
# The caller passes just the subdomain + target — the "which product/env"
# specifics — while the record shape (CNAME → CloudFront, etc.) lives here.
#
# The whole record is created only when `enabled` is true, so a stack can
# apply cleanly before DNS is wired (e.g. zone_id/token not yet configured).
# Because Terraform owns the record's full lifecycle, a teardown removes it —
# no stale CNAME left behind to collide with a CloudFront alias on rebuild.
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

resource "cloudflare_record" "this" {
  count = var.enabled ? 1 : 0

  zone_id = var.zone_id
  name    = var.name
  type    = var.type
  content = var.content
  proxied = var.proxied
  ttl     = var.proxied ? 1 : var.ttl # proxied records must use ttl=1 (automatic)
  comment = var.comment

  # Adopt a pre-existing record (e.g. one orphaned by a `state rm` teardown)
  # rather than failing the create with "record already exists".
  allow_overwrite = var.allow_overwrite
}
