#!/bin/bash

# Check if alumni filter actually works - test with NO filter on alumni field

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"

WINDOW_SECONDS=65
END_TIME=$(date -u +%s)
START_TIME=$((END_TIME - WINDOW_SECONDS))

END_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($END_TIME, datetime.UTC).isoformat().replace('+00:00', 'Z'))" 2>/dev/null)
START_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($START_TIME, datetime.UTC).isoformat().replace('+00:00', 'Z'))" 2>/dev/null)

echo "🔍 ALUMNI FILTER TEST (No alumni parameter at all)"
echo "=================================================="
echo ""

# ============================================================================
# Call 1: WITH alumni=false
# ============================================================================
echo "[1/3] With alumni=false filter..."

ALUMNI_FALSE="[]"
page=1
while true; do
  endpoint="/v2/cursus/21/users?range%5Bupdated_at%5D=$START_ISO,$END_ISO&filter%5Bkind%5D=student&filter%5Balumni%3F%5D=false&per_page=100&page=$page"
  page_json=$("$TOKEN_HELPER" call "$endpoint" 2>/dev/null || echo "[]")
  if ! echo "$page_json" | jq -e 'type=="array"' >/dev/null 2>&1; then break; fi
  page_count=$(echo "$page_json" | jq 'length' 2>/dev/null || echo "0")
  [[ "$page_count" == "0" ]] && break
  ALUMNI_FALSE=$(printf '%s\n%s\n' "$ALUMNI_FALSE" "$page_json" | jq -s 'add')
  page=$((page + 1))
  sleep 0.5
done

COUNT_FALSE=$(echo "$ALUMNI_FALSE" | jq 'length' 2>/dev/null || echo "0")
echo "Result: $COUNT_FALSE users"
echo ""

# ============================================================================
# Call 2: WITHOUT any alumni filter
# ============================================================================
echo "[2/3] Without alumni filter at all..."

NO_ALUMNI_FILTER="[]"
page=1
while true; do
  endpoint="/v2/cursus/21/users?range%5Bupdated_at%5D=$START_ISO,$END_ISO&filter%5Bkind%5D=student&per_page=100&page=$page"
  page_json=$("$TOKEN_HELPER" call "$endpoint" 2>/dev/null || echo "[]")
  if ! echo "$page_json" | jq -e 'type=="array"' >/dev/null 2>&1; then break; fi
  page_count=$(echo "$page_json" | jq 'length' 2>/dev/null || echo "0")
  [[ "$page_count" == "0" ]] && break
  NO_ALUMNI_FILTER=$(printf '%s\n%s\n' "$NO_ALUMNI_FILTER" "$page_json" | jq -s 'add')
  page=$((page + 1))
  sleep 0.5
done

COUNT_NO_FILTER=$(echo "$NO_ALUMNI_FILTER" | jq 'length' 2>/dev/null || echo "0")
echo "Result: $COUNT_NO_FILTER users"
echo ""

# ============================================================================
# Call 3: Check what alumni values exist in unfiltered set
# ============================================================================
echo "[3/3] Analyzing alumni status in unfiltered data..."
echo ""

ALUMNI_TRUE_COUNT=$(echo "$NO_ALUMNI_FILTER" | jq '[.[] | select(.alumni_p==true)] | length' 2>/dev/null || echo "0")
ALUMNI_FALSE_COUNT=$(echo "$NO_ALUMNI_FILTER" | jq '[.[] | select(.alumni_p==false)] | length' 2>/dev/null || echo "0")
ALUMNI_NULL_COUNT=$(echo "$NO_ALUMNI_FILTER" | jq '[.[] | select(.alumni_p==null)] | length' 2>/dev/null || echo "0")

echo "Alumni breakdown in unfiltered data:"
echo "  • alumni_p = true:  $ALUMNI_TRUE_COUNT"
echo "  • alumni_p = false: $ALUMNI_FALSE_COUNT"
echo "  • alumni_p = null:  $ALUMNI_NULL_COUNT"
echo ""

echo "Filter impact:"
echo "  • Detector uses (alumni=false): $COUNT_FALSE"
echo "  • All students (no filter):     $COUNT_NO_FILTER"
echo "  • Difference:                   $(($COUNT_NO_FILTER - $COUNT_FALSE))"
echo ""

if [[ $(($COUNT_NO_FILTER - $COUNT_FALSE)) -gt 0 ]]; then
  echo "✓ Alumni filter IS removing $(($COUNT_NO_FILTER - $COUNT_FALSE)) students"
  echo "  (These are students with alumni_p=true or alumni_p=null)"
else
  echo "⚠️  Alumni filter not removing any students"
  echo "    All students have alumni_p=false OR alumni_p=null"
fi

echo ""
echo "Sample alumni student (if exists):"
ALUMNI_EXAMPLE=$(echo "$NO_ALUMNI_FILTER" | jq '.[] | select(.alumni_p==true)' 2>/dev/null | head -1)
if [[ -n "$ALUMNI_EXAMPLE" ]]; then
  echo "$ALUMNI_EXAMPLE" | jq '{id, login, alumni_p, updated_at}'
else
  echo "  (no alumni_p=true found in this window)"
fi

echo ""
echo "Sample null alumni_p student:"
NULL_EXAMPLE=$(echo "$NO_ALUMNI_FILTER" | jq '.[] | select(.alumni_p==null)' 2>/dev/null | head -1)
if [[ -n "$NULL_EXAMPLE" ]]; then
  echo "$NULL_EXAMPLE" | jq '{id, login, alumni_p, updated_at}'
else
  echo "  (no alumni_p=null found)"
fi
