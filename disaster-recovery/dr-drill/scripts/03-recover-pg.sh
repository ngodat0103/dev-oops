#!/usr/bin/env bash
# scripts/03-recover-postgres.sh — point PG app at the recovery tag, sync, wait healthy.
set -euo pipefail

override_revision() {
  log_step "Overriding prod-postgresql revision -> $RECOVERY_TAG"
  argocd app set prod-postgresql \
    --core \
    --source-position 2 \
    --revision "$RECOVERY_TAG"
  log_ok "Revision set"
}

sync_postgres_app() {
  log_step "Syncing prod-postgresql (app)"
  # Non-fatal: the Cluster resource sync below is the authoritative gate.
  argocd app sync prod-postgresql --core \
    --retry-limit 3 \
    --retry-backoff-duration 5s \
    --retry-backoff-max-duration 1m \
    --retry-backoff-factor 2 || log_warn "app sync returned non-zero (continuing)"

  log_step "Syncing prod-postgresql (Cluster resource)"
  argocd app sync prod-postgresql --core \
    --resource postgresql.cnpg.io:Cluster:postgresql \
    --retry-limit 5 \
    --retry-backoff-duration 5s \
    --retry-backoff-max-duration 1m \
    --retry-backoff-factor 2 || log_warn "cluster-resource sync returned non-zero (continuing)"
}

wait_for_healthy() {
  log_step "Waiting for CNPG cluster to reach healthy state"
  local i phase
  for i in $(seq 1 "$CLUSTER_HEALTHY_ATTEMPTS"); do
    phase=$(kubectl get cluster -n "$NAMESPACE" postgresql \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    log_info "attempt $i/$CLUSTER_HEALTHY_ATTEMPTS: phase=$phase"
    if [ "$phase" = "Cluster in healthy state" ]; then
      log_ok "Cluster is healthy"
      return 0
    fi
    sleep "$CLUSTER_HEALTHY_INTERVAL"
  done

  log_error "Cluster did not reach healthy state in time — dumping diagnostics"
  kubectl get cluster -n "$NAMESPACE" postgresql -o yaml || true
  kubectl get pods -n "$NAMESPACE" -l cnpg.io/cluster=postgresql || true
  return 1
}

recover_postgres() {
  override_revision
  sync_postgres_app
  wait_for_healthy
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$HERE/config.sh"; source "$HERE/lib/log.sh"; source "$HERE/lib/preflight.sh"
  require_cmd kubectl argocd
  recover_postgres
fi