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
- `cache.mode = "shared"` composes `cache_urls` from `shared_cache` — one URL
  per USE, because §5d allocates by use and qnsc-kb holds two (broker, rate
  limiting) — and fails the plan when the wiring is missing. It creates nothing — §5d keeps one instance per
  environment — and there is no `dedicated`

### Not in the interface, and why

Three inputs sketched in the design are absent, because each would have promised
something the module cannot deliver:

- **`storage.r2_buckets`** — R2 is Cloudflare and `cf-r2` requires provider v5,
  while a root stack loads one Cloudflare major. Callers here are the data stacks,
  which load aws + postgresql. Buckets are declared in the Cloudflare stack; the
  name is derived on both sides (§7c) and the R2 token is a secret under the
  prefix this module already creates.
- **`services[*].needs_s3`** — there is no S3 in this estate (§7). A flag granting
  nothing reads in review as a grant that exists.
- **`vpc_id`** — nothing here takes one. `aws_db_subnet_group` is built from
  `subnet_ids`, the security group arrives created, and IAM, Secrets Manager and
  SQS are not VPC-scoped.

### Known limit

`role_settings_sql` is an OUTPUT, not applied. The `cyrilgdn/postgresql` provider
has no resource for role settings, and a `null_resource` shelling out to `psql`
fails in a way that leaves state disagreeing with reality. The caller applies it
alongside migrations. Revisit if the provider grows the resource.
