#!/usr/bin/env bash
set -euo pipefail

# Fetch project_users for a campus filtered by cursus 21 with detailed logging.
# Usage: CAMPUS_ID=12 [CURSUS_ID=21] ./fetch_projects_users_by_campus_cursus.sh [--force]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CAMPUS_ID=${CAMPUS_ID:-}
CURSUS_ID=${CURSUS_ID:-21}
EXPORT_DIR="$ROOT_DIR/exports/06_project_users/cursus_${CURSUS_ID}/campus_${CAMPUS_ID}"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/fetch_project_users_campus_cursus.log"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"
PER_PAGE=${PER_PAGE:-100}
SLEEP_BETWEEN_CALLS=${SLEEP_BETWEEN_CALLS:-0.6}
MIN_FETCH_AGE_SECONDS=${MIN_FETCH_AGE_SECONDS:-3600}

mkdir -p "$LOG_DIR" "$EXPORT_DIR"

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

if [[ -z "$CAMPUS_ID" ]]; then
  log "ERROR: Set CAMPUS_ID (e.g., CAMPUS_ID=12) before running."
  exit 1
fi

# Parse --force flag
FORCE_FETCH=0
for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE_FETCH=1
done
(( FORCE_FETCH )) && MIN_FETCH_AGE_SECONDS=0

# Skip if fetched recently
if [[ -f "$STAMP_FILE" ]] && (( ! FORCE_FETCH )); then
  last_run=$(cat "$STAMP_FILE")
  now=$(date +%s)
  age=$(( now - last_run ))
  if (( age < MIN_FETCH_AGE_SECONDS )); then
    log "SKIP: Campus $CAMPUS_ID: last fetch was $age seconds ago (threshold: ${MIN_FETCH_AGE_SECONDS}s)"
    exit 3
  fi
fi

log "====== FETCH PROJECT_USERS: CAMPUS $CAMPUS_ID, CURSUS $CURSUS_ID START ======"
START_TIME=$(date +%s)

rm -f "$EXPORT_DIR"/page_*.json

page=1
raw_total=0
total_kb=0
api_hits=0

while true; do
  outfile="$EXPORT_DIR/page_${page}.json"
  tmpfile="${outfile}.tmp"
  
  # Filter by campus + cursus + kind=student + alumni?=false
  query="filter%5Bkind%5D=student&filter%5Bcampus_id%5D=${CAMPUS_ID}&filter%5Bcursus_id%5D=${CURSUS_ID}&filter%5Balumni%3F%5D=false&per_page=${PER_PAGE}&page=${page}"
  
  # Optional: incremental sync by updated_at
  if [[ -n "${UPDATED_RANGE:-}" ]]; then
    ENCODED_RANGE=$(python3 -c "import urllib.parse; print(urllib.parse.quote_plus('${UPDATED_RANGE}'))")
    query="${query}&range%5Bupdated_at%5D=${ENCODED_RANGE}"
  fi
  
  log "Fetching page $page (campus $CAMPUS_ID, cursus $CURSUS_ID)..."
  
  page_start=$(date +%s%3N)
  "$ROOT_DIR/scripts/token_manager.sh" call-export "/v2/projects_users?${query}" "$tmpfile" >/dev/null
  page_end=$(date +%s%3N)
  page_duration=$(( page_end - page_start ))
  api_hits=$(( api_hits + 1 ))
  
  sleep "$SLEEP_BETWEEN_CALLS"

  if ! jq -e 'type=="array"' "$tmpfile" >/dev/null 2>&1; then
    log "ERROR: Page $page response not an array (campus $CAMPUS_ID)"
    exit 1
  fi

  count=$(jq '. | length' "$tmpfile")
  raw_total=$(( raw_total + count ))
  size=$(wc -c < "$tmpfile")
  size_kb=$(( size / 1024 ))
  total_kb=$(( total_kb + size_kb ))
  
  log "  Page $page: $count records, ${size_kb}KB, ${page_duration}ms"

  if (( count < PER_PAGE )); then
    mv "$tmpfile" "$outfile"
    break
  fi

  mv "$tmpfile" "$outfile"
  page=$(( page + 1 ))
done

log "Total: $raw_total project_users (non-alumni) in ${total_kb}KB across $page pages, $api_hits API hits"

# Merge pages
merged_json="$EXPORT_DIR/all.json"
jq -s 'add' "$EXPORT_DIR"/page_*.json > "$merged_json"
log "Exported to $merged_json"

# Record fetch timestamp
date +%s > "$STAMP_FILE"

# Record stats
echo "raw=$raw_total kb=$total_kb pages=$page api_hits=$api_hits campus_id=$CAMPUS_ID cursus_id=$CURSUS_ID filter_alumni=false" > "$METRIC_FILE"

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
log "====== FETCH PROJECT_USERS COMPLETE (${DURATION}s, $api_hits hits) ======"
log ""

exit 0
