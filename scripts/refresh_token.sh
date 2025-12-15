#!/bin/bash

# refresh_token.sh - Refresh 42 API token
# Runs every hour at minute 5 to ensure token stays valid

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"

mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/token_refresh.log"
TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

echo "[$TIMESTAMP] Refreshing 42 API token..." >> "$LOG_FILE"

# Call token_manager to refresh
if bash "$TOKEN_HELPER" refresh >/dev/null 2>&1; then
  echo "[$TIMESTAMP] ✓ Token refreshed successfully" >> "$LOG_FILE"
else
  echo "[$TIMESTAMP] ⚠️  Token refresh failed" >> "$LOG_FILE"
fi

# Keep log to last 100 lines
tail -100 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
