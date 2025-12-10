#!/usr/bin/env bash
set -euo pipefail

# Fetch all achievements from the 42 API (paginated) into exports/achievements/page_*.json
# Skips fetch if a successful run happened recently.
# Requires: token_manager.sh with valid tokens (.env at /srv/42_Network/.env) and jq installed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORT_DIR="$ROOT_DIR/exports/achievements"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"

# Minimum age (seconds) before re-fetch; default 24h unless --force.
# Usage:
#   fetch_all_achievements.sh            # uses default 86400s guard
#   fetch_all_achievements.sh 3600       # 1h guard
#   fetch_all_achievements.sh --force    # bypass guard
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
    echo "Skipping fetch: last successful run $age seconds ago (< ${MIN_FETCH_AGE_SECONDS}s)."
    exit 0
  fi
fi

page=1
total_items=0
bytes_downloaded=0
while true; do
  outfile="$EXPORT_DIR/page_${page}.json"
  echo "Fetching page $page..."
  "$ROOT_DIR/scripts/token_manager.sh" call-export "/v2/achievements?per_page=100&page=${page}" "$outfile" >/dev/null
  count=$(jq 'length' "$outfile")
  size_bytes=$(stat -c%s "$outfile")
  bytes_downloaded=$((bytes_downloaded + size_bytes))
  echo "  -> $count items saved to $outfile"
  total_items=$((total_items + count))
  if [[ "$count" -lt 100 ]]; then
    echo "Last page reached."
    break
  fi
  page=$((page + 1))
  sleep 1  # respect API rate limits
done
echo "Merging pages into $EXPORT_DIR/all.json"
jq -s 'add' "$EXPORT_DIR"/page_*.json > "$EXPORT_DIR/all.json"
merged_count=$(jq 'length' "$EXPORT_DIR/all.json")
date +%s > "$STAMP_FILE"
cat > "$METRIC_FILE" <<EOF
timestamp=$(cat "$STAMP_FILE")
pages=$page
total_items=$total_items
items_merged=$merged_count
bytes_downloaded=$bytes_downloaded
EOF

echo "Done. Stats:"
echo "  pages fetched: $page"
echo "  items fetched (sum of pages): $total_items"
echo "  merged count: $merged_count"
echo "  bytes downloaded: $bytes_downloaded"
