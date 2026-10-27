# Plan-only test root: exercises the tunnel + ingress config shape. NOTE: the
# `token` output reads a data source from the API at plan time, so this root can
# only plan against the REAL account (tofu plan with real credentials); with a
# dummy token it fails at the data read, after resource planning succeeded.
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
