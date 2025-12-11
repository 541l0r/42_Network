#!/usr/bin/env bash
set -euo pipefail

# Fetch achievements per campus and merge into a single file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORT_DIR="$ROOT_DIR/exports/04_campus_achievements"
CAMPUSES_JSON="$ROOT_DIR/exports/02_campus/all.json"
CAMPUS_HELPER="$ROOT_DIR/scripts/helpers/fetch_campuses.sh"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"
RAW_JSON="$EXPORT_DIR/raw_all.json"
LINKS_JSON="$EXPORT_DIR/all.json"
MIN_FETCH_AGE_SECONDS=${MIN_FETCH_AGE_SECONDS:-3600}
PER_PAGE=${PER_PAGE:-100}
SLEEP_BETWEEN_CAMPUSES=${SLEEP_BETWEEN_CAMPUSES:-0.6}
SLEEP_BETWEEN_CALLS=${SLEEP_BETWEEN_CALLS:-0.6}

if [[ "${1:-}" == "--force" ]]; then
  MIN_FETCH_AGE_SECONDS=0
fi

mkdir -p "$EXPORT_DIR"
mkdir -p "$(dirname "$CAMPUSES_JSON")"

# Guard: skip only if we have recent data on disk
if [[ -f "$STAMP_FILE" && -s "$RAW_JSON" ]]; then
  last_run=$(cat "$STAMP_FILE")
  now=$(date +%s)
  age=$(( now - last_run ))
  if (( age < MIN_FETCH_AGE_SECONDS )); then
    echo "Skipping campus achievements fetch: last run $age seconds ago (< ${MIN_FETCH_AGE_SECONDS}s)."
    exit 0
  fi
fi

if [[ ! -s "$CAMPUSES_JSON" ]]; then
  echo "Campus list not found at $CAMPUSES_JSON, fetching..."
  "$CAMPUS_HELPER" --force
fi

if [[ ! -s "$CAMPUSES_JSON" ]]; then
  echo "Campus list not found at $CAMPUSES_JSON." >&2
  exit 1
fi

total_pages=0
total_items=0
bytes_downloaded=0
rm -f "$EXPORT_DIR"/campus_*_page_*.json

campus_ids=($(jq -r '.[].id' "$CAMPUSES_JSON"))
for cid in "${campus_ids[@]}"; do
  page=1
  while true; do
    outfile="$EXPORT_DIR/campus_${cid}_page_${page}.json"
    echo "Fetching campus $cid achievements page $page..."
    "$ROOT_DIR/scripts/token_manager.sh" call-export "/v2/campus/${cid}/achievements?per_page=${PER_PAGE}&page=${page}" "$outfile" >/dev/null
    sleep "$SLEEP_BETWEEN_CALLS"
    if [[ ! -s "$outfile" ]]; then
      echo "  -> empty response for campus $cid page $page, stopping."
      rm -f "$outfile"
      break
    fi
    if ! jq -e 'type=="array"' "$outfile" >/dev/null 2>&1; then
      echo "  -> non-array response for campus $cid page $page, stopping."
      echo "     Response snippet: $(head -c 200 "$outfile")"
      if grep -q "429" "$outfile"; then
        rm -f "$outfile"
        echo "Hit 429 rate limit; retry after cooldown."
        exit 1
      fi
      rm -f "$outfile"
      break
    fi
    # Annotate each achievement with campus_id for merging
    tmpfile="${outfile}.tmp"
    jq --argjson cid "$cid" '[.[] | . + {campus_id: $cid}]' "$outfile" > "$tmpfile" && mv "$tmpfile" "$outfile"
    count=$(jq 'length' "$outfile")
    size_bytes=$(stat -c%s "$outfile")
    bytes_downloaded=$((bytes_downloaded + size_bytes))
    total_items=$((total_items + count))
    total_pages=$((total_pages + 1))
    if [[ "$count" -lt $PER_PAGE ]]; then
      break
    fi
    page=$((page + 1))
    sleep 1
  done
  # Respect secondary rate limits
  sleep "$SLEEP_BETWEEN_CAMPUSES"
done

echo "Merging pages into $EXPORT_DIR/raw_all.json"
if ls "$EXPORT_DIR"/campus_*_page_*.json >/dev/null 2>&1; then
  jq -s 'add' "$EXPORT_DIR"/campus_*_page_*.json > "$RAW_JSON"
  rm -f "$EXPORT_DIR"/campus_*_page_*.json
else
  echo "[]" > "$RAW_JSON"
fi

merged_count=$(jq 'length' "$RAW_JSON")

echo "Creating campus achievement links export..."
jq '[.[] | select(.campus_id != null and .id != null) | {campus_id, achievement_id: .id}]' "$RAW_JSON" > "$LINKS_JSON"
unique_count=$(jq '[.[] | .id] | unique | length' "$RAW_JSON")
link_rows=$(jq 'length' "$LINKS_JSON")

now_epoch=$(date +%s)
echo "$now_epoch" > "$STAMP_FILE"
cat > "$METRIC_FILE" <<EOF
timestamp=$now_epoch
pages=$total_pages
items=$total_items
items_merged=$merged_count
campus_achievement_rows=$link_rows
bytes_downloaded=$bytes_downloaded
EOF

echo "Done. Merged count: $merged_count"
