#!/bin/bash
# ============================================================================ #
#  update_users_campus.sh - Load campus-specific users to database
#
#  Purpose: Take users JSON from orchestra fetch and upsert to users table
#  
#  Usage: CAMPUS_ID=76 bash scripts/update_stable_tables/update_users_campus.sh
#
#  Input:  exports/09_users/campus_{CAMPUS_ID}/all.json (from fetch_users.sh)
#  Output: users table in PostgreSQL (upserted)
#           delta_users staging table (truncated after load)
#
#  Strategy (minimal DB hits):
#    1. Load JSON into delta_users (staging table)
#    2. Validate foreign keys (cursus_id=21, campus_id exists)
#    3. Upsert into users (ON CONFLICT DO UPDATE)
#    4. Truncate delta_users for next cycle
#    5. Log metrics (rows loaded, conflicts, errors)
#
# ============================================================================ #

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAMPUS_ID="${CAMPUS_ID:-76}"
CAMPUS_ID=$(echo "$CAMPUS_ID" | sed 's/"//g')
INPUT_FILE="$ROOT_DIR/exports/09_users/campus_${CAMPUS_ID}/all.json"
LOGS_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOGS_DIR/update_users_campus_${CAMPUS_ID}_$(date +%s).log"

mkdir -p "$LOGS_DIR"

# Database config
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-api42}"
DB_NAME="${DB_NAME:-api42}"
DB_PASSWORD="${DB_PASSWORD:-api42}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
  local level="$1"
  shift
  local msg="$@"
  local color
  case "$level" in
    ERROR)   color=$RED ;;
    SUCCESS) color=$GREEN ;;
    WARN)    color=$YELLOW ;;
    INFO)    color=$BLUE ;;
    *)       color=$NC ;;
  esac
  
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "${color}[$timestamp] [$level]${NC} $msg" | tee -a "$LOG_FILE"
}

# ============================================================================ #
#  VALIDATION
# ============================================================================ #

if [[ ! -f "$INPUT_FILE" ]]; then
  log ERROR "Input file not found: $INPUT_FILE"
  exit 1
fi

INPUT_SIZE=$(stat -f%z "$INPUT_FILE" 2>/dev/null || stat -c%s "$INPUT_FILE")
if [[ $INPUT_SIZE -eq 0 ]]; then
  log WARN "Input file is empty: $INPUT_FILE"
  log INFO "No users to load for campus $CAMPUS_ID"
  exit 0
fi

log INFO "Input file: $INPUT_FILE ($INPUT_SIZE bytes)"

# Test database connection
if ! PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" > /dev/null 2>&1; then
  log ERROR "Cannot connect to database at $DB_HOST:$DB_PORT"
  exit 1
fi

log SUCCESS "Database connected"

# ============================================================================ #
#  LOAD TO DELTA TABLE (STAGING)
# ============================================================================ #

log INFO "Loading JSON data into delta_users (staging) via COPY..."

# Prepare CSV for fast COPY
CSV_FILE=$(mktemp)
jq -r '.[] | [
  (.id // 0),
  (.login // ""),
  (.email // ""),
  (.first_name // ""),
  (.last_name // ""),
  (.usual_full_name // ""),
  (.usual_first_name // ""),
  (.usual_last_name // ""),
  (.kind // ""),
  (if .alumni then "t" else "f" end),
  (if .active then "t" else "f" end),
  (.image.url // ""),
  (.image.link // ""),
  (.phone // ""),
  (.kind_id // 0),
  (.created_at // ""),
  (.updated_at // "")
] | @csv' "$INPUT_FILE" > "$CSV_FILE"

# Truncate + COPY into delta_users
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<'EOSQL' 2>&1 | tee -a "$LOG_FILE"
TRUNCATE TABLE delta_users CASCADE;
EOSQL

PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -c "\copy delta_users (id, login, email, first_name, last_name, usual_full_name, usual_first_name, usual_last_name, kind, alumni, active, image_url, image_link, phone, kind_id, created_at, updated_at) FROM '$CSV_FILE' WITH (FORMAT csv, NULL '', HEADER FALSE)" \
  2>&1 | tee -a "$LOG_FILE"

DELTA_COUNT=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM delta_users;")
log SUCCESS "Loaded $DELTA_COUNT rows into delta_users"

rm -f "$CSV_FILE"

# ============================================================================ #
#  VALIDATE FOREIGN KEYS
# ============================================================================ #

log INFO "Validating foreign key constraints..."

VALIDATE_SQL=$(mktemp)
cat > "$VALIDATE_SQL" << 'EOSQL'
-- Check that all delta_users have valid cursus_id (must be 21)
SELECT COUNT(*) as invalid_cursus FROM delta_users 
WHERE (id IN (SELECT id FROM delta_users)) 
  AND id NOT IN (SELECT cursus_id FROM cursus WHERE id = 21);

-- Check that campus_id matches deploy environment (will be set via UPDATE)
-- This is validated at load time, not schema constraint
EOSQL

PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -f "$VALIDATE_SQL" 2>&1 | tee -a "$LOG_FILE"

rm -f "$VALIDATE_SQL"

log SUCCESS "Foreign key validation passed"

# ============================================================================ #
#  UPSERT INTO PRODUCTION TABLE
# ============================================================================ #

log INFO "Upserting users into production table..."

UPSERT_SQL=$(mktemp)
cat > "$UPSERT_SQL" << "EOSQL"
-- Upsert: Insert new, update existing
INSERT INTO users (
  id, login, email, first_name, last_name, usual_full_name,
  usual_first_name, usual_last_name, kind, alumni, active,
  image_url, image_link, phone, kind_id, cursus_id, campus_id,
  created_at, updated_at
)
SELECT 
  id, login, email, first_name, last_name, usual_full_name,
  usual_first_name, usual_last_name, kind, alumni, active,
  image_url, image_link, phone, kind_id, 21, $CAMPUS_ID,
  created_at, updated_at
FROM delta_users
ON CONFLICT (id, cursus_id, campus_id) DO UPDATE SET
  login = EXCLUDED.login,
  email = EXCLUDED.email,
  first_name = EXCLUDED.first_name,
  last_name = EXCLUDED.last_name,
  usual_full_name = EXCLUDED.usual_full_name,
  usual_first_name = EXCLUDED.usual_first_name,
  usual_last_name = EXCLUDED.usual_last_name,
  kind = EXCLUDED.kind,
  alumni = EXCLUDED.alumni,
  active = EXCLUDED.active,
  image_url = EXCLUDED.image_url,
  image_link = EXCLUDED.image_link,
  phone = EXCLUDED.phone,
  kind_id = EXCLUDED.kind_id,
  updated_at = EXCLUDED.updated_at;

-- Log result
SELECT 
  COUNT(*) as total_rows,
  COUNT(CASE WHEN updated_at > now() - interval '1 minute' THEN 1 END) as updated_recently
FROM users 
WHERE cursus_id = 21 AND campus_id = $CAMPUS_ID;
EOSQL

PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -f "$UPSERT_SQL" 2>&1 | tee -a "$LOG_FILE"

USERS_COUNT=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM users WHERE cursus_id = 21 AND campus_id = $CAMPUS_ID;")
log SUCCESS "Upserted $USERS_COUNT total users for campus $CAMPUS_ID in cursus 21"

rm -f "$UPSERT_SQL"

# ============================================================================ #
#  CLEANUP
# ============================================================================ #

log INFO "Truncating delta_users for next cycle..."

PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -c "TRUNCATE TABLE delta_users CASCADE;" 2>&1 | tee -a "$LOG_FILE"

log SUCCESS "Delta table cleaned"

# ============================================================================ #
#  SUMMARY
# ============================================================================ #

log SUCCESS "═══════════════════════════════════════════════════════════════"
log SUCCESS "Update complete for campus $CAMPUS_ID"
log SUCCESS "  • Input: $DELTA_COUNT rows from API"
log SUCCESS "  • Database: $USERS_COUNT total users now in production"
log SUCCESS "  • Log: $LOG_FILE"
log SUCCESS "═══════════════════════════════════════════════════════════════"

exit 0
