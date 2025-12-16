#!/bin/bash

# detect_changes.sh - Runs every minute
# Fetch users updated in a recent time window and enqueue IDs to backlog.
# Saves raw JSON snapshots to .cache/raw_detect; the worker will fetch full detail.

# Note: set -euo pipefail enabled for error detection
set -euo pipefail

# Resolve ROOT_DIR reliably from absolute or relative script path
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"
CACHE_DIR="$ROOT_DIR/.cache/raw_detect"

mkdir -p "$BACKLOG_DIR" "$LOG_DIR" "$CACHE_DIR"

LOG_FILE="$LOG_DIR/detect_changes.log"
LOG_TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# Configurable window (seconds) with precedence: env TIME_WINDOW > config > default 65
CONFIG_FILE="$ROOT_DIR/scripts/config/agents.config"
CONFIG_TIME_WINDOW=""
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_TIME_WINDOW=$(grep -E '^\s*TIME_WINDOW=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}' || echo "")
fi
DEFAULT_MAX_WINDOW="${CONFIG_TIME_WINDOW:-65}"
MAX_WINDOW="${TIME_WINDOW:-$DEFAULT_MAX_WINDOW}"

# Configurable timestamp delta (seconds) - skip delta check if old & new JSON updated_at < this (default 15min)
CONFIG_DELTA_SKIP=""
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_DELTA_SKIP=$(grep -E '^\s*DELTA_SKIP_SECONDS=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}' || echo "")
fi
DEFAULT_DELTA_SKIP="900"  # 15 minutes
DELTA_SKIP_SECONDS="${DELTA_SKIP_SECONDS:-${CONFIG_DELTA_SKIP:-$DEFAULT_DELTA_SKIP}}"

NOW_EPOCH=$(date -u +%s)
WINDOW_SECS="$MAX_WINDOW"
PID=$$

# Fetch users updated in window (filtered to students in cursus 21)
RAW_JSON=$(WINDOW_SECONDS="$WINDOW_SECS" FILTER_KIND=student FILTER_CURSUS_ID=21 FILTER_ALUMNI=false \
  bash "$ROOT_DIR/scripts/helpers/fetch_users_by_updated_at_window.sh" "$WINDOW_SECS" student 21 2>/dev/null || echo "[]")

# Validate JSON
if ! echo "$RAW_JSON" | jq empty >/dev/null 2>&1; then
  echo "[${LOG_TIMESTAMP}] [pid=${PID}] ERROR: Invalid JSON response" >> "$LOG_FILE"
  exit 0
fi

COUNT=$(echo "$RAW_JSON" | jq 'length' 2>/dev/null || echo "0")

# Treat non-numeric counts as zero
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  COUNT=0
fi

if [ "$COUNT" -gt 0 ]; then
  cache_file="$CACHE_DIR/users_latest.json"
  tmp_json=$(mktemp)
  echo "$RAW_JSON" | jq '.' > "$tmp_json"
  cp "$tmp_json" "$cache_file"

  HASH_FILE="$BACKLOG_DIR/detector_hashes.json"
  BACKLOG_FILE="$BACKLOG_DIR/fetch_queue.txt"
  LOCK_FILE="$BACKLOG_DIR/fetch_queue.lock"
  
  # Acquire exclusive lock for safe queue write
  exec 4>"$LOCK_FILE"
  flock -x 4

  TMP_JSON="$tmp_json" HASH_FILE="$HASH_FILE" BACKLOG_FILE="$BACKLOG_FILE" DELTA_SKIP="$DELTA_SKIP_SECONDS" python3 << 'PYTHON_FINGERPRINT'
import json, os, hashlib, hmac

root = os.environ.get("ROOT_DIR", "/srv/42_Network/repo")
tmp_json = os.environ["TMP_JSON"]
delta_skip = int(os.environ.get("DELTA_SKIP", "900"))  # 15 minutes default
hash_file = os.environ["HASH_FILE"]
backlog_file = os.environ["BACKLOG_FILE"]

# Load detector configuration
config_file = os.path.join(root, "scripts/config/detector_fields.json")
config = {}
try:
    with open(config_file, "r") as f:
        config = json.load(f)
except:
    print("ERROR: Could not load detector_fields.json", flush=True)
    exit(1)

# Extract internal/external fields and HMAC keys from config
internal_fields = config.get("internals", {}).get("fields", [])
external_fields = config.get("externals", {}).get("fields", [])
# Fallback: if no external fields configured, reuse internal list
if not external_fields:
    external_fields = internal_fields
hmac_keys = config.get("hmac_keys", {})
hmac_key_internal = hmac_keys.get("internal", "42network_internal_detection")
hmac_key_external = hmac_keys.get("external", "42network_external_detection")

def load_json(path, default):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except json.JSONDecodeError:
        return default

users = load_json(tmp_json, [])
hashes = load_json(hash_file, {})

def fingerprint(user, fields, hmac_key):
    """Calculate HMAC-SHA256 fingerprint using only configured fields"""
    filtered = {k: user.get(k) for k in fields if k in user}
    payload = json.dumps(filtered, sort_keys=True, separators=(",", ":"))
    signature = hmac.new(
        hmac_key.encode(),
        payload.encode(),
        hashlib.sha256
    ).hexdigest()
    return signature

def get_campus_id(user):
    """Extract campus_id from user's campus_users array or campus array"""
    # Try campus_users first (array of campus associations)
    campus_users = user.get("campus_users", [])
    if campus_users and isinstance(campus_users, list):
        for cu in campus_users:
            if isinstance(cu, dict) and cu.get("is_primary"):
                return cu.get("campus_id")
        # If no primary, take first
        if campus_users:
            return campus_users[0].get("campus_id")
    
    # Fallback to campus array
    campus_list = user.get("campus", [])
    if campus_list and isinstance(campus_list, list):
        return campus_list[0].get("id")
    
    return None

def get_updated_timestamp(user):
    """Extract updated_at timestamp as epoch seconds"""
    try:
        import datetime
        updated = user.get("updated_at")
        if not updated:
            return None
        # Parse ISO format: "2025-12-15T01:40:01.169Z"
        updated_dt = datetime.datetime.fromisoformat(updated.replace('Z', '+00:00'))
        return updated_dt.timestamp()
    except:
        return None

changed_ids = []
old_timestamps = {}

# Load old timestamps if they exist
for uid_str, hash_data in hashes.items():
    if isinstance(hash_data, dict):
        old_timestamps[uid_str] = hash_data.get("timestamp")
    else:
        old_timestamps[uid_str] = None

for u in users:
    uid = u.get("id")
    if uid is None:
        continue
    
    new_ts = get_updated_timestamp(u)
    old_ts = old_timestamps.get(str(uid))
    
    # OPTIMIZATION: Skip delta check if timestamp delta < configured seconds (default 900s = 15min)
    if new_ts and old_ts and abs(new_ts - old_ts) < delta_skip:
        # No significant time difference, skip fingerprint comparison
        continue
    
    # Determine which HMAC key to use based on data source
    # Currently: ALL detector comparisons are API-to-API (external)
    # Future: When detector compares DB snapshots, use internal
    campus_id = get_campus_id(u)
    fingerprint_key = "external"  # API snapshot comparison uses external field set

    if fingerprint_key == "internal":
        fingerprint_fields = internal_fields
        hmac_key = hmac_key_internal
    else:
        fingerprint_fields = external_fields
        hmac_key = hmac_key_external
    
    # Calculate fingerprint using only configured fields for the selected data source
    fp = fingerprint(u, fingerprint_fields, hmac_key)
    
    last_hash = hashes.get(str(uid))
    last = last_hash.get("hash") if isinstance(last_hash, dict) else last_hash
    
    if last != fp:
        # Change detected - queue for fetcher to process
        # Time gate (1h) and delta checking will be done in fetcher, not here
        changed_ids.append(str(uid))
        hashes[str(uid)] = {
            "hash": fp,
            "timestamp": new_ts,
            "campus_id": campus_id,
            "fingerprint_key": fingerprint_key
        }

# Dedup with existing backlog
existing = []
if os.path.isfile(backlog_file):
    with open(backlog_file, "r") as f:
        existing = [line.strip() for line in f if line.strip()]

all_ids = sorted(set(existing + changed_ids), key=int)
with open(backlog_file, "w") as f:
    for uid in all_ids:
        f.write(f"{uid}\n")

with open(hash_file, "w") as f:
    json.dump(hashes, f, indent=2)


print(f"fingerprinted={len(users)} changed={len(changed_ids)} backlog_total={len(all_ids)}")
PYTHON_FINGERPRINT

  # Release lock
  flock -u 4
  exec 4>&-

  rm -f "$tmp_json"
  
  # Log the final result in single-line format
  FINGERPRINT_OUTPUT=$(tail -1 "$LOG_FILE" 2>/dev/null | grep -o "fingerprinted=.*")
  if [[ -n "$FINGERPRINT_OUTPUT" ]]; then
    # Remove the raw python output line, replace with formatted line
    head -n -1 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
  echo "[${LOG_TIMESTAMP}] [pid=${PID}] $FINGERPRINT_OUTPUT" >> "$LOG_FILE"
fi

# Update last detection time (subtract 5 seconds for overlap safety)
LAST_EPOCH_FILE="$BACKLOG_DIR/last_detect_epoch"
NEXT_WINDOW_START=$((NOW_EPOCH - 5))
echo "$NEXT_WINDOW_START" > "$LAST_EPOCH_FILE"

# Keep log to last 5000 lines (increased for load testing)
tail -5000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
