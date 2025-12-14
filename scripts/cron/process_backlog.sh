#!/usr/bin/env bash
set -euo pipefail

# Process backlog: fetch and update users from backlog file
# Reads user IDs from backlog, fetches their data from API, updates DB

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"
BACKLOG_DIR="$ROOT_DIR/.backlog"
EXPORTS_DIR="$ROOT_DIR/exports/08_users"
LOG_DIR="$ROOT_DIR/logs"

mkdir -p "$BACKLOG_DIR" "$EXPORTS_DIR" "$LOG_DIR"

BACKLOG_FILE="$BACKLOG_DIR/pending_users.txt"
LOG_FILE="$LOG_DIR/process_backlog.log"

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

log "════════════════════════════════════════════"
log "Process Backlog - Start"
log "════════════════════════════════════════════"

# Check if backlog exists and has users
if [[ ! -f "$BACKLOG_FILE" ]] || [[ ! -s "$BACKLOG_FILE" ]]; then
  log "Backlog is empty, nothing to process"
  exit 0
fi

backlog_size=$(wc -l < "$BACKLOG_FILE")
log "Found $backlog_size users in backlog"

# Ensure token is fresh
bash "$TOKEN_HELPER" ensure-fresh > /dev/null 2>&1 || true

# Fetch data for all users in backlog (by ID)
# Build comma-separated ID list
user_ids=$(tr '\n' ',' < "$BACKLOG_FILE" | sed 's/,$//')

if [[ -z "$user_ids" ]]; then
  log "No valid user IDs in backlog"
  exit 0
fi

log "Fetching data for users: $user_ids"

# Fetch user data by IDs
# Use filter[id]=1,2,3,... (comma-separated)
response=$(bash "$TOKEN_HELPER" call "/v2/users?filter%5Bid%5D=$user_ids&per_page=100" 2>/dev/null || echo "[]")

# Filter to students and save to JSON
filtered_json=$(echo "$response" | python3 << 'PYTHON_EOF'
import json, sys
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list):
        data = []
    # Filter: kind=student, not alumni
    filtered = [u for u in data if u.get('kind') == 'student' and not u.get('alumni?')]
    print(json.dumps(filtered))
except:
    print("[]")
PYTHON_EOF
  )

filtered_count=$(echo "$filtered_json" | python3 -c "import json, sys; print(len(json.load(sys.stdin)))")
log "Fetched $filtered_count users (after filtering)"

if [[ "$filtered_count" -eq 0 ]]; then
  log "No students found to update"
  # Clear backlog anyway
  rm -f "$BACKLOG_FILE"
  exit 0
fi

# Save to JSON file for import
echo "$filtered_json" > "$EXPORTS_DIR/all.json"
log "Saved to $EXPORTS_DIR/all.json"

# Update database
log "Starting users update in database..."
bash "$ROOT_DIR/scripts/update_stable_tables/update_users_simple.sh" >> "$LOG_FILE" 2>&1 || {
  log "ERROR: Database update failed"
  exit 1
}

log "Users update complete"

# Clear backlog after successful update
rm -f "$BACKLOG_FILE"
log "Backlog cleared after processing"

log "════════════════════════════════════════════"
log "Process Backlog - Complete (updated $filtered_count users)"
log "════════════════════════════════════════════"

# Keep log to last 500 lines
tail -500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
