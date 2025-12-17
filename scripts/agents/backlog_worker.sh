#!/bin/bash

# backlog_worker.sh - Processes user IDs from backlog
# For each user ID:
#   1. Fetches achievements_users
#   2. Fetches projects_users
#   3. Fetches coalitions_users
# Saves to DB and clears backlog

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Attempt to load campus filter from config or .env
if [[ -f "$ROOT_DIR/../.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/../.env"
fi
PATH="$ROOT_DIR/scripts/bin:$PATH"
AGENTS_CONFIG="$ROOT_DIR/scripts/config/agents.config"
if [[ -z "${CAMPUS_ID:-}" && -f "$AGENTS_CONFIG" ]]; then
  CAMPUS_ID=$(grep -E '^\s*CAMPUS_ID=' "$AGENTS_CONFIG" | head -1 | cut -d= -f2 | tr -d '"')
fi
# If DRY_RUN not provided, allow agents.config to define a default (e.g., DRY_RUN=1)
if [[ -z "${DRY_RUN:-}" && -f "$AGENTS_CONFIG" ]]; then
  DRY_RUN=$(grep -E '^\s*DRY_RUN=' "$AGENTS_CONFIG" | head -1 | cut -d= -f2 | tr -d '"')
fi
# Allow rate limit delay override from agents.config
if [[ -z "${RATE_LIMIT_DELAY:-}" && -f "$AGENTS_CONFIG" ]]; then
  RATE_LIMIT_DELAY=$(grep -E '^\s*RATE_LIMIT_DELAY=' "$AGENTS_CONFIG" | head -1 | cut -d= -f2 | tr -d '"')
fi
RATE_LIMIT_DELAY="${RATE_LIMIT_DELAY:-6}"  # seconds between API calls to stay under limits (1000 calls/hour = 3.6s min; 6s = 600 calls/hour)

rate_limit_pause() {
  sleep "${RATE_LIMIT_DELAY}"
}

pop_next_user_id() {
  # Consume and remove the first ID from the backlog file under a lock
  touch "$BACKLOG_FILE"
  local id=""
  # Use fd 9 for locking this function only
  exec 9<>"$BACKLOG_FILE" || return
  flock -x 9
  id=$(head -n1 "$BACKLOG_FILE")
  if [[ -n "$id" ]]; then
    tail -n +2 "$BACKLOG_FILE" > "${BACKLOG_FILE}.tmp" && mv "${BACKLOG_FILE}.tmp" "$BACKLOG_FILE"
  fi
  flock -u 9
  exec 9>&-
  echo "$id"
}

BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/backlog_worker.log"
BACKLOG_FILE="$BACKLOG_DIR/pending_users.txt"
BASE_URL="https://api.intra.42.fr/v2"
CAMPUS_FILTER_RAW="${CAMPUS_FILTER:-${CAMPUS_ID:-}}"
CAMPUS_FILTER="$(echo "${CAMPUS_FILTER_RAW:-}" | tr -d '\"' | xargs)"  # If set and not ALL, only process matching campus_id
EXPORTS_USERS="$ROOT_DIR/exports/09_users"
EXPORTS_PROJECT_USERS="$ROOT_DIR/exports/10_projects_users"
EXPORTS_ACHIEVEMENTS_USERS="$ROOT_DIR/exports/11_achievements_users"
EXPORTS_COALITIONS_USERS="$ROOT_DIR/exports/12_coalitions_users"
DRY_RUN="${DRY_RUN:-0}"

# DB config
get_conf_val() {
  local key="$1"
  [[ -f "$AGENTS_CONFIG" ]] || return
  grep -E "^\s*${key}=" "$AGENTS_CONFIG" | head -1 | cut -d= -f2 | tr -d '"'
}

# Load DB defaults from agents.config, then allow env/.env to override if explicitly set
DB_HOST_CFG=$(get_conf_val "DB_HOST" || true)
DB_PORT_CFG=$(get_conf_val "DB_PORT" || true)
DB_USER_CFG=$(get_conf_val "DB_USER" || true)
DB_NAME_CFG=$(get_conf_val "DB_NAME" || true)
DB_PASSWORD_CFG=$(get_conf_val "DB_PASSWORD" || true)

# Prefer config values when present to avoid stale env pointing to wrong DB
DB_HOST="${DB_HOST_CFG:-${DB_HOST:-}}"
DB_PORT="${DB_PORT_CFG:-${DB_PORT:-}}"
DB_USER="${DB_USER_CFG:-${DB_USER:-}}"
DB_NAME="${DB_NAME_CFG:-${DB_NAME:-}}"
DB_PASSWORD="${DB_PASSWORD_CFG:-${DB_PASSWORD:-}}"

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-api42}"
DB_NAME="${DB_NAME:-api42}"
DB_PASSWORD="${DB_PASSWORD:-api42}"

mkdir -p "$BACKLOG_DIR" "$LOG_DIR" "$EXPORTS_USERS" "$EXPORTS_PROJECT_USERS" "$EXPORTS_ACHIEVEMENTS_USERS" "$EXPORTS_COALITIONS_USERS"

trap 'log_msg "Worker stopping"' EXIT

log_msg() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG_FILE"
}

json_count() {
  echo "$1" | jq 'length' 2>/dev/null || echo "0"
}

fetch_user_json() {
  local user_id="$1"
  local attempts=0
  local max_attempts=2
  while (( attempts <= max_attempts )); do
    rate_limit_pause
    local response
    response=$(curl -s --connect-timeout 5 --max-time 15 -w "\n%{http_code}" -H "Authorization: Bearer $API_TOKEN" "$BASE_URL/users/$user_id" 2>/dev/null || true)
    local status
    status=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | head -n -1)
    if [[ "$status" == "429" ]]; then
      log_msg "WARN user $user_id fetch returned HTTP 429 (rate limit), retrying..."
      attempts=$((attempts + 1))
      sleep "$RATE_LIMIT_DELAY"
      continue
    elif [[ "$status" == "403" ]]; then
      log_msg "WARN user $user_id fetch returned HTTP 403 (forbidden), backing off"
      attempts=$((attempts + 1))
      sleep "$RATE_LIMIT_DELAY"
      continue
    elif [[ "$status" != "200" ]]; then
      log_msg "WARN user $user_id fetch returned HTTP $status"
    elif echo "$body" | jq empty >/dev/null 2>&1; then
      echo "$body"
      return 0
    else
      log_msg "WARN user $user_id invalid JSON payload"
    fi
    attempts=$((attempts + 1))
    [[ $attempts -le $max_attempts ]] && sleep "$RATE_LIMIT_DELAY"
  done
  echo ""
}

get_campus_from_json() {
  local json="$1"
  if ! echo "$json" | jq empty >/dev/null 2>&1; then
    echo "0"
    return
  fi
  local campus_primary
  local campus_any
  campus_primary=$(echo "$json" | jq '(.campus_users[]? | select(.is_primary==true) | .campus_id) // empty' | head -n1)
  campus_any=$(echo "$json" | jq '(.campus_users[]? | .campus_id) // empty' | head -n1)
  local cid="${campus_primary:-$campus_any}"
  [[ -z "$cid" ]] && cid="0"
  echo "$cid"
}

fetch_relation_json() {
  local url="$1"
  local label="$2"
  # Curl with status appended on last line
  local response
  rate_limit_pause
  response=$(curl -s --connect-timeout 5 --max-time 20 -w "\n%{http_code}" -H "Authorization: Bearer $API_TOKEN" "$url" 2>/dev/null || true)
  local status
  status=$(echo "$response" | tail -n1)
  local body
  body=$(echo "$response" | head -n -1)
  if [[ "$status" == "429" ]]; then
    log_msg "WARN $label fetch returned HTTP 429 (rate limit), retrying..."
  fi
  if [[ "$status" != "200" ]]; then
    log_msg "WARN $label fetch returned HTTP $status"
    echo "[]"
    return 0
  fi
  # Validate JSON
  if ! echo "$body" | jq empty >/dev/null 2>&1; then
    log_msg "WARN $label invalid JSON"
    echo "[]"
    return 0
  fi
  echo "$body"
}

upsert_user() {
  local user_json="$1"
  local user_id="$2"
  local campus_primary
  local campus_any
  campus_primary=$(echo "$user_json" | jq '(.campus_users[]? | select(.is_primary==true) | .campus_id) // empty' | head -n1)
  campus_any=$(echo "$user_json" | jq '(.campus_users[]? | .campus_id) // empty' | head -n1)
  local campus_id="${campus_primary:-$campus_any}"
  if [[ -z "$campus_id" ]]; then
    campus_id="0"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_msg "DRY_RUN user ${user_id}: would upsert (campus ${campus_id})"
    echo "$campus_id"
    return 0
  fi

  local campus_id
  local campus_primary
  local campus_any
  campus_primary=$(echo "$user_json" | jq '(.campus_users[]? | select(.is_primary==true) | .campus_id) // empty' | head -n1)
  campus_any=$(echo "$user_json" | jq '(.campus_users[]? | .campus_id) // empty' | head -n1)
  campus_id="${campus_primary:-$campus_any}"
  if [[ -z "$campus_id" ]]; then
    log_msg "WARN user has no campus_id, skipping"
    echo "0"
    return 1
  fi

  # Build CSV for delta_users (matches existing schema)
  local csv
  csv=$(echo "$user_json" | jq -r '
    def nullize_empty(v): if (v // "" | tostring) == "" then null else v end;
    [
      (.id // 0),
      (.email // ""),
      (.login // ""),
      (.first_name // ""),
      (.last_name // ""),
      (.usual_full_name // ""),
      (.usual_first_name // ""),
      (.displayname // ""),
      (.kind // ""),
      (if .staff? then "t" else "f" end),
      (.correction_point // 0),
      (.pool_month // ""),
      (.pool_year // ""),
      (.location // ""),
      (.wallet // 0),
      (.phone // ""),
      nullize_empty(.anonymize_date),
      nullize_empty(.data_erasure_date),
      (.created_at // ""),
      (.updated_at // ""),
      nullize_empty(.alumnized_at),
      (if .alumni? then "t" else "f" end),
      (if .active? then "t" else "f" end),
      (.image.link // ""),
      (.image.versions.large // ""),
      (.image.versions.medium // ""),
      (.image.versions.small // ""),
      (.image.versions.micro // ""),
      (.url // "")
    ] | @csv
  ')

  # Copy into delta_users and upsert (suppress SQL debug output)
  if ! PGCONNECT_TIMEOUT=5 PGOPTIONS='-c statement_timeout=15000' PGPASSWORD="$DB_PASSWORD" psql -w -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "CREATE TABLE IF NOT EXISTS delta_users_stage (LIKE delta_users INCLUDING DEFAULTS);" >/dev/null 2>&1; then
    log_msg "WARN upsert_user ${user_id}: failed to create delta_users_stage"
    return 1
  fi
  if ! PGCONNECT_TIMEOUT=5 PGOPTIONS='-c statement_timeout=15000' PGPASSWORD="$DB_PASSWORD" psql -w -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "TRUNCATE delta_users_stage;" >/dev/null 2>&1; then
    log_msg "WARN upsert_user ${user_id}: failed to prepare delta_users_stage"
    return 1
  fi

  echo "$csv" | PGCONNECT_TIMEOUT=5 PGOPTIONS='-c statement_timeout=20000' PGPASSWORD="$DB_PASSWORD" psql -w -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "\copy delta_users_stage (
      id, email, login, first_name, last_name, usual_full_name, usual_first_name, displayname, kind, staff, correction_point,
      pool_month, pool_year, location, wallet, phone, anonymize_date, data_erasure_date, created_at, updated_at,
      alumnized_at, alumni, active, image_link, image_large, image_medium, image_small, image_micro, url
    ) FROM STDIN WITH (FORMAT csv, NULL '')" >/dev/null 2>&1 || {
      log_msg "WARN upsert_user ${user_id}: failed to copy into delta_users_stage"
      return 1
    }

  PGCONNECT_TIMEOUT=5 PGOPTIONS='-c statement_timeout=20000' PGPASSWORD="$DB_PASSWORD" psql -w -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<EOSQL >/dev/null 2>&1
INSERT INTO users (
  id, email, login, first_name, last_name, usual_full_name,
  usual_first_name, kind, displayname, staff_p, correction_point,
  pool_month, pool_year, location, wallet, phone, anonymize_date,
  data_erasure_date, created_at, updated_at, alumnized_at, alumni_p,
  active_p, image_link, image_large, image_medium, image_small, image_micro,
  url, ingested_at
)
SELECT
  d.id, d.email, d.login, d.first_name, d.last_name, d.usual_full_name,
  d.usual_first_name, d.kind, d.displayname, d.staff,
  d.correction_point, d.pool_month, d.pool_year, d.location,
  d.wallet, d.phone, d.anonymize_date, d.data_erasure_date,
  d.created_at, d.updated_at, d.alumnized_at, d.alumni, d.active,
  d.image_link, d.image_large, d.image_medium, d.image_small, d.image_micro,
  d.url, NOW()
FROM delta_users_stage d
ON CONFLICT (id) DO UPDATE SET
  email = EXCLUDED.email,
  login = EXCLUDED.login,
  first_name = EXCLUDED.first_name,
  last_name = EXCLUDED.last_name,
  usual_full_name = EXCLUDED.usual_full_name,
  usual_first_name = EXCLUDED.usual_first_name,
  kind = EXCLUDED.kind,
  displayname = EXCLUDED.displayname,
  staff_p = EXCLUDED.staff_p,
  correction_point = EXCLUDED.correction_point,
  pool_month = EXCLUDED.pool_month,
  pool_year = EXCLUDED.pool_year,
  location = EXCLUDED.location,
  wallet = EXCLUDED.wallet,
  phone = EXCLUDED.phone,
  anonymize_date = EXCLUDED.anonymize_date,
  data_erasure_date = EXCLUDED.data_erasure_date,
  created_at = EXCLUDED.created_at,
  updated_at = EXCLUDED.updated_at,
  alumnized_at = EXCLUDED.alumnized_at,
  alumni_p = EXCLUDED.alumni_p,
  active_p = EXCLUDED.active_p,
  image_link = EXCLUDED.image_link,
  image_large = EXCLUDED.image_large,
  image_medium = EXCLUDED.image_medium,
  image_small = EXCLUDED.image_small,
  image_micro = EXCLUDED.image_micro,
  url = EXCLUDED.url,
  ingested_at = NOW();
EOSQL
  upsert_rc=$?
  if [[ $upsert_rc -ne 0 ]]; then
    log_msg "WARN upsert_user ${user_id}: failed to insert into users (rc=$upsert_rc)"
    return 1
  fi

  log_msg "✓ Upserted user ${user_id} (campus ${campus_id})"

  # return campus_id for downstream use
  echo "$campus_id"
}

upsert_projects_users() {
  local projects_json="$1"
  local campus_id="$2"
  local user_id="$3"
  local tmpfile
  tmpfile=$(mktemp)

  if [[ "$DRY_RUN" == "1" ]]; then
    log_msg "DRY_RUN projects_users for user ${user_id} (campus ${campus_id}) count=$(echo "$projects_json" | jq 'length')"
    rm -f "$tmpfile"
    return 0
  fi

  echo "$projects_json" | jq -r --arg campus_id "$campus_id" '
    .[] | [
      (.id // 0),
      (.project.id // 0),
      (.campus_id // ($campus_id|tonumber)),
      (.user.id // 0),
      (.user.login // ""),
      (.user.email // ""),
      (.final_mark // null),
      (.status // ""),
      (if .validated? then "t" else "f" end),
      (.created_at // ""),
      (.updated_at // "")
    ] | @csv
  ' > "$tmpfile"

  if [[ ! -s "$tmpfile" ]]; then
    rm -f "$tmpfile"
    return 0
  fi

  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<'EOSQL' >/dev/null 2>&1
DROP TABLE IF EXISTS project_users_stage;
CREATE TEMP TABLE project_users_stage (LIKE project_users INCLUDING DEFAULTS);
EOSQL

  cat "$tmpfile" | PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "\copy project_users_stage (id, project_id, campus_id, user_id, user_login, user_email, final_mark, status, validated, created_at, updated_at) FROM STDIN WITH (FORMAT csv, NULL '')" >/dev/null 2>&1

  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<'EOSQL' >/dev/null 2>&1
INSERT INTO project_users (id, project_id, campus_id, user_id, user_login, user_email, final_mark, status, validated, created_at, updated_at, ingested_at)
SELECT id, project_id, campus_id, user_id, user_login, user_email, final_mark, status, validated, created_at, updated_at, NOW()
FROM project_users_stage
ON CONFLICT (id) DO UPDATE SET
  project_id = EXCLUDED.project_id,
  campus_id = EXCLUDED.campus_id,
  user_id = EXCLUDED.user_id,
  user_login = EXCLUDED.user_login,
  user_email = EXCLUDED.user_email,
  final_mark = EXCLUDED.final_mark,
  status = EXCLUDED.status,
  validated = EXCLUDED.validated,
  created_at = EXCLUDED.created_at,
  updated_at = EXCLUDED.updated_at,
  ingested_at = NOW();
EOSQL

  rm -f "$tmpfile"
  log_msg "✓ Upserted projects_users for user ${user_id}"
}

upsert_achievements_users() {
  local ach_json="$1"
  local campus_id="$2"
  local user_id="$3"
  local tmpfile
  tmpfile=$(mktemp)

  if [[ "$DRY_RUN" == "1" ]]; then
    log_msg "DRY_RUN achievements_users for user ${user_id} (campus ${campus_id}) count=$(echo "$ach_json" | jq 'length')"
    rm -f "$tmpfile"
    return 0
  fi

  echo "$ach_json" | jq -r --arg campus_id "$campus_id" '
    .[] | [
      (.id // 0),
      (.achievement.id // 0),
      (.campus_id // ($campus_id|tonumber)),
      (.user.id // 0),
      (.user.login // ""),
      (.user.email // ""),
      (.created_at // ""),
      (.updated_at // "")
    ] | @csv
  ' > "$tmpfile"

  if [[ ! -s "$tmpfile" ]]; then
    rm -f "$tmpfile"
    return 0
  fi

  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<'EOSQL' >/dev/null 2>&1
DROP TABLE IF EXISTS achievements_users_stage;
CREATE TEMP TABLE achievements_users_stage (LIKE achievements_users INCLUDING DEFAULTS);
EOSQL

  cat "$tmpfile" | PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "\copy achievements_users_stage (id, achievement_id, campus_id, user_id, user_login, user_email, created_at, updated_at) FROM STDIN WITH (FORMAT csv, NULL '')" >/dev/null 2>&1

  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<'EOSQL' >/dev/null 2>&1
INSERT INTO achievements_users (id, achievement_id, campus_id, user_id, user_login, user_email, created_at, updated_at, ingested_at)
SELECT id, achievement_id, campus_id, user_id, user_login, user_email, created_at, updated_at, NOW()
FROM achievements_users_stage
ON CONFLICT (id) DO UPDATE SET
  achievement_id = EXCLUDED.achievement_id,
  campus_id = EXCLUDED.campus_id,
  user_id = EXCLUDED.user_id,
  user_login = EXCLUDED.user_login,
  user_email = EXCLUDED.user_email,
  created_at = EXCLUDED.created_at,
  updated_at = EXCLUDED.updated_at,
  ingested_at = NOW();
EOSQL

  rm -f "$tmpfile"
  log_msg "✓ Upserted achievements_users for user ${user_id}"
}

upsert_coalitions_users() {
  local coal_json="$1"
  local campus_id="$2"
  local user_id="$3"
  local tmpfile
  tmpfile=$(mktemp)

  if [[ "$DRY_RUN" == "1" ]]; then
    log_msg "DRY_RUN coalitions_users for user ${user_id} (campus ${campus_id}) count=$(echo "$coal_json" | jq 'length')"
    rm -f "$tmpfile"
    return 0
  fi

  echo "$coal_json" | jq -r --arg campus_id "$campus_id" '
    .[] | [
      (.id // 0),
      (.coalition.id // 0),
      (.user.id // 0),
      (.score // 0),
      (.rank // null),
      (.campus_id // ($campus_id|tonumber)),
      (.created_at // ""),
      (.updated_at // "")
    ] | @csv
  ' > "$tmpfile"

  if [[ ! -s "$tmpfile" ]]; then
    rm -f "$tmpfile"
    return 0
  fi

  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<'EOSQL' >/dev/null 2>&1
DROP TABLE IF EXISTS coalitions_users_stage;
CREATE TEMP TABLE coalitions_users_stage (LIKE coalitions_users INCLUDING DEFAULTS);
EOSQL

  cat "$tmpfile" | PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "\copy coalitions_users_stage (id, coalition_id, user_id, score, rank, campus_id, created_at, updated_at) FROM STDIN WITH (FORMAT csv, NULL '')" >/dev/null 2>&1

  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<'EOSQL' >/dev/null 2>&1
INSERT INTO coalitions_users (id, coalition_id, user_id, score, rank, campus_id, created_at, updated_at, ingested_at)
SELECT id, coalition_id, user_id, score, rank, campus_id, created_at, updated_at, NOW()
FROM coalitions_users_stage
ON CONFLICT (id) DO UPDATE SET
  coalition_id = EXCLUDED.coalition_id,
  user_id = EXCLUDED.user_id,
  score = EXCLUDED.score,
  rank = EXCLUDED.rank,
  campus_id = EXCLUDED.campus_id,
  created_at = EXCLUDED.created_at,
  updated_at = EXCLUDED.updated_at,
  ingested_at = NOW();
EOSQL

  rm -f "$tmpfile"
  log_msg "✓ Upserted coalitions_users for user ${user_id}"
}

diff_user_changes() {
  local user_id="$1"
  local campus_id="$2"
  local new_json="$3"
  local old_path="$EXPORTS_USERS/campus_${campus_id}/user_${user_id}.json"

  if [[ ! -f "$old_path" ]]; then
    log_msg "DIFF user ${user_id}: new (no previous snapshot)"
    return
  fi

  if ! echo "$new_json" | jq empty >/dev/null 2>&1; then
    log_msg "DIFF user ${user_id}: skipped (invalid JSON)"
    return
  fi

  local diff_keys
  diff_keys=$(jq -r --slurp '
    def scrub(u): u | del(.updated_at, .alumnized_at, .created_at, .anonymize_date, .data_erasure_date);
    (.[0] // {}) as $old | (.[1] // {}) as $new
    | ($old + $new) | keys[]
    | select((($old[.] // null) != ($new[.] // null)))
  ' "$old_path" <(printf '%s' "$new_json") | sort -u | paste -sd, -)

  if [[ -n "$diff_keys" ]]; then
    log_msg "DIFF user ${user_id}: changed fields=${diff_keys}"
  else
    log_msg "DIFF user ${user_id}: no changes"
  fi
}

get_db_user_fields() {
  local user_id="$1"
  local out
  if ! out=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At -c "SELECT row_to_json(t) FROM (SELECT email,login,first_name,last_name,usual_full_name,usual_first_name,displayname,kind,correction_point,pool_month,pool_year,location,wallet,phone,anonymize_date,data_erasure_date,created_at,updated_at,alumnized_at,alumni_p,active_p,image_link,image_large,image_medium,image_small,image_micro,url FROM users WHERE id=${user_id} LIMIT 1) t;" 2>/dev/null); then
    log_msg "WARN DB query failed for user ${user_id} (host=$DB_HOST port=$DB_PORT db=$DB_NAME user=$DB_USER)"
    echo ""
    return
  fi
  echo "$out"
}

compare_api_vs_db_json() {
  local user_id="$1"
  local api_json="$2"

  # Extract same fields from DB as we track in log_db_delta
  local db_json
  db_json=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At \
    -c "SELECT row_to_json(row) FROM (SELECT 
      email, login, first_name, last_name, usual_full_name, usual_first_name, 
      displayname, kind, correction_point, pool_month, pool_year, location, 
      wallet, phone, alumni_p as \"alumni?\", active_p as \"active?\", staff_p as \"staff?\"
      FROM users WHERE id=$user_id) row;" 2>/dev/null || echo "{}")
  
  # Extract same fields from API JSON
  local api_fields
  api_fields=$(echo "$api_json" | jq -c '{
    email: .email,
    login: .login,
    first_name: .first_name,
    last_name: .last_name,
    usual_full_name: .usual_full_name,
    usual_first_name: .usual_first_name,
    displayname: .displayname,
    kind: .kind,
    correction_point: .correction_point,
    pool_month: .pool_month,
    pool_year: .pool_year,
    location: .location,
    wallet: .wallet,
    phone: .phone,
    "alumni?": (.["alumni?"] // .alumni // false),
    "active?": (.["active?"] // .active // false),
    "staff?": (.staff // false)
  }' 2>/dev/null)

  # Compare: if they're identical, user hasn't changed
  if [[ "$db_json" == "$api_fields" ]]; then
    return 0  # identical (no change)
  else
    return 1  # different (needs update)
  fi
}

log_db_delta() {
  local user_id="$1"
  local campus_id="$2"
  local new_json="$3"

  # For new users, no DB comparison needed
  local db_exists=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At \
    -c "SELECT COUNT(*) FROM users WHERE id=$user_id" 2>/dev/null || echo "0")
  
  if [[ "$db_exists" -eq 0 ]]; then
    # New user - no DB to compare against
    log_msg "✓ UPSERTED user ${user_id} (new user)"
    
    # Just show validated counts
    local proj_count ach_count
    proj_count=$(echo "$new_json" | jq '[.projects_users[]? | select(.status=="finished")] | length' 2>/dev/null || echo "0")
    ach_count=$(echo "$new_json" | jq '[.achievements_users[]? | select(.validated=="true" or .validated==true)] | length' 2>/dev/null || echo "0")
    
    if [[ "$proj_count" -gt 0 || "$ach_count" -gt 0 ]]; then
      log_msg "        🎯 VALIDATED: projects=$proj_count, achievements=$ach_count"
    fi
    return
  fi

  # User exists - compare changes (only DB query here)
  local new_fields
  new_fields=$(echo "$new_json" | jq -c --arg campus "$campus_id" '{
    email: .email,
    login: .login,
    first_name: .first_name,
    last_name: .last_name,
    usual_full_name: .usual_full_name,
    usual_first_name: .usual_first_name,
    displayname: .displayname,
    kind: .kind,
    correction_point: .correction_point,
    pool_month: .pool_month,
    pool_year: .pool_year,
    location: .location,
    wallet: .wallet,
    phone: .phone,
    alumni_p: (.["alumni?"] // .alumni // false),
    active_p: (.["active?"] // .active // false),
    campus_id: ($campus|tonumber)
  }' 2>/dev/null)

  local db_json
  db_json=$(get_db_user_fields "$user_id")
  if [[ -z "$db_json" || "$db_json" == "null" ]]; then
    log_msg "✓ UPSERTED user ${user_id} (new user)"
    return
  fi

  local diff_keys diff_detail
  read -r diff_keys diff_detail <<<"$(python3 - <<'PY'
import json, os, sys
try:
    db_json_str = os.environ.get("DB_JSON", "{}")
    new_json_str = os.environ.get("NEW_JSON", "{}")
    if not db_json_str or db_json_str == "null":
        db_json_str = "{}"
    if not new_json_str or new_json_str == "null":
        new_json_str = "{}"
    db = json.loads(db_json_str)
    new = json.loads(new_json_str)
    keys = sorted(set(db.keys()) | set(new.keys()))
    changes = []
    details = []
    def fmt(v):
        if v is None:
            return "null"
        if isinstance(v, bool):
            return "true" if v else "false"
        return str(v)
    for k in keys:
        if db.get(k) != new.get(k):
            changes.append(k)
            details.append(f"{k}:{fmt(db.get(k))}->{fmt(new.get(k))}")
    print(",".join(changes), ";".join(details))
except Exception as e:
    print("", f"error:{str(e)}")
PY
DB_JSON="$db_json" NEW_JSON="$new_fields")"

  if [[ -n "$diff_keys" ]]; then
    log_msg "✓ UPSERTED user ${user_id}: ⚠️  CHANGED FIELDS: ${diff_keys}"
    if [[ -n "$diff_detail" ]]; then
      log_msg "        details: ${diff_detail}"
    fi
    
    # Extract and log key field changes
    local cp_change location_change wallet_change
    if echo "$diff_detail" | grep -q "correction_point:"; then
      cp_change=$(echo "$diff_detail" | grep -o "correction_point:[^;]*" | cut -d: -f2-)
      log_msg "        📊 CORRECTION_POINT: $cp_change"
    fi
    if echo "$diff_detail" | grep -q "location:"; then
      location_change=$(echo "$diff_detail" | grep -o "location:[^;]*" | cut -d: -f2-)
      # Parse location change to show connection/disconnection semantics
      local from_loc to_loc
      from_loc=$(echo "$location_change" | cut -d'>' -f1)
      to_loc=$(echo "$location_change" | cut -d'>' -f2)
      
      if [[ "$from_loc" == "null" && "$to_loc" != "null" ]]; then
        log_msg "        🔌 CONNECTION: logged in at $to_loc"
      elif [[ "$from_loc" != "null" && "$to_loc" == "null" ]]; then
        log_msg "        🔌 DISCONNECTION: left $from_loc"
      else
        log_msg "        📍 LOCATION: $location_change"
      fi
    fi
    if echo "$diff_detail" | grep -q "wallet:"; then
      wallet_change=$(echo "$diff_detail" | grep -o "wallet:[^;]*" | cut -d: -f2-)
      log_msg "        💰 WALLET: $wallet_change"
    fi
  else
    log_msg "✓ VERIFIED user ${user_id} (no DB changes needed)"
  fi
  
  # Count validated projects and achievements - show DELTA (increase only)
  local proj_count ach_count
  proj_count=$(echo "$new_json" | jq '[.projects_users[]? | select(.status=="finished")] | length' 2>/dev/null || echo "0")
  ach_count=$(echo "$new_json" | jq '[.achievements_users[]? | select(.validated=="true" or .validated==true)] | length' 2>/dev/null || echo "0")
  
  # Get DB counts to calculate delta
  local db_proj_count db_ach_count proj_delta ach_delta
  db_proj_count=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At \
    -c "SELECT COUNT(*) FROM project_users WHERE user_id=$user_id AND status='finished'" 2>/dev/null || echo "0")
  db_ach_count=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At \
    -c "SELECT COUNT(*) FROM achievements_users WHERE user_id=$user_id AND validated=true" 2>/dev/null || echo "0")
  
  proj_delta=$((proj_count - db_proj_count))
  ach_delta=$((ach_count - db_ach_count))
  
  # Show only positive deltas
  if [[ $proj_delta -gt 0 ]]; then
    log_msg "        📈 PROJECTS: +$proj_delta"
  fi
  if [[ $ach_delta -gt 0 ]]; then
    log_msg "        🏆 ACHIEVEMENTS: +$ach_delta"
  fi
}

relation_db_count() {
  local table="$1"
  local user_id="$2"
  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At -c "SELECT count(*) FROM ${table} WHERE user_id=${user_id}" 2>/dev/null
}

get_snapshot_info() {
  local user_id="$1"
  local campus="$2"
  local snapshot_file="$EXPORTS_USERS/campus_${campus}/user_${user_id}.json"
  
  if [[ ! -f "$snapshot_file" ]]; then
    echo ""
    return
  fi
  
  # Get file modification time in seconds since epoch
  local snap_mtime=$(stat -c %Y "$snapshot_file" 2>/dev/null || echo "0")
  local now=$(date +%s)
  local age_seconds=$((now - snap_mtime))
  
  # Convert to readable format
  local age_str=""
  if [[ $age_seconds -lt 60 ]]; then
    age_str="${age_seconds}s"
  elif [[ $age_seconds -lt 3600 ]]; then
    age_str="$((age_seconds/60))m"
  elif [[ $age_seconds -lt 86400 ]]; then
    age_str="$((age_seconds/3600))h"
  else
    age_str="$((age_seconds/86400))d"
  fi
  
  echo "$age_str"
}

log_comprehensive_status() {
  local user_id="$1"
  local campus="$2"
  local api_json="$3"
  local old_snapshot_json="${4:-}"
  
  # DB Status
  local db_status=""
  local db_updated=""
  local db_full_json=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At \
    -c "SELECT row_to_json(row) FROM (SELECT updated_at FROM users WHERE id=$user_id) row;" 2>/dev/null || echo "{}")
  
  if [[ "$db_full_json" != "{}" && "$db_full_json" != "" ]]; then
    db_status="✓ in DB"
    db_updated=$(echo "$db_full_json" | jq -r '.updated_at' 2>/dev/null || echo "unknown")
    log_msg "  ├─ $db_status (last updated: $db_updated)"
  else
    log_msg "  ├─ ✨ NEW USER (not in DB)"
  fi
  
  # Snapshot Status
  local snap_exists="false"
  if [[ -n "$old_snapshot_json" && "$old_snapshot_json" != "{}" && "$old_snapshot_json" != "" ]]; then
    snap_exists="true"
    log_msg "  ├─ 📁 Prior snapshot available"
  else
    log_msg "  ├─ 📁 No prior snapshot"
  fi
  
  # Calculate deltas
  local api_cp=$(echo "$api_json" | jq '.correction_point // 0' 2>/dev/null || echo "0")
  local api_wallet=$(echo "$api_json" | jq '.wallet // 0' 2>/dev/null || echo "0")
  local api_location=$(echo "$api_json" | jq -r '.location // empty' 2>/dev/null || echo "")
  local api_proj=$(echo "$api_json" | jq '[.projects_users[]? | select(.status=="finished")] | length' 2>/dev/null || echo "0")
  local api_ach=$(echo "$api_json" | jq '[.achievements_users[]? | select(.validated=="true" or .validated==true)] | length' 2>/dev/null || echo "0")
  
  if [[ "$db_status" == "✓ in DB" ]]; then
    local db_cp db_wallet db_location db_proj db_ach
    db_cp=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At \
      -c "SELECT correction_point FROM users WHERE id=$user_id" 2>/dev/null || echo "0")
    db_wallet=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At \
      -c "SELECT wallet FROM users WHERE id=$user_id" 2>/dev/null || echo "0")
    db_location=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At \
      -c "SELECT COALESCE(location, '') FROM users WHERE id=$user_id" 2>/dev/null || echo "")
    db_proj=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At \
      -c "SELECT COUNT(*) FROM project_users WHERE user_id=$user_id AND status='finished'" 2>/dev/null || echo "0")
    db_ach=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At \
      -c "SELECT COUNT(*) FROM achievements_users WHERE user_id=$user_id AND validated=true" 2>/dev/null || echo "0")
    
    # Build delta summary
    local deltas_array=()
    [[ $api_cp -ne $db_cp ]] && deltas_array+=("cp:$api_cp")
    [[ $api_wallet -ne $db_wallet ]] && deltas_array+=("💰:$api_wallet")
    [[ "$api_location" != "$db_location" ]] && deltas_array+=("📍:${api_location:-empty}")
    [[ $api_proj -ne $db_proj ]] && deltas_array+=("projects:$api_proj")
    [[ $api_ach -ne $db_ach ]] && deltas_array+=("ach:$api_ach")
    
    if [[ ${#deltas_array[@]} -gt 0 ]]; then
      local deltas_str=$(IFS=', '; echo "${deltas_array[*]}")
      log_msg "  ├─ 📊 DB deltas: $deltas_str"
    fi
  fi
  
  # Compare with PREVIOUS snapshot if it exists
  if [[ "$snap_exists" == "true" ]]; then
    local snap_proj=$(echo "$old_snapshot_json" | jq '[.projects_users[]? | select(.status=="finished")] | length' 2>/dev/null || echo "0")
    local snap_ach=$(echo "$old_snapshot_json" | jq '[.achievements_users[]? | select(.validated=="true" or .validated==true)] | length' 2>/dev/null || echo "0")
    local snap_wallet=$(echo "$old_snapshot_json" | jq '.wallet // 0' 2>/dev/null || echo "0")
    local snap_cp=$(echo "$old_snapshot_json" | jq '.correction_point // 0' 2>/dev/null || echo "0")
    
    # Debug: show exact comparison
    if [[ $api_proj -ne $snap_proj || $api_ach -ne $snap_ach || $api_wallet -ne $snap_wallet || $api_cp -ne $snap_cp ]]; then
      log_msg "  ⚙️ SNAPSHOT vs API: proj($snap_proj→$api_proj) ach($snap_ach→$api_ach) 💰($snap_wallet→$api_wallet) cp($snap_cp→$api_cp)"
    fi
    
    # Build snapshot delta summary
    local snap_deltas_array=()
    [[ $api_proj -ne $snap_proj ]] && snap_deltas_array+=("📈 +$((api_proj-snap_proj))proj")
    [[ $api_ach -ne $snap_ach ]] && snap_deltas_array+=("🏆 +$((api_ach-snap_ach))ach")
    [[ $api_wallet -ne $snap_wallet ]] && snap_deltas_array+=("💰 +$((api_wallet-snap_wallet))")
    [[ $api_cp -ne $snap_cp ]] && snap_deltas_array+=("✨ +$((api_cp-snap_cp))cp")
    
    if [[ ${#snap_deltas_array[@]} -gt 0 ]]; then
      local snap_deltas_str=$(IFS=' '; echo "${snap_deltas_array[*]}")
      log_msg "  └─ 🔄 Snapshot growth: $snap_deltas_str"
    fi
  fi
}

log_msg "Worker started at $(date)"
log_msg "Backlog file path: $BACKLOG_FILE"
log_msg "Campus filter: ${CAMPUS_FILTER:-ALL}"
log_msg "DB target: host=${DB_HOST} port=${DB_PORT} db=${DB_NAME} user=${DB_USER}"

while true; do
  if [ ! -f "$BACKLOG_FILE" ]; then
    sleep 10
    continue
  fi

  if [ ! -s "$BACKLOG_FILE" ]; then
    sleep 10
    continue
  fi

  if [ ! -f "$ROOT_DIR/.oauth_state" ]; then
    log_msg "ERROR: No .oauth_state file"
    sleep 10
    continue
  fi

  source "$ROOT_DIR/.oauth_state"
  API_TOKEN="$ACCESS_TOKEN"

  if [ -z "$API_TOKEN" ]; then
    log_msg "ERROR: No API token"
    sleep 10
    continue
  fi

  queue_size=$(wc -l < "$BACKLOG_FILE" || echo 0)
  log_msg "Processing queue (current size: $queue_size)"

  COUNTER=0
  while true; do
    USER_ID=$(pop_next_user_id)
    [[ -z "$USER_ID" ]] && break
    COUNTER=$((COUNTER + 1))
    log_msg "→ Fetching user $USER_ID"
    user_json=$(fetch_user_json "$USER_ID")
    if [[ -z "$user_json" || "$user_json" == "null" ]]; then
      log_msg "WARN empty response for user $USER_ID"
      continue
    fi
    log_msg "← Fetched user $USER_ID (bytes=${#user_json})"
    if ! echo "$user_json" | jq empty >/dev/null 2>&1; then
      log_msg "WARN invalid JSON for user $USER_ID (skipping)"
      continue
    fi

    campus_from_user=$(get_campus_from_json "$user_json")
    campus_filter_upper="${CAMPUS_FILTER^^}"

    # Campus filter: skip if not in scope (no log)
    if [[ -n "$CAMPUS_FILTER" && "$campus_filter_upper" != "ALL" && "$CAMPUS_FILTER" != "$campus_from_user" ]]; then
      continue
    fi

    log_msg "Processing user $COUNTER (ID: $USER_ID, campus: $campus_from_user)"

    campus_dir_suffix="campus_${campus_from_user}"
    mkdir -p "$EXPORTS_USERS/$campus_dir_suffix" "$EXPORTS_PROJECT_USERS/$campus_dir_suffix" "$EXPORTS_ACHIEVEMENTS_USERS/$campus_dir_suffix" "$EXPORTS_COALITIONS_USERS/$campus_dir_suffix"

    # Read old snapshot FIRST
    export_file="$EXPORTS_USERS/$campus_dir_suffix/user_${USER_ID}.json"
    old_snapshot_json=""
    has_prior_snapshot=false
    if [[ -f "$export_file" ]]; then
      old_snapshot_json=$(cat "$export_file" 2>/dev/null || echo "")
      [[ -n "$old_snapshot_json" ]] && has_prior_snapshot=true
    fi
    
    log_msg "  ℹ️ Delta analysis (JSON comparison):"
    
    # Check if API JSON differs from snapshot
    has_deltas=false
    if [[ "$has_prior_snapshot" == "true" ]]; then
      # Compare JSON directly
      if [[ "$user_json" == "$old_snapshot_json" ]]; then
        log_msg "    • Snapshot: IDENTICAL (no changes)"
      else
        has_deltas=true
        log_msg "    • Snapshot: DIFFERS (has changes)"
        
        # Show what changed
        snap_proj=$(echo "$old_snapshot_json" | jq '[.projects_users[]? | select(.status=="finished")] | length' 2>/dev/null || echo "0")
        snap_ach=$(echo "$old_snapshot_json" | jq '[.achievements_users[]? | select(.validated=="true" or .validated==true)] | length' 2>/dev/null || echo "0")
        snap_wallet=$(echo "$old_snapshot_json" | jq '.wallet // 0' 2>/dev/null || echo "0")
        snap_cp=$(echo "$old_snapshot_json" | jq '.correction_point // 0' 2>/dev/null || echo "0")
        
        api_proj=$(echo "$user_json" | jq '[.projects_users[]? | select(.status=="finished")] | length' 2>/dev/null || echo "0")
        api_ach=$(echo "$user_json" | jq '[.achievements_users[]? | select(.validated=="true" or .validated==true)] | length' 2>/dev/null || echo "0")
        api_wallet=$(echo "$user_json" | jq '.wallet // 0' 2>/dev/null || echo "0")
        api_cp=$(echo "$user_json" | jq '.correction_point // 0' 2>/dev/null || echo "0")
        
        log_msg "      proj: $snap_proj→$api_proj | ach: $snap_ach→$api_ach | 💰: $snap_wallet→$api_wallet | cp: $snap_cp→$api_cp"
      fi
    else
      has_deltas=true
      log_msg "    • Snapshot: NONE (first capture)"
    fi
    
    # Decision: only upsert if there are deltas
    if [[ "$has_deltas" == "false" ]]; then
      log_msg "  ⏭️  SKIPPED: JSON unchanged (snapshot identical)"
      continue
    fi
    
    # Has deltas - proceed with upsert
    log_msg "  ✅ DECISION: Upsert (JSON differs from snapshot)"
    campus_from_user=$(upsert_user "$user_json" "$USER_ID" || true)
    [[ -z "$campus_from_user" ]] && campus_from_user="0"

    # Save raw user JSON for audit trail / comparison
    echo "$user_json" > "$export_file"
    log_msg "📁 SNAPSHOT exported: $campus_dir_suffix/user_${USER_ID}.json"
    
    # Log comprehensive status with old snapshot for comparison
    log_comprehensive_status "$USER_ID" "$campus_from_user" "$user_json" "$old_snapshot_json"

    diff_user_changes "$USER_ID" "$campus_from_user" "$user_json"
    
    # Call log_db_delta if snapshot differs to detect location/wallet/cp changes
    if [[ "$has_prior_snapshot" == "true" && "$user_json" != "$old_snapshot_json" ]]; then
      log_db_delta "$USER_ID" "$campus_from_user" "$user_json"
    fi

    # Fetch related datasets ONLY for CAMPUS_ID=12 (detailed info scope)
    # All users: basic user data only. Detailed relationships: CAMPUS_ID=12 only.
    if [[ "$campus_from_user" == "12" ]]; then
      log_msg "*** CAMPUS 12 DETECTED: Fetching detailed relations ***"
      projects_json=$(fetch_relation_json "$BASE_URL/users/$USER_ID/projects_users?per_page=100" "projects_users")
      achievements_json=$(fetch_relation_json "$BASE_URL/achievements_users?filter%5Buser_id%5D=$USER_ID&per_page=100" "achievements_users")
      coalitions_json=$(fetch_relation_json "$BASE_URL/users/$USER_ID/coalitions_users?per_page=100" "coalitions_users")

      count_proj=$(json_count "$projects_json")
      count_ach=$(json_count "$achievements_json")
      count_coal=$(json_count "$coalitions_json")
      db_proj=$(relation_db_count "project_users" "$USER_ID")
      db_ach=$(relation_db_count "achievements_users" "$USER_ID")
      db_coal=$(relation_db_count "coalitions_users" "$USER_ID")

      log_msg "CAMPUS 12 RELATIONS: proj=${count_proj}(db=${db_proj:-0}) | ach=${count_ach}(db=${db_ach:-0}) | coal=${count_coal}(db=${db_coal:-0})"

      # Persist raw JSON for traceability
      echo "$projects_json" > "$EXPORTS_PROJECT_USERS/$campus_dir_suffix/user_${USER_ID}.json"
      echo "$achievements_json" > "$EXPORTS_ACHIEVEMENTS_USERS/$campus_dir_suffix/user_${USER_ID}.json"
      echo "$coalitions_json" > "$EXPORTS_COALITIONS_USERS/$campus_dir_suffix/user_${USER_ID}.json"

      # Upsert related datasets
      upsert_projects_users "$projects_json" "$campus_from_user" "$USER_ID"
      upsert_achievements_users "$achievements_json" "$campus_from_user" "$USER_ID"
      upsert_coalitions_users "$coalitions_json" "$campus_from_user" "$USER_ID"
    else
      log_msg "→ User $USER_ID (campus $campus_from_user): basic user data only (no relations for non-CAMPUS_ID=12)"
    fi

    # Persist raw JSON for traceability (basic user always)
    echo "$user_json" > "$EXPORTS_USERS/$campus_dir_suffix/user_${USER_ID}.json"

    # Visual separator for log readability
    log_msg "---"

    # Rate limiting: pause between each user iteration
    sleep "$RATE_LIMIT_DELAY"
  done

  sleep 5
done
