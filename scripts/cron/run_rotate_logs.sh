#!/usr/bin/env bash
set -euo pipefail

# Rotate logs daily, keep 30 days of history.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$ROOT_DIR/../logs"
DATE_SUFFIX="$(date -u +"%Y-%m-%d")"
KEEP_DAYS="${KEEP_DAYS:-30}"

mkdir -p "$LOG_DIR"

rotate() {
  local base="$1"
  local log="$LOG_DIR/${base}.log"
  if [[ -f "$log" && -s "$log" ]]; then
    mv "$log" "$log.${DATE_SUFFIX}"
  fi
  : > "$log"
}

rotate "42_token_refresh"
rotate "update_tables_daily"

# Prune older than KEEP_DAYS
find "$LOG_DIR" -maxdepth 1 \( -name "42_token_refresh.log.*" -o -name "update_tables_daily.log.*" \) -mtime +"$KEEP_DAYS" -print -delete || true
