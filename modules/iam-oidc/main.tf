# =============================================================================
# iam-oidc — GitHub Actions OIDC deploy roles for a product.
#
# Creates the full role set every product needs (all scoped by var.product):
#   - <product>-github-deploy-<env>   per-environment app deploy (least privilege)
#   - <product>-github-ecr-push       image build/push (no env gate)
#   - <product>-github-infra-plan     read-only tofu plan on infra PRs
#   - <product>-github-infra-apply    tofu apply on infra main branch
#
# The GitHub OIDC provider itself is an account singleton owned by infra;
# this module only consumes its ARN (never creates it).
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  ecr_arn    = "arn:aws:ecr:*:${local.account_id}:repository/${var.ecr_repository_pattern}"
  passrole   = "arn:aws:iam::${local.account_id}:role/${var.ecs_passrole_pattern}"
  infra_sub  = "repo:${var.github_org}/${var.infra_repo_name}"

  # Scoped to this product's own secret prefix. The trailing `*` also absorbs the
  # 6-character random suffix Secrets Manager appends to every secret ARN
  # (`rally/production/cookie-secret-0sHpOW`), which a bare name never matches.
  secret_arns = "arn:aws:secretsmanager:*:${local.account_id}:secret:${var.product}/*"

  # Trust subjects — bound to specific refs/environments, NEVER the whole repo.
  # In a monorepo (app + infra in one repo) a "repo:org/repo:*" sub would let any
  # feature branch or PR that requests id-token assume these roles. Instead:
  #   - infra_plan  → PRs + main only (read-only tofu plan)
  #   - infra_apply → only from inside the gated GitHub Environments, so the AWS
  #     trust boundary matches the environment reviewer gate. A branch/PR with no
  #     `environment:` in its job emits sub `...:ref:...`/`...:pull_request`, which
  #     is NOT in this list → cannot assume apply, regardless of branch protection.
  # Both are overridable for products whose environments differ (e.g. infra
  # uses bootstrap/security-baseline).
  infra_plan_subjects_named = var.infra_plan_subjects != null ? var.infra_plan_subjects : [
    "${local.infra_sub}:pull_request",
    "${local.infra_sub}:ref:refs/heads/main",
  ]
  infra_apply_subjects_named = var.infra_apply_subjects != null ? var.infra_apply_subjects : [
    "${local.infra_sub}:environment:shared",
    "${local.infra_sub}:environment:develop",
    "${local.infra_sub}:environment:production",
  ]

  # ── GitHub issues the OIDC `sub` in TWO shapes ──────────────────────────────
  # Which one a repository gets is not a setting anyone here chose. Repositories that
  # predate GitHub's change emit the familiar
  #
  #   repo:ORG/REPO:pull_request
  #
  # while newer ones emit an ID-augmented form that pins the org and repo by their
  # immutable database ids:
  #
  #   repo:ORG@297362956/REPO@1312007613:pull_request
  #
  # A trust policy written for one silently rejects the other, and STS reports only
  # "Not authorized to perform sts:AssumeRoleWithWebIdentity" — it never says the
  # subject failed to match, so the obvious suspects (a missing account id, an
  # unscoped org variable, a wrong role name) all look equally plausible. Reading it
  # out of CloudTrail is the only way to see the claim that was actually presented.
  #
  # So every subject is trusted in both shapes. The rewrite is deliberately NOT a
  # loose wildcard: `ORG@*` requires the literal `@` immediately after the org name,
  # so it cannot match a different organisation whose name merely starts the same way
  # (`quynhonsemiconductor-evil`), and the same holds for the repository. `ORG*` would match both
  # and is the trap to avoid here.
  #
  # Additive: a repository on the old form keeps matching the named subject, so this
  # changes nothing for products already working.
  immutable_sub_re      = "/^repo:([^/@]+)\\/([^:@]+):/"
  immutable_sub_replace = "repo:$1@*/$2@*:"

  infra_plan_subjects = distinct(concat(
    local.infra_plan_subjects_named,
    [for s in local.infra_plan_subjects_named : replace(s, local.immutable_sub_re, local.immutable_sub_replace)],
  ))
  infra_apply_subjects = distinct(concat(
    local.infra_apply_subjects_named,
    [for s in local.infra_apply_subjects_named : replace(s, local.immutable_sub_re, local.immutable_sub_replace)],
  ))

  # Same expansion for the per-environment deploy roles, whose subjects the CALLER
  # supplies, and for the ECR push role.
  deploy_subjects = {
    for env, cfg in var.environments : env => distinct(concat(
      cfg.allowed_subjects,
      [for s in cfg.allowed_subjects : replace(s, local.immutable_sub_re, local.immutable_sub_replace)],
    ))
  }

  ecr_push_subjects_named = [for repo in var.app_repo_names : "repo:${var.github_org}/${repo}:*"]
  ecr_push_subjects = distinct(concat(
    local.ecr_push_subjects_named,
    [for s in local.ecr_push_subjects_named : replace(s, local.immutable_sub_re, local.immutable_sub_replace)],
  ))
}

# ── Per-environment app deploy roles ──────────────────────────────────────────
resource "aws_iam_role" "deploy" {
  for_each = var.environments

  name        = "${var.product}-github-deploy-${each.key}"
  description = "GitHub Actions deploy role for ${var.product} (${each.key})."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = local.deploy_subjects[each.key] }
      }
    }]
  })

  tags = merge(var.tags, { Environment = each.key })
}

resource "aws_iam_role_policy" "deploy" {
  for_each = var.environments

  name = "${var.product}-deploy-${each.key}"
  role = aws_iam_role.deploy[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ECRAuth", Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
          "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload", "ecr:DescribeRepositories", "ecr:ListImages",
        ]
        Resource = local.ecr_arn
      },
      {
        Sid    = "ECSDeploy"
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition", "ecs:DescribeServices",
          "ecs:UpdateService", "ecs:RunTask", "ecs:DescribeTasks", "ecs:ListTaskDefinitions",
          # ListTasks is required by the post-deploy verify step (verify-ecs-deploy),
          # which enumerates running tasks to confirm the new image tag is live.
          "ecs:ListTasks",
        ]
        Resource = "*"
      },
      {
        Sid      = "PassRoleToECS"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = local.passrole
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      { Sid = "Logs", Effect = "Allow", Action = ["logs:DescribeLogGroups"], Resource = "*" },
      {
        # Lets the deploy job PREFLIGHT that every secret its task definitions
        # inject actually holds a value. Terraform creates secret containers but
        # values are populated out of band, and an empty container is accepted by
        # RegisterTaskDefinition — the failure only surfaces minutes later as an
        # ECS ResourceInitializationError plus a rollback that never names the
        # secret. Metadata is enough to detect that.
        #
        # Deliberately NOT GetSecretValue: the deploy role must never be able to
        # read a secret's contents. DescribeSecret and ListSecretVersionIds return
        # names, ARNs and version ids only.
        Sid      = "SecretsMetadataForPreflight"
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:ListSecretVersionIds"]
        Resource = local.secret_arns
      },
      {
        # Same preflight, Parameter Store side — app secrets live here now because
        # standard SSM parameters carry no per-parameter monthly charge.
        #
        # Also deliberately NOT GetParameter: DescribeParameters returns names and
        # VERSION numbers only. That is all the check needs, because the secrets module
        # creates each parameter holding a placeholder with ignore_changes on the value,
        # so version 1 means "never populated" and version >1 means an operator set it.
        # This is a stronger guarantee than the Secrets Manager path above gets, with
        # strictly less privilege.
        #
        # Resource must be "*": DescribeParameters is a list operation and SSM does not
        # support resource-level permissions on it. It exposes no values.
        Sid      = "SsmMetadataForPreflight"
        Effect   = "Allow"
        Action   = ["ssm:DescribeParameters"]
        Resource = "*"
      },
    ]
  })
}

# ── ECR push role (build jobs, no environment gate) ───────────────────────────
resource "aws_iam_role" "ecr_push" {
  name        = "${var.product}-github-ecr-push"
  description = "GitHub Actions image build/push role for ${var.product}."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = local.ecr_push_subjects
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "ecr_push" {
  name = "${var.product}-ecr-push"
  role = aws_iam_role.ecr_push.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
          "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
          # DescribeImages: the tag→prod promote job resolves the promoted image
          # digest by tag (aws ecr describe-images) after re-tagging. Without it
          # the resolve fails AccessDenied and the prod deploy aborts.
          "ecr:DescribeImages",
        ]
        Resource = local.ecr_arn
      },
    ]
  })
}

# ── Infra CI roles (the product's *-infra repo) ───────────────────────────────
# Read-only plan role for PRs.
resource "aws_iam_role" "infra_plan" {
  name        = "${var.product}-github-infra-plan"
  description = "GitHub Actions tofu plan (read-only) for ${var.infra_repo_name} PRs."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = local.infra_plan_subjects }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "infra_plan_readonly" {
  role       = aws_iam_role.infra_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Apply role for main branch (broad; protected by branch rules + the sub condition).
resource "aws_iam_role" "infra_apply" {
  name        = "${var.product}-github-infra-apply"
  description = "GitHub Actions tofu apply for ${var.infra_repo_name} main branch."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Environment-scoped only (shared/develop/production by default) — the
          # apply role is unassumable from a bare branch/PR. See local.infra_apply_subjects.
          "token.actions.githubusercontent.com:sub" = local.infra_apply_subjects
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "infra_apply_admin" {
  role       = aws_iam_role.infra_apply.name
  policy_arn = var.infra_apply_policy_arn
}

# Blast-radius guardrail — explicit Deny beats the AdministratorAccess Allow, so
# even a compromised/buggy apply cannot destroy the platform's own foundations
# (state, locks, OIDC trust, the CMK) or mint IAM users/keys. Optional: only when
# var.infra_apply_guardrail is provided.
resource "aws_iam_role_policy" "infra_apply_guardrail" {
  count = var.infra_apply_guardrail != null ? 1 : 0

  name = "${var.product}-infra-apply-guardrail"
  role = aws_iam_role.infra_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ProtectStateAndArtifacts"
        Effect = "Deny"
        Action = ["s3:DeleteBucket", "s3:DeleteBucketPolicy", "s3:PutBucketPolicy", "s3:PutEncryptionConfiguration"]
        Resource = compact([
          var.infra_apply_guardrail.state_bucket_arn,
          try(var.infra_apply_guardrail.artifacts_bucket_arn, null),
        ])
      },
      {
        Sid      = "ProtectLockTable"
        Effect   = "Deny"
        Action   = ["dynamodb:DeleteTable"]
        Resource = [var.infra_apply_guardrail.lock_table_arn]
      },
      {
        Sid    = "ProtectOidcProvider"
        Effect = "Deny"
        Action = [
          "iam:DeleteOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:RemoveClientIDFromOpenIDConnectProvider",
        ]
        Resource = [var.infra_apply_guardrail.oidc_provider_arn]
      },
      {
        Sid      = "ProtectPlatformCMK"
        Effect   = "Deny"
        Action   = ["kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:PutKeyPolicy"]
        Resource = [var.infra_apply_guardrail.kms_key_arn]
      },
      {
        Sid    = "NoHumanIdentitiesOrOrgChanges"
        Effect = "Deny"
        Action = [
          "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "iam:CreateSAMLProvider",
          "organizations:*", "account:*",
        ]
        Resource = ["*"]
      },
    ]
  })
}

