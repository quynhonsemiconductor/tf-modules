# observability

SNS-backed CloudWatch alarms + a dashboard for the golden signals of an
ECS-on-ALB-with-RDS(-and-optionally-ElastiCache) service (ECS CPU/mem, ALB
5xx/latency, RDS CPU/free-storage/connections, cache CPU/free-memory/evictions),
plus opt-in burst-headroom alarms for burstable RDS classes.
Cheap (~$0.10/mo alarms, ~$3/mo dashboard) and additive — wire it from a product
stack with handles it already has.

## Usage

```hcl
module "observability" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/observability?ref=observability-v4.2.0"

  name              = "rova-prod"
  region            = var.aws_region
  ecs_cluster_name  = module.ecs_cluster.cluster_name
  ecs_service_names = [module.api.service_name, module.worker.service_name]
  alb_arn           = data.terraform_remote_state.runtime.outputs.alb_arn
  rds_instance_id   = module.rds.identifier
  # Node mode only, and never for a SHARED cache node — see cache_cluster_id's
  # own description in variables.tf. null/"" for serverless or a shared node.
  cache_cluster_id  = module.cache[0].cluster_id
  # Required for the two per-target-group alarms (latency, unhealthy hosts).
  target_group_arns = { api = module.api.target_group_arn }
  alarm_emails      = ["oncall@qnsc.vn"]
  tags              = local.tags
}
```

## Alarms

| Alarm | Scope | Notes |
| :---- | :---- | :---- |
| `<name>-<service>-cpu-high` / `-mem-high` | ECS service | Average over 2×5min. |
| `<name>-alb-5xx-high` | Load balancer | `HTTPCode_ELB_5XX_Count`. LB-wide on purpose — these are the ALB's own 5xx, not a target's. |
| `<name>-<tg>-alb-latency-high` | Target group | p95, **only evaluated in periods with ≥ `alb_latency_min_requests` requests**. |
| `<name>-<tg>-targets-unhealthy` | Target group | `treat_missing_data = "breaching"`. Disable via `monitor_target_health` where zero tasks is normal. |
| `<name>-rds-*` | RDS instance | CPU, free storage, connections. |
| `<name>-rds-cpu-credit-low` / `-freeable-memory-low` | RDS instance (burstable) | **Opt-in** — created only when `rds_cpu_credit_min` / `rds_freeable_memory_mb` is > 0. |
| `<name>-cache-*` | ElastiCache node | CPU, free memory, any eviction. Node mode only — see `cache_cluster_id`. |

Both target-group alarms are scoped by `TargetGroup`, not `LoadBalancer`, because the
ALB is **shared across products** — a load-balancer-wide dimension aggregates every
product into one number and pages the wrong team.

The latency gate exists because a percentile over a handful of samples is not a
percentile. A pre-launch environment serving 0-6 requests per 5-minute period has a p95
equal to its second-slowest single request, so one slow call pages on-call for something
nobody can act on. Below the floor the expression returns 0 instead of the measured
value; above it the alarm behaves normally.

### Burstable instances

A `db.t*` instance does not fail under sustained load, it **degrades**, and none of the
three standard RDS alarms can see that:

- **`CPUCreditBalance`** — a burstable class earns CPU credits while below its baseline
  and spends them to exceed it. When the balance empties, the instance is held at
  baseline (or billed for surplus, depending on burst mode). A throttled instance sits
  pinned at its baseline percentage, so **`CPUUtilization` reads as healthy** while every
  query slows down. The breach only surfaces downstream, as application p99 latency.
- **`FreeableMemory`** — the working set outgrowing RAM shows up as lost filesystem
  cache and reads falling through to EBS, then eventually as an engine restart. Again
  latency, not utilization and not an error rate.

Both are therefore alarmed separately, and both are **off by default** — a correct floor
depends on the instance class, not on the service, and a non-zero default would arm an
alarm against a metric that a non-burstable class never publishes (permanent
`INSUFFICIENT_DATA`, which looks like coverage). Set them per environment:

```hcl
thresholds = {
  # db.t4g.micro: earns 24 credits/hour, holds a 576-credit maximum. ~4 hours of
  # accumulated burst left is enough warning to act before throttling starts.
  rds_cpu_credit_min = 100
  # db.t4g.micro has 1 GiB. Under ~200 MB freeable, the filesystem cache is already
  # being given up. MEGABYTES — the alarm converts to bytes itself.
  rds_freeable_memory_mb = 200
}
```

Scale the credit floor with the class (a `db.t4g.medium` earns 96/hour, so its floor is
proportionally higher) and leave both at `0` on any `db.m*`/`db.r*` instance.

> **Breaking in v4.0.0:** `alb_latency` moved from one load-balancer-wide alarm
> (`<name>-alb-latency-high`, `count`) to one per target group
> (`<name>-<tg>-alb-latency-high`, `for_each`), and now requires `target_group_arns`.
> Callers that passed only `alb_arn` lose the latency alarm until they wire it.
> `monitor_target_health` no longer shares a switch with `target_group_arns`.

## Inputs

| Name | Type | Default | Description |
| :--- | :--- | :------ | :---------- |
| `name` | string | — | Prefix for alarm/dashboard names. |
| `region` | string | — | AWS region. |
| `ecs_cluster_name` | string | — | ECS cluster to alarm on. |
| `ecs_service_names` | list(string) | `[]` | Services to alarm on. |
| `alb_arn` | string | `""` | Full ALB ARN. Empty = skip ALB alarms. |
| `rds_instance_id` | string | `""` | RDS DBInstanceIdentifier. Empty = skip RDS alarms. |
| `cache_cluster_id` | string | `""` | ElastiCache `CacheClusterId` — the cache module's own `cluster_id` output (node mode only). Empty = skip cache alarms. Never wire this for a SHARED cache node. |
| `target_group_arns` | map(string) | `{}` | Service name => target group ARN. Required for the latency and unhealthy-host alarms. |
| `monitor_target_health` | bool | `true` | Create the unhealthy-host alarm. False where zero running tasks is normal. |
| `alarm_emails` | list(string) | `[]` | Emails subscribed to the alarm topic. |
| `thresholds` | object | see module | Per-signal alarm thresholds (all optional, sane defaults). Includes `alb_latency_min_requests` (default 50) and the two opt-in burstable keys below. |
| `thresholds.rds_cpu_credit_min` | number | `0` | `CPUCreditBalance` floor, in **credits**. `0` disables the alarm. See [Burstable instances](#burstable-instances). |
| `thresholds.rds_freeable_memory_mb` | number | `0` | `FreeableMemory` floor, in **megabytes** (the alarm converts to bytes; the AWS/RDS metric is in bytes). `0` disables the alarm. |
| `thresholds.rds_free_storage_pct` | number | `0` | Free-storage floor as a **percent of `rds_allocated_storage_gb`** (0–100). `0` uses `thresholds.rds_free_bytes`. Needs `rds_allocated_storage_gb`. The value is fixed at apply time: bump `rds_allocated_storage_gb` when autoscaling grows the volume. |
| `rds_allocated_storage_gb` | number | `0` | Allocated RDS storage in GiB. Read only when `thresholds.rds_free_storage_pct` > 0. |
| `create_dashboard` | bool | `true` | Create the dashboard. Alarms are created regardless. |
| `tags` | map(string) | `{}` | Resource tags. |

## Outputs

| Name | Description |
| :--- | :---------- |
| `alarm_topic_arn` | SNS topic all alarms publish to — subscribe PagerDuty/Slack/email. |
| `dashboard_name` | CloudWatch dashboard name. |
