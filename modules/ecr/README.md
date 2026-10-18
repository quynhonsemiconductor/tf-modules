# `ecr` module

ECR container repositories with a lifecycle policy (expire untagged, cap tagged)
and an optional repository policy granting pull/push to specified principals.

## Usage

```hcl
module "ecr" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/ecr?ref=ecr-v2.2.0"

  repository_names = ["myproduct-api", "myproduct-worker"]
  kms_key_arn      = local.kms_key_arn      # omit for AES256
  tags             = local.tags

  # Optional overrides (defaults shown):
  # image_tag_mutability   = "IMMUTABLE"
  # release_tag_prefix     = "v"
  # release_retention_days = 180
  # build_tag_prefix       = "sha-"
  # keep_build_count       = 10
  # untagged_expire_days   = 1
  # allowed_principal_arns = []   # set to create a repository policy
}
```

## Lifecycle policy

Three rules, in priority order (an image is governed by the lowest priority number that selects it):

1. untagged images older than `untagged_expire_days` expire;
2. `v*` release images older than `release_retention_days` expire (the production rollback window);
3. only the newest `keep_build_count` `sha-*` build images are kept.

A promoted image carries both a `sha-` and a `v` tag and is governed by rule 2, so trimming builds never removes a
release. Multi-architecture builds: the `sha-` tag is on the manifest list; the per-architecture images and the
attestations are untagged, are not counted by rule 3, and ECR does not expire an image that a manifest list still
references. **Preview before lowering any retention on a live repository** (`aws ecr start-lifecycle-policy-preview`).

## Inputs

| Name | Type | Default | Description |
| :--- | :--- | :------ | :---------- |
| `repository_names` | `list(string)` | — | Repositories to create |
| `image_tag_mutability` | `string` | `IMMUTABLE` | `IMMUTABLE` or `MUTABLE` |
| `kms_key_arn` | `string` | `""` | KMS key ARN (empty = AES256) |
| `release_tag_prefix` | `string` | `v` | Tag prefix of release images |
| `release_retention_days` | `number` | `180` | Delete release images older than this (rollback window) |
| `build_tag_prefix` | `string` | `sha-` | Tag prefix of per-commit build images |
| `keep_build_count` | `number` | `10` | Most-recent build images kept (was 20 before ecr-v2.2.0) |
| `untagged_expire_days` | `number` | `1` | Days before untagged images expire |
| `allowed_principal_arns` | `list(string)` | `[]` | Principals for repo policy (empty = no policy) |
| `force_delete` | `bool` | `false` | Allow deleting repositories that still hold images |
| `tags` | `map(string)` | `{}` | Tags applied to all repositories |

## Outputs

| Name | Description |
| :--- | :---------- |
| `repository_urls` | Map of repo name → URL |
| `repository_arns` | Map of repo name → ARN |

## Requirements

- OpenTofu / Terraform `>= 1.9.0`
- AWS provider `>= 5.0`
