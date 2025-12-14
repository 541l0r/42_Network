#!/bin/bash

# fetch_scope_09_brussels.sh
# Fetch scope 09: Users LIMITED to Brussels campus ONLY
# Initial full fetch for Brussels (one-time bootstrap operation)

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
EXPORTS_DIR="$ROOT_DIR/exports/09_users"

mkdir -p "$LOG_DIR" "$EXPORTS_DIR"

LOG_FILE="$LOG_DIR/fetch_scope_09_brussels.log"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $@" | tee -a "$LOG_FILE"
}

log "════════════════════════════════════════════════════════════"
log "SCOPE 09: Fetching users (BRUSSELS CAMPUS ONLY)"
log "════════════════════════════════════════════════════════════"

# Brussels campus ID from API
BRUSSELS_CAMPUS_ID=1

log ""
log "Target: Campus ID $BRUSSELS_CAMPUS_ID (Brussels)"
log "Scope: Students only, not alumni"
log "Output: exports/09_users/campus_1/"

cd "$ROOT_DIR/repo"

# Load API token
if [ ! -f "$ROOT_DIR/.oauth_state" ]; then
    log "ERROR: No .oauth_state file"
    exit 1
fi

source "$ROOT_DIR/.oauth_state"
API_TOKEN="$ACCESS_TOKEN"

if [ -z "$API_TOKEN" ]; then
    log "ERROR: No API token"
    exit 1
fi

BASE_URL="https://api.intra.42.fr/v2"
CAMPUS_DIR="$EXPORTS_DIR/campus_$BRUSSELS_CAMPUS_ID"
mkdir -p "$CAMPUS_DIR"

log ""
log "Fetching all students from campus $BRUSSELS_CAMPUS_ID..."

# Fetch users with campus filter
ALL_USERS="[]"
PAGE=1
TOTAL=0

while true; do
    log "  Fetching page $PAGE..."
    
    RESPONSE=$(curl -s -H "Authorization: Bearer $API_TOKEN" \
        "$BASE_URL/campus/$BRUSSELS_CAMPUS_ID/users?page=$PAGE&per_page=100" 2>/dev/null || echo "[]")
    
    if [ "$RESPONSE" = "[]" ]; then
        log "  End of results at page $PAGE"
        break
    fi
    
    # Filter: kind=student AND alumni?=false
    FILTERED=$(echo "$RESPONSE" | jq '[.[] | select(.kind=="student" and (.alumni|not))]' 2>/dev/null || echo "[]")
    FILTERED_COUNT=$(echo "$FILTERED" | jq 'length' 2>/dev/null || echo 0)
    
    if [ "$FILTERED_COUNT" -gt 0 ]; then
        ALL_USERS=$(echo "$ALL_USERS" | jq --argjson batch "$FILTERED" '. += $batch' 2>/dev/null || echo "$ALL_USERS")
        TOTAL=$((TOTAL + FILTERED_COUNT))
        log "    ✓ Page $PAGE: $FILTERED_COUNT students (total so far: $TOTAL)"
    fi
    
    # Rate limiting
    sleep 1
    
    PAGE=$((PAGE + 1))
done

# Save to JSON
OUTPUT_FILE="$CAMPUS_DIR/all.json"
echo "$ALL_USERS" | jq '.' > "$OUTPUT_FILE"

log ""
log "════════════════════════════════════════════════════════════"
log "✅ SCOPE 09 (BRUSSELS) COMPLETE"
log "════════════════════════════════════════════════════════════"
log ""
log "Results:"
log "  - Total students: $TOTAL"
log "  - Output file: $OUTPUT_FILE"
log "  - File size: $(du -h "$OUTPUT_FILE" | cut -f1)"
log ""
log "Next: Auto-updater will now run on trigger basis"
log "  - detect_changes.sh (every minute, all campuses)"
log "  - worker_process_backlog.sh (every 5 seconds)"
log ""
