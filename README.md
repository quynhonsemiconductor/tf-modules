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

### Cloudflare / on-prem

| Module | Latest | Pin | Purpose |
| :----- | :----- | :-- | :------ |
| [`cf-edge`](modules/cf-edge) | `v2.0.0` | `cf-edge-v2.0.0` | Cloudflare zone/edge wiring for the on-prem estate |
| [`cf-r2`](modules/cf-r2) | `v2.0.0` | `cf-r2-v2.0.0` | R2 bucket + lifecycle for image/asset delivery |
| [`cloudflare-turnstile`](modules/cloudflare-turnstile) | `v2.0.0` | `cloudflare-turnstile-v2.0.0` | Turnstile widget/secret wiring |
| [`dns-record`](modules/dns-record) | `v2.0.0` | `dns-record-v2.0.0` | Single Cloudflare DNS record (proxied-aware) |
| [`pages-web`](modules/pages-web) | `v2.0.0` | `pages-web-v2.0.0` | Cloudflare Pages project + custom domain (landing sites) |
| [`observability-agent`](modules/observability-agent) | `v1.1.0` | `observability-agent-v1.1.0` | OpenTelemetry Collector sidecar container definition (kept for the legacy ECS path until it is retired) |

The AWS modules (`app-bucket`, `cache`, `ecr`, `ecs-cluster`, `ecs-service`, `iam-oidc`, `messaging`,
`oneshot-task`, `rds`, `secrets`, `observability`, `product-profile`) were deleted on 2026-11-04 with
the AWS exit. Their tags remain resolvable in git history; nothing in the org pins them.

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

---

## Versioning

Each module is versioned **independently** with a prefixed tag:
`dns-record-v1.0.0`, `cf-r2-v1.1.0`, etc. This lets a product adopt a new `dns-record`
without being forced to take a new `cf-r2`.

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
