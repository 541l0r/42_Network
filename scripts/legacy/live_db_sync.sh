#!/usr/bin/env bash
set -euo pipefail

# Live Delta Sync - Updates DB with real user changes
# One-time run: detect changed users in time window, update DB
# Tables: users (main), project_users (project enrollments), achievements_users (earned achievements)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"
LOG_DIR="$ROOT_DIR/logs"
DB_HOST="${DB_HOST:-localhost}"
DB_USER="${DB_USER:-api42}"
DB_PASS="${DB_PASS:-api42}"
DB_NAME="${DB_NAME:-api42}"

mkdir -p "$LOG_DIR"

# Use date-stamped log file (one per day)
LOG_FILE="$LOG_DIR/live_db_sync_$(date -u +%Y-%m-%d).log"

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

log "════════════════════════════════════════════════════════"
log "Live Delta Sync - DB Update"
log "════════════════════════════════════════════════════════"

# Refresh token first
bash "$TOKEN_HELPER" refresh > /dev/null 2>&1

WINDOW_SECONDS="${1:-30}"

# Calculate time window
END_TIME=$(date -u +%s)
START_TIME=$((END_TIME - WINDOW_SECONDS))

END_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($END_TIME, datetime.UTC).isoformat().replace('+00:00', 'Z'))")
START_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($START_TIME, datetime.UTC).isoformat().replace('+00:00', 'Z'))")

log "Time window: $START_ISO to $END_ISO"

# Fetch changed users from API - filter for students only (like update_users.sh does)
# NOTE: API query returns ALL users in time window, client-side filtering applies kind=student
response=$(bash "$TOKEN_HELPER" call "/v2/users?range%5Bupdated_at%5D=$START_ISO,$END_ISO&per_page=100&sort=-updated_at" 2>/dev/null || echo "[]")

user_count=$(echo "$response" | python3 -c "import json, sys; data = json.load(sys.stdin); print(len(data) if isinstance(data, list) else 0)" 2>/dev/null || echo "0")

log "Found $user_count changed users (will filter to kind=student)"

if [[ $user_count -eq 0 ]]; then
  log "No changes. Done."
  exit 0
fi

# Process each user - update DB tables
TEMP_FILE=$(mktemp)
echo "$response" > "$TEMP_FILE"
trap "rm -f $TEMP_FILE" EXIT

RESPONSE_FILE="$TEMP_FILE" DB_HOST="$DB_HOST" DB_USER="$DB_USER" DB_PASS="$DB_PASS" DB_NAME="$DB_NAME" python3 << 'PYTHON_EOF'
import json
import sys
import subprocess
import os

# Read response from file
with open(os.environ.get('RESPONSE_FILE')) as f:
    data = json.load(f)

db_host = os.environ.get('DB_HOST')
db_user = os.environ.get('DB_USER')
db_pass = os.environ.get('DB_PASS')
db_name = os.environ.get('DB_NAME')

users_updated = 0
projects_synced = 0
achievements_synced = 0

# Apply same filters as update_users.sh uses
FILTER_KIND = os.environ.get('FILTER_KIND', 'student')
FILTER_ALUMNI = os.environ.get('FILTER_ALUMNI', 'false')  # Exclude alumni by default
FILTER_STATUS = os.environ.get('FILTER_STATUS', '')  # optional

def should_include_user(user):
    """Check if user matches inclusion filters (same as update_users.sh)"""
    # Filter by kind
    if FILTER_KIND and user.get('kind') != FILTER_KIND:
        return False
    # Filter by alumni status - default: exclude alumni (alumni?=false)
    if FILTER_ALUMNI.lower() == 'false' and user.get('alumni?') == True:
        return False
    if FILTER_ALUMNI.lower() == 'true' and user.get('alumni?') == False:
        return False
    # Filter by status if set
    if FILTER_STATUS and user.get('status') != FILTER_STATUS:
        return False
    return True

def exec_sql(query):
    """Execute SQL query against PostgreSQL via docker"""
    # Use docker socket to run psql
    # Change to repo directory first for docker-compose
    repo_dir = '/srv/42_Network/repo'
    
    cmd = [
        'docker', 'compose', 'exec', '-T', 'db',
        'psql',
        '-U', db_user,
        '-d', db_name
    ]
    
    env = os.environ.copy()
    env['PGPASSWORD'] = db_pass
    
    result = subprocess.run(cmd, input=query, capture_output=True, text=True, env=env, cwd=repo_dir, timeout=5)
    return result.returncode == 0, result.stderr

for user in data:
    # Apply same filters as update_users.sh
    if not should_include_user(user):
        continue
    
    user_id = user.get('id')
    login = user.get('login')
    email = user.get('email', '').replace("'", "''")  # Escape for SQL
    
    # Extract all user fields - both real-time and stable data
    wallet = user.get('wallet')
    correction_point = user.get('correction_point')
    location = user.get('location', '')
    if location:
        location = location.replace("'", "''")
    # active? field: NULL means false (offline), treat None as false
    active = user.get('active?') or False
    updated_at = user.get('updated_at')
    
    # Stable/identity fields
    first_name = (user.get('first_name') or '').replace("'", "''")
    last_name = (user.get('last_name') or '').replace("'", "''")
    usual_full_name = (user.get('usual_full_name') or '').replace("'", "''")
    usual_first_name = (user.get('usual_first_name') or '').replace("'", "''")
    displayname = (user.get('displayname') or '').replace("'", "''")
    phone = (user.get('phone') or '').replace("'", "''")
    url = (user.get('url') or '').replace("'", "''")
    kind = user.get('kind', 'student')
    alumni = user.get('alumni?') or False
    staff = user.get('staff?') or False
    pool_month = (user.get('pool_month') or '').replace("'", "''")
    pool_year = (user.get('pool_year') or '').replace("'", "''")
    created_at = user.get('created_at')
    
    # Image fields
    image_link = (user.get('image', {}).get('link') or '').replace("'", "''")
    image_large = (user.get('image', {}).get('versions', {}).get('large') or '').replace("'", "''")
    image_medium = (user.get('image', {}).get('versions', {}).get('medium') or '').replace("'", "''")
    image_small = (user.get('image', {}).get('versions', {}).get('small') or '').replace("'", "''")
    image_micro = (user.get('image', {}).get('versions', {}).get('micro') or '').replace("'", "''")
    image_raw = user.get('image')
    image_json = "'" + json.dumps(image_raw).replace("'", "''") + "'" if image_raw else 'NULL'
    
    # Get campus (it's array, take first)
    campus_id = None
    campuses = user.get('campus', [])
    if isinstance(campuses, list) and len(campuses) > 0:
        campus_id = campuses[0].get('id')
    
    # INSERT or UPDATE users - handles both new users and updates, syncs all stable data
    insert_sql = f"""INSERT INTO users (id, login, email, first_name, last_name, usual_full_name, usual_first_name, displayname, phone, url, kind, alumni, staff, pool_month, pool_year, image_link, image_large, image_medium, image_small, image_micro, image, wallet, correction_point, location, active, campus_id, created_at, updated_at, ingested_at)
VALUES ({user_id}, '{login}', '{email}', '{first_name}', '{last_name}', '{usual_full_name}', '{usual_first_name}', '{displayname}', '{phone}', '{url}', '{kind}', {'true' if alumni else 'false'}, {'true' if staff else 'false'}, '{pool_month}', '{pool_year}', '{image_link}', '{image_large}', '{image_medium}', '{image_small}', '{image_micro}', {image_json}, {wallet or 0}, {correction_point or 0}, '{location}', {'true' if active else 'false'}, {campus_id or 'NULL'}, '{created_at or 'NOW()'}', '{updated_at or 'NOW()'}', NOW())
ON CONFLICT (id) DO UPDATE SET
  login=EXCLUDED.login,
  email=EXCLUDED.email,
  first_name=EXCLUDED.first_name,
  last_name=EXCLUDED.last_name,
  usual_full_name=EXCLUDED.usual_full_name,
  usual_first_name=EXCLUDED.usual_first_name,
  displayname=EXCLUDED.displayname,
  phone=EXCLUDED.phone,
  url=EXCLUDED.url,
  kind=EXCLUDED.kind,
  alumni=EXCLUDED.alumni,
  staff=EXCLUDED.staff,
  pool_month=EXCLUDED.pool_month,
  pool_year=EXCLUDED.pool_year,
  image_link=EXCLUDED.image_link,
  image_large=EXCLUDED.image_large,
  image_medium=EXCLUDED.image_medium,
  image_small=EXCLUDED.image_small,
  image_micro=EXCLUDED.image_micro,
  image=EXCLUDED.image,
  wallet=EXCLUDED.wallet,
  correction_point=EXCLUDED.correction_point,
  location=EXCLUDED.location,
  active=EXCLUDED.active,
  campus_id=EXCLUDED.campus_id,
  updated_at=EXCLUDED.updated_at,
  ingested_at=NOW();"""
    
    success, err = exec_sql(insert_sql)
    if success:
        users_updated += 1
    else:
        print(f"Error inserting/updating user {user_id}: {err}", file=sys.stderr)
    
    # Sync project_users (upsert) - user already enrolled in these projects
    projects = user.get('projects_users', [])
    for proj in projects:
        proj_id = proj.get('id')
        project_id = proj.get('project', {}).get('id')
        final_mark = proj.get('final_mark')
        status = proj.get('status', '').replace("'", "''")
        validated = proj.get('validated?')
        proj_created = proj.get('created_at')
        proj_updated = proj.get('updated_at')
        
        validated_bool = 'true' if validated else 'false'
        
        upsert_sql = f"""
        INSERT INTO project_users (id, project_id, campus_id, user_id, user_login, user_email, final_mark, status, validated, created_at, updated_at, ingested_at)
        VALUES ({proj_id}, {project_id}, {campus_id or 'NULL'}, {user_id}, '{login}', '{email}', {final_mark or 'NULL'}, '{status}', {validated_bool}, '{proj_created or 'NOW()'}', '{proj_updated or 'NOW()'}', NOW())
        ON CONFLICT (id) DO UPDATE SET 
          project_id=EXCLUDED.project_id,
          final_mark={final_mark or 'NULL'}, 
          status='{status}', 
          validated={validated_bool},
          created_at=EXCLUDED.created_at,
          updated_at='{proj_updated or 'NOW()'}',
          ingested_at=NOW();
        """
        
        success, err = exec_sql(upsert_sql)
        if success:
            projects_synced += 1
    
    # Sync achievements_users (upsert) - user earned these badges
    achievements = user.get('achievements', [])
    for ach in achievements:
        ach_id = ach.get('id')
        achievement_id = ach.get('achievement', {}).get('id')  # Get actual achievement ID
        ach_created = ach.get('created_at')
        ach_updated = ach.get('updated_at')
        
        if ach_id and achievement_id:
            upsert_sql = f"""
            INSERT INTO achievements_users (id, achievement_id, campus_id, user_id, user_login, user_email, created_at, updated_at, ingested_at)
            VALUES ({ach_id}, {achievement_id}, {campus_id or 'NULL'}, {user_id}, '{login}', '{email}', '{ach_created or 'NOW()'}', '{ach_updated or 'NOW()'}', NOW())
            ON CONFLICT (id) DO UPDATE SET 
              achievement_id=EXCLUDED.achievement_id,
              created_at=EXCLUDED.created_at,
              updated_at='{ach_updated or 'NOW()'}',
              ingested_at=NOW();
            """
            
            success, err = exec_sql(upsert_sql)
            if success:
                achievements_synced += 1

print(f"✓ Users: {users_updated} | Projects: {projects_synced} | Achievements: {achievements_synced}")
PYTHON_EOF

log "Sync complete."

