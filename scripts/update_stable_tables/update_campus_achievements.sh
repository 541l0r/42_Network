#!/usr/bin/env bash
set -euo pipefail

# Fetch campus achievements and upsert into Postgres.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$ROOT_DIR/scripts/helpers/fetch_campus_achievements.sh"
EXPORT_DIR="$ROOT_DIR/exports/04_campus_achievements"
MERGED_JSON="$EXPORT_DIR/raw_all.json"
LINKS_JSON="$EXPORT_DIR/all.json"

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

# Ensure token is fresh before starting API calls
"$ROOT_DIR/scripts/token_manager.sh" ensure-fresh >&2

echo "Checking for campus achievements data..."
if [[ ! -s "$MERGED_JSON" ]]; then
  echo "No raw_all.json found, attempting to merge from campus directories..."
  jq -s 'add' "$EXPORT_DIR"/campus_*/all.json > "$MERGED_JSON" 2>/dev/null || echo "[] " > "$MERGED_JSON"
fi

if [[ ! -s "$MERGED_JSON" ]]; then
  echo "No campus achievements data found at $MERGED_JSON" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

# Build normalized achievements on the fly (not persisted).
ACHIEVEMENTS_JSON=$(mktemp)
LINKS_JSON="${LINKS_JSON:-$(mktemp)}"
jq 'map(select(.id != null)) | sort_by(.id) | group_by(.id) | map(.[0] | del(.campus_id))' "$MERGED_JSON" > "$ACHIEVEMENTS_JSON"
jq '[.[] | select(.campus_id != null and .id != null) | {campus_id, achievement_id: .id}]' "$MERGED_JSON" > "$LINKS_JSON"

run_psql <<'SQL'
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'achievements' AND column_name = 'raw_json'
  ) THEN
    EXECUTE 'ALTER TABLE achievements DROP COLUMN raw_json';
  END IF;
END$$;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'campus_achievements' AND column_name = 'raw_json'
  ) THEN
    EXECUTE 'ALTER TABLE campus_achievements DROP COLUMN raw_json';
  END IF;
END$$;
DROP TABLE IF EXISTS achievements_delta;
CREATE TABLE achievements_delta (LIKE achievements INCLUDING DEFAULTS);
TRUNCATE achievements_delta;
SQL

echo "Staging achievements into achievements_delta..."
jq -r '.[] | [
  (.id // null),
  (.name // ""),
  (.description // ""),
  (.tier // ""),
  (.kind // ""),
  (.visible // null),
  (.image // ""),
  (.nbr_of_success // null),
  (.users_url // ""),
  (if (.parent | type) == "object" then (.parent.id // null) else null end),
  (if (.title | type) == "object" then (.title.name // "") else (.title // null) end)
] | @csv' "$ACHIEVEMENTS_JSON" \
  | run_psql -c "\copy achievements_delta (id,name,description,tier,kind,visible,image,nbr_of_success,users_url,parent_id,title) FROM STDIN WITH (FORMAT csv, NULL '')"

delta_count=$(run_psql -t -c "SELECT COUNT(*) FROM achievements_delta")
if [ "$delta_count" = "0" ]; then
  echo "Skip upsert: No changes in achievements_delta (using cached data)"
  exit 0
fi

echo "Upserting achievements..."
run_psql <<'SQL'
WITH upsert AS (
  INSERT INTO achievements (id,name,description,tier,kind,visible,image,nbr_of_success,users_url,parent_id,title,ingested_at)
  SELECT id,name,description,tier,kind,visible,image,nbr_of_success,users_url,parent_id,title,ingested_at FROM achievements_delta
  ON CONFLICT (id) DO UPDATE SET
    name=EXCLUDED.name,
    description=EXCLUDED.description,
    tier=EXCLUDED.tier,
    kind=EXCLUDED.kind,
    visible=EXCLUDED.visible,
    image=EXCLUDED.image,
    nbr_of_success=EXCLUDED.nbr_of_success,
    users_url=EXCLUDED.users_url,
    parent_id=EXCLUDED.parent_id,
    title=EXCLUDED.title,
    ingested_at=EXCLUDED.ingested_at
  RETURNING (xmax = 0) AS inserted
)
SELECT
  count(*) FILTER (WHERE inserted) AS inserted,
  count(*) FILTER (WHERE NOT inserted) AS updated
FROM upsert;
TRUNCATE achievements_delta;
SQL

run_psql <<'SQL'
DROP TABLE IF EXISTS campus_achievements_delta;
CREATE TABLE campus_achievements_delta (LIKE campus_achievements INCLUDING DEFAULTS);
TRUNCATE campus_achievements_delta;
SQL

echo "Staging into campus_achievements_delta..."
jq -r '.[] | select(.id != null and .campus_id != null) | [
  .campus_id,
  .id
] | @csv' "$MERGED_JSON" \
  | run_psql -c "\copy campus_achievements_delta (campus_id,achievement_id) FROM STDIN WITH (FORMAT csv, NULL '')"

delta_count=$(run_psql -t -c "SELECT COUNT(*) FROM campus_achievements_delta")
if [ "$delta_count" = "0" ]; then
  echo "Skip upsert: No changes in campus_achievements_delta (using cached data)"
  exit 0
fi

echo "Upserting campus achievements..."
run_psql <<'SQL'
WITH upsert AS (
  INSERT INTO campus_achievements (campus_id,achievement_id,ingested_at)
  SELECT campus_id,achievement_id,ingested_at FROM campus_achievements_delta
  ON CONFLICT (campus_id, achievement_id) DO UPDATE SET
    ingested_at=EXCLUDED.ingested_at
  RETURNING (xmax = 0) AS inserted
)
SELECT
  count(*) FILTER (WHERE inserted) AS inserted,
  count(*) FILTER (WHERE NOT inserted) AS updated
FROM upsert;
TRUNCATE campus_achievements_delta;
SQL

ach_count=$(run_psql -Atc "SELECT count(*) FROM achievements;")
ach_recent=$(run_psql -Atc "SELECT count(*) FROM achievements WHERE ingested_at >= now() - interval '1 minute';")
link_count=$(run_psql -Atc "SELECT count(*) FROM campus_achievements;")
link_recent=$(run_psql -Atc "SELECT count(*) FROM campus_achievements WHERE ingested_at >= now() - interval '1 minute';")
echo "Achievements: total=$ach_count, recently_ingested=$ach_recent"
echo "Campus achievements: total=$link_count, recently_ingested=$link_recent"
echo "Campus achievements sync complete."
