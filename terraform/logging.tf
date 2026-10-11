# Phase 4: identity telemetry off the cluster.
#
# The practicum's audit evidence was a point-in-time log snippet pulled from a
# pod, showing node attestation only. Three things were missing: workload SVID
# issuance events, any record of a failed attestation, and durable retention
# outside the cluster. A log that lives in a pod's stdout buffer satisfies
# neither AU-9 nor continuous monitoring, because deleting the pod deletes the
# evidence.

resource "aws_cloudwatch_log_group" "spire_identity" {
  name              = "/spire/${var.cluster_name}/identity"
  retention_in_days = var.audit_retention_days

  tags = {
    Name    = "${var.cluster_name}-spire-identity"
    Purpose = "AU-9 audit record retention"
  }
}

# ---------------------------------------------------------------------------
# Fluent Bit: ships SPIRE and workload logs to CloudWatch
# ---------------------------------------------------------------------------

resource "aws_iam_role" "fluent_bit" {
  name = "${var.cluster_name}-fluent-bit"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "fluent_bit" {
  name = "${var.cluster_name}-fluent-bit"
  role = aws_iam_role.fluent_bit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
        "logs:DescribeLogGroups",
      ]
      Resource = "${aws_cloudwatch_log_group.spire_identity.arn}:*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "fluent_bit" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "observability"
  service_account = "fluent-bit"
  role_arn        = aws_iam_role.fluent_bit.arn
}

# ---------------------------------------------------------------------------
# Metric filters: turn identity events into measurable signals
#
# This is what moves the evidence from "we keep logs" to continuous monitoring.
# A FedRAMP ConMon reviewer wants a time series and an alarm, not a text file.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "svid_issued" {
  name           = "${var.cluster_name}-svid-issued"
  log_group_name = aws_cloudwatch_log_group.spire_identity.name
  pattern        = "\"Signed X509 SVID\""

  metric_transformation {
    name          = "SvidIssued"
    namespace     = "SPIRE/${var.cluster_name}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "attestation_denied" {
  name           = "${var.cluster_name}-attestation-denied"
  log_group_name = aws_cloudwatch_log_group.spire_identity.name
  pattern        = "\"no identity issued\""

  metric_transformation {
    name          = "IdentityDenied"
    namespace     = "SPIRE/${var.cluster_name}"
    value         = "1"
    default_value = "0"
  }
}

# A denial is normal at workload startup, before the controller manager has
# reconciled. A sustained run of them is not: it means something is repeatedly
# asking for an identity it cannot have. The threshold is deliberately above
# routine startup noise.
resource "aws_cloudwatch_metric_alarm" "identity_denied" {
  alarm_name          = "${var.cluster_name}-identity-denied"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.denied_alarm_threshold
  period              = 300
  statistic           = "Sum"
  metric_name         = "IdentityDenied"
  namespace           = "SPIRE/${var.cluster_name}"
  treat_missing_data  = "notBreaching"

  alarm_description = "Sustained workload identity denials. Investigate: misconfigured ClusterSPIFFEID, or an unauthorised workload repeatedly requesting an SVID."
}
