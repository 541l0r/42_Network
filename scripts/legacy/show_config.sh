#!/usr/bin/env bash

# Show current backlog system configuration/parameters

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     BACKLOG SYSTEM - CURRENT PARAMETERS                       ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

echo "📊 MONITOR SETTINGS"
echo "──────────────────────────────────────────────────────────────"
monitor_count=$(crontab -l 2>/dev/null | grep -c "monitor_backlog.sh" || echo 0)
detection_window=$(crontab -l 2>/dev/null | grep "monitor_backlog.sh" | head -1 | grep -oE "[0-9]+ >/dev/null" | awk '{print $1}' || echo "?")
echo "  Cron entries:          $monitor_count (should be 12)"
echo "  Detection window:      ${detection_window} seconds"
echo "  Frequency:             ~12 times per minute (distributed)"
echo ""

echo "⚙️  PROCESS SETTINGS"
echo "──────────────────────────────────────────────────────────────"
process_freq=$(crontab -l 2>/dev/null | grep "process_backlog.sh" | grep -oE "\*/[0-9]+" || echo "?")
echo "  Processing frequency:  ${process_freq} minutes"
echo "  Cron entry:            1 (every 10 minutes)"
echo ""

echo "🔐 API PARAMETERS"
echo "──────────────────────────────────────────────────────────────"
per_page=$(grep "per_page=" "$ROOT_DIR/scripts/cron/monitor_backlog.sh" 2>/dev/null | grep -oE "per_page=[0-9]+" | head -1 | cut -d= -f2 || echo "?")
echo "  Page size:             $per_page users per page"
echo "  API endpoint:          /v2/users"
echo "  Filters:               kind=student, alumni?=false"
echo ""

echo "📁 PATHS"
echo "──────────────────────────────────────────────────────────────"
echo "  Root directory:        $ROOT_DIR"
echo "  Backlog directory:     $ROOT_DIR/.backlog/"
echo "  Monitor log:           $ROOT_DIR/logs/monitor_backlog.log"
echo "  Process log:           $ROOT_DIR/logs/process_backlog.log"
echo "  Export directory:      $ROOT_DIR/exports/08_users/"
echo ""

echo "🗃️  BACKLOG STATUS"
echo "──────────────────────────────────────────────────────────────"
if [[ -f "$ROOT_DIR/.backlog/pending_users.txt" ]] && [[ -s "$ROOT_DIR/.backlog/pending_users.txt" ]]; then
  pending=$(wc -l < "$ROOT_DIR/.backlog/pending_users.txt")
  echo "  Pending users:         $pending"
else
  echo "  Pending users:         0 (empty)"
fi

if [[ -f "$ROOT_DIR/.backlog/last_monitor_epoch" ]]; then
  epoch=$(cat "$ROOT_DIR/.backlog/last_monitor_epoch")
  timestamp=$(date -u -d "@$epoch" +'%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "unknown")
  echo "  Last monitor:          $timestamp"
fi
echo ""

echo "🗄️  DATABASE"
echo "──────────────────────────────────────────────────────────────"
db_host=$(grep "DB_HOST=" "$ROOT_DIR/scripts/cron/process_backlog.sh" | head -1 | grep -oE ":-[a-zA-Z0-9.]*}" | cut -d: -f2 | cut -d} -f1 || echo "localhost")
db_user=$(grep "DB_USER=" "$ROOT_DIR/scripts/cron/process_backlog.sh" | head -1 | grep -oE ":-[a-zA-Z0-9]*}" | cut -d: -f2 | cut -d} -f1 || echo "api42")
db_name=$(grep "DB_NAME=" "$ROOT_DIR/scripts/cron/process_backlog.sh" | head -1 | grep -oE ":-[a-zA-Z0-9]*}" | cut -d: -f2 | cut -d} -f1 || echo "api42")
echo "  Host:                  $db_host"
echo "  User:                  $db_user"
echo "  Database:              $db_name"
echo ""

echo "🔄 TOKEN REFRESH"
echo "──────────────────────────────────────────────────────────────"
token_freq=$(crontab -l 2>/dev/null | grep "token_manager.sh" | grep -oE "^[^ ]+" || echo "5 * * * *")
echo "  Schedule:              $token_freq"
echo ""

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  To customize, see: CONFIG_PARAMETERS.md                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
