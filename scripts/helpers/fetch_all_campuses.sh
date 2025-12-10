#!/usr/bin/env bash
set -euo pipefail

# Fetch all campuses from the 42 API (paginated) into exports/campus/page_*.json and merge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORT_DIR="$ROOT_DIR/exports/campus"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"

# Usage: fetch_all_campuses.sh [seconds] | --force
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
    echo "Skipping campuses fetch: last run $age seconds ago (< ${MIN_FETCH_AGE_SECONDS}s)."
    exit 0
  fi
fi

page=1
total_kb=0
while true; do
  outfile="$EXPORT_DIR/page_${page}.json"
  echo "Fetching campuses page $page..."
  # Only active, public campuses with at least 2 users.
  query="filter%5Bactive%5D=true&filter%5Bpublic%5D=true&filter%5Busers_count%5D=gt:1&per_page=100&page=${page}"
  "$ROOT_DIR/scripts/token_manager.sh" call-export "/v2/campus?${query}" "$outfile" >/dev/null
  count=$(jq 'length' "$outfile")
   # add size for this page
  page_kb=$(du -k "$outfile" | cut -f1)
  total_kb=$(( total_kb + page_kb ))
  echo "  -> $count items saved to $outfile"
  if [[ "$count" -lt 100 ]]; then
    echo "Last page reached."
    break
  fi
  page=$((page + 1))
  sleep 1
done

echo "Merging pages into $EXPORT_DIR/all.json"
jq -s 'add' "$EXPORT_DIR"/page_*.json > "$EXPORT_DIR/all.json"
merged_count=$(jq 'length' "$EXPORT_DIR/all.json")
date +%s > "$STAMP_FILE"
cat > "$METRIC_FILE" <<EOF
timestamp=$(cat "$STAMP_FILE")
pages=$page
items_merged=$merged_count
downloaded_kB=$total_kb
EOF
echo "Done. Merged count: $merged_count"
