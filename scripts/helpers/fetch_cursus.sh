#!/usr/bin/env bash
set -euo pipefail

# Fetch a single cursus (default id 21) into exports/01_cursus/all.json.
# Usage: CURSUS_ID=21 fetch_cursus.sh [seconds] | --force

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORT_DIR="$ROOT_DIR/exports/01_cursus"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"
CURSUS_ID=${CURSUS_ID:-21}
SLEEP_BETWEEN_CALLS=${SLEEP_BETWEEN_CALLS:-0.6}
MIN_FETCH_AGE_SECONDS=${MIN_FETCH_AGE_SECONDS:-3600}

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
    echo "Skipping cursus fetch: last run $age seconds ago (< ${MIN_FETCH_AGE_SECONDS}s)."
    exit 0
  fi
fi

rm -f "$EXPORT_DIR"/page_*.json

outfile="$EXPORT_DIR/page_1.json"
echo "Fetching cursus id $CURSUS_ID..."
"$ROOT_DIR/scripts/token_manager.sh" call-export "/v2/cursus/${CURSUS_ID}" "$outfile" >/dev/null
sleep "$SLEEP_BETWEEN_CALLS"
if ! jq -e 'type == "object"' "$outfile" >/dev/null 2>&1; then
  echo "  -> unexpected response (not an object). Payload kept at $outfile"
  exit 1
fi

jq '[.]' "$outfile" > "$EXPORT_DIR/all.json"
downloaded_kb=$(du -k "$outfile" | cut -f1)
rm -f "$outfile"
date +%s > "$STAMP_FILE"
cat > "$METRIC_FILE" <<EOF
timestamp=$(cat "$STAMP_FILE")
pages=1
items_merged=1
downloaded_kB=$downloaded_kb
cursus_id=$CURSUS_ID
EOF
echo "Done. Merged count: 1 (cursus_id=$CURSUS_ID)"
