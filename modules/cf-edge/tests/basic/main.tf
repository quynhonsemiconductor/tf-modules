# Plan-only test root: exercises all three ruleset phases with NON-EMPTY inputs,
# which `tofu validate` cannot catch (validate has no plan-time type checking).
# Run: (cd modules/cf-edge/tests/basic && tofu init -backend=false && tofu plan -refresh=false -input=false)
# Expected: "Plan: 3 to add, 0 to change, 0 to destroy." (no API call is made).
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "5.28.1" }
  }
}

# Low-entropy placeholder — NOT a credential; -refresh=false makes no API calls.
provider "cloudflare" {
  api_token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # placeholder, not a credential
}

module "edge" {
  source = "../.."

  zone_id = "0123456789abcdef0123456789abcdef"
  rate_limit_rules = [{
    ref                 = "r1"
    description         = "plan-only test rule"
    expression          = "true"
    action              = "block"
    characteristics     = ["ip.src", "cf.colo.id"]
    period              = 10
    requests_per_period = 50
    mitigation_timeout  = 10
  }]
  enable_managed_waf  = true
  managed_ruleset_ids = ["efb7b8c949ac4650a09736fc376e9aee"]
  custom_firewall_rules = [{
    ref         = "c1"
    description = "plan-only test rule"
    expression  = "true"
    action      = "block"
  }]
}
