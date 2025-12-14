#!/usr/bin/env bash
set -euo pipefail

# Log cleanup script - Daily log file management
# Logs are organized by date: name_YYYY-MM-DD.log
# This script compresses logs > 7 days old and deletes logs > 30 days old
# Called daily by cron at 02:00 UTC

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"

echo "════════════════════════════════════════════════════════════════"
echo "LOG CLEANUP - $(date -u '+%Y-%m-%d %H:%M:%S %Z')"
echo "════════════════════════════════════════════════════════════════"

mkdir -p "$LOG_DIR"

# ════════════════════════════════════════════════════════════════
# COMPRESS LOGS OLDER THAN 7 DAYS
# ════════════════════════════════════════════════════════════════

echo ""
echo "Compressing logs older than 7 days..."

compressed_count=0
while IFS= read -r logfile; do
  if [[ -f "$logfile" && ! "$logfile" =~ \.gz$ ]]; then
    if gzip "$logfile" 2>/dev/null; then
      echo "✓ Compressed: ${logfile##*/}.gz"
      ((compressed_count++)) || true
    fi
  fi
done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "*.log" -mtime +7)

echo "✓ Compressed $compressed_count old logs"

# ════════════════════════════════════════════════════════════════
# DELETE LOGS OLDER THAN 30 DAYS
# ════════════════════════════════════════════════════════════════

echo ""
echo "Deleting logs older than 30 days..."

deleted_count=$(find "$LOG_DIR" -maxdepth 1 -type f \( -name "*.log.gz" -o -name "*.log" \) -mtime +30 | wc -l)
find "$LOG_DIR" -maxdepth 1 -type f \( -name "*.log.gz" -o -name "*.log" \) -mtime +30 -delete

if [[ $deleted_count -gt 0 ]]; then
  echo "✓ Deleted $deleted_count old logs"
else
  echo "✓ No logs to delete"
fi

# ════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "LOG STATUS SUMMARY"
echo "════════════════════════════════════════════════════════════════"

active_count=$(find "$LOG_DIR" -maxdepth 1 -type f -name "*.log" | wc -l)
compressed_count=$(find "$LOG_DIR" -maxdepth 1 -type f -name "*.log.gz" | wc -l)
total_size=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)

echo "Active logs:     $active_count files"
echo "Compressed logs: $compressed_count files"
echo "Total size:      $total_size"
echo ""
echo "Retention policy:"
echo "  • Keep active logs:    7 days"
echo "  • Keep compressed:     30 days"
echo "  • Delete older:        >30 days"
echo ""
echo "✓ Log cleanup complete"
