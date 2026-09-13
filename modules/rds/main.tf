# =============================================================================
# rds — PostgreSQL on RDS. Uses the RDS-managed master password (auto-rotated
# in Secrets Manager, never in tfstate). Optional query-stats parameter group
# and enhanced monitoring.
# =============================================================================

locals {
  # One list, used by both the instance's export setting and the log groups below, so
  # adding a log type cannot enable the export while leaving its group unmanaged.
  exported_logs = ["postgresql", "upgrade"]
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.identifier}-db"
  subnet_ids = var.subnet_ids
  tags       = merge(var.tags, { Name = "${var.identifier}-db" })
}

# Optional parameter group: pg_stat_statements + query/connection logging.
resource "aws_db_parameter_group" "this" {
  count  = var.enable_parameter_group ? 1 : 0
  name   = "${var.identifier}-pg${var.engine_version}"
  family = "postgres${var.engine_version}"

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot" # static parameter — can't be applied immediately
  }
  parameter {
    name  = "log_min_duration_statement"
    value = tostring(var.log_min_duration_ms)
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  tags = var.tags
}

# Enhanced monitoring role (only when monitoring_interval > 0).
resource "aws_iam_role" "enhanced_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0
  name  = "${var.identifier}-rds-enhanced-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "enhanced_monitoring" {
  count      = var.monitoring_interval > 0 ? 1 : 0
  role       = aws_iam_role.enhanced_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "this" {
  identifier     = var.identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn != "" ? var.kms_key_arn : null

  db_name  = var.db_name
  username = var.master_username
  # RDS-managed master password: auto-rotated in Secrets Manager, never in state.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = var.enable_parameter_group ? aws_db_parameter_group.this[0].name : null
  publicly_accessible    = false

  multi_az            = var.multi_az
  deletion_protection = var.deletion_protection

  backup_retention_period = var.backup_retention_days
  backup_window           = "03:00-04:00" # UTC
  maintenance_window      = "Mon:04:30-Mon:06:00"

  # WAS HARDCODED `true` until 2026-09-12, with no way for a caller to opt out. Exposed as a
  # variable because the blast radius depends on something this module cannot see: whether
  # the instance is Multi-AZ.
  #
  # On a Multi-AZ instance AWS applies a minor upgrade to the standby, fails over, then
  # upgrades the old primary — a brief connection reset. On a SINGLE-AZ instance there is no
  # standby, so the only instance restarts inside the maintenance window above. Every
  # production database in this org is currently `multi_az = false` (a documented cost
  # decision), which means automatic minor upgrades are unattended restarts of the only copy.
  #
  # The default stays `true`, so this change is a no-op for every existing caller and the
  # plan is empty. It exists so a caller running single-AZ production can make the tradeoff
  # deliberately rather than inherit it.
  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  apply_immediately          = false
  copy_tags_to_snapshot      = true

  performance_insights_enabled          = true
  performance_insights_retention_period = 7 # free tier

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.enhanced_monitoring[0].arn : null

  # The log groups these land in are managed below — see aws_cloudwatch_log_group.logs.
  enabled_cloudwatch_logs_exports = local.exported_logs

  # Dev (deletion_protection=false) skips the final snapshot for clean teardown.
  # Prod takes a final snapshot by default. skip_final_snapshot can be forced
  # true at teardown (via -var) to bypass a stale "<id>-final" snapshot that a
  # prior partial/failed destroy left behind (that collision blocked a teardown
  # in practice) — cheaper/safer than the module hardcoding the behavior.
  skip_final_snapshot       = var.skip_final_snapshot != null ? var.skip_final_snapshot : !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.identifier}-final" : null

  tags = merge(var.tags, { Name = var.identifier })
}


# ── Retention for the exported log groups ────────────────────────────────────
# RDS creates `/aws/rds/instance/<id>/<type>` ITSELF, on first write, with retention
# unset — and Terraform does not own what it did not create, so nothing ever corrected
# it. Measured across this organisation before this resource existed: three instances,
# three different answers, none of them in code.
#
#     /aws/rds/instance/qnsc-kb-develop/postgresql    None   (never expires)
#     /aws/rds/instance/rally-develop/postgresql      7      (set by hand)
#     /aws/rds/instance/rally-prod/postgresql         90     (set by hand)
#
# Declaring the group here makes RDS write into an existing group rather than create one,
# so retention is a decision in a diff instead of whatever a console click left behind.
#
# ⚠ AN EXISTING INSTANCE NEEDS A ONE-TIME IMPORT. RDS already made these groups, so a
# first apply against a live instance fails with ResourceAlreadyExistsException. Import
# each one before applying — the module cannot do this for you, because `import` blocks
# are only valid in a root module:
#
#     tofu import 'module.stack.module.rds.aws_cloudwatch_log_group.logs["postgresql"]' \
#       /aws/rds/instance/<identifier>/postgresql
#     tofu import 'module.stack.module.rds.aws_cloudwatch_log_group.logs["upgrade"]' \
#       /aws/rds/instance/<identifier>/upgrade
#
# The `upgrade` group may not exist yet on an instance that has never been upgraded —
# in that case skip its import and let the apply create it.
#
# NOT `depends_on` the instance, deliberately: the group must exist BEFORE RDS first
# writes, or RDS creates its own and this resource collides with it on the next apply.
resource "aws_cloudwatch_log_group" "logs" {
  #checkov:skip=CKV_AWS_158:CloudWatch Logs encrypts a group by assuming the CALLER's grant on the key, so the key policy must allow logs.<region>.amazonaws.com with a kms:EncryptionContext:aws:logs:arn condition. The product CMK is written for RDS, ECR and Secrets Manager and grants Logs nothing — v2.1.0 set kms_key_id here and every apply failed with "AccessDeniedException: The specified KMS key does not exist or is not allowed to be used", AFTER creating the group, leaving the apply half-done. No log group in this account uses a CMK; the ecs-service groups are suppressed for the same check. Encrypting these needs a deliberate key-policy change across the organisation, not a flag on one module.
  #checkov:skip=CKV_AWS_338:The check wants a year, for compliance retention. These are slow-query and upgrade logs, read when diagnosing something that already happened — 30 days covers that, and a year of a develop database's logs is storage nobody reads. The retention is now a decision in code (var.log_retention_days) rather than the "never expires" RDS leaves behind, which is what this resource exists to fix; a caller with a real retention obligation raises it.
  for_each = toset(local.exported_logs)

  name              = "/aws/rds/instance/${var.identifier}/${each.value}"
  retention_in_days = var.log_retention_days

  # NO kms_key_id, and that is deliberate rather than an omission.
  #
  # Setting it to the product CMK looked obviously right — the instance and its
  # snapshots use that key — and it broke the first apply:
  #
  #   Error: associating CloudWatch Logs Log Group (/aws/rds/instance/<id>/postgresql)
  #   KMS key: AccessDeniedException: The specified KMS key does not exist or is not
  #   allowed to be used with Arn 'arn:aws:logs:...:log-group:/aws/rds/instance/...'
  #
  # CloudWatch Logs encrypts a group by assuming the caller's grant on the key, so the
  # KEY POLICY must allow logs.<region>.amazonaws.com with an
  # kms:EncryptionContext:aws:logs:arn condition. The product CMK is written for RDS,
  # ECR and Secrets Manager and grants Logs nothing, so the association is refused —
  # after the group already exists, leaving the apply half-done.
  #
  # No log group in this organisation uses a CMK today, so adding one here would have
  # made this module the odd one out AND required a key-policy change nobody asked for.
  # CloudWatch Logs is encrypted at rest with an AWS-managed key regardless.

  tags = merge(var.tags, { Name = "/aws/rds/instance/${var.identifier}/${each.value}" })
}
