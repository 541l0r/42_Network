#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$ROOT_DIR/.oauth_config}"
STATE_FILE="${STATE_FILE:-$ROOT_DIR/.oauth_state}"
API_ROOT="https://api.intra.42.fr"

require_file() {
  local file=$1
  if [[ ! -f "$file" ]]; then
    echo "Missing $file. Create it with CLIENT_ID, CLIENT_SECRET, REDIRECT_URI, and SCOPE variables." >&2
    exit 1
  fi
}

load_config() {
  local cfg="$CONFIG_FILE"
  if [[ "${cfg:0:1}" != "/" ]]; then
    if [[ -f "$cfg" ]]; then
      cfg="$cfg"
    elif [[ -f "$ROOT_DIR/$cfg" ]]; then
      cfg="$ROOT_DIR/$cfg"
    elif [[ -f "$ROOT_DIR/env/.oauth_config" ]]; then
      cfg="$ROOT_DIR/env/.oauth_config"
    fi
  else
    # absolute path provided but missing; fall back to env/.oauth_config if available
    if [[ ! -f "$cfg" && -f "$ROOT_DIR/env/.oauth_config" ]]; then
      cfg="$ROOT_DIR/env/.oauth_config"
    fi
  fi
  CONFIG_FILE="$cfg"
  require_file "$cfg"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${CLIENT_ID:?Set CLIENT_ID in $CONFIG_FILE}"
  : "${CLIENT_SECRET:?Set CLIENT_SECRET in $CONFIG_FILE}"
  : "${REDIRECT_URI:?Set REDIRECT_URI in $CONFIG_FILE}"
  : "${SCOPE:?Set SCOPE in $CONFIG_FILE}"
  export API_ROOT CLIENT_ID CLIENT_SECRET REDIRECT_URI SCOPE
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

ensure_valid_access_token() {
  load_state
  : "${ACCESS_TOKEN:?No access token saved. Run exchange or refresh.}"
  : "${EXPIRES_AT:?No expiry found. Run exchange to regenerate state.}"
  local now
  now=$(date +%s)
  if (( now >= EXPIRES_AT - 30 )); then
    echo "Access token expired or expiring soon, refreshing..."
    refresh_token quiet
    load_state
  fi
}

save_state() {
  cat >"$STATE_FILE" <<EOF
ACCESS_TOKEN=$ACCESS_TOKEN
REFRESH_TOKEN=$REFRESH_TOKEN
EXPIRES_AT=$EXPIRES_AT
EOF
  echo "State saved to $STATE_FILE"
}

auth_url() {
  load_config
  local encoded_redirect
  encoded_redirect=$(python3 - <<PY
import urllib.parse, os
print(urllib.parse.quote(os.environ["REDIRECT_URI"], safe=""))
PY
)
  echo "$API_ROOT/oauth/authorize?client_id=${CLIENT_ID}&redirect_uri=${encoded_redirect}&response_type=code&scope=${SCOPE}"
}

refresh_token() {
  load_config
  load_state
  : "${REFRESH_TOKEN:?No refresh token saved. Run exchange first.}"
  local print_response=${1:-yes}
  local response
  response=$(curl -sS -X POST "$API_ROOT/oauth/token" \
    -u "$CLIENT_ID:$CLIENT_SECRET" \
    -d "grant_type=refresh_token" \
    -d "refresh_token=$REFRESH_TOKEN")
  if [[ "$print_response" == "yes" ]]; then
    echo "$response" | jq .
  fi
  ACCESS_TOKEN=$(jq -r '.access_token // empty' <<<"$response")
  REFRESH_TOKEN=$(jq -r '.refresh_token // empty' <<<"$response")
  local expires_in
  expires_in=$(jq -r '.expires_in // 0' <<<"$response")
  EXPIRES_AT=$(( $(date +%s) + expires_in ))
  [[ -n "$ACCESS_TOKEN" ]] && save_state || exit 1
}

call_api() {
  ensure_valid_access_token
  local endpoint=${1:? "Usage: $0 call /v2/me"}
  curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" "$API_ROOT$endpoint"
}

token_info() {
  ensure_valid_access_token
  curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" "$API_ROOT/oauth/token/info"
}

usage() {
  cat <<EOF
Usage: $0 <command> [args]

Commands:
  refresh               Refresh the access token using the saved refresh token.
  call <endpoint>       Call an API endpoint using the saved access token (e.g., /v2/me).
  token-info            Inspect the current access token metadata.

Environment files:
  $CONFIG_FILE    # must define CLIENT_ID, CLIENT_SECRET, REDIRECT_URI, SCOPE
  $STATE_FILE     # auto-generated; stores ACCESS_TOKEN, REFRESH_TOKEN, EXPIRES_AT
EOF
}

cmd=${1:-}
case "$cmd" in
  refresh) refresh_token ;;
  call) shift; call_api "$@" ;;
  token-info) token_info ;;
  *) usage ;;
esac
