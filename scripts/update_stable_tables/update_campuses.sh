#!/usr/bin/env bash
set -euo pipefail

# Fetch campuses and upsert into Postgres.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$ROOT_DIR/scripts/helpers/fetch_campuses.sh"
EXPORT_DIR="$ROOT_DIR/exports/02_campus"
MERGED_JSON="$EXPORT_DIR/all.json"

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

if [[ ! -x "$HELPER" ]]; then
  echo "Helper script not found or not executable: $HELPER" >&2
  exit 1
fi

echo "Fetching campuses..."
set +e
"$HELPER"
helper_status=$?
set -e
if [[ $helper_status -eq 3 ]]; then
  echo "Using cached campuses fetch (skip due to recency)."
elif [[ $helper_status -ne 0 ]]; then
  exit $helper_status
fi

if [[ ! -s "$MERGED_JSON" ]]; then
  echo "No campus data found at $MERGED_JSON" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

run_psql <<'SQL'
CREATE TABLE IF NOT EXISTS campuses (
  id           BIGINT PRIMARY KEY,
  name         TEXT,
  time_zone    TEXT,
  language_id  BIGINT,
  language_name TEXT,
  language_identifier TEXT,
  users_count  INTEGER,
  vogsphere_id BIGINT,
  country      TEXT,
  address      TEXT,
  zip          TEXT,
  city         TEXT,
  website      TEXT,
  facebook     TEXT,
  twitter      TEXT,
  public       BOOLEAN,
  active       BOOLEAN,
  email_extension       TEXT,
  default_hidden_phone  BOOLEAN,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_campuses_city ON campuses (city);
CREATE INDEX IF NOT EXISTS idx_campuses_active ON campuses (active);
CREATE INDEX IF NOT EXISTS idx_campuses_public ON campuses (public);
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'campuses' AND column_name = 'raw_json'
  ) THEN
    EXECUTE 'ALTER TABLE campuses DROP COLUMN raw_json';
  END IF;
END$$;
DROP TABLE IF EXISTS campuses_delta;
CREATE TABLE campuses_delta (LIKE campuses INCLUDING DEFAULTS);
TRUNCATE campuses_delta;
SQL

echo "Staging campuses..."
jq -r '.[] | [
  .id,
  (.name // ""),
  (.time_zone // ""),
  (.language.id // null),
  (.language.name // null),
  (.language.identifier // null),
  (.users_count // null),
  (.vogsphere_id // null),
  (.country // null),
  (.address // null),
  (.zip // null),
  (.city // null),
  (.website // null),
  (.facebook // null),
  (.twitter // null),
  (.public // null),
  (.active // null),
  (.email_extension // null),
  (.default_hidden_phone // null)
] | @csv' "$MERGED_JSON" \
  | run_psql -c "\copy campuses_delta (id,name,time_zone,language_id,language_name,language_identifier,users_count,vogsphere_id,country,address,zip,city,website,facebook,twitter,public,active,email_extension,default_hidden_phone) FROM STDIN WITH (FORMAT csv, NULL '')"

echo "Pruning campuses missing from this snapshot..."
run_psql <<'SQL'
DELETE FROM campuses c
WHERE NOT EXISTS (SELECT 1 FROM campuses_delta d WHERE d.id = c.id);
SQL

echo "Upserting campuses..."
run_psql <<'SQL'
WITH upsert AS (
  INSERT INTO campuses (id,name,time_zone,language_id,language_name,language_identifier,users_count,vogsphere_id,country,address,zip,city,website,facebook,twitter,public,active,email_extension,default_hidden_phone)
  SELECT id,name,time_zone,language_id,language_name,language_identifier,users_count,vogsphere_id,country,address,zip,city,website,facebook,twitter,public,active,email_extension,default_hidden_phone FROM campuses_delta
  ON CONFLICT (id) DO UPDATE SET
    name=EXCLUDED.name,
    time_zone=EXCLUDED.time_zone,
    language_id=EXCLUDED.language_id,
    language_name=EXCLUDED.language_name,
    language_identifier=EXCLUDED.language_identifier,
    users_count=EXCLUDED.users_count,
    vogsphere_id=EXCLUDED.vogsphere_id,
    country=EXCLUDED.country,
    address=EXCLUDED.address,
    zip=EXCLUDED.zip,
    city=EXCLUDED.city,
    website=EXCLUDED.website,
    facebook=EXCLUDED.facebook,
    twitter=EXCLUDED.twitter,
    public=EXCLUDED.public,
    active=EXCLUDED.active,
    email_extension=EXCLUDED.email_extension,
    default_hidden_phone=EXCLUDED.default_hidden_phone,
    ingested_at=EXCLUDED.ingested_at
  RETURNING xmax = 0 AS inserted
)
SELECT
  SUM(CASE WHEN inserted THEN 1 ELSE 0 END) AS inserted,
  SUM(CASE WHEN NOT inserted THEN 1 ELSE 0 END) AS updated
FROM upsert;
TRUNCATE campuses_delta;
SQL

inserted=$(run_psql -Atc "SELECT count(*) FROM campuses WHERE ingested_at >= now() - interval '1 minute';")
total=$(run_psql -Atc "SELECT count(*) FROM campuses;")
echo "Campuses: total=$total, recently_ingested=$inserted"
echo "Campuses sync complete."
