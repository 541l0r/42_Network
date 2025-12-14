#!/bin/bash

# fetch_scope_09_12_trigger.sh
# On-demand trigger to fetch/update scope 09-12 for currently active users
# This is called:
#   - Automatically by detect_changes.sh (when users change)
#   - Manually when needed (e.g., before dashboards)

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
BACKLOG_DIR="$ROOT_DIR/.backlog"

mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/fetch_scope_09_12_trigger_$(date +'%Y%m%d_%H%M%S').log"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $@" | tee -a "$LOG_FILE"
}

log "════════════════════════════════════════════════════════════"
log "SCOPE 09-12: On-demand trigger"
log "════════════════════════════════════════════════════════════"

log ""
log "This script processes the backlog of changed users"
log "and fetches their nested data (achievements, projects, coalitions)"
log ""

# Check if backlog has content
if [ ! -f "$BACKLOG_DIR/pending_users.txt" ] || [ ! -s "$BACKLOG_DIR/pending_users.txt" ]; then
    log "⚠️  No pending users in backlog"
    log "Backlog file: $BACKLOG_DIR/pending_users.txt"
    exit 0
fi

PENDING_COUNT=$(wc -l < "$BACKLOG_DIR/pending_users.txt")
log "Found $PENDING_COUNT pending users to process"
log ""
log "Processing will occur automatically via:"
log "  - worker_process_backlog.sh (systemd timer, every 5 seconds)"
log "  - Fetches achievements_users, projects_users, coalitions_users"
log "  - Inserts into DB and clears backlog"
log ""
log "Backlog monitoring:"
tail -5 "$BACKLOG_DIR/pending_users.txt" | sed 's/^/  - /' | tee -a "$LOG_FILE"

log ""
log "════════════════════════════════════════════════════════════"
log "✅ SCOPE 09-12 TRIGGER INITIATED"
log "════════════════════════════════════════════════════════════"
log ""
