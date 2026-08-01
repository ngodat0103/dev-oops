#!/usr/bin/env bash
# lib/preflight.sh — verify required tooling and environment before doing work.

# require_cmd <name>... — fail if any command is missing from PATH.
require_cmd() {
  local missing=0 c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      log_error "required command not found: $c"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "install missing CLIs (these are provided by the CI dependency step)"
}

# require_env <name>... — fail if any env var is empty.
require_env() {
  local missing=0 v
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      log_error "required environment variable not set: $v"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "export the missing variables (pass GHA secrets through env)"
}

# ensure_doctl_auth — re-init doctl auth if a token is present and not yet valid.
ensure_doctl_auth() {
  if doctl account get >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "${DIGITALOCEAN_TOKEN:-}" ]; then
    log_info "initialising doctl auth from DIGITALOCEAN_TOKEN"
    doctl auth init --access-token "$DIGITALOCEAN_TOKEN" >/dev/null
  else
    die "doctl is not authenticated and DIGITALOCEAN_TOKEN is unset"
  fi
}