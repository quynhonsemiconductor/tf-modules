# ─────────────────────────────────────────────────────────────────────────────
# product-profile — everything a product needs that OUTLIVES A DEPLOY.
#
# §7's rule draws the line this module sits on: "if it outlives a deploy,
# OpenTofu owns it." RDS, ElastiCache, R2, IRSA roles, Secrets Manager containers,
# DNS, budgets and alarms are here. Deployments, Services, HPAs, Jobs and CronJobs
# are the chart's, in `gitops`. No object is described in both.
#
# §6's discipline: capabilities are a SET, each defaulting to absent. A product
# with no database sets nothing and gets no RDS, no secret, no IAM grant, no
# alarms. Adding OpenSearch later means one optional block here — not a second
# module, and not a copy of the first.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # §7c — DERIVED, never passed. The Helm chart computes the identical strings
  # from the same three values, so nothing crosses the repository boundary.
  #
  #   qnsc-prod-rova-api              IRSA role
  #   qnsc/prod/rova/app/…            secret path — hierarchical, so the IAM
  #                                   policy below is ONE wildcard
  #   qnsc-prod-rova-email-bounce     SQS queue
  prefix        = "qnsc-${var.env}-${var.product}"
  secret_prefix = "qnsc/${var.env}/${var.product}"

  # Postgres identifiers take underscores. A role named `qnsc-kb` would need
  # double-quoting in every statement for the life of the database (§7c).
  pg_name     = replace(var.product, "-", "_")
  pg_migrator = "${local.pg_name}_migrator"

  dedicated = var.postgres.mode == "dedicated"
  shared    = var.postgres.mode == "shared"
  has_pg    = var.postgres.mode != "none"

  # §5 — the instance class follows the criticality tier when not set explicitly.
  # Measured prices, from rova/infra/live/prod/main.tf:339: micro $13.14/month,
  # small $26.28.
  default_instance_class = {
    xs = "db.t4g.micro"
    s  = "db.t4g.micro"
    m  = "db.t4g.small"
    l  = "db.t4g.small"
  }

  instance_class = coalesce(
    var.postgres.instance_class != "" ? var.postgres.instance_class : null,
    local.default_instance_class[var.size],
  )

  tags = merge(var.tags, {
    product   = var.product # §12 — cost allocation. Activate these in Billing
    env       = var.env     #       BEFORE migrating: history cannot be
    size      = var.size    #       reconstructed retroactively
    ManagedBy = "product-profile"
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Postgres
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated instance. §5 grants one only where it is earned.
module "rds" {
  count  = local.dedicated ? 1 : 0
  source = "../rds"

  identifier        = "${var.product}-${var.env}"
  subnet_ids        = var.subnet_ids
  security_group_id = var.security_group_id
  engine_version    = var.postgres.engine_version
  instance_class    = local.instance_class

  allocated_storage_gb = var.postgres.storage_gb
  multi_az             = var.postgres.multi_az
  db_name              = local.pg_name
  kms_key_arn          = var.kms_key_arn

  # §17b — one Terraform state owns both the database and, today, the ECS
  # services. `tofu destroy` run to remove ECS would take the database with it,
  # and 2026-09-14 already cost twelve minutes of downtime learning that.
  deletion_protection = var.env == "prod"
  skip_final_snapshot = false

  tags = local.tags
}

# The database and roles on the shared instance.
#
# TWO ROLES, NOT ONE — §5d. The application role carries statement_timeout = 30s
# to bound noisy neighbours, which would kill the 600s migrations §4 sets
# deliberately. Separating them also takes DDL off the runtime role, so a
# compromised application cannot reshape its own schema.
resource "postgresql_database" "this" {
  count = local.shared ? 1 : 0
  name  = local.pg_name
}

resource "postgresql_role" "app" {
  count = local.has_pg ? 1 : 0
  name  = local.pg_name
  login = true

  # §8 — RDS IAM authentication. No password exists, so there is nothing to
  # store, nothing to rotate, and nothing to get wrong on the next 2026-09-06.
  roles = ["rds_iam"]
}

resource "postgresql_role" "migrator" {
  count = local.has_pg ? 1 : 0
  name  = local.pg_migrator
  login = true
  roles = ["rds_iam"]
}

# ── Per-role limits — emitted as SQL, not applied here ───────────────────────
#
# §5d wants `ALTER ROLE <product> SET statement_timeout = '30s'` and friends: free,
# and they turn "the database is slow" from a mystery into a name.
#
# The cyrilgdn/postgresql provider has NO resource for role settings. The choices
# were a null_resource shelling out to psql — which needs network reachability and
# a client binary inside whatever runs `tofu apply`, and fails in a way that leaves
# state disagreeing with reality — or making the gap explicit.
#
# So the module emits the SQL as an output and the caller applies it the same way
# it applies migrations. A missing timeout is then a visible omission rather than
# a silently absent guard, which matters because these are the ONLY thing bounding
# a noisy neighbour on the shared instance (§5).
#
# Revisit if the provider grows the resource.
locals {
  role_settings_sql = local.has_pg ? join("\n", [
    "-- §5d — bounds a noisy neighbour on the shared instance. Idempotent.",
    "ALTER ROLE ${local.pg_name} SET statement_timeout = '30s';",
    "ALTER ROLE ${local.pg_name} SET idle_in_transaction_session_timeout = '60s';",
    "ALTER ROLE ${local.pg_name} CONNECTION LIMIT 40;",
    "",
    "-- The migrator needs the long fuse §4 sets deliberately: the default kills a",
    "-- slow migration part-way, which is the worst possible moment.",
    "ALTER ROLE ${local.pg_migrator} SET statement_timeout = '600s';",
    "ALTER ROLE ${local.pg_migrator} SET idle_in_transaction_session_timeout = '0';",
  ]) : ""
}

resource "postgresql_extension" "this" {
  for_each = local.has_pg ? toset(var.postgres.extensions) : []
  name     = each.value
  database = local.pg_name
}

# ─────────────────────────────────────────────────────────────────────────────
# Secrets — containers only, created EMPTY (§8)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "app" {
  for_each = toset(var.secrets)

  name       = "${local.secret_prefix}/app/${each.value}"
  kms_key_id = var.kms_key_arn != "" ? var.kms_key_arn : null

  # §13 — secrets are REGENERATED, not restored. A rotated Grafana token is not a
  # thing recovered from a backup; it is re-minted. 30 days covers the accident,
  # and §8's inventory records the provenance that covers everything else.
  recovery_window_in_days = 30

  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Messaging — §6b. SQS for work queues; EventBridge for cross-product events,
# added when a second consumer actually appears.
# ─────────────────────────────────────────────────────────────────────────────

# ONE call, not one per queue: the module already takes a prefix and a list, and
# it creates a dead-letter queue beside each. `queue.sqs` names PURPOSES
# (["email-bounce"]), and the chart derives the URL from the same prefix (§7c) —
# so a queue URL never appears in a values file.
module "messaging" {
  count  = length(var.queue.sqs) > 0 ? 1 : 0
  source = "../messaging"

  prefix      = local.prefix
  queues      = { for q in var.queue.sqs : q => {} }
  kms_key_arn = var.kms_key_arn
  tags        = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# IRSA — one role per service (§7c, §8)
# ─────────────────────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "trust" {
  for_each = var.services

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # Scoped to ONE ServiceAccount in ONE namespace. A wildcard here would let
    # any pod in the cluster assume any product's role, which is the same blast
    # radius §8 refuses a ClusterSecretStore for.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${var.product}:${each.key}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "service" {
  for_each = var.services

  # §8 — one wildcard, and it is only one because §7c made the secret path
  # hierarchical. Flat names would mean enumerating every secret here and editing
  # this on every addition.
  dynamic "statement" {
    for_each = length(var.secrets) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${local.secret_prefix}/*"]
    }
  }

  # RDS IAM auth: the right to mint a 15-minute token for THIS product's role on
  # THIS instance. Nothing long-lived is granted.
  dynamic "statement" {
    for_each = local.has_pg ? [1] : []
    content {
      effect  = "Allow"
      actions = ["rds-db:connect"]
      resources = [
        "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:*/${local.pg_name}",
      ]
    }
  }

  dynamic "statement" {
    for_each = each.value.needs_sqs && length(var.queue.sqs) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:SendMessage"]
      resources = ["arn:aws:sqs:${var.region}:${data.aws_caller_identity.current.account_id}:${local.prefix}-*"]
    }
  }
}

resource "aws_iam_role" "service" {
  for_each = var.services

  # §7c — this is the string the chart annotates its ServiceAccount with. Neither
  # side is told it by the other; both compute it.
  name               = "${local.prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.trust[each.key].json
  tags               = local.tags
}

resource "aws_iam_role_policy" "service" {
  for_each = var.services

  name   = "product-profile"
  role   = aws_iam_role.service[each.key].id
  policy = data.aws_iam_policy_document.service[each.key].json
}
