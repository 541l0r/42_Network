#!/bin/bash
# ============================================================================ #
#  fetch_metadata.sh - Fetch stable metadata (cursus 21 + campus achievements)
#  
#  Usage: CAMPUS_ID=1 bash scripts/orchestrate/fetch_metadata.sh
#  
#  Data fetched:
#    01_cursus        - Cursus 21 only (single object)
#    02_campus        - Campuses with users_count > 1 (active + public only)
#    03_achievements  - Achievements metadata for cursus 21
#
#  Note: This data is STATIC and campus-filtered. Fetch once per deployment.
# ============================================================================ #

set -e
CAMPUS_ID="${CAMPUS_ID:-1}"
# Honor global rate-limit setting if present
RATE_LIMIT_SECONDS="${ORCHESTRA_RATE_LIMIT_SECONDS:-1.0}"
last_call_ts=0

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_FILE="$ROOT_DIR/logs/fetch_metadata_$(date +%s).log"
mkdir -p "$ROOT_DIR/logs" "$ROOT_DIR/exports"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
  local msg="$1"
  local icon="•"
  case "$msg" in
    ✅*) icon="✓" ;;
    ❌*) icon="✗" ;;
    ⚠️*) icon="!" ;;
  esac
  echo -e "${icon} ${msg}" | tee -a "$LOG_FILE"
}

log "🌍 Fetching metadata from 42 API..."
log "   Log: $LOG_FILE"
log "   Scope: cursus, campuses, projects, achievements, coalitions"
log "   Started at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
log ""

# ============================================================================ #
#  Token Management
# ============================================================================ #

ensure_json() {
  local file="$1"
  local label="$2"
  local snippet
  if jq empty "$file" >/dev/null 2>&1; then
    return 0
  fi
  snippet=$(head -c 200 "$file" 2>/dev/null | tr '\n' ' ')
  log "  ❌ Invalid JSON for ${label}"
  if [ -n "$snippet" ]; then
    log "     Body head: ${snippet}"
  fi
  return 1
}

load_token() {
  if [ ! -f "$ROOT_DIR/.oauth_state" ]; then
    log "❌ OAuth token not found: $ROOT_DIR/.oauth_state"
    log "   Run: bash scripts/token_manager.sh exchange <code>"
    exit 1
  fi
  
  source "$ROOT_DIR/.oauth_state"
  token_expires_at="${token_expires_at:-${EXPIRES_AT:-}}"
  ACCESS_TOKEN="${ACCESS_TOKEN:-}"
  if [ -z "$ACCESS_TOKEN" ]; then
    log "❌ Access token is empty"
    exit 1
  fi
}

refresh_token_if_needed() {
  if [[ "${SKIP_TOKEN_REFRESH:-0}" == "1" ]]; then
    return
  fi
  local ttl_threshold=3600  # 1 hour
  local now=$(date +%s)
  local expires_at="$token_expires_at"

  if [ -z "$expires_at" ]; then
    log "⚠️  Token expiry unknown, refreshing..."
    bash "$ROOT_DIR/scripts/token_manager.sh" refresh > /dev/null 2>&1
    source "$ROOT_DIR/.oauth_state"
    log "✅ Token refreshed (expires_at=${token_expires_at:-unknown})"
    return
  fi

  local ttl=$((expires_at - now))
  if [ $ttl -lt $ttl_threshold ]; then
    log "🔄 Token expires in ${ttl}s (< 1h), refreshing..."
    bash "$ROOT_DIR/scripts/token_manager.sh" refresh > /dev/null 2>&1
    source "$ROOT_DIR/.oauth_state"
    log "✅ Token refreshed (expires_at=${token_expires_at:-unknown}, ttl=$(( ${token_expires_at:-0} - $(date +%s) ))s)"
  fi
}

# ============================================================================ #
#  Fetch each scope
# ============================================================================ #

load_token
refresh_token_if_needed

respect_rate_limit() {
  local now
  now=$(date +%s.%N)
  if (( $(echo "$last_call_ts > 0" | bc -l) )); then
    local elapsed
    elapsed=$(echo "$now - $last_call_ts" | bc -l)
    local sleep_needed
    sleep_needed=$(echo "$RATE_LIMIT_SECONDS - $elapsed" | bc -l)
    if (( $(echo "$sleep_needed > 0" | bc -l) )); then
      sleep "$sleep_needed"
    fi
  fi
  last_call_ts=$(date +%s.%N)
}

mkdir -p "$ROOT_DIR/exports"/{01_cursus,02_campus,03_achievements,04_campus_achievements,05_projects,06_campus_projects,07_project_sessions,08_coalitions}

log ""
log "───────── METADATA FETCH (STATIC, CAMPUS-FILTERED) ─────────"
log "Start UTC: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# Cursus 21 (single object, not an array)
log "📥 Fetching: /cursus/21"
respect_rate_limit
attempt=1
max_attempts=3
while true; do
  code=$(curl -s -w "%{http_code}" --max-time 30 \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -o "$ROOT_DIR/exports/01_cursus/all.json.tmp" \
    "https://api.intra.42.fr/v2/cursus/21")

  if [ "$code" = "200" ]; then
    break
  fi

  if [ "$code" = "429" ] && [ $attempt -lt $max_attempts ]; then
    log "  ❌ Failed to fetch cursus 21 (HTTP 429), retrying in ${RATE_LIMIT_SECONDS}s ($attempt/$max_attempts)"
    attempt=$((attempt + 1))
    sleep "$RATE_LIMIT_SECONDS"
    continue
  fi

  log "  ❌ Failed to fetch cursus 21 (HTTP $code)"
  if [ -s "$ROOT_DIR/exports/01_cursus/all.json.tmp" ]; then
    snippet=$(head -c 200 "$ROOT_DIR/exports/01_cursus/all.json.tmp" | tr '\n' ' ')
    log "     Body head: ${snippet}"
  fi
  exit 1
done

if ensure_json "$ROOT_DIR/exports/01_cursus/all.json.tmp" "cursus/21"; then
  jq '[.]' "$ROOT_DIR/exports/01_cursus/all.json.tmp" > "$ROOT_DIR/exports/01_cursus/all.json"
  rm -f "$ROOT_DIR/exports/01_cursus/all.json.tmp"
  log "  ✅ 1 record saved (cursus 21)"
else
  exit 1
fi

# Campuses: active=true, public=true, filter by users_count > 1
log "📥 Fetching: /campus (active, public, users_count > 1)"
page=1

while true; do
  respect_rate_limit
  attempt=1
  max_attempts=3
  while true; do
    code=$(curl -s -w "%{http_code}" --max-time 30 \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -o "$ROOT_DIR/exports/02_campus/page_${page}.json.tmp" \
      "https://api.intra.42.fr/v2/campus?filter%5Bactive%5D=true&filter%5Bpublic%5D=true&per_page=100&page=${page}")

    if [ "$code" = "200" ]; then
      break
    fi

    if [ "$code" = "429" ] && [ $attempt -lt $max_attempts ]; then
      log "  ❌ Failed on campus page $page (HTTP 429), retrying in ${RATE_LIMIT_SECONDS}s ($attempt/$max_attempts)"
      attempt=$((attempt + 1))
      sleep "$RATE_LIMIT_SECONDS"
      continue
    fi

    log "  ❌ Failed on campus page $page (HTTP $code)"
    if [ -s "$ROOT_DIR/exports/02_campus/page_${page}.json.tmp" ]; then
      snippet=$(head -c 200 "$ROOT_DIR/exports/02_campus/page_${page}.json.tmp" | tr '\n' ' ')
      log "     Body head: ${snippet}"
    fi
    exit 1
  done

  if [ -s "$ROOT_DIR/exports/02_campus/page_${page}.json.tmp" ]; then
    # Filter: users_count > 1
    jq '[.[] | select((.users_count // 0) > 1)]' "$ROOT_DIR/exports/02_campus/page_${page}.json.tmp" \
      > "$ROOT_DIR/exports/02_campus/page_${page}.json"
    rm -f "$ROOT_DIR/exports/02_campus/page_${page}.json.tmp"
    
    count=$(jq 'length' "$ROOT_DIR/exports/02_campus/page_${page}.json")
    log "  ├─ Campus page ${page} → $count campuses"
    
    if [ "$count" -lt 100 ]; then
      break
    fi
  else
    log "  ❌ Failed on page $page"
    exit 1
  fi
  
  page=$((page + 1))
done

# Merge all campus pages
if [ -f "$ROOT_DIR/exports/02_campus/page_1.json" ]; then
  jq -s 'add' "$ROOT_DIR/exports/02_campus"/page_*.json > "$ROOT_DIR/exports/02_campus/all.json"
  rm -f "$ROOT_DIR/exports/02_campus"/page_*.json
  total=$(jq 'length' "$ROOT_DIR/exports/02_campus/all.json")
  log "  ✅ $total campuses saved (filtered for users_count > 1)"
fi

# Achievements for Cursus 21 (paginated)
log "📥 Fetching: /cursus/21/achievements (all pages)"
page=1
achievement_pages=0

while true; do
  respect_rate_limit
  attempt=1
  max_attempts=3
  while true; do
    code=$(curl -s -w "%{http_code}" --max-time 30 \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -o "$ROOT_DIR/exports/03_achievements/page_${page}.json.tmp" \
      "https://api.intra.42.fr/v2/cursus/21/achievements?per_page=100&page=${page}")

    if [ "$code" = "200" ]; then
      break
    fi

    if [ "$code" = "429" ] && [ $attempt -lt $max_attempts ]; then
      log "  ❌ Failed on achievements page $page (HTTP 429), retrying in ${RATE_LIMIT_SECONDS}s ($attempt/$max_attempts)"
      attempt=$((attempt + 1))
      sleep "$RATE_LIMIT_SECONDS"
      continue
    fi

    log "  ❌ Failed on achievements page $page (HTTP $code)"
    if [ -s "$ROOT_DIR/exports/03_achievements/page_${page}.json.tmp" ]; then
      snippet=$(head -c 200 "$ROOT_DIR/exports/03_achievements/page_${page}.json.tmp" | tr '\n' ' ')
      log "     Body head: ${snippet}"
    fi
    exit 1
  done

  if [ -s "$ROOT_DIR/exports/03_achievements/page_${page}.json.tmp" ]; then
    mv "$ROOT_DIR/exports/03_achievements/page_${page}.json.tmp" "$ROOT_DIR/exports/03_achievements/page_${page}.json"
    count=$(jq 'length' "$ROOT_DIR/exports/03_achievements/page_${page}.json")
    log "  ├─ Achievements page ${page} → $count achievements"
    achievement_pages=$((achievement_pages + 1))
    
    if [ "$count" -lt 100 ]; then
      break
    fi
  else
    log "  ❌ Failed on page $page"
    break
  fi
  
  page=$((page + 1))
done

# Merge all achievement pages
if [ -f "$ROOT_DIR/exports/03_achievements/page_1.json" ]; then
  jq -s 'add' "$ROOT_DIR/exports/03_achievements"/page_*.json > "$ROOT_DIR/exports/03_achievements/all.json"
  rm -f "$ROOT_DIR/exports/03_achievements"/page_*.json
  total=$(jq 'length' "$ROOT_DIR/exports/03_achievements/all.json")
  log "  ✅ $total achievements saved ($achievement_pages pages)"
  date +%s > "$ROOT_DIR/exports/03_achievements/.last_fetch_epoch"
  if [[ -d "$ROOT_DIR/exports/04_campus_achievements" ]]; then
    date +%s > "$ROOT_DIR/exports/04_campus_achievements/.last_fetch_epoch"
  fi
fi

log ""
log "✅ Metadata fetch complete"
log "   Total files: $(ls -1 $ROOT_DIR/exports/0?_*/all.json 2>/dev/null | wc -l)"
