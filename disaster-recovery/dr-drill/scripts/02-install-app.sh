#!/usr/bin/env bash
# scripts/02-install-apps.sh — JuiceFS secret, app-of-app, cert-manager, secrets.
set -euo pipefail

# create_juicefs_secret — MUST run before install_app_of_app, because the
# JuiceFS StorageClass references existingSecret: <JUICEFS_SECRET_NAME>.
# Field names match the wener/juicefs-csi-driver existingSecret schema.
create_juicefs_secret() {
  [ "$JUICEFS_ENABLED" = "true" ] || { log_info "JuiceFS disabled — skipping secret"; return 0; }

  log_step "Creating JuiceFS namespace and credentials secret"
  require_env R2_ACCESS_KEY R2_SECRET_KEY

  if [ -z "${JUICEFS_META_PASSWORD:-}" ] && [[ "$JUICEFS_METAURL" == *"//${JUICEFS_META_USER}:@"* ]]; then
    log_warn "JUICEFS_META_PASSWORD is empty — metaurl will have no password"
  fi

  kubectl create namespace "$JUICEFS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic "$JUICEFS_SECRET_NAME" \
    -n "$JUICEFS_NAMESPACE" \
    --from-literal=name="$JUICEFS_VOLUME_NAME" \
    --from-literal=metaurl="$JUICEFS_METAURL" \
    --from-literal=storage="s3" \
    --from-literal=bucket="$JUICEFS_BUCKET" \
    --from-literal=accessKey="$R2_ACCESS_KEY" \
    --from-literal=secretKey="$R2_SECRET_KEY" \
    --from-literal=envs="$JUICEFS_ENVS" \
    --dry-run=client -o yaml | kubectl apply -f -

  log_ok "JuiceFS secret '$JUICEFS_SECRET_NAME' applied in '$JUICEFS_NAMESPACE'"
}

install_app_of_app() {
  log_step "Installing app-of-app chart (juicefs.enabled=$JUICEFS_ENABLED, readOnly=$JUICEFS_READONLY)"
  helm upgrade --install app-of-app "$REPO_ROOT/$APP_OF_APP_CHART" \
    --namespace argocd \
    --set metallb.enabled=false \
    --set argus.enabled=false \
    --set chaosMesh.enabled=false \
    --set nextcloud.enabled=false \
    --set nfsCsiDriver.enabled=false \
    --set jellyfin.enabled=false \
    --set qbittorrent.enabled=false \
    --set traefik.enabled=true \
    --set openebs.enabled=false \
    --set postgresql.enabled=true \
    --set certManager.enabled=true \
    --set kubePrometheusStack.enabled=false \
    --set customManifest.enabled=false \
    --set loki.enabled=false \
    --set alloy.enabled=false \
    --set pgadmin4.enabled=false \
    --set sonarqube.enabled=false \
    --set harbor.enabled=false \
    --set velero.enabled=false \
    --set mongoOperator.enabled=false \
    --set kafkaOperator.enabled=false \
    --set juicefs.enabled="$JUICEFS_ENABLED" \
    --set juicefs.readOnly="$JUICEFS_READONLY" \
    --set juicefs.monitoring="$JUICEFS_MONITORING" \
    --set vaultwarden.enabled=true
  log_ok "app-of-app installed"
}

sync_cert_manager() {
  log_step "Syncing cert-manager"
  argocd app sync cert-manager --core \
    --retry-limit 5 \
    --retry-backoff-duration 10s \
    --retry-backoff-max-duration 3m \
    --retry-backoff-factor 2
  log_ok "cert-manager synced"
}

create_secrets() {
  log_step "Creating namespace and secrets in $NAMESPACE"
  require_env R2_ACCESS_KEY R2_SECRET_KEY

  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic cloudflare-r2 \
    -n "$NAMESPACE" \
    --from-literal=ACCESS_KEY="$R2_ACCESS_KEY" \
    --from-literal=SECRET_KEY="$R2_SECRET_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic postgres-admin \
    -n "$NAMESPACE" \
    --from-literal=username=postgres \
    --from-literal=password=backup-test-dummy \
    --dry-run=client -o yaml | kubectl apply -f -

  log_ok "Secrets applied"
}

# sync_juicefs — call AFTER PostgreSQL is healthy (the mount pod needs the
# metaurl DB reachable). Syncs the Application and waits for CSI readiness.
sync_juicefs() {
  [ "$JUICEFS_ENABLED" = "true" ] || { log_info "JuiceFS disabled — skipping sync"; return 0; }

  log_step "Syncing juicefs Application"
  argocd app sync juicefs --core \
    --retry-limit 5 \
    --retry-backoff-duration 10s \
    --retry-backoff-max-duration 3m \
    --retry-backoff-factor 2

  log_step "Waiting for JuiceFS CSI components"
  # Controller is a StatefulSet, node service a DaemonSet.
  kubectl rollout status statefulset \
    -n "$JUICEFS_NAMESPACE" -l "$JUICEFS_CSI_SELECTOR" --timeout=180s 2>/dev/null \
    || log_warn "could not confirm CSI controller rollout (continuing)"
  kubectl rollout status daemonset \
    -n "$JUICEFS_NAMESPACE" -l "$JUICEFS_CSI_SELECTOR" --timeout=180s 2>/dev/null \
    || log_warn "could not confirm CSI node rollout (continuing)"
  log_ok "JuiceFS synced"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  REPO_ROOT="${REPO_ROOT:-$HERE}"
  source "$HERE/config.sh"; source "$HERE/lib/log.sh"; source "$HERE/lib/preflight.sh"
  require_cmd helm kubectl argocd
  create_juicefs_secret
  install_app_of_app
  sync_cert_manager
  create_secrets
fi