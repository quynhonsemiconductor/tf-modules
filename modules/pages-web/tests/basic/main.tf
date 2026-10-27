# Plan-only test root: custom domain + CNAME wired.
# Run: (cd modules/pages-web/tests/basic && tofu init -backend=false && tofu plan -refresh=false -input=false)
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "5.28.1" }
  }
}

provider "cloudflare" {
  api_token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # placeholder, not a credential
}

module "web" {
  source = "../.."

  account_id        = "0123456789abcdef0123456789abcdef"
  name              = "plan-only-web"
  production_branch = "main"
  production_env_vars = {
    VITE_API_URL = "https://api.example.com"
  }
  domain      = "app-dev.example.com"
  zone_id     = "0123456789abcdef0123456789abcdef"
  record_name = "app-dev"
  comment     = "plan-only test project"
}
