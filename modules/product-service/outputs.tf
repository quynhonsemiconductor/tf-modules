output "service_name" {
  description = "ECS service name."
  value       = module.service.service_name
}

output "service_arn" {
  value = module.service.service_arn
}

output "task_role_arn" {
  description = "Task role — grant runtime access (S3, SQS, Secrets at runtime) to this."
  value       = module.service.task_role_arn
}

output "execution_role_arn" {
  description = "Execution role — boot-time secret injection and image pull."
  value       = module.service.execution_role_arn
}

output "task_definition_arn" {
  value = module.service.task_definition_arn
}

output "log_group_name" {
  description = "Shared by the service and every sidecar, so a failure and the request it dropped land in one stream."
  value       = module.service.log_group_name
}

output "target_group_arn" {
  description = "Null unless ingress.mode = \"alb\". Feed to the observability module's target_group_arns for latency and unhealthy-host alarms."
  value       = module.service.target_group_arn
}

output "tunnel_origin_url" {
  description = <<-EOT
    The origin the Cloudflare tunnel forwards to, or null when ingress.mode is not `tunnel`.
    Set this as the service's origin in the tunnel's public-hostname route.
  EOT
  value       = length(module.tunnel_agent) > 0 ? module.tunnel_agent[0].origin_url : null
}

output "ingress_mode" {
  description = "Echoes the resolved mode, so a caller wiring alarms can branch on it without restating the condition."
  value       = var.ingress.mode
}

output "otel_enabled" {
  description = "Whether the collector sidecar actually produced a container. False when otlp_endpoint is empty, even with otel.enabled = true."
  value       = length(module.otel_agent) > 0 ? module.otel_agent[0].enabled : false
}
