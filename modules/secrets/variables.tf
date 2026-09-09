variable "prefix" {
  type        = string
  description = "Namespace prefix for secret/parameter names (e.g. \"myproduct/develop\")."
}

variable "secret_names" {
  type        = map(string)
  default     = {}
  description = <<-EOT
    Map of secret key → human-readable description. One empty Secrets Manager
    secret is created per entry, named "<prefix>/<key>". Values are set
    out-of-band.

    Defaults to empty, because `secure_parameters` is the cheaper default home for
    ordinary app secrets. Use this only for values that need something Parameter
    Store cannot do: rotation, cross-region replication, a resource policy, or more
    than 4 KB.
  EOT
}

variable "bundle_name" {
  type        = string
  default     = ""
  description = <<-EOT
    Collapse every `secret_names` entry into ONE Secrets Manager secret holding a JSON
    object, named "<prefix>/<bundle_name>". Empty (the default) keeps one secret per entry.

    Secrets Manager bills $0.40 per SECRET per month regardless of size, so the fee is a
    function of how many containers you have, not how much material. Twelve app secrets
    per environment across two environments is $9.60/mo for ~2.4 KB — against a 64 KB
    limit per secret. Bundling is the same material for $0.80.

    ECS reads a single key out of a JSON secret natively, via the `<arn>:<key>::` form of
    `valueFrom`, and this module returns exactly that from `secret_arns` when a bundle is
    in use. Call sites therefore do not change: `secret_arns["db-app-password"]` is a
    standalone ARN or a bundle key reference depending on this input alone.

    WHAT IS PRESERVED. The property that made Secrets Manager the choice over Parameter
    Store — a container can exist holding NO value, so "unpopulated" is unambiguous and
    fails a boot rather than degrading silently — survives per KEY: ECS fails the task
    when a referenced JSON key is absent, exactly as it does for an empty secret. The
    deploy preflight in ci already rejoins the first seven ARN fields before probing,
    so it keeps verifying the container is non-empty with no change.

    WHAT IS GIVEN UP. Per-secret IAM (see `secret_iam_arns`) and per-secret rotation: one
    key rotating rewrites the whole object as a new version. Neither applies here — the
    execution role is already granted every secret in the set, and none of these rotate.
    Keep a value OUT of the bundle if it needs its own resource policy, its own rotation
    schedule, or a narrower reader than the rest.
  EOT
}

variable "use_bundle" {
  type        = bool
  default     = false
  description = <<-EOT
    Return bundle key references from `secret_arns` instead of standalone ARNs.

    Separate from `bundle_name` so the migration can be staged, because the dangerous
    ordering is switching the references and destroying the old secrets in one apply: if
    the bundle turns out to be wrong, the values it replaced are already gone (and dev
    sets `recovery_window_days = 0`, so gone means gone).

      1. bundle_name = "app"                        create the empty bundle
      2.                                            populate it out of band from the
                                                    standalone values
      3. use_bundle = true, create_standalone = true references cut over, old secrets
                                                    RETAINED — revert to roll back
      4. drop create_standalone                     old secrets destroyed

    Step 3 is the only one that can fail, and it fails safely: a wrong or missing key
    means tasks cannot boot, the deploy never reaches steady state, and the previous task
    definition is still pointing at secrets that still exist.
  EOT

  validation {
    condition     = !var.use_bundle || var.bundle_name != ""
    error_message = "use_bundle = true requires bundle_name to be set — there is no bundle to read keys from."
  }
}

variable "create_standalone" {
  type        = bool
  default     = null
  description = <<-EOT
    Whether to create the per-entry standalone secrets. Defaults to `!use_bundle`, which
    is the right answer outside a migration: standalone when nothing else serves the
    references, absent once the bundle does.

    Set it TRUE explicitly to hold both at once — the retained-rollback step above. There
    is no reason to set it false while `use_bundle` is false; that would leave the
    references pointing at nothing, so a validation rejects it.

    Worth rejecting rather than tolerating because it APPLIES CLEANLY. Removing the
    containers while task definitions still reference them is not a smaller footprint, it
    is an environment whose next deploy cannot boot — and nothing surfaces until the
    rollout, long after the apply reported success.
  EOT

  validation {
    condition     = coalesce(var.create_standalone, !var.use_bundle) || (var.use_bundle && var.bundle_name != "")
    error_message = "create_standalone = false requires a bundle to serve the references: set bundle_name and use_bundle = true, or leave create_standalone unset (it defaults to !use_bundle)."
  }
}

variable "secure_parameters" {
  type        = map(string)
  default     = {}
  description = <<-EOT
    Sensitive values to create as SSM SecureString parameters: key => description.

    Preferred over `secret_names` for ordinary app secrets — standard SSM parameters
    carry no per-parameter monthly charge, where Secrets Manager is $0.40 each. Same
    CMK encryption, same one-ARN-per-value IAM granularity, and ECS reads both the
    same way.

    Created holding the literal "UNSET" (SSM forbids an empty value) with
    ignore_changes on the value, so the real material is pasted in out of band and
    Terraform never reverts it. A parameter still at version 1 has never been
    populated; CI gates on that.

    Reach for `secret_names` instead when a value needs rotation, replication, a
    resource policy, or is larger than the 4 KB standard-parameter limit.
  EOT
}

variable "ssm_parameters" {
  type = map(object({
    value       = string
    description = string
  }))
  default     = {}
  description = "Non-sensitive config to store in SSM Parameter Store (key → {value, description})."
}

variable "kms_key_arn" {
  type        = string
  default     = ""
  description = "KMS key ARN for encrypting secrets. Empty string uses the AWS-managed key."
}

variable "recovery_window_days" {
  type        = number
  default     = 7
  description = "Days before a deleted secret is permanently removed (0 = immediate delete)."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all secrets and parameters."
}
