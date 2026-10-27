# Cloudflare Tunnel — created and owned by Terraform.
#
# Replaces the "create it in the dashboard and paste the token into a secret" step that
# every product carried before this module existed. The module owns the tunnel secret,
# so it can build the connector token itself (see the `token` output) — nothing about a
# tunnel actually requires a human.
#
# WHAT THIS MEANS FOR STATE: the tunnel secret is a live credential and it WILL be stored
# in Terraform state. That is the trade this module makes. It is acceptable here because
# the state bucket is KMS-encrypted and readable only by the infra-apply role, which
# already holds AdministratorAccess — so the token grants nothing that reading the state
# did not already imply. A product that cannot accept a credential in state should keep
# creating tunnels out of band and pass the id in as a variable instead.

# The tunnel's shared secret. Cloudflare requires a base64 value of at least 32 bytes;
# `random_id` keeps it in state and stable, so the tunnel is not recreated on every plan.
#
# Rotating it means replacing the tunnel: change `keepers` deliberately, and expect a new
# tunnel id, a new CNAME target and a new connector token.
resource "random_id" "secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id    = var.account_id
  name          = var.name
  tunnel_secret = random_id.secret.b64_std

  # Defaults to "cloudflare" — routing served to the connector by Cloudflare, which is
  # what the ingress rules below write.
  #
  # "local" tells cloudflared its routing comes from a local config file or a --url flag.
  # A sidecar handed only TUNNEL_TOKEN has neither, so it connects successfully — QUIC up,
  # every precheck passing — and then logs "No ingress rules were defined in provided
  # config (if any) nor from the cli" and returns 503 for every request. The tunnel looks
  # healthy from every angle except the one that matters.
  #
  # Overridable so an EXISTING tunnel can be adopted without its configuration being
  # rewritten by the import. See the variable.
  config_src = var.config_src != "" ? var.config_src : null

  lifecycle {
    # ADOPTING AN EXISTING TUNNEL DEPENDS ON THIS.
    #
    # A tunnel created by hand has a secret Cloudflare knows and nobody else does. On
    # `tofu import`, Terraform would compare it against this module's freshly generated
    # random_id and try to write the generated one — which changes the tunnel's secret
    # and therefore its CONNECTOR TOKEN. Every running cloudflared then holds a token
    # that no longer authenticates, and the API is unreachable until the next deploy
    # ships the new one.
    #
    # Ignoring it makes an import a no-op: the tunnel keeps the secret it already has
    # (which the `token` output builds from), and the resource is simply adopted. It also
    # means the secret is never rewritten in place for a tunnel this module created —
    # rotating one is a deliberate replace, not a plan diff.
    ignore_changes = [tunnel_secret]
  }
}

# ── Routing ───────────────────────────────────────────────────────────────────
# A tunnel with no ingress rule is inert: it connects, reports healthy, and 503s every
# request. Creating the tunnel without this is the trap the resource above describes.
#
# OPTIONAL, and empty `hostname` is the escape hatch for adoption: a tunnel that already
# has routing configured elsewhere (a dashboard-created one, say) can be brought under
# Terraform WITHOUT this module rewriting rules nobody has compared. Cloudflare's
# configuration API is a whole-document PUT, so writing a partial rule set silently
# discards anything the existing configuration had that this module does not know about.
# Adopt first, move routing in a second, deliberate change.
#
# The catch-all matters as much as the hostname rule. Cloudflare requires the LAST rule
# to have no hostname, and without it the configuration is rejected.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  count = var.hostname != "" ? 1 : 0

  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config = {
    # Anything that reaches the connector without matching the hostname rule is not
    # traffic this tunnel is for; Cloudflare requires the LAST rule to have no
    # hostname, and without the catch-all the configuration is rejected.
    ingress = [
      { hostname = var.hostname, service = var.service },
      { service = "http_status:404" },
    ]
  }
}
