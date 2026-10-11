#!/usr/bin/env bash
#
# Capture the Private Only boundary evidence.
#
# Run the AWS and kubectl sections from your WORKSTATION, with the SSM tunnel
# up. The in-enclave section must run ON THE JUMP HOST, because the point is to
# show what a host inside the boundary can and cannot reach.
#
#   ./scripts/phase0-evidence.sh outside    # from the workstation
#   ./scripts/phase0-evidence.sh inside     # on the jump host, via SSM
#
# A note on claims. The Amazon-provided resolver answers public DNS queries
# normally, so names like example.com resolve inside the enclave. What is
# absent is a route, not name resolution. An earlier version of this capture
# was labelled "external DNS resolution fails", which is false and easy for a
# reviewer to disprove. The defensible claim is narrower: public names resolve
# and nothing outside AWS can be reached.

set -uo pipefail

MODE="${1:-}"
REGION="${AWS_REGION:-us-east-1}"
OUT="evidence/phase-0"

case "$MODE" in
  outside)
    TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
    VPC_ID="$(cd "$TF_DIR" && terraform output -raw vpc_id)"
    mkdir -p "$OUT"

    (cd "$TF_DIR" && terraform output) > "$OUT/terraform-output.txt"

    aws ec2 describe-vpc-endpoints --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" > "$OUT/vpc-endpoints.json"

    {
      echo "=== internet gateways ==="
      aws ec2 describe-internet-gateways --region "$REGION" \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID"
      echo "=== nat gateways ==="
      aws ec2 describe-nat-gateways --region "$REGION" \
        --filter "Name=vpc-id,Values=$VPC_ID"
    } > "$OUT/no-igw-no-nat.txt"

    kubectl get nodes -o wide        > "$OUT/nodes-ready.txt"
    kubectl -n kube-system get pods  > "$OUT/system-pods.txt"

    echo "Wrote the workstation-side artifacts to $OUT"
    echo
    echo "Now run the in-enclave half on the jump host:"
    echo "  ./scripts/connect.sh shell"
    echo "  # then paste the 'inside' section, or copy this script across"
    ;;

  inside)
    EKS_HOST="${EKS_HOST:-}"
    if [[ -z "$EKS_HOST" ]]; then
      echo "Set EKS_HOST to the cluster endpoint hostname first, e.g." >&2
      echo "  EKS_HOST=abc123.gr7.us-east-1.eks.amazonaws.com $0 inside" >&2
      exit 1
    fi

    echo "=== Phase 0 DNS and egress evidence ==="
    echo "date (UTC): $(date -u)"
    echo "host:       $(hostname)"
    echo

    echo "=== 1. Resolver configuration: the VPC resolver only ==="
    grep -v '^#' /etc/resolv.conf | grep -v '^$'
    echo

    echo "=== 2. AWS service names resolve to private VPC addresses ==="
    for h in sts api.ecr dkr.ecr eks eks-auth logs kms ssm tagging; do
      fqdn="${h}.${REGION}.amazonaws.com"
      addrs="$(getent hosts "$fqdn" | awk '{print $1}' | paste -sd, -)"
      printf '%-42s %s\n' "$fqdn" "${addrs:-<no address returned>}"
    done
    echo

    echo "=== 3. The EKS API endpoint resolves privately ==="
    printf '%-42s %s\n' "$EKS_HOST" \
      "$(getent hosts "$EKS_HOST" | awk '{print $1}' | paste -sd, -)"
    echo

    echo "=== 4. Nothing outside AWS is reachable ==="
    for u in https://example.com https://8.8.8.8 https://registry.k8s.io https://ghcr.io; do
      printf '%-28s ' "$u"
      if curl -sS --max-time 5 -o /dev/null "$u" 2>/dev/null; then
        echo "REACHABLE (unexpected)"
      else
        echo "unreachable (curl exit $?)"
      fi
    done
    echo

    echo "=== 5. Note on DNS ==="
    echo "Public names DO resolve here: the Amazon-provided resolver answers"
    echo "public queries. The boundary is the absence of a route, shown in"
    echo "section 4, not the absence of name resolution. Stated this way so the"
    echo "claim matches what the evidence supports."
    printf '%-28s ' "getent hosts example.com"
    getent hosts example.com >/dev/null 2>&1 \
      && echo "resolves (expected; see section 4 for reachability)" \
      || echo "no resolution"
    echo
    echo "=== end ==="
    ;;

  *)
    sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
