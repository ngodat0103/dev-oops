#!/usr/bin/env bash
# scripts/00-create-cluster.sh — provision the DOKS cluster and load kubeconfig.
set -euo pipefail

create_cluster() {
  log_step "Creating DOKS cluster: $CLUSTER_NAME ($REGION, ${NODE_COUNT}x $NODE_SIZE)"
  doctl kubernetes cluster create "$CLUSTER_NAME" \
    --region "$REGION" \
    --size "$NODE_SIZE" \
    --count "$NODE_COUNT" \
    --wait
  log_ok "Cluster created"

  log_step "Saving kubeconfig"
  doctl kubernetes cluster kubeconfig save "$CLUSTER_NAME"
  kubectl config set-context --current --namespace=argocd
  log_ok "kubeconfig loaded, default namespace set to argocd"
}

# Allow running standalone: ./scripts/00-create-cluster.sh
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck source=../config.sh
  source "$HERE/config.sh"
  # shellcheck source=../lib/log.sh
  source "$HERE/lib/log.sh"
  # shellcheck source=../lib/preflight.sh
  source "$HERE/lib/preflight.sh"
  require_cmd doctl kubectl
  ensure_doctl_auth
  create_cluster
fi