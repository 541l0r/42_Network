#!/usr/bin/env bash
set -euo pipefail

# Fetch all coalitions_users (user memberships) from the 42 API into exports/09_coalitions_users/all.json.
# This fetches per-coalition user lists to capture all memberships + scores/ranks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORT_DIR="$ROOT_DIR/exports/09_coalitions_users"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/fetch_coalitions_users.log"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"
SLEEP_BETWEEN_CALLS=${SLEEP_BETWEEN_CALLS:-0.6}
MIN_FETCH_AGE_SECONDS=${MIN_FETCH_AGE_SECONDS:-3600}

mkdir -p "$LOG_DIR"

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

# Usage: fetch_coalitions_users.sh [seconds] | --force
if [[ "${1:-}" == "--force" ]]; then
  MIN_FETCH_AGE_SECONDS=0
else
  MIN_FETCH_AGE_SECONDS=${1:-${MIN_FETCH_AGE_SECONDS}}
fi

mkdir -p "$EXPORT_DIR"

log "====== FETCH COALITIONS_USERS START ======"
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

rm -f "$EXPORT_DIR"/coalition_*.json

# First, get list of all coalitions
coalitions_export="$ROOT_DIR/exports/01_coalitions/all.json"
if [[ ! -f "$coalitions_export" ]]; then
  log "ERROR: Coalitions data not found at $coalitions_export"
  exit 1
fi

raw_total=0
filtered_total=0
total_kb=0
api_hits=0
coalition_count=0

log "Starting fetch: per_page=100"

log "Reading coalition list..."
coalition_list_tmp=$(mktemp)
jq -r '.[].id' "$coalitions_export" > "$coalition_list_tmp"
total_coalitions=$(wc -l < "$coalition_list_tmp")
log "Found $total_coalitions coalitions to fetch members for"

# For each coalition, fetch its members
while IFS= read -r coalition_id; do
  coalition_count=$(( coalition_count + 1 ))
  outfile="$EXPORT_DIR/coalition_${coalition_id}.json"
  tmpfile="${outfile}.tmp"
  
  page=1
  coalition_raw_total=0
  coalition_start=$(date +%s%3N)
  
  while true; do
    page_tmpfile="${tmpfile}_page_${page}.json"
    query="per_page=100&page=${page}"
    
    api_hits=$(( api_hits + 1 ))
    "$ROOT_DIR/scripts/token_manager.sh" call-export "/v2/coalitions/${coalition_id}/users?filter%5Bkind%5D=student&filter%5Balumni%3F%5D=false&${query}" "$page_tmpfile" >/dev/null 2>&1 || {
      log "  Coalition $coalition_count/$total_coalitions (ID $coalition_id): SKIPPED (not accessible)"
      rm -f "$page_tmpfile" "$tmpfile"*
      break
    }
    sleep "$SLEEP_BETWEEN_CALLS"

    if ! jq -e 'type=="array"' "$page_tmpfile" >/dev/null 2>&1; then
      log "  Coalition $coalition_count/$total_coalitions (ID $coalition_id): SKIPPED (invalid response)"
      rm -f "$page_tmpfile" "$tmpfile"*
      break
    fi

    count=$(jq '. | length' "$page_tmpfile")
    coalition_raw_total=$(( coalition_raw_total + count ))
    size=$(wc -c < "$page_tmpfile")
    size_kb=$(( size / 1024 ))
    total_kb=$(( total_kb + size_kb ))

    if (( count < 100 )); then
      # Merge pages for this coalition
      if (( page == 1 )); then
        mv "$page_tmpfile" "$outfile"
      else
        jq -s 'add' "${tmpfile}"_page_*.json > "$outfile"
        rm -f "${tmpfile}"_page_*.json
      fi
      break
    fi

    page=$(( page + 1 ))
  done

  coalition_end=$(date +%s%3N)
  coalition_duration=$(( coalition_end - coalition_start ))
  raw_total=$(( raw_total + coalition_raw_total ))
  filtered_total=$(( filtered_total + coalition_raw_total ))
  
  if (( coalition_raw_total > 0 )); then
    log "  Coalition $coalition_count/$total_coalitions (ID $coalition_id): $coalition_raw_total members, ${coalition_duration}ms"
  fi

done < "$coalition_list_tmp"
rm -f "$coalition_list_tmp"

log "Total: $raw_total user memberships in ${total_kb}KB from $coalition_count coalitions, $api_hits API hits"

# Merge all coalition files into all.json
merged_json="$EXPORT_DIR/all.json"
jq -s 'add' "$EXPORT_DIR"/coalition_*.json > "$merged_json" 2>/dev/null || {
  echo "[] " > "$merged_json"
}
log "Exported to $merged_json"

# Record fetch timestamp
date +%s > "$STAMP_FILE"

# Record stats
echo "raw=$raw_total filtered=$filtered_total kb=$total_kb coalitions=$coalition_count api_hits=$api_hits" > "$METRIC_FILE"

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
log "====== FETCH COALITIONS_USERS COMPLETE (${DURATION}s) ======"
log ""

exit 0
