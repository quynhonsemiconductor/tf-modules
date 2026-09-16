# Changelog

## [2.1.0](https://github.com/quynhonsemiconductor/tf-modules/compare/ecr-v2.0.0...ecr-v2.1.0) (2026-09-16)


### Features

* **product-profile:** the module, and time-based ECR retention ([#144](https://github.com/quynhonsemiconductor/tf-modules/issues/144)) ([ece31d4](https://github.com/quynhonsemiconductor/tf-modules/commit/ece31d4c918b060ecb869c0a143111598bf2d333))

## [2.0.0](https://github.com/QNSC-VN/qnsc-tf-modules/compare/ecr-v1.1.0...ecr-v2.0.0) (2026-07-27)


### ⚠ BREAKING CHANGES

* `keep_tagged_count` and `tag_prefix_list` are replaced by `keep_release_count` / `release_tag_prefix` and `keep_build_count` / `build_tag_prefix`. No caller in this organisation passed the removed variables.

### Features

* cost-posture fixes across ecs-cluster, ecs-service, observability, secrets, ecr ([#36](https://github.com/QNSC-VN/qnsc-tf-modules/issues/36)) ([9a2eb3b](https://github.com/QNSC-VN/qnsc-tf-modules/commit/9a2eb3bea6eb3995234cab5938f137b2c69efb0f))
