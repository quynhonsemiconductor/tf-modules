# tunnel-agent

Produces a `cloudflared` **sidecar container definition** for an ECS task — not
infrastructure. The tunnel itself (and its connector token) comes from
[`cf-tunnel`](../cf-tunnel); this module is what runs the connector next to your app.

Pairs with [`observability-agent`](../observability-agent), which follows the same
container-definition-not-infrastructure shape.

## Why it exists

An ALB costs ~$18.40/mo plus ~$3.65 per enabled AZ, and every request already arrives
through Cloudflare — the SPA is a Pages project whose Function proxies `/v1/*` to the API
origin, and the ALB security group only admits Cloudflare edge ranges. That makes the load
balancer a second TLS termination in an already-proxied path. `cloudflared` dials **out** to
Cloudflare instead, so the task needs no inbound listener, no public IPv4 and no ALB.

## Usage

```hcl
module "tunnel_api" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/tunnel-agent?ref=tunnel-agent-v1.0.0"

  name                    = "cloudflared"
  tunnel_token_secret_arn = module.secrets.secret_arns["tunnel-token"]
  app_port                = 3000
  log_group               = module.api.log_group_name
  region                  = var.region
}

module "api" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/ecs-service?ref=ecs-service-v1.0.0"

  # Merge alongside any other sidecars — adopting this needs no change to ecs-service.
  additional_containers = concat(
    module.otel_agent_api.container_definitions,
    module.tunnel_api.container_definitions,
  )

  # REQUIRED: the execution role must be able to read the token, or the task fails to
  # start with ResourceInitializationError.
  secret_arns = concat(local.secret_arns, module.tunnel_api.secret_arns)

  # A task served by a tunnel must NOT also be an ALB target.
  attach_alb = !module.tunnel_api.enabled

  # …
}
```

Then set the tunnel's public-hostname route origin to `module.tunnel_api.origin_url`.

## Inputs

| Name | Default | Description |
| :--- | :------ | :---------- |
| `tunnel_token_secret_arn` | `""` | Secrets Manager reference for the connector token, injected as `TUNNEL_TOKEN`. Accepts a plain ARN or the `<arn>:<key>::` bundled-JSON form. **Empty disables the sidecar entirely** |
| `name` | `cloudflared` | Container name; must be unique within the task definition |
| `image` | `cloudflare/cloudflared:2026.6.1` | Pinned by tag, never `:latest` — the agent runs `--no-autoupdate` so the running binary is the reviewed one |
| `app_port` | `3000` | App container's port, reached over the task's shared loopback |
| `cpu` | `0` | No reservation: cloudflared is near-idle at this traffic, and a reservation would be taken from the app container |
| `memory` | `128` | Hard limit in MiB. Raise it for tasks holding many long-lived SSE streams |
| `log_level` | `info` | One of `debug`, `info`, `warn`, `error`, `fatal`. `info` names the connection and edge locations at startup, which is what makes a failed handshake diagnosable |
| `log_group` | — | Normally the app's own group, so a dropped request and the failed connection are in one stream |
| `region` | — | For the `awslogs` driver |

## Outputs

| Output | Use |
| :--- | :--- |
| `container_definitions` | Concat into `ecs-service`'s `additional_containers`. Empty list when disabled |
| `secret_arns` | Concat into `ecs-service`'s `secret_arns` (execution role). Strips the `:<key>::` suffix, which an IAM statement would otherwise fail to match |
| `enabled` | Gate the ALB target-group attachment on its inverse |
| `origin_url` | `http://127.0.0.1:<app_port>` — the tunnel's origin |

## What this gives up

Not nothing. Read this before adopting it in production:

- **ALB access logs.** Cloudflare has its own analytics; the S3 log bucket goes unused.
- **Origin-side AWS WAF.** Cloudflare's edge WAF still applies.
- **Target-group CloudWatch alarms.** Response latency and `UnHealthyHostCount` have no
  equivalent here. Replace them with a Cloudflare health check or a synthetic probe
  **before** relying on this, or an outage that produces no load goes undetected.
- **Host-based routing across products on one shared ALB.** Each task now carries its own
  ingress.

## Two traps worth knowing

**No `healthCheck`, deliberately.** The obvious probe is `/ready` on the metrics port, which
returns 200 only when the connector holds live edge connections. It cannot be expressed
here: an ECS `healthCheck` runs *inside* the container, and this image is distroless —
verified against `cloudflare/cloudflared:2026.6.1`, there is no `/bin/sh`, `wget`, `curl` or
`busybox`. Both `CMD` and `CMD-SHELL` forms fail permanently, which would report a healthy
connector as unhealthy and make ECS kill the task in a loop. `essential = true` is the real
guard; detect a connector that is up-but-not-serving from *outside* the task.

**SSE needs a keepalive.** Cloudflare's idle timeout is ~100s. rova's SSE controller writes a
`: heartbeat` comment every 25s, comfortably inside it. A workload whose streams can be quiet
for longer than that needs its own keepalive before adopting this module.

The token is passed as `TUNNEL_TOKEN` via `secrets` and never as a `--token` argument —
command arguments are readable in `aws ecs describe-task-definition`, which every deploy role
can do.
