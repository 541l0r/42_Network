#!/bin/bash
# ============================================================================ #
#  orchestra.sh - Main orchestration controller for live user tracking
#
#  Purpose: Coordinate fetching and loading of campus-specific user data
#  
#  Usage:
#    CAMPUS_ID=76 bash scripts/orchestrate/orchestra.sh
#    CAMPUS_ID=12 bash scripts/orchestrate/orchestra.sh --dry-run
#
#  Environment variables:
#    CAMPUS_ID        - Campus to sync (default: ORCHESTRA_DEFAULT_CAMPUS_ID or 76)
#    POLL_INTERVAL    - Milliseconds between syncs (default: 60000 = 1 min)
#    --dry-run        - Show what would be fetched without saving
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
SKIP_METADATA_FETCH="${ORCHESTRA_SKIP_METADATA_FETCH:-0}"

# Fallbacks if values are present but empty
if [[ -z "$BOOTSTRAP_MODE" ]]; then
  BOOTSTRAP_MODE="empty"
fi
if [[ -z "$RAW_PATH" ]]; then
  RAW_PATH="/srv/42_Network/phase2_users_v2_all.json"
fi
if [[ -z "$SKIP_METADATA_FETCH" ]]; then
  SKIP_METADATA_FETCH="0"
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

# Parse arguments
DRY_RUN=0
FULL_CYCLE=0
TEST_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=1 ;;
    --full-cycle)   FULL_CYCLE=1 ;;
    --test)         TEST_MODE=1; DRY_RUN=1 ;;  # Test mode implies dry-run
    *)              log ERROR "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

# Load campus ID from environment (set by deploy)
CAMPUS_ID="${CAMPUS_ID:-$DEFAULT_CAMPUS_ID}"
CAMPUS_ID=$(echo "$CAMPUS_ID" | sed 's/"//g')  # Strip quotes

# ============================================================================ #
#  TEST MODE: Ensure environment is ready
# ============================================================================ #

if [[ $TEST_MODE -eq 1 ]]; then
  log INFO "TEST MODE: Ensuring docker and database are ready..."
  
  if ! docker ps | grep -q transcendence_db; then
    log INFO "Starting docker-compose..."
    docker compose -f "$ROOT_DIR/docker-compose.yml" up -d
    sleep 5
  fi
  
  # Create delta_users table if it doesn't exist
  DB_USER="${DB_USER:-api42}"
  DB_NAME="${DB_NAME:-api42}"
  if ! docker exec transcendence_db psql -U "$DB_USER" -d "$DB_NAME" -c "\dt delta_users" 2>/dev/null | grep -q delta_users; then
    log INFO "Creating delta_users table..."
    docker exec transcendence_db psql -U "$DB_USER" -d "$DB_NAME" << 'EOSQL'
CREATE TABLE IF NOT EXISTS delta_users (
  id SERIAL PRIMARY KEY,
  user_id INTEGER UNIQUE NOT NULL,
  email VARCHAR(255),
  first_name VARCHAR(255),
  last_name VARCHAR(255),
  phone VARCHAR(20),
  image_url TEXT,
  displayname VARCHAR(255),
  pool_month VARCHAR(50),
  pool_year INTEGER,
  location VARCHAR(255),
  wallet INTEGER,
  correction_point INTEGER,
  level NUMERIC(5,2),
  campus_id INTEGER NOT NULL,
  cursus_id INTEGER NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE,
  updated_at TIMESTAMP WITH TIME ZONE
);
EOSQL
    log SUCCESS "delta_users table created"
  fi
fi

frame "╔════════════════════════════════╗"
frame "║ RUN INFO                       ║"
frame "╚════════════════════════════════╝"
frame "  Campus    : $CAMPUS_ID (default $DEFAULT_CAMPUS_ID)"
frame "  Bootstrap : $BOOTSTRAP_MODE"
frame "  Dry run   : $([[ $DRY_RUN -eq 1 ]] && echo 'YES' || echo 'NO')"
frame "  Log       : $LOG_FILE"
frame "  Config    : $CONFIG_FILE"
frame "  Metadata  : skip=$ORCHESTRA_SKIP_METADATA_FETCH"

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
  local start=$(date +%s)
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://api.intra.42.fr/v2/cursus/21")
  local end=$(date +%s)
  local duration=$((end - start))
  if [[ "$code" == "200" ]]; then
    log SUCCESS "API health OK (GET /v2/cursus/21 -> 200 in ${duration}s)"
  else
    log ERROR "API health check failed (status=$code, duration=${duration}s)"
    return 1
  fi
}

db_counts() {
  # spacer
  frame ""
  frame "╔════════════════════════════════╗"
  frame "║ DB STATUS                      ║"
  frame "╚════════════════════════════════╝"
  local tables=("users" "campuses" "projects" "coalitions" "achievements" "project_users" "campus_projects" "project_sessions")
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
  if [[ "$SKIP_METADATA_FETCH" == "1" ]]; then
    log INFO "Metadata fetch skipped (ORCHESTRA_SKIP_METADATA_FETCH=1)"
    return 0
  fi
  log INFO "Metadata fetch (independent of user bootstrap)"
  if SKIP_TOKEN_REFRESH=1 bash "$SCRIPTS_DIR/orchestrate/fetch_metadata.sh" | tee -a "$LOG_FILE"; then
    log SUCCESS "Metadata fetched to exports/ (see per-page logs above)"
  else
    log ERROR "Metadata fetch failed"
    return 1
  fi
}

bootstrap_database() {
  local db_user="${DB_USER:-api42}"
  local db_name="${DB_NAME:-api42}"

  case "$BOOTSTRAP_MODE" in
    empty)
      log INFO "DB bootstrap mode=empty → loading existing exports if present"
      local default_json="$EXPORTS_DIR/08_users/all.json"
      if [[ $DRY_RUN -eq 1 ]]; then
        log INFO "[DRY RUN] Would load $default_json into DB (if present)"
        return 0
      fi
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
        if [[ $DRY_RUN -eq 1 ]]; then
          log INFO "[DRY RUN] Would import raw JSON from $RAW_PATH to $dest_file and load into DB"
          return 0
        fi
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
  
  if [[ $DRY_RUN -eq 1 ]]; then
    log INFO "[DRY RUN] Would fetch: /v2/cursus/21/cursus_users?campus_id=$campus_id"
    mkdir -p "$(dirname "$output_file")"
    echo '[]' > "$output_file"
    return 0
  fi
  
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
  
  if [[ $DRY_RUN -eq 1 ]]; then
    log INFO "[DRY RUN] Would load users from $input_file"
    return 0
  fi
  
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
  if ! check_api_health; then
    return 1
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
