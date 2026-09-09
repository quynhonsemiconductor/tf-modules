# `secrets` module

Creates **empty** AWS Secrets Manager secrets (values set out-of-band) plus
optional SSM Parameter Store entries for non-sensitive config.

## Usage

```hcl
module "secrets" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/secrets?ref=secrets-v1.0.0"

  prefix      = "myproduct/develop"
  kms_key_arn = local.kms_key_arn

  secret_names = {
    "db-url"      = "PostgreSQL connection URL"
    "jwt-private" = "EC P-256 (ES256) private key (PEM, base64)"
    "jwt-public"  = "EC P-256 (ES256) public key (PEM, base64)"
  }

  # Optional non-sensitive config:
  # ssm_parameters = {
  #   "feature-flag" = { value = "on", description = "…" }
  # }

  tags = local.tags
}
```

## Inputs

| Name | Type | Default | Description |
| :--- | :--- | :------ | :---------- |
| `prefix` | `string` | — | Namespace prefix (`<prefix>/<key>`) |
| `secret_names` | `map(string)` | — | Secret key → description; one empty secret each |
| `bundle_name` | `string` | `""` | Collapse all `secret_names` into ONE JSON secret named `<prefix>/<bundle_name>` |
| `use_bundle` | `bool` | `false` | Return bundle key references from `secret_arns` instead of standalone ARNs |
| `create_standalone` | `bool` | `null` | Create the per-entry secrets. Defaults to `!use_bundle`; set `true` to hold both during a migration |
| `ssm_parameters` | `map(object)` | `{}` | key → `{ value, description }` |
| `kms_key_arn` | `string` | `""` | KMS key for encryption (empty = AWS-managed key) |
| `recovery_window_days` | `number` | `7` | Days before permanent delete (0 = immediate) |
| `tags` | `map(string)` | `{}` | Tags applied to all resources |

## Outputs

| Name | Description |
| :--- | :---------- |
| `secret_arns` | Map of secret key → ECS `valueFrom` reference. **Not an IAM resource when bundled** |
| `secret_iam_arns` | Distinct container ARNs, for the execution role's `GetSecretValue` |
| `ssm_parameter_arns` | Map of SSM parameter key → ARN |

## Bundling

Secrets Manager bills **$0.40 per secret per month regardless of size**, against a 64 KB limit per secret. Twelve app secrets in two environments is $9.60/mo for ~2.4 KB of material. `bundle_name` makes it $0.80.

ECS reads one key out of a JSON secret natively, and `secret_arns` returns that shape, so **call sites do not change**:

```hcl
# identical in both modes
{ name = "COOKIE_SECRET", secret_arn = module.secrets.secret_arns["cookie-secret"] }
```

What is preserved: a bundled key that is absent fails the task exactly as an empty secret does, so "unpopulated" still means a failed deploy and a rollback rather than a silent downgrade. The ci preflight already rejoins the first seven ARN fields before probing, so it needs no change.

What is given up: per-secret IAM and per-secret rotation — one key rotating rewrites the object as a new version. Keep a value out of the bundle if it needs its own resource policy, its own rotation schedule, or a narrower reader than the rest.

### Migrating an existing set

Staged, because switching the references and destroying the old secrets in one apply leaves nothing to roll back to:

```hcl
bundle_name = "app"                              # 1. create the empty bundle
                                                 # 2. populate it out of band
bundle_name = "app"                              # 3. cut over, OLD SECRETS RETAINED
use_bundle  = true
create_standalone = true
                                                 # 4. drop create_standalone → old gone
```

Only step 3 can fail, and it fails safely: a wrong or missing key means tasks cannot boot, the deploy never reaches steady state, and the previous task definition still points at secrets that still exist. Reverting step 3 is a one-line rollback — `secret_iam_arns` deliberately grants both containers while both exist, so no IAM apply has to be sequenced with it.

## Requirements

- OpenTofu / Terraform `>= 1.9.0`
- AWS provider `>= 5.0`
