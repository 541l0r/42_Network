#!/usr/bin/env bash
set -euo pipefail

# Fetch cursus 21 students (Phase 2 users)
# Output: exports/09_users/all.json
# Filters: kind=student, alumni?=false

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORTS_DIR="$ROOT_DIR/exports/09_users"
LOGS_DIR="$ROOT_DIR/logs"

mkdir -p "$EXPORTS_DIR" "$LOGS_DIR"

if [[ -f "$ROOT_DIR/../.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/../.env"
fi

BASE_URL="${BASE_URL:-https://api.intra.42.fr/v2}"

# Ensure token is fresh
bash "$ROOT_DIR/scripts/token_manager.sh" ensure-fresh

# Load token from .oauth_state
if [[ -f "$ROOT_DIR/.oauth_state" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.oauth_state"
fi

API_TOKEN="${ACCESS_TOKEN:-}"
if [[ -z "$API_TOKEN" ]]; then
  echo "Error: API_TOKEN not set" >&2
  exit 1
fi

OUTPUT_FILE="$EXPORTS_DIR/all.json"
RAW_OUTPUT_FILE="$EXPORTS_DIR/raw_all.json"
TEMP_FILE="${OUTPUT_FILE}.tmp"
RAW_TEMP_FILE="${RAW_OUTPUT_FILE}.tmp"
DELTA_FILE="$EXPORTS_DIR/delta.json"
LOG_FILE="$LOGS_DIR/fetch_cursus_21_users.log"

# Calculate time window for delta
# Use .last_fetch_epoch if it exists, otherwise default to 3 hours ago
LAST_FETCH_FILE="$EXPORTS_DIR/.last_fetch_epoch"
if [[ -f "$LAST_FETCH_FILE" ]]; then
  LAST_EPOCH=$(cat "$LAST_FETCH_FILE")
  SINCE_TIME=$(date -u -d "@$LAST_EPOCH" +'%Y-%m-%dT%H:%M:%SZ')
else
  DELTA_HOURS=${DELTA_HOURS:-3}
  SINCE_TIME=$(date -u -d "$DELTA_HOURS hours ago" +'%Y-%m-%dT%H:%M:%SZ')
fi
UNTIL_TIME=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

{
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting fetch of cursus 21 students (delta fetch)..."
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Time range: $SINCE_TIME to $UNTIL_TIME"
  
  # Start JSON arrays for filtered and raw data
  filtered_records="[]"
  raw_records="[]"
  
  first=true
  page=1
  total=0
  total_raw=0
  per_page=100
  all_records="[]"
  
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting fetch: per_page=$per_page"
  
  while true; do
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Fetching page $page..."
    
    # Use /v2/users endpoint with URL-encoded range filter
    # Timeout: 30 seconds per request max
    response=$(curl -s --connect-timeout 10 --max-time 30 -w "\n%{http_code}" \
      -H "Authorization: Bearer $API_TOKEN" \
      "$BASE_URL/users?range%5Bupdated_at%5D=$SINCE_TIME,$UNTIL_TIME&sort=-updated_at&per_page=$per_page&page=$page" 2>&1)
    
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)
    
    # Rate limiting: 1200 requests/hour = 1 request per 3 seconds minimum
    sleep 1
    
    # Handle timeout or empty response
    if [[ -z "$http_code" ]] || [[ "$http_code" == "000" ]] || [[ "$http_code" == "" ]]; then
      echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Warning: Timeout or no response on page $page, stopping" >&2
      break
    fi
    
    if [[ "$http_code" != "200" ]]; then
      echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Warning: HTTP $http_code on page $page, stopping" >&2
      break
    fi
    
    # Extract raw and filtered users
    raw_page_json=$(echo "$body" | jq -c '.')
    page_json=$(echo "$body" | jq -c '[.[] | select(.kind=="student" and (.alumni|not))]' 2>/dev/null)
    
    # Count records on this page
    page_total=$(echo "$page_json" | jq 'length' 2>/dev/null || echo "0")
    raw_page_total=$(echo "$raw_page_json" | jq 'length' 2>/dev/null || echo "0")
    filtered_out=$((raw_page_total - page_total))
    
    # Log page summary
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Page $page result: raw=$raw_page_total, filtered=$page_total, non-students=$filtered_out"
    
    if [[ "$raw_page_total" -eq 0 ]]; then
      # No more records, we're done
      break
    fi
    
    # Accumulate filtered records
    filtered_records=$(echo "$filtered_records" "$page_json" | jq -s 'add')
    # Accumulate raw records
    raw_records=$(echo "$raw_records" "$raw_page_json" | jq -s 'add')
    total=$((total + page_total))
    total_raw=$((total_raw + raw_page_total))
    
    ((page++))
  done
  
  # Write final JSON arrays to files
  echo "$filtered_records" > "$TEMP_FILE"
  echo "$raw_records" > "$RAW_TEMP_FILE"
  
  # Validate JSON and move both files
  if jq empty "$TEMP_FILE" 2>/dev/null && jq empty "$RAW_TEMP_FILE" 2>/dev/null; then
    mv "$TEMP_FILE" "$OUTPUT_FILE"
    mv "$RAW_TEMP_FILE" "$RAW_OUTPUT_FILE"
    filtered_out=$((total_raw - total))
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Fetch complete: filtered=$total raw=$total_raw non-students=$filtered_out"
    
    # Save next fetch timestamp (convert ISO timestamp to epoch)
    NEXT_EPOCH=$(date -u -d "$UNTIL_TIME" +%s)
    echo "$NEXT_EPOCH" > "$LAST_FETCH_FILE"
    
    # Save metadata
    echo "items=$total" > "$EXPORTS_DIR/.last_fetch_stats"
    echo "timestamp=$UNTIL_TIME" >> "$EXPORTS_DIR/.last_fetch_stats"
  else
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Error: Invalid JSON generated" >&2
    rm -f "$TEMP_FILE" "$RAW_TEMP_FILE" "$LAST_FETCH_FILE"
    exit 1
  fi
  
} | tee -a "$LOG_FILE"

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Fetch complete"
