# pages-web

Cloudflare Pages hosting for a single-page web app (SPA). Replaces the
deprecated S3 + CloudFront (`cdn`) module for the **web** surface.

Why Pages over S3 + CloudFront:

- **Zero egress cost** (static assets are the highest-egress path).
- **Native SPA routing** — deep-links fall back to `index.html` automatically;
  no CloudFront Function or custom-error-response wiring.
- **Free managed TLS** + custom domain on the same Cloudflare account as DNS.

Content is deployed out-of-band from CI with `wrangler pages deploy` — this
module only provisions the project shell, the custom domain, and the proxied
CNAME (Pages does not create the DNS record for a custom domain itself).

## Usage

```hcl
module "web" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/pages-web?ref=pages-web-v1.0.0"

  account_id  = var.cloudflare_account_id
  name        = "rova-develop-web"
  zone_id     = local.cloudflare_zone_id
  domain      = "rova-dev.qnsc.vn"
  record_name = "rova-dev"

  production_env_vars = {
    VITE_API_URL = "https://rova-api-dev.qnsc.vn"
  }
}
```

Deploy from CI:

```bash
wrangler pages deploy apps/web/dist \
  --project-name "$(tofu output -raw web_pages_project)" \
  --branch main
```

## Secrets

Pages **secrets** (a Pages Function's signing key, say) are set out of band, never through this module:

```bash
wrangler pages secret put EDGE_CLIENT_IP_SECRET --project-name "$(tofu output -raw web_pages_project)"
```

A value written through Terraform is stored in state in clear text, so the module has no `secrets` input. The project's
`secrets` are `ignore_changes`, so a secret set by hand is never planned away. A secret applies to NEW deployments only:
redeploy after setting or rotating one.

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `account_id` | Cloudflare account ID (not a secret) | — |
| `name` | Pages project name / `<name>.pages.dev` | — |
| `production_branch` | Branch treated as production | `main` |
| `production_env_vars` | Non-secret env vars for production | `{}` |
| `domain` | Custom domain (empty = pages.dev only) | `""` |
| `zone_id` | Zone ID for the custom domain | `""` |
| `record_name` | Subdomain for the custom domain | `""` |
| `comment` | DNS record comment | `""` |

## Outputs

| Name | Description |
|------|-------------|
| `project_name` | Pages project name (pass to `wrangler --project-name`) |
| `pages_dev_subdomain` | Default `<name>.pages.dev` hostname |
| `custom_domain` | Custom domain, or `null` when only pages.dev is used |

## Prerequisites

- Cloudflare **Pages** enabled on the account.
- The caller-configured Cloudflare API token must include **Pages: Edit**.
- The `cloudflare` provider is configured by the calling stack.
