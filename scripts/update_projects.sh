#!/usr/bin/env bash
set -euo pipefail

# Fetch all projects and upsert into Postgres.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$ROOT_DIR/scripts/helpers/fetch_all_projects.sh"
EXPORT_DIR="$ROOT_DIR/exports/projects"
MERGED_JSON="$EXPORT_DIR/all.json"

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

if [[ ! -x "$HELPER" ]]; then
  echo "Helper script not found or not executable: $HELPER" >&2
  exit 1
fi

echo "Fetching projects..."
"$HELPER" "$@"

if [[ ! -s "$MERGED_JSON" ]]; then
  echo "No projects data found at $MERGED_JSON" >&2
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
DROP TABLE IF EXISTS projects_delta;
CREATE TABLE projects_delta (LIKE projects INCLUDING DEFAULTS);
TRUNCATE projects_delta;
SQL

echo "Staging into projects_delta..."
jq -r '.[] | [
  .id,
  .name,
  .slug,
  (.parent_id // null),
  (tojson)
] | @csv' "$MERGED_JSON" \
  | run_psql -c "\copy projects_delta (id,name,slug,parent_id,raw_json) FROM STDIN WITH (FORMAT csv)"

echo "Upserting projects..."
run_psql <<'SQL'
WITH upsert AS (
  INSERT INTO projects (id,name,slug,parent_id,raw_json)
  SELECT id,name,slug,parent_id,raw_json::jsonb FROM projects_delta
  ON CONFLICT (id) DO UPDATE SET
    name=EXCLUDED.name,
    slug=EXCLUDED.slug,
    parent_id=EXCLUDED.parent_id,
    raw_json=EXCLUDED.raw_json,
    ingested_at=EXCLUDED.ingested_at
  RETURNING xmax = 0 AS inserted
)
SELECT
  SUM(CASE WHEN inserted THEN 1 ELSE 0 END) AS inserted,
  SUM(CASE WHEN NOT inserted THEN 1 ELSE 0 END) AS updated
FROM upsert;
TRUNCATE projects_delta;
SQL

echo "Projects sync complete."
