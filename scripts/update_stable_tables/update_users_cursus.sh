#!/usr/bin/env bash
set -euo pipefail

# Update users table filtered by cursus_id=21 (42cursus)
# Only syncs active students (kind='student', alumni=false)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$ROOT_DIR/scripts/helpers/fetch_users_by_cursus.sh"
CURSUS_ID=${CURSUS_ID:-21}
EXPORT_DIR="$ROOT_DIR/exports/08_users/cursus_${CURSUS_ID}"
MERGED_JSON="$EXPORT_DIR/all.json"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/update_users_cursus.log"

mkdir -p "$LOG_DIR"

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

if [[ -f "$ROOT_DIR/../.env" ]]; then
  source "$ROOT_DIR/../.env"
fi

DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-api42}
DB_USER=${DB_USER:-api42}
DB_PASSWORD=${DB_PASSWORD:-api42}
export PGOPTIONS="${PGOPTIONS:--c client_min_messages=warning}"
PSQL_CONN="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export PGPASSWORD="$DB_PASSWORD"

run_psql() {
  if command -v psql >/dev/null 2>&1; then
    psql "$PSQL_CONN" "$@"
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose exec -T -e PGPASSWORD="$DB_PASSWORD" db psql -h db -U "$DB_USER" -d "$DB_NAME" "$@"
  else
    log "ERROR: psql not available"
    exit 1
  fi
}

if [[ ! -x "$HELPER" ]]; then
  log "ERROR: Helper script not found or not executable: $HELPER"
  exit 1
fi

# Ensure token is fresh before starting API calls
"$ROOT_DIR/scripts/token_manager.sh" ensure-fresh >&2

log "====== UPDATE USERS (CURSUS $CURSUS_ID) START ======="
START_TIME=$(date +%s)

log "Fetching users for cursus $CURSUS_ID..."
set +e
CURSUS_ID=$CURSUS_ID "$HELPER"
helper_status=$?
set -e

if [[ $helper_status -eq 3 ]]; then
  log "Using cached fetch (skip due to recency)."
elif [[ $helper_status -ne 0 ]]; then
  log "ERROR: User fetch failed with status $helper_status"
  exit $helper_status
fi

if [[ ! -s "$MERGED_JSON" ]]; then
  log "ERROR: No user data found at $MERGED_JSON"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq is required."
  exit 1
fi

log "Staging users (filtering alumni)..."
# cursus_users endpoint returns user + cursus enrollment data
# Extract user fields and filter out alumni
jq -r '.[] | 
  select(.user.alumni != true) |
  .user | [
  .id,
  (.email // ""),
  (.login // ""),
  (.first_name // ""),
  (.last_name // ""),
  (.usual_full_name // ""),
  (.usual_first_name // ""),
  (.url // ""),
  (.phone // ""),
  (.displayname // ""),
  (.kind // ""),
  (.image.link // ""),
  (.image.large // ""),
  (.image.medium // ""),
  (.image.small // ""),
  (.image.micro // ""),
  (.image // {} | @json),
  (.staff // false),
  (.correction_point // 0),
  (.pool_month // ""),
  (.pool_year // ""),
  (.location // ""),
  (.wallet // 0),
  (.anonymize_date // ""),
  (.data_erasure_date // ""),
  (.created_at // ""),
  (.updated_at // ""),
  (.alumnized_at // ""),
  (.alumni // false),
  (.active // false),
  (21 as $cursus_id | null) as $campus_id
] | @csv' "$MERGED_JSON" \
  | run_psql -c "\copy users (id,email,login,first_name,last_name,usual_full_name,usual_first_name,url,phone,displayname,kind,image_link,image_large,image_medium,image_small,image_micro,image,staff,correction_point,pool_month,pool_year,location,wallet,anonymize_date,data_erasure_date,created_at,updated_at,alumnized_at,alumni,active,campus_id) FROM STDIN WITH (FORMAT csv, NULL '')"

echo "Upserting users (cursus $CURSUS_ID only)..."
run_psql <<'SQL'
WITH upsert AS (
  INSERT INTO users (id,email,login,first_name,last_name,usual_full_name,usual_first_name,url,phone,displayname,kind,image_link,image_large,image_medium,image_small,image_micro,image,staff,correction_point,pool_month,pool_year,location,wallet,anonymize_date,data_erasure_date,created_at,updated_at,alumnized_at,alumni,active,campus_id)
  SELECT id,email,login,first_name,last_name,usual_full_name,usual_first_name,url,phone,displayname,kind,image_link,image_large,image_medium,image_small,image_micro,image,staff,correction_point,pool_month,pool_year,location,wallet,anonymize_date,data_erasure_date,created_at,updated_at,alumnized_at,alumni,active,campus_id FROM users_delta
  ON CONFLICT (id) DO UPDATE SET
    email=EXCLUDED.email,
    login=EXCLUDED.login,
    first_name=EXCLUDED.first_name,
    last_name=EXCLUDED.last_name,
    usual_full_name=EXCLUDED.usual_full_name,
    usual_first_name=EXCLUDED.usual_first_name,
    url=EXCLUDED.url,
    phone=EXCLUDED.phone,
    displayname=EXCLUDED.displayname,
    kind=EXCLUDED.kind,
    image_link=EXCLUDED.image_link,
    image_large=EXCLUDED.image_large,
    image_medium=EXCLUDED.image_medium,
    image_small=EXCLUDED.image_small,
    image_micro=EXCLUDED.image_micro,
    image=EXCLUDED.image,
    staff=EXCLUDED.staff,
    correction_point=EXCLUDED.correction_point,
    pool_month=EXCLUDED.pool_month,
    pool_year=EXCLUDED.pool_year,
    location=EXCLUDED.location,
    wallet=EXCLUDED.wallet,
    anonymize_date=EXCLUDED.anonymize_date,
    data_erasure_date=EXCLUDED.data_erasure_date,
    created_at=EXCLUDED.created_at,
    updated_at=EXCLUDED.updated_at,
    alumnized_at=EXCLUDED.alumnized_at,
    alumni=EXCLUDED.alumni,
    active=EXCLUDED.active,
    campus_id=EXCLUDED.campus_id,
    ingested_at=EXCLUDED.ingested_at
  RETURNING xmax = 0 AS inserted
)
SELECT
  SUM(CASE WHEN inserted THEN 1 ELSE 0 END) AS inserted,
  SUM(CASE WHEN NOT inserted THEN 1 ELSE 0 END) AS updated
FROM upsert;
TRUNCATE users_delta;
SQL

inserted=$(run_psql -Atc "SELECT count(*) FROM users WHERE alumni = false AND kind = 'student' AND ingested_at >= now() - interval '1 minute';")
total=$(run_psql -Atc "SELECT count(*) FROM users WHERE alumni = false AND kind = 'student';")
log "Users (cursus $CURSUS_ID, active only): total=$total, recently_ingested=$inserted"

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
log "====== UPDATE USERS COMPLETE (${DURATION}s) ======"
log "Log: $LOG_FILE"
log ""
