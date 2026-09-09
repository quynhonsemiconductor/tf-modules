# alb

Application Load Balancer with an HTTPS (:443) listener and an HTTP (:80) →
HTTPS redirect. In the Option A shared-runtime layout this is created **once per
env** (in `infra/live/runtime-*`) and shared by every product via
host-header listener rules — services attach their own forward rules to the
exported `https_listener_arn`.

## Usage

```hcl
module "alb" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/alb?ref=alb-v1.0.0"

  name                       = "qnsc-runtime-prod"
  security_group_ids         = [module.network.sg_alb_id]
  subnet_ids                 = module.network.public_subnet_ids
  certificate_arn            = var.acm_cert_arn
  enable_deletion_protection = true          # prod
  access_logs_bucket         = module.alb_logs.bucket # prod forensics; "" disables
  tags                       = local.tags
}
```

## Inputs

| Name | Type | Default | Description |
| :--- | :--- | :------ | :---------- |
| `name` | string | — | ALB name (e.g. `rova-develop`). |
| `security_group_ids` | list(string) | — | SGs for the ALB (typically `network.sg_alb_id`). |
| `subnet_ids` | list(string) | — | Public subnet IDs the ALB spans. |
| `certificate_arn` | string | — | ACM cert ARN for the HTTPS listener (ap-southeast-1). |
| `ssl_policy` | string | `ELBSecurityPolicy-TLS13-1-2-2021-06` | HTTPS listener SSL policy. |
| `enable_deletion_protection` | bool | `false` | Protect the ALB from deletion (true in prod). |
| `access_logs_bucket` | string | `""` | S3 bucket for access logs. Empty disables access logging. |
| `tags` | map(string) | `{}` | Resource tags. |

## Outputs

| Name | Description |
| :--- | :---------- |
| `arn` | ALB ARN. |
| `dns_name` | ALB DNS name (health-check URLs, CNAME target). |
| `zone_id` | ALB hosted zone ID (Route53/Cloudflare ALIAS). |
| `https_listener_arn` | HTTPS (:443) listener ARN — services attach forward rules here. |
| `http_listener_arn` | HTTP (:80) listener ARN. |
