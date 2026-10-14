# `ecs-service` module

A Fargate ECS service: task definition, execution + task IAM roles (with
optional SQS/SNS/S3 access), CloudWatch logs, optional ALB target group +
listener rule, deployment circuit breaker, and CPU + memory autoscaling.

## Usage

```hcl
module "api" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/ecs-service?ref=ecs-service-v1.0.0"

  service_name = "api"
  cluster_name = module.ecs_cluster.cluster_name
  cluster_arn  = module.ecs_cluster.cluster_arn
  region       = "ap-southeast-1"
  image_uri    = "${local.ecr_base}/myproduct-api:${var.image_tag}"

  cpu          = 1024
  memory       = 2048
  desired_count = 2
  min_count     = 2
  max_count     = 10

  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.sg_app_id

  attach_alb        = true
  alb_listener_arn  = aws_lb_listener.https.arn
  alb_priority      = 10
  alb_path_patterns = ["/*"]
  health_check_path = "/health/ready"

  secret_arns    = values(module.secrets.secret_arns)
  kms_key_arn    = local.kms_key_arn
  sqs_queue_arns = values(module.messaging.queue_arns)
  sns_topic_arns = values(module.messaging.topic_arns)
  # s3_bucket_arns = [aws_s3_bucket.uploads.arn]   # if the task needs S3

  tags = { Environment = "prod" }
}
```

## Key inputs

| Name | Default | Description |
| :--- | :------ | :---------- |
| `cpu` / `memory` | — | Fargate task size |
| `desired_count` / `min_count` / `max_count` | `1/1/4` | Service + autoscaling bounds |
| `cpu_target_pct` / `memory_target_pct` | `65 / 75` | Autoscaling targets |
| `attach_alb` | `true` | Create target group + listener rule |
| `alb_path_patterns` / `alb_host_headers` | `["/*"]` / `[]` | Listener-rule conditions. Set `alb_host_headers` for shared-ALB host-based routing (e.g. `["rova-api.qnsc.vn"]`) |
| `additional_containers` | `[]` | Extra sidecar container definitions merged into the task (e.g. a Valkey cache sidecar in dev; reachable at `localhost`) |
| `secret_arns` / `kms_key_arn` | `[]` / `""` | Execution-role secrets injection at boot (+ KMS decrypt) |
| `sqs_queue_arns` / `sns_topic_arns` / `s3_bucket_arns` | `[]` | Task-role runtime access |
| `task_secret_arns` | `[]` | Secret ARNs (wildcards allowed) the **task** role may read at runtime via `GetSecretValue` — e.g. resolving per-connection credentials on demand. Distinct from `secret_arns` (execution role, boot-time) |
| `enable_ecs_exec` | `false` | ECS Exec for debugging |
| `log_retention_days` | `30` | Log retention |

See `variables.tf` for the full list.

## Outputs

`service_name`, `service_arn`, `task_role_arn`, `execution_role_arn`,
`task_definition_arn`, `log_group_name`, `target_group_arn`.

## Requirements

- OpenTofu / Terraform `>= 1.9.0`
- AWS provider `>= 5.0`

## Stopping the app before its telemetry sidecar (`container_depends_on`, `stop_timeout`)

ECS sends SIGTERM to every container of a task at once. With a collector sidecar the collector exits immediately, and the app's own shutdown step that flushes
telemetry (5 s) times out against a collector that is already gone. `dependsOn` fixes the ORDER: ECS stops containers in the reverse of their dependencies.

```hcl
container_depends_on = [{ container_name = "otel-agent", condition = "START" }]   # the app now stops first
stop_timeout         = null                                                      # default 30 s; must exceed the app's shutdown deadline (25 s)
```

Both default to "unset", and then the rendered container definition is byte-identical to before (no `null` keys, so upgrading replaces no task definition).
