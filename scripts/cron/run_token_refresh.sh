#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$ROOT_DIR/../../logs"
LOG_FILE="$LOG_DIR/42_token_refresh.log"

mkdir -p "$LOG_DIR"

{
  echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") ====="
  (cd "$ROOT_DIR" && ./token_manager.sh refresh)
  echo
} >> "$LOG_FILE" 2>&1
