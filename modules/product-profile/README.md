# `product-profile` module

Everything a product needs that **outlives a deploy**.

§7 of `kubernetes-platform-design.md` draws the line this module sits on: *"if it
outlives a deploy, OpenTofu owns it."* RDS, IRSA roles, Secrets Manager
containers, SQS queues and R2 buckets are here. Deployments, Services, HPAs, Jobs
and CronJobs belong to the chart in `gitops`. **No object is described in both.**

## The interface

Capabilities are a **set, each defaulting to absent** (§6). A product with no
database sets nothing and gets no RDS, no secret, no IAM grant, no alarms. Adding
OpenSearch later means one optional block here — not a second module, and not a
copy of the first.

```hcl
module "product" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/product-profile?ref=product-profile-v1.0.0"

  product = "kb"        # short slug — NOT qnsc-kb (§7c)
  env     = "prod"      # dev | prod — never develop/production (§7c)
  size    = "m"         # a CRITICALITY tier, not a resource size (§5)

  postgres = {
    mode       = "dedicated"      # none | shared | dedicated
    extensions = ["vector", "pgcrypto"]
  }
  queue   = { sqs = ["jobs"] }    # PURPOSES, not URLs
  secrets = ["database-url", "openrouter-key"]

  services = {
    api      = { needs_sqs = true }
    worker   = { needs_sqs = true }
    migrator = {}
  }

  oidc_provider_arn = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
  oidc_issuer       = data.terraform_remote_state.cluster.outputs.oidc_issuer
  subnet_ids        = data.terraform_remote_state.network.outputs.data_subnet_ids
  security_group_id = data.terraform_remote_state.network.outputs.db_sg_id
}
```

## Names are derived, never passed

The Helm chart computes the **identical** strings from the same three identity
variables (§7c), so nothing crosses the repository boundary and the two cannot
drift.

```
IRSA role      qnsc-prod-kb-api
secret path    qnsc/prod/kb/app/database-url    hierarchical, so the IAM policy
                                                is ONE wildcard rather than an
                                                enumeration edited on every addition
SQS queue      qnsc-prod-kb-jobs                + a dead-letter queue
```

`services` keys must match `services` in `gitops/values/<product>/base.yaml`. A
mismatch surfaces as a pod that cannot assume anything, which is a slow way to
find a typo — §7c's CI check catches it earlier.

## `size` is the one fact declared twice

It appears here and in `gitops/values/<product>/<env>.yaml`, and nothing else
does. CI fails when the two disagree (§7c). **Do not build a generator for it** —
generating Terraform from YAML or the reverse costs more than the problem.

## Two roles per product, never one

```
kb            statement_timeout 30s   ·  no DDL     the runtime role
kb_migrator   statement_timeout 600s  ·  DDL        matches the Job's deadline (§4)
```

§5d: the application role's 30s timeout would kill the 600s migrations §4 sets
deliberately, *"because the default will kill a slow migration part-way, which is
the worst possible moment."* Separating them also takes `CREATE`/`ALTER`/`DROP`
off the runtime role, so a compromised application cannot reshape its own schema.

Postgres identifiers take **underscores**: a role named `qnsc-kb` would need
double-quoting in every statement for the life of the database.

## ⚠ `role_settings_sql` must be applied

The `cyrilgdn/postgresql` provider has **no resource for role settings**, so this
module cannot apply `ALTER ROLE … SET statement_timeout`. The alternative was a
`null_resource` shelling out to `psql`, which needs network reachability and a
client binary inside whatever runs `tofu apply`, and fails in a way that leaves
state disagreeing with reality.

So the module **emits the SQL as an output** and the caller applies it alongside
the product's migrations. It is idempotent.

```bash
tofu output -raw role_settings_sql | psql "$ADMIN_URL"
```

**Until it runs, nothing bounds a noisy neighbour on the shared instance** (§5).
A missing timeout is a visible omission rather than a silently absent guard, which
is the whole reason it is an output rather than a comment.

## Shared or dedicated

§5 dedicates in **production only, where it is earned**:

```
rova      dedicated   the only product earning money
qnsc-kb   dedicated   pgvector, a ~16 GiB working set, a workload shape unlike
                      anything else in the estate
others    shared      opshub · lms · solodesk · ai-dev-kit
DEV       shared      with no exceptions
```

The decision is made on **restore granularity**, not cost — the gap is about
$40/month. RDS snapshots and PITR operate on an *instance*, so restoring opshub
would drag LMS, solodesk and ai-dev-kit back to the same moment. In dev that costs
nothing. In production it is what $40 does not buy back.

A product graduates by changing `mode` from `shared` to `dedicated`.

## What it does not create

```
the shared RDS instance   one per environment, owned by the platform stack
ElastiCache               one per environment (§5d). `cache.mode = "shared"`
                          creates nothing and there is no `dedicated`: Redis has
                          no IAM, so the whole grant is an endpoint and an index,
                          both passed in as `shared_cache`. What the flag buys is
                          `cache_url` and a plan that FAILS when a product asks
                          for the cache with no wiring
R2 buckets                `cf-r2`, from the Cloudflare stack. A root stack loads
                          one Cloudflare major and `cf-r2` needs v5, so asking
                          for a bucket here would pin every caller's Cloudflare
                          version to suit a module about databases. The bucket
                          NAME is derived on both sides (§7c) and the R2 token is
                          a secret under the prefix, so nothing is lost
the EKS cluster           the platform stack
DNS                       the chart renders HTTPRoutes; Cloudflare records are
                          the edge stack's
```

## Deletion

`deletion_protection` is on for `env = "prod"`, and `skip_final_snapshot` is
`false` everywhere.

§17b records why in one line: **one Terraform state owns both the database and,
today, the ECS services** — so `tofu destroy` run to remove ECS takes the database
with it. On 2026-09-14 that cost twelve minutes of downtime and four snapshots
taken for insurance.

Removing a product is §12c, and ECR is the part that bites: retention expires by
age, never by abandonment.
