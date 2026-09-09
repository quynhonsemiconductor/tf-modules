# cf-edge

Cloudflare **zone-level edge governance** for the shared `qnsc.vn` zone: WAF
(managed + custom) and rate-limiting, as three independent ruleset phases.

Because one zone fronts every product, this is an **account/zone-level** concern
(not per-product). The caller configures the `cloudflare` provider and passes
the `zone_id` (read from `infra` bootstrap remote state — the single source
of truth, same pattern as `dns-record`).

## Plan-tier safety

Each phase is created **only when its input is non-empty**, so the module is
safe on any Cloudflare plan:

| Phase | Input | Free tier |
|---|---|---|
| `http_ratelimit` | `rate_limit_rules` | ✅ 1 rule |
| `http_request_firewall_managed` | `enable_managed_waf` (default **off**) | ❌ Pro+ only |
| `http_request_firewall_custom` | `custom_firewall_rules` | ✅ |

## WAF ownership

If the edge WAF is chosen for prod, **drop the AWS `waf` module from
`runtime-prod`** — never run both (see `IMPLEMENTATION_PLAN_OPTION_A.md` §6).

## Example

```hcl
module "edge" {
  source  = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cf-edge?ref=cf-edge-v1.0.0"
  zone_id = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id

  rate_limit_rules = [{
    ref                 = "api_default"
    description         = "Rate-limit product APIs per IP"
    expression          = "(http.request.uri.path matches \"^/v1/\")"
    period              = 60
    requests_per_period = 300
    mitigation_timeout  = 60
  }]

  enable_managed_waf = false # set true on Pro+; then drop AWS waf from runtime-prod
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `zone_id` | string | — | Cloudflare zone ID (qnsc.vn). |
| `rate_limit_rules` | list(object) | `[]` | Rate-limit rules (empty = no ruleset). |
| `enable_managed_waf` | bool | `false` | Deploy managed + OWASP rulesets (Pro+). |
| `managed_ruleset_ids` | list(string) | Managed + OWASP | Ruleset IDs to execute. |
| `custom_firewall_rules` | list(object) | `[]` | Custom expression rules (empty = no ruleset). |

## Outputs

| Name | Description |
|---|---|
| `ratelimit_ruleset_id` | Rate-limiting ruleset ID (null if none). |
| `managed_ruleset_id` | Managed-WAF ruleset ID (null if disabled). |
| `custom_ruleset_id` | Custom-firewall ruleset ID (null if none). |
