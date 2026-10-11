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
| 5 | FIPS 140-3 investigation: validated module for SPIRE, gap for Envoy | SC-13 | documented |
| 6 | mTLS on the validated Go module, no proxy; wrong-identity test | SC-13, SC-8, AC-3 | done |

## Layout

```
terraform/        infrastructure: VPC, EKS, RDS, KMS, ECR, logging
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
  deploy.sh               the whole quickstart as one idempotent command
  phase0-evidence.sh      boundary evidence, inside and outside the enclave
  build-fips-workloads.sh build the go-spiffe workloads on the validated module
  pre-destroy-cleanup.sh  orphaned ENIs and SPIRE-created KMS keys
evidence/         captured artifacts, organized by phase
docs/             build notes and findings
```

Set `use_fips_endpoints = true` to switch the AWS interface endpoints to their
`-fips` variants where a service publishes one. Off by default: the testbench
runs in a commercial region and makes no FIPS claim about its AWS calls. See
`docs/phase-5-fips.md`.

`helm/spire-values.yaml` is a single file rather than one per phase: there is
one SPIRE release and later phases upgrade it in place. Comments in the file
mark which settings belong to which phase.

`evidence/` is the point of the repository. Each phase deposits the logs and
configuration that the paper cites, so a reviewer can trace every claim back to
an artifact.

## Quickstart

One command deploys everything, from an empty AWS account to running workloads
with mTLS, audit telemetry and FIPS-validated transport.

**Authenticate to AWS first.** The script creates a VPC, an EKS cluster, an RDS
instance, KMS keys and ECR repositories, and bills whichever account your
credentials point at. It checks before doing anything and stops with
instructions if you are not signed in, then asks you to confirm the account.

```bash
aws sts get-caller-identity        # confirm who and where you are

./scripts/deploy.sh --plan-only    # review the Terraform plan first
./scripts/deploy.sh                # about 30 minutes
```

It is idempotent, so a failed run can be repeated without redoing the slow
parts. `SKIP_FIPS=1` skips the Phase 6 build if Docker is unavailable, and
`CONFIRM=1` skips the account prompt for unattended runs.

Most of the 30 minutes is Terraform building EKS and RDS, and Docker pushing
image layers to ECR. The steps below are what the script does, for anyone who
wants to run them individually or understand the ordering.

### Prerequisites

- Terraform >= 1.6
- AWS CLI v2, **already authenticated** (`aws configure`, `aws sso login`, or
  an exported `AWS_PROFILE`) to an account where you can create VPCs, EKS, RDS,
  KMS and ECR resources. Verify with `aws sts get-caller-identity` before
  starting; everything downstream fails without it.
- The AWS Session Manager plugin (`session-manager-plugin` on your PATH)
- kubectl and Helm
- Docker, for building the Phase 6 workloads
- `crane` is preferred for mirroring images; the script falls back to Docker

### 1. Infrastructure

```bash
cd terraform
terraform init
terraform plan -out tf.plan      # review: expect no NAT or internet gateway
terraform apply tf.plan
cd ..
```

Run this from your workstation, not the in-VPC jump host. Creating the IAM OIDC
provider needs public DNS, and the enclave deliberately has none. That ordering
is the compliant replacement for the public-resolver workaround used in the
original build; see `docs/phase-0-dns.md`.

This also creates the ECR repositories, which the next step pushes into. About
20 minutes, mostly the EKS control plane.

### 2. Mirror the container images

The cluster cannot reach ghcr.io, registry.k8s.io, docker.io or cgr.dev. Every
image it runs has to be served from this account first.

```bash
./scripts/mirror-images.sh                              # the SPIRE stack
./scripts/mirror-images.sh manifests/phase-3/00-images.txt   # Envoy, curl
./scripts/mirror-images.sh manifests/phase-4/00-images.txt   # Fluent Bit
```

### 3. Build the FIPS workloads

```bash
cd fips-workloads
docker run --rm -v "$PWD":/src -w /src golang:1.25 go mod tidy   # if go.sum is absent
cd ..
./scripts/build-fips-workloads.sh
```

The build asserts that `GOFIPS140` is recorded in the binaries and that no
BoringCrypto symbols are present. It fails rather than producing something that
looks FIPS-enabled and is not.

### 4. Connect

The API endpoint is private, so kubectl reaches it through an SSM port forward.
`scripts/connect.sh` reads everything from Terraform state, so nothing has to be
remembered after a rebuild even though the endpoint hostname changes each time.

```bash
./scripts/connect.sh tunnel       # terminal 1: leave this running
```

```bash
./scripts/connect.sh kubeconfig   # terminal 2
./scripts/connect.sh secret       # namespace + datastore secret
```

`connect.sh secret` prints the RDS endpoint. SSM sessions time out when idle and
any long Helm command will fail with a TLS handshake timeout when that happens,
so run `./scripts/connect.sh check` before starting one.

### 5. Set the account-specific values

Three files carry an account ID or an endpoint that differs per deployment:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
RDS=$(cd terraform && terraform output -raw spire_datastore_endpoint)

sed -i "s/401352756244/${ACCOUNT}/g" helm/spire-values.yaml
sed -i "s|spire-cluster-spire\..*\.rds\.amazonaws\.com|${RDS}|" helm/spire-values.yaml
sed -i "s/<ACCOUNT_ID>/${ACCOUNT}/g; s/401352756244/${ACCOUNT}/g" manifests/phase-6/*.yaml
```

Also change `global.spire.trustDomain` and `spire-server.caSubject` in
`helm/spire-values.yaml` if you want your own names rather than
`spire-rmf.lab`. The CA subject only takes effect when the CA rotates, which is
a finding in itself; see `evidence/phase-1/README.md`.

### 6. Deploy SPIRE

```bash
helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/
helm repo update

helm install spire-crds spiffe/spire-crds -n spire-server --version 0.6.1
helm install spire spiffe/spire -n spire-server \
  --version 0.30.3 --values helm/spire-values.yaml

kubectl -n spire-server get pods -w
```

All five pods should reach Running: server, two agents, two CSI drivers.

### 7. Deploy the workloads

```bash
kubectl apply -f manifests/phase-2/     # scoped identities and the denial test
kubectl apply -f manifests/phase-3/     # Envoy mTLS pair
kubectl apply -f manifests/phase-4/     # Fluent Bit log shipper
kubectl apply -f manifests/phase-6/     # FIPS workloads and wrong-identity test
```

### 8. Verify

```bash
# scoped identities, and an unmatched workload denied
kubectl -n payments logs deploy/payments-api --tail=12
kubectl -n unauthorized logs deploy/rogue --tail=5

# mTLS through Envoy
kubectl -n payments logs deploy/echo-server -c envoy | grep MTLS

# mTLS on the FIPS 140-3 validated Go module
kubectl -n payments logs deploy/fips-echo-server | grep -E "FIPS|MTLS"

# a valid SVID with an unauthorised identity, refused
kubectl -n payments logs deploy/fips-wrong-identity --tail=5

# nothing running depends on a registry outside AWS
./scripts/image-inventory.sh
```

### 9. Tear down

EKS bills for the control plane hourly and the interface endpoints are billed
per hour per availability zone, so destroy when not actively working.

```bash
./scripts/pre-destroy-cleanup.sh            # report what would be cleaned
./scripts/pre-destroy-cleanup.sh --apply    # orphaned ENIs, SPIRE-created KMS keys
cd terraform && terraform destroy
```

Run the cleanup first. Two things outlive Terraform: orphaned VPC CNI network
interfaces block subnet deletion for 15-20 minutes, and the KMS keys SPIRE
created become permanently unmanageable once destroy removes the IAM role their
key policy names. See `docs/phase-1-kms.md`; two keys were lost this way before
the explicit key policy was added.

Commit any evidence before destroying. With `force_delete = true` on the ECR
repositories, the mirrored images go too, so a rebuild repeats steps 2 and 3.
Set it to false in `terraform/ecr.tf` to keep them between runs.

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
