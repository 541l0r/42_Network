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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOKEN_HELPER="$ROOT_DIR/scripts/token_manager.sh"

# Parameters with defaults
WINDOW_SECONDS="${1:-30}"
FILTER_KIND="${2:-student}"
FILTER_CURSUS_ID="${3:-21}"

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

# Build API query with range filter on updated_at
# Escape the [ and ] for URL encoding: %5B and %5D
QUERY="/v2/users?range%5Bupdated_at%5D=$START_ISO,$END_ISO&per_page=100&sort=-updated_at"

# Fetch from API (may span multiple pages)
# Note: API returns ALL users in time window, client-side filtering will apply
response=$(bash "$TOKEN_HELPER" call "$QUERY" 2>/dev/null || echo "[]")

# Filter response by kind and cursus (if applicable)
# Output as JSON array
echo "$response" | python3 << 'PYTHON_EOF'
import json
import sys
import os

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print("[]")
    sys.exit(0)

# Ensure we have a list
if not isinstance(data, list):
    print("[]")
    sys.exit(0)

filter_kind = os.environ.get('FILTER_KIND', 'student')
filter_cursus_id = int(os.environ.get('FILTER_CURSUS_ID', '21')) if os.environ.get('FILTER_CURSUS_ID', '21').isdigit() else 21

# Filter users
filtered = []
for user in data:
    # Filter by kind
    if filter_kind and user.get('kind') != filter_kind:
        continue
    
    # Filter by cursus if provided (check if user is in this cursus)
    if filter_cursus_id:
        cursus_users = user.get('cursus_users', [])
        if not any(cu.get('cursus_id') == filter_cursus_id for cu in cursus_users):
            continue
    
    filtered.append(user)

# Output as JSON
print(json.dumps(filtered, indent=2))
PYTHON_EOF
