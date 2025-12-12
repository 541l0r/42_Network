#!/usr/bin/env bash
set -euo pipefail

# Nightly stable tables update for cursus 21 (42cursus)
# 
# Fetch Phase (API calls):
#   1. Cursus metadata (1 hit)
#   2. Cursus 21 projects (1-2 hits)
#   3. Cursus 21 students (5-20 hits, incremental)
#   4. Per-campus achievements (1-2 hits per campus, ~10 total)
#   5. Per-campus projects_users (2-5 hits per campus, ~20 total)
#   Total: ~35-50 API hits per night (vs 1,130+ for full sync)
#
# Update Phase (database):
#   1. Campuses (reference)
#   2. Cursus & projects (reference)
#   3. Users (cursus 21, kind=student only, alumni=false)
#   4. Projects_users enrollments (per campus)
#   5. Achievements (per campus, then achievements_users)
#   6. Coalitions (gamification, optional daily)
#
# Run once per night, triggered by cron at 2 AM UTC

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
FETCH_DIR="$ROOT_DIR/scripts/helpers"
STABLE_DIR="$ROOT_DIR/scripts/update_stable_tables"
CONFIG_FILE="$ROOT_DIR/scripts/config/logging.conf"

# Load logging config
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
else
  LOG_WRITE_DELAY_SECONDS=1
fi

# Export filters for all fetch scripts
export FILTER_KIND=student
export FILTER_ALUMNI=false  # Exclude alumni users
export FILTER_STATUS=""
export LOG_WRITE_DELAY_SECONDS  # Pass to child scripts

mkdir -p "$LOG_DIR"

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG_DIR/nightly_stable_tables.log"
  sleep "$LOG_WRITE_DELAY_SECONDS"  # Delay between log writes
}

log "════════════════════════════════════════════════════════════════"
log "NIGHTLY CURSUS 21 STABLE TABLES UPDATE"
log "═══════════════════════════════════════════════════════════════="
log "Scope: kind=student, alumni?=false (excludes all alumni users)"
log "════════════════════════════════════════════════════════════════"
START_TOTAL=$(date +%s)

# Refresh token before starting
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"
bash "$TOKEN_HELPER" refresh > /dev/null 2>&1
log "✓ Token refreshed"

# ═════════════════════════════════════════════════════════════════
# PHASE 1: FETCH DATA FROM API
# ═════════════════════════════════════════════════════════════════
log ""
log "PHASE 1: FETCHING CURSUS 21 DATA (expected ~40-50 API hits)"
log "─────────────────────────────────────────────────────────────"

FETCH_START=$(date +%s)

# Fetch cursus 21 core data (runs orchestrator with all per-campus loops)
log ""
log "Step 1.1: Fetching cursus, projects, users, achievements, enrollments..."
if bash "$FETCH_DIR/fetch_cursus_21_core_data.sh" >> "$LOG_DIR/nightly_stable_tables.log" 2>&1; then
  log "✓ Cursus 21 core data fetched"
else
  log "✗ Core data fetch failed (continuing with available data...)"
fi

FETCH_END=$(date +%s)
FETCH_DURATION=$(( FETCH_END - FETCH_START ))
log "Phase 1 complete: ${FETCH_DURATION}s"

# ═════════════════════════════════════════════════════════════════
# PHASE 2: UPDATE DATABASE TABLES (dependency order)
# ═════════════════════════════════════════════════════════════════
log ""
log "PHASE 2: UPDATING DATABASE TABLES"
log "─────────────────────────────────────────────────────────────"

UPDATE_START=$(date +%s)

# Step 2.1: Foundation tables (campuses, cursus, projects)
log ""
log "Step 2.1: Updating reference tables (campuses, cursus, projects)..."
bash "$STABLE_DIR/update_campuses.sh" >> "$LOG_DIR/nightly_stable_tables.log" 2>&1 && log "  ✓ Campuses" || log "  ✗ Campuses"
bash "$STABLE_DIR/update_cursus.sh" >> "$LOG_DIR/nightly_stable_tables.log" 2>&1 && log "  ✓ Cursus" || log "  ✗ Cursus"
bash "$STABLE_DIR/update_projects.sh" >> "$LOG_DIR/nightly_stable_tables.log" 2>&1 && log "  ✓ Projects" || log "  ✗ Projects"

# Step 2.2: Users table (cursus 21, kind=student, alumni=false)
log ""
log "Step 2.2: Updating users (cursus 21, kind=student)..."
if bash "$STABLE_DIR/update_users_cursus.sh" >> "$LOG_DIR/nightly_stable_tables.log" 2>&1; then
  log "  ✓ Users"
else
  log "  ✗ Users (continuing...)"
fi

# Step 2.3: Enrollments (projects_users per campus)
log ""
log "Step 2.3: Updating projects_users (enrollments)..."
if bash "$STABLE_DIR/update_projects_users_cursus.sh" >> "$LOG_DIR/nightly_stable_tables.log" 2>&1; then
  log "  ✓ Projects_users"
else
  log "  ✗ Projects_users (continuing...)"
fi

# Step 2.4: Achievements and achievements_users
log ""
log "Step 2.4: Updating achievements..."
if bash "$STABLE_DIR/update_achievements_cursus.sh" >> "$LOG_DIR/nightly_stable_tables.log" 2>&1; then
  log "  ✓ Achievements & achievements_users"
else
  log "  ✗ Achievements (continuing...)"
fi

# Step 2.5: Coalitions (gamification - optional)
log ""
log "Step 2.5: Updating coalitions (gamification)..."
bash "$STABLE_DIR/update_coalitions.sh" >> "$LOG_DIR/nightly_stable_tables.log" 2>&1 && log "  ✓ Coalitions" || log "  ✗ Coalitions"
bash "$STABLE_DIR/update_coalitions_users.sh" >> "$LOG_DIR/nightly_stable_tables.log" 2>&1 && log "  ✓ Coalitions_users" || log "  ✗ Coalitions_users"

UPDATE_END=$(date +%s)
UPDATE_DURATION=$(( UPDATE_END - UPDATE_START ))
log "Phase 2 complete: ${UPDATE_DURATION}s"

# ═════════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════════
log ""
END_TOTAL=$(date +%s)
TOTAL_DURATION=$(( END_TOTAL - START_TOTAL ))

log "════════════════════════════════════════════════════════════════"
log "NIGHTLY UPDATE COMPLETE"
log "════════════════════════════════════════════════════════════════"
log "Fetch phase:   ${FETCH_DURATION}s (~40-50 API hits)"
log "Update phase:  ${UPDATE_DURATION}s"
log "Total time:    ${TOTAL_DURATION}s"
log ""
log "Tables updated:"
log "  • Reference: campuses, cursus, projects, achievements"
log "  • Primary:   users (cursus 21, kind=student, alumni=false)"
log "  • Enrollments: projects_users per campus"
log "  • Gamification: coalitions, coalitions_users"
log ""
log "Next: live_db_sync.sh (real-time updates, runs separately)"
log ""
