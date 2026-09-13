# =============================================================================
# product-service — one ECS service plus the sidecars and ingress that always
# accompany it.
#
# WHY THIS EXISTS. Each product repo carries its own `infra/modules/stack` composition
# module — rova 3,233 lines, opshub 2,567, qnsc-kb 1,104 — implementing one pattern three
# times. Measured 2026-09-12: the `module "api"` call passes 31 of 34 arguments identically
# across all three, so the compositions have not diverged in substance, only in coverage.
#
# COVERAGE IS THE EXPENSIVE PART. Improvements land in some copies and not others, and the
# cost is real rather than theoretical:
#
#   * `cache.shared` existed in rova and qnsc-kb, not opshub — so opshub-develop ran its own
#     ElastiCache node at ~$15/month for services pinned at min_count = 0. ElastiCache has no
#     stopped state, so that billed 730 h/month.
#   * The cache/min_count guard was a `validation` in two products and a `check` block in the
#     third, where a violated assert exits 0 — so the guard permitted what it described.
#   * The Valkey db_index registry was inline in all three, in three different states.
#
# WHAT THIS MODULE CENTRALISES. Not the ECS service itself — `ecs-service` already does that.
# The value is the WIRING BETWEEN the service and its sidecars, which is what each product
# hand-assembled and therefore drifted on:
#
#   1. `additional_containers` — the concat of every sidecar's container definitions. Forget
#      one and the sidecar silently does not run.
#   2. `secret_arns` — the concat of every sidecar's token ARNs onto the EXECUTION role.
#      Forget one and the task fails at start with ResourceInitializationError, which reads
#      as a platform fault rather than a missing IAM grant.
#   3. `task_s3_bucket_arns` from FireLens onto the TASK role.
#   4. ALB-versus-tunnel exclusivity. A task served by a tunnel must not also be an ALB
#      target; each product previously expressed that as `attach_alb = !module.tunnel.enabled`
#      written out per service. Here it is one `ingress.mode` field, and the impossible
#      combination is unrepresentable rather than merely discouraged.
#
# MIGRATION IS NOT A FLAG FLIP. Moving resources into this module renames them in state, so
# every adoption needs `moved` blocks and a `tofu plan` reporting NO changes — not "only safe
# changes". See qnsc-infra/docs/product-service-extraction.md for the address map and the
# sequencing, and note that `modules/stack` is shared by both environments of a product, so
# every adoption touches at least one stateful environment.
# =============================================================================

locals {
  name = "${var.product}-${var.env}-${var.service_name}"

  # One log group for the service and all of its sidecars, deliberately: a dropped request
  # and the connector or collector failure that caused it belong in one stream. The
  # ecs-service module creates it; the sidecars are pointed at the same name.
  log_group = "/ecs/${var.product}-${var.env}/${var.service_name}"

  tunnel_enabled = var.ingress.mode == "tunnel"
  alb_enabled    = var.ingress.mode == "alb"
}

# ── Sidecars ─────────────────────────────────────────────────────────────────
# Each returns `container_definitions` (possibly empty) and `secret_arns`, so the concat
# below is uniform and a disabled sidecar contributes nothing.

module "otel_agent" {
  count  = var.otel.enabled ? 1 : 0
  source = "../observability-agent"

  name             = "otel-collector"
  product          = var.product
  env              = var.env
  otlp_endpoint    = var.otel.otlp_endpoint
  token_secret_arn = var.otel.token_secret_arn
  log_group        = local.log_group
  region           = var.region

  cpu              = var.otel.cpu
  memory           = var.otel.memory
  memory_limit_mib = floor(var.otel.memory * 0.625)
}

module "firelens_agent" {
  count  = var.firelens.enabled ? 1 : 0
  source = "../firelens-agent"

  service_name     = var.service_name
  product          = var.product
  env              = var.env
  router_log_group = local.log_group
  region           = var.region
  kms_key_arn      = var.kms_key_arn
}

module "tunnel_agent" {
  count  = local.tunnel_enabled ? 1 : 0
  source = "../tunnel-agent"

  tunnel_token_secret_arn = var.ingress.tunnel_token_secret_arn
  app_port                = var.container_port
  log_group               = local.log_group
  region                  = var.region
}

# ── The service ──────────────────────────────────────────────────────────────

module "service" {
  source = "../ecs-service"

  service_name = var.service_name
  cluster_name = var.cluster_name
  cluster_arn  = var.cluster_arn
  region       = var.region
  image_uri    = var.image_uri

  cpu              = var.cpu
  memory           = var.memory
  cpu_architecture = var.cpu_architecture
  use_spot         = var.use_spot

  desired_count      = var.desired_count
  min_count          = var.min_count
  max_count          = var.max_count
  enable_autoscaling = var.enable_autoscaling
  cpu_target_pct     = var.cpu_target_pct
  memory_target_pct  = var.memory_target_pct

  vpc_id            = var.vpc_id
  subnet_ids        = var.subnet_ids
  security_group_id = var.security_group_id

  # A task served by a tunnel dials OUT and has no inbound listener, so it must not also be
  # registered as an ALB target — an unreachable target fails health checks forever and the
  # deployment circuit breaker rolls the release back. `ingress.mode` makes the two
  # mutually exclusive by construction.
  attach_alb        = local.alb_enabled
  alb_listener_arn  = var.ingress.alb_listener_arn
  alb_priority      = var.ingress.alb_priority
  alb_host_headers  = var.ingress.alb_host_headers
  alb_path_patterns = var.ingress.alb_path_patterns
  health_check_path = var.health_check_path

  container_port       = var.container_port
  health_check_command = var.health_check_command
  environment_vars     = var.environment_vars
  secrets              = var.secrets
  log_retention_days   = var.log_retention_days
  kms_key_arn          = var.kms_key_arn
  enable_ecs_exec      = var.enable_ecs_exec

  # (1) Every sidecar's container definition, in one place. A product cannot forget one,
  # because it never assembles this list.
  additional_containers = concat(
    length(module.otel_agent) > 0 ? module.otel_agent[0].container_definitions : [],
    length(module.firelens_agent) > 0 ? module.firelens_agent[0].container_definitions : [],
    length(module.tunnel_agent) > 0 ? module.tunnel_agent[0].container_definitions : [],
  )

  # (2) Every sidecar's token ARN onto the EXECUTION role. Omitting one produces
  # ResourceInitializationError at task start, which does not name IAM as the cause.
  secret_arns = concat(
    var.secret_arns,
    length(module.otel_agent) > 0 ? module.otel_agent[0].secret_arns : [],
    length(module.firelens_agent) > 0 ? module.firelens_agent[0].secret_arns : [],
    length(module.tunnel_agent) > 0 ? module.tunnel_agent[0].secret_arns : [],
  )

  task_secret_arns = var.task_secret_arns

  # (3) FireLens writes to S3, and that grant belongs to the TASK role rather than the
  # execution role.
  s3_bucket_arns = concat(
    var.s3_bucket_arns,
    length(module.firelens_agent) > 0 ? module.firelens_agent[0].task_s3_bucket_arns : [],
  )

  sqs_queue_arns = var.sqs_queue_arns
  sns_topic_arns = var.sns_topic_arns

  tags = merge(var.tags, { Service = var.service_name })
}

# ── Public DNS ───────────────────────────────────────────────────────────────

module "dns" {
  count  = var.dns.enabled ? 1 : 0
  source = "../dns-record"

  enabled         = true
  zone_id         = var.dns.zone_id
  name            = var.dns.name
  type            = var.dns.type
  content         = var.dns.content
  proxied         = var.dns.proxied
  comment         = var.dns.comment != "" ? var.dns.comment : "${local.name} — managed by product-service"
  allow_overwrite = var.dns.allow_overwrite
}
