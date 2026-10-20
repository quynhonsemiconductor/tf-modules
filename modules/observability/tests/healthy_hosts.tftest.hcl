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
  alb_arn          = "arn:aws:elasticloadbalancing:ap-southeast-1:123456789012:loadbalancer/app/shared/abc123"
  target_group_arns = {
    api = "arn:aws:elasticloadbalancing:ap-southeast-1:123456789012:targetgroup/api/def456"
  }
}

# No input: no healthy-host alarm, so existing callers plan unchanged.
run "default_creates_none" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.healthy_hosts_below_desired) == 0
    error_message = "healthy-host alarm must not exist unless target_group_min_healthy is set"
  }
}

# Desired count 2 => alarm below 2 healthy hosts, on the ALB target group dimension.
run "desired_count_sets_floor" {
  command = plan

  variables {
    target_group_min_healthy = {
      api = 2
    }
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.healthy_hosts_below_desired["api"].threshold == 2
    error_message = "threshold must equal the desired count, got ${aws_cloudwatch_metric_alarm.healthy_hosts_below_desired["api"].threshold}"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.healthy_hosts_below_desired["api"].comparison_operator == "LessThanThreshold"
    error_message = "healthy-host alarm must fire below the floor"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.healthy_hosts_below_desired["api"].treat_missing_data == "breaching"
    error_message = "missing datapoints must breach: an empty target group is the outage"
  }
}

# An idle environment has zero tasks by design: no alarm.
run "idle_environment_creates_none" {
  command = plan

  variables {
    environment_idle = true
    target_group_min_healthy = {
      api = 2
    }
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.healthy_hosts_below_desired) == 0
    error_message = "environment_idle must switch off the healthy-host alarm"
  }
}
