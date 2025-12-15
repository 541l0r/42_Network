#!/bin/bash

# fetcher.sh - Stage 1: Fetch JSON from API and cache
# Fetches users from fetch_queue, saves JSON, enqueues to process_queue
# Rate limited independently from upsert

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"
EXPORTS_USERS="$ROOT_DIR/exports/09_users"

mkdir -p "$BACKLOG_DIR" "$LOG_DIR" "$EXPORTS_USERS"

LOG_FILE="$LOG_DIR/fetcher.log"

# Config
source "$ROOT_DIR/scripts/config/agents.config" 2>/dev/null || true
source "$ROOT_DIR/.env" 2>/dev/null || true

API_TOKEN="${API_TOKEN:-}"
BASE_URL="${API_BASE:-https://api.intra.42.fr}"
RATE_LIMIT_DELAY="${RATE_LIMIT_DELAY:-3.6}"  # 3.6 seconds = 1000 req/hour max
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"

FETCH_QUEUE="$BACKLOG_DIR/fetch_queue.txt"
PROCESS_QUEUE="$BACKLOG_DIR/process_queue.txt"

[[ ! -f "$FETCH_QUEUE" ]] && touch "$FETCH_QUEUE"
[[ ! -f "$PROCESS_QUEUE" ]] && touch "$PROCESS_QUEUE"

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Fetcher started (rate limit: ${RATE_LIMIT_DELAY}s)" | tee -a "$LOG_FILE"

COUNTER=0
FETCH_ERRORS=0

while true; do
  # Read next user ID from fetch queue
  if ! IFS= read -r USER_ID < "$FETCH_QUEUE" 2>/dev/null; then
    sleep 5
    continue
  fi
  
  [[ -z "$USER_ID" ]] && continue
  
  # Remove from fetch queue
  tail -n +2 "$FETCH_QUEUE" > "$FETCH_QUEUE.tmp" && mv "$FETCH_QUEUE.tmp" "$FETCH_QUEUE"
  
  COUNTER=$((COUNTER + 1))
  
  # Fetch user JSON from API using token manager
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] → Fetching user $USER_ID"
  
  user_json=$("$TOKEN_HELPER" call "/v2/users/$USER_ID" 2>/dev/null || echo "")
  
  if [[ -z "$user_json" ]]; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ⚠️  User $USER_ID: empty response (retrying)" | tee -a "$LOG_FILE"
    # Re-enqueue for retry
    echo "$USER_ID" >> "$FETCH_QUEUE"
    FETCH_ERRORS=$((FETCH_ERRORS + 1))
    sleep "$RATE_LIMIT_DELAY"
    continue
  fi
  
  if ! echo "$user_json" | jq empty >/dev/null 2>&1; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ⚠️  User $USER_ID: invalid JSON (skipping)" | tee -a "$LOG_FILE"
    FETCH_ERRORS=$((FETCH_ERRORS + 1))
    sleep "$RATE_LIMIT_DELAY"
    continue
  fi
  
  # Extract campus_id from campus_users (first campus)
  campus_id=$(echo "$user_json" | jq '.campus_users[0].campus_id // 0' 2>/dev/null)
  [[ -z "$campus_id" ]] && campus_id=0
  [[ "$campus_id" == "null" ]] && campus_id=0
  
  mkdir -p "$EXPORTS_USERS/campus_${campus_id}"
  echo "$user_json" > "$EXPORTS_USERS/campus_${campus_id}/user_${USER_ID}.json"
  
  # Enqueue to process queue for upserter
  echo "$USER_ID" >> "$PROCESS_QUEUE"
  
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ✓ Fetched user $USER_ID (campus $campus_id) → process_queue" | tee -a "$LOG_FILE"
  
  sleep "$RATE_LIMIT_DELAY"
  
  if [[ $((COUNTER % 20)) -eq 0 ]]; then
    FETCH_QUEUE_SIZE=$(wc -l < "$FETCH_QUEUE" 2>/dev/null || echo "0")
    PROCESS_QUEUE_SIZE=$(wc -l < "$PROCESS_QUEUE" 2>/dev/null || echo "0")
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Stats: Fetched=$COUNTER | Errors=$FETCH_ERRORS | FetchQueue=$FETCH_QUEUE_SIZE | ProcessQueue=$PROCESS_QUEUE_SIZE" | tee -a "$LOG_FILE"
    
    # Trim log to prevent growth (every 20 iterations)
    [[ $(wc -l < "$LOG_FILE" 2>/dev/null || echo "0") -gt 1000 ]] && tail -500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
done
