#!/bin/bash

# Fetch all users from cursus 21 (flat user base)
# Strategy: 
#   1. Fetch all cursus_21 users (paginated, 100/page)
#   2. Merge into all.json (raw JSON)
#   3. Extract user IDs for reference
#   4. Rate: configurable via SPEED env var (default 3 sec/call for 1200/hour limit)

set -euo pipefail

cd "$(dirname "$0")/.."

# Source config
source scripts/config/logging.conf || true
source ../.env || source /srv/42_Network/.env || true

# Config variables
SPEED="${SPEED:-3}"
CURSUS_ID="${CURSUS_ID:-21}"
OUTPUT_DIR="${OUTPUT_DIR:-.tmp/phase2_users}"
STAMP_FILE="$OUTPUT_DIR/.last_fetch_epoch"
METRIC_FILE="$OUTPUT_DIR/.last_fetch_stats"
MIN_FETCH_AGE_SECONDS="${MIN_FETCH_AGE_SECONDS:-3600}"
LOG_FILE="${LOG_DIR:-./logs}/fetch_cursus_21_users_all_$(date -u +%Y%m%d_%H%M%S).log"

# Usage: fetch_cursus_21_users_all.sh [seconds] | --force
if [[ "${1:-}" == "--force" ]]; then
  MIN_FETCH_AGE_SECONDS=0
else
  MIN_FETCH_AGE_SECONDS=${1:-${MIN_FETCH_AGE_SECONDS}}
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

# Skip if fetched recently
if [[ -f "$STAMP_FILE" ]]; then
  last_run=$(cat "$STAMP_FILE")
  now=$(date +%s)
  age=$(( now - last_run ))
  if (( age < MIN_FETCH_AGE_SECONDS )); then
    echo "Skipping users fetch: last run $age seconds ago (< ${MIN_FETCH_AGE_SECONDS}s)." | tee "$LOG_FILE"
    exit 3
  fi
fi

echo "📥 Phase 2: Fetch Cursus 21 Users (Speed: $SPEED req/sec)" | tee "$LOG_FILE"
echo "════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"

# Clean old page files
rm -f "$OUTPUT_DIR"/cursus_users_page_*.json

# ════════════════════════════════════════════════════════════════
# STEP 1: Fetch all cursus_21 users (base/stable data)
# ════════════════════════════════════════════════════════════════

echo "" | tee -a "$LOG_FILE"
echo "STEP 1: Fetching cursus/$CURSUS_ID/users..." | tee -a "$LOG_FILE"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting fetch: per_page=100" | tee -a "$LOG_FILE"

page=1
total_users=0
user_ids_file="$OUTPUT_DIR/user_ids.txt"
> "$user_ids_file"  # Clear file

while true; do
  echo -n "  Page $page..." | tee -a "$LOG_FILE"
  
  json_file="$OUTPUT_DIR/cursus_users_page_${page}.json"
  bash scripts/token_manager.sh call-export "/v2/cursus/$CURSUS_ID/users?filter[kind]=student&filter[alumni?]=false&per_page=100&page=$page" "$json_file" 2>&1 | tee -a "$LOG_FILE"
  
  # Check if valid JSON
  if ! jq empty "$json_file" 2>/dev/null; then
    echo " ERROR (invalid JSON)" | tee -a "$LOG_FILE"
    break
  fi
  
  # Count records on this page
  count=$(jq 'length' "$json_file")
  echo " $count records" | tee -a "$LOG_FILE"
  
  if [ "$count" -eq 0 ]; then
    echo "  No more pages" | tee -a "$LOG_FILE"
    break
  fi
  
  # Extract user IDs
  jq -r '.[].id' "$json_file" >> "$user_ids_file"
  total_users=$((total_users + count))
  
  # Respect SPEED limit
  sleep "$SPEED"
  page=$((page + 1))
done

echo "" | tee -a "$LOG_FILE"
echo "✅ Fetched $total_users users from cursus_21" | tee -a "$LOG_FILE"

# Merge pages into all.json
echo "" | tee -a "$LOG_FILE"
echo "Merging pages into $OUTPUT_DIR/all.json..." | tee -a "$LOG_FILE"
jq -s 'add' "$OUTPUT_DIR"/cursus_users_page_*.json > "$OUTPUT_DIR/all.json"
rm -f "$OUTPUT_DIR"/cursus_users_page_*.json

merged_count=$(jq 'length' "$OUTPUT_DIR/all.json")
echo "Done. Merged count: $merged_count" | tee -a "$LOG_FILE"

# Extract user IDs
user_ids_file="$OUTPUT_DIR/user_ids.txt"
jq -r '.[].id' "$OUTPUT_DIR/all.json" > "$user_ids_file"
id_count=$(wc -l < "$user_ids_file")
echo "User IDs extracted: $id_count" | tee -a "$LOG_FILE"

# Write stats
now_epoch=$(date +%s)
echo "$now_epoch" > "$STAMP_FILE"

total_kb=$(du -k "$OUTPUT_DIR/all.json" | cut -f1)
cat > "$METRIC_FILE" <<EOF
timestamp=$now_epoch
items=$merged_count
user_ids=$id_count
downloaded_kB=$total_kb
EOF

echo "" | tee -a "$LOG_FILE"
echo "════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "✅ FETCH COMPLETE" | tee -a "$LOG_FILE"
echo "════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "Total users fetched: $merged_count" | tee -a "$LOG_FILE"
echo "User IDs: $user_ids_file ($id_count)" | tee -a "$LOG_FILE"
echo "Raw JSON: $OUTPUT_DIR/all.json" | tee -a "$LOG_FILE"
echo "Stats: $METRIC_FILE" | tee -a "$LOG_FILE"
echo "Epoch: $STAMP_FILE" | tee -a "$LOG_FILE"
echo "Log: $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
