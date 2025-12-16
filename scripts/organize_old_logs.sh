#!/bin/bash

# organize_old_logs.sh - Archive and organize logs older than 24h by agent

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
ARCHIVE_DIR="$LOG_DIR/archive"

# Create archive directory
mkdir -p "$ARCHIVE_DIR"

echo "=== ORGANIZING OLD LOGS (>24h) ==="
echo ""

# Define agent categories and their patterns
declare -A AGENTS=(
  ["detect_changes"]="detect_changes|detector"
  ["fetcher"]="fetcher|fetch_scope|fetch_users"
  ["upserter"]="upserter"
  ["init_db"]="init_db"
  ["orchestrate"]="orchestra"
  ["fetch_metadata"]="fetch_metadata|metadata"
  ["coalitions"]="coalitions|fetch_coalitions"
  ["other"]=".*"
)

# Process each agent category
for agent in "${!AGENTS[@]}"; do
  pattern="${AGENTS[$agent]}"
  
  # Find old logs matching pattern
  old_logs=$(find "$LOG_DIR" -maxdepth 1 -type f -name "*.log" -mmin +1440 \
    | xargs -I {} basename {} \
    | grep -E "$pattern" || true)
  
  if [[ -n "$old_logs" ]]; then
    mkdir -p "$ARCHIVE_DIR/$agent"
    count=$(echo "$old_logs" | wc -l)
    
    # Move logs to agent subdirectory
    echo "$old_logs" | while read logfile; do
      [[ -f "$LOG_DIR/$logfile" ]] && mv "$LOG_DIR/$logfile" "$ARCHIVE_DIR/$agent/" 2>/dev/null || true
    done
    
    echo "✓ $agent: $count logs archived"
  fi
done

echo ""
echo "=== ARCHIVE STRUCTURE ==="
find "$ARCHIVE_DIR" -type d | sort | while read dir; do
  indent="  "
  if [[ "$dir" != "$ARCHIVE_DIR" ]]; then
    agent=$(basename "$dir")
    count=$(find "$dir" -type f | wc -l)
    echo "$indent$agent/ ($count files)"
  fi
done

echo ""
echo "=== ACTIVE LOGS (keep in /logs) ==="
ls -1 "$LOG_DIR"/*.log 2>/dev/null | xargs -I {} basename {} | head -10

echo ""
du -sh "$ARCHIVE_DIR" "$LOG_DIR"
echo ""
echo "✓ Old logs organized by agent in $ARCHIVE_DIR/"
