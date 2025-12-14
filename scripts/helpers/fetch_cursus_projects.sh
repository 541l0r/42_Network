#!/usr/bin/env bash
set -euo pipefail

# Fetch projects for a given cursus into exports/projects/page_*.json and merge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORT_DIR="$ROOT_DIR/exports/05_projects"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"

CURSUS_ID=${CURSUS_ID:-21}
PER_PAGE=${PER_PAGE:-100}
SLEEP_BETWEEN_CALLS=${SLEEP_BETWEEN_CALLS:-1}
MIN_FETCH_AGE_SECONDS=${MIN_FETCH_AGE_SECONDS:-3600}

# Usage: fetch_cursus_projects.sh [seconds] | --force
if [[ "${1:-}" == "--force" ]]; then
  MIN_FETCH_AGE_SECONDS=0
else
  MIN_FETCH_AGE_SECONDS=${1:-${MIN_FETCH_AGE_SECONDS:-86400}}
fi

mkdir -p "$EXPORT_DIR"

# Skip if fetched recently
if [[ -f "$STAMP_FILE" ]]; then
  last_run=$(cat "$STAMP_FILE")
  now=$(date +%s)
  age=$(( now - last_run ))
  if (( age < MIN_FETCH_AGE_SECONDS )); then
    echo "Skipping projects fetch: last run $age seconds ago (< ${MIN_FETCH_AGE_SECONDS}s)."
    exit 3
  fi
fi

rm -f "$EXPORT_DIR"/page_*.json

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting fetch: per_page=$PER_PAGE"

page=1
total_items=0
total_kb=0
while true; do
  outfile="$EXPORT_DIR/page_${page}.json"
  echo "Fetching cursus ${CURSUS_ID} projects page ${page}..."
  query="per_page=${PER_PAGE}&page=${page}"
  "$ROOT_DIR/scripts/token_manager.sh" call-export "/v2/cursus/${CURSUS_ID}/projects?${query}" "$outfile" >/dev/null
  sleep "$SLEEP_BETWEEN_CALLS"

  if [[ ! -s "$outfile" ]] || ! jq -e 'type=="array"' "$outfile" >/dev/null 2>&1; then
    echo "  -> non-array or empty response, stopping."
    [[ -s "$outfile" ]] && echo "     Payload kept at $outfile"
    rm -f "$outfile"
    break
  fi

  count=$(jq 'length' "$outfile")
  page_kb=$(du -k "$outfile" | cut -f1)
  total_kb=$(( total_kb + page_kb ))
  total_items=$(( total_items + count ))
  echo "  -> $count items"
  if [[ "$count" -lt $PER_PAGE ]]; then
    echo "Last page reached."
    break
  fi
  page=$((page + 1))
  sleep 1
done

echo "Merging pages into $EXPORT_DIR/raw_all.json"
if ls "$EXPORT_DIR"/page_*.json >/dev/null 2>&1; then
  jq -s 'add' "$EXPORT_DIR"/page_*.json > "$EXPORT_DIR/raw_all.json"
else
  echo "[]" > "$EXPORT_DIR/raw_all.json"
fi
rm -f "$EXPORT_DIR"/page_*.json
merged_count=$(jq 'length' "$EXPORT_DIR/raw_all.json")
now_epoch=$(date +%s)
echo "$now_epoch" > "$STAMP_FILE"
cat > "$METRIC_FILE" <<EOF
timestamp=$now_epoch
cursus_id=$CURSUS_ID
pages=$page
items_merged=$merged_count
downloaded_kB=$total_kb
EOF

echo "Done. Merged count: $merged_count"
