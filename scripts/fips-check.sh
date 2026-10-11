#!/usr/bin/env bash
#
# Report what cryptography the running components actually link.
#
# The point is to check the deployed binaries rather than the documentation. A
# chart value, a vendor page, or the phrase "FIPS compliant" is not evidence; an
# Active FIPS 140-3 certificate naming the exact deployed version is. This
# script gathers what can be observed from inside the cluster, and prints what
# still has to be confirmed by hand at csrc.nist.gov.
#
# Usage:
#   ./scripts/fips-check.sh
#   ./scripts/fips-check.sh > evidence/phase-5/fips-status.txt

set -uo pipefail

NS_SPIRE="${NS_SPIRE:-spire-server}"
NS_WORKLOAD="${NS_WORKLOAD:-payments}"
REGION="${AWS_REGION:-us-east-1}"

echo "FIPS posture check"
echo "Generated: $(date -u)"
echo
echo "Reference points, confirm status at csrc.nist.gov before citing:"
echo "  Go Cryptographic Module v1.0.0  CMVP #5247  FIPS 140-3 Level 1"
echo "  BoringSSL-FIPS                  FIPS 140-2 only; Historical since 2026-09-21"
echo

# ---------------------------------------------------------------------------
# SPIRE: Go binaries. GOFIPS140 is recorded in the binary's build settings, so
# `go version -m` is the authoritative check. The upstream images are distroless
# and have no shell, so this reads the image tag and reports what is known about
# it rather than execing into the container.
# ---------------------------------------------------------------------------
echo "=== SPIRE control plane ==="
SPIRE_IMAGES=$(kubectl -n "$NS_SPIRE" get pods \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
  | sort -u | grep -i spire || true)

if [[ -z "$SPIRE_IMAGES" ]]; then
  echo "  no SPIRE pods found in namespace ${NS_SPIRE}"
else
  while read -r img; do
    [[ -z "$img" ]] && continue
    echo "  image: $img"
  done <<< "$SPIRE_IMAGES"
  echo
  echo "  Upstream SPIRE images are not built with GOFIPS140. To verify a build"
  echo "  yourself, run against the binary:"
  echo "    go version -m /opt/spire/bin/spire-server | grep -i gofips140"
  echo "  A validated build records:  build  GOFIPS140=v1.0.0"
  echo "  and  go tool nm <binary> | grep -c goboringcrypto  returns 0."
fi
echo

# ---------------------------------------------------------------------------
# Envoy: the version banner names the SSL variant. "BoringSSL-FIPS" means the
# FIPS build, which is validated against FIPS 140-2 only.
# ---------------------------------------------------------------------------
echo "=== Envoy data plane ==="
ENVOY_POD=$(kubectl -n "$NS_WORKLOAD" get pods -l app=echo-server \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$ENVOY_POD" ]]; then
  echo "  no echo-server pod found in namespace ${NS_WORKLOAD}"
else
  banner=$(kubectl -n "$NS_WORKLOAD" exec "$ENVOY_POD" -c envoy -- \
    /usr/local/bin/envoy --version 2>/dev/null || echo "")
  if [[ -z "$banner" ]]; then
    echo "  could not read the version banner from $ENVOY_POD"
  else
    echo "  $banner"
    if grep -qi "BoringSSL-FIPS" <<< "$banner"; then
      echo
      echo "  FIPS build detected. Note that BoringSSL-FIPS is validated against"
      echo "  FIPS 140-2, which moved to Historical on 2026-09-21 and is no longer"
      echo "  valid for a new authorization. See docs/phase-5-fips.md."
    else
      echo
      echo "  Standard build: not a FIPS build of Envoy."
    fi
  fi
fi
echo

# ---------------------------------------------------------------------------
# AWS endpoints. Commercial endpoints are not the FIPS endpoints. In a
# private-only VPC this is visible in the interface endpoint service names.
# ---------------------------------------------------------------------------
echo "=== AWS endpoints ==="
VPC_ID=$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && terraform output -raw vpc_id 2>/dev/null || true)
if [[ -z "$VPC_ID" ]]; then
  echo "  no Terraform state; skipping"
else
  svc=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'VpcEndpoints[].ServiceName' --output text 2>/dev/null | tr '\t' '\n')
  fips_count=$(grep -c -- "-fips" <<< "$svc" || true)
  total=$(grep -c . <<< "$svc" || true)
  echo "  interface and gateway endpoints: $total"
  echo "  using FIPS service names:        $fips_count"
  if [[ "$fips_count" -eq 0 ]]; then
    echo
    echo "  All endpoints are commercial, not FIPS. A FIPS-configured deployment"
    echo "  uses the -fips service names (for example"
    echo "  com.amazonaws.${REGION}.kms-fips) and, in most federal cases, GovCloud."
  fi
fi
echo

echo "=== What this script cannot tell you ==="
echo "  Whether a module has an Active FIPS 140-3 certificate for the exact"
echo "  version deployed. That is a CMVP lookup, done by hand, recorded with the"
echo "  certificate number and the date checked. Nothing observable from inside"
echo "  the cluster substitutes for it."
