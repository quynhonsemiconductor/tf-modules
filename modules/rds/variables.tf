variable "identifier" {
  type        = string
  description = "DB instance identifier."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Data-tier subnet IDs for the DB subnet group."
}

variable "security_group_id" {
  type        = string
  description = "Security group for the DB instance."
}

variable "engine_version" {
  type        = string
  default     = "17"
  description = "Postgres major version (e.g. \"17\", \"18\")."
}

variable "auto_minor_version_upgrade" {
  type        = bool
  default     = true
  description = <<-EOT
    Let AWS apply Postgres MINOR upgrades during `maintenance_window`.

    `true` (the default, and the previously hardcoded behaviour) keeps you on supported patch
    levels without anyone remembering to act, which is the right default for most callers.

    Set it FALSE when the instance is single-AZ AND serves production. With `multi_az = true`
    AWS upgrades the standby and fails over, so the impact is a connection reset; with
    `multi_az = false` there is no standby, so the only instance restarts unattended inside
    the maintenance window. Turning this off makes patching a scheduled human action instead
    — which is only an improvement if someone actually schedules it, so record the owner.
  EOT
}

variable "instance_class" {
  type        = string
  description = "RDS instance class (e.g. db.t4g.medium, db.r7g.large)."
}

variable "allocated_storage_gb" {
  type    = number
  default = 20
}

variable "max_allocated_storage_gb" {
  type    = number
  default = 100
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "skip_final_snapshot" {
  type        = bool
  default     = null
  description = <<-EOT
    Override the final-snapshot behavior. Leave null (default) to derive it from
    deletion_protection (dev skips, prod snapshots). Set true at teardown time
    (tofu destroy -var 'skip_final_snapshot=true') to bypass a stale
    "<identifier>-final" snapshot left by a prior failed/partial destroy.
  EOT
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "db_name" {
  type    = string
  default = "app"
}

variable "master_username" {
  type    = string
  default = "app_admin"
}

variable "kms_key_arn" {
  type        = string
  default     = ""
  description = "CMK ARN for storage encryption. Empty uses the AWS-managed key."
}

variable "monitoring_interval" {
  type        = number
  default     = 0
  description = "Enhanced Monitoring interval in seconds (0 = disabled; 60 recommended in prod)."
}

variable "enable_parameter_group" {
  type        = bool
  default     = true
  description = "Create a parameter group with pg_stat_statements + query/connection logging."
}

variable "apply_immediately" {
  type    = bool
  default = false

  description = <<-EOT
    Apply modifications at once instead of queueing them for the maintenance window.

    `false` (the default) is correct for production: a resize or parameter change waits for
    `Mon:04:30-Mon:06:00` rather than restarting the instance under load.

    It is the wrong default for develop, and quietly so. With `false`, OpenTofu reports an
    apply as SUCCESSFUL while AWS holds the change in `PendingModifiedValues` — so state,
    plan and reality disagree and nothing surfaces it. qnsc-kb-develop was resized on
    2026-09-14 and was still running the old instance class afterwards; the only way to see
    that was `describe-db-instances`.

    Set `true` where a restart is free. Leave `false` where it is not.
  EOT
}

variable "snapshot_identifier" {
  type    = string
  default = null

  description = <<-EOT
    Restore this instance FROM an existing snapshot instead of creating an empty database.
    Identifier or ARN of a manual or automated DB snapshot. Null (the default) creates a new
    empty database, which is what every existing caller does.

    HONOURED ONLY AT CREATE TIME. The argument sits under `ignore_changes`, because the AWS
    provider marks it ForceNew: without that, bumping this to a newer snapshot — or clearing
    it once a restore is finished — would destroy and rebuild a live database as a side
    effect of editing a string. So this cannot retro-restore an existing instance; pair it
    with `tofu apply -replace=...` when a rebuild is genuinely intended.

    THE MASTER PASSWORD IS NOT PRESERVED. A restore keeps the password baked into the
    snapshot and arrives with no managed secret; this module sets
    `manage_master_user_password = true`, so the restored instance gets a BRAND NEW
    Secrets Manager secret with a NEW ARN. Every consumer of the old ARN must be reconciled
    in the same apply. The endpoint changes too — the host contains an instance-specific
    component, so `<id>.<something>.rds.amazonaws.com` is not stable across a rebuild.

    `username` and `db_name` come from the snapshot and cannot be overridden. Restoring an
    instance's own snapshot is therefore clean, since both already match; restoring one
    database's snapshot under another's config would leave a permanent diff.
  EOT
}
variable "log_min_duration_ms" {
  type        = number
  default     = 1000
  description = "Log statements slower than this (ms). Used by the parameter group."
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "log_retention_days" {
  type    = number
  default = 30

  description = <<-EOT
    CloudWatch retention for the log groups RDS creates from
    `enabled_cloudwatch_logs_exports` (postgresql, upgrade).

    WITHOUT THIS THEY NEVER EXPIRE. RDS creates `/aws/rds/instance/<id>/<type>` itself,
    on first write, with retention unset — and Terraform does not own a resource it did
    not create, so nothing ever corrected it. Measured across this organisation before
    the fix: three instances, three different answers, none of them in code.

        /aws/rds/instance/qnsc-kb-develop/postgresql    None   (never expires)
        /aws/rds/instance/rova-develop/postgresql      7      (set by hand)
        /aws/rds/instance/rova-prod/postgresql         90     (set by hand)

    Cheap to ignore and easy to miss: a develop database logs little, so the bill stays
    flat for a year and then is not flat. The point is less the money than that retention
    on a database's logs should be a decision someone made, in a diff.

    30 rather than the caller's application log retention: these are slow-query and
    upgrade logs, read when diagnosing something that already happened, so develop wants
    more than its 7-day application window while production needs no more than its 90.
  EOT
}
