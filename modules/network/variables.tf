variable "name" {
  type        = string
  description = "Name prefix for all network resources."
}

variable "region" {
  type        = string
  description = "AWS region (used for VPC endpoint service names)."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC."
}

variable "azs" {
  type        = list(string)
  description = "Availability zones; one public/private/data subnet is created per AZ."
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs for public subnets, ordered to match azs."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs for private subnets, ordered to match azs."
}

variable "data_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs for data subnets, ordered to match azs."
}

variable "cluster_subnet_cidrs" {
  type        = list(string)
  default     = []
  description = <<-EOT
    CIDRs for the EKS cluster subnets — nodes and pods. Task 0.6, §3, §15c.

    EMPTY BY DEFAULT, so this is a no-op for every existing caller and their plans
    stay empty. Only the two runtime stacks that front a cluster set it.

    These are ADDITIONAL subnets, not a resize of `private_subnet_cidrs`. See the
    long comment on `aws_subnet.cluster` for why a resize is not available: AWS has
    no subnet-resize operation, `cidr_block` forces replacement, and runtime-prod
    is applied with ECS ENIs in its private subnets.

    SIZE THEM /20. EKS Auto Mode allocates a /28 prefix — sixteen addresses — per
    node up front, so a /24 holds roughly fifteen nodes' worth of prefixes per AZ
    before allocation fails, and §15c records what that looks like: pods stuck in
    `ContainerCreating` with no obvious cause.

    CHOOSE THE RANGE BY HAND, and check it. A /20 must start on a /20 boundary, so
    the obvious continuation of an existing /24 layout usually is not legal and the
    nearest legal block often swallows a tier already in use — in a 10.x.0.0/16
    with data subnets at 10.x.20-22.0/24, `10.x.16.0/20` covers 10.x.16.0 through
    10.x.31.255 and collides with all three of them. The validation below catches
    the size and the count; it cannot catch an overlap with a sibling tier.
  EOT

  validation {
    condition     = length(var.cluster_subnet_cidrs) == 0 || alltrue([for c in var.cluster_subnet_cidrs : tonumber(split("/", c)[1]) <= 20])
    error_message = "cluster_subnet_cidrs must be /20 or larger (a smaller prefix number). §15c: Auto Mode reserves a /28 per node, so a /24 exhausts at roughly fifteen nodes per AZ."
  }

  validation {
    condition     = length(var.cluster_subnet_cidrs) == 0 || length(var.cluster_subnet_cidrs) == length(var.azs)
    error_message = "cluster_subnet_cidrs must be empty or hold exactly one CIDR per entry in azs, in the same order — the module zips them positionally."
  }
}

variable "app_port" {
  type        = number
  default     = 3000
  description = "Port the app listens on (ALB → app ingress rule)."
}

variable "alb_ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the ALB on 80/443."
}

variable "nat_type" {
  type        = string
  default     = "gateway"
  description = <<-EOT
    NAT egress type for private subnets.
      "gateway"  — AWS managed NAT Gateway (~$33/mo). Use for prod (reliability, no ops).
      "instance" — fck-nat t4g.nano EC2 (~$3/mo). Use for dev (single AZ, saves ~$30/mo).
  EOT
  validation {
    condition     = contains(["gateway", "instance", "none"], var.nat_type)
    error_message = "nat_type must be 'gateway', 'instance' or 'none'."
  }
}

variable "multi_az_nat" {
  type        = bool
  default     = false
  description = "One NAT gateway per AZ (HA, prod) vs a single NAT. Ignored when nat_type = 'instance'."
}

variable "enable_interface_endpoints" {
  type        = bool
  default     = true
  description = <<-EOT
    Create Interface VPC endpoints (ecr.api, ecr.dkr, secretsmanager). These cost
    ~$7.20/mo each and reduce NAT data cost in prod. In dev (which already has a
    NAT) they are redundant — set false to save cost. S3 gateway endpoint is free
    and always created.
  EOT
}

variable "enable_flow_logs" {
  type        = bool
  default     = true
  description = "Capture VPC flow logs to CloudWatch (audit trail)."
}

variable "flow_log_retention_days" {
  type        = number
  default     = 30
  description = "Retention for the VPC flow log group."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources."
}

variable "nat_ssm_bastion" {
  type    = bool
  default = false

  description = <<-EOT
    Attach an SSM instance profile to the NAT instance and allow it to reach RDS and the
    cache, so a developer can port-forward to them from a laptop:

        aws ssm start-session --target <nat-instance-id> \
          --document-name AWS-StartPortForwardingSessionToRemoteHost \
          --parameters '{"host":["<rds-endpoint>"],"portNumber":["5432"],"localPortNumber":["15432"]}'

    Then point DBeaver at localhost:15432. The databases stay `publicly_accessible =
    false`; there is no inbound port, no SSH key and no second instance to pay for,
    because the NAT already runs and already has the egress the SSM agent needs.

    OFF BY DEFAULT because it creates a path from a laptop to the data tier. That is
    reasonable for develop and a deliberate decision for production — so it is a choice
    someone makes per environment, in a diff, rather than a default nobody chose.

    Access is governed by IAM (who may call ssm:StartSession) rather than by the network,
    and every session appears in CloudTrail. That auditability is what an SSH bastion
    does not give you.

    NOTE for the cache: transit encryption is on, so the local end speaks TLS —
    `redis-cli --tls -h 127.0.0.1 -p 16379`. A plain connection is refused.
  EOT

  # There is no NAT instance to attach anything to unless nat_type is "instance", so this
  # would otherwise apply cleanly and produce nothing — the reader would set the flag,
  # get a green apply, and find no way in. Refusing the pair says which of the two to
  # change. Most likely nat_type: "none" is for an environment with no tasks running,
  # which is not one anybody needs a database tunnel into.
  validation {
    condition     = !var.nat_ssm_bastion || var.nat_type == "instance"
    error_message = "nat_ssm_bastion requires nat_type = \"instance\" — there is no NAT instance to attach the profile to otherwise, and the flag would apply cleanly while doing nothing."
  }
}
