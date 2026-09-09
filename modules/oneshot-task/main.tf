# =============================================================================
# oneshot-task — a one-shot Fargate task definition + its CloudWatch log group.
#
# Deliberately GENERIC: it owns the Fargate mechanics (task def shape, awslogs
# wiring, log group) and knows NOTHING about what the task does. A DB migrator,
# a data backfill, a one-off cron job — all the same shape. The MEANING (which
# image, which env vars, whether it seeds, which secrets) is passed in by the
# caller, because that's product/app-specific and must not be baked into shared
# infra. The task is never run as a service; a deploy pipeline triggers it with
# `aws ecs run-task` (see the ci ecs-run-task / run-db-migration actions).
# =============================================================================

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  # Must match the architecture of `var.image`, and therefore the services that run
  # alongside it — the migrator is built from the same Dockerfile in the same CI job.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([{
    name        = var.container_name
    image       = var.image
    essential   = true
    command     = length(var.command) > 0 ? var.command : null
    environment = [for k, v in var.environment : { name = k, value = v }]
    secrets     = [for k, arn in var.secrets : { name = k, valueFrom = arn }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = var.container_name
      }
    }
  }])

  tags = var.tags
}
