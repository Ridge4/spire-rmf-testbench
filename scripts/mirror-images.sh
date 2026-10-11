#!/usr/bin/env bash
#
# Mirror the SPIRE chart's container images into ECR.
#
# The Private Only cluster cannot reach ghcr.io, registry.k8s.io, docker.io or
# cgr.dev. Rather than open egress, images are copied into the account's own ECR
# registry, which the cluster already reaches over the interface endpoints
# created in Phase 0. This is the same pattern a real air-gapped federal
# deployment uses.
#
# Run from your WORKSTATION (needs internet + AWS credentials), not the jump host.
#
# Requires: aws CLI, and either crane (preferred) or docker.
#   crane: https://github.com/google/go-containerregistry  (no daemon needed)
#
# Usage:
#   ./scripts/mirror-images.sh                 # mirror the default list
#   ./scripts/mirror-images.sh images.txt      # mirror a list you rendered
#
# Produce a list from the chart like this:
#   helm template spire spiffe/spire --version 0.30.3 \
#     --values helm/spire-values.yaml \
#     | grep -oE 'image: .*' | tr -d '"' | awk '{print $2}' | sort -u > images.txt

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

# Default list, rendered from spiffe/spire 0.30.3. Override by passing a file.
DEFAULT_IMAGES=(
  "ghcr.io/spiffe/spire-server:1.15.3"
  "ghcr.io/spiffe/spire-agent:1.15.3"
  "ghcr.io/spiffe/spire-controller-manager:0.8.0"
  "ghcr.io/spiffe/spiffe-csi-driver:0.2.7"
  "ghcr.io/spiffe/spiffe-helper:0.11.0"
  "ghcr.io/spiffe/oidc-discovery-provider:1.15.3"
  "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.15.0"
  "registry.k8s.io/kubectl:v1.37.0"
  "docker.io/smallstep/step-cli:0.30.2"
  "busybox:1.37.0-uclibc"
  "cgr.dev/chainguard/bash:latest"
  "cgr.dev/chainguard/min-toolkit-debug:latest"
)

if [[ $# -ge 1 && -f "$1" ]]; then
  mapfile -t IMAGES < "$1"
else
  IMAGES=("${DEFAULT_IMAGES[@]}")
fi

if command -v crane >/dev/null 2>&1; then
  COPIER="crane"
elif command -v docker >/dev/null 2>&1; then
  COPIER="docker"
else
  echo "ERROR: need either crane or docker on PATH." >&2
  exit 1
fi

echo "Account : ${ACCOUNT}"
echo "Region  : ${REGION}"
echo "Registry: ${ECR}"
echo "Copier  : ${COPIER}"
echo

echo "==> Logging in to ECR"
aws ecr get-login-password --region "$REGION" \
  | { [[ $COPIER == crane ]] \
      && crane auth login --username AWS --password-stdin "$ECR" \
      || docker login --username AWS --password-stdin "$ECR"; }

# Turn a source reference into an ECR repository name.
#   ghcr.io/spiffe/spire-server:1.15.3  -> spiffe/spire-server
#   registry.k8s.io/kubectl:v1.37.0     -> kubectl
#   busybox:1.37.0-uclibc               -> library/busybox
repo_for() {
  local ref="$1" path
  ref="${ref%%@*}"                 # drop any digest
  path="${ref%:*}"                 # drop tag
  case "$path" in
    */*)
      # strip a leading registry host (contains a dot or is localhost)
      local first="${path%%/*}"
      if [[ "$first" == *.* || "$first" == localhost* ]]; then
        path="${path#*/}"
      fi
      ;;
    *)
      path="library/${path}"       # bare docker.io official image
      ;;
  esac
  echo "$path"
}

tag_for() {
  local ref="${1%%@*}"
  [[ "$ref" == *:* ]] && echo "${ref##*:}" || echo "latest"
}

# The mapping is a cumulative inventory, not a per-run artifact. Images arrive
# across several phases (SPIRE in phase 1, Envoy and curl in phase 3, Fluent Bit
# in phase 4), and the complete list of what an air-gapped deployment must
# mirror is one of this repository's findings. Appending, and de-duplicating at
# the end, keeps the whole inventory in one place instead of each run clobbering
# the last.
MAPPING_FILE="${MAPPING_FILE:-evidence/image-mirror-map.txt}"
mkdir -p "$(dirname "$MAPPING_FILE")"
touch "$MAPPING_FILE"

for src in "${IMAGES[@]}"; do
  [[ -z "$src" ]] && continue
  repo="$(repo_for "$src")"
  tag="$(tag_for "$src")"
  dst="${ECR}/${repo}:${tag}"

  echo "==> ${src}"
  echo "    -> ${dst}"

  # Terraform declares the known repositories in terraform/ecr.tf. This
  # creates one only if a new image has been added since the last apply; add
  # it to the Terraform list afterwards so the registry set stays in code.
  aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1 \
    || aws ecr create-repository \
         --repository-name "$repo" \
         --region "$REGION" \
         --image-scanning-configuration scanOnPush=true \
         --image-tag-mutability IMMUTABLE >/dev/null

  if [[ $COPIER == crane ]]; then
    crane copy "$src" "$dst"
  else
    docker pull "$src"
    docker tag "$src" "$dst"
    docker push "$dst"
  fi

  printf '%-72s -> %s\n' "$src" "$dst" >> "$MAPPING_FILE"
done

# De-duplicate in place, keeping the file sorted so diffs between runs are
# readable and re-mirroring the same image does not add a second line.
sort -u -o "$MAPPING_FILE" "$MAPPING_FILE"

echo
echo "Mirrored ${#IMAGES[@]} image(s)."
echo "Cumulative inventory: ${MAPPING_FILE} ($(grep -c . "$MAPPING_FILE") images total)"
echo
echo "Chart images are overridden in helm/spire-values.yaml. Workload images are"
echo "referenced directly in manifests/. After any chart or image change, confirm"
echo "nothing still points upstream:"
echo
echo "  helm template spire spiffe/spire --version 0.30.3 \\"
echo "    --values helm/spire-values.yaml | grep -oE 'image: .*' | sort -u"
echo
echo "Note that this undercounts: init-container and tools images do not always"
echo "render as 'image:' lines. The reliable inventory comes from describing the"
echo "running pods. See docs/phase-1-images.md."
