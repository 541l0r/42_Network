#!/usr/bin/env bash
set -euo pipefail

# Fetch users from 42 API within a time window based on updated_at
# 
# Usage:
#   fetch_users_by_updated_at_window.sh [WINDOW_SECONDS] [FILTER_KIND] [FILTER_CURSUS_ID]
#
# Parameters:
#   WINDOW_SECONDS   - Time window in seconds (default: 30)
#   FILTER_KIND      - Filter by user kind: 'student', 'external', 'staff' (default: 'student')
#   FILTER_CURSUS_ID - Optional: limit to specific cursus ID (default: 21)
#
# Output: JSON array of matching users
#
# Examples:
#   # Fetch users updated in last 30 seconds, kind=student, cursus 21
#   fetch_users_by_updated_at_window.sh
#   
#   # Fetch users from last 60 seconds, any kind
#   fetch_users_by_updated_at_window.sh 60
#   
#   # Fetch users from last 2 minutes, kind=staff
#   fetch_users_by_updated_at_window.sh 120 staff
#   
#   # Fetch users from last 5 seconds, kind=student, cursus 2
#   fetch_users_by_updated_at_window.sh 5 student 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"

# Parameters with defaults
WINDOW_SECONDS="${1:-30}"
FILTER_KIND="${FILTER_KIND:-${2:-student}}"
FILTER_CURSUS_ID="${FILTER_CURSUS_ID:-${3:-21}}"
FILTER_ALUMNI="${FILTER_ALUMNI:-false}"

# Validate window is numeric
if ! [[ "$WINDOW_SECONDS" =~ ^[0-9]+$ ]]; then
  echo '{"error":"WINDOW_SECONDS must be numeric"}' >&2
  exit 1
fi

# Calculate time window
END_TIME=$(date -u +%s)
START_TIME=$((END_TIME - WINDOW_SECONDS))

# Convert to ISO 8601 format (RFC 3339)
END_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($END_TIME, datetime.UTC).isoformat().replace('+00:00', 'Z'))" 2>/dev/null)
START_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($START_TIME, datetime.UTC).isoformat().replace('+00:00', 'Z'))" 2>/dev/null)

# Paginate through /v2/cursus/:cursus_id/users with updated_at range, server-side filters
# This ensures we only get students in the specific cursus (default: 21)
# NOTE: Alumni filter done in jq (not API) because alumni_p can be null/false/true
accum="[]"
page=1
while true; do
  endpoint="/v2/cursus/$FILTER_CURSUS_ID/users?range%5Bupdated_at%5D=$START_ISO,$END_ISO&filter%5Bkind%5D=$FILTER_KIND&per_page=100&page=$page&sort=-updated_at"
  page_json=$("$TOKEN_HELPER" call "$endpoint" 2>/dev/null || echo "[]")
  if ! echo "$page_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
    break
  fi
  page_count=$(echo "$page_json" | jq 'length' 2>/dev/null || echo "0")
  if [[ "$page_count" == "0" ]]; then
    break
  fi
  accum=$(printf '%s\n%s\n' "$accum" "$page_json" | jq -s 'add')
  page=$((page + 1))
  sleep 1
done

# Filter out alumni_p==true (keeps null and false)
accum=$(echo "$accum" | jq '[.[] | select(.alumni_p != true)]')

# Emit accumulated response
echo "$accum"
