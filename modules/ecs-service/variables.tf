# ── Identity / placement ──────────────────────────────────────────────────────
variable "service_name" { type = string }
variable "cluster_name" { type = string }
variable "cluster_arn" { type = string }
variable "region" {
  type        = string
  description = "AWS region (for the awslogs driver)."
}

variable "image_uri" {
  type        = string
  description = "Container image URI (registry/name:tag)."
}

# ── Sizing ────────────────────────────────────────────────────────────────────
variable "cpu" { type = number }
variable "memory" { type = number }
variable "container_port" {
  type    = number
  default = 3000
}
variable "desired_count" {
  type    = number
  default = 1
}
variable "min_count" {
  type    = number
  default = 1
}
variable "max_count" {
  type    = number
  default = 4
}

# ── Autoscaling targets ───────────────────────────────────────────────────────
variable "cpu_target_pct" {
  type        = number
  default     = 65
  description = "Target average CPU % for autoscaling."
}
variable "memory_target_pct" {
  type        = number
  default     = 75
  description = "Target average memory % for autoscaling."
}

# ── Networking ────────────────────────────────────────────────────────────────
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }

# ── ALB attachment ────────────────────────────────────────────────────────────
variable "attach_alb" {
  type    = bool
  default = true
}
variable "alb_listener_arn" {
  type    = string
  default = ""
}
variable "alb_priority" {
  type    = number
  default = 100
}
variable "alb_path_patterns" {
  type    = list(string)
  default = ["/*"]
}
variable "alb_host_headers" {
  type        = list(string)
  default     = []
  description = "Host headers for the ALB listener rule. Set for shared-ALB host-based routing (e.g. [\"rova-api.qnsc.vn\"]); empty keeps the rule path-only."
}
variable "health_check_path" {
  type    = string
  default = "/health"
}
variable "health_check_command" {
  type    = string
  default = null
}

# ── Config / secrets ──────────────────────────────────────────────────────────
variable "environment_vars" {
  type    = list(object({ name = string, value = string }))
  default = []
}
variable "secrets" {
  type    = list(object({ name = string, secret_arn = string }))
  default = []
}
variable "secret_arns" {
  type        = list(string)
  default     = []
  description = "Secret ARNs the execution role may read (for secrets injection)."
}
variable "ssm_parameter_arns" {
  type        = list(string)
  default     = []
  description = <<-EOT
    SSM Parameter Store ARNs the EXECUTION role may read for boot-time env injection
    (`ssm:GetParameters`). Separate from `secret_arns` because Secrets Manager and
    Parameter Store are different APIs — ECS injects from both identically, but the
    IAM action differs, so mixing them in one list grants the wrong permission.
  EOT
}

variable "task_ssm_parameter_arns" {
  type        = list(string)
  default     = []
  description = <<-EOT
    SSM Parameter Store ARNs the TASK role may read at RUNTIME. The Parameter Store
    counterpart of `task_secret_arns`.
  EOT
}

variable "kms_key_arn" {
  type        = string
  default     = ""
  description = "CMK ARN; if set, the execution role gets kms:Decrypt for KMS-encrypted secrets."
}

# ── Runtime AWS access (task role) ────────────────────────────────────────────
variable "sqs_queue_arns" {
  type    = list(string)
  default = []
}
variable "sns_topic_arns" {
  type    = list(string)
  default = []
}
variable "s3_bucket_arns" {
  type        = list(string)
  default     = []
  description = "S3 bucket ARNs the task may read/write (get/put/delete + list + get-bucket-location)."
}
variable "execution_s3_bucket_arns" {
  type        = list(string)
  default     = []
  description = <<-EOT
    S3 bucket ARNs the EXECUTION role may GetObject from (read-only) — for
    FireLens' external custom-config path (`config-file-type = "s3"`), fetched by
    the agent before the task's containers start. Not the task role: the running
    app has no reason to read a log-router config bucket.
  EOT
}
variable "task_secret_arns" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Secret ARNs (wildcards allowed) the TASK role may read at RUNTIME via
    secretsmanager:GetSecretValue — e.g. an app resolving per-connection
    credentials on demand from a DB-driven config. Distinct from `secret_arns`,
    which is the EXECUTION role reading secrets once at container start for env
    injection.
  EOT
}

# ── Misc ──────────────────────────────────────────────────────────────────────
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "use_firelens" {
  type        = bool
  default     = false
  description = <<-EOT
    Switch this container's log driver from `awslogs` to `awsfirelens`. Set
    true only when a `firelens-agent` router is ALSO present in
    `additional_containers` — otherwise the container has no log destination
    at all, since ECS routes `awsfirelens` output to whichever sidecar
    declares `firelensConfiguration`, not to CloudWatch directly.
  EOT
}
variable "enable_ecs_exec" {
  type        = bool
  default     = false
  description = "Enable ECS Exec (aws ecs execute-command) for debugging."
}
variable "use_spot" {
  type        = bool
  default     = false
  description = "Prefer FARGATE_SPOT (weight 4) with FARGATE fallback (weight 1). Saves ~70% on Fargate compute in dev."
}
variable "cpu_architecture" {
  type        = string
  default     = "X86_64"
  description = <<-EOT
    Fargate CPU architecture: "X86_64" or "ARM64".

    ARM64 (Graviton) bills roughly 20% less per vCPU-hour and GB-hour for identical
    sizing. It requires an image built for linux/arm64 — an x86 image on an ARM64 task
    fails at container start with "image Manifest does not contain descriptor matching
    platform", so flip this only together with the image build.

    Defaults to X86_64 so existing callers keep their current architecture on upgrade.
  EOT

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}
variable "container_depends_on" {
  description = <<-EOT
    `dependsOn` for the MAIN container. ECS starts containers in dependency order and stops them in REVERSE: a main container that depends on its
    telemetry sidecar (`{ container_name = "otel-agent", condition = "START" }`) is stopped FIRST and the sidecar after it, so the app's shutdown flush
    reaches a live collector. Without it both get SIGTERM at once.

    `START` is the right condition for a sidecar that has no health check (the ADOT image has none): it only orders start and stop. Default empty: the
    task definition is unchanged.
  EOT
  type = list(object({
    container_name = string
    condition      = string
  }))
  default = []

  validation {
    condition     = alltrue([for d in var.container_depends_on : contains(["START", "COMPLETE", "SUCCESS", "HEALTHY"], d.condition)])
    error_message = "container_depends_on condition must be START, COMPLETE, SUCCESS or HEALTHY."
  }
}

variable "stop_timeout" {
  description = <<-EOT
    `stopTimeout` of the MAIN container, in seconds: how long ECS waits after SIGTERM before SIGKILL. null (default) leaves the ECS default (30 s on Fargate)
    and the task definition unchanged. It must exceed the app's own shutdown deadline (the shared graceful shutdown defaults to 25 s), or the app is killed
    mid-flush. Fargate allows 2 to 120.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.stop_timeout == null ? true : (var.stop_timeout >= 2 && var.stop_timeout <= 120)
    error_message = "stop_timeout must be between 2 and 120 seconds (Fargate), or null."
  }
}

variable "additional_containers" {
  type        = any
  default     = []
  description = "Extra sidecar container definitions merged into the task definition (e.g. a Valkey cache sidecar in dev). Each element is a full ECS container definition object; reachable from the app at localhost via the shared task network namespace."
}
variable "tags" {
  type    = map(string)
  default = {}
}

variable "enable_autoscaling" {
  type        = bool
  default     = true
  description = <<-EOT
    Create the scalable target and the CPU/memory target-tracking policies.

    Set FALSE for a service whose desired count is driven on a schedule — an environment
    awake in working hours and asleep otherwise. The two mechanisms cannot coexist: with a
    floor of 1 a scheduled scale-to-zero is restored within minutes, and with a floor of 0
    target tracking scales the service to zero mid-day with nothing to bring it back.

    With autoscaling off, `desired_count` (already under ignore_changes) is the single
    owner, so the schedule is authoritative and no plan reports drift. It also removes the
    two CloudWatch alarms Application Auto Scaling creates per policy.

    `min_count`, `max_count` and the target percentages are ignored while false.
  EOT
}
