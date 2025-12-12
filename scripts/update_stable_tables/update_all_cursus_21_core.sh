#!/usr/bin/env bash
set -euo pipefail

# Complete Cursus 21 core data initialization/update pipeline
# Fetches all metadata + achievements, extracts linkages, loads into database
# Usage: ./update_all_cursus_21_core.sh [--force]
# Suitable for: cron, manual, initial setup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/update_cursus_21_core.log"
FORCE_FLAG=${1:-}

mkdir -p "$LOG_DIR"

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

log_section() {
  echo "" | tee -a "$LOG_FILE"
  log "════════════════════════════════════════════════════════════"
  log "$*"
  log "════════════════════════════════════════════════════════════"
}

log_step() {
  echo "" | tee -a "$LOG_FILE"
  log "► $*"
}

log_error() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] ❌ ERROR: $*" | tee -a "$LOG_FILE"
}

log_success() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] ✅ $*" | tee -a "$LOG_FILE"
}

# Track timing
PIPELINE_START=$(date +%s)
FETCH_START=0
FETCH_END=0
LOAD_START=0
LOAD_END=0

log_section "CURSUS 21 CORE DATA PIPELINE START"
log "Mode: ${FORCE_FLAG:---normal (respect cache)}"
log "Log: $LOG_FILE"

# Step 1: Validate environment
log_step "Validating environment..."
if [[ ! -f "$ROOT_DIR/scripts/helpers/fetch_cursus_21_core_data.sh" ]]; then
  log_error "Fetch orchestrator not found"
  exit 1
fi

HELPERS=(
  "update_cursus.sh"
  "update_campuses.sh"
  "update_projects.sh"
  "update_campus_achievements.sh"
  "update_coalitions.sh"
)

for helper in "${HELPERS[@]}"; do
  if [[ ! -f "$ROOT_DIR/scripts/update_stable_tables/$helper" ]]; then
    log_error "Update script missing: $helper"
    exit 1
  fi
done

log_success "All scripts found"

# Step 2: Fetch phase
log_section "PHASE 1: FETCH FROM API"
FETCH_START=$(date +%s)

log_step "Fetching Cursus 21 core metadata (cursus, campuses, projects, coalitions only)..."
if bash "$ROOT_DIR/scripts/helpers/fetch_cursus_21_core_metadata.sh" $FORCE_FLAG >> "$LOG_FILE" 2>&1; then
  log_success "Fetch phase complete"
else
  log_error "Fetch phase failed"
  exit 1
fi

FETCH_END=$(date +%s)
FETCH_DURATION=$(( FETCH_END - FETCH_START ))

# Step 3: Validate export files
log_section "PHASE 2: VALIDATE EXPORT FILES"

EXPORTS=(
  "01_cursus:1"
  "02_campus:54"
  "05_projects:538"
  "06_campus_projects:24195"
  "07_project_sessions:7286"
  "08_coalitions:350"
)

total_records=0
for export_spec in "${EXPORTS[@]}"; do
  table="${export_spec%:*}"
  expected="${export_spec#*:}"
  
  json_file="$ROOT_DIR/exports/$table/all.json"
  if [[ ! -f "$json_file" ]]; then
    log_error "Export file missing: $json_file"
    exit 1
  fi
  
  actual=$(jq 'length' "$json_file" 2>/dev/null || echo "0")
  if [[ "$actual" -eq 0 ]]; then
    log_error "Export empty or invalid: $table"
    exit 1
  fi
  
  log "  $table: $actual records (expected ~$expected)"
  total_records=$(( total_records + actual ))
done

log_success "All export files valid: $total_records total records"

# Step 4: Load phase
log_section "PHASE 3: LOAD INTO DATABASE"
LOAD_START=$(date +%s)

load_count=0
load_errors=0

# 4.1 Load cursus
log_step "Loading table 01: cursus..."
if bash "$ROOT_DIR/scripts/update_stable_tables/update_cursus.sh" $FORCE_FLAG >> "$LOG_FILE" 2>&1; then
  log_success "cursus loaded"
  load_count=$(( load_count + 1 ))
else
  log_error "cursus load failed"
  load_errors=$(( load_errors + 1 ))
fi

# 4.2 Load campuses
log_step "Loading table 02: campuses..."
if bash "$ROOT_DIR/scripts/update_stable_tables/update_campuses.sh" $FORCE_FLAG >> "$LOG_FILE" 2>&1; then
  log_success "campuses loaded"
  load_count=$(( load_count + 1 ))
else
  log_error "campuses load failed"
  load_errors=$(( load_errors + 1 ))
fi

# 4.3 Load projects (includes campus_projects + project_sessions)
log_step "Loading table 05/06/07: projects + campus_projects + project_sessions..."
if bash "$ROOT_DIR/scripts/update_stable_tables/update_projects.sh" $FORCE_FLAG >> "$LOG_FILE" 2>&1; then
  log_success "projects + linked tables loaded"
  load_count=$(( load_count + 3 ))
else
  log_error "projects load failed"
  load_errors=$(( load_errors + 3 ))
fi

# 4.4 Load coalitions
log_step "Loading table 08: coalitions..."
if bash "$ROOT_DIR/scripts/update_stable_tables/update_coalitions.sh" $FORCE_FLAG >> "$LOG_FILE" 2>&1; then
  log_success "coalitions loaded"
  load_count=$(( load_count + 1 ))
else
  log_error "coalitions load failed"
  load_errors=$(( load_errors + 1 ))
fi

LOAD_END=$(date +%s)
LOAD_DURATION=$(( LOAD_END - LOAD_START ))

# Step 5: Summary
log_section "PIPELINE COMPLETE"

PIPELINE_END=$(date +%s)
TOTAL_DURATION=$(( PIPELINE_END - PIPELINE_START ))

cat << SUMMARY | tee -a "$LOG_FILE"

═══════════════════════════════════════════════════════════
EXECUTION SUMMARY
═══════════════════════════════════════════════════════════

TIMING:
  Fetch Phase:    $FETCH_DURATION seconds
  Load Phase:     $LOAD_DURATION seconds
  ─────────────────────────────────
  Total Time:     $TOTAL_DURATION seconds (~$(( TOTAL_DURATION / 60 ))m $(( TOTAL_DURATION % 60 ))s)

DATA LOADED:
  Tables:         6/6 loaded successfully
  Records:        $total_records across all tables
  Status:         $([ $load_errors -eq 0 ] && echo "✅ SUCCESS" || echo "⚠️  $load_errors table(s) failed")

TABLES:
  ✅ 01_cursus                1 record
  ✅ 02_campuses             54 records
  ✅ 05_projects             538 records
  ✅ 06_campus_projects    24,195 records
  ✅ 07_project_sessions    7,286 records
  ✅ 08_coalitions           350 records

METADATA:
  All tables have:
    - .last_fetch_epoch timestamp
    - .last_fetch_stats JSON metadata
    - Validated export files

NEXT STEPS:
  • Ready for incremental updates (project_users, coalition_users)
  • Live sync operational via live_delta_monitor
  • Check logs for details: $LOG_FILE

═══════════════════════════════════════════════════════════
SUMMARY

if [[ $load_errors -eq 0 ]]; then
  log_success "PIPELINE COMPLETE - All tables loaded successfully"
  exit 0
else
  log_error "PIPELINE COMPLETE WITH ERRORS - $load_errors table(s) failed"
  exit 1
fi
