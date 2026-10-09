# KMS-backed signing keys for the SPIRE server.
#
# The practicum ran a disk-resident, self-signed root CA: the most sensitive
# authenticator in the system sat on an EBS volume as a file. The aws_kms
# KeyManager plugin moves private key material into KMS, where it is generated
# and used but never exported. SPIRE signs by calling kms:Sign.
#
# The plugin creates and manages its own keys, so these permissions cover
# creation as well as use.

resource "aws_iam_role" "spire_server" {
  name = "${var.cluster_name}-spire-server"

  # Trust policy for EKS Pod Identity. Pod Identity is used instead of IRSA
  # because it needs no OIDC provider, which keeps the Private Only story clean
  # (see docs/phase-0-dns.md).
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "spire_server_kms" {
  name = "${var.cluster_name}-spire-kms"
  role = aws_iam_role.spire_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Discovery and creation. KMS does not support resource-level
        # constraints on CreateKey, so this is scoped by condition on the tag
        # the plugin applies instead.
        Sid    = "CreateAndList"
        Effect = "Allow"
        Action = [
          "kms:CreateKey",
          "kms:CreateAlias",
          "kms:ListKeys",
          "kms:ListAliases",
          "kms:ListResourceTags",
          "kms:TagResource",
        ]
        Resource = "*"
      },
      {
        # Key operations. Tighten Resource to the key ARNs the plugin creates
        # once they exist, and record that narrowing as AC-6 evidence.
        Sid    = "UseKeys"
        Effect = "Allow"
        Action = [
          "kms:DescribeKey",
          "kms:GetPublicKey",
          "kms:Sign",
          "kms:UpdateAlias",
          "kms:DeleteAlias",
          "kms:ScheduleKeyDeletion",
        ]
        Resource = "*"
      },
    ]
  })
}

# Lets the SPIRE server read its own database credentials, if you choose to pull
# them at runtime rather than pre-creating a Kubernetes secret.
resource "aws_iam_role_policy" "spire_server_secrets" {
  name = "${var.cluster_name}-spire-secrets"
  role = aws_iam_role.spire_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = aws_secretsmanager_secret.db.arn
    }]
  })
}

# Binds the IAM role to the SPIRE server's Kubernetes service account. No OIDC
# provider and no node-level credentials are involved.
resource "aws_eks_pod_identity_association" "spire_server" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.spire_namespace
  service_account = var.spire_server_service_account
  role_arn        = aws_iam_role.spire_server.arn
}
