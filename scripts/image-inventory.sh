#!/usr/bin/env bash
#
# Inventory every container image actually running in the cluster.
#
# `helm template | grep image:` undercounts. It misses init containers, tools
# images, and components that only render under certain conditions. During the
# Phase 1 build six separate image overrides had to be found one crash at a
# time, because each missing image only surfaced when a pod failed to start.
#
# This reads the live pod specs instead, which is the only reliable inventory,
# and flags anything still pointing at a registry outside the account. For an
# air-gapped deployment that list is the thing that has to be empty.
#
# Usage:
#   ./scripts/image-inventory.sh                      # all namespaces
#   ./scripts/image-inventory.sh spire-server         # one namespace
#   ./scripts/image-inventory.sh > evidence/phase-1/image-inventory.txt

set -euo pipefail

NS_ARG="${1:-}"
if [[ -n "$NS_ARG" ]]; then
  SCOPE=(-n "$NS_ARG")
  SCOPE_LABEL="namespace ${NS_ARG}"
else
  SCOPE=(--all-namespaces)
  SCOPE_LABEL="all namespaces"
fi

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '')"
REGION="${AWS_REGION:-us-east-1}"
ECR_HOST="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

echo "Image inventory: ${SCOPE_LABEL}"
echo "Generated: $(date -u)"
echo "Private registry: ${ECR_HOST}"
echo

# Every image reference on every pod, including init containers and ephemeral
# containers, which is exactly what the chart-template approach misses.
mapfile -t ALL < <(
  kubectl get pods "${SCOPE[@]}" -o jsonpath='
{range .items[*]}
{range .spec.initContainers[*]}{.image}{"\n"}{end}
{range .spec.containers[*]}{.image}{"\n"}{end}
{range .spec.ephemeralContainers[*]}{.image}{"\n"}{end}
{end}' 2>/dev/null | tr -s '\n' '\n' | sed '/^[[:space:]]*$/d' | sort -u
)

echo "=== All images in use (${#ALL[@]}) ==="
printf '  %s\n' "${ALL[@]}"
echo

# Three categories, not two.
#
#   own      images mirrored into this account's registry
#   aws      images from an AWS-managed ECR account (EKS addons: CNI, CoreDNS,
#            kube-proxy, Pod Identity agent). These reach the node over the same
#            ECR interface endpoints and need no internet route, so they are not
#            an egress dependency. They are still a supply-chain input and
#            belong in an ATO package, but they are not something to mirror.
#   external anything else: a registry outside AWS. In a disconnected enclave
#            this list must be empty.
OWN=(); AWS_MANAGED=(); EXTERNAL=()
for img in "${ALL[@]}"; do
  if [[ "$img" == "${ECR_HOST}/"* ]]; then
    OWN+=("$img")
  elif [[ "$img" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/ ]] \
    || [[ "$img" == public.ecr.aws/* ]]; then
    AWS_MANAGED+=("$img")
  else
    EXTERNAL+=("$img")
  fi
done

echo "=== Mirrored into this account (${#OWN[@]}) ==="
[[ ${#OWN[@]} -eq 0 ]] && echo "  none" || printf '  %s\n' "${OWN[@]}"
echo

echo "=== AWS-managed registries (${#AWS_MANAGED[@]}) ==="
if [[ ${#AWS_MANAGED[@]} -eq 0 ]]; then
  echo "  none"
else
  printf '  %s\n' "${AWS_MANAGED[@]}"
  echo
  echo "  Served over the ECR interface endpoints, so these pull without an"
  echo "  internet route and do not need mirroring. They remain supply-chain"
  echo "  inputs that an ATO package has to account for."
fi
echo

echo "=== External registries (${#EXTERNAL[@]}) ==="
if [[ ${#EXTERNAL[@]} -eq 0 ]]; then
  echo "  none: nothing running depends on a registry outside AWS"
else
  printf '  %s\n' "${EXTERNAL[@]}"
  echo
  echo "  Each of these needs an internet route and will fail in a disconnected"
  echo "  enclave. Mirror them: put them in a list and run"
  echo "    ./scripts/mirror-images.sh <list>"
fi
echo

# Pods that cannot pull are the symptom that reveals a missed image, so surface
# them explicitly rather than making someone notice a CrashLoop by eye.
echo "=== Pods unable to pull an image ==="
PULL_FAILURES="$(kubectl get pods "${SCOPE[@]}" \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}{range .status.initContainerStatuses[*]}{.state.waiting.reason}{" "}{end}{"\n"}{end}' 2>/dev/null \
  | grep -E "ImagePullBackOff|ErrImagePull" || true)"

if [[ -z "$PULL_FAILURES" ]]; then
  echo "  none"
else
  echo "$PULL_FAILURES" | sed 's/^/  /'
  echo
  echo "  Find the offending image with:"
  echo "    kubectl -n <ns> describe pod <pod> | grep -iE 'Image:|Failed to pull'"
fi
