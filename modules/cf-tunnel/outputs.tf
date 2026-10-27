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
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.this.token
  sensitive   = true
  description = "Connector token — the cloudflared sidecar's TUNNEL_TOKEN. A live credential, read back from the API (correct even for adopted tunnels whose secret is not in state)."
}
