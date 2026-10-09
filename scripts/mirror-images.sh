#!/usr/bin/env bash

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

MAPPING_FILE="evidence/phase-1/image-mirror-map.txt"
mkdir -p "$(dirname "$MAPPING_FILE")"
: > "$MAPPING_FILE"

for src in "${IMAGES[@]}"; do
  [[ -z "$src" ]] && continue
  repo="$(repo_for "$src")"
  tag="$(tag_for "$src")"
  dst="${ECR}/${repo}:${tag}"

  echo "==> ${src}"
  echo "    -> ${dst}"

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

  printf '%s -> %s\n' "$src" "$dst" >> "$MAPPING_FILE"
done

echo
echo "Done. Mapping written to ${MAPPING_FILE}"
echo
echo "Add to helm/phase-1/spire-values.yaml (adjust keys to the chart's schema):"
cat <<EOF

global:
  spire:
    image:
      registry: ${ECR}

spire-server:
  image:
    registry: ${ECR}
    repository: spiffe/spire-server
  controllerManager:
    image:
      registry: ${ECR}
      repository: spiffe/spire-controller-manager

spire-agent:
  image:
    registry: ${ECR}
    repository: spiffe/spire-agent

spiffe-csi-driver:
  image:
    registry: ${ECR}
    repository: spiffe/spiffe-csi-driver
  nodeDriverRegistrar:
    image:
      registry: ${ECR}
      repository: sig-storage/csi-node-driver-registrar
EOF
