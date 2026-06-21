#!/bin/bash
# https://argo-cd.readthedocs.io/en/stable/getting_started/


helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --render-subchart-notes --version 9.5.21 --force-conflicts -f values.yaml
