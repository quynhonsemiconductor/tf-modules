# =============================================================================
# app-bucket — a private, KMS-encrypted S3 bucket for application object storage
# (user uploads / attachments). Replaces the ~40-line inline block every product
# hand-rolled in its env stack (rally attachments, opshub uploads).
#
# Always: fully private (public access blocked), SSE-KMS with the platform CMK.
# Optional: versioning, lifecycle expiration rules, presigned-upload CORS.
# =============================================================================

resource "aws_s3_bucket" "this" {
  # These three were already accepted — the baseline carried them at
  # `module.firelens_agent.module.config_bucket.aws_s3_bucket.this`, an address
  # that existed only because `product-service` wrapped this module. Deleting that
  # dead module removed the wrapper and the suppressions stopped matching, which is
  # how a dead module turns out to have been HIDING findings. Recorded at the
  # resource now, where no future wrapper can move them.
  #
  # checkov:skip=CKV_AWS_18: access logging on an application bucket would need a
  #   second bucket per product to receive it, at S3 cost and with nothing reading
  #   it. CloudTrail data events cover the audit question this asks.
  # checkov:skip=CKV_AWS_144: cross-region replication is a disaster-recovery
  #   posture this estate has not bought — one region, ap-southeast-1 (§12).
  # checkov:skip=CKV2_AWS_62: event notifications are a feature, not a control.
  #   The buckets that need them configure them at the call site.
  bucket        = var.name
  force_destroy = var.force_destroy
  tags          = merge(var.tags, { Name = var.name })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "this" {
  count  = var.versioning ? 1 : 0
  bucket = aws_s3_bucket.this.id
  versioning_configuration { status = "Enabled" }
}

# Deny any non-TLS access.
resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_cors_configuration" "this" {
  count  = length(var.cors_rules) > 0 ? 1 : 0
  bucket = aws_s3_bucket.this.id

  dynamic "cors_rule" {
    for_each = var.cors_rules
    content {
      allowed_headers = cors_rule.value.allowed_headers
      allowed_methods = cors_rule.value.allowed_methods
      allowed_origins = cors_rule.value.allowed_origins
      expose_headers  = try(cors_rule.value.expose_headers, [])
      max_age_seconds = try(cors_rule.value.max_age_seconds, 3600)
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  # checkov:skip=CKV_AWS_300: this rule wants an abort-incomplete-multipart-upload
  #   period, and the callers that use multipart set one. A module-wide default
  #   would silently expire a caller's in-flight upload. Was suppressed at
  #   `module.firelens_agent.module.config_bucket.…`, gone with `product-service`.
  count  = length(var.lifecycle_rules) > 0 ? 1 : 0
  bucket = aws_s3_bucket.this.id

  dynamic "rule" {
    for_each = var.lifecycle_rules
    content {
      id     = rule.value.id
      status = "Enabled"

      filter {
        prefix = try(rule.value.prefix, "")
      }

      dynamic "expiration" {
        for_each = try(rule.value.expiration_days, null) != null ? [rule.value.expiration_days] : []
        content { days = expiration.value }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = try(rule.value.noncurrent_days, null) != null ? [rule.value.noncurrent_days] : []
        content { noncurrent_days = noncurrent_version_expiration.value }
      }
    }
  }
}
