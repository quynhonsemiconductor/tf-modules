# Changelog

## [2.4.0](https://github.com/quynhonsemiconductor/tf-modules/compare/ecs-service-v2.3.2...ecs-service-v2.4.0) (2026-09-16)


### Features

* **product-profile:** the module, and time-based ECR retention ([#144](https://github.com/quynhonsemiconductor/tf-modules/issues/144)) ([ece31d4](https://github.com/quynhonsemiconductor/tf-modules/commit/ece31d4c918b060ecb869c0a143111598bf2d333))

## [2.3.2](https://github.com/QNSC-VN/qnsc-tf-modules/compare/ecs-service-v2.3.1...ecs-service-v2.3.2) (2026-08-30)


### Bug Fixes

* **ecs-service:** grant the task role kms:Decrypt for its own S3 reads ([#116](https://github.com/QNSC-VN/qnsc-tf-modules/issues/116)) ([01f89ec](https://github.com/QNSC-VN/qnsc-tf-modules/commit/01f89ecb54f54726cde499ec54417b114a598825))

## [2.3.1](https://github.com/QNSC-VN/qnsc-tf-modules/compare/ecs-service-v2.3.0...ecs-service-v2.3.1) (2026-08-27)


### Bug Fixes

* **ecs-service:** grant task role s3:GetBucketLocation ([#92](https://github.com/QNSC-VN/qnsc-tf-modules/issues/92)) ([285bb29](https://github.com/QNSC-VN/qnsc-tf-modules/commit/285bb2986e48f06416f47f54173eb5d430792c39))

## [2.3.0](https://github.com/QNSC-VN/qnsc-tf-modules/compare/ecs-service-v2.2.0...ecs-service-v2.3.0) (2026-08-27)


### Features

* **ecs-service:** add use_firelens to switch the primary container's log driver ([#88](https://github.com/QNSC-VN/qnsc-tf-modules/issues/88)) ([87ffc4a](https://github.com/QNSC-VN/qnsc-tf-modules/commit/87ffc4a563e8ea1c46f86aaeb831eaa8315affcc))

## [2.2.0](https://github.com/QNSC-VN/qnsc-tf-modules/compare/ecs-service-v2.1.1...ecs-service-v2.2.0) (2026-08-27)


### Features

* **ecs-service:** add execution_s3_bucket_arns, mirroring the existing ([108dced](https://github.com/QNSC-VN/qnsc-tf-modules/commit/108dced3d5a4d104d20eddcc4843813a474fe0b8))
* **firelens-agent:** FireLens log router, dual-write to CloudWatch and Grafana ([#86](https://github.com/QNSC-VN/qnsc-tf-modules/issues/86)) ([108dced](https://github.com/QNSC-VN/qnsc-tf-modules/commit/108dced3d5a4d104d20eddcc4843813a474fe0b8))

## [2.1.1](https://github.com/QNSC-VN/qnsc-tf-modules/compare/ecs-service-v2.1.0...ecs-service-v2.1.1) (2026-07-31)


### Bug Fixes

* **ecs-service:** move autoscaling state instead of recreating it on upgrade ([#46](https://github.com/QNSC-VN/qnsc-tf-modules/issues/46)) ([a817c7d](https://github.com/QNSC-VN/qnsc-tf-modules/commit/a817c7d73cef35003e7a213a8e8307f651288e8f))

## [2.1.0](https://github.com/QNSC-VN/qnsc-tf-modules/compare/ecs-service-v2.0.0...ecs-service-v2.1.0) (2026-07-31)


### Features

* **ecs-service:** make autoscaling optional, for schedule-driven environments ([#44](https://github.com/QNSC-VN/qnsc-tf-modules/issues/44)) ([a8e8bbc](https://github.com/QNSC-VN/qnsc-tf-modules/commit/a8e8bbc3c58a5a6e5f0b1bf359ffb542fc778f58))

## [2.0.0](https://github.com/QNSC-VN/qnsc-tf-modules/compare/ecs-service-v1.4.0...ecs-service-v2.0.0) (2026-07-27)


### ⚠ BREAKING CHANGES

* `keep_tagged_count` and `tag_prefix_list` are replaced by `keep_release_count` / `release_tag_prefix` and `keep_build_count` / `build_tag_prefix`. No caller in this organisation passed the removed variables.

### Features

* cost-posture fixes across ecs-cluster, ecs-service, observability, secrets, ecr ([#36](https://github.com/QNSC-VN/qnsc-tf-modules/issues/36)) ([9a2eb3b](https://github.com/QNSC-VN/qnsc-tf-modules/commit/9a2eb3bea6eb3995234cab5938f137b2c69efb0f))

## [1.4.0](https://github.com/QNSC-VN/qnsc-tf-modules/compare/ecs-service-v1.3.0...ecs-service-v1.4.0) (2026-07-24)


### Features

* **ecs-service:** task_secret_arns for runtime secret reads by the task role ([#30](https://github.com/QNSC-VN/qnsc-tf-modules/issues/30)) ([41b3731](https://github.com/QNSC-VN/qnsc-tf-modules/commit/41b3731ec74e89bbcdb44459b40cddff713a7aef))
