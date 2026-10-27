# Plan-only test root: exercises the tunnel + ingress config shape. The `token`
# output reads a data source, but the read is deferred: with a placeholder token
# the plan completes cleanly (3 to add) and only emits 401 dry-run warnings.
# Run: (cd modules/cf-tunnel/tests/basic && tofu init -backend=false && tofu plan -refresh=false -input=false)
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "5.28.1" }
  }
}

provider "cloudflare" {
  api_token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # placeholder, not a credential
}

module "tunnel" {
  source = "../.."

  account_id = "0123456789abcdef0123456789abcdef"
  name       = "plan-only-tunnel"
  hostname   = "plan-only.example.com"
  service    = "http://localhost:8000"
}
