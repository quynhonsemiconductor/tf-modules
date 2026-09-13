// ── Identity ────────────────────────────────────────────────────────────────

variable "product" {
  type        = string
  description = "Product name, e.g. `rova`. Used for sidecar naming and tags."
}

variable "env" {
  type        = string
  description = "Environment name, e.g. `develop` or `prod`."
}

variable "service_name" {
  type        = string
  description = "Service name within the product, e.g. `api` or `worker`."
}

variable "region" {
  type        = string
  description = "AWS region, for the awslogs driver and sidecar config."
}

// ── Cluster + network (read from the shared runtime stack by the caller) ──────

variable "cluster_name" { type = string }
variable "cluster_arn" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }

// ── Image + sizing ──────────────────────────────────────────────────────────

variable "image_uri" {
  type        = string
  description = "Fully qualified image URI including tag or digest."
}

variable "cpu" { type = number }
variable "memory" { type = number }

variable "cpu_architecture" {
  type        = string
  default     = "ARM64"
  description = <<-EOT
    `ARM64` (Graviton, ~20% cheaper per vCPU-hour and GB-hour) or `X86_64`.

    Must MOVE TOGETHER with the CI build platform. Setting only one side produces
    "image Manifest does not contain descriptor matching platform" at task start — after a
    clean apply and a build that reported success, so nothing warns you until tasks refuse
    to run. Products whose sidecars have no arm64 build (clamav/clamav publishes none) must
    stay on X86_64.
  EOT
}

variable "use_spot" {
  type        = bool
  default     = false
  description = "Fargate Spot. Suitable for workers whose interruption is a retry, not for an api serving requests."
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

variable "enable_autoscaling" {
  type    = bool
  default = true
}

variable "cpu_target_pct" {
  type    = number
  default = 65
}

variable "memory_target_pct" {
  type    = number
  default = 75
}

// ── Application configuration ───────────────────────────────────────────────

variable "environment_vars" {
  type        = list(object({ name = string, value = string }))
  default     = []
  description = <<-EOT
    Plaintext env, in the ECS task-definition shape. Anything sensitive belongs in `secrets`,
    which uses `valueFrom` so the value never lands in the task definition.
  EOT
}

variable "secrets" {
  type        = list(object({ name = string, secret_arn = string }))
  default     = []
  description = "Env var name -> Secrets Manager/SSM reference, injected via `valueFrom`."
}

variable "secret_arns" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Secret ARNs the task EXECUTION role may read at boot.

    Sidecar tokens are added automatically — see the module header. Pass only the
    application's own secrets here.
  EOT
}

variable "task_secret_arns" {
  type        = list(string)
  default     = []
  description = "Secret ARNs the TASK role may read at runtime (distinct from boot-time injection)."
}

variable "kms_key_arn" {
  type    = string
  default = ""
}

variable "container_port" {
  type    = number
  default = 3000
}

variable "health_check_path" {
  type        = string
  default     = "/health/ready"
  description = "ALB target-group health check path. Ignored when ingress mode is not `alb`."
}

variable "health_check_command" {
  type    = string
  default = null

  description = <<-EOT
    Container-level health check command, for a service with no ALB target group to
    health-check it.

    A worker served by neither an ALB nor a tunnel has NOTHING checking it otherwise: ECS
    reports the task running as long as the process has not exited, so a wedged worker looks
    healthy indefinitely. `null` is a real gap rather than a neutral default — it is the
    divergence the stack-conformance check flags on opshub's `worker`.
  EOT
}

variable "log_retention_days" {
  type        = number
  default     = 30
  description = "CloudWatch log retention. Convention here is 7 in develop, 90 in production."
}

variable "s3_bucket_arns" {
  type    = list(string)
  default = []
}

variable "sqs_queue_arns" {
  type    = list(string)
  default = []
}

variable "sns_topic_arns" {
  type    = list(string)
  default = []
}

variable "enable_ecs_exec" {
  type    = bool
  default = false
}

// ── Ingress ─────────────────────────────────────────────────────────────────

variable "ingress" {
  type = object({
    mode = optional(string, "none")

    // mode = "tunnel"
    tunnel_token_secret_arn = optional(string, "")

    // mode = "alb"
    alb_listener_arn  = optional(string, "")
    alb_priority      = optional(number, 100)
    alb_host_headers  = optional(list(string), [])
    alb_path_patterns = optional(list(string), ["/*"])
  })
  default = {}

  description = <<-EOT
    How traffic reaches this service. `tunnel` (a cloudflared sidecar dialling out),
    `alb` (a target group and listener rule), or `none` (a worker).

    ONE FIELD, not two booleans, because the two are mutually exclusive and expressing that
    as separate flags is what let it go wrong: a task served by a tunnel must not also be an
    ALB target, and each product previously wired `attach_alb = !module.tunnel.enabled` by
    hand in every service block.
  EOT

  validation {
    condition     = contains(["none", "tunnel", "alb"], var.ingress.mode)
    error_message = "ingress.mode must be one of: none, tunnel, alb."
  }

  validation {
    condition     = var.ingress.mode != "tunnel" || var.ingress.tunnel_token_secret_arn != ""
    error_message = "ingress.mode = \"tunnel\" requires tunnel_token_secret_arn. Without it the sidecar is a no-op and the service has NO ingress at all, while still reporting a healthy rollout."
  }

  validation {
    condition     = var.ingress.mode != "alb" || var.ingress.alb_listener_arn != ""
    error_message = "ingress.mode = \"alb\" requires alb_listener_arn. Both shared runtime ALBs are currently absent (enable_alb = false), so this is usually a sign the service should use \"tunnel\"."
  }
}

// ── Sidecars ────────────────────────────────────────────────────────────────

variable "otel" {
  type = object({
    enabled          = optional(bool, false)
    otlp_endpoint    = optional(string, "")
    token_secret_arn = optional(string, "")
    cpu              = optional(number, 0)
    memory           = optional(number, 128)
  })
  default     = {}
  description = <<-EOT
    OpenTelemetry collector sidecar. DORMANT when `otlp_endpoint` is empty: the underlying
    module returns no container, so `enabled = true` with no endpoint costs nothing and
    lets a product carry the wiring before the backend exists.
  EOT
}

variable "firelens" {
  type = object({
    enabled = optional(bool, false)
  })
  default     = {}
  description = "FireLens log router sidecar. Its S3 bucket grants reach the TASK role automatically."
}

// ── DNS ─────────────────────────────────────────────────────────────────────

variable "dns" {
  type = object({
    enabled         = optional(bool, false)
    zone_id         = optional(string, "")
    name            = optional(string, "")
    content         = optional(string, "")
    type            = optional(string, "CNAME")
    proxied         = optional(bool, true)
    comment         = optional(string, "")
    allow_overwrite = optional(bool, false)
  })
  default     = {}
  description = <<-EOT
    Public DNS record for this service, normally the Cloudflare CNAME pointing at the
    tunnel. `content` is usually the tunnel's cname output.

    Cloudflare rejects a CREATE for a name that already exists, so adopting an existing
    record needs `allow_overwrite` or an import — a missing record here is a FAILED apply
    rather than a silent no-op.
  EOT
}

variable "tags" {
  type    = map(string)
  default = {}
}
