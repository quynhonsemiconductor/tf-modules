# Changelog

## [1.1.0](https://github.com/quynhonsemiconductor/tf-modules/compare/tunnel-agent-v1.0.0...tunnel-agent-v1.1.0) (2026-09-13)


### Features

* **product-service:** add the per-service composition module ([#137](https://github.com/quynhonsemiconductor/tf-modules/issues/137)) ([5bafd07](https://github.com/quynhonsemiconductor/tf-modules/commit/5bafd07bf0945acfe676e51ae3969db961ed73b2))
* **tunnel-agent:** cloudflared sidecar so a task can serve without an ALB ([#50](https://github.com/quynhonsemiconductor/tf-modules/issues/50)) ([edc14e0](https://github.com/quynhonsemiconductor/tf-modules/commit/edc14e0d12010cb5bcf13dffc268364e6ba62ad3))

## 1.0.0

Initial release: `cloudflared` sidecar container definition for an ECS task, replacing
per-product ALB ingress.

- Emits `container_definitions` for `ecs-service`'s `additional_containers`, plus
  `secret_arns` for the execution role, `enabled` to gate ALB attachment, and `origin_url`
  for the tunnel's public-hostname route.
- Gated on `tunnel_token_secret_arn`: empty produces no sidecar, so a stack can adopt the
  module and stay a no-op until a tunnel exists.
- `essential = true` — losing the connector loses ingress, so the task should die and be
  replaced rather than run while serving nothing.
- Token injected as `TUNNEL_TOKEN` via `secrets`, never as a `--token` command argument.
- No `healthCheck`: the image is distroless, so an in-container probe can never succeed.
- Flags verified against the pinned image rather than documentation — no `--protocol`
  (removed from `tunnel run` in this version), `--metrics` as a flag because this version
  exposes no `TUNNEL_METRICS` variable.

### Note on this file

This module shipped `1.0.0` as a manually created tag and was the only module in this repo
absent from `release-please-config.json`, so no release automation tracked it. Registered in
release-please as of this entry; subsequent versions are generated from conventional commits
like every other module.
