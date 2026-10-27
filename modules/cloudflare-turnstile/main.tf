# =============================================================================
# cloudflare-turnstile — a Cloudflare Turnstile widget (bot/CAPTCHA challenge)
# for a public form. The edge-side counterpart to the app's server-side
# verification: the widget's sitekey is baked into the client (public), and its
# secret is used by the Pages Function to call the Turnstile siteverify API.
#
# Provisioned centrally in the platform (the same place the Cloudflare provider
# + admin token already live for `edge`/`storage`), so the Turnstile admin
# scope is not copied into each product's CI — the same rule the cf-r2 buckets
# follow. Consumers read `sitekey` (public → bake at build) and set `secret`
# out-of-band as the Pages `TURNSTILE_SECRET` env var (never committed, never in
# app state), matching the platform's "secrets out-of-band" convention.
#
# Requires the Cloudflare provider v5 (pin ~> 5.28, same as the `edge` stack).
# v5 note: `domains` is a plain list and must stay in ALPHABETICAL order or the
# provider reads perpetual drift against the API response.
# =============================================================================

resource "cloudflare_turnstile_widget" "this" {
  account_id = var.account_id
  name       = var.name
  domains    = var.domains
  mode       = var.mode
  region     = var.region
}
