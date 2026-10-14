# observability-agent

OpenTelemetry Collector **sidecar** for an ECS task. Emits a container definition;
creates no infrastructure of its own.

The app exports to `http://127.0.0.1:4318` through the task's shared network
namespace — no service discovery, no cross-AZ hop, no extra security group.

## Usage

```hcl
module "otel_agent" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/observability-agent?ref=observability-agent-v1.0.0"

  product          = "rova"
  env              = "develop"          # deployment identity, NOT NODE_ENV
  otlp_endpoint    = var.otlp_endpoint  # "" ⇒ module is a no-op
  token_secret_arn = module.secrets.secret_arns["observability-token"]
  log_group        = module.api.log_group_name
  region           = var.region
}

module "api" {
  source = "…//modules/ecs-service?ref=ecs-service-v1.3.0"

  additional_containers = module.otel_agent.container_definitions
  secret_arns           = concat(local.app_secret_arns, module.otel_agent.secret_arns)

  environment = concat(local.app_env, [
    { name = "OTEL_ENABLED",                value = tostring(module.otel_agent.enabled) },
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = module.otel_agent.endpoint },
  ])
  # …
}
```

Gating `OTEL_ENABLED` on `module.otel_agent.enabled` is the point: the app can
never be told to export into a void.

## The token

`token_secret_arn` must hold the **complete `Authorization` header value**, e.g.

```
Basic MTIzNDU2OmdsY19leUp...
```

Not just the token. Grafana Cloud wants `Basic base64(instanceID:token)`, and
assembling that in Terraform would put the instance id in state and the credential
in a plaintext task-definition `environment` entry. One opaque secret keeps it out
of both. The collector reads it as `${env:OBSERVABILITY_TOKEN}`; Terraform never
interpolates it.

Create it empty in Terraform and populate out of band:

```bash
aws secretsmanager put-secret-value \
  --secret-id rova/develop/observability-token \
  --secret-string "Basic $(printf '%s:%s' "$INSTANCE_ID" "$TOKEN" | base64 -w0)"
```

## Deliberate omissions

| Not here | Why |
|---|---|
| **Logs pipeline** | A sidecar cannot read another container's stdout on ECS; that needs a FireLens log router. App logs already reach CloudWatch via `awslogs`, where the compliance retention lives, and `trace.id` is on every line — so log↔trace correlation works without moving logs at all. |
| **Tail sampling** | A tail sampler must see *every* span of a trace; a sidecar only ever sees its own task's fragment. Needs a load-balancing gateway keyed by trace id. Until then head sampling in the SDK is the only lever, and a production ratio below 1.0 loses most **error** traces. |
| **`healthCheck`** | The image ships no shell and no netcat — verified: `exec: "sh": executable file not found in $PATH`. Any `CMD-SHELL` probe would fail permanently and report a healthy collector as unhealthy. `essential = false` already prevents a collector failure from stopping the task. |
| **Health-probe filtering** | The SDK already refuses to trace `/v1/healthz`, `/v1/readyz` and `/favicon.ico`, so no span is created to drop. |

## Safety properties

- `essential = false` — telemetry can never take the application down.
- `memory_limiter` is **first** in every pipeline. Without it the collector grows
  until ECS OOM-kills it, and on a sidecar that restarts the whole task. It sheds
  telemetry instead. `spike_limit_mib` is 25% of the soft limit, and `memory` (hard)
  is comfortably above it so the limiter gets to act before the kernel does.
- The exporter queue is **bounded** (`queue_size = 512`) with a 120 s retry ceiling.
  An unbounded queue turns a backend outage into an application memory leak.
- Receivers bind to `127.0.0.1`, not `0.0.0.0` — the only legitimate clients share
  the task's network namespace.

## Verification

The rendered config was validated by running the real image:

```
$ docker run --rm -e AOT_CONFIG_CONTENT="$(tofu output -raw cfg)" … aws-otel-collector:v0.43.3
ADOT Collector version: v0.43.3
# starts, stays running, no errors
```

A deliberately broken config under the same harness exits with
`Error: invalid configuration: …`, so a clean start is a meaningful result rather
than an absence of output.

## Diagnostic: `debug_metrics`

For finding a series that two writers emit with the **same timestamp** (Grafana Cloud discards those as `sample_duplicate_timestamp`). Off by default; turn it on in
ONE develop stack, read the sidecar's log stream, turn it off.

- Adds the collector's `debug` exporter (`verbosity: detailed`) to the **metrics** pipeline only. Every datapoint is logged with its resource, labels,
  `Timestamp` and `Value`. A duplicate is the same series and the same `Timestamp` appearing twice with different values.
- Raises the collector's own log level to `info` while it is on, because the debug exporter writes at info and the default level is `warn`.
- `debug_sampling_initial` (1000/s) and `debug_sampling_thereafter` (1) keep everything in a quiet develop task.
- Cost: it logs every datapoint to CloudWatch, and the values are application data. **Do not leave it on.**

Verified against the real image (`aws-otel-collector:v0.43.3`): with the option on, a posted OTLP batch of two datapoints with one timestamp is logged as two
`NumberDataPoints` with the same `Timestamp` and different `Value`s; with it off, the rendered config is identical to before (`exporters: [otlphttp]`).
