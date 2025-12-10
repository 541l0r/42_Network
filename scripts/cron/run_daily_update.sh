#!/usr/bin/env bash
set -euo pipefail

# Wrapper for cron: runs update_tables.sh once, appends output to daily log.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$ROOT_DIR/../logs"
LOG_FILE="$LOG_DIR/update_tables_daily.log"

mkdir -p "$LOG_DIR"

{
  echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") ====="
  (cd "$ROOT_DIR" && ./update_tables.sh "$@")
  echo
} >> "$LOG_FILE" 2>&1
