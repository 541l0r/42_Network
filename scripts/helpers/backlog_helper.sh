#!/usr/bin/env bash
set -euo pipefail

# Backlog Helper - Manage pending user changes and sync state

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
STATE_DIR="$LOG_DIR/.monitor_state"

mkdir -p "$STATE_DIR"

BACKLOG_FILE="$STATE_DIR/pending_users.jsonl"

log_time() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Add user to backlog
add_to_backlog() {
  local user_id="$1"
  local reason="${2:-live_delta}"
  
  cat >> "$BACKLOG_FILE" << EOF
{"id":$user_id,"reason":"$reason","added_at":"$(log_time)"}
EOF
  echo "[$(log_time)] Added user $user_id to backlog (reason: $reason)" >> "$LOG_DIR/backlog.log" 2>/dev/null || true
}

# List pending users
list_backlog() {
  if [[ ! -f "$BACKLOG_FILE" ]] || [[ ! -s "$BACKLOG_FILE" ]]; then
    echo "Backlog is empty"
    return 0
  fi
  
  echo "Pending Users:"
  cat "$BACKLOG_FILE"
}

# Show backlog status
backlog_status() {
  local pending=0
  
  if [[ -f "$BACKLOG_FILE" ]] && [[ -s "$BACKLOG_FILE" ]]; then
    pending=$(wc -l < "$BACKLOG_FILE" || echo "0")
  fi
  
  echo "═════════════════════════════════════════"
  echo "  Backlog Status"
  echo "═════════════════════════════════════════"
  echo "  Pending users: $pending"
  echo "═════════════════════════════════════════"
}

# Clear backlog
clear_backlog() {
  if [[ -f "$BACKLOG_FILE" ]]; then
    mv "$BACKLOG_FILE" "${BACKLOG_FILE}.old" 2>/dev/null || true
    echo "Backlog cleared"
  else
    echo "Backlog already empty"
  fi
}

# Process all pending users (test mode)
process_backlog_test() {
  if [[ ! -f "$BACKLOG_FILE" ]] || [[ ! -s "$BACKLOG_FILE" ]]; then
    echo "No pending users to process"
    return 0
  fi
  
  local count=$(wc -l < "$BACKLOG_FILE" || echo "0")
  echo "Processing backlog (TEST MODE - no API calls):"
  echo "  Would process $count users:"
  
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      continue
    fi
    local user_id=$(echo "$line" | grep -oE '"id":[0-9]+' | cut -d: -f2 || echo "?")
    echo "    • User $user_id: fetch profile, projects, achievements"
  done < "$BACKLOG_FILE"
}

# Usage
usage() {
  cat << EOF
Backlog Helper - Manage pending user syncs

Usage:
  backlog_helper.sh add USER_ID [REASON]      Add user to backlog
  backlog_helper.sh list                       List pending users
  backlog_helper.sh status                     Show statistics
  backlog_helper.sh clear                      Clear backlog
  backlog_helper.sh process --test             Process (test mode)
  backlog_helper.sh help                       Show this help
EOF
}

case "${1:-help}" in
  add)
    add_to_backlog "${2:-}" "${3:-live_delta}"
    ;;
  list)
    list_backlog
    ;;
  status)
    backlog_status
    ;;
  clear)
    clear_backlog
    ;;
  process)
    process_backlog_test
    ;;
  *)
    usage
    ;;
esac
