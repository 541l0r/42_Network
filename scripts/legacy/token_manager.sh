#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"  # /srv/42_Network
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/.env}"
STATE_FILE="${STATE_FILE:-$ROOT_DIR/.oauth_state}"
API_ROOT="https://api.intra.42.fr"

load_config() {
  local cfg="$CONFIG_FILE"
  # resolve config: use provided CONFIG_FILE, otherwise default to .env at project root (/srv/42_Network)
  if [[ ! -f "$cfg" && -f "$REPO_ROOT/.env" ]]; then
    cfg="$REPO_ROOT/.env"
  fi
  CONFIG_FILE="$cfg"
  if [[ ! -f "$cfg" ]]; then
    echo "Missing $cfg. Provide CLIENT_ID, CLIENT_SECRET, REDIRECT_URI, and SCOPE (ACCESS/REFRESH optional)." >&2
    exit 1
  fi
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

ensure_fresh_token() {
  # For use by major scripts: ensure token is fresh (not expiring in next hour)
  # This is called at script start to refresh proactively
  load_state
  if [[ -z "${ACCESS_TOKEN:-}" ]]; then
    echo "No access token found. Run 'token_manager.sh refresh' first." >&2
    exit 1
  fi
  : "${EXPIRES_AT:?No expiry found. Run exchange to regenerate state.}"
  local now
  now=$(date +%s)
  local expires_in=$(( EXPIRES_AT - now ))
  
  # Refresh if expires in less than 1 hour, or if already expired
  if (( expires_in < 3600 )); then
    echo "Token expires in ${expires_in}s, refreshing proactively..." >&2
    refresh_token quiet "$LOG_FILE"
    load_state
    expires_in=$(( EXPIRES_AT - now ))
    echo "Token refreshed, new expiry in ${expires_in}s" >&2
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
  local log_file="${2:-}"
  local response
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S UTC')
  
  # Log start if log file provided
  if [[ -n "$log_file" ]]; then
    echo "[$timestamp] Starting token refresh..." >> "$log_file"
  fi
  
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
  
  if [[ -n "$ACCESS_TOKEN" ]]; then
    save_state
    if [[ -n "$log_file" ]]; then
      echo "[$timestamp] Token refresh successful. Expires at: $(date -d @$EXPIRES_AT '+%Y-%m-%d %H:%M:%S UTC')" >> "$log_file"
    fi
  else
    if [[ -n "$log_file" ]]; then
      echo "[$timestamp] Token refresh FAILED" >> "$log_file"
    fi
    exit 1
  fi
}

exchange_code() {
  load_config
  local code=${1:? "Usage: $0 exchange <authorization_code>"}
  local response
  response=$(curl -sS -X POST "$API_ROOT/oauth/token" \
    -u "$CLIENT_ID:$CLIENT_SECRET" \
    -d "grant_type=authorization_code" \
    -d "code=$code" \
    -d "redirect_uri=$REDIRECT_URI")
  echo "$response" | jq .
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
  local response_code
  local response
  response=$(curl -sS -w "\n%{http_code}" -H "Authorization: Bearer $ACCESS_TOKEN" "$API_ROOT$endpoint")
  response_code=$(echo "$response" | tail -n1)
  response=$(echo "$response" | head -n-1)
  
  # If we get 401 (Unauthorized), refresh token and retry once
  if [[ "$response_code" == "401" ]]; then
    echo "Token expired (401), refreshing and retrying..." >&2
    refresh_token quiet "$LOG_FILE"
    load_state
    response=$(curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" "$API_ROOT$endpoint")
  fi
  
  echo "$response"
}

call_export() {
  ensure_valid_access_token
  local endpoint=${1:? "Usage: $0 call-export /v2/endpoint [outfile.json]"}
  local outfile=${2:-}
  local safe_name=${endpoint//\//_}
  safe_name=${safe_name##_}
  [[ -n "$safe_name" ]] || safe_name="response"
  [[ -n "$outfile" ]] || outfile="$ROOT_DIR/exports/${safe_name}.json"
  mkdir -p "$(dirname "$outfile")"
  
  local response_code
  local tmpfile
  tmpfile=$(mktemp)
  trap "rm -f $tmpfile" EXIT
  
  response_code=$(curl -g -sS -w "%{http_code}" -H "Authorization: Bearer $ACCESS_TOKEN" "$API_ROOT$endpoint" -o "$tmpfile")
  
  # If we get 401 (Unauthorized), refresh token and retry once
  if [[ "$response_code" == "401" ]]; then
    echo "Token expired (401), refreshing and retrying..." >&2
    refresh_token quiet "$LOG_FILE"
    load_state
    response_code=$(curl -g -sS -w "%{http_code}" -H "Authorization: Bearer $ACCESS_TOKEN" "$API_ROOT$endpoint" -o "$tmpfile")
  fi
  
  # Validate response
  if ! jq . "$tmpfile" >"${outfile}" 2>/dev/null; then
    echo "Invalid JSON response (HTTP $response_code). Response:" >&2
    cat "$tmpfile" >&2
    exit 1
  fi
  echo "Saved to $outfile"
}

token_info() {
  load_config
  load_state
  : "${ACCESS_TOKEN:?No access token saved. Run exchange or refresh.}"
  echo "Stored tokens:"
  echo "  ACCESS_TOKEN=$ACCESS_TOKEN"
  echo "  REFRESH_TOKEN=${REFRESH_TOKEN:-<none>}"
  if [[ -n "${EXPIRES_AT:-}" ]]; then
    local now remaining
    now=$(date +%s)
    remaining=$(( EXPIRES_AT - now ))
    echo "  EXPIRES_AT=$EXPIRES_AT (in ${remaining}s)"
  fi
  echo "Token info from API:"
  curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" "$API_ROOT/oauth/token/info" | jq .
}

usage() {
  cat <<EOF
Usage: $0 <command> [args]

Commands:
  exchange <code>       Exchange an authorization code for tokens and save them.
  refresh               Refresh the access token using the saved refresh token.
  ensure-fresh          Ensure token is fresh (refresh if expires in < 1 hour). For script startup.
  call <endpoint>       Call an API endpoint using the saved access token (e.g., /v2/me).
  call-export <ep> [f]  Call an API endpoint and save pretty JSON to file (default: exports/<ep>.json).
  token-info            Inspect the current access token metadata.

Environment files:
  $CONFIG_FILE    # must define CLIENT_ID, CLIENT_SECRET, REDIRECT_URI, SCOPE
  $STATE_FILE     # auto-generated; stores ACCESS_TOKEN, REFRESH_TOKEN, EXPIRES_AT
EOF
}

cmd=${1:-}
LOG_FILE="${LOG_FILE:-/srv/42_Network/logs/42_token_refresh.log}"
case "$cmd" in
  exchange) shift; exchange_code "$@" ;;
  refresh) refresh_token quiet "$LOG_FILE" ;;
  ensure-fresh) ensure_fresh_token ;;
  call) shift; call_api "$@" ;;
  call-export) shift; call_export "$@" ;;
  token-info) token_info ;;
  *) usage ;;
esac
