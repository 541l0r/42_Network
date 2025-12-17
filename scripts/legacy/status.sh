#!/usr/bin/env bash

# Show complete system status: backlog + last update + monitor

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"

BACKLOG_FILE="$BACKLOG_DIR/pending_users.txt"
STATE_FILE="$BACKLOG_DIR/last_monitor_epoch"
PROCESS_LOG="$LOG_DIR/process_backlog.log"
MONITOR_LOG="$LOG_DIR/monitor_backlog.log"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║         42 NETWORK USER SYNC SYSTEM STATUS                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# BACKLOG STATUS
echo "┌─ BACKLOG STATUS ──────────────────────────────────────────┐"
if [[ ! -f "$BACKLOG_FILE" ]] || [[ ! -s "$BACKLOG_FILE" ]]; then
  echo "│ Pending users:        0 (EMPTY)                          │"
else
  pending=$(wc -l < "$BACKLOG_FILE")
  echo "│ Pending users:        $pending                          │"
  echo "│                                                          │"
  echo "│ First 5 users:                                           │"
  head -5 "$BACKLOG_FILE" | while read uid; do
    printf "│   • %-50s │\n" "$uid"
  done
fi
echo "└──────────────────────────────────────────────────────────────┘"
echo ""

# MONITOR STATUS
echo "┌─ MONITOR STATUS ──────────────────────────────────────────┐"
if [[ -f "$STATE_FILE" ]]; then
  last_epoch=$(cat "$STATE_FILE")
  last_time=$(date -u -d "@$last_epoch" +'%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "unknown")
  echo "│ Last monitor:         $last_time            │"
else
  echo "│ Last monitor:         (never run)                         │"
fi
echo "└──────────────────────────────────────────────────────────────┘"
echo ""

# LAST PROCESS
echo "┌─ LAST PROCESS ────────────────────────────────────────────┐"
if [[ -f "$PROCESS_LOG" ]]; then
  last_lines=$(tail -3 "$PROCESS_LOG" | grep -E "Process Backlog|updated" || echo "No recent process")
  echo "$last_lines" | while read line; do
    printf "│ %-58s │\n" "$line"
  done
else
  echo "│ No process log (never run)                         │"
fi
echo "└──────────────────────────────────────────────────────────────┘"
echo ""

# DB STATUS
echo "┌─ DATABASE STATUS ─────────────────────────────────────────┐"
total_users=$(psql -h localhost -U api42 -d api42 -t -c "SELECT COUNT(*) FROM users" 2>/dev/null || echo "?")
printf "│ Total users in DB:    %-46s │\n" "$total_users"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""

# CRON STATUS
echo "┌─ CRON SCHEDULE ───────────────────────────────────────────┐"
echo "│ Monitor:              Every 5-12 seconds                   │"
echo "│ Process backlog:      Every 10 minutes                     │"
echo "│ Token refresh:        Every hour at :05                    │"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""

echo "╔════════════════════════════════════════════════════════════╗"
echo "║ How to use:                                                ║"
echo "║  • View backlog:      bash scripts/backlog_status.sh       ║"
echo "║  • Process now:       bash scripts/cron/process_backlog.sh ║"
echo "║  • Monitor once:      bash scripts/cron/monitor_backlog.sh ║"
echo "║  • View logs:         tail logs/monitor_backlog.log        ║"
echo "║                       tail logs/process_backlog.log        ║"
echo "╚════════════════════════════════════════════════════════════╝"
