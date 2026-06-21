#!/usr/bin/env bash
# run.sh — orchestrate the full PostgreSQL DR drill.
#
# Usage:
#   ./run.sh                  # full drill: create -> recover -> validate -> destroy
#   ./run.sh --skip-destroy   # leave the cluster up for inspection
#   ./run.sh destroy          # destroy only (e.g. to clean up a leaked run)
#
# Required env (typically GHA secrets passed through):
#   DIGITALOCEAN_TOKEN, R2_ACCESS_KEY, R2_SECRET_KEY
#
# Optional overrides: see config.sh (REGION, NODE_SIZE, RUN_ID, etc.)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

# --- load config + libs ----------------------------------------------------
source "$REPO_ROOT/config.sh"
source "$REPO_ROOT/lib/log.sh"
source "$REPO_ROOT/lib/preflight.sh"

# --- load step functions ---------------------------------------------------
source "$REPO_ROOT/scripts/00-create-cluster.sh"
source "$REPO_ROOT/scripts/01-install-argocd.sh"
source "$REPO_ROOT/scripts/02-install-apps.sh"
source "$REPO_ROOT/scripts/03-recover-postgres.sh"
source "$REPO_ROOT/scripts/04-sync-juicefs.sh"
source "$REPO_ROOT/scripts/05-validate.sh"
source "$REPO_ROOT/scripts/06-validate-vaultwarden.sh"
source "$REPO_ROOT/scripts/99-destroy.sh"

# --- argument parsing ------------------------------------------------------
DESTROY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skip-destroy) SKIP_DESTROY=1 ;;
    destroy)        DESTROY_ONLY=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

# --- cleanup trap: the `if: always()` equivalent ---------------------------
# Runs destroy on ANY exit (success, failure, or interrupt) unless skipped.
cleanup() {
  local rc=$?
  if [ "$SKIP_DESTROY" = "1" ]; then
    log_warn "SKIP_DESTROY set — leaving cluster '$CLUSTER_NAME' running"
    log_warn "clean up later with: ./run.sh destroy   (CLUSTER_NAME=$CLUSTER_NAME)"
  else
    log_step "Cleanup (exit code: $rc)"
    destroy_cluster || log_warn "destroy encountered errors (best-effort)"
  fi
  exit "$rc"
}

main() {
  require_cmd doctl kubectl helm argocd jq curl
  require_env DIGITALOCEAN_TOKEN
  ensure_doctl_auth

  if [ "$DESTROY_ONLY" = "1" ]; then
    destroy_cluster
    return 0
  fi

  # Register cleanup only for the full drill path.
  trap cleanup EXIT INT TERM

  create_cluster
  install_argocd
  wait_for_argocd

  # JuiceFS secret must exist before the StorageClass (existingSecret) is created.
  create_juicefs_secret
  install_app_of_app
  sync_cert_manager
  create_secrets

  # PostgreSQL first — JuiceFS metadata + Vaultwarden DB both live here.
  recover_postgres
  validate_data

  # Data layer: JuiceFS sync (needs the metaurl DB up) → Vaultwarden on top.
  sync_juicefs
  sync_vaultwarden
  validate_vaultwarden

  log_ok "DR drill succeeded for cluster $CLUSTER_NAME"
}

main