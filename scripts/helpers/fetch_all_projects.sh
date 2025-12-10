#!/usr/bin/env bash
set -euo pipefail

# Fetch all projects from the 42 API (paginated) into exports/projects/page_*.json and merge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORT_DIR="$ROOT_DIR/exports/projects"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"

# Usage: fetch_all_projects.sh [seconds] | --force | --force-full
MIN_FETCH_AGE_SECONDS=${MIN_FETCH_AGE_SECONDS:-86400}
SINCE=""
FORCE_FULL=0
if [[ "${1:-}" == "--force-full" ]]; then
  MIN_FETCH_AGE_SECONDS=0
  FORCE_FULL=1
  shift
elif [[ "${1:-}" == "--force" ]]; then
  MIN_FETCH_AGE_SECONDS=0
  shift
fi
if [[ $# -ge 1 ]]; then
  MIN_FETCH_AGE_SECONDS=$1
fi

mkdir -p "$EXPORT_DIR"

# Determine SINCE from stamp (epoch or ISO) unless forced full
if (( FORCE_FULL == 0 )) && [[ -f "$STAMP_FILE" ]]; then
  stamp_val=$(cat "$STAMP_FILE")
  if [[ "$stamp_val" =~ ^[0-9]+$ ]]; then
    last_epoch="$stamp_val"
  else
    last_epoch=$(date -d "$stamp_val" +%s 2>/dev/null || echo "")
  fi
  if [[ -n "${last_epoch:-}" ]]; then
    now=$(date +%s)
    age=$(( now - last_epoch ))
    if (( age < MIN_FETCH_AGE_SECONDS )); then
      echo "Skipping projects fetch: last run $age seconds ago (< ${MIN_FETCH_AGE_SECONDS}s)."
      exit 0
    fi
    SINCE=$(date -u -d "@$last_epoch" +"%Y-%m-%dT%H:%M:%SZ")
  fi
fi
if [[ -z "$SINCE" ]]; then
  SINCE="1970-01-01T00:00:00Z"
fi
UNTIL=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

PER_PAGE=${PER_PAGE:-100}
MAX_PAGES=${MAX_PAGES:-}
EXTRA_QUERY="${EXTRA_QUERY:-}"
BASE_ENDPOINT="/v2/projects"

page=1
total_kb=0
while true; do
  if [[ -n "$MAX_PAGES" && "$page" -gt "$MAX_PAGES" ]]; then
    echo "Max pages limit reached ($MAX_PAGES); stopping."
    break
  fi

  outfile="$EXPORT_DIR/page_${page}.json"
  echo "Fetching projects page $page..."
  query="sort=updated_at&range%5Bupdated_at%5D=${SINCE},${UNTIL}&per_page=${PER_PAGE}&page=${page}"
  if [[ -n "$EXTRA_QUERY" ]]; then
    query="${query}&${EXTRA_QUERY}"
  fi
  "$ROOT_DIR/scripts/token_manager.sh" call-export "${BASE_ENDPOINT}?${query}" "$outfile" >/dev/null
  if [[ ! -s "$outfile" ]]; then
    echo "  -> empty response, stopping."
    rm -f "$outfile"
    break
  fi
  if ! jq -e 'type == "array"' "$outfile" >/dev/null 2>&1; then
    echo "  -> non-array response, stopping. Contents:"
    cat "$outfile"
    rm -f "$outfile"
    break
  fi
  count=$(jq 'length' "$outfile")
  page_kb=$(du -k "$outfile" | cut -f1)
  total_kb=$(( total_kb + page_kb ))
  echo "  -> $count items saved to $outfile"
  if [[ "$count" -lt $PER_PAGE ]]; then
    echo "Last page reached."
    break
  fi
  page=$((page + 1))
  sleep 1
done

echo "Merging pages into $EXPORT_DIR/all.json"
if ls "$EXPORT_DIR"/page_*.json >/dev/null 2>&1; then
  jq -s 'add' "$EXPORT_DIR"/page_*.json > "$EXPORT_DIR/all.json"
else
  echo "[]" > "$EXPORT_DIR/all.json"
fi
merged_count=$(jq 'length' "$EXPORT_DIR/all.json")
date +%s > "$STAMP_FILE"
echo "$UNTIL" > "$EXPORT_DIR/.last_updated_at"
cat > "$METRIC_FILE" <<EOF
timestamp=$(cat "$STAMP_FILE")
pages=$page
items_merged=$merged_count
since=$SINCE
until=$UNTIL
downloaded_kB=$total_kb
EOF
echo "Done. Merged count: $merged_count"
