variable "repository_names" {
  type        = list(string)
  description = "ECR repository names to create."
}

variable "image_tag_mutability" {
  type        = string
  default     = "IMMUTABLE"
  description = "IMMUTABLE (recommended) or MUTABLE (allows re-tagging e.g. :latest)."

  validation {
    condition     = contains(["IMMUTABLE", "MUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be IMMUTABLE or MUTABLE."
  }
}

variable "kms_key_arn" {
  type        = string
  default     = ""
  description = "KMS key ARN for encryption. Empty string uses AES256 (AWS-managed)."
}

variable "release_tag_prefix" {
  type        = string
  default     = "v"
  description = "Tag prefix for release images (the tags production pins)."
}

variable "release_retention_days" {
  type        = number
  default     = 180
  description = <<-EOT
    Delete RELEASE images older than this many days. This is the rollback window for
    production, expressed in the unit the promise is made in.

    It used to be `keep_release_count = 30`, a COUNT, and that is a duration only if
    the promotion rate is known. GitOps raises that rate — the point of promoting by
    pull request is that a release stops being a batch of forty-four commits — so a
    count-based rule silently shortens the rollback window exactly as deploys get
    healthier, and the failure surfaces at the worst possible moment.

    180 rather than 90: ECR storage is $0.10/GB-month and August's ECR bill was ~94%
    data transfer, not storage, so there is no cost argument for a short window. The
    number is chosen to be generous enough that it is not the binding constraint
    today, and to stay correct as the promotion rate rises.

    BEFORE APPLYING THIS TO A LIVE REPOSITORY, preview it. A time rule can delete
    images a count rule was keeping, and the direction depends on the current
    promotion rate:

      aws ecr start-lifecycle-policy-preview \
        --repository-name <repo> --lifecycle-policy-text "$(tofu output -raw ...)"
      aws ecr get-lifecycle-policy-preview --repository-name <repo>

    If the preview expires a release you would still want to roll back to, raise this
    number. Do not lower it to match what a count rule happened to keep.
  EOT
}

variable "build_tag_prefix" {
  type        = string
  default     = "sha-"
  description = "Tag prefix for per-commit build images."
}

variable "keep_build_count" {
  type        = number
  default     = 20
  description = <<-EOT
    Most-recent per-commit BUILD images to keep. Trimmed harder than releases: on a
    busy repo these accumulate at several per day and nothing pins them once the
    commit is superseded.
  EOT
}

variable "untagged_expire_days" {
  type        = number
  default     = 1
  description = <<-EOT
    Delete untagged images older than this many days.

    Note this does NOT catch the provenance/SBOM attestation manifests buildx pushes.
    ECR reports them as untagged, but they are referenced by the image index of a
    tagged image, so ECR keeps them alive with their parent. That is correct — they
    are the attestations for an image you are still keeping.
  EOT
}

variable "allowed_principal_arns" {
  type        = list(string)
  default     = []
  description = "IAM principal ARNs allowed to push/pull. Empty = no repository policy created."
}

variable "force_delete" {
  type        = bool
  default     = false
  description = <<-EOT
    Allow repositories to be deleted even when they still contain images.
    Set true so a full teardown (dev, or a from-scratch rebuild) doesn't require
    manually deleting images first. Defaults false for safety in long-lived envs.
  EOT
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all repositories."
}
