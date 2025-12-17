#!/usr/bin/env bash
# Log cleanup & rotation
# Usage: CLEANUP_LINES=500 bash cleanup_logs.sh [--aggressive]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"

# Aggressive mode: delete old orchestra logs, keep only 3 days
AGGRESSIVE="${1:-}"

echo "=== LOG CLEANUP ==="

if [[ "$AGGRESSIVE" == "--aggressive" ]]; then
  echo "🔴 Aggressive mode: Deleting old orchestra logs..."
  find "$LOG_DIR" -name "orchestra_*.log" -mtime +3 -delete
  echo "   Deleted orchestra logs older than 3 days"
fi

TAIL_LIMIT="${CLEANUP_LINES:-500}"
for logfile in detect_changes.log fetcher.log upserter.log; do
  filepath="$LOG_DIR/$logfile"
  if [[ -f "$filepath" ]]; then
    lines=$(wc -l < "$filepath")
    if [[ $lines -gt $TAIL_LIMIT ]]; then
      tail -"$TAIL_LIMIT" "$filepath" > "${filepath}.tmp" && mv "${filepath}.tmp" "$filepath"
      echo "✓ Trimmed $logfile: $lines → $TAIL_LIMIT lines"
    fi
  fi
done

echo ""
echo "Before/After:"
du -sh "$LOG_DIR"
echo ""
echo "✓ Logs cleaned (current active logs capped at $TAIL_LIMIT lines each)"
