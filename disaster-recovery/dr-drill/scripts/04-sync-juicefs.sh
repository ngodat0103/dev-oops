#!/usr/bin/env bash
# scripts/04-sync-juicefs.sh — sync the JuiceFS Application and wait for the CSI
# driver to be ready.
#
# ORDERING: must run AFTER PostgreSQL recovery (03). The JuiceFS mount pod
# connects to the metaurl (the restored CNPG juicefs_prod DB) when a volume is
# mounted, so the metadata engine has to be up first. The credentials secret
# itself is created earlier in 02 (before the StorageClass references it).
set -euo pipefail

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
  source "$HERE/config.sh"; source "$HERE/lib/log.sh"; source "$HERE/lib/preflight.sh"
  require_cmd kubectl argocd
  sync_juicefs
fi