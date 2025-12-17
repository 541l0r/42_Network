#!/usr/bin/env bash

# Show backlog status and statistics

BACKLOG_DIR="$1/.backlog"
[[ -z "$1" ]] && BACKLOG_DIR="/srv/42_Network/repo/.backlog"

BACKLOG_FILE="$BACKLOG_DIR/pending_users.txt"
STATE_FILE="$BACKLOG_DIR/last_monitor_epoch"

echo "═══════════════════════════════════════════════════"
echo "  BACKLOG STATUS"
echo "═══════════════════════════════════════════════════"

if [[ ! -f "$BACKLOG_FILE" ]] || [[ ! -s "$BACKLOG_FILE" ]]; then
  echo "Status: EMPTY"
  echo "Pending users: 0"
else
  pending=$(wc -l < "$BACKLOG_FILE")
  echo "Status: ACTIVE"
  echo "Pending users: $pending"
  echo ""
  echo "First 10 users:"
  head -10 "$BACKLOG_FILE" | sed 's/^/  - /'
  
  if [[ $pending -gt 10 ]]; then
    echo "  ... and $((pending - 10)) more"
  fi
fi

echo ""

if [[ -f "$STATE_FILE" ]]; then
  last_epoch=$(cat "$STATE_FILE")
  last_time=$(date -u -d "@$last_epoch" +'%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "unknown")
  echo "Last monitor: $last_time"
fi

echo "═══════════════════════════════════════════════════"
