#!/usr/bin/env bash
set -euo pipefail

# Fetch achievements for a campus with detailed logging.
# Usage: CAMPUS_ID=12 ./fetch_campus_achievements.sh [--force]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CAMPUS_ID=${CAMPUS_ID:-}
EXPORT_DIR="$ROOT_DIR/exports/04_campus_achievements"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/fetch_campus_achievements.log"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"
PER_PAGE=${PER_PAGE:-100}
SLEEP_BETWEEN_CALLS=${SLEEP_BETWEEN_CALLS:-1}
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
    log "SKIP: Campus $CAMPUS_ID achievements: last fetch was $age seconds ago (threshold: ${MIN_FETCH_AGE_SECONDS}s)"
    exit 3
  fi
fi

log "====== FETCH CAMPUS ACHIEVEMENTS: CAMPUS $CAMPUS_ID START ======"
log "Starting fetch: per_page=$PER_PAGE"
START_TIME=$(date +%s)

mkdir -p "$EXPORT_DIR/campus_${CAMPUS_ID}"
rm -f "$EXPORT_DIR/campus_${CAMPUS_ID}"/page_*.json

page=1
raw_total=0
total_kb=0
api_hits=0

while true; do
  outfile="$EXPORT_DIR/campus_${CAMPUS_ID}/page_${page}.json"
  tmpfile="${outfile}.tmp"
  
  log "Fetching achievements for campus $CAMPUS_ID, page $page..."
  
  page_start=$(date +%s%3N)
  "$ROOT_DIR/scripts/token_manager.sh" call-export "/v2/campus/${CAMPUS_ID}/achievements?per_page=${PER_PAGE}&page=${page}" "$tmpfile" >/dev/null
  page_end=$(date +%s%3N)
  page_duration=$(( page_end - page_start ))
  api_hits=$(( api_hits + 1 ))
  
  sleep "$SLEEP_BETWEEN_CALLS"

  if ! jq -e 'type=="array"' "$tmpfile" >/dev/null 2>&1; then
    log "ERROR: Page $page response not an array"
    exit 1
  fi

  count=$(jq '. | length' "$tmpfile")
  raw_total=$(( raw_total + count ))
  size=$(wc -c < "$tmpfile")
  size_kb=$(( size / 1024 ))
  total_kb=$(( total_kb + size_kb ))
  
  log "  Page $page: $count achievements, ${size_kb}KB, ${page_duration}ms"

  if (( count < PER_PAGE )); then
    mv "$tmpfile" "$outfile"
    break
  fi

  mv "$tmpfile" "$outfile"
  page=$(( page + 1 ))
done

log "Total: $raw_total achievements in ${total_kb}KB across $page pages, $api_hits API hits"

# Merge pages
merged_json="$EXPORT_DIR/campus_${CAMPUS_ID}/all.json"
# Add campus_id to each achievement record from this campus
jq -s --arg cid "$CAMPUS_ID" '[.[] | .[] + {campus_id: ($cid | tonumber)}]' "$EXPORT_DIR/campus_${CAMPUS_ID}"/page_*.json > "$merged_json"
log "Exported to $merged_json (with campus_id=$CAMPUS_ID embedded)"

# Record fetch timestamp
date +%s > "$STAMP_FILE"

# Record stats
echo "raw=$raw_total kb=$total_kb pages=$page api_hits=$api_hits campus_id=$CAMPUS_ID" > "$METRIC_FILE"

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
log "====== FETCH CAMPUS ACHIEVEMENTS COMPLETE (${DURATION}s, $api_hits hits) ======"
log ""

exit 0
