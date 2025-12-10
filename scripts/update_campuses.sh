#!/usr/bin/env bash
set -euo pipefail

# Fetch all campuses and upsert into Postgres.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPORT_DIR="$ROOT_DIR/exports/campus"
ALL_FILE="$EXPORT_DIR/all.json"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"
MIN_FETCH_AGE_SECONDS=${MIN_FETCH_AGE_SECONDS:-86400}
FETCH_SCRIPT="$SCRIPT_DIR/helpers/fetch_all_campuses.sh"
if [[ "${1:-}" == "--force" ]]; then
  MIN_FETCH_AGE_SECONDS=0
fi

mkdir -p "$EXPORT_DIR"

if [[ -f "$ROOT_DIR/../.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/../.env"
fi

DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-api42}
DB_USER=${DB_USER:-api42}
DB_PASSWORD=${DB_PASSWORD:-api42}

PSQL_CONN="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export PGPASSWORD="$DB_PASSWORD"

if command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
else
  COMPOSE_CMD=""
fi

run_psql() {
  if command -v psql >/dev/null 2>&1; then
    psql "$PSQL_CONN" "$@"
  elif [[ -n "$COMPOSE_CMD" ]]; then
    $COMPOSE_CMD exec -T -e PGPASSWORD="$DB_PASSWORD" db psql -h db -U "$DB_USER" -d "$DB_NAME" "$@"
  else
    echo "psql is not installed and docker compose is unavailable. Install psql or docker compose." >&2
    exit 1
  fi
}

if [[ -f "$STAMP_FILE" ]]; then
  last_run=$(cat "$STAMP_FILE")
  now=$(date +%s)
    age=$(( now - last_run ))
    if (( age < MIN_FETCH_AGE_SECONDS )); then
      echo "Skipping campus fetch: last run $age seconds ago (< ${MIN_FETCH_AGE_SECONDS}s)."
    else
      echo "Fetching campuses..."
      "$FETCH_SCRIPT"
      now_epoch=$(date +%s)
      date +%s > "$STAMP_FILE"
      cat > "$METRIC_FILE" <<EOF
timestamp=$now_epoch
files=$(ls "$EXPORT_DIR"/page_*.json 2>/dev/null | wc -l | tr -d ' ')
EOF
  fi
else
  echo "Fetching campuses..."
  "$FETCH_SCRIPT"
  now_epoch=$(date +%s)
  date +%s > "$STAMP_FILE"
  cat > "$METRIC_FILE" <<EOF
timestamp=$now_epoch
files=$(ls "$EXPORT_DIR"/page_*.json 2>/dev/null | wc -l | tr -d ' ')
EOF
fi

if [[ ! -f "$ALL_FILE" ]]; then
  echo "Expected file not found: $ALL_FILE" >&2
  exit 1
fi

echo "Upserting campuses into database..."
if ! run_psql -Atqc "SELECT to_regclass('public.campuses')" | grep -q campuses; then
  echo "Table campuses not found. Create it before running this script." >&2
  exit 1
fi

run_psql <<'SQL'
DROP TABLE IF EXISTS campuses_delta;
CREATE TABLE campuses_delta (LIKE campuses INCLUDING DEFAULTS);
TRUNCATE campuses_delta;
SQL

jq -r '.[] | [
  .id,
  .name,
  .time_zone,
  ( .language // null | tojson ),
  (.users_count // null),
  (.vogsphere_id // null),
  .country,
  .address,
  .zip,
  .city,
  .website,
  .facebook,
  .twitter,
  (.public // null),
  (.active // null),
  (tojson)
] | @csv' "$ALL_FILE" \
  | run_psql -c "\copy campuses_delta (id,name,time_zone,language,users_count,vogsphere_id,country,address,zip,city,website,facebook,twitter,public,active,raw_json) FROM STDIN WITH (FORMAT csv)"

upsert_result=$(run_psql -At <<'SQL'
WITH upsert AS (
  INSERT INTO campuses (id,name,time_zone,language,users_count,vogsphere_id,country,address,zip,city,website,facebook,twitter,public,active,raw_json)
  SELECT id,name,time_zone,language,users_count,vogsphere_id,country,address,zip,city,website,facebook,twitter,public,active,raw_json
  FROM campuses_delta
  ON CONFLICT (id) DO UPDATE SET
    name=EXCLUDED.name,
    time_zone=EXCLUDED.time_zone,
    language=EXCLUDED.language,
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
    raw_json=EXCLUDED.raw_json,
    ingested_at=EXCLUDED.ingested_at
  WHERE campuses.name IS DISTINCT FROM EXCLUDED.name
     OR campuses.time_zone IS DISTINCT FROM EXCLUDED.time_zone
     OR campuses.language IS DISTINCT FROM EXCLUDED.language
     OR campuses.users_count IS DISTINCT FROM EXCLUDED.users_count
     OR campuses.vogsphere_id IS DISTINCT FROM EXCLUDED.vogsphere_id
     OR campuses.country IS DISTINCT FROM EXCLUDED.country
     OR campuses.address IS DISTINCT FROM EXCLUDED.address
     OR campuses.zip IS DISTINCT FROM EXCLUDED.zip
     OR campuses.city IS DISTINCT FROM EXCLUDED.city
     OR campuses.website IS DISTINCT FROM EXCLUDED.website
     OR campuses.facebook IS DISTINCT FROM EXCLUDED.facebook
     OR campuses.twitter IS DISTINCT FROM EXCLUDED.twitter
     OR campuses.public IS DISTINCT FROM EXCLUDED.public
     OR campuses.active IS DISTINCT FROM EXCLUDED.active
     OR campuses.raw_json IS DISTINCT FROM EXCLUDED.raw_json
  RETURNING (xmax = 0) AS inserted
)
SELECT
  count(*) FILTER (WHERE inserted) AS inserted,
  count(*) FILTER (WHERE NOT inserted) AS updated
FROM upsert;
SQL
)

inserted_count=$(echo "$upsert_result" | cut -d'|' -f1)
updated_count=$(echo "$upsert_result" | cut -d'|' -f2)
echo "Upserted campuses: inserted=$inserted_count updated=$updated_count"

run_psql <<'SQL'
TRUNCATE campuses_delta;
SQL

run_psql -c "DELETE FROM campuses WHERE active IS NOT TRUE OR public IS NOT TRUE;"

echo "Campuses sync complete."
