# tf-modules

Shared, versioned OpenTofu/Terraform modules for all QNSC products.

This is the infrastructure counterpart to [`ci`](https://github.com/quynhonsemiconductor/ci)
(shared CI actions): reusable Terraform building blocks live here once, are
versioned per module, and are consumed by every product's `*-infra` repo. Fixes
and improvements made here propagate to all products on their next version bump —
no copy-paste drift.

---

## Module catalog

The canonical list of shared modules, their **current version**, and the pin to
use. Bump a consumer by changing its `?ref=<module>-vX.Y.Z`.

> **This table is the source of truth for the version to pin.** When a module is
> re-tagged, update its **Latest** here in the same PR. If the table and the git
> tags disagree, the git tags win — but that's a bug to fix here.

### Core infrastructure

| Module | Latest | Pin | Purpose |
| :----- | :----- | :-- | :------ |
| [`rds`](modules/rds) | `v1.1.0` | `rds-v1.1.0` | PostgreSQL, RDS-managed password, Perf Insights, param group, enhanced monitoring |
| [`cache`](modules/cache) | `v1.0.0` | `cache-v1.0.0` | Valkey ElastiCache: serverless (prod) or node (dev cost mode) |
| [`ecs-cluster`](modules/ecs-cluster) | `v1.0.0` | `ecs-cluster-v1.0.0` | ECS cluster + Fargate capacity providers + Container Insights |
| [`ecs-service`](modules/ecs-service) | `v1.1.0` | `ecs-service-v1.1.0` | Fargate service: task def, IAM, ALB, circuit breaker, CPU+mem autoscaling |
| [`ecr`](modules/ecr) | `v1.1.0` | `ecr-v1.1.0` | ECR repositories + lifecycle + optional repo policy |
| [`messaging`](modules/messaging) | `v1.0.0` | `messaging-v1.0.0` | Data-driven SQS (DLQs) + SNS topics + subscriptions |
| [`app-bucket`](modules/app-bucket) | `v1.0.0` | `app-bucket-v1.0.0` | Private KMS-encrypted S3 bucket (app uploads) with TLS-only policy |
| [`pages-web`](modules/pages-web) | `v1.0.0` | `pages-web-v1.0.0` | Cloudflare Pages project + custom domain (SPA hosting — replaced S3+CloudFront) |
| [`dns-record`](modules/dns-record) | `v1.0.0` | `dns-record-v1.0.0` | Single Cloudflare DNS record (proxied-aware) |

### Security & access

| Module | Latest | Pin | Purpose |
| :----- | :----- | :-- | :------ |
| [`iam-oidc`](modules/iam-oidc) | `v3.0.1` | `iam-oidc-v3.0.1` | GitHub OIDC deploy roles (per-env, ecr-push, infra plan/apply, apply guardrail) |
| [`secrets`](modules/secrets) | `v1.0.0` | `secrets-v1.0.0` | Secrets Manager (empty secrets) + SSM Parameter Store |

### Operations & cost

| Module | Latest | Pin | Purpose |
| :----- | :----- | :-- | :------ |
| [`observability`](modules/observability) | `v1.0.0` | `observability-v1.0.0` | CloudWatch alarms (ECS/ALB/RDS) + SNS + dashboard |
| [`oneshot-task`](modules/oneshot-task) | `v1.0.0` | `oneshot-task-v1.0.0` | Generic one-shot Fargate task def (DB migrator/backfill) |

> **Updating versions:** update the **Latest** column above in the same PR that
> re-tags a module. [Renovate](https://docs.renovatebot.com/) then opens bump PRs
> in consumer repos (they carry a `renovate.json`) so products pick up the new pin.

---

## Usage

Reference a module by git source pinned to a **per-module version tag**:

```hcl
module "dns_record" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/dns-record?ref=dns-record-v1.0.0"
  # ... inputs
}
```

> **⚠ `product-profile`: pin `product-profile-v0.9.0` or newer (2026-10-21).**
> The `v0.2.0`–`v0.8.0` tags were cut from commits dated 2026-09-22/23 (verified:
> `ec2491f`, `3e8efba`, `29fa5da`, `c1118fe`) while their changelog entries are dated
> 2026-10-13..20 — the tagged commits do not contain what the changelogs describe.
> `product-profile-v0.9.0` (cut by release-please after #171) is the first tag whose
> commit matches its changelog. Existing tags are left untouched; do not pin below 0.9.0.
>
> **Pin to a tag** (`?ref=dns-record-v1.0.0`) in committed environments. Use `?ref=main`
> only for testing on a branch. Upgrades should be deliberate.

---

## Versioning

Each module is versioned **independently** with a prefixed tag:
`dns-record-v1.0.0`, `ecs-service-v1.1.0`, etc. This lets a product adopt a new `dns-record`
without being forced to take a new `rds`.

- Backward-compatible additions → minor bump (`dns-record-v1.1.0`)
- Breaking input/output changes → major bump (`dns-record-v2.0.0`)

---

## Contributing

- One module per directory under `modules/`.
- Every module declares its own `versions.tf` (provider/version constraints) and
  carries a `README.md` documenting inputs/outputs.
- CI runs `tofu fmt -check`, `tofu validate`, and `tflint` on every PR.
- Changes require review (see [`CODEOWNERS`](.github/CODEOWNERS)).
- After merge, tag the module: `git tag <module>-vX.Y.Z && git push origin <module>-vX.Y.Z`.

---

## License

Proprietary and confidential. © QNSC — Quy Nhon Semiconductor. See [`LICENSE`](./LICENSE).
