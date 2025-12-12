#!/usr/bin/env bash
set -euo pipefail

# Live Delta Monitor CLI - Real-time monitoring dashboard for API changes
#
# Displays live statistics about changed users detected in rolling time windows
# Shows API call rates, user change frequency, and sync performance
#
# Usage:
#   live_delta_monitor.sh [WINDOW_SECONDS] [REFRESH_INTERVAL] [LOOP_COUNT]
#
# Parameters:
#   WINDOW_SECONDS    - Detection window (default: 30, range: 5-300)
#   REFRESH_INTERVAL  - Seconds between refreshes (default: 10, range: 2-60)
#   LOOP_COUNT        - How many times to refresh (default: 0 = infinite)
#
# Examples:
#   # Monitor 30-second window, refresh every 10 seconds, run forever
#   live_delta_monitor.sh
#
#   # Monitor 60-second window, refresh every 5 seconds, 12 times (2 minutes total)
#   live_delta_monitor.sh 60 5 12
#
#   # Quick check: 10-second window, refresh every 2 seconds, 5 times
#   live_delta_monitor.sh 10 2 5

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FETCH_HELPER="$ROOT_DIR/scripts/helpers/fetch_users_by_updated_at_window.sh"
LOG_DIR="$ROOT_DIR/logs"

# Parameters with defaults
WINDOW_SECONDS="${1:-30}"
REFRESH_INTERVAL="${2:-10}"
LOOP_COUNT="${3:-0}"

mkdir -p "$LOG_DIR"

# Validate parameters
if ! [[ "$WINDOW_SECONDS" =~ ^[0-9]+$ ]] || (( WINDOW_SECONDS < 5 || WINDOW_SECONDS > 300 )); then
  echo "Error: WINDOW_SECONDS must be 5-300 (got: $WINDOW_SECONDS)" >&2
  exit 1
fi

if ! [[ "$REFRESH_INTERVAL" =~ ^[0-9]+$ ]] || (( REFRESH_INTERVAL < 2 || REFRESH_INTERVAL > 60 )); then
  echo "Error: REFRESH_INTERVAL must be 2-60 (got: $REFRESH_INTERVAL)" >&2
  exit 1
fi

# Calculate stats tracking variables
ITERATION=0
TOTAL_USERS=0
MAX_USERS=0
MIN_USERS=999999
CONSECUTIVE_EMPTY=0

# Function to get current timestamp
get_ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Function to display stats header
show_header() {
  clear
  echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
  echo "║                    LIVE DELTA MONITOR - Cursus 21 Users                       ║"
  echo "║                    Real-time API change detection                             ║"
  echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Configuration:"
  echo "  Window:     $WINDOW_SECONDS seconds"
  echo "  Refresh:    Every $REFRESH_INTERVAL seconds"
  if [[ $LOOP_COUNT -gt 0 ]]; then
    echo "  Duration:   $((LOOP_COUNT * REFRESH_INTERVAL)) seconds ($LOOP_COUNT iterations)"
  else
    echo "  Duration:   Continuous (Ctrl+C to stop)"
  fi
  echo ""
}

# Function to display current stats
show_stats() {
  local ts=$(get_ts)
  local user_count="$1"
  local api_hit_count="$2"
  
  # Update tracking stats
  TOTAL_USERS=$((TOTAL_USERS + user_count))
  (( user_count > MAX_USERS )) && MAX_USERS=$user_count
  (( user_count < MIN_USERS )) && MIN_USERS=$user_count
  
  if [[ $user_count -eq 0 ]]; then
    CONSECUTIVE_EMPTY=$((CONSECUTIVE_EMPTY + 1))
  else
    CONSECUTIVE_EMPTY=0
  fi
  
  ITERATION=$((ITERATION + 1))
  
  # Calculate average
  local avg=$((TOTAL_USERS / ITERATION))
  
  # Display current iteration
  echo "[$ts] Iteration #$ITERATION"
  echo "  Changed users (${WINDOW_SECONDS}s window): $user_count"
  echo "  API hits:                    $api_hit_count"
  echo "  Stats (avg/min/max):         $avg / $MIN_USERS / $MAX_USERS"
  
  if [[ $CONSECUTIVE_EMPTY -gt 3 ]]; then
    echo "  ⚠️  ${CONSECUTIVE_EMPTY} consecutive checks with no changes"
  fi
  
  echo ""
}

# Main monitoring loop
show_header

iteration_count=0
while true; do
  (( LOOP_COUNT > 0 && iteration_count >= LOOP_COUNT )) && break
  
  ts_start=$(date -u +%s%N)
  
  # Fetch users in time window
  user_data=$(bash "$FETCH_HELPER" "$WINDOW_SECONDS" "student" "21" 2>/dev/null || echo "[]")
  user_count=$(echo "$user_data" | python3 -c "import json, sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  
  ts_end=$(date -u +%s%N)
  elapsed_ms=$(( (ts_end - ts_start) / 1000000 ))
  
  # Rough API hit estimate (100 users per page)
  api_hits=$((user_count / 100 + 1))
  
  show_stats "$user_count" "$api_hits"
  
  # Log to file
  {
    echo "$(get_ts) | Users: $user_count | API: $api_hits | Duration: ${elapsed_ms}ms"
  } >> "$LOG_DIR/live_delta_monitor.log"
  
  iteration_count=$((iteration_count + 1))
  
  if [[ $LOOP_COUNT -eq 0 ]] || (( iteration_count < LOOP_COUNT )); then
    sleep "$REFRESH_INTERVAL"
  fi
done

# Final summary
echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
echo "║                            MONITORING COMPLETE                                ║"
echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Summary (${ITERATION} iterations over ${WINDOW_SECONDS}s windows):"
echo "  Total users detected:        $TOTAL_USERS"
echo "  Average per window:          $((TOTAL_USERS / ITERATION))"
echo "  Min per window:              $MIN_USERS"
echo "  Max per window:              $MAX_USERS"
echo "  Empty windows:               $CONSECUTIVE_EMPTY"
echo ""
echo "Logs available in: $LOG_DIR/live_delta_monitor.log"
