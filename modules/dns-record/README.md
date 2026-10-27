# dns-record

A single Cloudflare DNS record on the `qnsc.vn` zone. Used to point product
hostnames (API, web) at their ALB / CloudFront / Pages target. The zone ID is
typically read from `infra` bootstrap remote state.

**v2 (cloudflare provider v5):** the resource is `cloudflare_dns_record` and the
v5 API requires the full FQDN, so the module takes a new required `zone_name`
and builds it from `name` (+ `zone_name` for the `@` apex). v5 also removed
`allow_overwrite`: a create against an existing record FAILS with
"record already exists" — adoption after a `state rm` teardown is now an
explicit two-step import (see below).

**Consumer migration (bumping v1 → v2):** renaming the resource inside the
module changes the state address in YOUR stack, and on OpenTofu 1.12 neither
`moved` blocks nor `removed {}` blocks work here (cross-type moves are rejected;
v4-named state entries fail plan with "no schema available"). Do it with CLI
state surgery before the first apply on the bumped tag:

```bash
tofu state rm 'module.dns_api.cloudflare_record.this[0]'
tofu import 'module.dns_api.cloudflare_dns_record.this[0]' '<zone_id>/<record_id>'
```

(import format `<zone_id>/<record_id>` per the provider's v5 dns_record docs.
Both steps were proven on a hand-made v4 state against tofu 1.12 + 5.28.1.)

## Usage

```hcl
module "dns_api" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/dns-record?ref=dns-record-v2.0.0"

  zone_id   = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id
  zone_name = "qnsc.vn"
  name      = "rova-api-dev"
  type      = "CNAME"
  content   = data.terraform_remote_state.runtime.outputs.alb_dns_name
  proxied   = false # ALB/CloudFront target — keep grey-cloud
  comment   = "managed by rova-develop"
}
```

## Inputs

| Name | Type | Default | Description |
| :--- | :--- | :------ | :---------- |
| `enabled` | bool | `true` | Set false to skip creation (e.g. before the CF token is configured). |
| `zone_id` | string | — | Cloudflare Zone ID (the `qnsc.vn` zone). |
| `zone_name` | string | — | Cloudflare zone NAME (`qnsc.vn`) — builds the FQDN v5 requires. |
| `name` | string | — | Record name / subdomain (`rova-dev`, or `@` for apex). |
| `type` | string | `CNAME` | One of `CNAME`, `A`, `AAAA`, `TXT`. |
| `content` | string | — | Record target (CloudFront/ALB domain, or IP). |
| `proxied` | bool | `false` | Cloudflare orange-cloud. Keep false for CloudFront targets. |
| `ttl` | number | `1` | TTL seconds (1 = automatic). Ignored when proxied. |
| `comment` | string | `""` | Dashboard comment (which stack manages this). |
| `allow_overwrite` | — | — | **Removed in v2** (upstream v5 dropped it). Adoption = the `state rm` + `import` sequence above. |

## Outputs

| Name | Description |
| :--- | :---------- |
| `hostname` | FQDN (e.g. `rova-dev.qnsc.vn`), or null when disabled. |
| `record_id` | Cloudflare record ID, or null when disabled. |
