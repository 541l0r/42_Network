#!/bin/bash

# Quick validation: Check alumni filter impact
# Call API with SAME time window but toggle alumni filter ON/OFF

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"

# Time window (same as detector)
WINDOW_SECONDS=65
END_TIME=$(date -u +%s)
START_TIME=$((END_TIME - WINDOW_SECONDS))

END_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($END_TIME, datetime.UTC).isoformat().replace('+00:00', 'Z'))" 2>/dev/null)
START_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($START_TIME, datetime.UTC).isoformat().replace('+00:00', 'Z'))" 2>/dev/null)

echo "🔍 ALUMNI FILTER VALIDATION"
echo "============================"
echo ""
echo "Time window: $WINDOW_SECONDS seconds"
echo "Range: $START_ISO to $END_ISO"
echo ""
echo "Fetching data..."
echo ""

# ============================================================================
# Call 1: alumni=false (what detector uses)
# ============================================================================
echo "[1/2] Fetching with alumni=false (detector config)..."

ALUMNI_FALSE="[]"
page=1
while true; do
  endpoint="/v2/cursus/21/users?range%5Bupdated_at%5D=$START_ISO,$END_ISO&filter%5Bkind%5D=student&filter%5Balumni%3F%5D=false&per_page=100&page=$page"
  page_json=$("$TOKEN_HELPER" call "$endpoint" 2>/dev/null || echo "[]")
  
  if ! echo "$page_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
    break
  fi
  
  page_count=$(echo "$page_json" | jq 'length' 2>/dev/null || echo "0")
  [[ "$page_count" == "0" ]] && break
  
  ALUMNI_FALSE=$(printf '%s\n%s\n' "$ALUMNI_FALSE" "$page_json" | jq -s 'add')
  echo "  → page $page: $page_count users"
  page=$((page + 1))
  sleep 0.5
done

COUNT_FALSE=$(echo "$ALUMNI_FALSE" | jq 'length' 2>/dev/null || echo "0")
echo "✓ alumni=false: $COUNT_FALSE users"
echo ""

# ============================================================================
# Call 2: alumni=true (no filter on alumni field)
# ============================================================================
echo "[2/2] Fetching with alumni=true (everyone)..."

ALUMNI_TRUE="[]"
page=1
while true; do
  endpoint="/v2/cursus/21/users?range%5Bupdated_at%5D=$START_ISO,$END_ISO&filter%5Bkind%5D=student&filter%5Balumni%3F%5D=true&per_page=100&page=$page"
  page_json=$("$TOKEN_HELPER" call "$endpoint" 2>/dev/null || echo "[]")
  
  if ! echo "$page_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
    break
  fi
  
  page_count=$(echo "$page_json" | jq 'length' 2>/dev/null || echo "0")
  [[ "$page_count" == "0" ]] && break
  
  ALUMNI_TRUE=$(printf '%s\n%s\n' "$ALUMNI_TRUE" "$page_json" | jq -s 'add')
  echo "  → page $page: $page_count users"
  page=$((page + 1))
  sleep 0.5
done

COUNT_TRUE=$(echo "$ALUMNI_TRUE" | jq 'length' 2>/dev/null || echo "0")
echo "✓ alumni=true: $COUNT_TRUE users"
echo ""

# ============================================================================
# Analysis
# ============================================================================
echo "📊 COMPARISON:"
echo "  • Non-alumni (alumni=false):  $COUNT_FALSE"
echo "  • Alumni (alumni=true):       $COUNT_TRUE"
echo "  • Difference:                 $(($COUNT_TRUE - $COUNT_FALSE))"
echo ""

# Show examples
if [[ $COUNT_TRUE -gt $COUNT_FALSE ]]; then
  echo "✅ Alumni filter IS working - found $(($COUNT_TRUE - $COUNT_FALSE)) alumni students"
  echo ""
  echo "Example alumni student (filtered out by detector):"
  ALUMNI_STUDENT=$(echo "$ALUMNI_TRUE" | jq '.[] | select(.alumni_p==true) | select(.id)' 2>/dev/null | head -1)
  echo "$ALUMNI_STUDENT" | jq '{id, login, alumni_p, updated_at}'
else
  echo "⚠️  No alumni found in this window"
fi

echo ""
echo "Example non-alumni student (kept by detector):"
NON_ALUMNI=$(echo "$ALUMNI_FALSE" | jq '.[0]' 2>/dev/null)
echo "$NON_ALUMNI" | jq '{id, login, alumni_p, updated_at}'
echo ""

# Check if difference matches what we'd expect
if [[ $COUNT_FALSE -lt $COUNT_TRUE ]]; then
  ALUMNI_COUNT=$(($COUNT_TRUE - $COUNT_FALSE))
  echo "✓ Detector filters out $ALUMNI_COUNT alumni students from this time window"
else
  echo "✓ No alumni to filter in this time window"
fi
