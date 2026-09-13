# product-service

One ECS service plus the sidecars and ingress that always accompany it. Wraps
[`ecs-service`](../ecs-service), [`observability-agent`](../observability-agent),
[`firelens-agent`](../firelens-agent), [`tunnel-agent`](../tunnel-agent) and
[`dns-record`](../dns-record).

**Status: `0.1.0`, unreleased and unconsumed.** Adopting it is a state migration, not a
dependency bump — see [Migration](#migration) before using it.

## Why it exists

Each product repo carries its own `infra/modules/stack` composition module — rova 3,233
lines, opshub 2,567, qnsc-kb 1,104 — implementing one pattern three times. Measured
2026-09-12, the `module "api"` call passes **31 of 34 arguments identically** across all
three, so the compositions have not diverged in substance, only in coverage.

Coverage is the expensive part, and the cost has been measured rather than assumed:

- `cache.shared` existed in rova and qnsc-kb but not opshub, so opshub-develop ran its own
  ElastiCache node at **~$15/month** for services pinned at `min_count = 0`. ElastiCache has
  no stopped state, so that billed 730 h/month.
- The cache/min_count guard was a `validation` in two products and a `check` block in the
  third, where a violated assert exits 0 — so that guard permitted exactly what it described.
- The Valkey `db_index` registry was inline in all three, in three different states.

## What it actually centralises

Not the ECS service — `ecs-service` already does that. The value is the **wiring between**
the service and its sidecars, which each product hand-assembled and therefore drifted on:

| # | Wiring | What goes wrong without it |
| :- | :--- | :--- |
| 1 | `additional_containers` concat | A forgotten sidecar silently does not run |
| 2 | Sidecar token ARNs onto the **execution** role | Task fails at start with `ResourceInitializationError`, which does not name IAM as the cause |
| 3 | FireLens `task_s3_bucket_arns` onto the **task** role | Log router cannot write |
| 4 | ALB-vs-tunnel exclusivity | A tunnel-served task registered as an ALB target fails health checks forever, and the circuit breaker rolls the release back |

Item 4 is the one worth the interface change: `ingress.mode` is a single field with values
`none` / `tunnel` / `alb`, so the impossible combination is **unrepresentable** rather than
merely discouraged. Each product previously wrote `attach_alb = !module.tunnel.enabled` out
per service.

## Usage

```hcl
module "api" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/product-service?ref=product-service-v0.1.0"

  product      = "rova"
  env          = "prod"
  service_name = "api"
  region       = var.region

  cluster_name = module.ecs_cluster.cluster_name
  cluster_arn  = module.ecs_cluster.cluster_arn

  vpc_id            = data.terraform_remote_state.runtime.outputs.vpc_id
  subnet_ids        = data.terraform_remote_state.runtime.outputs.private_subnet_ids
  security_group_id = data.terraform_remote_state.runtime.outputs.sg_app_id

  image_uri        = "${local.ecr_base}/rova-api:${var.image_tag}"
  cpu              = 256
  memory           = 1024
  cpu_architecture = "ARM64"

  # Ingress: one field, mutually exclusive by construction.
  ingress = {
    mode                    = "tunnel"
    tunnel_token_secret_arn = module.secrets.secret_arns["tunnel-token"]
  }

  # Sidecars: opt in. The collector is dormant while otlp_endpoint is empty, so a product
  # can carry the wiring before the backend exists.
  otel = {
    enabled          = true
    otlp_endpoint    = var.observability.otlp_endpoint
    token_secret_arn = try(module.secrets.secret_arns["observability-token"], "")
  }
  firelens = { enabled = true }

  dns = {
    enabled = true
    zone_id = var.cloudflare_zone_id
    name    = "rova-api"
    content = module.tunnel.cname
  }

  secret_arns        = values(module.secrets.secret_arns)
  kms_key_arn        = local.kms_key_arn
  log_retention_days = 90

  tags = local.tags
}
```

A worker is the same call with `ingress = { mode = "none" }`, `dns` omitted, and
`health_check_command` set — because a worker with neither an ALB nor a tunnel has nothing
else checking it, and ECS reports a wedged process as running indefinitely.

## Key inputs

| Name | Default | Notes |
| :--- | :------ | :---- |
| `ingress.mode` | `none` | `none` / `tunnel` / `alb`. Validated; `tunnel` requires a token ARN, `alb` requires a listener ARN |
| `otel.enabled` | `false` | Dormant when `otlp_endpoint` is empty — costs nothing |
| `firelens.enabled` | `false` | S3 grants routed to the task role automatically |
| `dns.enabled` | `false` | Cloudflare rejects CREATE for an existing name; adopting needs `allow_overwrite` or an import |
| `cpu_architecture` | `ARM64` | Must move together with the CI build platform, or tasks fail at start with a manifest-platform error |
| `health_check_command` | `null` | `null` is a real gap for a worker, not a neutral default |
| `use_spot` | `false` | Suitable where interruption is a retry, not for a request-serving api |

See `variables.tf` for the full list.

## Outputs

`service_name`, `service_arn`, `task_role_arn`, `execution_role_arn`,
`task_definition_arn`, `log_group_name`, `target_group_arn` (null unless
`ingress.mode = "alb"`), `tunnel_origin_url`, `ingress_mode`, `otel_enabled`.

## Migration

**Adoption renames resources in state.** Moving `module.api` to
`module.api.module.service` is a rename, and without `moved` blocks Terraform reads it as
destroy-and-create — of ECS services, and potentially the database beside them.

The gate is evidence, not review: `tofu plan` must report **no changes**, not "only safe
changes". Any non-empty plan means an address was missed.

Note also that `infra/modules/stack` is shared by **both** environments of a product, so
every adoption touches at least one stateful environment. There is no risk-free first target.

The address map, the sequencing, and the ordering constraints live in
`qnsc-infra/docs/product-service-extraction.md`.
