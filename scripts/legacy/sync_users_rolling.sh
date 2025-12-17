#!/usr/bin/env bash
set -euo pipefail

# Rolling window sync: fetch users modified in last minute and update DB every minute
# Call this from cron every 1 minute

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGS_DIR="$ROOT_DIR/logs"

mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/sync_users_rolling.log"

# Load token
if [[ -f "$ROOT_DIR/.oauth_state" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.oauth_state"
  export API_TOKEN="${ACCESS_TOKEN:-}"
fi

if [[ -z "${API_TOKEN:-}" ]]; then
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Error: API_TOKEN not set" >&2
  exit 1
fi

{
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting rolling window sync..."
  
  # Fetch users modified in rolling window (last 2 minutes to be safe)
  DELTA_HOURS=0 bash "$SCRIPT_DIR/helpers/fetch_cursus_21_users_simple.sh" || {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Error: Fetch failed" >&2
    exit 1
  }
  
  # Update database
  bash "$SCRIPT_DIR/update_stable_tables/update_users_simple.sh" || {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Error: Update failed" >&2
    exit 1
  }
  
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Rolling sync complete"
  
} 2>&1 | tee -a "$LOG_FILE"

# Keep only last 1000 lines of log
tail -1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
