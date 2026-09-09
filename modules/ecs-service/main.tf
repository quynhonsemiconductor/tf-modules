locals {
  full_name = "${var.cluster_name}-${var.service_name}"
}

# ── Log group ─────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.full_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ── IAM: task execution role ──────────────────────────────────────────────────
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.full_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.secret_arns) + length(var.ssm_parameter_arns) > 0 ? 1 : 0

  # Two services, two actions. ECS reads Secrets Manager and SSM Parameter Store the
  # same way in `secrets[].valueFrom`, but they are different APIs, so a parameter ARN
  # listed under `secret_arns` would be granted an action that does not apply to it.
  dynamic "statement" {
    for_each = length(var.secret_arns) > 0 ? [1] : []
    content {
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.secret_arns
    }
  }
  dynamic "statement" {
    for_each = length(var.ssm_parameter_arns) > 0 ? [1] : []
    content {
      actions   = ["ssm:GetParameters"]
      resources = var.ssm_parameter_arns
    }
  }
  # Decrypt KMS-encrypted secrets when a CMK is provided.
  dynamic "statement" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count  = length(var.secret_arns) + length(var.ssm_parameter_arns) > 0 ? 1 : 0
  name   = "secrets-access"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

# FireLens' external custom-config path (`config-file-type = "s3"`) is read by
# the AGENT before the task's own containers start, which is why this is on the
# EXECUTION role, not the task role below. `s3_bucket_arns` (task role) cannot
# be reused here: granting the task's own runtime code read access to a config
# bucket it has no reason to touch would be a second, wider grant for the same
# object.
data "aws_iam_policy_document" "execution_s3" {
  count = length(var.execution_s3_bucket_arns) > 0 ? 1 : 0
  statement {
    actions   = ["s3:GetObject"]
    resources = [for arn in var.execution_s3_bucket_arns : "${arn}/*"]
  }
}

resource "aws_iam_role_policy" "execution_s3" {
  count  = length(var.execution_s3_bucket_arns) > 0 ? 1 : 0
  name   = "execution-s3-access"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_s3[0].json
}

# ── IAM: task role (runtime AWS access) ───────────────────────────────────────
resource "aws_iam_role" "task" {
  name               = "${local.full_name}-task"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "task_messaging" {
  count = length(var.sqs_queue_arns) + length(var.sns_topic_arns) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = length(var.sqs_queue_arns) > 0 ? [1] : []
    content {
      actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
      resources = var.sqs_queue_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.sns_topic_arns) > 0 ? [1] : []
    content {
      actions   = ["sns:Publish"]
      resources = var.sns_topic_arns
    }
  }
}

resource "aws_iam_role_policy" "task_messaging" {
  count  = length(var.sqs_queue_arns) + length(var.sns_topic_arns) > 0 ? 1 : 0
  name   = "messaging-access"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_messaging[0].json
}

data "aws_iam_policy_document" "task_s3" {
  count = length(var.s3_bucket_arns) > 0 ? 1 : 0
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for arn in var.s3_bucket_arns : "${arn}/*"]
  }
  statement {
    # GetBucketLocation is required by any S3 SDK client that resolves the
    # bucket's region before its first request — confirmed live, not a
    # guess: aws-for-fluent-bit's init process (firelens-agent) failed with
    # exactly this action denied, fatal, and took its whole task down with
    # it (essential=true). ListBucket alone is not a substitute.
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = var.s3_bucket_arns
  }
  # A KMS-encrypted bucket needs kms:Decrypt on top of s3:GetObject, or the read
  # fails identically fatally — confirmed live: firelens-agent's own S3 config
  # fetch (task_s3_bucket_arns, this variable) against app-bucket's org-standard
  # KMS-at-rest bucket failed with AccessDenied on kms:Decrypt, not s3:GetObject,
  # because this policy granted only the latter. This was previously covered only
  # as a SIDE EFFECT of also passing `task_secret_arns` (whose own policy document
  # separately grants kms:Decrypt on the same CMK) — callers that pass
  # `s3_bucket_arns` + `kms_key_arn` but no `task_secret_arns` got no such grant at
  # all. Gated on `kms_key_arn` alone, independent of every other reason the task
  # role might need KMS.
  dynamic "statement" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "task_s3" {
  count  = length(var.s3_bucket_arns) > 0 ? 1 : 0
  name   = "s3-access"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_s3[0].json
}

# Runtime secret reads by the task role (e.g. an app resolving per-connection
# credentials on demand). Scoped to the given ARNs + kms:Decrypt on the CMK.
# Separate from the execution-role boot-time injection above.
data "aws_iam_policy_document" "task_secrets" {
  count = length(var.task_secret_arns) + length(var.task_ssm_parameter_arns) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = length(var.task_secret_arns) > 0 ? [1] : []
    content {
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.task_secret_arns
    }
  }
  dynamic "statement" {
    for_each = length(var.task_ssm_parameter_arns) > 0 ? [1] : []
    content {
      actions   = ["ssm:GetParameter", "ssm:GetParameters"]
      resources = var.task_ssm_parameter_arns
    }
  }
  dynamic "statement" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "task_secrets" {
  count  = length(var.task_secret_arns) + length(var.task_ssm_parameter_arns) > 0 ? 1 : 0
  name   = "task-secrets-access"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_secrets[0].json
}

# ── Task definition ───────────────────────────────────────────────────────────
# ── The baseline task definition ─────────────────────────────────────────────
# EXPECT THIS TO SHOW "must be replaced" ON EVERY PLAN OF A DEPLOYED ENVIRONMENT. It is
# not drift and it is not a bug, and it is written here because the plan output looks
# alarming and somebody will eventually stop a release over it.
#
# Two things register revisions of this family:
#   Terraform  owns the BASELINE — image, environment, secrets, sizing, architecture.
#   The deploy  (ci backend-deploy) registers a new revision per release and points
#              the service at it with `ecs update-service`.
#
# So the sequence is: Terraform writes revision N, a deploy writes N+1, and Terraform's
# next plan sees its own resource no longer matching the live family and wants N+2. That
# is why a healthy production stack plans as `3 to add, 0 to change, 3 to destroy` — one
# add and one destroy per service, api plus worker plus migrator — while nothing is wrong.
#
# Measured on rally production 2026-08-18, hours after a successful go-live with the api
# serving 200s: exactly that plan, and an identical plan from a clean checkout of main,
# which is how it was confirmed to be pre-existing rather than caused by the change under
# review.
#
# IT IS HARMLESS BECAUSE OF `ignore_changes = [task_definition]` on the service below: a
# `tofu apply` registers its new revision and the SERVICE keeps running the one the deploy
# chose. Applying does not roll production back.
#
# WHAT WOULD BE WRONG, and what to actually look for in that plan: a task definition being
# replaced is routine, but the ECS SERVICE, the cluster, the RDS instance, the cache or any
# secret appearing in a destroy is not. Read the resource names, not the counts.
#
# The alternative — `ignore_changes` on the task definition's own attributes — was not
# taken: it would silence real drift in image, secrets and sizing, which is the part
# Terraform exists to own here.
resource "aws_ecs_task_definition" "this" {
  family                   = local.full_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # Stated explicitly rather than left to Fargate's X86_64 default, so the
  # architecture the image was built for is visible in the task definition and a
  # mismatch shows up in a plan instead of at container start.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode(concat([
    {
      name      = var.service_name
      image     = var.image_uri
      essential = true
      portMappings = var.attach_alb ? [
        { containerPort = var.container_port, protocol = "tcp" }
      ] : []
      environment = var.environment_vars
      secrets = [
        for s in var.secrets : { name = s.name, valueFrom = s.secret_arn }
      ]
      # `awsfirelens` when a firelens-agent router sits in `additional_containers`:
      # ECS allows exactly one log driver per container, so routing to a second
      # destination (Grafana, via that router's own dual-write config) means
      # THIS container stops talking to awslogs directly — see firelens-agent's
      # README for why that is not a loss (the router's config still writes
      # CloudWatch itself). `aws_cloudwatch_log_group.this` is still created
      # either way: FireLens' `cloudwatch_logs` output plugin needs somewhere
      # to write, and it is the same group this container used to log to
      # directly, so existing queries and retention are unaffected.
      logConfiguration = var.use_firelens ? {
        logDriver = "awsfirelens"
        options   = {}
        } : {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = var.service_name
        }
      }
      healthCheck = var.health_check_command != null ? {
        command     = ["CMD-SHELL", var.health_check_command]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      } : null
    }
  ], var.additional_containers))

  tags = var.tags
}

# ── Target group (ALB-attached services) ──────────────────────────────────────
resource "aws_lb_target_group" "this" {
  count       = var.attach_alb ? 1 : 0
  name        = substr(local.full_name, 0, 32)
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  deregistration_delay = 30
  tags                 = var.tags
}

resource "aws_lb_listener_rule" "this" {
  count        = var.attach_alb ? 1 : 0
  listener_arn = var.alb_listener_arn
  priority     = var.alb_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }

  condition {
    path_pattern {
      values = var.alb_path_patterns
    }
  }

  # Host-based routing for a shared ALB (multiple products/hostnames on one
  # listener). Empty alb_host_headers keeps the rule path-only (single-tenant ALB).
  dynamic "condition" {
    for_each = length(var.alb_host_headers) > 0 ? [1] : []
    content {
      host_header {
        values = var.alb_host_headers
      }
    }
  }
}

# ── Service ───────────────────────────────────────────────────────────────────
resource "aws_ecs_service" "this" {
  name            = var.service_name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  # launch_type and capacity_provider_strategy are mutually exclusive.
  # use_spot=true: prefer FARGATE_SPOT (4:1), fall back to on-demand.
  launch_type            = var.use_spot ? null : "FARGATE"
  enable_execute_command = var.enable_ecs_exec

  dynamic "capacity_provider_strategy" {
    for_each = var.use_spot ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = 4
      base              = 0
    }
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.use_spot ? [1] : []
    content {
      capacity_provider = "FARGATE"
      weight            = 1
      base              = 0
    }
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.attach_alb ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = var.service_name
      container_port   = var.container_port
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    # CD (backend-deploy) registers new task-def revisions out of band via
    # ecs update-service; ignore task_definition so a `tofu apply` never rolls
    # the running deployment back to the module's baseline revision. Terraform
    # still owns the baseline task def (image/env/secrets); the next deploy
    # derives from it. desired_count is ignored for the same reason (autoscaling).
    ignore_changes = [desired_count, task_definition]
  }

  tags = var.tags
}

# ── Autoscaling ───────────────────────────────────────────────────────────────
# ── Autoscaling ───────────────────────────────────────────────────────────────
# Optional, because not every service wants it and one that does not is CHEAPER AND
# SIMPLER without it.
#
# A service whose desired count is driven on a schedule — an environment awake in working
# hours and asleep otherwise — cannot also have target-tracking policies. The two fight:
# with a floor of 1 the scheduled scale-to-zero is restored within minutes, and with a
# floor of 0 target tracking scales the service to zero mid-day and nothing brings it
# back. Turning autoscaling off leaves `desired_count` (already under ignore_changes) as
# the single owner, so the schedule is authoritative and no plan reports drift.
#
# The alternative — `ignore_changes` on min/max so scheduled actions can move them — was
# tried and rejected: it silently swallows a later `min_count` change in a caller, which
# turns "restore capacity at go-live" into an edit that appears to apply and does nothing.
resource "aws_appautoscaling_target" "this" {
  count              = var.enable_autoscaling ? 1 : 0
  max_capacity       = var.max_count
  min_capacity       = var.min_count
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  count              = var.enable_autoscaling ? 1 : 0
  name               = "${local.full_name}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.cpu_target_pct
    scale_in_cooldown  = 120
    scale_out_cooldown = 60
  }
}

# Memory-based scaling — a NestJS API can hit memory pressure before CPU.
resource "aws_appautoscaling_policy" "memory" {
  count              = var.enable_autoscaling ? 1 : 0
  name               = "${local.full_name}-memory"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = var.memory_target_pct
    scale_in_cooldown  = 120
    scale_out_cooldown = 60
  }
}

# ── State moves for the enable_autoscaling toggle ─────────────────────────────
#
# `enable_autoscaling` gave these three resources a `count`, which changed their
# addresses from `.this`/`.cpu`/`.memory` to `.this[0]`/`.cpu[0]`/`.memory[0]`. Without
# these blocks a caller that simply bumps the module ref — changing no inputs and keeping
# autoscaling on — gets a destroy-and-recreate of its scalable target and both policies,
# because Terraform matches state to config by address and finds nothing at the old one.
#
# The plan shows that as ordinary churn, which is what makes it dangerous: adding a
# `count` without a `moved` block is how an unrelated ElastiCache migration in this
# organisation destroyed and recreated a running cache node. Same mistake, same shape.
#
# With these, an autoscaling-enabled caller plans `0 to add, 0 to change, 0 to destroy`.
# Callers setting `enable_autoscaling = false` still get the destroy they asked for —
# Terraform performs the move, then removes the instance the config no longer declares.
moved {
  from = aws_appautoscaling_target.this
  to   = aws_appautoscaling_target.this[0]
}

moved {
  from = aws_appautoscaling_policy.cpu
  to   = aws_appautoscaling_policy.cpu[0]
}

moved {
  from = aws_appautoscaling_policy.memory
  to   = aws_appautoscaling_policy.memory[0]
}
