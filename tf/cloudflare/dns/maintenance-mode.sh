#!/usr/bin/env bash
set -euo pipefail

# Toggle Cloudflare maintenance redirect for all app subdomains.
# Usage:
#   CF_API_TOKEN=... ./maintenance-mode.sh on
#   CF_API_TOKEN=... ./maintenance-mode.sh off
#   CF_API_TOKEN=... ./maintenance-mode.sh status

ZONE_ID="${ZONE_ID:-ab6606e8b3aad0b66008eb26f2dd3660}"
TARGET_URL="${TARGET_URL:-https://maintainance.datrollout.workers.dev/}"
RULE_DESCRIPTION="${RULE_DESCRIPTION:-Maintenance mode redirect}"
ACTION="${1:-status}"

DOMAINS=(
  "nextcloud.datrollout.dev"
  "gitlab.datrollout.dev"
  "bitwarden.datrollout.dev"
  "sonarqube.datrollout.dev"
  "loki.datrollout.dev"
  "prometheus.datrollout.dev"
  "grafana.datrollout.dev"
)

require_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Missing dependency: $bin" >&2
    exit 1
  fi
}

require_auth() {
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    echo "Set CF_API_TOKEN environment variable first." >&2
    exit 1
  fi
}

cf_api() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$body"
  else
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

build_expression() {
  local joined=""
  for d in "${DOMAINS[@]}"; do
    if [[ -z "$joined" ]]; then
      joined="\"$d\""
    else
      joined="$joined \"$d\""
    fi
  done
  printf 'http.host in {%s}' "$joined"
}

RULE_EXPRESSION="$(build_expression)"
BASE_URL="https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/rulesets/phases/http_request_dynamic_redirect/entrypoint"

get_entrypoint() {
  cf_api "GET" "$BASE_URL"
}

get_rule_id_by_description() {
  local payload="$1"
  jq -r --arg desc "$RULE_DESCRIPTION" '.result.rules[]? | select(.description == $desc) | .id' <<<"$payload" | head -n 1
}

create_ruleset_with_rule() {
  local enabled="$1"
  local body
  body="$(jq -n \
    --arg phase "http_request_dynamic_redirect" \
    --arg name "Default Redirect Ruleset" \
    --arg desc "$RULE_DESCRIPTION" \
    --arg expr "$RULE_EXPRESSION" \
    --arg target "$TARGET_URL" \
    --argjson enabled "$enabled" \
    '{
      name: $name,
      kind: "zone",
      phase: $phase,
      rules: [
        {
          action: "redirect",
          expression: $expr,
          description: $desc,
          enabled: $enabled,
          action_parameters: {
            from_value: {
              status_code: 302,
              target_url: { value: $target },
              preserve_query_string: true
            }
          }
        }
      ]
    }')"

  local response
  response="$(cf_api "POST" "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/rulesets" "$body")"
  jq -e '.success == true' <<<"$response" >/dev/null || {
    echo "Failed to create redirect ruleset:"
    echo "$response" | jq .
    exit 1
  }
}

upsert_rule() {
  local enabled="$1"
  local entrypoint="$2"
  local rule_id
  rule_id="$(get_rule_id_by_description "$entrypoint")"

  if [[ -z "$rule_id" ]]; then
    local body
    body="$(jq -n \
      --arg action "redirect" \
      --arg expr "$RULE_EXPRESSION" \
      --arg desc "$RULE_DESCRIPTION" \
      --arg target "$TARGET_URL" \
      --argjson enabled "$enabled" \
      '{
        action: $action,
        expression: $expr,
        description: $desc,
        enabled: $enabled,
        action_parameters: {
          from_value: {
            status_code: 302,
            target_url: { value: $target },
            preserve_query_string: true
          }
        }
      }')"

    local response
    response="$(cf_api "POST" "${BASE_URL}/rules" "$body")"
    jq -e '.success == true' <<<"$response" >/dev/null || {
      echo "Failed to create redirect rule:"
      echo "$response" | jq .
      exit 1
    }
    return
  fi

  local current_rule
  current_rule="$(jq --arg id "$rule_id" -c '.result.rules[] | select(.id == $id)' <<<"$entrypoint")"
  local updated_rule
  updated_rule="$(jq -n \
    --argjson rule "$current_rule" \
    --arg expr "$RULE_EXPRESSION" \
    --arg target "$TARGET_URL" \
    --argjson enabled "$enabled" \
    '$rule
      | .enabled = $enabled
      | .expression = $expr
      | .action_parameters.from_value.status_code = 302
      | .action_parameters.from_value.target_url.value = $target
      | .action_parameters.from_value.preserve_query_string = true')"

  local response
  response="$(cf_api "PUT" "${BASE_URL}/rules/${rule_id}" "$updated_rule")"
  jq -e '.success == true' <<<"$response" >/dev/null || {
    echo "Failed to update redirect rule:"
    echo "$response" | jq .
    exit 1
  }
}

set_mode() {
  local enabled="$1"
  local entrypoint
  entrypoint="$(get_entrypoint)"

  if jq -e '.success == true' <<<"$entrypoint" >/dev/null; then
    upsert_rule "$enabled" "$entrypoint"
    return
  fi

  # Create ruleset when none exists yet for this phase.
  create_ruleset_with_rule "$enabled"
}

show_status() {
  local entrypoint
  entrypoint="$(get_entrypoint)"

  if ! jq -e '.success == true' <<<"$entrypoint" >/dev/null; then
    echo "No dynamic redirect ruleset found (maintenance OFF)."
    return
  fi

  local status
  status="$(jq -r --arg desc "$RULE_DESCRIPTION" '.result.rules[]? | select(.description == $desc) | .enabled' <<<"$entrypoint" | head -n 1)"
  if [[ -z "$status" || "$status" == "null" ]]; then
    echo "Maintenance rule not found (maintenance OFF)."
  elif [[ "$status" == "true" ]]; then
    echo "Maintenance mode is ON."
  else
    echo "Maintenance mode is OFF."
  fi
}

main() {
  require_bin "curl"
  require_bin "jq"
  require_auth

  case "$ACTION" in
    on)
      set_mode "true"
      echo "Maintenance mode enabled for ${#DOMAINS[@]} domains -> $TARGET_URL"
      ;;
    off)
      set_mode "false"
      echo "Maintenance mode disabled."
      ;;
    status)
      show_status
      ;;
    *)
      echo "Usage: $0 {on|off|status}" >&2
      exit 1
      ;;
  esac
}

main "$@"
