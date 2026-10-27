output "id" {
  value       = cloudflare_zero_trust_tunnel_cloudflared.this.id
  description = "Tunnel UUID."
}

output "cname" {
  value       = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  description = <<-EOT
    The CNAME target for a hostname served by this tunnel — "<id>.cfargotunnel.com".

    Built from the tunnel id: v5 removed the computed `cname` attribute. It is a
    Cloudflare-internal name that only resolves through the edge, so the DNS record
    MUST be proxied (orange cloud). An unproxied record cannot reach a connector.
  EOT
}

output "token" {
  value = base64encode(jsonencode({
    "a" = cloudflare_zero_trust_tunnel_cloudflared.this.account_tag
    "t" = cloudflare_zero_trust_tunnel_cloudflared.this.id
    "s" = cloudflare_zero_trust_tunnel_cloudflared.this.tunnel_secret
  }))
  sensitive   = true
  description = <<-EOT
    Connector token — the cloudflared sidecar's TUNNEL_TOKEN. A live credential.

    v5 removed the provider-computed `tunnel_token`; the token is just the
    Cloudflare-documented JSON envelope {a: account tag, t: tunnel id,
    s: tunnel secret} base64-encoded, so it is built here from fields the
    resource still exposes.
  EOT
}
