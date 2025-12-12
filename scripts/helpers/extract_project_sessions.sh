#!/usr/bin/env bash
set -euo pipefail

# Extract project_sessions table from projects raw data
# Source: 05_projects/raw_all.json
# Output: 07_project_sessions/all.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_FILE="$ROOT_DIR/exports/05_projects/raw_all.json"
EXPORT_DIR="$ROOT_DIR/exports/07_project_sessions"
STAMP_FILE="$EXPORT_DIR/.last_fetch_epoch"
METRIC_FILE="$EXPORT_DIR/.last_fetch_stats"

mkdir -p "$EXPORT_DIR"

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*"
}

log "====== EXTRACT PROJECT_SESSIONS START ======"
START_TIME=$(date +%s)

if [ ! -f "$SOURCE_FILE" ]; then
  log "ERROR: Source file not found: $SOURCE_FILE"
  exit 1
fi

# Extract project_sessions from nested array
output_json="$EXPORT_DIR/all.json"
if jq '[.[] | select(.project_sessions | length > 0) | .project_sessions[]]' "$SOURCE_FILE" > "$output_json"; then
  count=$(jq 'length' "$output_json")
  log "Extracted $count project sessions"
else
  log "ERROR: Failed to extract project_sessions"
  exit 1
fi

# Record timestamp
EPOCH=$(date +%s)
date +%s > "$STAMP_FILE"

# Record stats
cat > "$METRIC_FILE" << STATS
{
  "type": "project_sessions",
  "count": $count,
  "method": "extract_from_projects",
  "source": "05_projects",
  "timestamp": $EPOCH
}
STATS

log "Saved to $output_json"
log "Updated timestamp in $STAMP_FILE"

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
log "====== EXTRACT COMPLETE (${DURATION}s) ======"
log ""

exit 0
