#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-.oauth_config}"
STATE_FILE="${STATE_FILE:-.oauth_state}"
API_ROOT="https://api.intra.42.fr"

require_file() {
  local file=$1
  if [[ ! -f "$file" ]]; then
    echo "Missing $file. Create it with CLIENT_ID, CLIENT_SECRET, REDIRECT_URI, and SCOPE variables." >&2
    exit 1
  fi
}

load_config() {
  require_file "$CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${CLIENT_ID:?Set CLIENT_ID in $CONFIG_FILE}"
  : "${CLIENT_SECRET:?Set CLIENT_SECRET in $CONFIG_FILE}"
  : "${REDIRECT_URI:?Set REDIRECT_URI in $CONFIG_FILE}"
  : "${SCOPE:?Set SCOPE in $CONFIG_FILE}"
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

listen_callback() {
  load_config
  local port
  port=$(python3 - <<PY
import urllib.parse, os
url = urllib.parse.urlparse(os.environ["REDIRECT_URI"])
print(url.port or 80)
PY
)
  echo "Listening for callback on $REDIRECT_URI ..."
  python3 - <<'PY'
import http.server, urllib.parse, os

redirect = urllib.parse.urlparse(os.environ["REDIRECT_URI"])
host = redirect.hostname or "127.0.0.1"
port = redirect.port or (443 if redirect.scheme == "https" else 80)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        query = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(query)
        code = params.get("code", [""])[0]
        print(f"\nAuthorization code: {code}")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"You can close this tab.")
        raise SystemExit

    def log_message(self, fmt, *args):
        pass

server = http.server.HTTPServer((host, port), Handler)
print(f"Callback server running on {host}:{port}")
server.serve_forever()
PY
}

login_once() {
  load_config
  local code
  code=$(python3 - <<'PY'
import http.server, urllib.parse, os, threading, sys, webbrowser

API_ROOT = os.environ.get("API_ROOT")
CLIENT_ID = os.environ.get("CLIENT_ID")
SCOPE = os.environ.get("SCOPE")
REDIRECT_URI = os.environ.get("REDIRECT_URI")

redirect = urllib.parse.urlparse(REDIRECT_URI)
host = redirect.hostname or "127.0.0.1"
port = redirect.port or (443 if redirect.scheme == "https" else 80)
auth_url = f"{API_ROOT}/oauth/authorize?client_id={CLIENT_ID}&redirect_uri={urllib.parse.quote(REDIRECT_URI, safe='')}&response_type=code&scope={SCOPE}"

code_holder = {"code": ""}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        query = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(query)
        code_holder["code"] = params.get("code", [""])[0]
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"You can close this tab.")
        threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, fmt, *args):
        pass

server = http.server.HTTPServer((host, port), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()

print("Opening browser for authorization...")
webbrowser.open(auth_url)
print(f"If the browser did not open, visit:\n{auth_url}")

try:
    server.serve_forever()
except KeyboardInterrupt:
    pass

server.server_close()
sys.stdout.write(code_holder["code"])
PY
)
  if [[ -z "$code" ]]; then
    echo "No authorization code captured." >&2
    exit 1
  fi
  echo "Captured authorization code, exchanging..."
  exchange_code "$code"
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

usage() {
  cat <<EOF
Usage: $0 <command> [args]

Commands:
  auth-url              Print the OAuth authorize URL with current config.
  listen                Run a temporary callback server to capture ?code= in the terminal.
  login                 Open browser, capture code once, exchange, and save tokens.
  exchange <code>       Exchange an authorization code for tokens and save them.
  refresh               Refresh the access token using the saved refresh token.
  call <endpoint>       Call an API endpoint using the saved access token (e.g., /v2/me).

Environment files:
  $CONFIG_FILE    # must define CLIENT_ID, CLIENT_SECRET, REDIRECT_URI, SCOPE
  $STATE_FILE     # auto-generated; stores ACCESS_TOKEN, REFRESH_TOKEN, EXPIRES_AT
EOF
}

cmd=${1:-}
case "$cmd" in
  auth-url) auth_url ;;
  listen) listen_callback ;;
  login) login_once ;;
  exchange) shift; exchange_code "$@" ;;
  refresh) refresh_token ;;
  call) shift; call_api "$@" ;;
  *) usage ;;
esac
