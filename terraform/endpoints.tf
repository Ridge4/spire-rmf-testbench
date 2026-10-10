resource "aws_security_group" "endpoints" {
  name        = "${var.cluster_name}-vpce"
  description = "Allows HTTPS from inside the VPC to interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-vpce"
  }
}

# S3 must be a gateway endpoint; ECR stores image layers in S3, so image pulls
# fail without it even when the ECR interface endpoints are present.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${var.cluster_name}-s3"
  }
}

# Interface endpoints.
#
# private_dns_enabled is what makes this work: each endpoint takes over DNS for
# its service name inside the VPC, so the standard SDK endpoints resolve to
# private addresses. This is the supported mechanism that the practicum's
# 8.8.8.8 workaround stood in for.
locals {
  interface_endpoints = [
    "ec2",          # CNI and node bootstrap
    "ec2messages",  # SSM
    "ssm",          # SSM
    "ssmmessages",  # SSM Session Manager
    "ecr.api",      # image pulls
    "ecr.dkr",      # image pulls
    "sts",          # IRSA and Pod Identity token exchange
    "eks",          # cluster describe
    "eks-auth",     # EKS Pod Identity
    "logs",         # CloudWatch Logs (Phase 4 telemetry)
    "kms",          # Phase 1 KMS-backed SPIRE key manager
    "tagging",      # Resource Groups Tagging API; SPIRE tag-based key discovery
    "elasticloadbalancing",
    "autoscaling",
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoints)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.cluster_name}-${each.value}"
  }
}
