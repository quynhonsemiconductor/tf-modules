# `rds` module

PostgreSQL on RDS with the **RDS-managed master password** (auto-rotated in
Secrets Manager, never in tfstate), gp3 encrypted storage, Performance Insights,
optional query-stats parameter group, and optional enhanced monitoring.

## Usage

```hcl
module "rds" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/rds?ref=rds-v1.0.0"

  identifier        = "myproduct-prod"
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.sg_rds_id
  kms_key_arn       = local.kms_key_arn

  engine_version           = "17"
  instance_class           = "db.r7g.large"
  allocated_storage_gb     = 100
  max_allocated_storage_gb = 500
  multi_az                 = true
  deletion_protection      = true
  backup_retention_days    = 30
  monitoring_interval      = 60     # enhanced monitoring in prod

  tags = { Environment = "prod" }
}

# The app reads the DB password from:
#   module.rds.master_secret_arn   (RDS-managed Secrets Manager secret)
```

## Inputs (key)

| Name | Default | Description |
| :--- | :------ | :---------- |
| `identifier` | — | DB identifier |
| `engine_version` | `17` | Postgres major (`17`, `18`) or a full minor (`18.6`). The parameter group family is always the major |
| `allow_major_version_upgrade` | `false` | Permit a major change on an existing instance. One apply, then back to `false` |
| `instance_class` | — | e.g. db.r7g.large |
| `multi_az` / `deletion_protection` | `false` | Prod: true |
| `kms_key_arn` | `""` | Storage CMK (empty = AWS-managed) |
| `monitoring_interval` | `0` | Enhanced monitoring secs (60 in prod) |
| `enable_parameter_group` | `true` | pg_stat_statements + query logging |
| `log_min_duration_ms` | `1000` | Slow-query log threshold |

## Outputs

`endpoint`, `address`, `port`, `db_name`, `instance_id`, `instance_arn`,
`master_secret_arn`.

## Requirements

- OpenTofu / Terraform `>= 1.9.0`
- AWS provider `>= 5.0`
