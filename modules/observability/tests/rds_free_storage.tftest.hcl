# Plan-only checks with a mocked AWS provider: no credentials, no API calls.
mock_provider "aws" {
  override_resource {
    target = aws_sns_topic.alarms
    values = {
      arn = "arn:aws:sns:ap-southeast-1:123456789012:test-obs-alarms"
    }
  }
}

variables {
  name             = "test-obs"
  region           = "ap-southeast-1"
  ecs_cluster_name = "test-cluster"
  rds_instance_id  = "test-db"
}

# Existing callers pass no pct: the absolute floor is used, unchanged.
run "default_uses_absolute_floor" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.rds_storage[0].threshold == 2147483648
    error_message = "default free-storage threshold must stay 2 GiB, got ${aws_cloudwatch_metric_alarm.rds_storage[0].threshold}"
  }
}

# 20% of a 100 GiB volume is 20 GiB, in bytes.
run "pct_of_allocated_gib" {
  command = plan

  variables {
    rds_allocated_storage_gb = 100
    thresholds = {
      rds_free_storage_pct = 20
    }
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.rds_storage[0].threshold == 21474836480
    error_message = "20% of 100 GiB must be 21474836480 bytes, got ${aws_cloudwatch_metric_alarm.rds_storage[0].threshold}"
  }
}

# A percentage without the allocation is refused: CloudWatch has no allocated-storage metric to derive it from.
run "pct_without_allocation_refused" {
  command = plan

  variables {
    thresholds = {
      rds_free_storage_pct = 20
    }
  }

  expect_failures = [
    aws_cloudwatch_metric_alarm.rds_storage[0],
  ]
}

run "pct_above_100_refused" {
  command = plan

  variables {
    rds_allocated_storage_gb = 100
    thresholds = {
      rds_free_storage_pct = 120
    }
  }

  expect_failures = [
    aws_cloudwatch_metric_alarm.rds_storage[0],
  ]
}
