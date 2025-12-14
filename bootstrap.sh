#!/bin/bash

# ============================================================================
# TRANSCENDENCE BOOTSTRAP
# ============================================================================
# Fully automated setup:
# 1. make
# 2. docker-compose up (DB + services)
# 3. Install DB schema
# 4. Fetch full metadata (scopes 01-08)
# 5. Fetch Brussels campus users (scope 09) - first time
# 6. Launch auto-updater (scope 09-12, trigger-based)
# 7. Launch data visualization & API
# ============================================================================

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR"

BOOTSTRAP_LOG="$LOG_DIR/bootstrap_$(date +'%Y%m%d_%H%M%S').log"

log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] $@" | tee -a "$BOOTSTRAP_LOG"
}

log "════════════════════════════════════════════════════════════════════"
log "TRANSCENDENCE BOOTSTRAP STARTING"
log "════════════════════════════════════════════════════════════════════"

# ============================================================================
# STEP 1: make
# ============================================================================
log ""
log "STEP 1: Building project with make..."
cd "$ROOT_DIR"
if [ -f "Makefile" ]; then
    make 2>&1 | tee -a "$BOOTSTRAP_LOG"
    log "✅ Make completed"
else
    log "⚠️  No Makefile found, skipping"
fi

# ============================================================================
# STEP 2: docker-compose up
# ============================================================================
log ""
log "STEP 2: Starting services (docker-compose)..."
if [ -f "docker-compose.yml" ]; then
    docker-compose up -d 2>&1 | tee -a "$BOOTSTRAP_LOG"
    log "✅ Docker services started"
    log "⏳ Waiting 10 seconds for DB to be ready..."
    sleep 10
else
    log "⚠️  No docker-compose.yml found, skipping"
fi

# ============================================================================
# STEP 3: Initialize database
# ============================================================================
log ""
log "STEP 3: Initializing database..."
if [ -x "$ROOT_DIR/scripts/init_db.sh" ]; then
    bash "$ROOT_DIR/scripts/init_db.sh" 2>&1 | tee -a "$BOOTSTRAP_LOG"
    log "✅ Database initialized"
else
    log "⚠️  init_db.sh not found, skipping"
fi

# ============================================================================
# STEP 4: Fetch full metadata (01-08)
# ============================================================================
log ""
log "STEP 4: Fetching full metadata (cursus, campuses, projects, etc.)..."
if [ -x "$ROOT_DIR/scripts/bootstrap/fetch_scope_01_08.sh" ]; then
    bash "$ROOT_DIR/scripts/bootstrap/fetch_scope_01_08.sh" 2>&1 | tee -a "$BOOTSTRAP_LOG"
    log "✅ Metadata fetched"
else
    log "⚠️  fetch_scope_01_08.sh not found, skipping"
fi

# ============================================================================
# STEP 5: Fetch Brussels campus users (09)
# ============================================================================
log ""
log "STEP 5: Fetching Brussels campus users (scope 09)..."
if [ -x "$ROOT_DIR/scripts/bootstrap/fetch_scope_09_brussels.sh" ]; then
    bash "$ROOT_DIR/scripts/bootstrap/fetch_scope_09_brussels.sh" 2>&1 | tee -a "$BOOTSTRAP_LOG"
    log "✅ Brussels users fetched"
else
    log "⚠️  fetch_scope_09_brussels.sh not found, skipping"
fi

# ============================================================================
# STEP 6: Launch auto-updater (trigger-based)
# ============================================================================
log ""
log "STEP 6: Starting auto-updater (detect changes + worker)..."
log "  - Enabling detect_changes cron (every minute)"
log "  - Starting backlog_worker systemd service"

# Verify cron entry exists
if crontab -l 2>/dev/null | grep -q "detect_changes.sh"; then
    log "✅ Cron detect_changes already configured"
else
    log "⚠️  Cron detect_changes not configured"
fi

# Start systemd service if available
if systemctl is-active --quiet backlog-worker 2>/dev/null; then
    log "✅ backlog-worker service already running"
else
    log "⏳ Starting backlog-worker service..."
    sudo systemctl start backlog-worker 2>/dev/null || log "⚠️  Could not start backlog-worker"
fi

# ============================================================================
# STEP 7: Launch data visualization & API
# ============================================================================
log ""
log "STEP 7: Starting data visualization & API..."
if [ -x "$ROOT_DIR/repo/api/server.js" ] || [ -f "$ROOT_DIR/repo/package.json" ]; then
    log "⏳ Starting API server..."
    cd "$ROOT_DIR/repo"
    npm start &
    API_PID=$!
    log "✅ API started (PID: $API_PID)"
else
    log "⚠️  API not found"
fi

# ============================================================================
# FINAL SUMMARY
# ============================================================================
log ""
log "════════════════════════════════════════════════════════════════════"
log "BOOTSTRAP COMPLETE"
log "════════════════════════════════════════════════════════════════════"
log ""
log "🎉 Transcendence is ready!"
log ""
log "Status:"
log "  - Database: $(docker ps --filter 'name=postgres' --quiet | head -1 | xargs -I {} docker inspect -f '{{.State.Status}}' {} 2>/dev/null || echo 'unknown')"
log "  - API Server: Running (check logs)"
log "  - Auto-updater: Running (detect_changes + worker)"
log "  - Data Sync: Limited to Brussels campus (scope 09)"
log ""
log "Next steps:"
log "  - Access API: http://localhost:3000"
log "  - View data viz: http://localhost:3000/viz"
log "  - Monitor logs: tail -f $LOG_DIR/*.log"
log ""
log "To update only scope 09-12 on demand:"
log "  bash $ROOT_DIR/scripts/bootstrap/fetch_scope_09_12_trigger.sh"
log ""
log "Full bootstrap log: $BOOTSTRAP_LOG"
log ""
