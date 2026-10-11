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
| 3 | Live mTLS via Envoy SDS, identity-based authorisation | SC-8, AC-3 | in progress |
| 4 | Telemetry to CloudWatch, metric filters, denial alarm | AU-2, AU-3, AU-9 | done |
| 5 | FIPS 140-3 investigation: validated module for SPIRE, gap for Envoy | SC-13 | documented |
| 6 | mTLS on the validated Go module, no proxy; wrong-identity test | SC-13, SC-8, AC-3 | done |

## Layout

```
terraform/        infrastructure: VPC, EKS, RDS, KMS, logging
helm/             SPIRE chart values (one release, upgraded in place)
manifests/        per-phase Kubernetes resources
  phase-2/          namespaces, scoped ClusterSPIFFEIDs, test workloads
  phase-3/          Envoy mTLS peers and the negative test
  phase-4/          Fluent Bit log shipper
  phase-6/          go-spiffe FIPS workloads and the wrong-identity test
fips-workloads/   go-spiffe client and server, built with GOFIPS140
scripts/          operational helpers
  connect.sh        SSM tunnel, kubeconfig, datastore secret
  mirror-images.sh  copy container images into ECR
  image-inventory.sh      what is actually running, and what is not mirrored
  fips-check.sh           what cryptography the running binaries link
  phase0-evidence.sh      boundary evidence, inside and outside the enclave
  build-fips-workloads.sh build the go-spiffe workloads on the validated module
  pre-destroy-cleanup.sh  orphaned ENIs and SPIRE-created KMS keys
evidence/         captured artifacts, organized by phase
docs/             build notes and findings
```

`helm/spire-values.yaml` is a single file rather than one per phase: there is
one SPIRE release and later phases upgrade it in place. Comments in the file
mark which settings belong to which phase.

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

## Connecting to the cluster

The API endpoint is private, so kubectl reaches it through an SSM port forward.
`scripts/connect.sh` reads everything from Terraform state, so nothing needs to
be remembered or pasted after a rebuild even though the endpoint hostname
changes each time.

```bash
./scripts/connect.sh tunnel       # terminal 1: start the tunnel, leave it running
./scripts/connect.sh kubeconfig   # terminal 2: point kubectl at the tunnel
./scripts/connect.sh secret       # recreate the SPIRE datastore secret
```

Other subcommands: `check` (is the cluster reachable), `shell` (a shell on the
jump host), `info` (print cluster facts). Run with no arguments for usage.

SSM sessions time out when idle, and any long helm command will fail with a TLS
handshake timeout when that happens. `./scripts/connect.sh check` before
starting one is the cheap habit.

Tear down when not actively working. EKS bills for the control plane hourly,
and the interface endpoints are billed per hour per availability zone.

Run the cleanup script first. Two things outlive Terraform and cause trouble:
orphaned VPC CNI network interfaces block subnet deletion for 15-20 minutes,
and the KMS keys SPIRE created become permanently unmanageable once destroy
removes the IAM role their key policy names (see `docs/phase-1-kms.md`).

```bash
./scripts/pre-destroy-cleanup.sh            # report what would be cleaned
./scripts/pre-destroy-cleanup.sh --apply    # clean it up
cd terraform && terraform destroy
```

Commit any evidence first. The ECR repositories and mirrored images survive
destroy, so a rebuild does not repeat that step.

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
