#!/usr/bin/env bash
set -euo pipefail

# Sync State Backlog Helper - Tracks incremental sync progress and outstanding work
#
# Maintains state files that track:
#  - Last successful fetch timestamp for each table
#  - Fetch count and API hit stats
#  - Outstanding batches to process
#
# Usage:
#   sync_backlog_helper.sh [COMMAND] [TABLE] [EXTRA_ARGS...]
#
# Commands:
#   init <TABLE>              - Initialize backlog tracking for a table
#   last-fetch <TABLE>        - Get last successful fetch timestamp
#   set-fetch <TABLE> <TIME>  - Update last fetch time (ISO 8601 format)
#   get-stats <TABLE>         - Show fetch statistics
#   mark-complete <TABLE>     - Mark a fetch batch as complete
#   outstanding <TABLE>       - Show outstanding work since last sync
#   record-hit <TABLE> <HITS> - Record API hit count
#   reset <TABLE>             - Reset backlog state
#
# Examples:
#   # Initialize tracking for users table
#   sync_backlog_helper.sh init users_cursus
#
#   # Check when users were last fetched
#   sync_backlog_helper.sh last-fetch users_cursus
#
#   # Mark successful fetch at specific time
#   sync_backlog_helper.sh set-fetch users_cursus "2025-12-12T10:15:30Z"
#
#   # Show how much data is outstanding
#   sync_backlog_helper.sh outstanding users_cursus
#
#   # Record API call stats
#   sync_backlog_helper.sh record-hit users_cursus 47

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"

mkdir -p "$BACKLOG_DIR" "$LOG_DIR"

# Get current UTC timestamp in ISO 8601
get_iso_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Get timestamp from seconds ago
get_iso_timestamp_ago() {
  local seconds_ago="${1:-0}"
  python3 -c "import datetime; print(datetime.datetime.fromtimestamp($(date -u +%s) - $seconds_ago, datetime.UTC).isoformat().replace('+00:00', 'Z'))"
}

# Initialize backlog state file for a table
cmd_init() {
  local table="$1"
  local state_file="$BACKLOG_DIR/${table}.state"
  
  if [[ -f "$state_file" ]]; then
    echo "✓ Backlog state already initialized: $state_file"
    return 0
  fi
  
  # Create initial state: never fetched
  cat > "$state_file" << EOF
{
  "table": "$table",
  "initialized_at": "$(get_iso_timestamp)",
  "last_fetch_at": null,
  "last_fetch_count": 0,
  "total_fetches": 0,
  "total_api_hits": 0,
  "consecutive_empty": 0,
  "status": "initialized"
}
EOF
  
  echo "✓ Backlog initialized for $table: $state_file"
}

# Get last fetch timestamp
cmd_last_fetch() {
  local table="$1"
  local state_file="$BACKLOG_DIR/${table}.state"
  
  if [[ ! -f "$state_file" ]]; then
    echo "null"
    return 0
  fi
  
  python3 << PYTHON_EOF
import json
with open('$state_file') as f:
    data = json.load(f)
    last = data.get('last_fetch_at')
    print(last if last else "never")
PYTHON_EOF
}

# Set last fetch timestamp
cmd_set_fetch() {
  local table="$1"
  local timestamp="$2"
  local state_file="$BACKLOG_DIR/${table}.state"
  
  if [[ ! -f "$state_file" ]]; then
    cmd_init "$table"
  fi
  
  python3 << PYTHON_EOF
import json
with open('$state_file') as f:
    data = json.load(f)

data['last_fetch_at'] = '$timestamp'
data['total_fetches'] = data.get('total_fetches', 0) + 1
data['status'] = 'fetched'

with open('$state_file', 'w') as f:
    json.dump(data, f, indent=2)
    
print("✓ Updated $table fetch time to $timestamp")
PYTHON_EOF
}

# Show fetch statistics
cmd_get_stats() {
  local table="$1"
  local state_file="$BACKLOG_DIR/${table}.state"
  
  if [[ ! -f "$state_file" ]]; then
    echo "No backlog state for $table"
    return 0
  fi
  
  python3 << PYTHON_EOF
import json
with open('$state_file') as f:
    data = json.load(f)
    
print(f"Table: {data['table']}")
print(f"Status: {data['status']}")
print(f"Last fetch: {data.get('last_fetch_at', 'never')}")
print(f"Total fetches: {data.get('total_fetches', 0)}")
print(f"Total API hits: {data.get('total_api_hits', 0)}")
print(f"Last fetch count: {data.get('last_fetch_count', 0)} records")
PYTHON_EOF
}

# Show outstanding work
cmd_outstanding() {
  local table="$1"
  local state_file="$BACKLOG_DIR/${table}.state"
  
  if [[ ! -f "$state_file" ]]; then
    echo "Never fetched (all data outstanding)"
    return 0
  fi
  
  python3 << PYTHON_EOF
import json
import datetime

with open('$state_file') as f:
    data = json.load(f)

last_fetch = data.get('last_fetch_at')
if not last_fetch:
    print("Never fetched - all data outstanding")
    return

# Parse ISO timestamp
dt = datetime.datetime.fromisoformat(last_fetch.replace('Z', '+00:00'))
now = datetime.datetime.now(datetime.UTC)
time_since = (now - dt).total_seconds()

hours = int(time_since / 3600)
minutes = int((time_since % 3600) / 60)
seconds = int(time_since % 60)

print(f"Outstanding since last fetch: {hours}h {minutes}m {seconds}s ago")
print(f"  Last fetch: {last_fetch}")
print(f"  Records synced then: {data.get('last_fetch_count', 0)}")
PYTHON_EOF
}

# Record API hit count
cmd_record_hit() {
  local table="$1"
  local hits="${2:-1}"
  local state_file="$BACKLOG_DIR/${table}.state"
  
  if [[ ! -f "$state_file" ]]; then
    cmd_init "$table"
  fi
  
  python3 << PYTHON_EOF
import json
with open('$state_file') as f:
    data = json.load(f)

data['total_api_hits'] = data.get('total_api_hits', 0) + $hits
data['last_api_hits'] = $hits

with open('$state_file', 'w') as f:
    json.dump(data, f, indent=2)
    
print("✓ Recorded $hits API hits for $table")
PYTHON_EOF
}

# Reset backlog state
cmd_reset() {
  local table="$1"
  local state_file="$BACKLOG_DIR/${table}.state"
  
  if [[ -f "$state_file" ]]; then
    rm "$state_file"
    echo "✓ Backlog reset for $table"
  else
    echo "No backlog state to reset"
  fi
}

# Main command dispatcher
COMMAND="${1:-help}"
TABLE="${2:-}"

case "$COMMAND" in
  init)
    [[ -z "$TABLE" ]] && { echo "Error: table name required"; exit 1; }
    cmd_init "$TABLE"
    ;;
  last-fetch)
    [[ -z "$TABLE" ]] && { echo "Error: table name required"; exit 1; }
    cmd_last_fetch "$TABLE"
    ;;
  set-fetch)
    [[ -z "$TABLE" ]] && { echo "Error: table name required"; exit 1; }
    [[ -z "$3" ]] && { echo "Error: timestamp required"; exit 1; }
    cmd_set_fetch "$TABLE" "$3"
    ;;
  get-stats)
    [[ -z "$TABLE" ]] && { echo "Error: table name required"; exit 1; }
    cmd_get_stats "$TABLE"
    ;;
  outstanding)
    [[ -z "$TABLE" ]] && { echo "Error: table name required"; exit 1; }
    cmd_outstanding "$TABLE"
    ;;
  record-hit)
    [[ -z "$TABLE" ]] && { echo "Error: table name required"; exit 1; }
    cmd_record_hit "$TABLE" "${3:-1}"
    ;;
  reset)
    [[ -z "$TABLE" ]] && { echo "Error: table name required"; exit 1; }
    cmd_reset "$TABLE"
    ;;
  help|--help|-h)
    cat << 'HELP_EOF'
Sync State Backlog Helper - Track incremental sync progress

Usage: sync_backlog_helper.sh [COMMAND] [TABLE] [EXTRA_ARGS]

Commands:
  init <TABLE>              Initialize backlog tracking for a table
  last-fetch <TABLE>        Get last successful fetch timestamp
  set-fetch <TABLE> <TIME>  Update last fetch time (ISO 8601)
  get-stats <TABLE>         Show fetch statistics
  outstanding <TABLE>       Show outstanding work since last sync
  record-hit <TABLE> <HITS> Record API hit count
  reset <TABLE>             Reset backlog state

Examples:
  sync_backlog_helper.sh init users_cursus
  sync_backlog_helper.sh last-fetch users_cursus
  sync_backlog_helper.sh set-fetch users_cursus "2025-12-12T10:15:30Z"
  sync_backlog_helper.sh outstanding users_cursus
  sync_backlog_helper.sh record-hit users_cursus 47
  sync_backlog_helper.sh get-stats users_cursus

State files stored in: .backlog/
HELP_EOF
    ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Run: $0 help"
    exit 1
    ;;
esac
