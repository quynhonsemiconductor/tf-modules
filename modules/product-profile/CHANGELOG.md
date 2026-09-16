# Changelog — `product-profile`

## v1.0.0 — unreleased

First version. Replaces the compute-plus-data `stack` modules each product
carries today; §17b shrinks those to data-only rather than destroying them,
because one state owns both the database and the ECS services.

- capability set, each defaulting to absent (§6)
- `postgres.mode` — none | shared | dedicated. Dedicated in production only where
  earned; dev shared with no exceptions (§5)
- two Postgres roles per product: the 30s application timeout would kill the 600s
  migrations §4 sets deliberately (§5d)
- RDS IAM authentication via IRSA — no database password exists to rotate (§8)
- IRSA role per service, trust scoped to ONE ServiceAccount in ONE namespace
- Secrets Manager containers created empty, under a hierarchical path so the IAM
  policy is one wildcard (§8, §7c)
- SQS queues named by PURPOSE; the chart derives the URLs (§7c)

### Known limit

`role_settings_sql` is an OUTPUT, not applied. The `cyrilgdn/postgresql` provider
has no resource for role settings, and a `null_resource` shelling out to `psql`
fails in a way that leaves state disagreeing with reality. The caller applies it
alongside migrations. Revisit if the provider grows the resource.
