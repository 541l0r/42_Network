#!/bin/bash

# fetch_scope_01_08.sh
# Fetch all metadata: cursus, campuses, projects, achievements, coalition, etc.
# This is the FULL stable database scope - independent of users

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
EXPORTS_DIR="$ROOT_DIR/exports"

mkdir -p "$LOG_DIR" "$EXPORTS_DIR"

LOG_FILE="$LOG_DIR/fetch_scope_01_08.log"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $@" | tee -a "$LOG_FILE"
}

log "════════════════════════════════════════════════════════════"
log "SCOPE 01-08: Fetching metadata (cursus, campuses, projects...)"
log "════════════════════════════════════════════════════════════"

# Fetch each table in order (respecting FK dependencies)
cd "$ROOT_DIR/repo"

log ""
log "01. Cursus..."
bash scripts/helpers/fetch_cursus.sh >> "$LOG_FILE" 2>&1 || log "⚠️  Cursus fetch failed"

log ""
log "02. Campuses..."
bash scripts/helpers/fetch_campuses.sh >> "$LOG_FILE" 2>&1 || log "⚠️  Campuses fetch failed"

log ""
log "03. Achievements (metadata)..."
bash scripts/helpers/fetch_achievements.sh >> "$LOG_FILE" 2>&1 || log "⚠️  Achievements fetch failed"

log ""
log "04. Campus Achievements (N-to-N)..."
bash scripts/helpers/fetch_campus_achievements.sh >> "$LOG_FILE" 2>&1 || log "⚠️  Campus achievements fetch failed"

log ""
log "05. Projects..."
bash scripts/helpers/fetch_projects.sh >> "$LOG_FILE" 2>&1 || log "⚠️  Projects fetch failed"

log ""
log "06. Campus Projects (N-to-N)..."
bash scripts/helpers/fetch_campus_projects.sh >> "$LOG_FILE" 2>&1 || log "⚠️  Campus projects fetch failed"

log ""
log "06b. Project Users (N-to-N - legacy for completeness)..."
bash scripts/helpers/fetch_project_users.sh >> "$LOG_FILE" 2>&1 || log "⚠️  Project users fetch failed"

log ""
log "07. Project Sessions..."
bash scripts/helpers/fetch_project_sessions.sh >> "$LOG_FILE" 2>&1 || log "⚠️  Project sessions fetch failed"

log ""
log "08. Coalitions (metadata)..."
bash scripts/helpers/fetch_coalitions.sh >> "$LOG_FILE" 2>&1 || log "⚠️  Coalitions fetch failed"

log ""
log "════════════════════════════════════════════════════════════"
log "✅ SCOPE 01-08 COMPLETE"
log "════════════════════════════════════════════════════════════"
log ""
log "Metadata tables populated:"
log "  - 01_cursus/"
log "  - 02_campus/"
log "  - 03_achievements/"
log "  - 04_campus_achievements/"
log "  - 05_projects/"
log "  - 06_campus_projects/"
log "  - 06_project_users/"
log "  - 07_project_sessions/"
log "  - 08_coalitions/"
log ""
