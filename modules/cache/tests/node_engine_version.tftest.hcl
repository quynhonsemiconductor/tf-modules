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

# Opt-in: node engine 8.2.
run "opt_in_valkey81" {
  command = plan

  variables {
    node_engine_version = "8.2"
  }

  assert {
    condition     = aws_elasticache_replication_group.this[0].engine_version == "8.2"
    error_message = "node_engine_version \"8.2\" must reach the replication group"
  }
}
