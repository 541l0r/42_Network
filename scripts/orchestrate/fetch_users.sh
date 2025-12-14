#!/bin/bash
# ============================================================================ #
#  fetch_users.sh - Fetch users for ANY campus (parameterized)
#  
#  Usage: CAMPUS_ID=76 bash scripts/orchestrate/fetch_users.sh
#         CAMPUS_ID=12 bash scripts/orchestrate/fetch_users.sh
#  
#  Environment variables:
#    CAMPUS_ID  - Campus to fetch (default: 76 = low-volume campus)
#    --dry-run  - Show what would be fetched without saving
#
#  Data fetched:
#    - Scope: campus_id=CAMPUS_ID
#    - Filter: kind='student' AND alumni=false
#    - Saves: exports/09_users/campus_{CAMPUS_ID}/all.json
#
#  Note: Called every minute by cron for live updates.
# ============================================================================ #

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAMPUS_ID="${CAMPUS_ID:-76}"
DRY_RUN="${1:-}"
LOG_FILE="$ROOT_DIR/logs/fetch_users_campus_${CAMPUS_ID}_$(date +%s).log"

mkdir -p "$ROOT_DIR/logs" "$ROOT_DIR/exports/09_users/campus_${CAMPUS_ID}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ============================================================================ #
#  Token Management
# ============================================================================ #

load_token() {
  if [ ! -f "$ROOT_DIR/.oauth_state" ]; then
    log "❌ OAuth token not found: $ROOT_DIR/.oauth_state"
    exit 1
  fi
  
  source "$ROOT_DIR/.oauth_state"
  ACCESS_TOKEN="${ACCESS_TOKEN:-}"
  
  if [ -z "$ACCESS_TOKEN" ]; then
    log "❌ Access token is empty"
    exit 1
  fi
}

refresh_token_if_needed() {
  local ttl_threshold=3600
  local now=$(date +%s)
  local expires_at="$token_expires_at"

  if [ -z "$expires_at" ]; then
    bash "$ROOT_DIR/scripts/token_manager.sh" refresh > /dev/null 2>&1
    source "$ROOT_DIR/.oauth_state"
    return
  fi

  local ttl=$((expires_at - now))
  if [ $ttl -lt $ttl_threshold ]; then
    bash "$ROOT_DIR/scripts/token_manager.sh" refresh > /dev/null 2>&1
    source "$ROOT_DIR/.oauth_state"
  fi
}

# ============================================================================ #
#  Pagination + Filtering
# ============================================================================ #

fetch_campus_users() {
  local per_page=100
  local page=1
  local all_users="[]"
  local output_file="$ROOT_DIR/exports/09_users/campus_${CAMPUS_ID}/all.json"
  local stamp_file="$ROOT_DIR/exports/09_users/campus_${CAMPUS_ID}/.last_fetch_epoch"

  log "📥 Fetching users from /v2/campus/${CAMPUS_ID}/users..."

  while true; do
  log "  Page $page @ $(date -u +'%H:%M:%SZ')"

    local response=$(curl -s \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "https://api.intra.42.fr/v2/campus/${CAMPUS_ID}/users?page=${page}&per_page=${per_page}" \
      2>/dev/null)

    # Check if empty
    if [ "$(echo "$response" | jq 'length' 2>/dev/null)" -eq 0 ]; then
      log "  ✅ Pagination complete (empty page)"
      break
    fi

    # Append to collection
    all_users=$(echo "$all_users" "$response" | jq -s 'add')

    page=$((page + 1))
    sleep 1  # Rate limiting
  done

  # Filter: kind='student' AND alumni=false
  log "🔍 Filtering students (alumni=false)..."
  all_users=$(echo "$all_users" | jq '[.[] | select(.kind == "student" and (.alumni // false) | not)]')

  local count=$(echo "$all_users" | jq 'length')
  log "  ✅ $count students found"

  if [ "$DRY_RUN" == "--dry-run" ]; then
    log "📋 DRY RUN: Would save $count students to $output_file"
    echo "[]" > "$output_file"
    return
  fi

  # Save
  echo "$all_users" > "$output_file"
  log "✅ Saved to: $output_file"
  
  # Record fetch timestamp
  date +%s > "$stamp_file"
  log "📅 Fetch timestamp saved"
}

# ============================================================================ #
#  Main
# ============================================================================ #

log "👥 Fetching users for campus $CAMPUS_ID..."
log "   Log: $LOG_FILE"

if [ "$DRY_RUN" == "--dry-run" ]; then
  log "   Mode: DRY RUN (no save)"
fi

log ""

load_token
refresh_token_if_needed
fetch_campus_users

log ""
log "✅ Users fetch complete (campus $CAMPUS_ID)"
