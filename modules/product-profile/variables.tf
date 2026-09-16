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
    and opshub's shared cache, and rate limiting — but §15b consolidates it to
    ONE cache.t4g.micro per environment with a database index per product, never
    an instance per product.

    `shared` therefore CREATES NOTHING, and there is no `dedicated`. Redis has no
    IAM, so there is nothing to put in a policy either: the whole grant is an
    endpoint and an index, and both are passed in as `shared_cache`. What this
    flag buys is `cache_url` — one place that composes them, so the URL is not
    assembled by hand in each stack — and a precondition that fails the plan when
    a product asks for the cache and the wiring is absent.

    The INDEX is allocated by the data stack, not here, because §5d's table
    allocates by USE rather than by product (qnsc-kb holds db 0 for the broker and
    db 1 for rate limiting) and a per-product module cannot see the other products
    it must not collide with.
  EOT

  validation {
    # No `dedicated`. §15b's whole argument is that per-product Redis is the line
    # that grows with product count; accepting the value would make the interface
    # promise something the design refuses.
    condition     = contains(["none", "shared"], var.cache.mode)
    error_message = "cache.mode must be none or shared. There is no dedicated Redis in this estate (§15b)."
  }
}

# NO `storage` VARIABLE, though §6's example sketched one.
#
# R2 buckets are Cloudflare resources and `cf-r2` already creates them. Nesting it
# here would drag the Cloudflare provider into a module whose callers are the data
# stacks, which load aws + postgresql and no Cloudflare provider at all — and
# `cf-r2` requires provider v5 specifically, while a root stack can load only one
# Cloudflare major. So a bucket asked for here would either fail to plan or pin
# every caller's Cloudflare version to suit a module that is otherwise about
# databases.
#
# Buckets are declared in the Cloudflare stack. Nothing about that crosses into
# this module, because §7c means the bucket name is DERIVED on both sides
# (`qnsc-<env>-<product>-<use>`) rather than passed.
#
# R2 credentials are an API token under `qnsc/<env>/<product>/app/`, which the
# `secrets` list below creates and the IAM wildcard already covers. That is the
# only R2 fact this module needs to know.

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
    # NO `needs_s3`. Object storage here is Cloudflare R2 (§7), which has no AWS
    # IAM surface — access is an API token under the secret prefix, already
    # covered by the one wildcard. A flag that granted nothing would read in
    # review as a grant that exists.
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

variable "shared_cache" {
  type = object({
    host     = optional(string, "")
    port     = optional(number, 6379)
    db_index = optional(number, 0)
  })
  default     = {}
  description = <<-EOT
    The one instance for this environment, and THIS PRODUCT'S INDEX on it (§5d).

    Required when cache.mode = "shared". The index comes from the data stack's
    allocation table, for the reason `cache` gives: uniqueness is a fact about
    the set of products, which this module cannot see.
  EOT
}

# NO `vpc_id`. Nothing here takes one: `aws_db_subnet_group` is built from
# `subnet_ids`, the security group arrives already created as `security_group_id`,
# and IAM, Secrets Manager and SQS are not VPC-scoped at all. It was passed
# because a module that makes a database looks like it should need one.

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
