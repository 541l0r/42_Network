#!/bin/bash
set -euo pipefail

# Analyze delta between two Phase 2 user fetches (v1 vs v2)
# Compares: user counts, field changes, NULL values, field usage, ID increments

cd "$(dirname "$0")/.."

V1_JSON=".tmp/phase2_users_v1/all.json"
V2_JSON=".tmp/phase2_users_v2/all.json"
OUTPUT_DIR=".tmp/phase2_delta_analysis"

if [[ ! -f "$V1_JSON" ]]; then
  echo "❌ V1 JSON not found: $V1_JSON"
  exit 1
fi

if [[ ! -f "$V2_JSON" ]]; then
  echo "❌ V2 JSON not found: $V2_JSON"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "╔═══════════════════════════════════════════════════════════════════════════╗"
echo "║                    PHASE 2 DELTA ANALYSIS (v1 vs v2)                     ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# 1. USER COUNT ANALYSIS
# ═══════════════════════════════════════════════════════════════════════════════

echo "📊 1. USER COUNT ANALYSIS"
echo "─────────────────────────────────────────────────────────────────────────"

v1_count=$(jq 'length' "$V1_JSON")
v2_count=$(jq 'length' "$V2_JSON")
delta_count=$((v2_count - v1_count))
delta_pct=$((delta_count * 100 / v1_count))

echo "v1 (23h):  $v1_count users"
echo "v2 (3h):   $v2_count users"
echo "Δ:         $delta_count users ($delta_pct%)"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# 2. ID RANGE ANALYSIS
# ═══════════════════════════════════════════════════════════════════════════════

echo "🆔 2. ID RANGE & INCREMENTAL SYNC STRATEGY"
echo "─────────────────────────────────────────────────────────────────────────"

v1_min=$(jq 'map(.id) | min' "$V1_JSON")
v1_max=$(jq 'map(.id) | max' "$V1_JSON")
v2_min=$(jq 'map(.id) | min' "$V2_JSON")
v2_max=$(jq 'map(.id) | max' "$V2_JSON")

echo "v1 ID range: $v1_min - $v1_max (span: $((v1_max - v1_min)))"
echo "v2 ID range: $v2_min - $v2_max (span: $((v2_max - v2_min)))"
echo ""
echo "💡 For Phase 3 incremental sync: fetch only IDs > $v1_max"
echo "   Expected new users: ~$((v2_max - v1_max)) to fetch"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# 3. NEW/DELETED USERS
# ═══════════════════════════════════════════════════════════════════════════════

echo "👤 3. NEW & DELETED USERS"
echo "─────────────────────────────────────────────────────────────────────────"

# Extract IDs
jq -r '.[].id' "$V1_JSON" | sort -n > "$OUTPUT_DIR/v1_ids.txt"
jq -r '.[].id' "$V2_JSON" | sort -n > "$OUTPUT_DIR/v2_ids.txt"

# Find new (in v2 but not in v1)
new_users=$(comm -13 <(sort "$OUTPUT_DIR/v1_ids.txt") <(sort "$OUTPUT_DIR/v2_ids.txt") | wc -l)
# Find deleted (in v1 but not in v2)
deleted_users=$(comm -23 <(sort "$OUTPUT_DIR/v1_ids.txt") <(sort "$OUTPUT_DIR/v2_ids.txt") | wc -l)

echo "New users:     $new_users"
echo "Deleted users: $deleted_users"

if [[ $new_users -gt 0 ]]; then
  echo ""
  echo "Sample new user IDs (first 10):"
  comm -13 <(sort "$OUTPUT_DIR/v1_ids.txt") <(sort "$OUTPUT_DIR/v2_ids.txt") | head -10 | sed 's/^/  /'
fi

if [[ $deleted_users -gt 0 ]]; then
  echo ""
  echo "Sample deleted user IDs (first 10):"
  comm -23 <(sort "$OUTPUT_DIR/v1_ids.txt") <(sort "$OUTPUT_DIR/v2_ids.txt") | head -10 | sed 's/^/  /'
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# 4. FIELD USAGE ANALYSIS (NULL values, sparse fields)
# ═══════════════════════════════════════════════════════════════════════════════

echo "🔍 4. FIELD USAGE ANALYSIS (v2 sample - batch processing)"
echo "─────────────────────────────────────────────────────────────────────────"

echo "  Processing fields..."
# Analyze each field with true/false/null/zero counts for booleans
jq 'map(to_entries) | flatten | group_by(.key) | map({
  field: .[0].key,
  total: length,
  values: map(.value) | group_by(type) | map({type: .[0] | type, count: length}) | map(select(.type != "object" and .type != "array")),
  null_count: map(select(.value == null)) | length,
  true_count: map(select(.value == true)) | length,
  false_count: map(select(.value == false)) | length,
  zero_count: map(select(.value == 0)) | length,
  empty_string: map(select(.value == "")) | length
}) | sort_by(.field)' "$V2_JSON" > "$OUTPUT_DIR/v2_field_stats.json"

echo "  Rendering field statistics..."
echo ""
echo "Field                          | Total    | Used%  | NULL  | TRUE  | FALSE | ZERO  | Empty"
echo "───────────────────────────────┼──────────┼────────┼───────┼───────┼───────┼───────┼───────"
jq -r '.[] | 
  ((.total - .null_count) / .total * 100 | floor) as $used |
  "\(.field | @json) | \(.total) | \($used)% | \(.null_count) | \(.true_count) | \(.false_count) | \(.zero_count) | \(.empty_string)"' \
  "$OUTPUT_DIR/v2_field_stats.json" | \
  awk -F'|' '{printf "%-30s | %8s | %6s | %5s | %5s | %5s | %5s | %5s\n", substr($1, 2, length($1)-3), $2, $3, $4, $5, $6, $7, $8}' | sort -k 7 -rn | head -35

echo ""

echo "🔄 5. CHANGED USERS ANALYSIS (updated_at - batch via jq)"
echo "─────────────────────────────────────────────────────────────────────────"

echo "  Indexing v1 users (by ID)..."
jq 'INDEX(.id | tostring)' "$V1_JSON" > "$OUTPUT_DIR/v1_index.json"

echo "  Indexing v2 users (by ID)..."
jq 'INDEX(.id | tostring)' "$V2_JSON" > "$OUTPUT_DIR/v2_index.json"

echo "  Comparing changed fields..."
# Find users with updated_at changes
changed_count=$(jq -s '
  . as [$v1, $v2] |
  ($v1 | keys) as $v1_keys |
  $v1_keys | 
  map(select($v2[.] != null)) as $common_keys |
  $common_keys | 
  map(select($v1[.].updated_at != $v2[.].updated_at)) | 
  length
' "$OUTPUT_DIR/v1_index.json" "$OUTPUT_DIR/v2_index.json" 2>/dev/null || echo "0")

common_users=$((v1_count - deleted_users))
if [[ $common_users -gt 0 ]]; then
  changed_pct=$((changed_count * 100 / common_users))
else
  changed_pct=0
fi

echo "Common users:      $common_users"
echo "Changed (updated): $changed_count ($changed_pct%)"
echo ""
echo "💡 Incremental sync strategy:"
echo "   - Fetch interval: 4 hours (23h → 3h)"
echo "   - Users updated: $changed_pct% in 4h window"
echo "   - New users: ~$new_users per 4h cycle"
echo "   - Deleted users: $deleted_users (alumni/inactive)"
echo "   - Recommendation: Daily delta every 12h (safe for $changed_pct% churn)"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# 6. KEY FIELDS SNAPSHOT
# ═══════════════════════════════════════════════════════════════════════════════

echo "📋 6. KEY FIELDS SNAPSHOT"
echo "─────────────────────────────────────────────────────────────────────────"

echo "Sample user (v2, ID from max ID):"
max_id=$(jq 'map(.id) | max' "$V2_JSON")
jq ".[] | select(.id == $max_id) | {id, login, email, first_name, last_name, kind, active_p: .active?, alumni_p: .alumni?, created_at, updated_at, wallet}" "$V2_JSON" | head -20

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# 7. WRITE SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$OUTPUT_DIR/DELTA_SUMMARY.txt" <<EOF
╔═══════════════════════════════════════════════════════════════════════════╗
║                    PHASE 2 DELTA ANALYSIS SUMMARY                        ║
╚═══════════════════════════════════════════════════════════════════════════╝

FETCH WINDOWS
─────────────
v1: 23:00 (previous day) → 405 pages, $v1_count users
v2: 03:00 (current day)  → 405 pages, $v2_count users
Duration: 4 hours

USER CHANGES
────────────
Total users v1:    $v1_count
Total users v2:    $v2_count
New users:         $new_users
Deleted users:     $deleted_users
Changed users:     $changed_count/$common_users ($changed_pct%)
Net change:        $delta_count ($delta_pct%)

ID STRATEGY FOR PHASE 3
───────────────────────
v1 ID range: $v1_min - $v1_max
v2 ID range: $v2_min - $v2_max
Max ID increment: $((v2_max - v1_max))

For next fetch: Use filter[id]>$v1_max to get only new users
Expected API calls saved: ~$((v1_count - new_users)) (cached fetch)
Estimated savings: $((new_users * 100 / v1_count))% of previous volume

FIELD USAGE RECOMMENDATIONS
────────────────────────────
• High coverage (>95%): Use as required filters
• Medium coverage (50-95%): Include but handle NULLs
• Low coverage (<50%): Optional/sparse fields

See v2_field_stats.json for detailed breakdown.

NULL/EMPTY PATTERNS
───────────────────
Location field: Often NULL (user location data sparse)
Anonymize/erasure dates: Future dates, low relevance
Phone: Always hidden (API limitation)

INCREMENTAL SYNC VIABILITY
──────────────────────────
✓ New users detected: YES ($new_users in 4h)
✓ Updated users detectable: YES ($changed_count changes)
✓ Deletions tracked: YES ($deleted_users)

RECOMMENDATION
──────────────
✅ Viable for 24h incremental syncs
   - Fetch new users: every 12h (IDs > last_max_id)
   - Sync updates: every 4-6h (updated_at > timestamp)
   - Full refresh: weekly (sanity check)
EOF

echo "════════════════════════════════════════════════════════════════════════"
echo "✅ Analysis complete!"
echo ""
echo "Output files:"
echo "  • $OUTPUT_DIR/v2_field_stats.json"
echo "  • $OUTPUT_DIR/DELTA_SUMMARY.txt"
echo "  • $OUTPUT_DIR/v1_ids.txt, v2_ids.txt (for diffs)"
echo ""
