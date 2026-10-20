locals {
  # ALB CloudWatch dimension is the arn suffix: app/<name>/<id>
  alb_suffix = var.alb_arn != "" ? replace(var.alb_arn, "/^.*:loadbalancer\\//", "") : ""
  # Empty while the environment is deliberately idle, which switches off every alarm
  # whose premise is "this environment is serving traffic". See var.environment_idle.
  ecs_services = var.environment_idle ? toset([]) : toset(var.ecs_service_names)

  # Percentage of allocated storage wins over the absolute floor when set. The result is a
  # threshold fixed at apply time: if storage autoscaling grows the volume, bump
  # rds_allocated_storage_gb to match or the alarm keeps the old allocation's floor.
  rds_free_storage_threshold_bytes = var.thresholds.rds_free_storage_pct > 0 ? var.thresholds.rds_free_storage_pct / 100 * var.rds_allocated_storage_gb * 1073741824 : var.thresholds.rds_free_bytes

  # TargetGroup CloudWatch dimension is likewise the arn suffix: targetgroup/<name>/<id>.
  # Derived once because both per-target-group alarms below need it.
  tg_dimensions = {
    for name, arn in var.target_group_arns :
    name => replace(arn, "/^.*:(targetgroup\\/.*)$/", "$1")
  }
}

# ── Alarm topic ──────────────────────────────────────────────────────────────
resource "aws_sns_topic" "alarms" {
  name = "${var.name}-alarms"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alarm_emails)
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

# ── ECS alarms (per service) ─────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  for_each            = local.ecs_services
  alarm_name          = "${var.name}-${each.value}-cpu-high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = var.ecs_cluster_name, ServiceName = each.value }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.thresholds.ecs_cpu_pct
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  # No ok_actions, matching ecs_mem below. CPU recovering is not news, and on a service
  # that scales to zero the metric DISAPPEARS — so the alarm walks
  # OK -> INSUFFICIENT_DATA -> OK on every sleep/wake cycle and mailed a
  # "<service>-cpu-high" OK notification each time. Recipients read the name, not the
  # transition, so a routine wake looked like a CPU incident.
  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_mem" {
  for_each            = local.ecs_services
  alarm_name          = "${var.name}-${each.value}-mem-high"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = { ClusterName = var.ecs_cluster_name, ServiceName = each.value }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.thresholds.ecs_mem_pct
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

# ── ALB alarms ───────────────────────────────────────────────────────────────
# NOT created while the environment is idle. `HTTPCode_ELB_5XX_Count` counts 5xx the
# LOAD BALANCER generated, and an idled environment has no registered targets, so every
# request it receives becomes a 503 by design — a browser tab left open on an SSE
# endpoint reconnects hard enough to clear the threshold on its own, and inbound
# webhooks add more. The alarm then reports the intended state as an incident.
#
# Same reasoning as target_unhealthy below: an alarm whose premise is "this environment
# is serving traffic" cannot stay armed while the environment is deliberately not.
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  count               = var.alb_arn != "" && !var.environment_idle ? 1 : 0
  alarm_name          = "${var.name}-alb-5xx-high"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = local.alb_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.thresholds.alb_5xx_count
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

# Closes the one real gap in this set: every other alarm fires on a SYMPTOM of load
# (CPU, latency, 5xx), so a service whose tasks are simply not running looks quiet.
# UnHealthyHostCount is the direct signal, and it lives in AWS/ApplicationELB — free
# and native, so it needs no Container Insights, which nothing else here reads either.
#
# Scoped per TARGET GROUP, not per load balancer, because the ALB is shared across
# products: a LoadBalancer-only dimension would aggregate rally and opshub into one
# number and page the wrong team.
resource "aws_cloudwatch_metric_alarm" "target_unhealthy" {
  # Guarded on alb_arn like every other ALB alarm here. Without it, `local.alb_suffix`
  # is "" and the alarm is created with an empty LoadBalancer dimension — it matches no
  # metric and can never fire, which is worse than having no alarm because it looks like
  # coverage.
  # Gated on `monitor_target_health` as well as the target-group map, so a caller can
  # keep the per-target-group LATENCY alarm below while opting out of this one. They
  # used to share one switch, which forced an environment where zero tasks is normal
  # to give up latency monitoring too.
  for_each = var.alb_arn != "" && var.monitor_target_health && !var.environment_idle ? var.target_group_arns : {}

  alarm_name  = "${var.name}-${each.key}-targets-unhealthy"
  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  dimensions = {
    LoadBalancer = local.alb_suffix
    TargetGroup  = local.tg_dimensions[each.key]
  }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.thresholds.unhealthy_hosts
  comparison_operator = "GreaterThanThreshold"
  # Missing data is NOT healthy here: a target group with no registered targets
  # publishes nothing at all, which is exactly the outage this exists to catch.
  #
  # That makes the alarm wrong for any environment where zero tasks is a NORMAL state —
  # an off-hours cost-saver that scales services to 0 would hold it permanently in ALARM.
  # Wire `target_group_arns` only for environments expected to be always-on.
  treat_missing_data = "breaching"
  alarm_actions      = [aws_sns_topic.alarms.arn]
  ok_actions         = [aws_sns_topic.alarms.arn]
  tags               = var.tags
}

# Healthy-host floor, per TARGET GROUP: fires when fewer tasks are registered and healthy
# behind the ALB than the service's desired count. This is the ECS "running < desired"
# signal, read from the ALB's own HealthyHostCount, so it needs no Container Insights.
#
# Blind spot: a task that never registers with the target group (crash before its first
# health check, stuck in PROVISIONING) is never counted in HealthyHostCount, so this alarm
# cannot see it. Only tasks that were registered and then lost show as a shortfall.
# Desired counts are static inputs: when a service is scaled, update
# target_group_min_healthy in the same change.
resource "aws_cloudwatch_metric_alarm" "healthy_hosts_below_desired" {
  # Same guards as target_unhealthy: needs the ALB dimension, and an environment that is
  # serving. An idle environment has zero tasks by design.
  for_each = var.alb_arn != "" && !var.environment_idle ? var.target_group_min_healthy : {}

  alarm_name  = "${var.name}-${each.key}-healthy-hosts-below-desired"
  namespace   = "AWS/ApplicationELB"
  metric_name = "HealthyHostCount"
  dimensions = {
    LoadBalancer = local.alb_suffix
    TargetGroup  = local.tg_dimensions[each.key]
  }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  threshold           = each.value
  comparison_operator = "LessThanThreshold"
  # A target group with no registered targets publishes no datapoint: that is the outage
  # this alarm exists to catch, so missing data is breaching, as in target_unhealthy.
  treat_missing_data = "breaching"
  alarm_actions      = [aws_sns_topic.alarms.arn]
  ok_actions         = [aws_sns_topic.alarms.arn]
  tags               = var.tags
}

# Latency, per TARGET GROUP and gated on traffic volume.
#
# Two defects in the previous LoadBalancer-scoped p95 alarm, both of which paged for
# things nobody could act on:
#
#  1. The ALB is SHARED across products, so a LoadBalancer-only dimension aggregated
#     rally and opshub into one p95 and named the result after whichever product's
#     stack created it. `target_unhealthy` above already scopes per target group for
#     exactly this reason; latency now matches.
#
#  2. A percentile over a handful of samples is not a percentile. On a pre-launch or
#     low-traffic environment (measured: 0-6 requests per 5-minute period) p95 IS
#     effectively the second-slowest single request, so ONE slow request held the
#     alarm over the threshold for three consecutive periods and paged. That is noise
#     that trains people to ignore the alarm, which is worse than no alarm.
#
# The metric-math expression suppresses the evaluation below `alb_latency_min_requests`
# requests per period by returning 0 — chosen over a composite alarm because it stays
# one resource with one history to read, and over raising the threshold because a high
# threshold hides a real regression under load instead of ignoring an idle environment.
# Missing RequestCount (a target group serving nothing publishes no datapoint) combines
# with `notBreaching` below, so silence still reads as OK rather than as a breach.
resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  for_each = var.alb_arn != "" ? var.target_group_arns : {}

  alarm_name          = "${var.name}-${each.key}-alb-latency-high"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.thresholds.alb_latency_sec
  evaluation_periods  = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  alarm_description = join(" ", [
    "p95 target response time above ${var.thresholds.alb_latency_sec}s for 15 minutes,",
    "evaluated only in periods with at least ${var.thresholds.alb_latency_min_requests} requests.",
  ])
  tags = var.tags

  metric_query {
    id          = "gated_latency"
    expression  = "IF(requests >= ${var.thresholds.alb_latency_min_requests}, latency, 0)"
    label       = "p95 latency (periods with >= ${var.thresholds.alb_latency_min_requests} requests)"
    return_data = true
  }

  metric_query {
    id = "latency"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "TargetResponseTime"
      dimensions = {
        LoadBalancer = local.alb_suffix
        TargetGroup  = local.tg_dimensions[each.key]
      }
      period = 300
      stat   = "p95"
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions = {
        LoadBalancer = local.alb_suffix
        TargetGroup  = local.tg_dimensions[each.key]
      }
      period = 300
      stat   = "Sum"
    }
  }
}

# ── RDS alarms ───────────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count               = var.rds_instance_id != "" ? 1 : 0
  alarm_name          = "${var.name}-rds-cpu-high"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.rds_instance_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.thresholds.rds_cpu_pct
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  count               = var.rds_instance_id != "" ? 1 : 0
  alarm_name          = "${var.name}-rds-free-storage-low"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.rds_instance_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = local.rds_free_storage_threshold_bytes
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = var.thresholds.rds_free_storage_pct >= 0 && var.thresholds.rds_free_storage_pct <= 100
      error_message = "thresholds.rds_free_storage_pct must be between 0 and 100."
    }
    precondition {
      condition     = var.thresholds.rds_free_storage_pct == 0 || var.rds_allocated_storage_gb > 0
      error_message = "thresholds.rds_free_storage_pct needs rds_allocated_storage_gb: the percentage is of allocated storage, which CloudWatch does not publish."
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  count               = var.rds_instance_id != "" ? 1 : 0
  alarm_name          = "${var.name}-rds-connections-high"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = var.rds_instance_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.thresholds.rds_connections
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

# ── Burstable-instance RDS alarms (opt-in) ───────────────────────────────────
# Both are gated on their threshold being > 0 as well as on rds_instance_id, so a
# caller that has not sized a floor gets no alarm — see the two keys' comments in
# variables.tf for why these default off while every other threshold defaults on.
#
# They exist because a burstable instance does not fail, it DEGRADES, and the three
# alarms above cannot see that. A prod p99-latency page on rally's db.t4g.micro is
# what found this: the runbook in the product's live/main.tf named CPUCreditBalance
# and FreeableMemory as the first signals to check, but neither had an alarm, so the
# only thing that fired was the downstream symptom hours after the cause.
#
# Conventions follow the rds_* siblings exactly: AWS/RDS, DBInstanceIdentifier taken
# from var.rds_instance_id (the module's existing, validated handle — no new input),
# Average over a 300s period, alarm_actions only, var.tags. `treat_missing_data` is
# left at the provider default for the same reason the siblings leave it: a stopped
# or non-burstable instance publishes nothing, and reading that as INSUFFICIENT_DATA
# rather than as a breach is the behaviour var.environment_idle already documents.
resource "aws_cloudwatch_metric_alarm" "rds_cpu_credit" {
  count       = var.rds_instance_id != "" && var.thresholds.rds_cpu_credit_min > 0 ? 1 : 0
  alarm_name  = "${var.name}-rds-cpu-credit-low"
  namespace   = "AWS/RDS"
  metric_name = "CPUCreditBalance"
  dimensions  = { DBInstanceIdentifier = var.rds_instance_id }
  statistic   = "Average"
  period      = 300
  # 1, matching rds_storage rather than the 3 used by rds_cpu/rds_connections. The
  # two utilization alarms need 3 periods to ride out spikes; a credit balance is a
  # slow-draining accumulator that cannot spike, so a second confirmation period only
  # spends credits the operator was being warned about.
  evaluation_periods  = 1
  threshold           = var.thresholds.rds_cpu_credit_min
  comparison_operator = "LessThanThreshold"
  alarm_description = join(" ", [
    "CPUCreditBalance on ${var.rds_instance_id} has fallen below ${var.thresholds.rds_cpu_credit_min} credits,",
    "meaning the instance has been running above its CPU baseline for long enough to spend",
    "most of its accumulated burst allowance. A burstable (db.t*) class earns credits only",
    "while below baseline and spends them to exceed it; once the balance is gone the",
    "instance is held at baseline or billed for surplus, depending on its burst mode.",
    "This needs its own alarm because exhaustion does not look like a failure: a throttled",
    "instance sits pinned at its baseline percentage, so CPUUtilization reads as healthy",
    "while every query gets slower, and the breach surfaces downstream as application p99",
    "latency instead. Treat a falling balance as sustained load above baseline — shed the",
    "load, or move off the burstable class before the balance reaches zero.",
  ])
  alarm_actions = [aws_sns_topic.alarms.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_freeable_memory" {
  count       = var.rds_instance_id != "" && var.thresholds.rds_freeable_memory_mb > 0 ? 1 : 0
  alarm_name  = "${var.name}-rds-freeable-memory-low"
  namespace   = "AWS/RDS"
  metric_name = "FreeableMemory"
  dimensions  = { DBInstanceIdentifier = var.rds_instance_id }
  statistic   = "Average"
  period      = 300
  # 1, matching rds_storage and cache_free_memory — the other two floor alarms here.
  # A memory floor that has already been crossed is not made truer by waiting.
  evaluation_periods = 1
  # MB -> bytes. The metric is published in bytes; the variable is in megabytes so the
  # call site reads as an operator sizing decision rather than a nine-digit constant.
  # Kept as an inline expression rather than a local because it is used exactly once,
  # and the multiplication next to the threshold is what makes the unit mismatch
  # between variable and metric visible to a reviewer.
  threshold           = var.thresholds.rds_freeable_memory_mb * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  alarm_description = join(" ", [
    "FreeableMemory on ${var.rds_instance_id} has fallen below",
    "${var.thresholds.rds_freeable_memory_mb} MB. On a burstable instance this is how the",
    "working set outgrowing RAM presents itself: PostgreSQL loses its filesystem cache",
    "first, so reads that were served from memory start hitting EBS and the database gets",
    "steadily slower without returning a single error. If it keeps falling, the host runs",
    "out of memory and the engine is restarted, which costs a failover-length outage.",
    "It is alarmed separately from CPU and connections because neither of those moves",
    "while this one does — the degradation is latency, not utilization and not an error",
    "rate. Check for a query plan that started sorting on disk, a connection count that",
    "outgrew the instance's per-connection work_mem, or a table that no longer fits.",
  ])
  alarm_actions = [aws_sns_topic.alarms.arn]
  tags          = var.tags
}

# ── Cache (ElastiCache/Valkey) alarms ────────────────────────────────────────
# Node mode only — see cache_cluster_id's own description for why a shared node is
# never wired here, and the cache module's cluster_id output for why serverless is
# out of scope (different metric set entirely).
resource "aws_cloudwatch_metric_alarm" "cache_cpu" {
  count               = var.enable_cache_alarms ? 1 : 0
  alarm_name          = "${var.name}-cache-cpu-high"
  namespace           = "AWS/ElastiCache"
  metric_name         = "EngineCPUUtilization"
  dimensions          = { CacheClusterId = var.cache_cluster_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.thresholds.cache_cpu_pct
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "cache_free_memory" {
  count               = var.enable_cache_alarms ? 1 : 0
  alarm_name          = "${var.name}-cache-free-memory-low"
  namespace           = "AWS/ElastiCache"
  metric_name         = "FreeableMemory"
  dimensions          = { CacheClusterId = var.cache_cluster_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.thresholds.cache_free_bytes
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

# Evictions is the direct signal that the working set no longer fits — auth token
# denylist entries and rate-limiter counters silently getting evicted early is a
# security-relevant failure mode (see libs/platform's fail-open notes), not just a
# performance one, so this fires on ANY eviction rather than a tuned threshold.
resource "aws_cloudwatch_metric_alarm" "cache_evictions" {
  count               = var.enable_cache_alarms ? 1 : 0
  alarm_name          = "${var.name}-cache-evictions"
  namespace           = "AWS/ElastiCache"
  metric_name         = "Evictions"
  dimensions          = { CacheClusterId = var.cache_cluster_id }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.thresholds.cache_evictions
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

# ── Dashboard ────────────────────────────────────────────────────────────────
# Optional, unlike the alarms above. CloudWatch gives 3 dashboards free per ACCOUNT
# and then charges $3/mo each, so a dashboard per environment per product starts
# billing at the fourth one — and an environment nobody watches is the wrong one to
# pay for. The alarms are what page someone; this is what you open afterwards.
resource "aws_cloudwatch_dashboard" "this" {
  count          = var.create_dashboard ? 1 : 0
  dashboard_name = var.name
  dashboard_body = jsonencode({
    widgets = concat(
      [for i, svc in var.ecs_service_names : {
        type = "metric", x = (i * 12) % 24, y = 0, width = 12, height = 6
        properties = {
          title  = "ECS ${svc} — CPU/Mem %"
          region = var.region
          view   = "timeSeries"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", svc],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", svc],
          ]
        }
      }],
      var.alb_arn != "" ? [{
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "ALB — requests / 5xx / p95 latency"
          region = var.region
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.alb_suffix],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_suffix, { stat = "p95" }],
          ]
        }
      }] : [],
      var.rds_instance_id != "" ? [{
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "RDS — CPU / connections"
          region = var.region
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_instance_id],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_instance_id],
          ]
        }
      }] : [],
      # Burst headroom, on its own widget and gated on the same opt-in as the two
      # alarms above rather than folded into the RDS widget. Two reasons: a caller
      # that has not sized these floors must see a no-op plan on upgrade, and the
      # dashboard_body is part of the diff — and credits (hundreds) next to CPU
      # percent and a connection count would be a fourth series on an axis it does
      # not share, which is the same reason FreeableMemory gets the right axis here.
      var.rds_instance_id != "" && (var.thresholds.rds_cpu_credit_min > 0 || var.thresholds.rds_freeable_memory_mb > 0) ? [{
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "RDS burst — CPU credits / freeable memory"
          region = var.region
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "CPUCreditBalance", "DBInstanceIdentifier", var.rds_instance_id],
            ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", var.rds_instance_id, { yAxis = "right" }],
          ]
        }
      }] : [],
      var.cache_cluster_id != "" ? [{
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "Cache — CPU / free memory / evictions"
          region = var.region
          view   = "timeSeries"
          metrics = [
            ["AWS/ElastiCache", "EngineCPUUtilization", "CacheClusterId", var.cache_cluster_id],
            ["AWS/ElastiCache", "FreeableMemory", "CacheClusterId", var.cache_cluster_id],
            ["AWS/ElastiCache", "Evictions", "CacheClusterId", var.cache_cluster_id],
          ]
        }
      }] : [],
    )
  })
}
