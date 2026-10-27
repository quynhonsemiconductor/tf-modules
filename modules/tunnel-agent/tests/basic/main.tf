# Plan-only test root: sidecar enabled (real token secret ARN shape).
# Run: (cd modules/tunnel-agent/tests/basic && tofu init -backend=false && tofu plan -refresh=false -input=false)
module "tunnel_agent" {
  source = "../.."

  name                    = "plan-only"
  region                  = "ap-southeast-1"
  log_group               = "/plan-only/cloudflared"
  tunnel_token_secret_arn = "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:plan-only"
  app_port                = 8000
}
