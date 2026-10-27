# Plan-only test root: non-empty CORS + lifecycle rules + custom domain.
# Run: (cd modules/cf-r2/tests/basic && tofu init -backend=false && tofu plan -refresh=false -input=false)
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "5.28.1" }
  }
}

provider "cloudflare" {
  api_token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # placeholder, not a credential
}

module "bucket" {
  source = "../.."

  account_id   = "0123456789abcdef0123456789abcdef"
  name         = "plan-only-bucket"
  jurisdiction = "default"
  cors_rules = [{
    id              = "presigned-put"
    allowed_methods = ["PUT"]
    allowed_origins = ["https://example.com"]
    allowed_headers = ["*"]
    max_age_seconds = 3600
  }]
  lifecycle_rules = [{
    id                              = "tmp-expiry"
    prefix                          = "tmp/"
    expiration_days                 = 7
    abort_incomplete_multipart_days = 3
  }]
  custom_domain = {
    hostname = "cdn.example.com"
    zone_id  = "0123456789abcdef0123456789abcdef"
  }
}
