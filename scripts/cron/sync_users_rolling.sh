#!/bin/bash

# sync_users_rolling.sh - Simple rolling window sync (every minute)
# Detects user changes in last 65 seconds, fetches and updates in one pass

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
EXPORTS_DIR="$ROOT_DIR/exports/08_users"

# Database configuration (can be overridden by environment variables)
DB_HOST="${DB_HOST:-localhost}"
DB_USER="${DB_USER:-api42}"
DB_PASS="${DB_PASS:-api42}"
DB_NAME="${DB_NAME:-api42}"

# Create log directory if needed
mkdir -p "$LOG_DIR"

# Rolling window: detect changes in last 65 seconds (allows for 5 sec detection offset)
CURRENT_TIME=$(date -u +%s)
WINDOW_START=$((CURRENT_TIME - 65))
WINDOW_END=$CURRENT_TIME

WINDOW_START_ISO=$(date -u -d @$WINDOW_START +'%Y-%m-%dT%H:%M:%SZ')
WINDOW_END_ISO=$(date -u -d @$WINDOW_END +'%Y-%m-%dT%H:%M:%SZ')

LOG_TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

echo "[${LOG_TIMESTAMP}] Starting rolling window sync..."
echo "[${LOG_TIMESTAMP}] Starting fetch of cursus 21 students (delta fetch)..."
echo "[${LOG_TIMESTAMP}] Time range: ${WINDOW_START_ISO} to ${WINDOW_END_ISO}"
echo "[${LOG_TIMESTAMP}] Starting fetch: per_page=100"

# Fetch changed users from API
FETCH_OUTPUT=$("$ROOT_DIR/scripts/helpers/fetch_cursus_21_users_simple.sh" "$WINDOW_START_ISO" "$WINDOW_END_ISO" 2>&1)
FETCH_EXIT=$?

if [ $FETCH_EXIT -ne 0 ]; then
    echo "[${LOG_TIMESTAMP}] Error: Fetch failed"
    echo "$FETCH_OUTPUT" | while IFS= read -r line; do
        echo "[${LOG_TIMESTAMP}] $line"
    done
    exit 1
fi

# Parse fetch output to count results
FILTERED_COUNT=$(echo "$FETCH_OUTPUT" | grep -oP 'filtered=\K[0-9]+' | head -1 || echo "0")
RAW_COUNT=$(echo "$FETCH_OUTPUT" | grep -oP 'raw=\K[0-9]+' | head -1 || echo "0")

echo "[${LOG_TIMESTAMP}] Fetch complete: filtered=${FILTERED_COUNT} raw=${RAW_COUNT}"
echo "[${LOG_TIMESTAMP}] Fetch complete"

# If no users found, skip update
if [ "$FILTERED_COUNT" -eq 0 ]; then
    echo "[${LOG_TIMESTAMP}] No changes detected, skipping update"
    echo "[${LOG_TIMESTAMP}] Rolling sync complete"
    echo "$FETCH_OUTPUT" | tail -50 >> "$LOG_DIR/sync_users_rolling.log"
    exit 0
fi

# Process the fetched users
echo "[${LOG_TIMESTAMP}] Starting users update..."

# Load and filter the JSON to match our criteria
python3 << 'PYTHON_FILTER'
import json
import sys

try:
    with open('exports/08_users/raw_all.json', 'r') as f:
        users = json.load(f)
except FileNotFoundError:
    print("ERROR: Could not read exported users file")
    sys.exit(1)

# Filter: keep only students (kind='student') AND not alumni (alumni?=false)
filtered = [
    u for u in users
    if u.get('kind') == 'student' and u.get('alumni?') is False
]

# Save filtered results
with open('exports/08_users/all.json', 'w') as f:
    json.dump(filtered, f, indent=2)

print(f"Filtered: {len(filtered)} users")
PYTHON_FILTER

PYTHON_EXIT=$?

if [ $PYTHON_EXIT -ne 0 ]; then
    echo "[${LOG_TIMESTAMP}] Error: Filtering failed"
    exit 1
fi

# Update database with filtered users
(
cat << 'EOF'
-- Create staging table
CREATE TEMP TABLE IF NOT EXISTS users_staging (
    id BIGINT,
    login VARCHAR(255),
    email VARCHAR(255),
    kind VARCHAR(50),
    alumni BOOLEAN,
    updated_at TIMESTAMP
);

-- Import staging table
\COPY users_staging FROM PSTDIN WITH (FORMAT csv, HEADER true, DELIMITER ',');

-- Upsert into main users table
INSERT INTO users (id, login, email, kind, alumni, updated_at)
SELECT id, login, email, kind, alumni, updated_at FROM users_staging
ON CONFLICT (id) DO UPDATE SET
    login = EXCLUDED.login,
    email = EXCLUDED.email,
    kind = EXCLUDED.kind,
    alumni = EXCLUDED.alumni,
    updated_at = EXCLUDED.updated_at;

-- Show results
SELECT 
    COUNT(*) FILTER (WHERE xmax = 0) as inserted,
    COUNT(*) FILTER (WHERE xmax > 0) as updated
FROM users_staging;
EOF

# Convert JSON to CSV for import
python3 << 'PYTHON_CSV'
import json
import sys

try:
    with open('exports/08_users/all.json', 'r') as f:
        users = json.load(f)
except FileNotFoundError:
    print("ERROR: Could not read filtered users file")
    sys.exit(1)

# Print CSV header
print("id,login,email,kind,alumni,updated_at")

# Print rows
for user in users:
    id_ = user.get('id', '')
    login = user.get('login', '').replace('"', '""')  # Escape quotes
    email = user.get('email', '').replace('"', '""')
    kind = user.get('kind', '')
    alumni = str(user.get('alumni?', False)).lower()
    updated_at = user.get('updated_at', '')
    
    print(f'{id_},"{login}","{email}",{kind},{alumni},{updated_at}')
PYTHON_CSV

) | psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -w -v ON_ERROR_STOP=1 2>&1 | grep -E "(inserted|updated|COPY|ERROR)" || true

UPDATE_EXIT=$?

if [ $UPDATE_EXIT -eq 0 ]; then
    echo "[${LOG_TIMESTAMP}] Upserting..."
    echo "[${LOG_TIMESTAMP}] Users: total=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -w -t -c "SELECT COUNT(*) FROM users" 2>/dev/null || echo '?')"
    echo "[${LOG_TIMESTAMP}] Update complete"
else
    echo "[${LOG_TIMESTAMP}] Warning: Update had errors but continuing"
fi

echo "[${LOG_TIMESTAMP}] Rolling sync complete"

# Log with rotation (keep last 500 lines)
{
    echo "$FETCH_OUTPUT" | sed "s/^/[${LOG_TIMESTAMP}] /"
    echo "[${LOG_TIMESTAMP}] Update complete"
} >> "$LOG_DIR/sync_users_rolling.log"

tail -500 "$LOG_DIR/sync_users_rolling.log" > "$LOG_DIR/sync_users_rolling.log.tmp"
mv "$LOG_DIR/sync_users_rolling.log.tmp" "$LOG_DIR/sync_users_rolling.log"
