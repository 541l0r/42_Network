#!/bin/bash

# Log cleanup & rotation
# Usage: bash cleanup_logs.sh [--aggressive]

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"

# Aggressive mode: delete old orchestra logs, keep only 3 days
AGGRESSIVE="${1:-}"

echo "=== LOG CLEANUP ==="

# Delete old orchestra logs (Dec 14 and earlier, keep only Dec 15+)
if [[ "$AGGRESSIVE" == "--aggressive" ]]; then
  echo "🔴 Aggressive mode: Deleting old orchestra logs..."
  find "$LOG_DIR" -name "orchestra_*.log" -mtime +3 -delete
  echo "   Deleted orchestra logs older than 3 days"
fi

# Current main logs to keep active (cap at 500 lines)
for logfile in detect_changes.log fetcher.log upserter.log upserter2.log; do
  filepath="$LOG_DIR/$logfile"
  if [[ -f "$filepath" ]]; then
    lines=$(wc -l < "$filepath")
    if [[ $lines -gt 500 ]]; then
      # Keep last 500 lines
      tail -500 "$filepath" > "${filepath}.tmp" && mv "${filepath}.tmp" "$filepath"
      echo "✓ Trimmed $logfile: $lines → 500 lines"
    fi
  fi
done

# Summary
echo ""
echo "Before/After:"
du -sh "$LOG_DIR"
echo ""
echo "✓ Logs cleaned (current active logs capped at 500 lines each)"
