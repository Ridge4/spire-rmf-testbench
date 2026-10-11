#!/usr/bin/env bash
#
# Run before `terraform destroy`.
#
# Two things outlive Terraform and cause problems:
#
#   1. VPC CNI network interfaces. The CNI allocates secondary ENIs for pod
#      addresses and does not always release them when nodes terminate. A
#      leftover ENI holds an address in the subnet, so the subnet delete blocks
#      and Terraform retries for 15-20 minutes before failing.
#
#   2. KMS keys created by the SPIRE server. These are not Terraform-managed, so
#      destroy leaves them behind at roughly $1/month each. Worse, their key
#      policy names the SPIRE server IAM role, and destroy deletes that role: a
#      key whose only administrative principal no longer exists cannot be
#      managed by anyone afterwards, including the account root. See
#      docs/phase-1-kms.md. Scheduling deletion BEFORE destroy is the only
#      moment this is still possible.
#
# Usage:
#   ./scripts/pre-destroy-cleanup.sh            # report only
#   ./scripts/pre-destroy-cleanup.sh --apply    # actually clean up

set -euo pipefail

APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true

REGION="${AWS_REGION:-us-east-1}"
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"

VPC_ID="$(cd "$TF_DIR" && terraform output -raw vpc_id 2>/dev/null || true)"
if [[ -z "$VPC_ID" ]]; then
  echo "Could not read vpc_id from Terraform state. Nothing to do."
  exit 0
fi

echo "VPC    : $VPC_ID"
echo "Region : $REGION"
echo "Mode   : $([[ $APPLY == true ]] && echo APPLY || echo 'report only (pass --apply to act)')"
echo

# ---------------------------------------------------------------------------
# 1. Detached ENIs in the VPC
# ---------------------------------------------------------------------------
echo "=== Detached network interfaces ==="
mapfile -t ENIS < <(aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text --region "$REGION" \
  | tr '\t' '\n' | sed '/^$/d')

if [[ ${#ENIS[@]} -eq 0 ]]; then
  echo "  none"
else
  for eni in "${ENIS[@]}"; do
    desc=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" \
      --query 'NetworkInterfaces[0].Description' --output text --region "$REGION")
    echo "  $eni  ($desc)"
    if [[ $APPLY == true ]]; then
      aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" \
        && echo "    deleted" \
        || echo "    could not delete; it may have re-attached, re-run after a moment"
    fi
  done
fi
echo

# ---------------------------------------------------------------------------
# 2. KMS keys created by the SPIRE server
# ---------------------------------------------------------------------------
echo "=== SPIRE-created KMS keys ==="
mapfile -t ALIASES < <(aws kms list-aliases --region "$REGION" \
  --query "Aliases[?contains(AliasName,'SPIRE_SERVER')].AliasName" --output text \
  | tr '\t' '\n' | sed '/^$/d')

if [[ ${#ALIASES[@]} -eq 0 ]]; then
  echo "  none"
else
  for alias in "${ALIASES[@]}"; do
    key_id=$(aws kms describe-key --key-id "$alias" --region "$REGION" \
      --query 'KeyMetadata.KeyId' --output text 2>/dev/null || echo "")
    state=$(aws kms describe-key --key-id "$alias" --region "$REGION" \
      --query 'KeyMetadata.KeyState' --output text 2>/dev/null || echo "unknown")
    echo "  $alias"
    echo "    key=$key_id state=$state"

    [[ "$state" == "PendingDeletion" ]] && continue

    if [[ $APPLY == true && -n "$key_id" ]]; then
      # Delete the alias first so a later rebuild does not collide with it, then
      # schedule the key. Both calls must happen while the SPIRE server role
      # still exists, because the key policy grants only that role and the
      # account root (read-only under the plugin default).
      aws kms delete-alias --alias-name "$alias" --region "$REGION" 2>/dev/null \
        && echo "    alias deleted" \
        || echo "    alias delete DENIED (key policy no longer grants this caller)"
      aws kms schedule-key-deletion --key-id "$key_id" --pending-window-in-days 7 \
        --region "$REGION" >/dev/null 2>&1 \
        && echo "    key scheduled for deletion in 7 days" \
        || echo "    schedule-key-deletion DENIED; see docs/phase-1-kms.md"
    fi
  done
fi
echo

if [[ $APPLY == true ]]; then
  echo "Cleanup done. Now run:  cd terraform && terraform destroy"
else
  echo "Report only. Re-run with --apply to clean up, then run terraform destroy."
fi
