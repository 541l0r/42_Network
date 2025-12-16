#!/bin/bash

# Global Rate Limiter Helper
# Ensures multiple fetchers respect shared API rate limit (1,200 req/hour)
# 
# Usage: source global_rate_limiter.sh
#        respect_global_rate_limit "6.0"  # wait until 6 seconds passed since last call
#
# Design:
#   - Lock file: .backlog/rate_limit.lock
#   - Timestamp file: .backlog/rate_limit.timestamp
#   - Each fetcher acquires lock, checks delay, sleeps if needed, updates timestamp
#   - This ensures synchronized access to API across all fetcher instances

LOCK_FILE="${BACKLOG_DIR:-./.backlog}/rate_limit.lock"
TIMESTAMP_FILE="${BACKLOG_DIR:-./.backlog}/rate_limit.timestamp"

respect_global_rate_limit() {
  local delay_seconds="${1:-6.0}"
  
  # Acquire exclusive lock
  exec 9>"$LOCK_FILE"
  flock -x 9
  
  # Read last call timestamp
  local last_timestamp=0
  if [[ -f "$TIMESTAMP_FILE" ]]; then
    last_timestamp=$(cat "$TIMESTAMP_FILE" 2>/dev/null || echo 0)
  fi
  
  # Calculate time since last call
  local now=$(date +%s)
  local elapsed=$((now - last_timestamp))
  
  # Sleep if needed
  if (( elapsed < ${delay_seconds%.*} )); then
    local sleep_time=$(echo "$delay_seconds - $elapsed" | bc -l)
    if (( $(echo "$sleep_time > 0" | bc -l) )); then
      sleep "$sleep_time" 2>/dev/null || sleep 1
    fi
  fi
  
  # Update timestamp
  echo "$(date +%s)" > "$TIMESTAMP_FILE"
  
  # Release lock
  flock -u 9
  exec 9>&-
}

export -f respect_global_rate_limit
