#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-argus}"

read -rsp "DEEPSEEK_API_KEY: " DEEPSEEK_API_KEY; echo
read -rsp "POSTGRES_PASSWORD: " POSTGRES_PASSWORD; echo
read -rsp "TELEGRAM_TOKEN (leave blank to skip): " TELEGRAM_TOKEN; echo
read -rsp "GITHUB_APP_SECRET (webhook secret): " GITHUB_APP_SECRET; echo
read -rp  "Path to GitHub App private key .pem: " GITHUB_APP_PRIVATE_KEY_PATH

POSTGRES_USER="${POSTGRES_USER:-argus}"

# Env secret, consumed via envFrom. GITHUB_APP_SECRET binds to github.app.secret.
kubectl create secret generic argus-secrets \
  --namespace "$NAMESPACE" \
  --from-literal=DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=TELEGRAM_TOKEN="$TELEGRAM_TOKEN" \
  --from-literal=GITHUB_APP_SECRET="$GITHUB_APP_SECRET" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -

# File secret holding the GitHub App private key. Mounted as a file by the
# Deployment at github.app.private-key-path (default /etc/argus/github/private-key.pem).
# The key name here MUST match .Values.github.app.privateKeySecret.key.
kubectl create secret generic argus-github-app \
  --namespace "$NAMESPACE" \
  --from-file=private-key.pem="$GITHUB_APP_PRIVATE_KEY_PATH" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secrets 'argus-secrets' and 'argus-github-app' applied in namespace '$NAMESPACE'."
