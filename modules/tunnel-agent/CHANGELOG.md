# Changelog

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
