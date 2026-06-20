#!/usr/bin/env bash
# scripts/04-validate.sh — verify the restored PostgreSQL data.
set -euo pipefail

_primary_pod() {
  kubectl get pods -n "$NAMESPACE" \
    -l cnpg.io/cluster=postgresql,role=primary \
    -o jsonpath='{.items[0].metadata.name}'
}

validate_data() {
  log_step "Validating restored data"
  local pod
  pod="$(_primary_pod)"
  [ -n "$pod" ] || die "could not find primary PostgreSQL pod"
  log_info "primary pod: $pod"

  log_info "--- connectivity check ---"
  kubectl exec -n "$NAMESPACE" "$pod" -- \
    psql -U postgres -c "SELECT 1 AS connectivity_check;"

  log_info "--- database listing ---"
  kubectl exec -n "$NAMESPACE" "$pod" -- \
    psql -U postgres -c "\l"

  log_info "--- verifying expected databases ---"
  local db count
  for db in $EXPECTED_DBS; do
    count=$(kubectl exec -n "$NAMESPACE" "$pod" -- \
      psql -U postgres -tAc \
      "SELECT count(*) FROM pg_database WHERE datname = '$db';")
    if [ "$count" -eq 0 ]; then
      die "database '$db' not found"
    fi
    log_ok "database '$db' exists"
  done

  log_info "--- counting user tables ---"
  local table_count
  for db in $EXPECTED_DBS; do
    table_count=$(kubectl exec -n "$NAMESPACE" "$pod" -- \
      psql -U postgres -d "$db" -tAc \
      "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');" \
      2>/dev/null || echo "0")
    log_info "database '$db': $table_count user table(s)"
  done

  log_ok "All validation checks passed"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$HERE/config.sh"; source "$HERE/lib/log.sh"; source "$HERE/lib/preflight.sh"
  require_cmd kubectl
  validate_data
fi