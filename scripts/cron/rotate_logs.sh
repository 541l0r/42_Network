#!/usr/bin/env bash
set -euo pipefail

# Log rotation and cleanup script
# Manages log file retention, compression, and archival
# Called daily by cron

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="$ROOT_DIR/scripts/config/logging.conf"

# Source config
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
else
  echo "ERROR: Config file not found: $CONFIG_FILE"
  exit 1
fi

# Create directories if needed
mkdir -p "$LOG_DIR" "$LOG_ARCHIVE_DIR" "$TEMP_LOG_DIR"

echo "════════════════════════════════════════════════════════════════"
echo "LOG ROTATION & CLEANUP - $(date -u '+%Y-%m-%d %H:%M:%S %Z')"
echo "════════════════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════
# ROTATE & ARCHIVE MAIN LOGS
# ════════════════════════════════════════════════════════════════

rotate_log() {
  local logfile=$1
  local retention=$2
  
  if [[ -f "$logfile" ]]; then
    local size_mb=$(du -m "$logfile" | cut -f1)
    
    # Rotate if size > 50MB or age = 1 day
    if [[ $size_mb -gt $LOG_ROTATION_SIZE_MB ]] || [[ -n "$(find "$logfile" -mtime +0)" ]]; then
      local timestamp=$(date -u +"%Y%m%d_%H%M%S")
      local rotated="${logfile}.${timestamp}"
      
      mv "$logfile" "$rotated"
      touch "$logfile"
      echo "✓ Rotated: $logfile (${size_mb}MB)"
      
      # Compress and move to archive
      if [[ "$ENABLE_LOG_COMPRESSION" == "true" ]]; then
        if gzip "$rotated"; then
          mv "${rotated}.gz" "$LOG_ARCHIVE_DIR/"
          echo "  → Archived: ${rotated##*/}.gz"
        fi
      else
        mv "$rotated" "$LOG_ARCHIVE_DIR/"
      fi
    fi
  fi
}

# Rotate main logs
echo ""
echo "Rotating main pipeline logs..."
rotate_log "$LOG_DIR/$LOG_NIGHTLY" "$RETENTION_MAIN_LOGS"
rotate_log "$LOG_DIR/$LOG_NIGHTLY_CRON" "$RETENTION_MAIN_LOGS"
rotate_log "$LOG_DIR/$LOG_LIVE_SYNC" "$RETENTION_MAIN_LOGS"

# Rotate component logs
echo ""
echo "Rotating component logs..."
for logfile in \
  "$LOG_DIR/$LOG_FETCH_CURSUS" \
  "$LOG_DIR/$LOG_FETCH_PROJECTS" \
  "$LOG_DIR/$LOG_FETCH_USERS" \
  "$LOG_DIR/$LOG_FETCH_ACHIEVEMENTS" \
  "$LOG_DIR/$LOG_UPDATE_CAMPUSES" \
  "$LOG_DIR/$LOG_UPDATE_CURSUS" \
  "$LOG_DIR/$LOG_UPDATE_PROJECTS"; do
  rotate_log "$logfile" "$RETENTION_COMPONENT_LOGS"
done

# ════════════════════════════════════════════════════════════════
# DELETE OLD ARCHIVED LOGS
# ════════════════════════════════════════════════════════════════

echo ""
echo "Cleaning up old archives (retention: ${RETENTION_ARCHIVE} days)..."
find "$LOG_ARCHIVE_DIR" -type f -mtime +$RETENTION_ARCHIVE -delete
deleted_count=$(find "$LOG_ARCHIVE_DIR" -type f | wc -l)
echo "✓ Kept ${deleted_count} archived logs"

# ════════════════════════════════════════════════════════════════
# DELETE TEMP LOGS
# ════════════════════════════════════════════════════════════════

echo ""
echo "Cleaning up temp logs (retention: ${RETENTION_TEMP} days)..."
find "$TEMP_LOG_DIR" -type f -mtime +$RETENTION_TEMP -delete
temp_count=$(find "$TEMP_LOG_DIR" -type f 2>/dev/null | wc -l)
echo "✓ Kept ${temp_count} temp logs"

# ════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "LOG STATUS SUMMARY"
echo "════════════════════════════════════════════════════════════════"

main_size=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)
archive_size=$(du -sh "$LOG_ARCHIVE_DIR" 2>/dev/null | cut -f1)
temp_size=$(du -sh "$TEMP_LOG_DIR" 2>/dev/null | cut -f1)

main_count=$(find "$LOG_DIR" -maxdepth 1 -type f | wc -l)
archive_count=$(find "$LOG_ARCHIVE_DIR" -type f | wc -l)
temp_count=$(find "$TEMP_LOG_DIR" -type f | wc -l)

echo "Active logs:     ${main_count} files, ${main_size}"
echo "Archived logs:   ${archive_count} files, ${archive_size}"
echo "Temp logs:       ${temp_count} files, ${temp_size}"
echo ""
echo "Retention policies:"
echo "  • Main logs:      ${RETENTION_MAIN_LOGS} days"
echo "  • Component logs: ${RETENTION_COMPONENT_LOGS} days"
echo "  • Archives:       ${RETENTION_ARCHIVE} days"
echo "  • Temp logs:      ${RETENTION_TEMP} day"
echo ""
echo "✓ Log rotation complete"
