#!/usr/bin/env bash
set -euo pipefail

# Update achievements_users table (badge enrollments) per campus.
# Derives achievements_users from campus_achievements data.
# Usage: ./update_achievements_cursus.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORT_DIR="$ROOT_DIR/exports/04_campus_achievements"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/update_achievements_cursus.log"

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

log "====== UPDATE ACHIEVEMENTS (CURSUS 21) START ======"
START_TIME=$(date +%s)

if [[ ! -d "$EXPORT_DIR" ]]; then
  log "ERROR: Achievements export directory not found: $EXPORT_DIR"
  exit 1
fi

# First, update achievements table (reference data)
log "Step 1: Updating achievements reference table..."

campus_dirs=$(find "$EXPORT_DIR" -maxdepth 1 -type d -name "campus_*" | sort)

if [[ -z "$campus_dirs" ]]; then
  log "WARNING: No campus directories found in $EXPORT_DIR"
  exit 0
fi

total_achievements=0
total_achievement_users=0

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
  log "Campus $campus_id: Processing $count achievements..."
  
  # Update achievements table
  csv_tmp=$(mktemp)
  trap "rm -f $csv_tmp" EXIT
  
  jq -r '.[] | [
    .id,
    (.name // ""),
    (.description // ""),
    (.image // ""),
    (.campus_id // 0),
    (now | floor)
  ] | @csv' "$all_json" > "$csv_tmp"
  
  ach_count=$(wc -l < "$csv_tmp")
  log "  Staging $ach_count achievement records (campus $campus_id)"
  
  result=$(run_psql <<EOF
CREATE TEMP TABLE achievements_delta (
  id BIGINT,
  name TEXT,
  description TEXT,
  image TEXT,
  campus_id BIGINT,
  ingested_at BIGINT
);

COPY achievements_delta FROM STDIN WITH (FORMAT csv);

INSERT INTO achievements (id, name, description, image, campus_id, ingested_at, created_at, updated_at)
  SELECT 
    d.id,
    d.name,
    d.description,
    d.image,
    d.campus_id,
    to_timestamp(d.ingested_at),
    now(),
    now()
  FROM achievements_delta d
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  image = EXCLUDED.image,
  campus_id = EXCLUDED.campus_id,
  ingested_at = EXCLUDED.ingested_at,
  updated_at = now();

SELECT COUNT(*) FROM achievements WHERE campus_id = ${campus_id};
EOF
  )
  
  ach_total=$(echo "$result" | tail -1 | xargs)
  total_achievements=$(( total_achievements + ach_total ))
  log "  Campus $campus_id: $ach_count achievements staged, $ach_total total in DB"
done

log "Step 1 complete: $total_achievements total achievements in DB"

# Step 2: Extract achievements_users from projects_users
log "Step 2: Extracting achievements_users from projects_users table..."

result=$(run_psql <<EOF
-- Extract achievements_users where achievement_id is present
INSERT INTO achievements_users (id, user_id, achievement_id, cursus_id, created_at, updated_at, ingested_at)
SELECT 
  (user_id::text || '_' || achievement_id::text)::bigint as id,  -- Simple composite ID
  pu.user_id,
  NULL::bigint as achievement_id,  -- To be filled from projects_users.achievement_id if available
  pu.cursus_id,
  now(),
  now(),
  to_timestamp(EXTRACT(epoch FROM now())::bigint)
FROM projects_users pu
WHERE pu.cursus_id = 21
ON CONFLICT (id) DO UPDATE SET
  updated_at = now();

SELECT COUNT(*) FROM achievements_users;
EOF
  )

au_total=$(echo "$result" | tail -1 | xargs)
log "Step 2 complete: $au_total achievements_users records in DB"

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

log "====== UPDATE ACHIEVEMENTS COMPLETE ======"
log "  Total achievements: $total_achievements"
log "  Total achievement_users: $au_total"
log "  Duration: ${DURATION}s"
log ""

exit 0
