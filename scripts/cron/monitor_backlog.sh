#!/usr/bin/env bash
set -euo pipefail

# Monitor for user changes and add to backlog
# Runs frequently (every 5-10 seconds) to detect new changes
# Maintains backlog of users needing DB update

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"
BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"

mkdir -p "$BACKLOG_DIR" "$LOG_DIR"

BACKLOG_FILE="$BACKLOG_DIR/pending_users.txt"
STATE_FILE="$BACKLOG_DIR/last_monitor_epoch"
LOG_FILE="$LOG_DIR/monitor_backlog.log"
WINDOW_SECONDS=${1:-10}  # Default: check last 10 seconds

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

# Get last monitor time
if [[ -f "$STATE_FILE" ]]; then
  LAST_EPOCH=$(cat "$STATE_FILE")
  SINCE_TIME=$(date -u -d "@$LAST_EPOCH" +'%Y-%m-%dT%H:%M:%SZ')
else
  # First run: look back WINDOW_SECONDS
  SINCE_TIME=$(date -u -d "$WINDOW_SECONDS seconds ago" +'%Y-%m-%dT%H:%M:%SZ')
fi

UNTIL_TIME=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
UNTIL_EPOCH=$(date -u -d "$UNTIL_TIME" +%s)

{
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Monitor check: $SINCE_TIME to $UNTIL_TIME"
  
  # Ensure token is fresh
  bash "$TOKEN_HELPER" ensure-fresh > /dev/null 2>&1 || true
  
  # Fetch users modified in window (per_page=100, student filter)
  response=$(bash "$TOKEN_HELPER" call "/v2/users?range%5Bupdated_at%5D=$SINCE_TIME,$UNTIL_TIME&sort=-updated_at&per_page=100" 2>/dev/null || echo "[]")
  
  # Filter to students only and extract IDs
  new_users=$(echo "$response" | python3 << 'PYTHON_EOF'
import json, sys
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list):
        print("")
        sys.exit(0)
    # Filter: kind=student, not alumni
    filtered = [str(u['id']) for u in data if u.get('kind') == 'student' and not u.get('alumni?')]
    print('\n'.join(filtered))
except:
    print("")
PYTHON_EOF
  )
  
  # Add new users to backlog
  added_count=0
  if [[ -n "$new_users" ]]; then
    while IFS= read -r user_id; do
      if [[ -z "$user_id" ]]; then
        continue
      fi
      # Check if already in backlog
      if ! grep -q "^$user_id$" "$BACKLOG_FILE" 2>/dev/null; then
        echo "$user_id" >> "$BACKLOG_FILE"
        added_count=$((added_count + 1))
      fi
    done <<< "$new_users"
  fi
  
  # Get backlog size
  backlog_size=0
  if [[ -f "$BACKLOG_FILE" ]] && [[ -s "$BACKLOG_FILE" ]]; then
    backlog_size=$(wc -l < "$BACKLOG_FILE")
  fi
  
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Added: $added_count, Backlog size: $backlog_size"
  
  # Save current timestamp for next run
  echo "$UNTIL_EPOCH" > "$STATE_FILE"
  
} | tee -a "$LOG_FILE"

# Keep log to last 500 lines
tail -500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
