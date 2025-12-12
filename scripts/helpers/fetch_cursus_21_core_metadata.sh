#!/usr/bin/env bash
set -euo pipefail

# Fetch ONLY core Cursus 21 metadata (no users, no per-campus achievements)
# Tables: cursus, campuses, projects, coalitions, campus_projects, project_sessions
# Usage: ./fetch_cursus_21_core_metadata.sh [--force]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CURSUS_ID=21
FORCE_FLAG=${1:-}

# Export filters to child scripts
export FILTER_KIND=student
export FILTER_ALUMNI=false
export FILTER_STATUS=""
export SLEEP_BETWEEN_CALLS=1

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*"
}

log "====== FETCH CURSUS 21 CORE METADATA ONLY ======"
log "Filters: kind=$FILTER_KIND, alumni?=$FILTER_ALUMNI"

# Step 1: Fetch cursus metadata (1 hit)
log "Step 1: Fetch cursus 21 metadata..."
bash "$SCRIPT_DIR/fetch_cursus.sh" $FORCE_FLAG || true

# Step 1b: Fetch coalitions (4 hits)
log "Step 1b: Fetch coalitions metadata..."
bash "$SCRIPT_DIR/fetch_coalitions.sh" $FORCE_FLAG || true

# Step 2: Fetch cursus 21 projects (6 hits)
log "Step 2: Fetch cursus 21 projects..."
bash "$SCRIPT_DIR/fetch_cursus_projects.sh" $FORCE_FLAG || true

# Step 2b: Extract campus_projects and project_sessions from projects
log "Step 2b: Extract campus_projects linkage (06)..."
bash "$SCRIPT_DIR/extract_campus_projects.sh" || true

log "Step 2c: Extract project_sessions (07)..."
bash "$SCRIPT_DIR/extract_project_sessions.sh" || true

log "====== CURSUS 21 CORE METADATA FETCH COMPLETE ======"
log ""

exit 0
