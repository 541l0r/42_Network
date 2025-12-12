#!/usr/bin/env bash
set -euo pipefail

# Merge achievements from all campus directories into raw_all.json
# and update .last_fetch_epoch timestamp
# Also creates normalized 03_achievements/all.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORT_DIR_CAMPUS="$ROOT_DIR/exports/04_campus_achievements"
EXPORT_DIR_NORM="$ROOT_DIR/exports/03_achievements"
STAMP_FILE_CAMPUS="$EXPORT_DIR_CAMPUS/.last_fetch_epoch"
METRIC_FILE_CAMPUS="$EXPORT_DIR_CAMPUS/.last_fetch_stats"
STAMP_FILE_NORM="$EXPORT_DIR_NORM/.last_fetch_epoch"
METRIC_FILE_NORM="$EXPORT_DIR_NORM/.last_fetch_stats"

mkdir -p "$EXPORT_DIR_CAMPUS" "$EXPORT_DIR_NORM"

log() {
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*"
}

log "====== MERGE CAMPUS ACHIEVEMENTS START ======"
START_TIME=$(date +%s)

# Merge all campus achievement files (with campus_id)
merged_json="$EXPORT_DIR_CAMPUS/raw_all.json"
if jq -s 'add // []' "$EXPORT_DIR_CAMPUS"/campus_*/all.json > "$merged_json" 2>/dev/null; then
  raw_count=$(jq 'length' "$merged_json")
  log "Merged $raw_count achievement records from all campuses"
else
  log "ERROR: Failed to merge campus achievements"
  exit 1
fi

# Create normalized achievements (deduplicated, without campus_id)
normalized_json="$EXPORT_DIR_NORM/all.json"
if jq 'map(select(.id != null)) | sort_by(.id) | group_by(.id) | map(.[0] | del(.campus_id))' "$merged_json" > "$normalized_json"; then
  norm_count=$(jq 'length' "$normalized_json")
  log "Created normalized achievements: $norm_count unique records"
else
  log "ERROR: Failed to normalize achievements"
  exit 1
fi

# Record fetch timestamp (now)
EPOCH=$(date +%s)
date +%s > "$STAMP_FILE_CAMPUS"
date +%s > "$STAMP_FILE_NORM"
log "Updated timestamps in both folders"

# Record stats for campus_achievements
campus_count=$(ls -d "$EXPORT_DIR_CAMPUS"/campus_* 2>/dev/null | wc -l)
cat > "$METRIC_FILE_CAMPUS" << STATS
{
  "type": "campus_achievements",
  "count": $raw_count,
  "campuses": $campus_count,
  "method": "merge_from_campus_dirs",
  "timestamp": $EPOCH
}
STATS

# Record stats for normalized achievements
cat > "$METRIC_FILE_NORM" << STATS
{
  "type": "achievements",
  "count": $norm_count,
  "method": "deduplicate_from_campus_achievements",
  "source": "04_campus_achievements",
  "timestamp": $EPOCH
}
STATS

# Cleanup individual campus page files
log "Cleaning up page_*.json files from campus directories..."
find "$EXPORT_DIR_CAMPUS"/campus_* -name "page_*.json" -delete
cleanup_count=$(find "$EXPORT_DIR_CAMPUS"/campus_* -name "page_*.json" 2>/dev/null | wc -l)
if [ "$cleanup_count" -eq 0 ]; then
  log "Cleanup complete: all page_*.json files removed"
fi

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
log "====== MERGE COMPLETE (${DURATION}s) ======"
log ""

exit 0
