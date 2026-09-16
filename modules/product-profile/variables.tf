# ── Identity ─────────────────────────────────────────────────────────────────
# These three inputs derive every name this module creates. The Helm chart
# derives the SAME names from the same three values (§7c), so nothing crosses the
# repository boundary and the two cannot drift.

variable "product" {
  type        = string
  description = <<-EOT
    Short product slug: rova · opshub · kb · lms · solodesk · ai-dev-kit.

    NOT `qnsc-kb` — §7c shortens it, because AWS resources already carry a `qnsc-`
    prefix and the long form double-prefixes: `qnsc-prod-qnsc-kb-sources`.
  EOT

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.product))
    error_message = "product must be a lowercase slug, e.g. rova or kb."
  }
}

variable "env" {
  type        = string
  description = <<-EOT
    `dev` or `prod`. Never `develop`/`production` (§7c).

    Production already matches — rova/infra/live/prod/main.tf:88 records the
    decision: "Resources are named `rova-prod`, not `rova-production`". Only dev
    differs, and only in RDS instance identifiers, which are grandfathered because
    renaming an instance changes its ENDPOINT HOSTNAME.
  EOT

  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env must be dev or prod (§7c)."
  }
}

variable "size" {
  type        = string
  default     = "s"
  description = <<-EOT
    A CRITICALITY tier, not a resource size.

    Every property it controls is an availability one. rova is `l` and the
    SMALLEST workload in the estate: `l` means an outage costs revenue, not that
    the product is big (§5).

    CI fails if this disagrees with `size` in gitops/values/<product>/<env>.yaml —
    the one fact declared in both repositories (§7c).
  EOT

  validation {
    condition     = contains(["xs", "s", "m", "l"], var.size)
    error_message = "size must be xs, s, m or l."
  }
}

# ── Capabilities, each defaulting to ABSENT ──────────────────────────────────
# §6: "A product with no database sets mode = "none" and gets no RDS, no secret,
# no IAM grant, no alarms. Adding OpenSearch later means adding one optional block
# to the module — not a second module, and not a copy of the first."

variable "postgres" {
  type = object({
    mode           = optional(string, "none") # none | shared | dedicated
    pooling        = optional(string, "pgbouncer")
    extensions     = optional(list(string), [])
    engine_version = optional(string, "16")
    instance_class = optional(string, "") # dedicated only; "" picks from size
    storage_gb     = optional(number, 20)
    multi_az       = optional(bool, false)
  })
  default     = {}
  description = <<-EOT
    `shared` provisions a database and two roles on the shared instance for this
    environment. `dedicated` provisions an instance of its own.

    §5 dedicates in PRODUCTION only where it is earned: rova (the only product
    earning money) and qnsc-kb (pgvector, a ~16 GiB working set, a workload shape
    unlike anything else). Everything else shares, and DEV IS SHARED WITH NO
    EXCEPTIONS.

    The decision is made on RESTORE GRANULARITY rather than on cost — the gap is
    about $40/month. RDS snapshots and PITR operate on an INSTANCE, so restoring
    opshub would drag LMS, solodesk and ai-dev-kit back to the same moment. In dev
    that costs nothing; in prod it is what $40 does not buy back.
  EOT

  validation {
    condition     = contains(["none", "shared", "dedicated"], var.postgres.mode)
    error_message = "postgres.mode must be none, shared or dedicated."
  }
}

variable "cache" {
  type = object({
    mode = optional(string, "none") # none | shared
  })
  default     = {}
  description = <<-EOT
    Defaults to NONE for every product (§5d).

    Redis is not removable from this estate — it is qnsc-kb's Celery broker, rova
    and opshub's shared cache, and rate limiting — but it is ONE shared instance
    per environment with a database index per product, never an instance per
    product. `shared` grants access; it does not create anything.
  EOT
}

variable "storage" {
  type = object({
    r2_buckets = optional(list(string), [])
  })
  default = {}
}

variable "queue" {
  type = object({
    sqs = optional(list(string), []) # queue PURPOSES: ["email-bounce"], not URLs
  })
  default     = {}
  description = <<-EOT
    Queue purposes, not URLs. The chart derives
    `https://sqs.<region>.amazonaws.com/<account>/qnsc-<env>-<product>-<purpose>`
    from the same three identity variables (§7c), so the URL never crosses the
    repository boundary.

    Each queue gets a dead-letter queue. §6b's three controls apply to whatever
    publishes to them.
  EOT
}

variable "secrets" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Secret names under `qnsc/<env>/<product>/app/`. Created EMPTY — values are
    written out of band and never enter state or git (§8).

    The path is hierarchical so the IRSA policy is one wildcard. Flat names would
    mean enumerating every secret in the policy and editing it on every addition,
    which is the chore that gets skipped and leaves the wildcard nobody meant to
    grant.
  EOT
}

# ── Services, for IRSA ───────────────────────────────────────────────────────

variable "services" {
  type = map(object({
    needs_s3     = optional(bool, false)
    needs_sqs    = optional(bool, false)
    extra_policy = optional(string, "")
  }))
  default     = {}
  description = <<-EOT
    One IRSA role per service, named `qnsc-<env>-<product>-<service>` — exactly
    what the chart annotates its ServiceAccounts with (§7c).

    Keys must match `services` in gitops/values/<product>/base.yaml. A missing
    role surfaces as a pod that cannot assume anything, which is a slow way to
    find a typo; the CI check in §7c catches it earlier.
  EOT
}

# ── Wiring ───────────────────────────────────────────────────────────────────

variable "oidc_provider_arn" {
  type        = string
  description = "EKS OIDC provider ARN. IRSA trust is scoped to this cluster's issuer."
}

variable "oidc_issuer" {
  type        = string
  description = "EKS OIDC issuer URL without the https:// prefix."
}

variable "shared_postgres" {
  type = object({
    host       = optional(string, "")
    port       = optional(number, 5432)
    identifier = optional(string, "")
  })
  default     = {}
  description = "The shared instance for this environment. Required when postgres.mode = shared."
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "kms_key_arn" {
  type    = string
  default = ""
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "tags" {
  type    = map(string)
  default = {}
}
