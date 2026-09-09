# `iam-oidc` module

Creates the full GitHub Actions OIDC role set for a product — per-environment
app deploy roles, an ECR push role, and the infra plan/apply roles. All role
names are prefixed by `var.product`. The OIDC provider itself is an account
singleton owned by `infra`; this module only consumes its ARN.

Roles created:

| Role | Purpose |
| :--- | :------ |
| `<product>-github-deploy-<env>` | Per-env app deploy (ECR pull/push, ECS update, scoped PassRole) |
| `<product>-github-ecr-push` | Image build/push (no env gate) |
| `<product>-github-infra-plan` | Read-only `tofu plan` on infra PRs |
| `<product>-github-infra-apply` | `tofu apply` on infra `main` |

## Usage

```hcl
module "iam_oidc" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/iam-oidc?ref=iam-oidc-v1.0.0"

  product           = "myproduct"
  github_org        = "quynhonsemiconductor"
  oidc_provider_arn = data.terraform_remote_state.platform.outputs.oidc_provider_arn

  environments = {
    develop = {
      allowed_subjects = [
        "repo:quynhonsemiconductor/myproduct-api:ref:refs/heads/main",
        "repo:quynhonsemiconductor/myproduct-api:environment:develop",
      ]
    }
    production = {
      allowed_subjects = [
        "repo:quynhonsemiconductor/myproduct-api:ref:refs/heads/main",
        "repo:quynhonsemiconductor/myproduct-api:ref:refs/tags/v*",
      ]
    }
  }

  app_repo_names         = ["myproduct-api"]
  infra_repo_name        = "myproduct-infra"
  ecr_repository_pattern = "myproduct-*"
  ecs_passrole_pattern   = "myproduct-*"
  tags                   = { Scope = "shared" }
}
```

> **Bootstrapping note:** the `infra-apply` role is created by this module, but
> the apply pipeline *assumes* it — a chicken-and-egg on the very first apply.
> Create `<product>-github-infra-apply` once by hand (or run the first `_shared`
> apply with local AWS credentials), after which the pipeline manages it.

## Inputs

| Name | Type | Default | Description |
| :--- | :--- | :------ | :---------- |
| `product` | `string` | — | Role name prefix |
| `github_org` | `string` | `quynhonsemiconductor` | GitHub org |
| `oidc_provider_arn` | `string` | — | OIDC provider ARN (from infra) |
| `environments` | `map(object)` | — | env → `{ allowed_subjects }` |
| `app_repo_names` | `list(string)` | — | Repos allowed to assume ecr-push |
| `infra_repo_name` | `string` | — | The `*-infra` repo name |
| `ecr_repository_pattern` | `string` | — | ECR ARN scope (e.g. `myproduct-*`) |
| `ecs_passrole_pattern` | `string` | — | PassRole role-name scope |
| `infra_apply_policy_arn` | `string` | `AdministratorAccess` | Managed policy on apply role |
| `tags` | `map(string)` | `{}` | Tags |

## Outputs

| Name | Description |
| :--- | :---------- |
| `deploy_role_arns` | Map env → deploy role ARN |
| `ecr_push_role_arn` | ECR push role ARN |
| `infra_plan_role_arn` | Infra plan role ARN |
| `infra_apply_role_arn` | Infra apply role ARN |

## Requirements

- OpenTofu / Terraform `>= 1.9.0`
- AWS provider `>= 5.0`
