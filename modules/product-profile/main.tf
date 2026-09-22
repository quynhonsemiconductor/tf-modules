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

  # §5d — ONE instance per environment, an index per use. The module composes the
  # URL and creates nothing; `shared_cache` carries both halves in.
  has_cache = var.cache.mode != "none"
  cache_urls = local.has_cache ? {
    for use, idx in var.shared_cache.db_indexes :
    use => "redis://${var.shared_cache.host}:${var.shared_cache.port}/${idx}"
  } : {}

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

  # New instances, so the CMK can be set at creation — see the variable.
  performance_insights_kms_key_arn = var.kms_key_arn

  # §8 chose RDS IAM authentication, and BOTH halves are required. The roles below
  # are granted `rds_iam` and the IRSA policy grants `rds-db:connect`, but a token
  # minted against an instance with this off is rejected — the product would fail
  # to connect with two correct-looking grants in place. checkov's CKV_AWS_161
  # found the gap; three review passes over the module did not.
  iam_database_authentication = true

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

  # NO `owner`, AND THAT IS A HARD-WON CHOICE — SEE BELOW.
}

# ── WHY THE MIGRATOR DOES NOT OWN THE DATABASE ───────────────────────────────
#
# Making it the owner is the obvious modelling: it is the DDL identity, so let it own
# what it reshapes. It also locks the admin out of the instance, and this module did
# exactly that before reverting.
#
# To set a database's owner, the connecting role must be a member of the new owning
# role, so the provider grants it. `<product>_migrator` is a member of `rds_iam`, and
# MEMBERSHIP IN `rds_iam` IS INHERITED — so `app_admin` acquired it and RDS immediately
# stopped accepting its PASSWORD:
#
#     FATAL: PAM authentication failed for user "app_admin"
#
# The master credential, the one thing every future apply of this stack depends on,
# became unusable as a side effect of a grant nobody asked for. Recovery was only
# possible because app_admin had by then also inherited the ability to authenticate by
# IAM TOKEN, which is a coincidence and not a plan.
#
# Grants achieve the same end with none of that: CREATE on the database lets the
# migrator create schemas, and ALL on `public` lets it build in the default one. No
# membership, no inheritance, no lockout.
resource "postgresql_grant" "migrator_create_db" {
  count       = local.has_pg ? 1 : 0
  database    = local.pg_name
  role        = local.pg_migrator
  object_type = "database"
  # CONNECT is implied by PUBLIC today, and named explicitly because a future
  # `REVOKE ... FROM PUBLIC` should not silently break migrations.
  privileges = ["CONNECT", "CREATE"]

  depends_on = [postgresql_role.migrator, postgresql_database.this]
}

resource "postgresql_grant" "migrator_schema" {
  count       = local.has_pg ? 1 : 0
  database    = local.pg_name
  role        = local.pg_migrator
  schema      = "public"
  object_type = "schema"
  # CREATE and USAGE. Since PostgreSQL 15 `public` grants CREATE to nobody by default,
  # which is why `CREATE SCHEMA` and `CREATE TABLE` both failed with
  # `permission denied for database` / `for schema public`.
  privileges = ["CREATE", "USAGE"]

  depends_on = [postgresql_grant.migrator_create_db]
}

# ── What the RUNTIME role may do — §5d, §8 ───────────────────────────────────
#
# The app role owns nothing and creates nothing. It connects, reads and writes rows in
# the schema the migrator built. A compromised application therefore cannot reshape its
# own schema, which is the property the two-role split exists for.
resource "postgresql_grant" "app_connect" {
  count       = local.has_pg ? 1 : 0
  database    = local.pg_name
  role        = local.pg_name
  object_type = "database"
  privileges  = ["CONNECT"]

  depends_on = [postgresql_role.app, postgresql_database.this]
}

resource "postgresql_grant" "app_schema_usage" {
  count       = local.has_pg ? 1 : 0
  database    = local.pg_name
  role        = local.pg_name
  schema      = "public"
  object_type = "schema"
  privileges  = ["USAGE"]

  depends_on = [postgresql_grant.app_connect]
}

# DML on what EXISTS today. `postgresql_default_privileges` below covers what the
# migrator creates later — both are needed, and only having the second is a common way
# to end up with an app that can read new tables and not old ones.
resource "postgresql_grant" "app_tables" {
  count       = local.has_pg ? 1 : 0
  database    = local.pg_name
  role        = local.pg_name
  schema      = "public"
  object_type = "table"
  privileges  = ["SELECT", "INSERT", "UPDATE", "DELETE"]

  depends_on = [postgresql_grant.app_schema_usage]
}

resource "postgresql_grant" "app_sequences" {
  count       = local.has_pg ? 1 : 0
  database    = local.pg_name
  role        = local.pg_name
  schema      = "public"
  object_type = "sequence"
  privileges  = ["USAGE", "SELECT"]

  depends_on = [postgresql_grant.app_schema_usage]
}

# ── AND ON EVERYTHING THE MIGRATOR CREATES FROM NOW ON ───────────────────────
#
# Without these, every future migration produces tables the application cannot read,
# and the failure arrives one deploy AFTER the change that caused it — the migration
# succeeds, then the app 500s on a table it has no privilege for.
#
# `owner` is the migrator because default privileges attach to the role that CREATES
# the object, not to the one being granted.
resource "postgresql_default_privileges" "app_tables" {
  count       = local.has_pg ? 1 : 0
  database    = local.pg_name
  role        = local.pg_name
  owner       = local.pg_migrator
  schema      = "public"
  object_type = "table"
  privileges  = ["SELECT", "INSERT", "UPDATE", "DELETE"]

  depends_on = [postgresql_grant.app_schema_usage]
}

resource "postgresql_default_privileges" "app_sequences" {
  count       = local.has_pg ? 1 : 0
  database    = local.pg_name
  role        = local.pg_name
  owner       = local.pg_migrator
  schema      = "public"
  object_type = "sequence"
  privileges  = ["USAGE", "SELECT"]

  depends_on = [postgresql_grant.app_schema_usage]
}

resource "postgresql_role" "app" {
  count = local.has_pg ? 1 : 0
  name  = local.pg_name
  login = true

  # §8 — RDS IAM authentication. No password exists, so there is nothing to
  # store, nothing to rotate, and nothing to get wrong on the next 2026-09-06.
  roles = ["rds_iam"]

  # ── MANAGED HERE, NOT IN role_settings_sql, AND THAT IS A BUG FIX ───────────
  #
  # The note below says the provider "has NO resource for role settings". True of
  # idle_in_transaction_session_timeout; NOT true of these two — `postgresql_role`
  # has had both for some time.
  #
  # Emitting them as SQL did something worse than duplicate them. It wrote
  # `statement_timeout = '30s'`, and the provider reads that attribute back as an
  # INTEGER of milliseconds, so every later plan or apply of the consuming stack
  # failed before doing anything at all:
  #
  #     Error: error reading statement_timeout: strconv.Atoi: parsing "30s": invalid syntax
  #
  # The apply that installed the guard was the apply that broke the stack. Setting it
  # natively keeps state and reality in agreement, in a form the provider can read.
  #
  # 30000ms IS §5d's 30s — milliseconds are the provider's unit, not a new value.
  statement_timeout = 30000
  connection_limit  = 40
}

resource "postgresql_role" "migrator" {
  count = local.has_pg ? 1 : 0
  name  = local.pg_migrator
  login = true
  roles = ["rds_iam"]

  # The long fuse §4 sets deliberately: 600s, because the default kills a slow
  # migration part-way, which is the worst possible moment. Same unit note as above.
  statement_timeout = 600000

  # ── CREATEROLE, BECAUSE THE SCHEMA HISTORY CREATES ROLES ────────────────────
  #
  # A migration history has to replay in full on an empty database, and rova's does
  # this at 0068:
  #
  #     CREATE ROLE rally_app NOLOGIN;
  #
  # so a migrator without CREATEROLE cannot reach the current schema at all:
  #
  #     error: permission denied to create role   (routine: CreateRole)
  #
  # On an existing database this never surfaces — the migration ran years of deploys
  # ago — so it appears only when a NEW environment is built, which is exactly when a
  # migration failure is most expensive.
  #
  # This is narrower than it sounds. CREATEROLE lets the migrator manage roles; it does
  # NOT grant superuser, and on RDS it cannot escalate to `rds_superuser`. The
  # alternative — running migrations as the master user — is the stored admin credential
  # §8 exists to remove.
  create_role = true
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
  # ONLY what the provider cannot express. statement_timeout and CONNECTION LIMIT
  # moved onto the postgresql_role resources above — emitting them here wrote
  # `'30s'`, which the provider could not read back as an integer, and every
  # subsequent apply of the consuming stack then failed before doing anything.
  # What remains genuinely has no attribute.
  role_settings_sql = local.has_pg ? join("\\n", [
    "-- §5d — bounds a noisy neighbour on the shared instance. Idempotent.",
    "ALTER ROLE ${local.pg_name} SET idle_in_transaction_session_timeout = '60s';",
    "",
    "-- The migrator holds a transaction open for the length of a migration, so it",
    "-- must NOT be reaped for idling inside one.",
    "ALTER ROLE ${local.pg_migrator} SET idle_in_transaction_session_timeout = '0';",
  ]) : ""
}

resource "postgresql_extension" "this" {
  for_each = local.has_pg ? toset(var.postgres.extensions) : []
  name     = each.value
  database = local.pg_name
}

# ─────────────────────────────────────────────────────────────────────────────
# Cache — §5d. Nothing is created: one instance per environment already exists,
# and this product gets an INDEX on it.
# ─────────────────────────────────────────────────────────────────────────────

# The only thing to enforce is that asking for the cache and not wiring it is a
# PLAN failure rather than a `redis://:6379/0` that resolves to nothing at
# runtime. `terraform_data` holds the precondition because there is no resource
# for it to hang off — which is itself the honest shape of "grants access".
resource "terraform_data" "cache_contract" {
  count = local.has_cache ? 1 : 0
  input = local.cache_urls

  lifecycle {
    precondition {
      condition     = var.shared_cache.host != ""
      error_message = "cache.mode = \"shared\" needs shared_cache.host. §5d keeps ONE instance per environment and this module does not create one — pass the endpoint from the data stack."
    }
    precondition {
      # An empty map is the silent version of the same mistake: the plan succeeds,
      # `cache_urls` is `{}`, and nothing says the product asked for a cache it
      # cannot reach.
      condition     = length(var.shared_cache.db_indexes) > 0
      error_message = "cache.mode = \"shared\" needs at least one entry in shared_cache.db_indexes. §5d allocates by USE — see the data stack's cache_host output for which index belongs to this product."
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Secrets — containers only, created EMPTY (§8)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "app" {
  # checkov:skip=CKV2_AWS_57: §13 — these are REGENERATED, not rotated. A Grafana
  #   token or an R2 key is re-minted at its source; automatic rotation needs a
  #   Lambda that knows how to mint each one, which is more moving parts than the
  #   thing it protects. §8's inventory records provenance instead.
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

  # ── DISCOVERY, WITHOUT WHICH THE WILDCARD ABOVE IS UNUSABLE ─────────────────
  #
  # The statement above grants the right to READ a secret whose name you already
  # know. ESO does not know the names: the chart says `dataFrom.find.path`, which is
  # how one policy covers a growing set of secrets — the whole point of the
  # hierarchical path. Resolving a path into names is `ListSecrets`, and reading the
  # results is `BatchGetSecretValue`.
  #
  # Neither was granted, so every ExternalSecret in every product namespace failed
  # with `AccessDeniedException` on BatchGetSecretValue while the SecretStore itself
  # reported `Valid` — validation proves reachability, never a read.
  #
  # `*` IS NOT A WIDENING OF READ SCOPE, which is worth stating precisely because it
  # looks like one. Neither action supports resource-level permissions, so AWS
  # requires `*`. BatchGetSecretValue then evaluates GetSecretValue per returned
  # secret against the statement above, so the set this role can actually read stays
  # exactly `${local.secret_prefix}/*`. ListSecrets does reveal that other secrets
  # EXIST, names only — that is the real cost, and it is small.
  dynamic "statement" {
    for_each = length(var.secrets) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["secretsmanager:ListSecrets", "secretsmanager:BatchGetSecretValue"]
      resources = ["*"]
    }
  }

  # ── AND THE KEY THEY ARE ENCRYPTED WITH ─────────────────────────────────────
  #
  # These secrets are created with `kms_key_id` set (see aws_secretsmanager_secret
  # above), so a read also needs kms:Decrypt. Without it GetSecretValue fails with an
  # AccessDenied that names KMS rather than Secrets Manager — an error that sends you
  # to the wrong policy.
  #
  # `kms:ViaService` confines the grant to decryption performed BY Secrets Manager on
  # this role's behalf, so it cannot decrypt anything else under the same key by any
  # other route.
  dynamic "statement" {
    for_each = length(var.secrets) > 0 && var.kms_key_arn != "" ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_arn]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.region}.amazonaws.com"]
      }
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
        # THE MIGRATOR AUTHENTICATES AS A DIFFERENT DATABASE USER. §5d creates two
        # roles precisely so DDL and runtime are separate; granting only the runtime
        # one meant the migrator Job could not connect at all, failing with
        # `PAM authentication failed for user "<product>_migrator"` — a message that
        # names neither IAM nor the grant it is missing.
        "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:*/${coalesce(each.value.uses_migrator_db_role, each.key == "migrator") ? local.pg_migrator : local.pg_name}",
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
