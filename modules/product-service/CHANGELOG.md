# Changelog

## 0.1.0

Initial, **unreleased and unconsumed**. Pre-1.0 deliberately: no product has adopted it, so
the interface has not been proven against a real migration and may still change.

Composes one ECS service with its sidecars and ingress, centralising the four pieces of
wiring each product previously hand-assembled — sidecar container definitions, sidecar token
ARNs onto the execution role, FireLens S3 grants onto the task role, and ALB-versus-tunnel
exclusivity.

- `ingress.mode` (`none` / `tunnel` / `alb`) replaces the per-service
  `attach_alb = !module.tunnel.enabled` pattern, making the mutually exclusive combination
  unrepresentable rather than merely discouraged. Validated: `tunnel` requires a token ARN,
  `alb` requires a listener ARN.
- `otel` and `firelens` sidecars are opt-in; the collector stays dormant while
  `otlp_endpoint` is empty, so a product can carry the wiring before the backend exists.
- Interface types were corrected against `ecs-service` during authoring rather than assumed:
  `environment_vars` and `secrets` are lists of objects, and `health_check_command` is a
  string, not a list.

Adoption is a state migration requiring `moved` blocks and a zero-diff plan — see the README
and `qnsc-infra/docs/product-service-extraction.md`.
