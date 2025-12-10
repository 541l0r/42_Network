#!/usr/bin/env bash
set -euo pipefail

# Incrementally fetch achievements updated since last sync and upsert into Postgres.
# Uses the 42 API range[updated_at] filter and ON CONFLICT upsert.
# Requirements:
# - token_manager.sh configured with valid 42 OAuth tokens (.env at /srv/42_Network/.env)
# - jq installed
# - psql locally or via docker compose (db service)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPORT_DIR="$ROOT_DIR/exports/achievements"
STAMP_FILE="$EXPORT_DIR/.last_updated_at"

mkdir -p "$EXPORT_DIR"

# DB config
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

# Choose docker compose if local psql absent
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

# Args
SINCE=""
UNTIL=""
PER_PAGE=100
MIN_FETCH_AGE_SECONDS=${MIN_FETCH_AGE_SECONDS:-86400}
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="${2:?missing value for --since}"; shift 2 ;;
    --until) UNTIL="${2:?missing value for --until}"; shift 2 ;;
    --per-page) PER_PAGE="${2:?missing value for --per-page}"; shift 2 ;;
    --force-full) SINCE="1970-01-01T00:00:00Z"; MIN_FETCH_AGE_SECONDS=0; shift ;;
    --force) MIN_FETCH_AGE_SECONDS=0; shift ;;
    --min-age) MIN_FETCH_AGE_SECONDS="${2:?missing seconds for --min-age}"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$SINCE" ]]; then
  if [[ -f "$STAMP_FILE" ]]; then
    stamp_val=$(cat "$STAMP_FILE")
    # Try to interpret stamp as epoch; if not, parse as ISO.
    if [[ "$stamp_val" =~ ^[0-9]+$ ]]; then
      last_run_epoch="$stamp_val"
    else
      last_run_epoch=$(date -d "$stamp_val" +%s 2>/dev/null || echo "")
    fi
    if [[ -n "$last_run_epoch" ]]; then
      now=$(date +%s)
      age=$(( now - last_run_epoch ))
      if (( age < MIN_FETCH_AGE_SECONDS )); then
        echo "Skipping achievements fetch: last run $age seconds ago (< ${MIN_FETCH_AGE_SECONDS}s)."
        exit 0
      fi
      SINCE=$(date -u -d "@$last_run_epoch" +"%Y-%m-%dT%H:%M:%SZ")
    else
      SINCE="1970-01-01T00:00:00Z"
    fi
  else
    SINCE="1970-01-01T00:00:00Z"
  fi
fi
if [[ -z "$UNTIL" ]]; then
  UNTIL=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
fi

echo "Delta fetch achievements from $SINCE to $UNTIL (per_page=$PER_PAGE)..."

# Ensure target table exists; bail if missing
if ! run_psql -Atqc "SELECT to_regclass('public.achievements')" | grep -q achievements; then
  echo "Table achievements not found. Create it before running this script." >&2
  exit 1
fi

# Prep staging table (session-agnostic)
run_psql <<'SQL'
DROP TABLE IF EXISTS achievements_delta;
CREATE TABLE achievements_delta (LIKE achievements INCLUDING DEFAULTS);
TRUNCATE achievements_delta;
SQL

page=1
total=0
total_kb=0
max_seen=""
while true; do
  endpoint="/v2/achievements?sort=updated_at&range%5Bupdated_at%5D=${SINCE},${UNTIL}&page=${page}&per_page=${PER_PAGE}"
  echo "Fetching page $page..."
  resp=$("$SCRIPT_DIR/token_manager.sh" call "$endpoint")
  page_kb=$(( $(printf '%s' "$resp" | wc -c) / 1024 ))
  total_kb=$(( total_kb + page_kb ))
  count=$(echo "$resp" | jq 'length')
  if (( count == 0 )); then
    echo "No more results."
    break
  fi
  total=$((total + count))

  # Load into staging
  echo "$resp" | jq -r '.[] | [
    .id,
    .name,
    .description,
    .tier,
    .kind,
    .visible,
    .image,
    .nbr_of_success,
    .users_url,
    (.parent.id // .parent // null),
    (.title.name // .title.id // .title // null),
    (tojson)
  ] | @csv' \
    | run_psql -c "\copy achievements_delta (id,name,description,tier,kind,visible,image,nbr_of_success,users_url,parent_id,title,raw_json) FROM STDIN WITH (FORMAT csv)"

  upsert_result=$(run_psql -At <<'SQL'
WITH upsert AS (
  INSERT INTO achievements (id,name,description,tier,kind,visible,image,nbr_of_success,users_url,parent_id,title,raw_json,ingested_at)
  SELECT id,name,description,tier,kind,visible,image,nbr_of_success,users_url,parent_id,title,raw_json,ingested_at
  FROM achievements_delta
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
    raw_json=EXCLUDED.raw_json,
    ingested_at=EXCLUDED.ingested_at
  WHERE achievements.name IS DISTINCT FROM EXCLUDED.name
     OR achievements.description IS DISTINCT FROM EXCLUDED.description
     OR achievements.tier IS DISTINCT FROM EXCLUDED.tier
     OR achievements.kind IS DISTINCT FROM EXCLUDED.kind
     OR achievements.visible IS DISTINCT FROM EXCLUDED.visible
     OR achievements.image IS DISTINCT FROM EXCLUDED.image
     OR achievements.nbr_of_success IS DISTINCT FROM EXCLUDED.nbr_of_success
     OR achievements.users_url IS DISTINCT FROM EXCLUDED.users_url
     OR achievements.parent_id IS DISTINCT FROM EXCLUDED.parent_id
     OR achievements.title IS DISTINCT FROM EXCLUDED.title
     OR achievements.raw_json IS DISTINCT FROM EXCLUDED.raw_json
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
  echo "Upserted achievements: inserted=$inserted_count updated=$updated_count"

  run_psql <<'SQL'
TRUNCATE achievements_delta;
SQL

  page_max=$(echo "$resp" | jq -r '[.[].updated_at] | map(select(. != null)) | max // empty')
  if [[ -n "$page_max" ]]; then
    if [[ -z "$max_seen" || "$page_max" > "$max_seen" ]]; then
      max_seen="$page_max"
    fi
  fi

  (( page += 1 ))
done

if [[ -n "$max_seen" ]]; then
  echo "$max_seen" > "$STAMP_FILE"
  echo "Updated last_updated_at -> $max_seen"
else
  # Fallback to the end of the window so we don't refetch everything next run.
  echo "$UNTIL" > "$STAMP_FILE"
  echo "No updated_at values seen; advancing last_updated_at -> $UNTIL"
fi

# Normalize stamp file to epoch for future runs
if [[ -f "$STAMP_FILE" ]]; then
  ts=$(cat "$STAMP_FILE")
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    epoch_ts="$ts"
  else
    epoch_ts=$(date -d "$ts" +%s 2>/dev/null || echo "")
  fi
  if [[ -n "$epoch_ts" ]]; then
    echo "$epoch_ts" > "$STAMP_FILE"
  fi
fi

printf "timestamp=%s\npages=%s\nitems_merged=%s\ndownloaded_kB=%s\n" "$(date +%s)" "$page" "$total" "$total_kb" > "$METRIC_FILE"

echo "Done. Upserted ${total} records."
