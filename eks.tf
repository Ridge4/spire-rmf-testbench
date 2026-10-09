data "aws_caller_identity" "current" {}

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster"
  description = "Additional security group for the EKS control plane ENIs"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Kubernetes API from inside the VPC"
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
    Name = "${var.cluster_name}-cluster"
  }
}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  # Control plane audit logging. Phase 4 cites these alongside the SPIRE logs,
  # and they are the evidence for "who called the Kubernetes API" that the
  # attestation chain depends on.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3,
  ]
}

# IAM OIDC provider for IRSA.
#
# Creating this requires resolving the public OIDC issuer hostname. Apply from
# your workstation, not from the in-VPC jump host; that is the compliant
# alternative to repointing a resolver at 8.8.8.8.
data "tls_certificate" "oidc" {
  count = var.create_oidc_provider ? 1 : 0
  url   = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  count = var.create_oidc_provider ? 1 : 0

  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc[0].certificates[0].sha1_fingerprint]
}

resource "aws_eks_addon" "this" {
  for_each = toset([
    "vpc-cni",
    "coredns",
    "kube-proxy",
    "eks-pod-identity-agent",
  ])

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}
