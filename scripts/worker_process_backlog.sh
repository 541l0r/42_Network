#!/bin/bash

# worker_process_backlog.sh
# Runs every 5 seconds via systemd timer
# Processes one batch of user IDs from backlog
# Fetches nested data: achievements_users, projects_users, coalitions_users
# Saves to exports: 09_users, 10_projects_users, 11_achievements_users, 12_coalitions_users
# TODO: Insert into DB and clear backlog

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"
EXPORTS_09="$ROOT_DIR/exports/09_users"
EXPORTS_10="$ROOT_DIR/exports/10_projects_users"
EXPORTS_11="$ROOT_DIR/exports/11_achievements_users"
EXPORTS_12="$ROOT_DIR/exports/12_coalitions_users"
LOG_DIR="$ROOT_DIR/logs"

mkdir -p "$BACKLOG_DIR" "$EXPORTS_09" "$EXPORTS_10" "$EXPORTS_11" "$EXPORTS_12" "$LOG_DIR"

BACKLOG_FILE="$BACKLOG_DIR/pending_users.txt"
LOG_FILE="$LOG_DIR/backlog_worker.log"

# Load token
if [ ! -f "$ROOT_DIR/.oauth_state" ]; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ERROR: No .oauth_state file" >> "$LOG_FILE"
    exit 1
fi

source "$ROOT_DIR/.oauth_state"
API_TOKEN="$ACCESS_TOKEN"

if [ -z "$API_TOKEN" ]; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ERROR: No API token" >> "$LOG_FILE"
    exit 1
fi

# Check if backlog has content
if [ ! -f "$BACKLOG_FILE" ] || [ ! -s "$BACKLOG_FILE" ]; then
    # Backlog empty - that's OK, just exit silently
    exit 0
fi

# Process ONE user ID from backlog
USER_ID=$(head -1 "$BACKLOG_FILE")

if [ -z "$USER_ID" ]; then
    exit 0
fi

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Processing user $USER_ID" >> "$LOG_FILE"

BASE_URL="https://api.intra.42.fr/v2"

# Fetch achievements_users
ACHIEVEMENTS=$(curl -s -H "Authorization: Bearer $API_TOKEN" \
    "$BASE_URL/users/$USER_ID/achievements_users?per_page=100" 2>/dev/null || echo "[]")

# Fetch projects_users
PROJECTS=$(curl -s -H "Authorization: Bearer $API_TOKEN" \
    "$BASE_URL/users/$USER_ID/projects_users?per_page=100" 2>/dev/null || echo "[]")

# Fetch coalitions_users
COALITIONS=$(curl -s -H "Authorization: Bearer $API_TOKEN" \
    "$BASE_URL/users/$USER_ID/coalitions_users?per_page=100" 2>/dev/null || echo "[]")

# TODO: Insert into DB
# Save to JSON exports grouped by campus (best-effort: derive from achievements or default 0)
campus_id=$(echo "$ACHIEVEMENTS" | jq -r '.[0].campus_id // 0' 2>/dev/null)
[ -z "$campus_id" ] && campus_id=0
mkdir -p "$EXPORTS_09/campus_${campus_id}" "$EXPORTS_10/campus_${campus_id}" "$EXPORTS_11/campus_${campus_id}" "$EXPORTS_12/campus_${campus_id}"
echo "$ACHIEVEMENTS" > "$EXPORTS_11/campus_${campus_id}/user_${USER_ID}.json"
echo "$PROJECTS" > "$EXPORTS_10/campus_${campus_id}/user_${USER_ID}.json"
echo "$COALITIONS" > "$EXPORTS_12/campus_${campus_id}/user_${USER_ID}.json"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Fetched achievements, projects, coalitions for user $USER_ID (campus $campus_id)" >> "$LOG_FILE"

# Remove processed ID from backlog
tail -n +2 "$BACKLOG_FILE" > "$BACKLOG_FILE.tmp"
mv "$BACKLOG_FILE.tmp" "$BACKLOG_FILE"

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ✓ User $USER_ID processed and removed from backlog" >> "$LOG_FILE"
