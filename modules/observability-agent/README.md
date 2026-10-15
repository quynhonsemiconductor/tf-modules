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

- Adds the collector's `debug` exporter (`verbosity: detailed`) to the **metrics** pipeline only, **after** the `batch` processor: what it logs is what `otlphttp`
  sends. Every datapoint is logged with its resource attributes, scope, labels, `Timestamp` and value. A duplicate is the same series and the same `Timestamp`
  appearing twice with different values.
- Raises the collector's own log level to `info` while it is on, because the debug exporter writes at info and the default level is `warn`.
- Off (the default): the rendered collector config is **byte-identical** to the previous version (checked by rendering both).

### Where it goes and how to read it

The sidecar's `awslogs` stream: log group `var.log_group`, stream `<var.name>/<var.name>/<task id>` (one stream per task; the task id tells old tasks from new ones in a
rolling deploy). The driver sends **one CloudWatch event per line**, and one batch is a multi-line text block that starts with a
`<ts>  info  ResourceMetrics #0` line, so a dump has to be read **in order per stream** to be reassembled; the analysis script in `quynhonsemiconductor/ci` does that.
(No `awslogs-multiline-pattern` is set: a block can exceed CloudWatch's 256 KB event limit and would be cut in the middle, which is worse than one event per line.)

### Cost: there is no sampling knob, on purpose

Measured against `aws-otel-collector:v0.43.3`, counting CloudWatch's 26-byte per-event overhead:

| datapoint | lines | bytes in CloudWatch |
| --- | --- | --- |
| a counter / gauge with 2 labels | 7 | ~0.4 KB |
| a histogram with 15 explicit bounds (16 buckets) | 42 | ~2.2 KB |

At a 70/30 mix that is ~0.9 KB per datapoint. So **3,600 datapoints a minute is ~3.3 MB/min, ~200 MB/hour, ~5 GB/day (~US$2.5/day** at US$0.50/GB ingested). If
"3,600 series" means series that are each exported every 10 s (the develop export interval) it is 21,600 datapoints/min, six times that: ~30 GB/day (~US$15/day).
A 20-minute window is 66 to 400 MB. Fine for a time-boxed run; **not** something to leave on.

The exporter's own sampling does not help: it counts log records of *identical text*, and every batch is different text. Measured with `sampling_initial: 1,
sampling_thereafter: 1000`: all 30 distinct batches were still logged in full; only the repeated one-line `Metrics {...}` count header was thinned. So the module keeps
everything (`sampling_initial: 1000`, `sampling_thereafter: 1`) and exposes no sampling variable; the lever is how long it is on.

### Things to know

- The values are application data, and the labels may carry route templates: read access to the log group is the access control. Do not leave it on.
- The awslogs driver is blocking by default. A very slow CloudWatch could back up the collector's stdout; the `memory_limiter` then refuses data and the app's SDK
  retries. Acceptable for a develop task for a few hours.

Verified against the real image (`aws-otel-collector:v0.43.3`), with the config this module renders: on, a posted OTLP batch is logged as `NumberDataPoints` blocks
including two with one timestamp and different values; off, the container logs nothing at all (warn level).
