#!/usr/bin/env bash
set -euo pipefail

# Update users table from exports/08_users/all.json
# Simple UPSERT pattern - runs independently every X hours

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="$ROOT_DIR/exports/08_users"
LOGS_DIR="$ROOT_DIR/logs"

mkdir -p "$LOGS_DIR"

if [[ -f "$ROOT_DIR/../.env" ]]; then
  # shellcheck disable=SC1091
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
    echo "psql not available" >&2
    exit 1
  fi
}

LOG_FILE="$LOGS_DIR/update_users.log"

{
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting users update..."
  
  merged_json="$DATA_DIR/all.json"
  if [[ ! -f "$merged_json" ]]; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Error: $merged_json not found"
    exit 1
  fi
  
  # Create users table if not exists
  run_psql <<'SQL'
CREATE TABLE IF NOT EXISTS users (
  id                    BIGINT PRIMARY KEY,
  email                 TEXT,
  login                 TEXT UNIQUE,
  first_name            TEXT,
  last_name             TEXT,
  usual_full_name       TEXT,
  usual_first_name      TEXT,
  kind                  TEXT,
  displayname           TEXT,
  staff_p               BOOLEAN,
  correction_point      INTEGER,
  pool_month            TEXT,
  pool_year             TEXT,
  location              TEXT,
  wallet                BIGINT,
  phone                 TEXT,
  anonymize_date        TIMESTAMPTZ,
  data_erasure_date     TIMESTAMPTZ,
  created_at            TIMESTAMPTZ,
  updated_at            TIMESTAMPTZ,
  alumnized_at          TIMESTAMPTZ,
  alumni_p              BOOLEAN,
  active_p              BOOLEAN,
  image_link            TEXT,
  image_large           TEXT,
  image_medium          TEXT,
  image_small           TEXT,
  image_micro           TEXT,
  url                   TEXT,
  campus_id             BIGINT,
  ingested_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_login ON users (login);
CREATE INDEX IF NOT EXISTS idx_users_email ON users (email);
CREATE INDEX IF NOT EXISTS idx_users_kind ON users (kind);
CREATE INDEX IF NOT EXISTS idx_users_updated_at ON users (updated_at);
ALTER TABLE users ADD COLUMN IF NOT EXISTS campus_id BIGINT;
CREATE INDEX IF NOT EXISTS idx_users_campus_id ON users (campus_id);

DROP TABLE IF EXISTS users_delta;
CREATE TABLE users_delta (LIKE users INCLUDING DEFAULTS);
TRUNCATE users_delta;
SQL
  
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Staging users..."
  
  # Load into delta table
  jq -r '.[] | [
    .id,
    (.email // ""),
    (.login // ""),
    (.first_name // ""),
    (.last_name // ""),
    (.usual_full_name // ""),
    (.usual_first_name // ""),
    (.kind // ""),
    (.displayname // ""),
    (.staff? // false),
    (.correction_point // null),
    (.pool_month // ""),
    (.pool_year // ""),
    (.location // ""),
    (.wallet // null),
    (.phone // ""),
    (.anonymize_date // null),
    (.data_erasure_date // null),
    (.created_at // null),
    (.updated_at // null),
    (.alumnized_at // null),
    (.alumni? // false),
    (.active? // false),
    (.image.link // ""),
    (.image.versions.large // ""),
    (.image.versions.medium // ""),
    (.image.versions.small // ""),
    (.image.versions.micro // ""),
    (
      .campus[0].id //
      (.campus_users[]? | select(.is_primary == true) | .campus_id) //
      (.campus_users[0].campus_id // null)
    )
  ] | @csv' "$merged_json" \
    | run_psql -c "\copy users_delta (id,email,login,first_name,last_name,usual_full_name,usual_first_name,kind,displayname,staff_p,correction_point,pool_month,pool_year,location,wallet,phone,anonymize_date,data_erasure_date,created_at,updated_at,alumnized_at,alumni_p,active_p,image_link,image_large,image_medium,image_small,image_micro,campus_id) FROM STDIN WITH (FORMAT csv, NULL '')"
  
  delta_count=$(run_psql -t -c "SELECT COUNT(*) FROM users_delta")
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Staged $delta_count users"
  
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Upserting..."
  
  # Upsert into production table
  run_psql <<'SQL'
WITH upsert AS (
  INSERT INTO users (id,email,login,first_name,last_name,usual_full_name,usual_first_name,kind,displayname,staff_p,correction_point,pool_month,pool_year,location,wallet,phone,anonymize_date,data_erasure_date,created_at,updated_at,alumnized_at,alumni_p,active_p,image_link,image_large,image_medium,image_small,image_micro,url,campus_id)
  SELECT id,email,login,first_name,last_name,usual_full_name,usual_first_name,kind,displayname,staff_p,correction_point,pool_month,pool_year,location,wallet,phone,anonymize_date,data_erasure_date,created_at,updated_at,alumnized_at,alumni_p,active_p,image_link,image_large,image_medium,image_small,image_micro,CONCAT('https://api.intra.42.fr/v2/users/',login),campus_id FROM users_delta
  ON CONFLICT (id) DO UPDATE SET
    email=EXCLUDED.email,
    login=EXCLUDED.login,
    first_name=EXCLUDED.first_name,
    last_name=EXCLUDED.last_name,
    usual_full_name=EXCLUDED.usual_full_name,
    usual_first_name=EXCLUDED.usual_first_name,
    correction_point=EXCLUDED.correction_point,
    pool_month=EXCLUDED.pool_month,
    pool_year=EXCLUDED.pool_year,
    location=EXCLUDED.location,
    wallet=EXCLUDED.wallet,
    updated_at=EXCLUDED.updated_at,
    campus_id=EXCLUDED.campus_id,
    ingested_at=NOW()
  RETURNING xmax = 0 AS inserted
)
SELECT 
  SUM(CASE WHEN inserted THEN 1 ELSE 0 END) as inserted,
  SUM(CASE WHEN NOT inserted THEN 1 ELSE 0 END) as updated
FROM upsert;
SQL
  
  run_psql -c "TRUNCATE users_delta;"
  
  total=$(run_psql -t -c "SELECT COUNT(*) FROM users")
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Users: total=$total"
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Update complete"
  
} | tee -a "$LOG_FILE"
