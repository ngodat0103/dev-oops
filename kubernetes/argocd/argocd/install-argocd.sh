#!/bin/bash
# https://argo-cd.readthedocs.io/en/stable/getting_started/


helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd . -n argocd --create-namespace --render-subchart-notes -f values.yaml
