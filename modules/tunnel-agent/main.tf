# =============================================================================
# tunnel-agent — cloudflared sidecar for an ECS task.
#
# Produces a CONTAINER DEFINITION, not infrastructure, exactly like
# `observability-agent`. The caller merges it into `ecs-service`'s existing
# `additional_containers`, so adopting it needs no change to the service module:
#
#   module "tunnel_api" { source = ".../tunnel-agent"  … }
#   module "api" {
#     source                = ".../ecs-service"
#     additional_containers = concat(module.otel_agent.container_definitions,
#                                    module.tunnel_api.container_definitions)
#     secret_arns           = concat(local.secret_arns, module.tunnel_api.secret_arns)
#     …
#   }
#
# WHY THIS EXISTS: an ALB costs $18.40/mo plus $3.65 per enabled AZ, and every
# request already arrives through Cloudflare — the SPA is a Pages project whose
# Function proxies /v1/* to API_ORIGIN, and the ALB security group only admits
# Cloudflare edge ranges. The load balancer is a second TLS termination in a path
# that is already proxied. `cloudflared` dials OUT to Cloudflare instead, so the
# task needs no inbound listener, no public IPv4 and no ALB.
#
# WHAT THIS GIVES UP, and it is not nothing:
#   - ALB access logs. Cloudflare has its own analytics; the S3 log bucket becomes
#     unused.
#   - Origin-side AWS WAF. Cloudflare's edge WAF still applies.
#   - Target-group CloudWatch alarms — response latency and UnHealthyHostCount have
#     no equivalent here. Replace them with a Cloudflare health check or a synthetic
#     probe BEFORE relying on this in production, or an outage that produces no load
#     goes undetected.
#   - Host-based routing across products on one shared ALB. Each task now carries its
#     own ingress.
#
# SSE IS THE COMPATIBILITY QUESTION, and it was checked rather than assumed. Rova's
# NotificationSseController writes a `: heartbeat` comment every 25s, which is well
# inside Cloudflare's ~100s idle timeout — the heartbeat exists precisely to hold
# connections open through proxies. A workload whose streams are quiet for longer
# than that needs its own keepalive before adopting this.
#
# Everything is gated on `tunnel_token_secret_arn`: empty means no sidecar at all, so
# a stack can adopt this module and stay a no-op until a tunnel exists.
# =============================================================================

locals {
  enabled = var.tunnel_token_secret_arn != ""

  # Flags verified against the pinned image, not against documentation — the two
  # disagree by version, and a wrong flag makes cloudflared exit at startup, which on
  # an `essential = true` container is a task that will never come up.
  #
  #   docker run --rm cloudflare/cloudflared:2026.6.1 tunnel run --help
  #
  # `--no-autoupdate`: the image tag is the version. An agent that updates itself
  # mid-task makes the running binary differ from the one that was reviewed and
  # pinned, and ECS already handles upgrades by replacing tasks.
  #
  # `--metrics` binds the readiness/metrics listener. It takes a flag value only —
  # there is no TUNNEL_METRICS environment variable in this version, so it cannot be
  # set through `environment`.
  #
  # NO `--protocol` flag: it does not exist on `tunnel run` in this version (it was
  # removed once QUIC-with-http2-fallback became automatic). Passing it is an
  # immediate startup failure. cloudflared negotiates QUIC over outbound UDP/7844 and
  # falls back to http2 over TCP/7844 on its own, which matters here because egress is
  # an fck-nat instance where UDP is less predictable than TCP.
  #
  # The token arrives as TUNNEL_TOKEN via `secrets`, never as `--token`: command
  # arguments are readable in `aws ecs describe-task-definition`.
  command = [
    "tunnel",
    "--no-autoupdate",
    "--loglevel", var.log_level,
    "--metrics", "127.0.0.1:2000",
    "run",
  ]
}
