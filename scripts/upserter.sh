#!/bin/bash

# upserter.sh - Stage 3: Batch upsert to database
# Reads from process_queue, loads cached JSON, upserts to DB
# No rate limiting needed (local DB is fast)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"
EXPORTS_USERS="$ROOT_DIR/exports/09_users"

mkdir -p "$BACKLOG_DIR" "$LOG_DIR" "$EXPORTS_USERS"

LOG_FILE="$LOG_DIR/upserter.log"

# Config
source "$ROOT_DIR/scripts/config/agents.config" 2>/dev/null || true
source "$ROOT_DIR/.env" 2>/dev/null || true

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-api42}"
DB_PASSWORD="${DB_PASSWORD:-api42}"
DB_NAME="${DB_NAME:-api42}"

PROCESS_QUEUE="$BACKLOG_DIR/process_queue.txt"
[[ ! -f "$PROCESS_QUEUE" ]] && touch "$PROCESS_QUEUE"

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Upserter started (no batching, immediate upserts)" | tee -a "$LOG_FILE"

COUNTER=0

# Main loop
while true; do
  # Read random line from process queue
  if [[ -s "$PROCESS_QUEUE" ]]; then
    # Get random line number
    TOTAL_LINES=$(wc -l < "$PROCESS_QUEUE")
    RANDOM_LINE=$((RANDOM % TOTAL_LINES + 1))
    USER_ID=$(sed -n "${RANDOM_LINE}p" "$PROCESS_QUEUE")
    
    if [[ -n "$USER_ID" ]]; then
      # Remove the selected line from queue
      sed -i "${RANDOM_LINE}d" "$PROCESS_QUEUE"
      
      campus_id=0
      snapshot_file=""
      
      # Find the snapshot file (it was created by fetcher)
      for campus_dir in "$EXPORTS_USERS"/campus_*; do
        if [[ -f "$campus_dir/user_${USER_ID}.json" ]]; then
          snapshot_file="$campus_dir/user_${USER_ID}.json"
          campus_id=$(basename "$campus_dir" | sed 's/campus_//')
          break
        fi
      done
      
      if [[ -z "$snapshot_file" ]]; then
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ⚠️  User $USER_ID: snapshot not found" | tee -a "$LOG_FILE"
        continue
      fi
      
      # Load JSON
      user_json=$(cat "$snapshot_file" 2>/dev/null || echo "")
      [[ -z "$user_json" ]] && continue
      
      # Extract campus_id from campus_users (first campus)
      campus_id=$(echo "$user_json" | jq '.campus_users[0].campus_id // 0' 2>/dev/null)
      [[ -z "$campus_id" ]] && campus_id=0
      [[ "$campus_id" == "null" ]] && campus_id=0
      
      # Extract fields
      login=$(echo "$user_json" | jq -r '.login // ""' 2>/dev/null | sed "s/'/''/g")
      email=$(echo "$user_json" | jq -r '.email // ""' 2>/dev/null | sed "s/'/''/g")
      first_name=$(echo "$user_json" | jq -r '.first_name // ""' 2>/dev/null | sed "s/'/''/g")
      last_name=$(echo "$user_json" | jq -r '.last_name // ""' 2>/dev/null | sed "s/'/''/g")
      correction_point=$(echo "$user_json" | jq -r '.correction_point // 0' 2>/dev/null)
      wallet=$(echo "$user_json" | jq -r '.wallet // 0' 2>/dev/null)
      location=$(echo "$user_json" | jq -r '.location // ""' 2>/dev/null | sed "s/'/''/g")
      
      # Upsert to DB immediately
      PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=0 \
        -c "INSERT INTO users (id, login, email, first_name, last_name, correction_point, wallet, location, campus_id) 
            VALUES ($USER_ID, E'$login', E'$email', E'$first_name', E'$last_name', $correction_point, $wallet, E'$location', $campus_id)
            ON CONFLICT (id) DO UPDATE SET
              login=EXCLUDED.login,
              email=EXCLUDED.email,
              correction_point=EXCLUDED.correction_point,
              wallet=EXCLUDED.wallet,
              location=EXCLUDED.location,
              campus_id=EXCLUDED.campus_id;" \
        2>/dev/null || true
      
      COUNTER=$((COUNTER + 1))
      echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ✓ Upserted user $USER_ID (total: $COUNTER)" | tee -a "$LOG_FILE"
    fi
  else
    # No more items in queue
    sleep 2
  fi
done
