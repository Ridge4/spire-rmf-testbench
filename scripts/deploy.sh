#!/usr/bin/env bash
#
# Deploy the whole testbench, from an empty AWS account to running workloads.
#
# This is the README quickstart as one command. It is idempotent: each step
# checks whether its work is already done, so it can be re-run after a failure
# without repeating the slow parts.
#
# Run from your WORKSTATION. Creating the IAM OIDC provider needs public DNS,
# which the enclave deliberately does not have; see docs/phase-0-dns.md.
#
# Usage:
#   ./scripts/deploy.sh              # everything
#   ./scripts/deploy.sh --plan-only  # stop after terraform plan, for review
#   SKIP_FIPS=1 ./scripts/deploy.sh  # skip the Phase 6 build (needs Docker)
#   CONFIRM=1 ./scripts/deploy.sh    # skip the account confirmation prompt
#
# You must be authenticated to AWS first. The script checks and stops with
# instructions if not.
#
# Expect roughly 30 minutes, almost all of it Terraform building EKS and RDS,
# and Docker pushing image layers to ECR.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

REGION="${AWS_REGION:-us-east-1}"
SPIRE_CHART_VERSION="${SPIRE_CHART_VERSION:-0.30.3}"
SPIRE_CRDS_VERSION="${SPIRE_CRDS_VERSION:-0.6.1}"
PLAN_ONLY=false
[[ "${1:-}" == "--plan-only" ]] && PLAN_ONLY=true

step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note()  { printf '    %s\n' "$*"; }
die()   { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
step "Checking prerequisites"
# ---------------------------------------------------------------------------
for tool in terraform aws kubectl helm; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done
command -v session-manager-plugin >/dev/null \
  || die "session-manager-plugin is not on PATH; kubectl cannot reach the private endpoint without it"

if [[ "${SKIP_FIPS:-}" != "1" ]]; then
  command -v docker >/dev/null \
    || die "docker is required for the Phase 6 build; set SKIP_FIPS=1 to skip it"
fi

# Everything downstream creates AWS resources, so fail here with something
# readable rather than part way through Terraform.
if ! CALLER="$(aws sts get-caller-identity --output json 2>&1)"; then
  printf '\n\033[31mNot authenticated to AWS.\033[0m\n\n' >&2
  printf 'aws sts get-caller-identity said:\n%s\n\n' "$CALLER" >&2
  cat >&2 <<'HELP'
Authenticate first, by whichever route your account uses:

  aws configure                          # long-lived access keys
  aws sso login --profile <profile>      # IAM Identity Center
  export AWS_PROFILE=<profile>           # select an existing profile

Then confirm, and check the account is the one you intend to build in:

  aws sts get-caller-identity

This deployment creates a VPC, an EKS cluster, an RDS instance, KMS keys and
ECR repositories. It will bill the account it is pointed at.
HELP
  exit 1
fi

ACCOUNT="$(echo "$CALLER" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])')"
CALLER_ARN="$(echo "$CALLER" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Arn"])')"

note "account ${ACCOUNT}, region ${REGION}"
note "identity ${CALLER_ARN}"

# A wrong-account deployment is expensive and annoying to unwind, so make the
# target explicit before anything is created. Set CONFIRM=1 to skip, for CI.
if [[ "${CONFIRM:-}" != "1" && -t 0 ]]; then
  read -r -p "    Deploy into account ${ACCOUNT}? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted"
fi

# ---------------------------------------------------------------------------
step "1/8  Infrastructure"
# ---------------------------------------------------------------------------
pushd terraform >/dev/null
terraform init -input=false
terraform plan -input=false -out tf.plan

if [[ "$PLAN_ONLY" == true ]]; then
  note "stopping after plan as requested"
  note "review it, then re-run without --plan-only"
  popd >/dev/null
  exit 0
fi

terraform apply -input=false tf.plan
rm -f tf.plan

CLUSTER="$(terraform output -raw cluster_name)"
RDS_HOST="$(terraform output -raw spire_datastore_endpoint)"
EKS_HOST="$(terraform output -raw cluster_endpoint | sed 's#https://##')"
JUMP_HOST="$(terraform output -raw jump_host_id)"
popd >/dev/null
note "cluster ${CLUSTER}"

# ---------------------------------------------------------------------------
step "2/8  Mirroring container images into ECR"
# ---------------------------------------------------------------------------
# The cluster cannot reach ghcr.io, registry.k8s.io, docker.io or cgr.dev.
# Already-present images are skipped by the push, so re-running is cheap.
./scripts/mirror-images.sh
for list in manifests/phase-3/00-images.txt manifests/phase-4/00-images.txt; do
  [[ -f "$list" ]] && ./scripts/mirror-images.sh "$list"
done

# ---------------------------------------------------------------------------
step "3/8  Building the FIPS workloads"
# ---------------------------------------------------------------------------
if [[ "${SKIP_FIPS:-}" == "1" ]]; then
  note "skipped (SKIP_FIPS=1); Phase 6 manifests will not be applied"
else
  if [[ ! -f fips-workloads/go.sum ]]; then
    note "generating go.sum"
    docker run --rm -v "$PWD/fips-workloads":/src -w /src golang:1.25 go mod tidy
  fi
  # The build asserts GOFIPS140 is recorded and no BoringCrypto symbols exist.
  # It fails rather than producing something that looks FIPS-enabled and is not.
  ./scripts/build-fips-workloads.sh
fi

# ---------------------------------------------------------------------------
step "4/8  Opening the SSM tunnel"
# ---------------------------------------------------------------------------
# The API endpoint is private. A background port forward gives kubectl and helm
# a path to it for the rest of this script.
if kubectl get --raw /version >/dev/null 2>&1; then
  note "cluster already reachable; leaving the existing connection alone"
  TUNNEL_PID=""
else
  aws ssm start-session \
    --target "$JUMP_HOST" --region "$REGION" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=${EKS_HOST},portNumber=443,localPortNumber=8443" \
    >/dev/null 2>&1 &
  TUNNEL_PID=$!
  trap '[[ -n "${TUNNEL_PID}" ]] && kill "${TUNNEL_PID}" 2>/dev/null || true' EXIT

  note "waiting for the tunnel"
  CLUSTER_ARN="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
  kubectl config set-cluster "$CLUSTER_ARN" --server="https://localhost:8443" >/dev/null
  kubectl config set-cluster "$CLUSTER_ARN" --tls-server-name="$EKS_HOST" >/dev/null

  for i in $(seq 1 30); do
    kubectl get --raw /version >/dev/null 2>&1 && break
    [[ $i -eq 30 ]] && die "tunnel did not come up; try ./scripts/connect.sh tunnel by hand"
    sleep 2
  done
fi
note "cluster reachable"

# ---------------------------------------------------------------------------
step "5/8  Namespace and datastore secret"
# ---------------------------------------------------------------------------
./scripts/connect.sh secret

# ---------------------------------------------------------------------------
step "6/8  Rewriting account-specific values"
# ---------------------------------------------------------------------------
# Three files carry an account ID or an RDS endpoint that differs per
# deployment. Rewriting in place keeps the repository usable in any account.
sed -i -E "s/[0-9]{12}(\.dkr\.ecr\.)/${ACCOUNT}\1/g; s/<ACCOUNT_ID>/${ACCOUNT}/g" \
  helm/spire-values.yaml manifests/phase-6/*.yaml
sed -i -E "s#host: .*\.rds\.amazonaws\.com#host: ${RDS_HOST}#" helm/spire-values.yaml
sed -i -E "s/arn:aws:iam::[0-9]{12}:/arn:aws:iam::${ACCOUNT}:/g" helm/spire-values.yaml
note "account ${ACCOUNT}, datastore ${RDS_HOST}"

# ---------------------------------------------------------------------------
step "7/8  Installing SPIRE"
# ---------------------------------------------------------------------------
helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/ >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install spire-crds spiffe/spire-crds \
  -n spire-server --version "$SPIRE_CRDS_VERSION" >/dev/null
note "CRDs ${SPIRE_CRDS_VERSION}"

helm upgrade --install spire spiffe/spire \
  -n spire-server --version "$SPIRE_CHART_VERSION" \
  --values helm/spire-values.yaml >/dev/null
note "chart ${SPIRE_CHART_VERSION}"

kubectl -n spire-server rollout status statefulset/spire-server --timeout=300s
kubectl -n spire-server rollout status daemonset/spire-agent --timeout=300s

# ---------------------------------------------------------------------------
step "8/8  Deploying workloads"
# ---------------------------------------------------------------------------
for phase in 2 3 4; do
  [[ -d "manifests/phase-${phase}" ]] && kubectl apply -f "manifests/phase-${phase}/" >/dev/null
done
if [[ "${SKIP_FIPS:-}" != "1" ]]; then
  kubectl apply -f manifests/phase-6/ >/dev/null
fi

note "waiting for workloads to obtain identities"
sleep 45

# ---------------------------------------------------------------------------
step "Results"
# ---------------------------------------------------------------------------
echo
echo "--- scoped identity (AC-6) ---"
kubectl -n payments logs deploy/payments-api --tail=8 2>/dev/null | grep -A4 "SPIFFE ID" || echo "  not ready yet"

echo
echo "--- unmatched workload denied (AC-6) ---"
kubectl -n unauthorized logs deploy/rogue --tail=2 2>/dev/null || echo "  not ready yet"

echo
echo "--- mTLS through Envoy (SC-8) ---"
kubectl -n payments logs deploy/echo-server -c envoy 2>/dev/null | grep MTLS | tail -1 || echo "  not ready yet"

if [[ "${SKIP_FIPS:-}" != "1" ]]; then
  echo
  echo "--- mTLS on the FIPS 140-3 validated Go module (SC-13) ---"
  kubectl -n payments logs deploy/fips-echo-server 2>/dev/null | grep -E "FIPS|MTLS" | tail -2 || echo "  not ready yet"

  echo
  echo "--- valid SVID, unauthorised identity, refused (AC-3) ---"
  kubectl -n payments logs deploy/fips-wrong-identity --tail=2 2>/dev/null || echo "  not ready yet"
fi

echo
echo "--- supply chain ---"
./scripts/image-inventory.sh | grep -A1 "=== External registries"

cat <<EOF

Deployed.

The SSM tunnel this script opened closes when it exits. To work with the
cluster afterwards, open your own:

  ./scripts/connect.sh tunnel       # terminal 1
  ./scripts/connect.sh kubeconfig   # terminal 2

Tear down when you are finished. EKS and the interface endpoints bill hourly:

  ./scripts/pre-destroy-cleanup.sh --apply
  cd terraform && terraform destroy
EOF
