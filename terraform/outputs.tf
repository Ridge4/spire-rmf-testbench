output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Private API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_oidc_issuer" {
  description = "OIDC issuer URL for the cluster."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN, when created."
  value       = try(aws_iam_openid_connect_provider.this[0].arn, null)
}

output "vpc_id" {
  description = "Testbench VPC ID."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = aws_subnet.private[*].id
}

output "jump_host_id" {
  description = "Jump host instance ID, for SSM Session Manager."
  value       = try(aws_instance.jump[0].id, null)
}

output "ssm_connect_command" {
  description = "Open a shell on the jump host."
  value       = try("aws ssm start-session --target ${aws_instance.jump[0].id} --region ${var.region}", null)
}

output "kubeconfig_command" {
  description = "Run this on the jump host to configure kubectl."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region}"
}

output "flow_log_group" {
  description = "VPC flow log group; evidence that no traffic left the enclave."
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "spire_datastore_endpoint" {
  description = "RDS endpoint for the SPIRE datastore."
  value       = aws_db_instance.spire.address
}

output "spire_datastore_secret_arn" {
  description = "Secrets Manager ARN holding the datastore credentials."
  value       = aws_secretsmanager_secret.db.arn
}

output "spire_server_role_arn" {
  description = "IAM role assumed by the SPIRE server via Pod Identity."
  value       = aws_iam_role.spire_server.arn
}
