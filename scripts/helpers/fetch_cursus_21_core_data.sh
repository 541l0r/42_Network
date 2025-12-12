#!/usr/bin/env bash
set -euo pipefail

# Orchestrate project_users and achievements fetches for all cursus 21 campuses.
# Fetches cursus, cursus_projects, then per-campus: projects_users and achievements.
# Usage: ./fetch_cursus_21_core_data.sh [--force]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CURSUS_ID=21
FORCE_FLAG=${1:-}

# Export filters to child scripts
export FILTER_KIND=student
export FILTER_ALUMNI=false  # Exclude alumni users
export FILTER_STATUS=""
export SLEEP_BETWEEN_CALLS=1  # 1 second between API calls for safety margin

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*"
}

log "====== FETCH CURSUS 21 CORE DATA ORCHESTRATOR START ======"
log "Filters: kind=$FILTER_KIND, alumni?=$FILTER_ALUMNI"

# Step 1: Fetch cursus metadata (1 hit)
log "Step 1: Fetch cursus 21 metadata..."
bash "$SCRIPT_DIR/fetch_cursus.sh" $FORCE_FLAG || true

# Step 1b: Fetch coalitions (4 hits)
log "Step 1b: Fetch coalitions metadata..."
bash "$SCRIPT_DIR/fetch_coalitions.sh" $FORCE_FLAG || true

# Step 2: Fetch cursus 21 projects (1-2 hits)
log "Step 2: Fetch cursus 21 projects..."
bash "$SCRIPT_DIR/fetch_cursus_projects.sh" $FORCE_FLAG || true

# Step 2b: Extract campus_projects and project_sessions from projects
log "Step 2b: Extract campus_projects linkage (06)..."
bash "$SCRIPT_DIR/extract_campus_projects.sh" || true

log "Step 2c: Extract project_sessions (07)..."
bash "$SCRIPT_DIR/extract_project_sessions.sh" || true

# Step 3: Fetch cursus 21 users (500-1000 hits on first run, 5-20 daily)
# Filters to: kind=student AND alumni?=false
log "Step 3: Fetch cursus 21 users (kind=$FILTER_KIND, alumni?=$FILTER_ALUMNI)..."
bash "$SCRIPT_DIR/fetch_cursus_users.sh" $FORCE_FLAG || true

# Step 4: Get list of cursus 21 campuses from local data
log "Step 4: Identify cursus 21 campuses..."
CURSUS_FILE="$ROOT_DIR/exports/01_cursus/all.json"
if [[ ! -f "$CURSUS_FILE" ]]; then
  log "ERROR: Cursus file not found at $CURSUS_FILE"
  exit 1
fi

# Parse cursus.json for campus_ids of cursus 21
CAMPUS_IDS=$(jq -r '.[] | select(.id==21) | .campus_ids[]? // empty' "$CURSUS_FILE" | sort -u)

if [[ -z "$CAMPUS_IDS" ]]; then
  log "WARNING: No campuses found in cursus 21, checking alternative structure..."
  # Alternative: fetch campuses globally and filter by users_count > 2 (active campuses)
  CAMPUS_IDS=$(jq -r '.[] | select(.users_count > 2) | .id' "$ROOT_DIR/exports/02_campus/all.json" 2>/dev/null | sort -u)
  [[ -z "$CAMPUS_IDS" ]] && CAMPUS_IDS="1 12 13 14 16 20 21 22 25 26"  # Fallback: known cursus 21 campuses
fi

log "Active campuses (users_count > 2): $CAMPUS_IDS"

# Step 5: Per-campus project_users and achievements
total_hits=0
for campus_id in $CAMPUS_IDS; do
  log "Step 5.$campus_id: Fetch projects_users for campus $campus_id (cursus 21)..."
  CAMPUS_ID=$campus_id bash "$SCRIPT_DIR/fetch_projects_users_by_campus_cursus.sh" $FORCE_FLAG || true
  
  log "Step 5.$campus_id: Fetch achievements for campus $campus_id..."
  CAMPUS_ID=$campus_id bash "$SCRIPT_DIR/fetch_campus_achievements_by_id.sh" $FORCE_FLAG || true
done

# Merge all campus achievements into raw_all.json
log "Step 6: Merge campus achievements from all campuses..."
bash "$SCRIPT_DIR/merge_campus_achievements.sh" || true

log "====== CURSUS 21 CORE DATA FETCH COMPLETE ======"
log ""
