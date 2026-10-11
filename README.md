# spire-rmf-testbench

A reproducible SPIFFE/SPIRE testbench on Amazon EKS, built to generate the
evidence artifacts a federal assessor would need to validate ephemeral workload
identity against NIST SP 800-53 controls.

This repository is the rebuild supporting an extended version of the practicum
report *Ephemeral Workload Identity Under the Federal Risk Management
Framework*. The original testbench demonstrated SVID issuance; this one is built
to close the evidence gaps that report identified.

## Phases

| Phase | Goal | Controls addressed | Status |
|---|---|---|---|
| 0 | Private Only VPC and EKS foundation, compliant DNS | boundary / emulation fidelity | done |
| 1 | External datastore (RDS), KMS-backed keys, enforced TTL, ECR mirror | IA-5, SC-12, CM-7, RA-5 | done |
| 2 | Purpose-built namespaces, scoped ClusterSPIFFEIDs, negative test | AC-3, AC-6 | done |
| 3 | Live mTLS via Envoy SDS, identity-based authorisation | SC-8, AC-3 | done |
| 4 | Telemetry to CloudWatch, metric filters, denial alarm | AU-2, AU-3, AU-9 | done |
| 5 | FIPS 140-validated crypto investigation | SC-13 | planned |

## Layout

```
terraform/   infrastructure (Phase 0 onward)
helm/        SPIRE values files, per phase
manifests/   ClusterSPIFFEID resources and test workloads
evidence/    captured artifacts, organized by phase
docs/        build notes and findings
```

`evidence/` is the point of the repository. Each phase deposits the logs and
configuration that the paper cites, so a reviewer can trace every claim back to
an artifact.

## Phase 0 quickstart

Prerequisites: Terraform >= 1.6, AWS CLI v2 with credentials, and the Session
Manager plugin.

```bash
cd terraform
terraform init
terraform plan -out tf.plan     # review before applying
terraform apply tf.plan
```

Run Terraform **from your workstation**, not from the in-VPC jump host. See
`docs/phase-0-dns.md` for why that matters; it is the compliant replacement for
the public-resolver workaround used in the original build.

Connect to the jump host:

```bash
aws ssm start-session --target $(terraform output -raw jump_host_id)
```

Tear down when not actively working. EKS bills for the control plane hourly:

```bash
terraform destroy
```

## Cost note

A rough order of magnitude at current on-demand pricing: the EKS control plane
and two t3.large nodes together run a few dollars per day, and the thirteen
interface endpoints add a comparable amount since each is billed hourly per
availability zone. Set an AWS Budgets alarm before the first apply and destroy
between sessions. Confirm current pricing yourself; these are not quotes.

## What this is not

A production reference architecture. FIPS validation, multi-cluster federation,
and a hardened SPIRE control plane are out of scope until the phases above say
otherwise. Limitations are tracked in `docs/`.
