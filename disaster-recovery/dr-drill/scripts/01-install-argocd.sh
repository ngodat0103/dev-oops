#!/usr/bin/env bash
# scripts/01-install-argocd.sh — install ArgoCD via Helm and wait for it to be ready.
set -euo pipefail

install_argocd() {
  log_step "Installing ArgoCD (chart $ARGOCD_CHART_VERSION)"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null

  helm upgrade --install argocd argo/argo-cd \
    --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd \
    --create-namespace \
    --debug \
    --set 'configs.params.server\.insecure=true'
  log_ok "ArgoCD installed"
}

wait_for_argocd() {
  log_step "Waiting for ArgoCD core deployments"
  local d
  for d in argocd-server argocd-repo-server argocd-applicationset-controller; do
    log_info "rollout: $d"
    kubectl rollout status "deployment/$d" -n argocd --timeout="$ARGOCD_ROLLOUT_TIMEOUT"
  done
  log_ok "ArgoCD is ready"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$HERE/config.sh"; source "$HERE/lib/log.sh"; source "$HERE/lib/preflight.sh"
  require_cmd helm kubectl
  install_argocd
  wait_for_argocd
fi