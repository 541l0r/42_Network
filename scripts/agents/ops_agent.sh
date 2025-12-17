#!/usr/bin/env bash
# ops_agent.sh - lightweight operations loop for tokens, cleanup, backups
# Runs inside the ops Docker service. Interval is configurable with OPS_INTERVAL (seconds).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR"

OPS_INTERVAL="${OPS_INTERVAL:-3600}" # default: 1 hour
CLEANUP_LINES="${CLEANUP_LINES:-500}" # default truncation target
LOG_FILE="$LOG_DIR/ops_agent.log"

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"
  # Trim log to avoid growth (avoid set -e issues)
  lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if [[ "$lines" -gt 4000 ]]; then
    tail -3000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
}

run_token_refresh() {
  if bash "$ROOT_DIR/scripts/refresh_token.sh"; then
    log "Token refresh: ok"
  else
    log "Token refresh: failed"
  fi
}

run_cleanup() {
  CLEANUP_LINES="$CLEANUP_LINES" bash "$ROOT_DIR/scripts/cleanup_logs.sh" >/dev/null 2>&1 \
    && log "Cleanup logs: ok (lines=$CLEANUP_LINES)" \
    || log "Cleanup logs: skipped/failed"
}

run_backup() {
  # If a concrete backup script exists, run it; otherwise skip gracefully
  if [[ -x "$ROOT_DIR/scripts/cron/backup_database.sh" ]]; then
    if bash "$ROOT_DIR/scripts/cron/backup_database.sh"; then
      log "Backup: ok"
    else
      log "Backup: failed"
    fi
  else
    log "Backup: skipped (no scripts/cron/backup_database.sh)"
  fi
}

log "Ops agent starting (interval=${OPS_INTERVAL}s)"

while true; do
  run_token_refresh
  run_cleanup
  run_backup
  sleep "$OPS_INTERVAL"
done
