#!/usr/bin/env bash
set -euo pipefail

# Fetch coalitions_users (user memberships + scores/ranks) and upsert into Postgres.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$ROOT_DIR/scripts/helpers/fetch_coalitions_users.sh"
EXPORT_DIR="$ROOT_DIR/exports/09_coalitions_users"
MERGED_JSON="$EXPORT_DIR/all.json"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/update_coalitions_users.log"

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

log "====== UPDATE COALITIONS_USERS START ======"
START_TIME=$(date +%s)

echo "Fetching coalitions_users..."
set +e
"$HELPER"
helper_status=$?
set -e
if [[ $helper_status -eq 3 ]]; then
  log "Using cached coalitions_users fetch (skip due to recency)."
elif [[ $helper_status -ne 0 ]]; then
  log "ERROR: Coalitions_users fetch failed with status $helper_status"
  exit $helper_status
fi

if [[ ! -s "$MERGED_JSON" ]]; then
  log "ERROR: No coalitions_users data found at $MERGED_JSON"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq is required."
  exit 1
fi

run_psql <<'SQL'
CREATE TABLE IF NOT EXISTS coalitions_users (
  id            BIGINT PRIMARY KEY,
  coalition_id  BIGINT NOT NULL,
  user_id       BIGINT NOT NULL,
  score         INTEGER DEFAULT 0,
  rank          INTEGER,
  campus_id     BIGINT,
  created_at    TIMESTAMPTZ,
  updated_at    TIMESTAMPTZ,
  ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_coalitions_users_coalition
    FOREIGN KEY (coalition_id) REFERENCES coalitions(id) ON DELETE CASCADE,
  CONSTRAINT fk_coalitions_users_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_coalitions_users_coalition_id ON coalitions_users (coalition_id);
CREATE INDEX IF NOT EXISTS idx_coalitions_users_user_id ON coalitions_users (user_id);
CREATE INDEX IF NOT EXISTS idx_coalitions_users_campus_id ON coalitions_users (campus_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_coalitions_users_unique ON coalitions_users (coalition_id, user_id);
DROP TABLE IF EXISTS coalitions_users_delta;
CREATE TABLE coalitions_users_delta (LIKE coalitions_users INCLUDING DEFAULTS);
TRUNCATE coalitions_users_delta;
SQL

echo "Staging coalitions_users..."
jq -r '.[] | [
  .id,
  (.coalition_id // null),
  (.user_id // null),
  (.score // 0),
  (.rank // null),
  (.campus_id // null),
  (.created_at // ""),
  (.updated_at // "")
] | @csv' "$MERGED_JSON" \
  | run_psql -c "\copy coalitions_users_delta (id,coalition_id,user_id,score,rank,campus_id,created_at,updated_at) FROM STDIN WITH (FORMAT csv, NULL '')"

echo "Removing duplicate (coalition_id, user_id) pairs - keeping latest by id..."
run_psql <<'SQL'
DELETE FROM coalitions_users_delta
WHERE id NOT IN (
  SELECT DISTINCT ON (coalition_id, user_id) id
  FROM coalitions_users_delta
  ORDER BY coalition_id, user_id, id DESC
);
SQL

echo "Pruning coalitions_users missing from this snapshot..."
run_psql <<'SQL'
DELETE FROM coalitions_users cu
WHERE NOT EXISTS (SELECT 1 FROM coalitions_users_delta d WHERE d.id = cu.id);
SQL

echo "Upserting coalitions_users (ignoring missing coalition FKs)..."
run_psql <<'SQL'
-- Temporarily disable FK constraint
ALTER TABLE coalitions_users DROP CONSTRAINT fk_coalitions_users_coalition;

WITH upsert AS (
  INSERT INTO coalitions_users (id,coalition_id,user_id,score,rank,campus_id,created_at,updated_at)
  SELECT id,coalition_id,user_id,score,rank,campus_id,created_at,updated_at FROM coalitions_users_delta
  ON CONFLICT (id) DO UPDATE SET
    coalition_id=EXCLUDED.coalition_id,
    user_id=EXCLUDED.user_id,
    score=EXCLUDED.score,
    rank=EXCLUDED.rank,
    campus_id=EXCLUDED.campus_id,
    created_at=EXCLUDED.created_at,
    updated_at=EXCLUDED.updated_at,
    ingested_at=EXCLUDED.ingested_at
  RETURNING xmax = 0 AS inserted
)
SELECT
  SUM(CASE WHEN inserted THEN 1 ELSE 0 END) AS inserted,
  SUM(CASE WHEN NOT inserted THEN 1 ELSE 0 END) AS updated
FROM upsert;

-- Re-enable FK constraint
ALTER TABLE coalitions_users ADD CONSTRAINT fk_coalitions_users_coalition
  FOREIGN KEY (coalition_id) REFERENCES coalitions(id) ON DELETE CASCADE;

TRUNCATE coalitions_users_delta;
SQL

inserted=$(run_psql -Atc "SELECT count(*) FROM coalitions_users WHERE ingested_at >= now() - interval '1 minute';")
total=$(run_psql -Atc "SELECT count(*) FROM coalitions_users;")
log "Coalitions_users: total=$total, recently_ingested=$inserted"

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
log "====== UPDATE COALITIONS_USERS COMPLETE (${DURATION}s) ======"
log "Log: $LOG_FILE"
log ""
