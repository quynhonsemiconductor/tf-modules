variable "product" {
  type        = string
  description = "Product name; prefixes every role (e.g. \"rova\" → rova-github-deploy-*)."
}

variable "github_org" {
  type        = string
  default     = "quynhonsemiconductor"
  description = "GitHub org/owner that hosts the product repos."
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the GitHub OIDC provider (an account singleton from infra)."
}

variable "environments" {
  type = map(object({
    allowed_subjects = list(string)
  }))
  description = <<-EOT
    Per-environment deploy roles. Key = env name (develop, production);
    allowed_subjects = the OIDC `sub` claims permitted to assume the role
    (e.g. "repo:ORG/myproduct-api:ref:refs/heads/main").
  EOT
}

variable "app_repo_names" {
  type        = list(string)
  description = "Repos allowed to assume the ecr-push role (e.g. [\"myproduct-api\"])."
}

variable "infra_repo_name" {
  type        = string
  description = "The product's infra repo name (e.g. \"myproduct-infra\")."
}

variable "ecr_repository_pattern" {
  type        = string
  description = "ECR repository name pattern these roles may push/pull (e.g. \"myproduct-*\")."
}

variable "ecs_passrole_pattern" {
  type        = string
  description = "IAM role name pattern the deploy role may PassRole to ECS (e.g. \"myproduct-*\" or \"myproduct-ecs-*\")."
}

variable "infra_apply_policy_arn" {
  type        = string
  default     = "arn:aws:iam::aws:policy/AdministratorAccess"
  description = <<-EOT
    Managed policy attached to the infra-apply role. A full-stack `tofu apply`
    legitimately needs broad create/update/delete across many services, so this
    stays broad; the real controls are (1) environment-scoped trust
    (infra_apply_subjects) and (2) the blast-radius guardrail below.
  EOT
}

variable "infra_plan_subjects" {
  type        = list(string)
  default     = null
  description = <<-EOT
    OIDC `sub` claims allowed to assume the read-only infra-plan role. Defaults
    to PRs + main of the infra repo. Never use a bare "repo:org/repo:*".
  EOT
}

variable "infra_apply_subjects" {
  type        = list(string)
  default     = null
  description = <<-EOT
    OIDC `sub` claims allowed to assume the infra-apply role. Defaults to the
    shared/develop/production GitHub Environments of the infra repo, so a bare
    branch or PR can never assume it. Override for products with different
    environment names (e.g. infra uses ["...:environment:bootstrap",
    "...:environment:security-baseline"]).
  EOT
}

variable "infra_apply_guardrail" {
  type = object({
    state_bucket_arn     = string
    lock_table_arn       = string
    oidc_provider_arn    = string
    kms_key_arn          = string
    artifacts_bucket_arn = optional(string)
  })
  default     = null
  description = <<-EOT
    When set, attaches an explicit-Deny guardrail to the infra-apply role that a
    broad Allow (AdministratorAccess) cannot override. Protects the platform's
    own foundations from a buggy/compromised product apply in a single account:
    denies deleting the state bucket / lock table / OIDC provider, scheduling
    deletion or rewriting the policy of the platform CMK, and creating IAM
    users/access-keys or touching AWS Organizations. Leave null to skip.
  EOT
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all roles."
}
