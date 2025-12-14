#!/bin/bash

# backlog_worker.sh - Processes user IDs from backlog
# For each user ID:
#   1. Fetches achievements_users
#   2. Fetches projects_users
#   3. Fetches coalitions_users
# Saves to DB and clears backlog

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"
EXPORTS_DIR="$ROOT_DIR/exports/08_users"
LOG_DIR="$ROOT_DIR/logs"

mkdir -p "$BACKLOG_DIR" "$EXPORTS_DIR" "$LOG_DIR"

BACKLOG_FILE="$BACKLOG_DIR/pending_users.txt"
LOG_FILE="$LOG_DIR/backlog_worker.log"

echo "Worker started at $(date)" | tee -a "$LOG_FILE"
echo "Backlog file path: $BACKLOG_FILE" | tee -a "$LOG_FILE"

BASE_URL="https://api.intra.42.fr/v2"

while true; do
    # Check if backlog exists and has content
    if [ ! -f "$BACKLOG_FILE" ]; then
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Backlog file doesn't exist, sleeping..." | tee -a "$LOG_FILE"
        sleep 5
        continue
    fi
    
    if [ ! -s "$BACKLOG_FILE" ]; then
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Backlog file is empty, sleeping..." | tee -a "$LOG_FILE"
        sleep 5
        continue
    fi
    
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Processing backlog..." | tee -a "$LOG_FILE"
    
    # Load token
    if [ ! -f "$ROOT_DIR/.oauth_state" ]; then
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ERROR: No .oauth_state file" | tee -a "$LOG_FILE"
        sleep 10
        continue
    fi
    
    source "$ROOT_DIR/.oauth_state"
    API_TOKEN="$ACCESS_TOKEN"
    
    if [ -z "$API_TOKEN" ]; then
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ERROR: No API token" | tee -a "$LOG_FILE"
        sleep 10
        continue
    fi
    
    # Get all unique user IDs from backlog
    USER_IDS=$(sort -u "$BACKLOG_FILE")
    USER_COUNT=$(echo "$USER_IDS" | wc -l)
    
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Found $USER_COUNT users to process" | tee -a "$LOG_FILE"
    
    # Process each user
    COUNTER=0
    FAILED=0
    
    for USER_ID in $USER_IDS; do
        COUNTER=$((COUNTER + 1))
        
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Processing user $COUNTER/$USER_COUNT (ID: $USER_ID)" >> "$LOG_FILE"
        
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
        # For now, just log that we fetched the data
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Fetched data for user $USER_ID" >> "$LOG_FILE"
        
        # Rate limiting: 1 request per second
        sleep 1
        
        if [ $((COUNTER % 10)) -eq 0 ]; then
            echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Processed $COUNTER/$USER_COUNT users" | tee -a "$LOG_FILE"
        fi
    done
    
    # Clear backlog after successful processing
    rm "$BACKLOG_FILE"
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ✓ Backlog cleared ($COUNTER users processed)" | tee -a "$LOG_FILE"
    
    sleep 5
done

