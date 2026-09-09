# dns-record

A single Cloudflare DNS record on the `qnsc.vn` zone. Used to point product
hostnames (API, web) at their ALB / CloudFront / Pages target. The zone ID is
typically read from `infra` bootstrap remote state.

`allow_overwrite` defaults **true** so a rebuild after a `state rm` teardown
(which leaves the live record orphaned) cleanly adopts and repoints the record
instead of erroring with "record already exists".

## Usage

```hcl
module "dns_api" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/dns-record?ref=dns-record-v1.1.0"

  zone_id = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id
  name    = "rova-api-dev"
  type    = "CNAME"
  content = data.terraform_remote_state.runtime.outputs.alb_dns_name
  proxied = false # ALB/CloudFront target — keep grey-cloud
  comment = "managed by rova-develop"
}
```

## Inputs

| Name | Type | Default | Description |
| :--- | :--- | :------ | :---------- |
| `enabled` | bool | `true` | Set false to skip creation (e.g. before the CF token is configured). |
| `zone_id` | string | — | Cloudflare Zone ID (the `qnsc.vn` zone). |
| `name` | string | — | Record name / subdomain (`rova-dev`, or `@` for apex). |
| `type` | string | `CNAME` | One of `CNAME`, `A`, `AAAA`, `TXT`. |
| `content` | string | — | Record target (CloudFront/ALB domain, or IP). |
| `proxied` | bool | `false` | Cloudflare orange-cloud. Keep false for CloudFront targets. |
| `ttl` | number | `1` | TTL seconds (1 = automatic). Ignored when proxied. |
| `comment` | string | `""` | Dashboard comment (which stack manages this). |
| `allow_overwrite` | bool | `true` | Adopt an existing same-name/type record instead of failing. |

## Outputs

| Name | Description |
| :--- | :---------- |
| `hostname` | FQDN (e.g. `rova-dev.qnsc.vn`), or null when disabled. |
| `record_id` | Cloudflare record ID, or null when disabled. |
