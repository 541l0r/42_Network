#!/usr/bin/env bash
set -euo pipefail

# Fetch all campuses from the 42 API (paginated) into exports/02_campus/all.json.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORT_DIR="$ROOT_DIR/exports/02_campus"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"
SLEEP_BETWEEN_CALLS=${SLEEP_BETWEEN_CALLS:-0.6}
MIN_FETCH_AGE_SECONDS=${MIN_FETCH_AGE_SECONDS:-3600}

# Usage: fetch_campuses.sh [seconds] | --force
if [[ "${1:-}" == "--force" ]]; then
  MIN_FETCH_AGE_SECONDS=0
else
  MIN_FETCH_AGE_SECONDS=${1:-${MIN_FETCH_AGE_SECONDS}}
fi

mkdir -p "$EXPORT_DIR"

# Skip if fetched recently
if [[ -f "$STAMP_FILE" ]]; then
  last_run=$(cat "$STAMP_FILE")
  now=$(date +%s)
  age=$(( now - last_run ))
  if (( age < MIN_FETCH_AGE_SECONDS )); then
    echo "Skipping campuses fetch: last run $age seconds ago (< ${MIN_FETCH_AGE_SECONDS}s)."
    exit 3
  fi
fi

rm -f "$EXPORT_DIR"/page_*.json
page=1
raw_total=0
filtered_total=0
total_kb=0
while true; do
  outfile="$EXPORT_DIR/page_${page}.json"
  tmpfile="${outfile}.tmp"
  echo "Fetching campuses page $page..."
  # Only active, public campuses (users_count filtered locally; API no longer supports that filter).
  query="filter%5Bactive%5D=true&filter%5Bpublic%5D=true&per_page=100&page=${page}"
  "$ROOT_DIR/scripts/token_manager.sh" call-export "/v2/campus?${query}" "$tmpfile" >/dev/null
  sleep "$SLEEP_BETWEEN_CALLS"

  if ! jq -e 'type=="array"' "$tmpfile" >/dev/null 2>&1; then
    echo "  -> unexpected response (not an array). Leaving payload at $tmpfile"
    exit 1
  fi

  raw_count=$(jq 'length' "$tmpfile")
  raw_total=$(( raw_total + raw_count ))
  jq '[.[] | select((.users_count // 0) > 1)]' "$tmpfile" > "$outfile"
  filtered_count=$(jq 'length' "$outfile")
  filtered_total=$(( filtered_total + filtered_count ))
  rm -f "$tmpfile"

  page_kb=$(du -k "$outfile" | cut -f1)
  total_kb=$(( total_kb + page_kb ))
  echo "  -> $filtered_count items saved to $outfile (raw: $raw_count)"
  if [[ "$raw_count" -lt 100 ]]; then
    echo "Last page reached."
    break
  fi
  page=$((page + 1))
  sleep 1
done

echo "Merging pages into $EXPORT_DIR/all.json"
jq -s 'add' "$EXPORT_DIR"/page_*.json > "$EXPORT_DIR/all.json"
rm -f "$EXPORT_DIR"/page_*.json
merged_count=$(jq 'length' "$EXPORT_DIR/all.json")
echo "Done. Merged count: $merged_count"

now_epoch=$(date +%s)
echo "$now_epoch" > "$STAMP_FILE"
cat > "$METRIC_FILE" <<EOF
timestamp=$now_epoch
pages=$page
items_raw=$raw_total
items_filtered=$filtered_total
items_merged=$merged_count
downloaded_kB=$total_kb
EOF
