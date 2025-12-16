#!/bin/bash

# archive_bottleneck_logs.sh - Save bottleneck logs every 10 minutes during load testing
# Preserves full history of detector and fetcher activity without truncation

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
BACKLOG_DIR="$ROOT_DIR/.backlog"
ARCHIVE_DIR="$BACKLOG_DIR/archive"

mkdir -p "$ARCHIVE_DIR"

TIMESTAMP=$(date -u +'%Y%m%d_%H%M%S')

# Key bottleneck logs to archive
BOTTLENECK_LOGS=(
  "detect_changes.log"
  "fetcher.log"
)

for logfile in "${BOTTLENECK_LOGS[@]}"; do
  SRC="$LOG_DIR/$logfile"
  
  if [[ -f "$SRC" ]]; then
    # Archive with timestamp: detect_changes_20251215_093000.log
    BASENAME="${logfile%.log}"
    DEST="$ARCHIVE_DIR/${BASENAME}_${TIMESTAMP}.log"
    
    cp "$SRC" "$DEST"
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ✓ Archived $logfile → $(basename "$DEST")"
  fi
done

# Cleanup: Keep only last 288 archives (48 hours @ 10-min interval)
find "$ARCHIVE_DIR" -name "detect_changes_*.log" -o -name "fetcher_*.log" | \
  sort -r | tail -n +289 | xargs -r rm -v

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ✓ Bottleneck logs archived (keeping 48h history)"
