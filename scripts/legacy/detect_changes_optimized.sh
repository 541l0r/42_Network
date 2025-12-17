#!/bin/bash

# detect_changes_optimized.sh - Moved JSON comparison to detector
# Only enqueue users whose JSON actually differs from snapshot
# Worker becomes pure upsert engine (no comparison, no logging queries)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"
CACHE_DIR="$ROOT_DIR/.cache/raw_detect"
EXPORTS_DIR="$ROOT_DIR/exports/09_users"

mkdir -p "$BACKLOG_DIR" "$LOG_DIR" "$CACHE_DIR" "$EXPORTS_DIR"

LOG_FILE="$LOG_DIR/detect_changes.log"
LOG_TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# Get time window
CONFIG_FILE="$ROOT_DIR/scripts/config/agents.config"
CONFIG_TIME_WINDOW=""
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_TIME_WINDOW=$(grep -E '^\s*TIME_WINDOW=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}')
fi
DEFAULT_MAX_WINDOW="${CONFIG_TIME_WINDOW:-65}"
MAX_WINDOW="${TIME_WINDOW:-$DEFAULT_MAX_WINDOW}"

NOW_EPOCH=$(date -u +%s)
WINDOW_SECS="$MAX_WINDOW"
PID=$$

echo "[${LOG_TIMESTAMP}] [pid=${PID}] Detecting changes in last ${WINDOW_SECS}s (JSON comparison in detector)" | tee -a "$LOG_FILE"

# Fetch users updated in window
RAW_JSON=$(WINDOW_SECONDS="$WINDOW_SECS" FILTER_KIND=student FILTER_CURSUS_ID=21 FILTER_ALUMNI=false \
  bash "$ROOT_DIR/scripts/helpers/fetch_users_by_updated_at_window.sh" "$WINDOW_SECS" student 21 2>/dev/null || echo "[]")

if ! echo "$RAW_JSON" | jq empty >/dev/null 2>&1; then
  echo "[${LOG_TIMESTAMP}] Fetch returned invalid JSON, skipping" >> "$LOG_FILE"
  exit 0
fi

COUNT=$(echo "$RAW_JSON" | jq 'length' 2>/dev/null || echo "0")
echo "[${LOG_TIMESTAMP}] Found $COUNT users in window" >> "$LOG_FILE"

if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  COUNT=0
fi

if [ "$COUNT" -eq 0 ]; then
  echo "[${LOG_TIMESTAMP}] No users to process" >> "$LOG_FILE"
  exit 0
fi

# ============================================================================
# OPTIMIZATION: Compare JSON in detector, only enqueue if changed
# ============================================================================

HASH_FILE="$BACKLOG_DIR/detector_hashes.json"
BACKLOG_FILE="$BACKLOG_DIR/pending_users.txt"

TMP_JSON=$(mktemp)
echo "$RAW_JSON" | jq '.' > "$TMP_JSON"

TMP_JSON="$TMP_JSON" HASH_FILE="$HASH_FILE" BACKLOG_FILE="$BACKLOG_FILE" EXPORTS_DIR="$EXPORTS_DIR" python3 << 'PYTHON_COMPARE'
import json, os, hashlib

root = os.environ.get("ROOT_DIR", "/srv/42_Network/repo")
tmp_json = os.environ["TMP_JSON"]
hash_file = os.environ["HASH_FILE"]
backlog_file = os.environ["BACKLOG_FILE"]
exports_dir = os.environ["EXPORTS_DIR"]

def load_json(path, default):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default

users = load_json(tmp_json, [])
hashes = load_json(hash_file, {})

def fingerprint(user):
    # Ignore volatile fields
    ignore = {"updated_at", "alumnized_at", "created_at", "anonymize_date", "data_erasure_date"}
    filtered = {k: v for k, v in user.items() if k not in ignore}
    payload = json.dumps(filtered, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()

changed_ids = []
json_differs = []

for u in users:
    uid = u.get("id")
    if uid is None:
        continue
    
    fp = fingerprint(u)
    last = hashes.get(str(uid))
    
    # Fingerprint changed (core data differs)
    if last != fp:
        changed_ids.append(str(uid))
        hashes[str(uid)] = fp
    
    # Check if full JSON snapshot differs (catches array reordering, etc)
    campus = u.get("campus", {})
    campus_id = campus.get("id", 0) if isinstance(campus, dict) else 0
    
    snapshot_file = f"{exports_dir}/campus_{campus_id}/user_{uid}.json"
    try:
        with open(snapshot_file, "r") as f:
            old_json = json.load(f)
        # Normalize and compare
        old_str = json.dumps(old_json, sort_keys=True, separators=(",", ":"))
        new_str = json.dumps(u, sort_keys=True, separators=(",", ":"))
        if old_str != new_str:
            json_differs.append(uid)
    except (FileNotFoundError, json.JSONDecodeError):
        # No prior snapshot, will be first upsert
        json_differs.append(uid)

# Only enqueue users where JSON actually differs
enqueue_ids = list(set(json_differs))  # Remove duplicates
enqueue_ids.sort()

# Append to backlog
if enqueue_ids:
    with open(backlog_file, "a") as f:
        for user_id in enqueue_ids:
            f.write(f"{user_id}\n")

# Save updated hashes
with open(hash_file, "w") as f:
    json.dump(hashes, f)

print(f"[detector] Queued {len(enqueue_ids)} users with JSON changes")
print(f"[detector] Changed fingerprints: {len(changed_ids)}, JSON differs: {len(json_differs)}")

PYTHON_COMPARE

echo "[${LOG_TIMESTAMP}] Done" >> "$LOG_FILE"
