# Plan-only test root: non-empty domains (alphabetical order per the v5 contract).
# Run: (cd modules/cloudflare-turnstile/tests/basic && tofu init -backend=false && tofu plan -refresh=false -input=false)
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "5.28.1" }
  }
}

provider "cloudflare" {
  api_token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # placeholder, not a credential
}

module "turnstile" {
  source = "../.."

  account_id = "0123456789abcdef0123456789abcdef"
  name       = "plan-only-widget"
  domains    = ["example.com", "www.example.com"]
  mode       = "managed"
}
