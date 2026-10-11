#!/usr/bin/env bash
#
# Build the go-spiffe client and server against the FIPS 140-3 validated Go
# Cryptographic Module, and push them to ECR.
#
# Run from your WORKSTATION: it needs Docker, internet access to fetch the Go
# toolchain and modules, and AWS credentials to push.
#
# The Dockerfile asserts that GOFIPS140 is recorded in the binary and that no
# BoringCrypto symbols are present, so a build that silently produced a
# non-FIPS binary fails here rather than at review time.
#
# Usage:
#   ./scripts/build-fips-workloads.sh
#   GO_FIPS_MODULE=v1.0.0 TAG=v1 ./scripts/build-fips-workloads.sh

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

GO_VERSION="${GO_VERSION:-1.25}"
GO_FIPS_MODULE="${GO_FIPS_MODULE:-v1.0.0}"
TAG="${TAG:-v1}"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fips-workloads" && pwd)"

echo "Account   : ${ACCOUNT}"
echo "Go        : ${GO_VERSION}"
echo "FIPS mod  : ${GO_FIPS_MODULE}  (CMVP #5247 at v1.0.0)"
echo "Tag       : ${TAG}"
echo

if [[ ! -f "${SRC_DIR}/go.sum" ]]; then
  echo "go.sum is missing. Run 'go mod tidy' in fips-workloads/ first." >&2
  exit 1
fi

echo "==> Logging in to ECR"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR"

for component in server client; do
  repo="fips/echo-${component}"
  image="${ECR}/${repo}:${TAG}"

  echo
  echo "==> Building ${component}"
  docker build \
    --build-arg "GO_VERSION=${GO_VERSION}" \
    --build-arg "GO_FIPS_MODULE=${GO_FIPS_MODULE}" \
    --build-arg "TARGET=${component}" \
    -t "$image" \
    "$SRC_DIR"

  # Declared in terraform/ecr.tf; created here only if Terraform has not run.
  aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1 \
    || aws ecr create-repository \
         --repository-name "$repo" \
         --region "$REGION" \
         --image-scanning-configuration scanOnPush=true \
         --image-tag-mutability IMMUTABLE >/dev/null

  echo "==> Pushing ${image}"
  docker push "$image"
done

# Keep the build record as evidence: this is what shows the binaries were
# produced against the validated module. The runtime image is distroless and
# has no shell, so the file is copied out of a container rather than cat'd.
mkdir -p evidence/phase-6
{
  echo "=== FIPS workload build record ==="
  echo "date:       $(date -u)"
  echo "go version: ${GO_VERSION}"
  echo "GOFIPS140:  ${GO_FIPS_MODULE}"
  echo
  for component in server client; do
    echo "--- echo-${component} ---"
    cid="$(docker create "${ECR}/fips/echo-${component}:${TAG}")"
    docker cp "${cid}:/build-settings.txt" - | tar -xO
    docker rm "$cid" >/dev/null
    echo
  done
} > evidence/phase-6/build-settings.txt

echo
echo "Done."
echo "  ${ECR}/fips/echo-server:${TAG}"
echo "  ${ECR}/fips/echo-client:${TAG}"
echo
echo "Build record: evidence/phase-6/build-settings.txt"
