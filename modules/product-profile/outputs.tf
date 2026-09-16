output "irsa_role_arns" {
  value       = { for k, r in aws_iam_role.service : k => r.arn }
  description = <<-EOT
    One ARN per service. The chart does NOT consume this — it derives the same
    string from product, env and service name (§7c), so nothing crosses the
    repository boundary. It is emitted for humans and for `tofu output` when
    something does not assume and the question is which name actually exists.
  EOT
}

output "secret_prefix" {
  value       = local.secret_prefix
  description = "qnsc/<env>/<product> — the path the ExternalSecret and the IAM wildcard both use."
}

output "postgres_endpoint" {
  value       = local.dedicated ? module.rds[0].endpoint : var.shared_postgres.host
  description = <<-EOT
    Where PgBouncer connects. Applications never see this: the chart points them
    at `pgbouncer:6432` in-namespace, and PgBouncer holds the real endpoint from
    the same secret (§5d).
  EOT
}

output "postgres_roles" {
  value = local.has_pg ? {
    app      = local.pg_name
    migrator = local.pg_migrator
  } : null
  description = "Two roles, never one — §5d. The 30s app timeout would kill the 600s migration."
}

output "role_settings_sql" {
  value       = local.role_settings_sql
  description = <<-EOT
    APPLY THIS. The postgresql provider cannot express role settings, so the module
    emits them instead of pretending. Run it alongside the product's migrations;
    it is idempotent.

    Until it runs, nothing bounds a noisy neighbour on the shared instance (§5).
  EOT
}

output "queue_urls" {
  value       = length(var.queue.sqs) > 0 ? module.messaging[0].queue_urls : {}
  description = "For humans. The chart derives these from the naming convention (§7c)."
}
