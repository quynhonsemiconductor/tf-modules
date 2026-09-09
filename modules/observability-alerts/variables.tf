variable "product" {
  description = "Product slug. Stamped as the `product` label on every rule this module creates — the same value observability-agent's `product` var gets, and what the shared notification policy in infra/live/observability would route on if/when per-product routing is added."
  type        = string
}

variable "env" {
  description = "Deployment environment (`develop`, `production`). Stamped as the `env` label on every rule, and appended to `promql` queries automatically — see `rules[].promql`."
  type        = string
}

variable "prometheus_datasource_name" {
  description = <<-EOT
    infra/live/observability's `alerting_prometheus_datasource_name`
    output. A NAME, not a UID: this module looks up the UID itself (see
    main.tf) rather than taking it as an input, because that lookup is a
    `data` read against the Grafana instance API — safe to do HERE, where
    the inherited provider's credentials are always a plain, already-known
    value by apply time (a CI secret, not a same-run resource attribute),
    but NOT safe in infra/live/observability itself, where the service
    account token that read would authenticate with is still being created
    in the SAME plan on a fresh apply.
  EOT
  type        = string
}

variable "folder_uid" {
  description = "infra/live/observability's `alerting_folder_uid` output — the shared folder every product's rule groups live under."
  type        = string
}

variable "interval_seconds" {
  description = "How often the rule group evaluates. 60s is the Grafana Cloud default and fine for these symptom-level checks — none of them need sub-minute detection."
  type        = number
  default     = 60
}

variable "rules" {
  description = <<-EOT
    One entry per alert. `promql` is used VERBATIM — this module does not
    inject or rewrite label filters into it (string surgery on arbitrary
    PromQL is exactly the kind of hidden magic that silently breaks on a
    query shape nobody tested). If a rule should be scoped to this
    environment/product, write that into the query yourself, e.g.
    `db_pool_waiting{deployment_environment_name="develop"}`.

    `op` is one of `gt`, `lt`, `ge`, `le`, `eq`, `ne` (Grafana's threshold
    expression evaluator types — NOT `>`/`<`, which the API rejects).
  EOT
  type = list(object({
    name        = string
    promql      = string
    for         = string # e.g. "5m" — how long the condition must hold before firing
    op          = string
    threshold   = number
    severity    = optional(string, "warning")
    summary     = string               # annotation shown in the notification
    runbook_url = optional(string, "") # rendered by Grafana as a clickable link on the alert; "" omits the annotation entirely
  }))
}
