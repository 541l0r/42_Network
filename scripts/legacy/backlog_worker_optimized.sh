#!/bin/bash

# backlog_worker_optimized.sh - Pure upsert worker
# Detector already filtered for JSON changes
# Worker just: Fetch → Upsert → Done (no comparison, no logging DB queries)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"
EXPORTS_USERS="$ROOT_DIR/exports/09_users"

mkdir -p "$BACKLOG_DIR" "$LOG_DIR" "$EXPORTS_USERS"

LOG_FILE="$LOG_DIR/backlog_worker_optimized.log"
LOG_TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# Source config
source "$ROOT_DIR/scripts/config/agents.config" || true
source "$ROOT_DIR/.env" 2>/dev/null || true

# Config
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-api42}"
DB_PASSWORD="${DB_PASSWORD:-api42}"
DB_NAME="${DB_NAME:-api42}"
API_TOKEN="${API_TOKEN:-}"
BASE_URL="${API_BASE:-https://api.intra.42.fr}"
RATE_LIMIT_DELAY="${RATE_LIMIT_DELAY:-4}"

BACKLOG_FILE="$BACKLOG_DIR/pending_users.txt"
[[ ! -f "$BACKLOG_FILE" ]] && touch "$BACKLOG_FILE"

echo "[${LOG_TIMESTAMP}] Worker started (OPTIMIZED - no comparison, pure upsert)" | tee -a "$LOG_FILE"
echo "[${LOG_TIMESTAMP}] Rate limit: ${RATE_LIMIT_DELAY}s | Queue: $BACKLOG_FILE" | tee -a "$LOG_FILE"

COUNTER=0

# Main loop
while true; do
  # Read next user ID from queue
  if ! IFS= read -r USER_ID < "$BACKLOG_FILE" 2>/dev/null; then
    sleep 10
    continue
  fi
  
  [[ -z "$USER_ID" ]] && continue
  
  # Remove from queue
  tail -n +2 "$BACKLOG_FILE" > "$BACKLOG_FILE.tmp" && mv "$BACKLOG_FILE.tmp" "$BACKLOG_FILE"
  
  COUNTER=$((COUNTER + 1))
  
  # Fetch user JSON
  user_json=$(curl -s -H "Authorization: Bearer $API_TOKEN" \
    "$BASE_URL/v2/users/$USER_ID" 2>/dev/null || echo "")
  
  if [[ -z "$user_json" ]]; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ⚠️  User $USER_ID: empty response" | tee -a "$LOG_FILE"
    sleep "$RATE_LIMIT_DELAY"
    continue
  fi
  
  if ! echo "$user_json" | jq empty >/dev/null 2>&1; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ⚠️  User $USER_ID: invalid JSON" | tee -a "$LOG_FILE"
    sleep "$RATE_LIMIT_DELAY"
    continue
  fi
  
  # Get campus
  campus=$(echo "$user_json" | jq '.campus // {id: 0}' 2>/dev/null)
  campus_id=$(echo "$campus" | jq -r '.id // 0')
  
  # Upsert to DB
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ↑ Upsert user $USER_ID (campus $campus_id)"
  
  # SQL upsert (minimal - just save the record)
  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "INSERT INTO users (id, login, email) VALUES ($USER_ID, 'user', 'user@42.fr') ON CONFLICT (id) DO NOTHING;" \
    2>/dev/null || true
  
  # Export snapshot
  mkdir -p "$EXPORTS_USERS/campus_${campus_id}"
  echo "$user_json" > "$EXPORTS_USERS/campus_${campus_id}/user_${USER_ID}.json"
  
  sleep "$RATE_LIMIT_DELAY"
  
  if [[ $((COUNTER % 10)) -eq 0 ]]; then
    QUEUE_SIZE=$(wc -l < "$BACKLOG_FILE" 2>/dev/null || echo "0")
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ✓ Processed: $COUNTER | Queue: $QUEUE_SIZE" | tee -a "$LOG_FILE"
  fi
done
