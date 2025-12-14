#!/usr/bin/env bash
set -euo pipefail

# Fetch all coalitions from the 42 API (paginated) into exports/08_coalitions/all.json.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORT_DIR="$ROOT_DIR/exports/08_coalitions"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/fetch_coalitions.log"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"
SLEEP_BETWEEN_CALLS=${SLEEP_BETWEEN_CALLS:-1}
MIN_FETCH_AGE_SECONDS=${MIN_FETCH_AGE_SECONDS:-3600}

mkdir -p "$LOG_DIR"

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

# Usage: fetch_coalitions.sh [seconds] | --force
if [[ "${1:-}" == "--force" ]]; then
  MIN_FETCH_AGE_SECONDS=0
else
  MIN_FETCH_AGE_SECONDS=${1:-${MIN_FETCH_AGE_SECONDS}}
fi

mkdir -p "$EXPORT_DIR"

log "====== FETCH COALITIONS START ======"
START_TIME=$(date +%s)

# Skip if fetched recently
if [[ -f "$STAMP_FILE" ]]; then
  last_run=$(cat "$STAMP_FILE")
  now=$(date +%s)
  age=$(( now - last_run ))
  if (( age < MIN_FETCH_AGE_SECONDS )); then
    log "SKIP: Last fetch was $age seconds ago (threshold: ${MIN_FETCH_AGE_SECONDS}s)"
    exit 3
  fi
fi

rm -f "$EXPORT_DIR"/page_*.json

log "Starting fetch: per_page=100"

page=1
raw_total=0
filtered_total=0
total_kb=0
api_hits=0

while true; do
  outfile="$EXPORT_DIR/page_${page}.json"
  tmpfile="${outfile}.tmp"
  log "Fetching page $page..."
  query="per_page=100&page=${page}"
  
  page_start=$(date +%s%3N)
  "$ROOT_DIR/scripts/token_manager.sh" call-export "/v2/coalitions?${query}" "$tmpfile" >/dev/null
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
  filtered_total=$(( filtered_total + count ))
  size=$(wc -c < "$tmpfile")
  size_kb=$(( size / 1024 ))
  total_kb=$(( total_kb + size_kb ))
  
  log "  Page $page: $count records, ${size_kb}KB, ${page_duration}ms"

  if (( count < 100 )); then
    mv "$tmpfile" "$outfile"
    break
  fi

  mv "$tmpfile" "$outfile"
  page=$(( page + 1 ))
done

log "Total: $raw_total coalitions in ${total_kb}KB across $page pages, $api_hits API hits"

# Merge pages into all.json
merged_json="$EXPORT_DIR/all.json"
jq -s 'add' "$EXPORT_DIR"/page_*.json > "$merged_json"
log "Exported to $merged_json"

# Clean up page files after successful merge
rm -f "$EXPORT_DIR"/page_*.json
log "Cleaned up page files"

# Record fetch timestamp
EPOCH=$(date +%s)
date +%s > "$STAMP_FILE"

# Record stats
cat > "$METRIC_FILE" << STATS
{
  "type": "coalitions",
  "count": $raw_total,
  "pages": $page,
  "method": "fetch_from_api",
  "source": "/v2/coalitions",
  "timestamp": $EPOCH
}
STATS

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
log "====== FETCH COALITIONS COMPLETE (${DURATION}s) ======"
log ""

exit 0
