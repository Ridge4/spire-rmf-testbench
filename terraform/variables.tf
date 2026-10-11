variable "region" {
  description = "AWS region for the testbench."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "spire-cluster"
}

variable "kubernetes_version" {
  description = "EKS control plane version. Check the AWS docs for currently supported versions before applying."
  type        = string
  default     = "1.33"
}

variable "vpc_cidr" {
  description = "CIDR block for the testbench VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs. EKS requires at least two availability zones."
  type        = list(string)
  default     = ["10.42.1.0/24", "10.42.2.0/24"]
}

variable "node_instance_type" {
  description = "Worker node instance type."
  type        = string
  default     = "t3.large"
}

variable "node_desired_size" {
  description = "Desired worker node count."
  type        = number
  default     = 2
}

variable "jump_host_instance_type" {
  description = "Jump host size. The practicum used t3.micro and hit OOM crashes; t3.medium is the floor."
  type        = string
  default     = "t3.medium"
}

variable "create_jump_host" {
  description = "Create the SSM-managed jump host inside the VPC."
  type        = bool
  default     = true
}

variable "create_oidc_provider" {
  description = <<-EOT
    Create the IAM OIDC provider for IRSA.

    This resource must be created from a host that can resolve the public EKS OIDC
    endpoint. Run Terraform from your workstation, not from the in-VPC jump host.
    See docs/phase-0-dns.md. Pod Identity is used for in-cluster IAM, so this can
    be set to false if you do not need IRSA.
  EOT
  type        = bool
  default     = true
}

variable "owner_tag" {
  description = "Value for the Owner tag applied to all resources."
  type        = string
  default     = "spire-rmf-testbench"
}

# ---------------------------------------------------------------------------
# Phase 1
# ---------------------------------------------------------------------------

variable "rds_engine_version" {
  description = "PostgreSQL major version. Verify it is still a supported RDS version before applying."
  type        = string
  default     = "16"
}

variable "rds_instance_class" {
  description = "RDS instance class. db.t4g.micro is adequate for a testbench."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_multi_az" {
  description = <<-EOT
    Run the datastore Multi-AZ. Roughly doubles cost, so the default is false
    for routine work. Set true for the evidence run: the availability claim in
    the paper is only defensible with a standby in a second AZ.
  EOT
  type        = bool
  default     = false
}

variable "spire_namespace" {
  description = "Namespace the SPIRE server runs in."
  type        = string
  default     = "spire-server"
}

variable "spire_server_service_account" {
  description = "Service account name for the SPIRE server. Confirm against the chart before applying."
  type        = string
  default     = "spire-server"
}

# ---------------------------------------------------------------------------
# Phase 4
# ---------------------------------------------------------------------------

variable "audit_retention_days" {
  description = <<-EOT
    CloudWatch retention for identity audit records. 30 days suits a testbench.
    Federal systems commonly require far longer (AU-11 is typically read as at
    least one year online for moderate baselines), so state the testbench value
    as a deviation rather than a recommendation.
  EOT
  type        = number
  default     = 30
}

variable "denied_alarm_threshold" {
  description = "Identity denials in a 5-minute period before the alarm fires."
  type        = number
  default     = 10
}
