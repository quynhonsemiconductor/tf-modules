output "vpc_id" {
  value       = aws_vpc.this.id
  description = "VPC ID."
}

output "public_subnet_ids" {
  value       = [for s in aws_subnet.public : s.id]
  description = "Public subnet IDs."
}

output "private_subnet_ids" {
  value       = [for s in aws_subnet.private : s.id]
  description = "Private subnet IDs (ECS tasks)."
}

output "data_subnet_ids" {
  value       = [for s in aws_subnet.data : s.id]
  description = "Data subnet IDs (RDS, cache)."
}

output "cluster_subnet_ids" {
  value       = [for s in aws_subnet.cluster : s.id]
  description = <<-EOT
    EKS cluster subnet IDs — the /20 tier that holds nodes and pods. Task 0.6.

    EMPTY unless `cluster_subnet_cidrs` was set, which is why `infra/live/cluster-*`
    must read THIS output rather than `private_subnet_ids`: the private tier is the
    ECS one and keeps its /24s (see `aws_subnet.cluster`).

    An empty list here is the failure mode to recognise. `aws_eks_cluster` rejects
    an empty `subnet_ids`, so a cluster stack pointed at this output before the
    runtime stack sets its CIDRs fails at PLAN with a validation error rather than
    creating something subtly wrong — which is the order this should fail in.
  EOT
}

output "sg_alb_id" {
  value       = aws_security_group.alb.id
  description = "ALB security group ID."
}

output "sg_app_id" {
  value       = aws_security_group.app.id
  description = "App (ECS) security group ID."
}

output "sg_rds_id" {
  value       = aws_security_group.rds.id
  description = "RDS security group ID."
}

output "sg_cache_id" {
  value       = aws_security_group.cache.id
  description = "Cache (Valkey/Redis/ElastiCache) security group ID."
}

output "nat_instance_id" {
  description = <<-EOT
    Instance id of the NAT box, or null when nat_type is not "instance".

    Exposed so the SSM port-forward command can be scripted or printed by the caller —
    it is the `--target` argument, and hunting for it in the console is the small friction
    that stops people using the safe path.
  EOT
  value       = var.nat_type == "instance" ? aws_instance.nat[0].id : null
}
