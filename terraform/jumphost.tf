# Jump host reached through SSM Session Manager.

data "aws_ssm_parameter" "al2023" {
  count = var.create_jump_host ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_iam_role" "jump" {
  count = var.create_jump_host ? 1 : 0
  name  = "${var.cluster_name}-jump"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "jump_ssm" {
  count      = var.create_jump_host ? 1 : 0
  role       = aws_iam_role.jump[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "jump_eks" {
  count = var.create_jump_host ? 1 : 0
  name  = "${var.cluster_name}-jump-eks"
  role  = aws_iam_role.jump[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "jump" {
  count = var.create_jump_host ? 1 : 0
  name  = "${var.cluster_name}-jump"
  role  = aws_iam_role.jump[0].name
}

resource "aws_security_group" "jump" {
  count       = var.create_jump_host ? 1 : 0
  name        = "${var.cluster_name}-jump"
  description = "Jump host; egress only, reached via SSM"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-jump"
  }
}

resource "aws_instance" "jump" {
  count = var.create_jump_host ? 1 : 0

  ami                    = data.aws_ssm_parameter.al2023[0].value
  instance_type          = var.jump_host_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.jump[0].id]
  iam_instance_profile   = aws_iam_instance_profile.jump[0].name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 20
    encrypted   = true
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab

    dnf install -y git tar unzip
  EOT

  tags = {
    Name = "${var.cluster_name}-jump"
  }
}

# Cluster-admin access for the jump host role, via EKS access entries rather
# than the deprecated aws-auth ConfigMap.
resource "aws_eks_access_entry" "jump" {
  count         = var.create_jump_host ? 1 : 0
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.jump[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jump" {
  count         = var.create_jump_host ? 1 : 0
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.jump[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.jump]
}
