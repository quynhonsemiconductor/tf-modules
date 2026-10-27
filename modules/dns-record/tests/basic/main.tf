# Plan-only test root: apex + subdomain FQDN building.
# Run: (cd modules/dns-record/tests/basic && tofu init -backend=false && tofu plan -refresh=false -input=false)
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "5.28.1" }
  }
}

provider "cloudflare" {
  api_token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # placeholder, not a credential
}

module "record" {
  source = "../.."

  zone_id   = "0123456789abcdef0123456789abcdef"
  zone_name = "example.com"
  name      = "api-dev"
  type      = "CNAME"
  content   = "target.example.com"
  proxied   = true
  comment   = "plan-only test record"
}
