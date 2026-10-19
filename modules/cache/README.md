# `cache` module

Valkey (Redis-compatible) on ElastiCache. Two modes:

| mode | What | Cost | Use |
| :--- | :--- | :--- | :-- |
| `serverless` (default) | ElastiCache Serverless, auto-scaling | ~$90/mo floor | prod |
| `node` | single `cache.t4g.micro`, encrypted in-transit + at-rest | ~$11/mo | dev |

> Serverless cannot be stopped. For real
> dev savings, use `mode = "node"`.

## Usage

```hcl
module "cache" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cache?ref=cache-v1.1.0"

  name              = "myproduct-prod"
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.sg_cache_id
  kms_key_arn       = local.kms_key_arn

  mode = "serverless"          # prod
  # mode = "node"              # dev (cheaper)

  max_data_storage_gb = 10
  max_ecpu_per_second = 10000
  tags                = { Environment = "prod" }
}
```

Node mode takes the engine version and apply timing:

```hcl
  node_engine_version = "8.1"    # Valkey 8 target; default "7.2" is unchanged for existing callers
  apply_immediately   = true     # develop only: apply now instead of in the maintenance window
  maintenance_window  = "sun:05:00-sun:06:00"
```

`node_engine_version` accepts `7.2`, `8.0`, `8.1`. ElastiCache's "8.2" is open-source Valkey 8.1 plus
the valkey-search module, so it is not a separate target here.

## Outputs

`endpoint`, `port`, `reader_endpoint` — work in both modes.

`cluster_id` — node mode only, `null` for serverless. The CloudWatch `CacheClusterId`
dimension every AWS/ElastiCache metric is published under (the provider's own
`member_clusters` value, not a guessed `<replication_group_id>-001` string) — pass it to
the `observability` module's `cache_cluster_id` input to get CPU/free-memory/eviction
alarms wired for this node. Not usable for serverless: it publishes a different metric
set entirely (`ElastiCacheProcessingUnits`, `BytesUsedForCache`, no
`FreeableMemory`/`Evictions` in the same shape).

## Requirements

- OpenTofu / Terraform `>= 1.9.0`
- AWS provider `>= 5.0`
