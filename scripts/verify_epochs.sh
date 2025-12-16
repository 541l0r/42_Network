#!/bin/bash

# verify_epochs.sh - Check that epoch files are being updated correctly

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"

echo "=== EPOCH VERIFICATION ==="
echo ""

# Check last_detect_epoch
if [[ -f "$BACKLOG_DIR/last_detect_epoch" ]]; then
  EPOCH=$(cat "$BACKLOG_DIR/last_detect_epoch")
  DATE=$(date -d @"$EPOCH" -u 2>/dev/null || echo "INVALID")
  MTIME=$(stat -c %Y "$BACKLOG_DIR/last_detect_epoch")
  MTIME_SECONDS_AGO=$(($(date +%s) - MTIME))
  
  echo "✓ last_detect_epoch:"
  echo "  Value: $EPOCH"
  echo "  Date: $DATE"
  echo "  File modified: ${MTIME_SECONDS_AGO}s ago"
  
  if [[ $MTIME_SECONDS_AGO -lt 120 ]]; then
    echo "  Status: ✅ HEALTHY (recently updated)"
  elif [[ $MTIME_SECONDS_AGO -lt 300 ]]; then
    echo "  Status: ⚠️  OK (within 5 minutes)"
  else
    echo "  Status: 🔴 STALE (not updated in ${MTIME_SECONDS_AGO}s)"
  fi
else
  echo "❌ last_detect_epoch: FILE NOT FOUND"
fi

echo ""

# Check last_monitor_epoch (legacy)
if [[ -f "$BACKLOG_DIR/last_monitor_epoch" ]]; then
  EPOCH=$(cat "$BACKLOG_DIR/last_monitor_epoch")
  DATE=$(date -d @"$EPOCH" -u 2>/dev/null || echo "INVALID")
  MTIME=$(stat -c %Y "$BACKLOG_DIR/last_monitor_epoch")
  MTIME_HOURS_AGO=$(($(date +%s) - MTIME))
  MTIME_HOURS_AGO=$((MTIME_HOURS_AGO / 3600))
  
  echo "⚠️  last_monitor_epoch (LEGACY):"
  echo "  Value: $EPOCH"
  echo "  Date: $DATE"
  echo "  File modified: ${MTIME_HOURS_AGO}h ago"
  echo "  Status: ℹ️  Not updated (legacy monitoring script)"
else
  echo "ℹ️  last_monitor_epoch: not present (legacy)"
fi

echo ""
echo "=== DETECTOR STATUS ==="
if grep -q "Found" "$ROOT_DIR/logs/detect_changes.log" 2>/dev/null; then
  LAST_RUN=$(grep "Found" "$ROOT_DIR/logs/detect_changes.log" | tail -1 | awk '{print $1}')
  echo "Last detector run: $LAST_RUN"
  
  # Check if detector is in cron
  if crontab -l 2>/dev/null | grep -q "detect_changes.sh"; then
    echo "✅ Detector configured in cron (runs every minute)"
  else
    echo "🔴 Detector NOT in cron"
  fi
else
  echo "❌ No detector activity found"
fi
