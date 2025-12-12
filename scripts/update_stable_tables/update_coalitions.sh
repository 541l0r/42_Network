#!/usr/bin/env bash
set -euo pipefail

# Fetch coalitions and upsert into Postgres.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$ROOT_DIR/scripts/helpers/fetch_coalitions.sh"
EXPORT_DIR="$ROOT_DIR/exports/08_coalitions"
MERGED_JSON="$EXPORT_DIR/all.json"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/update_coalitions.log"

mkdir -p "$LOG_DIR"

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

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
    log "ERROR: psql is not available"
    exit 1
  fi
}

if [[ ! -x "$HELPER" ]]; then
  log "ERROR: Helper script not found or not executable: $HELPER"
  exit 1
fi

# Ensure token is fresh before starting API calls
"$ROOT_DIR/scripts/token_manager.sh" ensure-fresh >&2

log "====== UPDATE COALITIONS START ======"
START_TIME=$(date +%s)

echo "Fetching coalitions..."
set +e
"$HELPER"
helper_status=$?
set -e
if [[ $helper_status -eq 3 ]]; then
  log "Using cached coalitions fetch (skip due to recency)."
elif [[ $helper_status -ne 0 ]]; then
  log "ERROR: Coalitions fetch failed with status $helper_status"
  exit $helper_status
fi

if [[ ! -s "$MERGED_JSON" ]]; then
  log "ERROR: No coalitions data found at $MERGED_JSON"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq is required."
  exit 1
fi

run_psql <<'SQL'
CREATE TABLE IF NOT EXISTS coalitions (
  id            BIGINT PRIMARY KEY,
  name          VARCHAR(255) NOT NULL,
  slug          VARCHAR(255) NOT NULL,
  image_url     TEXT,
  cover_url     TEXT,
  color         VARCHAR(7),
  score         INTEGER DEFAULT 0,
  user_id       BIGINT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Drop UNIQUE constraint on slug if it exists (slugs are not unique)
ALTER TABLE coalitions DROP CONSTRAINT IF EXISTS coalitions_slug_key;

CREATE INDEX IF NOT EXISTS idx_coalitions_slug ON coalitions (slug);
CREATE INDEX IF NOT EXISTS idx_coalitions_user_id ON coalitions (user_id);
CREATE INDEX IF NOT EXISTS idx_coalitions_score ON coalitions (score);
DROP TABLE IF EXISTS coalitions_delta;
CREATE TABLE coalitions_delta (LIKE coalitions INCLUDING DEFAULTS);
TRUNCATE coalitions_delta;
SQL

echo "Staging coalitions..."
jq -r '.[] | [
  .id,
  (.name // ""),
  (.slug // ""),
  (.image_url // ""),
  (.cover_url // ""),
  ((.color // "") | gsub("^\\s+|\\s+$"; "")),
  (.score // 0),
  (.user_id // null)
] | @csv' "$MERGED_JSON" \
  | run_psql -c "\copy coalitions_delta (id,name,slug,image_url,cover_url,color,score,user_id) FROM STDIN WITH (FORMAT csv, NULL '')"

delta_count=$(run_psql -t -c "SELECT COUNT(*) FROM coalitions_delta")
if [ "$delta_count" = "0" ]; then
  echo "Skip upsert: No changes in coalitions_delta (using cached data)"
  exit 0
fi

echo "Pruning coalitions missing from this snapshot..."
run_psql <<'SQL'
DELETE FROM coalitions c
WHERE NOT EXISTS (SELECT 1 FROM coalitions_delta d WHERE d.id = c.id);
SQL

echo "Upserting coalitions..."
run_psql <<'SQL'
WITH upsert AS (
  INSERT INTO coalitions (id,name,slug,image_url,cover_url,color,score,user_id)
  SELECT id,name,slug,image_url,cover_url,color,score,user_id FROM coalitions_delta
  ON CONFLICT (id) DO UPDATE SET
    name=EXCLUDED.name,
    slug=EXCLUDED.slug,
    image_url=EXCLUDED.image_url,
    cover_url=EXCLUDED.cover_url,
    color=EXCLUDED.color,
    score=EXCLUDED.score,
    user_id=EXCLUDED.user_id,
    updated_at=CURRENT_TIMESTAMP,
    ingested_at=EXCLUDED.ingested_at
  RETURNING xmax = 0 AS inserted
)
SELECT
  SUM(CASE WHEN inserted THEN 1 ELSE 0 END) AS inserted,
  SUM(CASE WHEN NOT inserted THEN 1 ELSE 0 END) AS updated
FROM upsert;
TRUNCATE coalitions_delta;
SQL

inserted=$(run_psql -Atc "SELECT count(*) FROM coalitions WHERE ingested_at >= now() - interval '1 minute';")
total=$(run_psql -Atc "SELECT count(*) FROM coalitions;")
log "Coalitions: total=$total, recently_ingested=$inserted"

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
log "====== UPDATE COALITIONS COMPLETE (${DURATION}s) ======"
log "Log: $LOG_FILE"
log ""
