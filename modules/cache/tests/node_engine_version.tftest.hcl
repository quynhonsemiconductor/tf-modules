# Plan-only checks with a mocked AWS provider: no credentials, no API calls.
mock_provider "aws" {}

variables {
  name              = "test-cache"
  subnet_ids        = ["subnet-aaaa1111", "subnet-bbbb2222"]
  security_group_id = "sg-0123456789abcdef0"
  mode              = "node"
}

# Existing callers pass nothing: node engine stays 7.2.
run "default_stays_valkey72" {
  command = plan

  assert {
    condition     = aws_elasticache_replication_group.this[0].engine_version == "7.2"
    error_message = "default node_engine_version must stay \"7.2\", got ${aws_elasticache_replication_group.this[0].engine_version}"
  }
}

# Opt-in: node engine 8.1 (the Valkey 8 target, same as the local and CI images).
run "opt_in_valkey81" {
  command = plan

  variables {
    node_engine_version = "8.1"
  }

  assert {
    condition     = aws_elasticache_replication_group.this[0].engine_version == "8.1"
    error_message = "node_engine_version \"8.1\" must reach the replication group"
  }
}

# Apply timing and maintenance window reach the replication group.
run "apply_and_window_pass_through" {
  command = plan

  variables {
    node_engine_version = "8.1"
    apply_immediately   = true
    maintenance_window  = "sun:05:00-sun:06:00"
  }

  assert {
    condition     = aws_elasticache_replication_group.this[0].apply_immediately == true
    error_message = "apply_immediately must reach the replication group"
  }

  assert {
    condition     = aws_elasticache_replication_group.this[0].maintenance_window == "sun:05:00-sun:06:00"
    error_message = "maintenance_window must reach the replication group"
  }
}

# Only the Valkey lines the repo supports are accepted.
run "unsupported_valkey_is_refused" {
  command = plan

  variables {
    node_engine_version = "9.0"
  }

  expect_failures = [var.node_engine_version]
}
