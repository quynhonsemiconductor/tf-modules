# Plan-only checks with a mocked AWS provider: no credentials, no API calls.
mock_provider "aws" {
  # The module's outputs read master_user_secret[0] (computed by AWS), which a mock leaves empty.
  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:test", kms_key_id = "", secret_status = "active" }]
    }
  }
}

variables {
  identifier               = "test-db"
  subnet_ids               = ["subnet-aaaa1111", "subnet-bbbb2222"]
  security_group_id        = "sg-0123456789abcdef0"
  instance_class           = "db.t4g.micro"
  allocated_storage_gb     = 20
  max_allocated_storage_gb = 100
  multi_az                 = false
  deletion_protection      = false
  backup_retention_days    = 7
}

# Existing callers pass nothing: engine stays 17, family postgres17, major upgrade refused.
run "default_stays_pg17" {
  command = plan

  assert {
    condition     = aws_db_instance.this.engine_version == "17"
    error_message = "default engine_version must stay \"17\", got ${aws_db_instance.this.engine_version}"
  }

  assert {
    condition     = aws_db_parameter_group.this[0].family == "postgres17"
    error_message = "default parameter group family must be postgres17"
  }

  assert {
    condition     = aws_db_instance.this.allow_major_version_upgrade == false
    error_message = "allow_major_version_upgrade must default to false"
  }
}

# Opt-in: engine 18 gets the postgres18 family; the major upgrade is allowed only when asked for.
run "opt_in_pg18_with_upgrade" {
  command = plan

  variables {
    engine_version              = "18"
    allow_major_version_upgrade = true
    apply_immediately           = true
  }

  assert {
    condition     = aws_db_instance.this.engine_version == "18"
    error_message = "engine_version must be \"18\" when opted in"
  }

  assert {
    condition     = aws_db_parameter_group.this[0].family == "postgres18"
    error_message = "parameter group family must be postgres18 for engine 18"
  }

  assert {
    condition     = aws_db_instance.this.allow_major_version_upgrade == true
    error_message = "allow_major_version_upgrade must pass through when set"
  }

  assert {
    condition     = aws_db_instance.this.apply_immediately == true
    error_message = "apply_immediately must pass through when set"
  }
}

# A full minor (18.6) is accepted: the family and parameter group name stay per major.
run "minor_version_uses_major_family" {
  command = plan

  variables {
    engine_version             = "18.6"
    auto_minor_version_upgrade = false
  }

  assert {
    condition     = aws_db_instance.this.engine_version == "18.6"
    error_message = "engine_version \"18.6\" must reach aws_db_instance unchanged"
  }

  assert {
    condition     = aws_db_parameter_group.this[0].family == "postgres18"
    error_message = "a minor engine_version must still use the postgres18 family"
  }
}

# A full minor pins the minor: auto-minor on is refused by a precondition on the instance.
run "minor_with_auto_minor_is_refused" {
  command = plan

  variables {
    engine_version             = "18.6"
    auto_minor_version_upgrade = true
  }

  expect_failures = [aws_db_instance.this]
}

# A major upgrade without apply_immediately would sit in PendingModifiedValues: refused.
run "major_upgrade_needs_apply_immediately" {
  command = plan

  variables {
    engine_version              = "18"
    allow_major_version_upgrade = true
    apply_immediately           = false
  }

  expect_failures = [aws_db_instance.this]
}

# Only Postgres 16 to 19 are accepted.
run "unsupported_major_is_refused" {
  command = plan

  variables {
    engine_version = "15"
  }

  expect_failures = [var.engine_version]
}
