# =============================================================================
# cache — Valkey (Redis-compatible) on ElastiCache.
#
# Two modes:
#   mode = "serverless"  → ElastiCache Serverless. Auto-scaling, no node mgmt,
#                          but a ~$90/mo minimum floor. Good for prod.
#   mode = "node"        → a single cache.t4g.micro node (~$11/mo). Cheaper for
#                          dev; cannot auto-scale. NOTE: serverless can't be
#                          stopped, so use "node" in dev to actually save.
# =============================================================================

locals {
  serverless = var.mode == "serverless"
  node       = var.mode == "node"
}

# ── Serverless mode ───────────────────────────────────────────────────────────
resource "aws_elasticache_serverless_cache" "this" {
  count  = local.serverless ? 1 : 0
  engine = "valkey"
  name   = var.name

  cache_usage_limits {
    data_storage {
      maximum = var.max_data_storage_gb
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = var.max_ecpu_per_second
    }
  }

  daily_snapshot_time      = "04:30"
  snapshot_retention_limit = var.snapshot_retention_days

  subnet_ids         = var.subnet_ids
  security_group_ids = [var.security_group_id]
  kms_key_id         = var.kms_key_arn != "" ? var.kms_key_arn : null

  major_engine_version = var.engine_version

  tags = merge(var.tags, { Name = var.name })
}

# ── Node mode (single small node; cheaper for dev) ────────────────────────────
resource "aws_elasticache_subnet_group" "this" {
  count      = local.node ? 1 : 0
  name       = "${var.name}-subnets"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_elasticache_replication_group" "this" {
  count                = local.node ? 1 : 0
  replication_group_id = var.name
  description          = "Valkey cache (node mode) for ${var.name}"

  engine             = "valkey"
  engine_version     = var.node_engine_version
  node_type          = var.node_type
  num_cache_clusters = 1
  port               = 6379

  subnet_group_name  = aws_elasticache_subnet_group.this[0].name
  security_group_ids = [var.security_group_id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn != "" ? var.kms_key_arn : null

  snapshot_retention_limit = var.snapshot_retention_days
  snapshot_window          = "04:00-05:00"
  maintenance_window       = var.maintenance_window
  apply_immediately        = var.apply_immediately

  tags = merge(var.tags, { Name = var.name })
}
