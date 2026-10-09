# External datastore for the SPIRE server.
#
# Phase 1 replaces the bundled SQLite datastore. SQLite is single-writer, which
# made the practicum build both a single point of failure and a scaling ceiling:
# the server ran as one pod against one EBS volume whose StorageClass carried
# reclaimPolicy: Delete.
#
# Set rds_multi_az = true to make the availability claim defensible. It roughly
# doubles the cost, so the default is false for routine development; flip it on
# for the evidence run and capture the artifact then.

resource "random_password" "db" {
  length  = 32
  special = false # avoids connection-string quoting problems
}

resource "aws_db_subnet_group" "spire" {
  name       = "${var.cluster_name}-spire"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.cluster_name}-spire"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds"
  description = "PostgreSQL access from EKS worker nodes only"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.cluster_name}-rds"
  }
}

# Only the cluster security group may reach the database. Managed node group
# ENIs are members of this group, so this is the SPIRE server's path in.
resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from EKS cluster security group"
}

resource "aws_db_instance" "spire" {
  identifier     = "${var.cluster_name}-spire"
  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  db_name  = "spire"
  username = "spire"
  password = random_password.db.result
  port     = 5432

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.spire.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az                = var.rds_multi_az
  backup_retention_period = var.rds_multi_az ? 7 : 1
  deletion_protection     = false
  skip_final_snapshot     = true
  apply_immediately       = true

  performance_insights_enabled = false
  auto_minor_version_upgrade   = true

  tags = {
    Name = "${var.cluster_name}-spire-datastore"
  }
}

# The password is written to Secrets Manager rather than printed as a Terraform
# output, so it stays out of the repository and out of shell history. Phase 1
# docs show how to turn it into a Kubernetes secret.
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.cluster_name}/spire/datastore"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = aws_db_instance.spire.username
    password = random_password.db.result
    host     = aws_db_instance.spire.address
    port     = aws_db_instance.spire.port
    dbname   = aws_db_instance.spire.db_name
  })
}
