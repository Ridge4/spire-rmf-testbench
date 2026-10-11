#!/usr/bin/env bash
#
# Connect to the private-only EKS cluster.
#
# The API endpoint has no public access, so kubectl and helm reach it through an
# SSM port forward via the jump host. Every value below is read from Terraform
# state, so nothing has to be remembered or pasted after a rebuild, even though
# the cluster endpoint hostname changes each time.
#
# Usage, from the repository root:
#
#   ./scripts/connect.sh tunnel      # terminal 1: start the tunnel, leave running
#   ./scripts/connect.sh kubeconfig  # terminal 2: point kubectl at the tunnel
#   ./scripts/connect.sh check       # is the tunnel up and the cluster reachable?
#   ./scripts/connect.sh shell       # a shell on the jump host
#   ./scripts/connect.sh secret      # recreate the SPIRE datastore secret
#   ./scripts/connect.sh info        # print the cluster facts
#
# Typical session after `terraform apply`:
#   terminal 1:  ./scripts/connect.sh tunnel
#   terminal 2:  ./scripts/connect.sh kubeconfig && ./scripts/connect.sh secret

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
LOCAL_PORT="${LOCAL_PORT:-8443}"
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"

tf() { (cd "$TF_DIR" && terraform output -raw "$1" 2>/dev/null); }

require_state() {
  if [[ -z "$(tf cluster_name)" ]]; then
    echo "No Terraform outputs found. Has the stack been applied?" >&2
    exit 1
  fi
}

cmd_info() {
  require_state
  echo "cluster   : $(tf cluster_name)"
  echo "endpoint  : $(tf cluster_endpoint)"
  echo "jump host : $(tf jump_host_id)"
  echo "vpc       : $(tf vpc_id)"
  echo "datastore : $(tf spire_datastore_endpoint)"
  echo "log group : $(tf identity_log_group)"
  echo "local port: ${LOCAL_PORT}"
}

cmd_tunnel() {
  require_state
  local host
  host="$(tf cluster_endpoint | sed 's#https://##')"
  echo "Forwarding localhost:${LOCAL_PORT} -> ${host}:443"
  echo "Leave this running. Open a second terminal and run: ./scripts/connect.sh kubeconfig"
  echo
  exec aws ssm start-session \
    --target "$(tf jump_host_id)" \
    --region "$REGION" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=${host},portNumber=443,localPortNumber=${LOCAL_PORT}"
}

cmd_kubeconfig() {
  require_state
  local host cluster_arn account
  host="$(tf cluster_endpoint | sed 's#https://##')"
  account="$(aws sts get-caller-identity --query Account --output text)"
  cluster_arn="arn:aws:eks:${REGION}:${account}:cluster/$(tf cluster_name)"

  aws eks update-kubeconfig --name "$(tf cluster_name)" --region "$REGION" >/dev/null

  # Point kubectl at the tunnel, and keep certificate validation working by
  # telling it the name the server's certificate actually carries.
  kubectl config set-cluster "$cluster_arn" --server="https://localhost:${LOCAL_PORT}" >/dev/null
  kubectl config set-cluster "$cluster_arn" --tls-server-name="$host" >/dev/null

  echo "kubeconfig points at localhost:${LOCAL_PORT} (tls-server-name ${host})"
  cmd_check
}

cmd_check() {
  if kubectl get --raw /version >/dev/null 2>&1; then
    echo "cluster reachable"
    kubectl get nodes 2>/dev/null || true
  else
    echo "cluster NOT reachable."
    echo "  - is the tunnel running?   ./scripts/connect.sh tunnel"
    echo "  - has it timed out?        restart it; SSM sessions expire when idle"
    echo "  - port already in use?     pkill -f session-manager-plugin"
    return 1
  fi
}

cmd_shell() {
  require_state
  exec aws ssm start-session --target "$(tf jump_host_id)" --region "$REGION"
}

# The RDS password is regenerated on every rebuild, so the Kubernetes secret
# the SPIRE chart reads has to be recreated too. This is the step most easily
# forgotten after a destroy/apply cycle.
cmd_secret() {
  require_state
  local arn pass
  arn="$(tf spire_datastore_secret_arn)"
  pass="$(aws secretsmanager get-secret-value --secret-id "$arn" \
    --query SecretString --output text --region "$REGION" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')"

  kubectl create namespace spire-server --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n spire-server delete secret spire-datastore --ignore-not-found >/dev/null
  kubectl -n spire-server create secret generic spire-datastore \
    --from-literal=password="$pass" >/dev/null

  echo "namespace spire-server and secret spire-datastore are in place"
  echo
  echo "RDS endpoint for helm/spire-values.yaml (dataStore.sql.host):"
  echo "  $(tf spire_datastore_endpoint)"
}

case "${1:-}" in
  tunnel)     cmd_tunnel ;;
  kubeconfig) cmd_kubeconfig ;;
  check)      cmd_check ;;
  shell)      cmd_shell ;;
  secret)     cmd_secret ;;
  info)       cmd_info ;;
  *)
    sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
