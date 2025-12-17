#!/bin/bash

# Validate detector filter logic
# Fetches same data WITH and WITHOUT time window filter, compares results

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"

REPORT_FILE="/tmp/detector_filter_validation_$(date -u +%s).json"
LOG_FILE="$ROOT_DIR/logs/detector_validation.log"

mkdir -p "$ROOT_DIR/logs"

echo "🔍 DETECTOR FILTER VALIDATION" | tee -a "$LOG_FILE"
echo "=============================" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Time window (same as detector)
WINDOW_SECONDS=65
END_TIME=$(date -u +%s)
START_TIME=$((END_TIME - WINDOW_SECONDS))

# Convert to ISO 8601
END_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($END_TIME, datetime.UTC).isoformat().replace('+00:00', 'Z'))" 2>/dev/null)
START_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($START_TIME, datetime.UTC).isoformat().replace('+00:00', 'Z'))" 2>/dev/null)

echo "[$(date -u +'%H:%M:%SZ')] Window: $WINDOW_SECONDS seconds" | tee -a "$LOG_FILE"
echo "[$(date -u +'%H:%M:%SZ')] Range: $START_ISO to $END_ISO" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ============================================================================
# 1. FILTERED CALL (with time window AND alumni filter - what detector does)
# ============================================================================
echo "[$(date -u +'%H:%M:%SZ')] Fetching WITH time window AND alumni filter..." | tee -a "$LOG_FILE"

FILTERED_WITH_ALUMNI="[]"
page=1
while true; do
  endpoint="/v2/cursus/21/users?range%5Bupdated_at%5D=$START_ISO,$END_ISO&filter%5Bkind%5D=student&filter%5Balumni%3F%5D=false&per_page=100&page=$page&sort=-updated_at"
  page_json=$("$TOKEN_HELPER" call "$endpoint" 2>/dev/null || echo "[]")
  if ! echo "$page_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
    break
  fi
  page_count=$(echo "$page_json" | jq 'length' 2>/dev/null || echo "0")
  if [[ "$page_count" == "0" ]]; then
    break
  fi
  FILTERED_WITH_ALUMNI=$(printf '%s\n%s\n' "$FILTERED_WITH_ALUMNI" "$page_json" | jq -s 'add')
  echo "[$(date -u +'%H:%M:%SZ')] ... page $page: $page_count users" | tee -a "$LOG_FILE"
  page=$((page + 1))
  sleep 1
done

COUNT_WITH_ALUMNI=$(echo "$FILTERED_WITH_ALUMNI" | jq 'length' 2>/dev/null || echo "0")
echo "[$(date -u +'%H:%M:%SZ')] ✓ WITH alumni filter (false): $COUNT_WITH_ALUMNI users" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ============================================================================
# 2. SAME TIME WINDOW, NO ALUMNI FILTER
# ============================================================================
echo "[$(date -u +'%H:%M:%SZ')] Fetching SAME RANGE but WITHOUT alumni filter..." | tee -a "$LOG_FILE"

FILTERED_NO_ALUMNI="[]"
page=1
while true; do
  # Same time range, kind filter, but NO alumni filter
  endpoint="/v2/cursus/21/users?range%5Bupdated_at%5D=$START_ISO,$END_ISO&filter%5Bkind%5D=student&per_page=100&page=$page&sort=-updated_at"
  page_json=$("$TOKEN_HELPER" call "$endpoint" 2>/dev/null || echo "[]")
  if ! echo "$page_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
    break
  fi
  page_count=$(echo "$page_json" | jq 'length' 2>/dev/null || echo "0")
  if [[ "$page_count" == "0" ]]; then
    break
  fi
  FILTERED_NO_ALUMNI=$(printf '%s\n%s\n' "$FILTERED_NO_ALUMNI" "$page_json" | jq -s 'add')
  echo "[$(date -u +'%H:%M:%SZ')] ... page $page: $page_count users" | tee -a "$LOG_FILE"
  page=$((page + 1))
  sleep 1
done

COUNT_NO_ALUMNI=$(echo "$FILTERED_NO_ALUMNI" | jq 'length' 2>/dev/null || echo "0")
echo "[$(date -u +'%H:%M:%SZ')] ✓ WITHOUT alumni filter: $COUNT_NO_ALUMNI users" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ============================================================================
# 3. SAME TIME WINDOW, NO KIND FILTER
# ============================================================================
echo "[$(date -u +'%H:%M:%SZ')] Fetching SAME RANGE but without kind filter (all types)..." | tee -a "$LOG_FILE"

FILTERED_NO_KIND="[]"
page=1
while true; do
  # Same time range, alumni filter, but NO kind filter
  endpoint="/v2/cursus/21/users?range%5Bupdated_at%5D=$START_ISO,$END_ISO&filter%5Balumni%3F%5D=false&per_page=100&page=$page&sort=-updated_at"
  page_json=$("$TOKEN_HELPER" call "$endpoint" 2>/dev/null || echo "[]")
  if ! echo "$page_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
    break
  fi
  page_count=$(echo "$page_json" | jq 'length' 2>/dev/null || echo "0")
  if [[ "$page_count" == "0" ]]; then
    break
  fi
  FILTERED_NO_KIND=$(printf '%s\n%s\n' "$FILTERED_NO_KIND" "$page_json" | jq -s 'add')
  echo "[$(date -u +'%H:%M:%SZ')] ... page $page: $page_count users" | tee -a "$LOG_FILE"
  page=$((page + 1))
  sleep 1
done

COUNT_NO_KIND=$(echo "$FILTERED_NO_KIND" | jq 'length' 2>/dev/null || echo "0")
echo "[$(date -u +'%H:%M:%SZ')] ✓ WITHOUT kind filter: $COUNT_NO_KIND users" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ============================================================================
# 2. UNFILTERED CALL (no time window - all cursus 21 students)
# ============================================================================
echo "[$(date -u +'%H:%M:%SZ')] Fetching WITHOUT filter (all students)..." | tee -a "$LOG_FILE"

UNFILTERED_JSON="[]"
page=1
while true; do
  # Same endpoint but NO time window, NO alumni filter - just basic student filter
  endpoint="/v2/cursus/21/users?filter%5Bkind%5D=student&per_page=100&page=$page&sort=-updated_at"
  page_json=$("$TOKEN_HELPER" call "$endpoint" 2>/dev/null || echo "[]")
  if ! echo "$page_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
    break
  fi
  page_count=$(echo "$page_json" | jq 'length' 2>/dev/null || echo "0")
  if [[ "$page_count" == "0" ]]; then
    break
  fi
  UNFILTERED_JSON=$(printf '%s\n%s\n' "$UNFILTERED_JSON" "$page_json" | jq -s 'add')
  echo "[$(date -u +'%H:%M:%SZ')] ... page $page: $page_count users" | tee -a "$LOG_FILE"
  page=$((page + 1))
  sleep 1
done

UNFILTERED_COUNT=$(echo "$UNFILTERED_JSON" | jq 'length' 2>/dev/null || echo "0")
echo "[$(date -u +'%H:%M:%SZ')] ✓ UNFILTERED RESULT: $UNFILTERED_COUNT total students in cursus 21" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ============================================================================
# 3. COMPARISON & ANALYSIS
# ============================================================================
echo "[$(date -u +'%H:%M:%SZ')] Analyzing filter impact..." | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Extract IDs from all responses
IDS_WITH_ALUMNI=$(echo "$FILTERED_WITH_ALUMNI" | jq -r '.[].id' | sort -n)
IDS_NO_ALUMNI=$(echo "$FILTERED_NO_ALUMNI" | jq -r '.[].id' | sort -n)
IDS_NO_KIND=$(echo "$FILTERED_NO_KIND" | jq -r '.[].id' | sort -n)

# Count difference caused by alumni filter
ALUMNI_DIFF=$((COUNT_NO_ALUMNI - COUNT_WITH_ALUMNI))

# Count difference caused by kind filter
KIND_DIFF=$((COUNT_NO_KIND - COUNT_WITH_ALUMNI))

echo "📊 FILTER IMPACT ANALYSIS (Same $WINDOW_SECONDS second time window):" | tee -a "$LOG_FILE"
echo "  ┌─ WITH both filters (kind=student, alumni=false):" | tee -a "$LOG_FILE"
echo "  │   → $COUNT_WITH_ALUMNI users" | tee -a "$LOG_FILE"
echo "  │" | tee -a "$LOG_FILE"
echo "  ├─ WITHOUT alumni filter (only kind=student):" | tee -a "$LOG_FILE"
echo "  │   → $COUNT_NO_ALUMNI users (+$ALUMNI_DIFF from alumni filter)" | tee -a "$LOG_FILE"
echo "  │" | tee -a "$LOG_FILE"
echo "  ├─ WITHOUT kind filter (only alumni=false):" | tee -a "$LOG_FILE"
echo "  │   → $COUNT_NO_KIND users (+$KIND_DIFF from kind filter)" | tee -a "$LOG_FILE"
echo "  │" | tee -a "$LOG_FILE"
echo "  └─ TOTAL all users in time window:" | tee -a "$LOG_FILE"
echo "      → $UNFILTERED_COUNT users" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Check for anomalies
if [[ $ALUMNI_DIFF -lt 0 ]]; then
  echo "⚠️  ANOMALY: Alumni filter DECREASED count (shouldn't happen)" | tee -a "$LOG_FILE"
fi

if [[ $KIND_DIFF -lt 0 ]]; then
  echo "⚠️  ANOMALY: Kind filter DECREASED count (shouldn't happen)" | tee -a "$LOG_FILE"
fi

if [[ $COUNT_WITH_ALUMNI -eq 0 ]]; then
  echo "⚠️  WARNING: No users in recent $WINDOW_SECONDS seconds - detector will be quiet" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"

# ============================================================================
# 4. SAMPLE DATA COMPARISON
# ============================================================================
echo "📋 SAMPLE DATA (from detector's actual filter - with alumni=false):" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Newest user in detector window:" | tee -a "$LOG_FILE"
echo "$FILTERED_WITH_ALUMNI" | jq '.[0] | {id, login, updated_at, alumni_p}' | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Oldest user in detector window:" | tee -a "$LOG_FILE"
echo "$FILTERED_WITH_ALUMNI" | jq '.[-1] | {id, login, updated_at, alumni_p}' | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Find a user that was filtered OUT by alumni filter
ALUMNI_FILTERED=$(comm -13 <(echo "$IDS_WITH_ALUMNI") <(echo "$IDS_NO_ALUMNI") | head -1)
if [[ -n "$ALUMNI_FILTERED" ]]; then
  echo "Example user FILTERED OUT by alumni=false:" | tee -a "$LOG_FILE"
  echo "$FILTERED_NO_ALUMNI" | jq ".[] | select(.id==$ALUMNI_FILTERED) | {id, login, updated_at, alumni_p}" | tee -a "$LOG_FILE"
else
  echo "No users filtered by alumni filter in this window" | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

# ============================================================================
# 5. GENERATE JSON REPORT
# ============================================================================
cat > "$REPORT_FILE" <<EOF
{
  "timestamp": "$(date -u -Iseconds)",
  "validation": {
    "with_alumni_false": $COUNT_WITH_ALUMNI,
    "without_alumni_filter": $COUNT_NO_ALUMNI,
    "without_kind_filter": $COUNT_NO_KIND,
    "total_in_cursus_21": $UNFILTERED_COUNT
  },
  "time_range": {
    "window_seconds": $WINDOW_SECONDS,
    "start": "$START_ISO",
    "end": "$END_ISO"
  },
  "filter_impact": {
    "alumni_filter_removes": $ALUMNI_DIFF,
    "kind_filter_removes": $KIND_DIFF
  },
  "detector_config": {
    "kind": "student",
    "alumni": false,
    "cursus": 21,
    "time_window": "${WINDOW_SECONDS}s"
  },
  "newest_in_detector_range": $(echo "$FILTERED_WITH_ALUMNI" | jq '.[0]'),
  "oldest_in_detector_range": $(echo "$FILTERED_WITH_ALUMNI" | jq '.[-1]')
}
EOF

echo "[$(date -u +'%H:%M:%SZ')] Report saved to: $REPORT_FILE" | tee -a "$LOG_FILE"
cat "$REPORT_FILE" | jq '.'
