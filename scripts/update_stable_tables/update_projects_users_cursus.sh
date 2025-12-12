#!/usr/bin/env bash
set -euo pipefail

# Update projects_users table (enrollments) for cursus 21 per campus.
# Fetches all per-campus project_users and upserts to database.
# Usage: ./update_projects_users_cursus.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CURSUS_ID=${CURSUS_ID:-21}
EXPORT_BASE_DIR="$ROOT_DIR/exports/06_project_users/cursus_${CURSUS_ID}"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/update_projects_users_cursus.log"

mkdir -p "$LOG_DIR"

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

if [[ -f "$ROOT_DIR/../.env" ]]; then
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
    docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T -e PGPASSWORD="$DB_PASSWORD" db psql -h db -U "$DB_USER" -d "$DB_NAME" "$@"
  else
    log "ERROR: psql not available"
    exit 1
  fi
}

log "====== UPDATE PROJECTS_USERS (CURSUS $CURSUS_ID) START ======"
START_TIME=$(date +%s)

# Find all campus directories
campus_dirs=$(find "$EXPORT_BASE_DIR" -maxdepth 1 -type d -name "campus_*" | sort)

if [[ -z "$campus_dirs" ]]; then
  log "WARNING: No campus directories found in $EXPORT_BASE_DIR"
  exit 0
fi

total_staged=0
total_inserted=0
total_updated=0

for campus_dir in $campus_dirs; do
  campus_id=$(basename "$campus_dir" | sed 's/campus_//')
  all_json="$campus_dir/all.json"
  
  if [[ ! -f "$all_json" ]]; then
    log "SKIP: Campus $campus_id - no all.json found"
    continue
  fi
  
  if ! jq -e 'type=="array"' "$all_json" >/dev/null 2>&1; then
    log "ERROR: Campus $campus_id all.json is not a valid array"
    continue
  fi
  
  count=$(jq '. | length' "$all_json")
  log "Campus $campus_id: Staging $count project_users records..."
  
  # Create staging table
  csv_tmp=$(mktemp)
  trap "rm -f $csv_tmp" EXIT
  
  jq -r '.[] | [
    .id,
    .user_id,
    .project_id,
    .cursus_id,
    .campus_id,
    .final_mark // null,
    (.status // ""),
    (.occurrence // 0),
    (now | floor)
  ] | @csv' "$all_json" > "$csv_tmp"
  
  staging_count=$(wc -l < "$csv_tmp")
  log "  Prepared $staging_count CSV rows (campus $campus_id)"
  
  # Upsert via psql COPY + ON CONFLICT
  log "  Upserting to projects_users (campus $campus_id)..."
  
  result=$(run_psql <<EOF
-- Create temp table
CREATE TEMP TABLE projects_users_delta (
  id BIGINT,
  user_id BIGINT,
  project_id BIGINT,
  cursus_id BIGINT,
  campus_id BIGINT,
  final_mark INT,
  status TEXT,
  occurrence INT,
  ingested_at BIGINT
);

-- Load CSV
COPY projects_users_delta FROM STDIN WITH (FORMAT csv);

-- Upsert (INSERT ON CONFLICT)
INSERT INTO projects_users (id, user_id, project_id, cursus_id, campus_id, final_mark, status, occurrence, ingested_at, created_at, updated_at)
  SELECT 
    d.id,
    d.user_id,
    d.project_id,
    d.cursus_id,
    d.campus_id,
    d.final_mark,
    d.status,
    d.occurrence,
    to_timestamp(d.ingested_at),
    now(),
    now()
  FROM projects_users_delta d
ON CONFLICT (id) DO UPDATE SET
  user_id = EXCLUDED.user_id,
  project_id = EXCLUDED.project_id,
  cursus_id = EXCLUDED.cursus_id,
  campus_id = EXCLUDED.campus_id,
  final_mark = EXCLUDED.final_mark,
  status = EXCLUDED.status,
  occurrence = EXCLUDED.occurrence,
  ingested_at = EXCLUDED.ingested_at,
  updated_at = now();

SELECT 
  (SELECT COUNT(*) FROM projects_users_delta) as staged,
  (SELECT COUNT(*) FROM projects_users WHERE campus_id = ${campus_id} AND cursus_id = ${CURSUS_ID}) as total;
EOF
  )
  
  staged=$(echo "$result" | tail -1 | awk '{print $1}')
  total=$(echo "$result" | tail -1 | awk '{print $2}')
  
  total_staged=$(( total_staged + staged ))
  total_inserted=$(( total_inserted + total ))
  
  log "  Campus $campus_id complete: $staged staged, $total total in DB"
done

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

log "====== UPDATE PROJECTS_USERS COMPLETE ======"
log "  Total staged: $total_staged"
log "  Total in DB: $total_inserted"
log "  Duration: ${DURATION}s"
log ""

exit 0
