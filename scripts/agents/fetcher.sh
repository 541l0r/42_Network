#!/bin/bash

# fetcher.sh - Stage 1: Fetch JSON from API and cache
# Fetches users from fetch_queue, saves JSON, enqueues to process_queue
# Uses synchronized global rate limiter (supports multiple parallel instances)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
RATE_LIMIT_DELAY="${RATE_LIMIT_DELAY:-6.0}"  # Shared across FETCHER_INSTANCES
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"

# Allow overriding the source queue (default: internal queue)
FETCH_QUEUE="${FETCH_QUEUE_FILE:-$BACKLOG_DIR/fetch_queue_internal.txt}"
PROCESS_QUEUE="$BACKLOG_DIR/process_queue.txt"
PROCESS_LOCK="$PROCESS_QUEUE.lock"

[[ ! -f "$FETCH_QUEUE" ]] && touch "$FETCH_QUEUE"
[[ ! -f "$PROCESS_QUEUE" ]] && touch "$PROCESS_QUEUE"
[[ ! -f "$PROCESS_LOCK" ]] && touch "$PROCESS_LOCK"

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Fetcher started on queue $(basename "$FETCH_QUEUE") (rate limit: ${RATE_LIMIT_DELAY}s per fetcher)" | tee -a "$LOG_FILE"

COUNTER=0
FETCH_ERRORS=0

# Lock file for coordinating multiple fetchers
LOCK_FILE="${FETCH_QUEUE}.lock"

while true; do
  # Acquire exclusive lock to safely read and modify queue
  exec 3>"$LOCK_FILE"
  flock -x 3 || { sleep 1; continue; }
  
  # Read next user ID from fetch queue
  if ! IFS= read -r USER_ID < "$FETCH_QUEUE" 2>/dev/null; then
    flock -u 3
    exec 3>&-
    sleep 5
    continue
  fi
  
  [[ -z "$USER_ID" ]] && { flock -u 3; exec 3>&-; continue; }
  
  # Remove from fetch queue (atomic operation under lock)
  tail -n +2 "$FETCH_QUEUE" > "$FETCH_QUEUE.tmp" && mv "$FETCH_QUEUE.tmp" "$FETCH_QUEUE"
  
  # Release lock
  flock -u 3
  exec 3>&-
  
  COUNTER=$((COUNTER + 1))
  
  # Per-fetcher independent rate limiting
  sleep "$RATE_LIMIT_DELAY"
  
  # Fetch user JSON from API using token manager
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] → Fetching user $USER_ID"
  
  user_json=$("$TOKEN_HELPER" call "/v2/users/$USER_ID" 2>/dev/null || echo "")
  
  if [[ -z "$user_json" ]]; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ⚠️  User $USER_ID: empty response (retrying)" | tee -a "$LOG_FILE"
    # Re-enqueue for retry
    echo "$USER_ID" >> "$FETCH_QUEUE"
    FETCH_ERRORS=$((FETCH_ERRORS + 1))
    continue
  fi
  
  if ! echo "$user_json" | jq empty >/dev/null 2>&1; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ⚠️  User $USER_ID: invalid JSON (skipping)" | tee -a "$LOG_FILE"
    FETCH_ERRORS=$((FETCH_ERRORS + 1))
    continue
  fi
  
	  # Extract primary campus_id (fallback: first campus_users or campus[0].id)
	  campus_id=$(echo "$user_json" | jq '((.campus_users[]? | select(.is_primary==true) | .campus_id) // .campus_users[0].campus_id // .campus[0].id // 0)' 2>/dev/null)
	  [[ -z "$campus_id" ]] && campus_id=0
	  [[ "$campus_id" == "null" ]] && campus_id=0
	  mkdir -p "$EXPORTS_USERS/campus_${campus_id}"
	  echo "$user_json" > "$EXPORTS_USERS/campus_${campus_id}/user_${USER_ID}.json"
  
  # Enqueue to process queue for upserter with simple lock
  {
    flock -x 5
    echo "$USER_ID" >> "$PROCESS_QUEUE"
  } 5>"$PROCESS_LOCK"
  
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ✓ Fetched user $USER_ID (campus $campus_id) → process_queue" | tee -a "$LOG_FILE"
  
  if [[ $((COUNTER % 20)) -eq 0 ]]; then
    FETCH_QUEUE_SIZE=$(wc -l < "$FETCH_QUEUE" 2>/dev/null || echo "0")
    PROCESS_QUEUE_SIZE=$(wc -l < "$PROCESS_QUEUE" 2>/dev/null || echo "0")
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Stats: Fetched=$COUNTER | Errors=$FETCH_ERRORS | FetchQueue=$FETCH_QUEUE_SIZE | ProcessQueue=$PROCESS_QUEUE_SIZE" | tee -a "$LOG_FILE"
    
    # Trim log to prevent growth (every 20 iterations)
    [[ $(wc -l < "$LOG_FILE" 2>/dev/null || echo "0") -gt 5500 ]] && tail -5000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
done
