# observability — SNS-backed CloudWatch alarms + a dashboard for the golden
# signals of an ECS-on-ALB-with-RDS service. Cheap (alarms ~$0.10/mo, dashboard
# ~$3/mo) and additive. Wire from product-stack with the handles it already has.

variable "name" { type = string }

variable "alarm_emails" {
  type        = list(string)
  default     = []
  description = "Emails subscribed to the alarm SNS topic. Empty = topic only (wire subscribers later)."
}

variable "region" { type = string }

variable "ecs_cluster_name" { type = string }
variable "ecs_service_names" {
  type    = list(string)
  default = []
}

variable "alb_arn" {
  type        = string
  default     = ""
  description = "Full ALB ARN; the CloudWatch LoadBalancer dimension is derived from it. Empty = skip ALB alarms."
}

variable "rds_instance_id" {
  type        = string
  default     = ""
  description = <<-EOT
    DB instance IDENTIFIER (e.g. `rova-prod`) — the value RDS publishes as the
    CloudWatch `DBInstanceIdentifier` dimension. Empty skips the RDS alarms.

    NOT the resource id. `aws_db_instance.id` returns `db-XXXX…` on AWS provider 5.x,
    and passing that produced six alarms permanently in INSUFFICIENT_DATA — matching no
    metric while looking like coverage. Use the rds module's `identifier` output.
  EOT

  validation {
    # An RDS resource id is `db-` followed by 26 uppercase alphanumerics. No real
    # identifier looks like that (they are lowercase, and cannot contain consecutive
    # hyphens), so this catches the exact mistake without rejecting anything valid.
    condition     = !can(regex("^db-[A-Z0-9]{26}$", var.rds_instance_id))
    error_message = "rds_instance_id looks like an RDS RESOURCE id (db-XXXX…), not an identifier. Pass the rds module's `identifier` output — the resource id matches no CloudWatch dimension."
  }
}

variable "thresholds" {
  type = object({
    ecs_cpu_pct     = optional(number, 85)
    ecs_mem_pct     = optional(number, 85)
    alb_5xx_count   = optional(number, 20)
    alb_latency_sec = optional(number, 2)
    # Traffic floor below which the latency alarm does not evaluate. A p95 over a
    # handful of requests is the second-slowest request, not a percentile, so a
    # single slow call would otherwise page an idle environment. 50 requests per
    # 5-minute period is ~1 rps sustained: low enough that any environment under
    # real use is covered, high enough that noise cannot reach the threshold.
    alb_latency_min_requests = optional(number, 50)
    rds_cpu_pct              = optional(number, 85)
    rds_free_bytes           = optional(number, 2147483648) # 2 GiB
    rds_connections          = optional(number, 100)
    # ── Burstable-instance signals, both OPT-IN (0 = do not create the alarm) ──
    #
    # Deliberately defaulted OFF rather than given a working threshold, which is the
    # opposite of every other key here. Two reasons:
    #
    #  1. A correct floor is a function of the INSTANCE CLASS, not of the service. A
    #     db.t4g.micro earns 24 CPU credits/hour and holds a 576-credit maximum; a
    #     db.t4g.medium earns 96/hour. A db.m6g has no credit metric at all, so any
    #     non-zero default would arm an alarm against a metric that is never published
    #     and park it in INSUFFICIENT_DATA — the same "looks like coverage, matches no
    #     metric" failure that rds_instance_id's validation exists to prevent.
    #  2. Every product already consuming this module (ceo-suite, solodesk,
    #     qnsc-kb-backend, opshub) must upgrade with a no-op plan. An additive default
    #     would create alarms in four stacks that nobody sized, reviewed, or expects.
    #
    # So the caller who runs burstable states its own floor, and everyone else is
    # untouched. Sizing guidance lives in the README.
    rds_cpu_credit_min = optional(number, 0)
    # MEGABYTES, not bytes — unlike rds_free_bytes/cache_free_bytes above. The
    # operator-facing number for a 1 GiB instance is "alert me under 200 MB", and
    # writing that as 209715200 in a live/main.tf is where an order-of-magnitude typo
    # goes unnoticed in review. The alarm multiplies up to bytes itself because the
    # AWS/RDS FreeableMemory metric is published in bytes; the unit lives in the
    # variable NAME so the conversion cannot be forgotten at the call site.
    rds_freeable_memory_mb = optional(number, 0)
    unhealthy_hosts        = optional(number, 0) # any unhealthy target is worth knowing about
    cache_cpu_pct          = optional(number, 85)
    cache_free_bytes       = optional(number, 52428800) # 50 MiB — cache.t4g.micro has ~500MB usable
    cache_evictions        = optional(number, 0)        # any eviction means the working set no longer fits
  })
  default = {}
}

variable "cache_cluster_id" {
  type        = string
  default     = ""
  description = <<-EOT
    ElastiCache CloudWatch `CacheClusterId` dimension — the cache module's own
    `cluster_id` output (node mode only). Used only as an alarm DIMENSION value;
    see `enable_cache_alarms` for whether the alarms are created at all.

    Deliberately NOT wired for a SHARED cache node (rally develop, infra
    live/runtime-dev's module.shared_cache): the node serves more than one product,
    so an alarm named after just one of them would misattribute exactly like the
    ALB-wide latency alarm did before it was scoped per target group (see
    alb_latency above). A shared node's alarms belong where the node is created,
    not in a single tenant's stack.
  EOT
}

variable "enable_cache_alarms" {
  type        = bool
  default     = false
  description = <<-EOT
    Whether to create the three cache alarms (cache_cpu/cache_free_memory/
    cache_evictions). A SEPARATE bool from cache_cluster_id being non-empty,
    deliberately: on an environment's first-ever apply the cache module's
    cluster_id output is unknown until apply (the node doesn't exist yet), and
    a `count` meta-argument that depends on that unknown value is a hard
    OpenTofu error ("Invalid count argument"), not a deferred plan. This flag
    must come from something known at PLAN time — e.g. the caller's own
    `var.cache.enabled && var.cache.mode == "node"` — while cache_cluster_id
    itself (possibly unknown-until-apply) stays a plain resource argument,
    which Terraform allows.
  EOT
}

variable "target_group_arns" {
  type        = map(string)
  default     = {}
  description = <<-EOT
    Service name => ALB target group ARN. Drives BOTH per-target-group alarms: response
    latency and UnHealthyHostCount. Pass the `target_group_arn` output of each
    ecs-service that attaches to the ALB.

    Empty creates neither. The ALB is shared across products, so a load-balancer-wide
    dimension would aggregate every product into one number and page the wrong team —
    which is why latency is scoped here rather than by `alb_arn` alone.
  EOT
}

variable "monitor_target_health" {
  type        = bool
  default     = true
  description = <<-EOT
    Create the per-target-group UnHealthyHostCount alarm.

    It uses `treat_missing_data = "breaching"` because a target group with no registered
    targets publishes no datapoint at all, which is the outage it exists to catch. That
    makes it wrong wherever zero running tasks is a NORMAL state — an off-hours
    cost-saver that scales services to 0 would hold it permanently in ALARM.

    Set false there. The latency alarm is unaffected: it is gated on request volume, so
    an environment scaled to zero simply never evaluates it.
  EOT
}

variable "create_dashboard" {
  type        = bool
  default     = true
  description = <<-EOT
    Create the CloudWatch dashboard. Alarms are created regardless.

    CloudWatch bills dashboards per ACCOUNT: three are free, every one after that is
    $3/mo. One dashboard per environment per product crosses that line at the fourth,
    so turn this off for environments nobody actively watches. Defaults to true so
    existing callers keep their dashboard on upgrade.
  EOT
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "environment_idle" {
  type        = bool
  default     = false
  description = <<-EOT
    This environment is deliberately not serving traffic — scaled to zero, database
    stopped, pre-launch or off-hours.

    Suppresses every alarm whose premise is "this environment is serving traffic":
    ECS CPU and memory, ALB 5xx, and unhealthy hosts. The RDS and latency alarms need no
    special case — a stopped instance publishes nothing and reads as INSUFFICIENT_DATA,
    and the latency alarm is already gated on request volume.

    Why it exists: idling an environment turned its own alarms into a pager. With no
    registered targets every request becomes a 503, so `HTTPCode_ELB_5XX_Count` clears
    its threshold from a single browser tab reconnecting to an SSE endpoint. And a
    service that scales to zero makes its CPU metric disappear, so a CPU alarm walks
    OK -> INSUFFICIENT_DATA -> OK on every wake.

    Set it back to false in the same change that restores capacity. An idle environment
    with armed load alarms is noise; a LIVE environment without them is blind.
  EOT
}
