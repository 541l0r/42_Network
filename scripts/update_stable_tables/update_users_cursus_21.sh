#!/usr/bin/env bash
set -euo pipefail

# Load cursus 21 users into Postgres
# Fetches from .tmp/phase2_users/ (output of fetch_cursus_21_users_all.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Use phase2_users_v2 if it exists, otherwise fall back to phase2_users
if [[ -d "$ROOT_DIR/.tmp/phase2_users_v2" ]]; then
  DATA_DIR="$ROOT_DIR/.tmp/phase2_users_v2"
else
  DATA_DIR="$ROOT_DIR/.tmp/phase2_users"
fi

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
    echo "psql is not available locally and docker compose is unavailable." >&2
    exit 1
  fi
}

# Verify data exists
if [[ ! -d "$DATA_DIR" ]]; then
  echo "Data directory not found: $DATA_DIR" >&2
  echo "Run fetch_cursus_21_users_all.sh first." >&2
  exit 1
fi

merged_json="$DATA_DIR/all.json"
if [[ ! -f "$merged_json" ]]; then
  echo "Merged JSON file not found: $merged_json" >&2
  exit 1
fi

# Read stats if available
stats_file="$DATA_DIR/.last_fetch_stats"
if [[ -f "$stats_file" ]]; then
  # shellcheck disable=SC1090
  source "$stats_file"
  echo "Loading users from fetch: timestamp=$timestamp, items=$items"
fi

echo "Loading cursus 21 users from $merged_json..."

# Create users table
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
  ingested_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_login ON users (login);
CREATE INDEX IF NOT EXISTS idx_users_email ON users (email);
CREATE INDEX IF NOT EXISTS idx_users_kind ON users (kind);
CREATE INDEX IF NOT EXISTS idx_users_active ON users (active_p);
CREATE INDEX IF NOT EXISTS idx_users_alumni ON users (alumni_p);
CREATE INDEX IF NOT EXISTS idx_users_updated_at ON users (updated_at);

DROP TABLE IF EXISTS users_delta;
CREATE TABLE users_delta (LIKE users INCLUDING DEFAULTS);
TRUNCATE users_delta;
SQL

echo "Staging users from $merged_json..."

# Extract user data from merged JSON
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
  (.image.versions.micro // "")
] | @csv' \
  "$merged_json" \
  | run_psql -c "\copy users_delta (id,email,login,first_name,last_name,usual_full_name,usual_first_name,kind,displayname,staff_p,correction_point,pool_month,pool_year,location,wallet,phone,anonymize_date,data_erasure_date,created_at,updated_at,alumnized_at,alumni_p,active_p,image_link,image_large,image_medium,image_small,image_micro) FROM STDIN WITH (FORMAT csv, NULL '')"

delta_count=$(run_psql -t -c "SELECT COUNT(*) FROM users_delta")
if [ "$delta_count" = "0" ]; then
  echo "Skip upsert: No changes in users_delta"
  exit 0
fi

echo "Upserting $delta_count users..."
run_psql <<'SQL'
WITH upsert AS (
  INSERT INTO users (id,email,login,first_name,last_name,usual_full_name,usual_first_name,kind,displayname,staff_p,correction_point,pool_month,pool_year,location,wallet,phone,anonymize_date,data_erasure_date,created_at,updated_at,alumnized_at,alumni_p,active_p,image_link,image_large,image_medium,image_small,image_micro,url)
  SELECT id,email,login,first_name,last_name,usual_full_name,usual_first_name,kind,displayname,staff_p,correction_point,pool_month,pool_year,location,wallet,phone,anonymize_date,data_erasure_date,created_at,updated_at,alumnized_at,alumni_p,active_p,image_link,image_large,image_medium,image_small,image_micro,CONCAT('https://api.intra.42.fr/v2/users/',login) FROM users_delta
  ON CONFLICT (id) DO UPDATE SET
    email=EXCLUDED.email,
    login=EXCLUDED.login,
    first_name=EXCLUDED.first_name,
    last_name=EXCLUDED.last_name,
    usual_full_name=EXCLUDED.usual_full_name,
    usual_first_name=EXCLUDED.usual_first_name,
    kind=EXCLUDED.kind,
    displayname=EXCLUDED.displayname,
    staff_p=EXCLUDED.staff_p,
    correction_point=EXCLUDED.correction_point,
    pool_month=EXCLUDED.pool_month,
    pool_year=EXCLUDED.pool_year,
    location=EXCLUDED.location,
    wallet=EXCLUDED.wallet,
    phone=EXCLUDED.phone,
    anonymize_date=EXCLUDED.anonymize_date,
    data_erasure_date=EXCLUDED.data_erasure_date,
    created_at=EXCLUDED.created_at,
    updated_at=EXCLUDED.updated_at,
    alumnized_at=EXCLUDED.alumnized_at,
    alumni_p=EXCLUDED.alumni_p,
    active_p=EXCLUDED.active_p,
    image_link=EXCLUDED.image_link,
    image_large=EXCLUDED.image_large,
    image_medium=EXCLUDED.image_medium,
    image_small=EXCLUDED.image_small,
    image_micro=EXCLUDED.image_micro,
    url=EXCLUDED.url,
    ingested_at=EXCLUDED.ingested_at
  RETURNING xmax = 0 AS inserted
)
SELECT
  SUM(CASE WHEN inserted THEN 1 ELSE 0 END) AS inserted,
  SUM(CASE WHEN NOT inserted THEN 1 ELSE 0 END) AS updated
FROM upsert;
TRUNCATE users_delta;
SQL

total=$(run_psql -Atc "SELECT count(*) FROM users;")
echo "Users: total=$total"
echo "Users sync complete."
