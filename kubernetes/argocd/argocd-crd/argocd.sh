#!/bin/bash
# https://argo-cd.readthedocs.io/en/stable/getting_started/

set -euo pipefail

MODE=${1:-"--diff"}

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

case "$MODE" in
  --diff)
    echo "Running diff..."
    helm diff upgrade argocd argo/argo-cd \
      -n argocd \
      --version 9.5.21 \
      -f values.yaml
    ;;
  --apply)
    echo "Applying..."
    helm upgrade --install argocd argo/argo-cd \
      -n argocd \
      --create-namespace \
      --render-subchart-notes \
      --version 9.5.21 \
      --force-conflicts \
      -f values.yaml
    ;;
  *)
    echo "Usage: $0 [--diff|--apply]"
    exit 1
    ;;
esac