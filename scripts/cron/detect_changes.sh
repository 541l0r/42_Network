#!/bin/bash

# detect_changes.sh - Runs every minute
# Fetches users updated in last time window, extracts IDs to backlog
# Does NOT throw away data - saves raw JSON for worker processing

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Source API token (needed for cron execution)
if [ -f "$ROOT_DIR/.oauth_state" ]; then
    source "$ROOT_DIR/.oauth_state"
fi

BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"
CACHE_DIR="$ROOT_DIR/.cache/raw_detect"

mkdir -p "$BACKLOG_DIR" "$LOG_DIR" "$CACHE_DIR"

LOG_TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# Configurable time window (default: 120 seconds)
TIME_WINDOW="${TIME_WINDOW:-120}"

# Read last detection time (or use TIME_WINDOW seconds ago)
LAST_EPOCH_FILE="$BACKLOG_DIR/last_detect_epoch"

if [ -f "$LAST_EPOCH_FILE" ]; then
    WINDOW_START=$(<"$LAST_EPOCH_FILE")
else
    WINDOW_START=$(($(date -u +%s) - TIME_WINDOW))
fi

# Current time
WINDOW_END=$(date -u +%s)

# Convert to ISO format
WINDOW_START_ISO=$(date -u -d @$WINDOW_START +'%Y-%m-%dT%H:%M:%SZ')
WINDOW_END_ISO=$(date -u -d @$WINDOW_END +'%Y-%m-%dT%H:%M:%SZ')

echo "[${LOG_TIMESTAMP}] Detecting changes: $WINDOW_START_ISO to $WINDOW_END_ISO" | tee -a "$LOG_DIR/detect_changes.log"

# Fetch users updated in time window
FETCH_OUTPUT=$("$ROOT_DIR/scripts/helpers/fetch_cursus_21_users_simple.sh" "$WINDOW_START_ISO" "$WINDOW_END_ISO" 2>&1) || {
    echo "[${LOG_TIMESTAMP}] Fetch failed" >> "$LOG_DIR/detect_changes.log"
    exit 0  # Don't fail the cron
}

# Count results
FILTERED_COUNT=$(echo "$FETCH_OUTPUT" | grep -oP 'filtered=\K[0-9]+' | head -1 || echo "0")

echo "[${LOG_TIMESTAMP}] Found $FILTERED_COUNT users" >> "$LOG_DIR/detect_changes.log"

# If users found, extract IDs and save raw data
if [ "$FILTERED_COUNT" -gt 0 ]; then
    export ROOT_DIR
    python3 << 'PYTHON_EXTRACT'
import json
import os
from datetime import datetime

try:
    users_file = os.path.join(os.environ.get('ROOT_DIR', '/srv/42_Network/repo'), 'exports/09_users/raw_all.json')
    with open(users_file, 'r') as f:
        users = json.load(f)
except FileNotFoundError:
    print("No users file")
    exit(1)

# Filter: kind=student AND alumni?=false
filtered = [
    u for u in users
    if u.get('kind') == 'student' and u.get('alumni?') is False
]

# Save raw JSON data to cache (don't throw away!)
cache_dir = os.path.join(os.environ.get('ROOT_DIR', '/srv/42_Network/repo'), '.cache/raw_detect')
timestamp = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
cache_file = os.path.join(cache_dir, f'users_{timestamp}.json')
with open(cache_file, 'w') as f:
    json.dump(filtered, f, indent=2)

# Extract and write IDs to backlog
backlog_file = os.path.join(os.environ.get('ROOT_DIR', '/srv/42_Network/repo'), '.backlog/pending_users.txt')
with open(backlog_file, 'a') as f:
    for user in filtered:
        f.write(f"{user['id']}\n")

print(f"Added {len(filtered)} IDs to backlog, cached raw data to {cache_file}")
PYTHON_EXTRACT

fi

# Update last detection time (subtract 5 seconds for overlap safety)
NEXT_WINDOW_START=$((WINDOW_END - 5))
echo "$NEXT_WINDOW_START" > "$LAST_EPOCH_FILE"

# Keep log to 500 lines
tail -500 "$LOG_DIR/detect_changes.log" > "$LOG_DIR/detect_changes.log.tmp"
mv "$LOG_DIR/detect_changes.log.tmp" "$LOG_DIR/detect_changes.log"
