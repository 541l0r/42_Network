#!/bin/bash
# ============================================================================ #
#  orchestra.sh - Main orchestration controller for live user tracking
#
#  Purpose: Coordinate fetching and loading of campus-specific user data
#  
#  Usage:
#    CAMPUS_ID=76 bash scripts/orchestrate/orchestra.sh [--full-cycle]
#    (all other knobs live in scripts/config/orchestra.conf)
#
#  Environment variables:
#    CAMPUS_ID        - Campus to sync (default: ORCHESTRA_DEFAULT_CAMPUS_ID or 76)
#    --full-cycle     - Force fetch + load regardless of last run time
#
#  Data flow:
#    1. Validate environment (token, campus, database)
#    2. Refresh token if needed (<1h TTL)
#    3. Fetch users for CAMPUS_ID via range[updated_at] (incremental)
#    4. Normalize JSON data
#    5. Stage in delta_users table
#    6. Validate foreign keys
#    7. Upsert into production users table
#    8. Load project_users, achievements_users, coalitions_users
#    9. Log metrics and errors
#
#  API Strategy (minimal hits):
#    - Rolling window: Fetch only users modified in last N minutes
#    - Per-campus: Only hits /v2/cursus/21/cursus_users?campus_id=X
#    - Pagination: 100 per page, stop after last page
#    - Retry: 3 attempts with exponential backoff on 429/5xx
#
#  Database Strategy:
#    - Delta staging: Atomic upserts (all-or-nothing)
#    - Idempotent: Safe to re-run
#    - Campus isolation: Only users for this CAMPUS_ID
#    - Derived tables: achievements_users from project_users
#
# ============================================================================ #

set -e

# ============================================================================ #
#  INITIALIZATION
# ============================================================================ #

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts"
LOGS_DIR="$ROOT_DIR/logs"
EXPORTS_DIR="$ROOT_DIR/exports"
BACKLOG_DIR="$ROOT_DIR/.backlog"
ENV_FILE="$ROOT_DIR/.env"
CONFIG_FILE="$SCRIPTS_DIR/config/orchestra.conf"

# Load orchestration config first (preferred overrides)
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "$CONFIG_FILE"
  set +a
fi

# Load .env for orchestration options if present
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "$ENV_FILE"
  set +a
fi

DEFAULT_CAMPUS_ID="${ORCHESTRA_DEFAULT_CAMPUS_ID:-76}"
BOOTSTRAP_MODE="${ORCHESTRA_DB_BOOTSTRAP_MODE:-empty}"   # raw | empty
RAW_PATH="${ORCHESTRA_DB_RAW_PATH:-/srv/42_Network/phase2_users_v2_all.json}"
METADATA_FETCH="${ORCHESTRA_METADATA_FETCH:-1}"
METADATA_SNAPSHOT="${ORCHESTRA_METADATA_SNAPSHOT:-0}"
METADATA_SNAPSHOT_PATH="${ORCHESTRA_METADATA_SNAPSHOT_PATH:-$ROOT_DIR/metadata_snapshot_latest.json}"
METADATA_FALLBACK_PATH="${ORCHESTRA_METADATA_FALLBACK_PATH:-$METADATA_SNAPSHOT_PATH}"
START_WORKER="${ORCHESTRA_START_WORKER:-1}"
DB_CHECK_BYPASS="${ORCHESTRA_DB_CHECK_BYPASS:-0}"
RATE_LIMIT_SECONDS="${ORCHESTRA_RATE_LIMIT_SECONDS:-1.0}"
API_HEALTH_CHECK="${ORCHESTRA_API_HEALTH_CHECK:-1}"

# Fallbacks if values are present but empty
if [[ -z "$BOOTSTRAP_MODE" ]]; then
  BOOTSTRAP_MODE="empty"
fi
if [[ -z "$RAW_PATH" ]]; then
  RAW_PATH="/srv/42_Network/phase2_users_v2_all.json"
fi
if [[ -z "$METADATA_FETCH" && -n "${ORCHESTRA_METADA_FETCH:-}" ]]; then
  METADATA_FETCH="$ORCHESTRA_METADA_FETCH"
fi
if [[ -z "$METADATA_FETCH" ]]; then
  METADATA_FETCH="1"
fi
if [[ -z "$START_WORKER" ]]; then
  START_WORKER="1"
fi
if [[ -z "$API_HEALTH_CHECK" ]]; then
  API_HEALTH_CHECK="1"
fi

# Validate root directory
if [[ ! -f "$ROOT_DIR/docker-compose.yml" ]]; then
  echo "❌ Error: Not in 42_Network root directory"
  exit 1
fi

# Create directories
mkdir -p "$LOGS_DIR" "$EXPORTS_DIR/09_users"

# Logging
TIMESTAMP=$(date +%s)
DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE="$LOGS_DIR/orchestra_$(date +%Y%m%d_%H%M%S).log"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
  local level="$1"
  shift
  local msg="$@"
  local color icon
  case "$level" in
    ERROR)   color=$RED;   icon="✗" ;;
    SUCCESS) color=$GREEN; icon="✓" ;;
    WARN)    color=$YELLOW;icon="!" ;;
    INFO)    color=$BLUE;  icon="•" ;;
    *)       color=$NC;    icon="•" ;;
  esac
  echo -e "${color}${icon} ${msg}${NC}" | tee -a "$LOG_FILE"
}

frame() {
  echo "$@" | tee -a "$LOG_FILE"
}

# ============================================================================ #
#  CONFIGURATION & VALIDATION
# ============================================================================ #

# Parse arguments (no dry-run/test flags)
FULL_CYCLE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full-cycle)   FULL_CYCLE=1 ;;
    *)              log ERROR "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

# Load campus ID from environment (set by deploy)
CAMPUS_ID="${CAMPUS_ID:-$DEFAULT_CAMPUS_ID}"
CAMPUS_ID=$(echo "$CAMPUS_ID" | sed 's/"//g')  # Strip quotes

frame "╔════════════════════════════════╗"
frame "║ RUN INFO                       ║"
frame "╚════════════════════════════════╝"
frame "  Campus    : $CAMPUS_ID (default $DEFAULT_CAMPUS_ID)"
frame "  Bootstrap : $BOOTSTRAP_MODE"
frame "  Worker    : $([[ $START_WORKER -eq 1 ]] && echo 'YES' || echo 'NO')"
frame "  Rate limit: ${RATE_LIMIT_SECONDS}s min gap"
frame "  API check : $([[ $API_HEALTH_CHECK -eq 1 ]] && echo 'YES' || echo 'NO')"
frame "  DB check  : $([[ $DB_CHECK_BYPASS -eq 1 ]] && echo 'BYPASS' || echo 'RUN')"
frame "  Log       : $LOG_FILE"
frame "  Config    : $CONFIG_FILE"
frame "  Metadata  : fetch=$([[ $METADATA_FETCH -eq 1 ]] && echo 'YES' || echo 'NO')"
frame "  Meta snapshot: $([[ $METADATA_SNAPSHOT -eq 1 ]] && echo 'YES' || echo 'NO')"
frame "  Meta fallback: ${METADATA_FALLBACK_PATH}"

# Validate CAMPUS_ID is numeric
if ! [[ "$CAMPUS_ID" =~ ^[0-9]+$ ]]; then
  log ERROR "CAMPUS_ID must be numeric, got: $CAMPUS_ID"
  exit 1
fi

# ============================================================================ #
#  TOKEN MANAGEMENT
# ============================================================================ #

load_token() {
  if [[ ! -f "$ROOT_DIR/.oauth_state" ]]; then
    log ERROR "OAuth token not found: $ROOT_DIR/.oauth_state"
    log ERROR "Run: bash scripts/token_manager.sh exchange <code>"
    return 1
  fi
  
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.oauth_state"
  
  if [[ -z "${ACCESS_TOKEN:-}" ]]; then
    log ERROR "ACCESS_TOKEN is empty"
    return 1
  fi
  
  local expires_at_val="${token_expires_at:-${EXPIRES_AT:-unknown}}"
  local ttl="unknown"
  if [[ "$expires_at_val" =~ ^[0-9]+$ ]]; then
    ttl=$((expires_at_val - $(date +%s)))
  fi
  log SUCCESS "Token loaded (expires_at=${expires_at_val}, ttl=${ttl}s)"
  return 0
}

docker_status() {
  log INFO "Docker status (transcendence containers):"
  if timeout 5 docker ps --format '{{.Names}} | {{.Status}}' | grep -i 'transcendence' >/tmp/docker_status.$$ 2>>"$LOG_FILE"; then
    if [[ -s /tmp/docker_status.$$ ]]; then
      while IFS= read -r line; do
        log INFO "  $line"
      done < /tmp/docker_status.$$
    else
      log INFO "  (no transcendence containers running)"
    fi
    rm -f /tmp/docker_status.$$
  else
    log ERROR "Docker status check failed"
  fi
}

check_api_health() {
  local max_attempts=3
  local attempt=1
  while [[ $attempt -le $max_attempts ]]; do
    sleep "$RATE_LIMIT_SECONDS"
    local start=$(date +%s)
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "https://api.intra.42.fr/v2/cursus/21")
    local end=$(date +%s)
    local duration=$((end - start))

    if [[ "$code" == "200" ]]; then
      log SUCCESS "API health OK (GET /v2/cursus/21 -> 200 in ${duration}s)"
      return 0
    fi

    if [[ "$code" == "429" && $attempt -lt $max_attempts ]]; then
      log WARN "API health check 429, retrying in ${RATE_LIMIT_SECONDS}s (attempt $attempt/$max_attempts)"
      attempt=$((attempt + 1))
      continue
    fi

    log ERROR "API health check failed (status=$code, duration=${duration}s)"
    return 1
  done
}

db_counts() {
  # spacer
  frame ""
  frame "╔════════════════════════════════╗"
  frame "║ DB STATUS                      ║"
  frame "╚════════════════════════════════╝"
  local tables=(
    "users"
    "campuses"
    "projects"
    "coalitions"
    "achievements"
    "project_users"
    "achievements_users"
    "coalitions_users"
    "campus_projects"
    "campus_achievements"
    "project_sessions"
  )
  for tbl in "${tables[@]}"; do
    if docker exec transcendence_db psql -U "${DB_USER:-api42}" -d "${DB_NAME:-api42}" -t -c "SELECT COUNT(*) FROM ${tbl}" >/tmp/db_count.$$ 2>/dev/null; then
      local cnt
      cnt=$(tr -d '[:space:]' </tmp/db_count.$$)
      log INFO "  ${tbl}: ${cnt:-0}"
    else
      log WARN "  ${tbl}: not present"
    fi
    rm -f /tmp/db_count.$$
  done
}

run_db_check() {
  frame ""
  frame "╔════════════════════════════════╗"
  frame "║ DB CHECK                       ║"
  frame "╚════════════════════════════════╝"
  local tmp_log
  tmp_log=$(mktemp)
  if bash "$SCRIPTS_DIR/check_db_integrity.sh" >"$tmp_log" 2>&1; then
    while IFS= read -r line; do
      log INFO "$line"
    done < "$tmp_log"
    log SUCCESS "DB integrity check completed"
  else
    while IFS= read -r line; do
      log INFO "$line"
    done < "$tmp_log"
    log WARN "DB integrity check failed"
  fi
  cat "$tmp_log" >> "$LOG_FILE"
  rm -f "$tmp_log"
}

prepare_backlog() {
  mkdir -p "$BACKLOG_DIR"
  local backlog_file="$BACKLOG_DIR/pending_users.txt"
  : > "$backlog_file"
  log INFO "Backlog file prepared (cleared): $backlog_file"
}

start_worker() {
  frame ""
  frame "╔════════════════════════════════╗"
  frame "║ WORKER                         ║"
  frame "╚════════════════════════════════╝"

  if [[ "${START_WORKER}" != "1" ]]; then
    log INFO "Worker start disabled (ORCHESTRA_START_WORKER=${START_WORKER})"
    return 0
  fi

  prepare_backlog

  # Ensure manager exists
  if [[ ! -x "$SCRIPTS_DIR/backlog_worker_manager.sh" ]]; then
    log ERROR "backlog_worker_manager.sh not found or not executable at $SCRIPTS_DIR/backlog_worker_manager.sh"
    return 1
  fi

  # Show current status
  local status_out
  status_out=$(bash "$SCRIPTS_DIR/backlog_worker_manager.sh" status 2>&1 || true)
  if [[ -n "$status_out" ]]; then
    log INFO "$status_out"
    if echo "$status_out" | grep -qi "not running"; then
      :
    elif echo "$status_out" | grep -qi "running"; then
      return 0
    fi
  else
    log WARN "Unable to read worker status"
  fi

  # Start via manager
  if output=$(bash "$SCRIPTS_DIR/backlog_worker_manager.sh" start 2>&1); then
    while IFS= read -r line; do
      log INFO "$line"
    done <<< "$output"
  else
    while IFS= read -r line; do
      log WARN "$line"
    done <<< "$output"
    return 1
  fi
}

refresh_token_now() {
  log INFO "Refreshing token..."
  if bash "$SCRIPTS_DIR/token_manager.sh" refresh >> "$LOG_FILE" 2>&1; then
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.oauth_state"
    local expires_at="${token_expires_at:-${EXPIRES_AT:-}}"
    local now=$(date +%s)
    local ttl="unknown"
    if [[ -n "$expires_at" ]]; then
      ttl=$((expires_at - now))
    fi
    log SUCCESS "Token refreshed (expires_at=${expires_at:-unknown}, ttl=${ttl}s)"
    return 0
  else
    log ERROR "Token refresh failed"
    return 1
  fi
}

# ============================================================================ #
#  DATABASE VALIDATION
# ============================================================================ #

validate_database() {
  local db_user="${DB_USER:-api42}"
  local db_name="${DB_NAME:-api42}"
  local db_password="${DB_PASSWORD:-api42}"
  
  # Try to connect via docker exec if container exists
  if docker ps | grep -q transcendence_db; then
    if ! docker exec -e PGPASSWORD="$db_password" transcendence_db psql -U "$db_user" -d "$db_name" -c "SELECT 1" > /dev/null 2>&1; then
      log ERROR "Cannot connect to database in docker (tried via docker exec)"
      return 1
    fi
  else
    # Fall back to network connection if not in docker
    local db_host="${DB_HOST:-localhost}"
    local db_port="${DB_PORT:-5432}"
    if ! PGPASSWORD="$db_password" psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" -c "SELECT 1" > /dev/null 2>&1; then
      log ERROR "Cannot connect to database at $db_host:$db_port"
      return 1
    fi
  fi
  
  log SUCCESS "Database connected"
  return 0
}

validate_table_exists() {
  local table="$1"
  local db_user="${DB_USER:-api42}"
  local db_name="${DB_NAME:-api42}"
  local db_password="${DB_PASSWORD:-api42}"
  
  if docker ps | grep -q transcendence_db; then
    if docker exec -e PGPASSWORD="$db_password" transcendence_db psql -U "$db_user" -d "$db_name" -c "\dt $table" 2>&1 | grep -q "1 row"; then
      return 0  # Table exists
    else
      log ERROR "Table does not exist: $table"
      return 1
    fi
  else
    local db_host="${DB_HOST:-localhost}"
    local db_port="${DB_PORT:-5432}"
    if PGPASSWORD="$db_password" psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" -c "\dt $table" 2>&1 | grep -q "1 row"; then
      return 0  # Table exists
    else
      log ERROR "Table does not exist: $table"
      return 1
    fi
  fi
}

# ============================================================================ #
#  METADATA & DATABASE BOOTSTRAP
# ============================================================================ #

ensure_metadata_exports() {
  local fetched=0
  local fallback_used=0
  local metadata_epoch=""

  if [[ "$METADATA_FETCH" == "1" ]]; then
    log INFO "Metadata fetch (independent of user bootstrap)"
    if ( set -o pipefail; SKIP_TOKEN_REFRESH=1 bash "$SCRIPTS_DIR/orchestrate/fetch_metadata.sh" | tee -a "$LOG_FILE" ); then
      log SUCCESS "Metadata fetched to exports/ (see per-page logs above)"
      fetched=1
      # Optional JSON snapshot (aggregated) with timestamped copy
      if [[ "$METADATA_SNAPSHOT" == "1" ]]; then
        local ts
        ts=$(date +%Y%m%d_%H%M%S)
        local snapshot_ts="$ROOT_DIR/metadata_snapshot_${ts}.json"
        local latest_path="$METADATA_SNAPSHOT_PATH"
        mkdir -p "$(dirname "$latest_path")"
        if jq -n \
          --arg created_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
          --slurpfile cursus "$ROOT_DIR/exports/01_cursus/all.json" \
          --slurpfile campus "$ROOT_DIR/exports/02_campus/all.json" \
          --slurpfile achievements "$ROOT_DIR/exports/03_achievements/all.json" \
          --slurpfile campus_achievements "$ROOT_DIR/exports/04_campus_achievements/all.json" \
          --slurpfile projects "$ROOT_DIR/exports/05_projects/all.json" \
          --slurpfile campus_projects "$ROOT_DIR/exports/06_campus_projects/all.json" \
          --slurpfile project_sessions "$ROOT_DIR/exports/07_project_sessions/all.json" \
          --slurpfile coalitions "$ROOT_DIR/exports/08_coalitions/all.json" \
          '{created_at:$created_at,datasets:{cursus:$cursus|flatten,campus:$campus|flatten,achievements:$achievements|flatten,campus_achievements:$campus_achievements|flatten,projects:$projects|flatten,campus_projects:$campus_projects|flatten,project_sessions:$project_sessions|flatten,coalitions:$coalitions|flatten}}' \
          > "$snapshot_ts" 2>>"$LOG_FILE"; then
          cp "$snapshot_ts" "$latest_path"
          log INFO "Metadata snapshot saved to $snapshot_ts (latest -> $latest_path)"
        else
          log WARN "Failed to write metadata snapshot JSON"
        fi
      fi
    else
      log ERROR "Metadata fetch failed"
    fi
  else
    log INFO "Metadata fetch disabled (ORCHESTRA_METADATA_FETCH=0) → will try fallback"
  fi

  # If fetch did not happen or failed, try fallback
  if [[ "$fetched" -eq 0 ]]; then
    local fallback_path="$METADATA_FALLBACK_PATH"
    if [[ ! -f "$fallback_path" ]]; then
      # Try latest timestamped snapshot as fallback
      local latest_candidate
      latest_candidate=$(ls -1t "$ROOT_DIR"/metadata_snapshot_*.json 2>/dev/null | head -n1 || true)
      if [[ -n "$latest_candidate" ]]; then
        fallback_path="$latest_candidate"
        log WARN "Configured fallback missing; using latest snapshot: $fallback_path"
      fi
    fi

    if [[ -n "$fallback_path" && -f "$fallback_path" ]]; then
      log WARN "Restoring metadata from fallback JSON: $fallback_path"
      if jq -e '.' "$fallback_path" >/dev/null 2>&1; then
        mkdir -p "$ROOT_DIR/exports"/{01_cursus,02_campus,03_achievements,04_campus_achievements,05_projects,06_campus_projects,07_project_sessions,08_coalitions}
        jq -r '.datasets.cursus' "$fallback_path" > "$ROOT_DIR/exports/01_cursus/all.json"
        jq -r '.datasets.campus' "$fallback_path" > "$ROOT_DIR/exports/02_campus/all.json"
        jq -r '.datasets.achievements' "$fallback_path" > "$ROOT_DIR/exports/03_achievements/all.json"
        jq -r '.datasets.campus_achievements' "$fallback_path" > "$ROOT_DIR/exports/04_campus_achievements/all.json"
        jq -r '.datasets.projects' "$fallback_path" > "$ROOT_DIR/exports/05_projects/all.json"
        jq -r '.datasets.campus_projects' "$fallback_path" > "$ROOT_DIR/exports/06_campus_projects/all.json"
        jq -r '.datasets.project_sessions' "$fallback_path" > "$ROOT_DIR/exports/07_project_sessions/all.json"
        jq -r '.datasets.coalitions' "$fallback_path" > "$ROOT_DIR/exports/08_coalitions/all.json"
        # Sync epoch markers from snapshot created_at if present
        local snapshot_created
        snapshot_created=$(jq -r '.created_at // empty' "$fallback_path")
        if [[ -n "$snapshot_created" ]]; then
          local snapshot_epoch
          snapshot_epoch=$(date -d "$snapshot_created" +%s 2>/dev/null || true)
          if [[ -n "$snapshot_epoch" ]]; then
            echo "$snapshot_epoch" > "$ROOT_DIR/exports/03_achievements/.last_fetch_epoch"
            echo "$snapshot_epoch" > "$ROOT_DIR/exports/04_campus_achievements/.last_fetch_epoch"
            metadata_epoch="$snapshot_epoch"
          fi
        fi
        log SUCCESS "Fallback metadata restored from $fallback_path"
        fetched=1
        fallback_used=1
      else
        log ERROR "Fallback restore failed (invalid JSON at $fallback_path)"
        return 1
      fi
    else
      log ERROR "No metadata available (fetch skipped/failed and fallback missing)"
      return 1
    fi
  fi

  # Load metadata into DB (cursus, campuses, projects, coalitions, campus achievements)
  local loaders=(
    "update_stable_tables/update_cursus.sh"
    "update_stable_tables/update_campuses.sh"
    "update_stable_tables/update_projects.sh"
    "update_stable_tables/update_coalitions.sh"
    "update_stable_tables/update_campus_achievements.sh"
  )
  for loader in "${loaders[@]}"; do
    if [[ ! -f "$SCRIPTS_DIR/$loader" ]]; then
      log WARN "Missing loader: $loader"
      continue
    fi
    local lstart=$(date +%s)
    if SKIP_FETCH=1 bash "$SCRIPTS_DIR/$loader" >> "$LOG_FILE" 2>&1; then
      local lend=$(date +%s)
      local dur=$((lend - lstart))
      log SUCCESS "Loaded via $loader (${dur}s)"
    else
      local lend=$(date +%s)
      local dur=$((lend - lstart))
      log WARN "Loader failed: $loader (${dur}s, likely due to missing/invalid exports)"
    fi
  done

  # If we restored from fallback, normalize ingested_at to the snapshot epoch for consistency
  if [[ "$fallback_used" -eq 1 && -n "$metadata_epoch" ]]; then
    local ts_sql="TO_TIMESTAMP(${metadata_epoch})"
    docker exec transcendence_db psql -U "${DB_USER:-api42}" -d "${DB_NAME:-api42}" -v ON_ERROR_STOP=1 -c "
      UPDATE cursus SET ingested_at = ${ts_sql};
      UPDATE campuses SET ingested_at = ${ts_sql};
      UPDATE projects SET ingested_at = ${ts_sql};
      UPDATE coalitions SET ingested_at = ${ts_sql};
      UPDATE campus_projects SET ingested_at = ${ts_sql};
      UPDATE project_sessions SET ingested_at = ${ts_sql};
      UPDATE achievements SET ingested_at = ${ts_sql};
      UPDATE campus_achievements SET ingested_at = ${ts_sql};
    " >> "$LOG_FILE" 2>&1 || log WARN "Failed to align ingested_at to snapshot epoch"
  fi
}

bootstrap_database() {
  local db_user="${DB_USER:-api42}"
  local db_name="${DB_NAME:-api42}"

  case "$BOOTSTRAP_MODE" in
    empty)
      log INFO "DB bootstrap mode=empty → loading existing exports if present"
      local default_json="$EXPORTS_DIR/08_users/all.json"
      if [[ -f "$default_json" ]]; then
        if bash "$SCRIPTS_DIR/update_stable_tables/update_users_simple.sh" >> "$LOG_FILE" 2>&1; then
          log SUCCESS "Loaded users from $default_json via update_users_simple.sh"
          return 0
        else
          log WARN "Users load from $default_json failed; continuing"
          return 0
        fi
      else
        log INFO "No $default_json found; skipping user load"
        return 0
      fi
      ;;
    raw|import)
      if [[ -z "$RAW_PATH" ]]; then
        log ERROR "ORCHESTRA_DB_RAW_PATH is required for raw mode"
        return 1
      fi
      if [[ ! -f "$RAW_PATH" ]]; then
        log ERROR "Raw file not found: $RAW_PATH"
        return 1
      fi
      if [[ "$RAW_PATH" == *.sql ]]; then
        log INFO "Loading raw SQL from $RAW_PATH into database"
        if cat "$RAW_PATH" | docker exec -i transcendence_db psql -U "$db_user" -d "$db_name" >> "$LOG_FILE" 2>&1; then
          log SUCCESS "Raw SQL loaded from $RAW_PATH"
          return 0
        else
          log ERROR "Raw SQL load failed"
          return 1
        fi
      else
        local dest_dir="$EXPORTS_DIR/08_users"
        local dest_file="$dest_dir/all.json"
        mkdir -p "$dest_dir"
        if cp "$RAW_PATH" "$dest_file"; then
          log INFO "Raw JSON copied to $dest_file"
          if bash "$SCRIPTS_DIR/update_stable_tables/update_users_simple.sh" >> "$LOG_FILE" 2>&1; then
            log SUCCESS "Raw JSON loaded into DB via update_users_simple.sh"
            return 0
          else
            log ERROR "Raw JSON load failed via update_users_simple.sh"
            return 1
          fi
        else
          log ERROR "Failed to copy raw JSON from $RAW_PATH"
          return 1
        fi
      fi
      ;;
    *)
      log WARN "Unknown bootstrap mode '$BOOTSTRAP_MODE', defaulting to empty (no load)"
      return 0
      ;;
  esac
}

# ============================================================================ #
#  FETCH USERS (CAMPUS-SPECIFIC)
# ============================================================================ #

fetch_campus_users() {
  local campus_id="$1"
  local output_file="$EXPORTS_DIR/09_users/campus_${campus_id}/all.json"
  
  mkdir -p "$(dirname "$output_file")"

  log INFO "📥 Fetching users for campus $campus_id..."

  # Call helper script to fetch from API
  # This script handles pagination, retries, and filtering
  if ! CAMPUS_ID="$campus_id" bash "$SCRIPTS_DIR/orchestrate/fetch_users.sh"; then
    log ERROR "Failed to fetch users for campus $campus_id"
    return 1
  fi
  
  # Verify output was created
  if [[ ! -f "$output_file" ]]; then
    log ERROR "Output file not created: $output_file"
    return 1
  fi
  
  local user_count=$(jq 'length' "$output_file" 2>/dev/null || echo "0")
  log SUCCESS "Fetched $user_count users for campus $campus_id"
  
  return 0
}

# ============================================================================ #
#  LOAD USERS TO DATABASE
# ============================================================================ #

load_users_to_db() {
  local campus_id="$1"
  local input_file="$EXPORTS_DIR/09_users/campus_${campus_id}/all.json"
  
  log INFO "📤 Loading users to database for campus $campus_id..."
  
  # Call helper script to load and upsert
  if ! CAMPUS_ID="$campus_id" bash "$SCRIPTS_DIR/update_stable_tables/update_users_campus.sh"; then
    log ERROR "Failed to load users for campus $campus_id"
    return 1
  fi
  
  log SUCCESS "Users loaded for campus $campus_id"
  return 0
}

# ============================================================================ #
#  MAIN ORCHESTRATION FLOW
# ============================================================================ #

main() {
  local exit_code=0
  local orchestration_start=$(date +%s)
  
  frame ""
  frame "╔════════════════════════════════╗"
  frame "║ INIT                           ║"
  frame "╚════════════════════════════════╝"
  docker_status
  if bash "$SCRIPTS_DIR/orchestrate/init_db.sh" >> "$LOG_FILE" 2>&1; then
    log SUCCESS "Init DB completed"
  else
    log ERROR "Init DB failed"
    return 1
  fi
  
  frame ""
  frame "╔════════════════════════════════╗"
  frame "║ API                            ║"
  frame "╚════════════════════════════════╝"
  # 1. Load and validate token
  if ! load_token; then
    log ERROR "Token validation failed"
    return 1
  fi
  
  # 2. Refresh token directly and log TTL
  if ! refresh_token_now; then
    log ERROR "Token refresh failed"
    return 1
  fi
  if [[ "$API_HEALTH_CHECK" == "1" ]]; then
    if ! check_api_health; then
      return 1
    fi
  else
    log INFO "API health check skipped (ORCHESTRA_API_HEALTH_CHECK=0)"
  fi

  frame ""
  frame "╔════════════════════════════════╗"
  frame "║ METADATA                       ║"
  frame "╚════════════════════════════════╝"
  local metadata_start=$(date +%s)
  # 3. Always refresh stable metadata exports
  if ! ensure_metadata_exports; then
    log ERROR "Metadata step failed"
    return 1
  fi
  local metadata_end=$(date +%s)

  # 4. Bootstrap database according to mode
  frame ""
  frame "╔════════════════════════════════╗"
  frame "║ BOOTSTRAP                      ║"
  frame "╚════════════════════════════════╝"
  local bootstrap_start=$(date +%s)
  if ! bootstrap_database; then
    log ERROR "Database bootstrap failed"
    return 1
  fi
  local bootstrap_end=$(date +%s)
 
  # Database already validated by init_db.sh, skip redundant check
  # if ! validate_database; then
  #   log ERROR "Database validation failed"
  #   return 1
  # fi
  
  # 4. Tables already created and verified by init_db.sh
  # Skip redundant validation to avoid timeouts
  # for table in users cursus campuses; do
  #   if ! validate_table_exists "$table"; then
  #     log ERROR "Required table missing: $table"
  #     return 1
  #   fi
  # done
  
  db_counts
  if [[ "$DB_CHECK_BYPASS" == "1" ]]; then
    log WARN "DB integrity check skipped (ORCHESTRA_DB_CHECK_BYPASS=1)"
  else
    run_db_check
  fi
  start_worker
  
if [[ $exit_code -eq 0 ]]; then
  frame ""
  frame "═══════════════════════════════════════════════════════════════"
  log SUCCESS "Orchestra cycle complete"
  frame "═══════════════════════════════════════════════════════════════"
else
  frame ""
  frame "═══════════════════════════════════════════════════════════════"
  log ERROR "Orchestra cycle FAILED"
  log ERROR "Check logs: $LOG_FILE"
  frame "═══════════════════════════════════════════════════════════════"
fi

  return $exit_code
}

# ============================================================================ #
#  EXECUTION
# ============================================================================ #

main "$@"
exit $?
