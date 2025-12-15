#!/usr/bin/env bash
set -euo pipefail

# Process backlog: fetch and update users from backlog file
# Reads user IDs from backlog, fetches their data from API, updates DB

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"
BACKLOG_DIR="$ROOT_DIR/.backlog"
EXPORTS_DIR="$ROOT_DIR/exports/08_users"
EXPORTS_USERS_DIR="$ROOT_DIR/exports/09_users"
EXPORTS_PROJECT_USERS="$ROOT_DIR/exports/10_projects_users"
EXPORTS_ACHIEVEMENTS_USERS="$ROOT_DIR/exports/11_achievements_users"
EXPORTS_COALITIONS_USERS="$ROOT_DIR/exports/12_coalitions_users"
LOG_DIR="$ROOT_DIR/logs"

mkdir -p "$BACKLOG_DIR" "$EXPORTS_DIR" "$EXPORTS_USERS_DIR" "$EXPORTS_PROJECT_USERS" "$EXPORTS_ACHIEVEMENTS_USERS" "$EXPORTS_COALITIONS_USERS" "$LOG_DIR"

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

tmp_dir=$(mktemp -d)
filtered_ndjson="$tmp_dir/filtered.ndjson"

# Fetch each user via detail endpoint (contains embedded data)
while read -r user_id; do
  [[ -z "$user_id" ]] && continue
  log "Fetching user $user_id (detail)"
  user_json=$(bash "$TOKEN_HELPER" call "/v2/users/$user_id" 2>/dev/null || echo "")
  if ! echo "$user_json" | jq empty >/dev/null 2>&1; then
    log "WARN invalid JSON for user $user_id"
    continue
  fi

  # Persist raw detail and embedded slices
  campus_id=$(echo "$user_json" | jq -r '(
    .campus[0].id //
    (.campus_users[]? | select(.is_primary==true) | .campus_id) //
    (.campus_users[0].campus_id) //
    0
  )')

  user_dir="$EXPORTS_USERS_DIR/campus_${campus_id}"
  proj_dir="$EXPORTS_PROJECT_USERS/campus_${campus_id}"
  ach_dir="$EXPORTS_ACHIEVEMENTS_USERS/campus_${campus_id}"
  coal_dir="$EXPORTS_COALITIONS_USERS/campus_${campus_id}"
  mkdir -p "$user_dir" "$proj_dir" "$ach_dir" "$coal_dir"

  echo "$user_json" > "$user_dir/user_${user_id}.json"
  echo "$user_json" | jq '.projects_users // []' > "$proj_dir/user_${user_id}.json"
  echo "$user_json" | jq '.achievements // []' > "$ach_dir/user_${user_id}.json"
  echo "$user_json" | jq '.coalitions_users // []' > "$coal_dir/user_${user_id}.json"

  # Filter to active students
  kind=$(echo "$user_json" | jq -r '.kind // empty')
  alumni_flag=$(echo "$user_json" | jq -r 'if (.["alumni?"] // .alumni // false) then "true" else "false" end')
  if [[ "$kind" != "student" ]] || [[ "$alumni_flag" == "true" ]]; then
    log "Skipping user $user_id (kind=$kind alumni=$alumni_flag)"
    continue
  fi

  echo "$user_json" >> "$filtered_ndjson"
done < <(sort -u "$BACKLOG_FILE")

if [[ ! -s "$filtered_ndjson" ]]; then
  log "No students found to update"
  rm -rf "$tmp_dir"
  # Clear backlog anyway
  rm -f "$BACKLOG_FILE"
  exit 0
fi

jq -s '.' "$filtered_ndjson" > "$EXPORTS_DIR/all.json"
filtered_count=$(jq 'length' "$EXPORTS_DIR/all.json")
log "Fetched $filtered_count users (after filtering)"
log "Saved to $EXPORTS_DIR/all.json and per-user caches"

rm -rf "$tmp_dir"

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
