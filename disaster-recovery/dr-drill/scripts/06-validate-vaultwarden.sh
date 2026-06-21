#!/usr/bin/env bash
# scripts/05-validate-vaultwarden.sh — deploy + validate Vaultwarden on the
# read-only JuiceFS mount. Replaces the un-automatable "log in via UI" step.
set -euo pipefail

sync_vaultwarden() {
  log_step "Syncing vaultwarden Application"
  argocd app sync vaultwarden --core \
    --retry-limit 5 \
    --retry-backoff-duration 5s \
    --retry-backoff-max-duration 1m \
    --retry-backoff-factor 2 || log_warn "vaultwarden sync returned non-zero (continuing)"

  log_step "Waiting for Vaultwarden rollout"
  kubectl rollout status "deployment/$VAULTWARDEN_DEPLOYMENT" \
    -n "$VAULTWARDEN_NAMESPACE" \
    --timeout="$VAULTWARDEN_ROLLOUT_TIMEOUT"
  log_ok "Vaultwarden is running"
}

_vw_pod() {
  kubectl get pods -n "$VAULTWARDEN_NAMESPACE" \
    -l "app=$VAULTWARDEN_DEPLOYMENT" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# 1) Process health via HTTP — proves the server started and serves requests.
check_health_endpoint() {
  log_step "Checking Vaultwarden HTTP health"
  kubectl port-forward "svc/$VAULTWARDEN_SERVICE" \
    "${VAULTWARDEN_LOCAL_PORT}:80" -n "$VAULTWARDEN_NAMESPACE" >/dev/null 2>&1 &
  local pf_pid=$!
  # Ensure the port-forward is torn down no matter how we exit this function.
  trap 'kill "$pf_pid" 2>/dev/null || true' RETURN
  sleep 5

  curl --fail --silent --show-error --retry 5 --retry-delay 3 \
    "http://localhost:${VAULTWARDEN_LOCAL_PORT}/alive" >/dev/null
  curl --fail --silent --show-error --retry 5 --retry-delay 3 \
    "http://localhost:${VAULTWARDEN_LOCAL_PORT}/api/config" >/dev/null
  log_ok "Vaultwarden is alive and serving /api/config"
}

# 2) Read-only enforcement — a write into the JuiceFS-backed data dir MUST fail.
#    This is the split-brain guarantee: DR cannot mutate the prod R2 prefix.
check_mount_is_readonly() {
  log_step "Verifying JuiceFS mount is read-only"
  local pod
  pod="$(_vw_pod)"
  [ -n "$pod" ] || die "could not find Vaultwarden pod"

  local out
  out=$(kubectl exec -n "$VAULTWARDEN_NAMESPACE" "$pod" -- \
    sh -c "touch ${VAULTWARDEN_DATA_PATH}/.dr-write-test 2>&1" || true)

  if printf '%s' "$out" | grep -qiE 'read-only file system|permission denied'; then
    log_ok "write correctly rejected: ${out}"
  else
    # Clean up if the write unexpectedly succeeded, then fail hard.
    kubectl exec -n "$VAULTWARDEN_NAMESPACE" "$pod" -- \
      rm -f "${VAULTWARDEN_DATA_PATH}/.dr-write-test" 2>/dev/null || true
    die "mount is NOT read-only — DR could corrupt prod R2 (output: '${out:-<empty, write succeeded>}')"
  fi
}

# 3) Data is actually readable — proves restored metadata maps to real objects.
check_data_readable() {
  log_step "Verifying restored data is readable via JuiceFS"
  local pod count
  pod="$(_vw_pod)"
  count=$(kubectl exec -n "$VAULTWARDEN_NAMESPACE" "$pod" -- \
    sh -c "ls -A ${VAULTWARDEN_DATA_PATH} 2>/dev/null | wc -l" || echo 0)

  if [ "${count:-0}" -gt 0 ]; then
    log_ok "data dir has $count entries — files restored"
  else
    die "data dir is empty — JuiceFS restore may have failed"
  fi
}

# 4) Log scan — catch DB connection failures / startup panics.
check_logs_clean() {
  log_step "Scanning Vaultwarden logs"
  local logs
  logs=$(kubectl logs "deployment/$VAULTWARDEN_DEPLOYMENT" \
    -n "$VAULTWARDEN_NAMESPACE" --tail=100 2>/dev/null || echo "")
  printf '%s\n' "$logs"

  if printf '%s' "$logs" | grep -qiE 'panic|fatal|database.*(fail|error)|unable to connect'; then
    die "critical errors found in Vaultwarden logs"
  fi
  log_ok "no critical errors in logs"
}

# 5) Optional deep check — assert restored user count via the admin API.
check_user_data() {
  [ -n "${VW_ADMIN_TOKEN:-}" ] || { log_info "VW_ADMIN_TOKEN unset — skipping user-count check"; return 0; }

  log_step "Validating restored user data via admin API"
  kubectl port-forward "svc/$VAULTWARDEN_SERVICE" \
    "${VAULTWARDEN_LOCAL_PORT}:80" -n "$VAULTWARDEN_NAMESPACE" >/dev/null 2>&1 &
  local pf_pid=$!
  trap 'kill "$pf_pid" 2>/dev/null || true' RETURN
  sleep 5

  local users
  users=$(curl --silent \
    -H "Authorization: Bearer ${VW_ADMIN_TOKEN}" \
    "http://localhost:${VAULTWARDEN_LOCAL_PORT}/admin/users/overview" \
    | jq 'length' 2>/dev/null || echo 0)

  if [ "${users:-0}" -gt 0 ]; then
    log_ok "$users user(s) found — user data restored"
  else
    die "no users found — DB restore may be incomplete"
  fi
}

validate_vaultwarden() {
  check_health_endpoint
  check_mount_is_readonly
  check_data_readable
  check_logs_clean
  check_user_data
  log_ok "Vaultwarden DR validation passed"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$HERE/config.sh"; source "$HERE/lib/log.sh"; source "$HERE/lib/preflight.sh"
  require_cmd kubectl argocd curl jq
  sync_vaultwarden
  validate_vaultwarden
fi