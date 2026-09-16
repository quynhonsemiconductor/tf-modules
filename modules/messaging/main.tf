# =============================================================================
# Messaging — data-driven SQS queues (with DLQs), SNS topics, and SNS→SQS
# subscriptions. The topology is supplied by the caller so each product
# expresses its own event architecture while sharing the hardened primitives
# (DLQ redrive, SSE, SNS-publish queue policy, KMS on SNS).
# =============================================================================

# ── Dead-letter queue per main queue ─────────────────────────────────────────
resource "aws_sqs_queue" "dlq" {
  for_each = var.queues

  name                      = "${var.prefix}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = merge(var.tags, { Name = "${var.prefix}-${each.key}-dlq", Role = "dlq" })
}

# ── Main queues ──────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "main" {
  for_each = var.queues

  name                       = "${var.prefix}-${each.key}"
  visibility_timeout_seconds = each.value.visibility_timeout
  message_retention_seconds  = 345600 # 4 days
  max_message_size           = 262144 # 256 KB
  receive_wait_time_seconds  = 20     # long polling
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.dlq_max_receive_count
  })

  tags = merge(var.tags, { Name = "${var.prefix}-${each.key}" })
}

# ── Queue policies: allow SNS topics under this prefix to publish ─────────────
#
# The account is pinned. `arn:aws:sns:*:*:<prefix>-*` matched a topic of that name
# in ANY AWS account, which is the confused-deputy shape checkov's CKV_AWS_168
# names: anyone able to create `qnsc-prod-rova-email-bounce` in their own account
# could publish into these queues. Nothing in this estate is cross-account, so
# pinning costs nothing and closes it.
data "aws_caller_identity" "current" {}

resource "aws_sqs_queue_policy" "main" {
  for_each = var.create_queue_policies ? aws_sqs_queue.main : {}

  queue_url = each.value.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowSNSPublish"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = each.value.arn
        Condition = {
          ArnLike = { "aws:SourceArn" = "arn:aws:sns:*:${data.aws_caller_identity.current.account_id}:${var.prefix}-*" }
        }
      }
    ]
  })
}

# ── SNS topics ───────────────────────────────────────────────────────────────
resource "aws_sns_topic" "events" {
  for_each = toset(var.topics)

  name              = "${var.prefix}-${each.key}"
  kms_master_key_id = var.kms_key_arn != "" ? var.kms_key_arn : "alias/aws/sns"

  tags = merge(var.tags, { Name = "${var.prefix}-${each.key}" })
}

# ── SNS → SQS subscriptions ──────────────────────────────────────────────────
resource "aws_sns_topic_subscription" "this" {
  for_each = { for s in var.subscriptions : "${s.topic}->${s.queue}" => s }

  topic_arn     = aws_sns_topic.events[each.value.topic].arn
  protocol      = "sqs"
  endpoint      = aws_sqs_queue.main[each.value.queue].arn
  filter_policy = each.value.filter_policy != "" ? each.value.filter_policy : null
}
