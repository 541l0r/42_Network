#!/usr/bin/env bash
set -euo pipefail

# Fetch all cursus and upsert into Postgres.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$ROOT_DIR/scripts/helpers/fetch_cursus.sh"
EXPORT_DIR="$ROOT_DIR/exports/01_cursus"
MERGED_JSON="$EXPORT_DIR/all.json"
CURSUS_ID=${CURSUS_ID:-21}

HELPER_ARGS=("$@")

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
export PGOPTIONS="${PGOPTIONS:--c client_min_messages=warning}"
PSQL_CONN="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export PGPASSWORD="$DB_PASSWORD"

echo "Fetching cursus..."
CURSUS_ID="$CURSUS_ID" "$HELPER" "${HELPER_ARGS[@]}"

if [[ ! -s "$MERGED_JSON" ]]; then
  echo "No cursus data found at $MERGED_JSON" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

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

run_psql <<'SQL'
CREATE TABLE IF NOT EXISTS cursus (
  id          BIGINT PRIMARY KEY,
  name        TEXT,
  slug        TEXT,
  kind        TEXT,
  created_at  TIMESTAMPTZ,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_cursus_slug ON cursus (slug);
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'cursus' AND column_name = 'raw_json'
  ) THEN
    EXECUTE 'ALTER TABLE cursus DROP COLUMN raw_json';
  END IF;
END$$;
SQL

run_psql <<'SQL'
DROP TABLE IF EXISTS cursus_delta;
CREATE TABLE cursus_delta (LIKE cursus INCLUDING DEFAULTS);
TRUNCATE cursus_delta;
SQL

echo "Staging into cursus_delta..."
jq -r '.[] | [
  .id,
  .name,
  .slug,
  (.kind // null),
  (.created_at // null)
] | @csv' "$MERGED_JSON" \
  | run_psql -c "\copy cursus_delta (id,name,slug,kind,created_at) FROM STDIN WITH (FORMAT csv, NULL '')"

echo "Upserting cursus..."
run_psql <<'SQL'
WITH upsert AS (
  INSERT INTO cursus (id,name,slug,kind,created_at)
  SELECT id,name,slug,kind,created_at FROM cursus_delta
  ON CONFLICT (id) DO UPDATE SET
    name=EXCLUDED.name,
    slug=EXCLUDED.slug,
    kind=EXCLUDED.kind,
    created_at=EXCLUDED.created_at,
    ingested_at=EXCLUDED.ingested_at
  RETURNING xmax = 0 AS inserted
)
SELECT
  SUM(CASE WHEN inserted THEN 1 ELSE 0 END) AS inserted,
  SUM(CASE WHEN NOT inserted THEN 1 ELSE 0 END) AS updated
FROM upsert;
TRUNCATE cursus_delta;
SQL

inserted=$(run_psql -Atc "SELECT count(*) FROM cursus WHERE ingested_at >= now() - interval '1 minute';")
total=$(run_psql -Atc "SELECT count(*) FROM cursus;")
echo "Cursus: total=$total, recently_ingested=$inserted"
echo "Cursus sync complete."
