#!/bin/bash
# https://argo-cd.readthedocs.io/en/stable/getting_started/

set -euo pipefail

MODE=${1:-"--diff"}
HELM_VERSION=10.1.0

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

case "$MODE" in
  --diff)
    echo "Running diff..."
    helm diff upgrade argocd argo/argo-cd \
      -n argocd \
      --version "$HELM_VERSION" \
      -f values.yaml
    ;;
  --apply)
    echo "Applying..."
    helm upgrade --install argocd argo/argo-cd \
      -n argocd \
      --create-namespace \
      --render-subchart-notes \
      --version "$HELM_VERSION" \
      --force-conflicts \
      -f values.yaml
    ;;
  *)
    echo "Usage: $0 [--diff|--apply]"
    exit 1
    ;;
esac