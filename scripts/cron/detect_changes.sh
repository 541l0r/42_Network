#!/bin/bash

# detect_changes.sh - Runs every minute
# Fetch users updated in a recent time window and enqueue IDs to backlog.
# Saves raw JSON snapshots to .cache/raw_detect; the worker will fetch full detail.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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
  CONFIG_TIME_WINDOW=$(grep -E '^\s*TIME_WINDOW=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}')
fi
DEFAULT_MAX_WINDOW="${CONFIG_TIME_WINDOW:-65}"
MAX_WINDOW="${TIME_WINDOW:-$DEFAULT_MAX_WINDOW}"

NOW_EPOCH=$(date -u +%s)
WINDOW_SECS="$MAX_WINDOW"
PID=$$

echo "[${LOG_TIMESTAMP}] [pid=${PID}] Detecting changes in last ${WINDOW_SECS}s" | tee -a "$LOG_FILE"

# Fetch users updated in window (filtered to students in cursus 21)
RAW_JSON=$(WINDOW_SECONDS="$WINDOW_SECS" FILTER_KIND=student FILTER_CURSUS_ID=21 FILTER_ALUMNI=false \
  bash "$ROOT_DIR/scripts/helpers/fetch_users_by_updated_at_window.sh" "$WINDOW_SECS" student 21 2>/dev/null || echo "[]")

# Validate JSON
if ! echo "$RAW_JSON" | jq empty >/dev/null 2>&1; then
  echo "[${LOG_TIMESTAMP}] Fetch returned invalid JSON, skipping" >> "$LOG_FILE"
  exit 0
fi

COUNT=$(echo "$RAW_JSON" | jq 'length' 2>/dev/null || echo "0")
echo "[${LOG_TIMESTAMP}] Found $COUNT users" >> "$LOG_FILE"

# Treat non-numeric counts as zero
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  COUNT=0
fi

if [ "$COUNT" -gt 0 ]; then
  timestamp=$(date -u +'%Y%m%d_%H%M%S')
  cache_file="$CACHE_DIR/users_${timestamp}.json"
  tmp_json=$(mktemp)
  echo "$RAW_JSON" | jq '.' > "$tmp_json"
  cp "$tmp_json" "$cache_file"

  HASH_FILE="$BACKLOG_DIR/detector_hashes.json"
  BACKLOG_FILE="$BACKLOG_DIR/fetch_queue.txt"

  TMP_JSON="$tmp_json" HASH_FILE="$HASH_FILE" BACKLOG_FILE="$BACKLOG_FILE" python3 << 'PYTHON_FINGERPRINT'
import json, os, hashlib

root = os.environ.get("ROOT_DIR", "/srv/42_Network/repo")
tmp_json = os.environ["TMP_JSON"]
hash_file = os.environ["HASH_FILE"]
backlog_file = os.environ["BACKLOG_FILE"]

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

def fingerprint(user):
    # Ignore volatile fields that should not trigger reprocessing
    ignore = {"updated_at", "alumnized_at", "created_at", "anonymize_date", "data_erasure_date"}
    filtered = {k: v for k, v in user.items() if k not in ignore}
    payload = json.dumps(filtered, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()

changed_ids = []
for u in users:
    uid = u.get("id")
    if uid is None:
        continue
    fp = fingerprint(u)
    last = hashes.get(str(uid))
    if last != fp:
        changed_ids.append(str(uid))
        hashes[str(uid)] = fp

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

  echo "[${LOG_TIMESTAMP}] Cached raw data to $cache_file" >> "$LOG_FILE"
  rm -f "$tmp_json"
fi

# Update last detection time (subtract 5 seconds for overlap safety)
LAST_EPOCH_FILE="$BACKLOG_DIR/last_detect_epoch"
NEXT_WINDOW_START=$((NOW_EPOCH - 5))
echo "$NEXT_WINDOW_START" > "$LAST_EPOCH_FILE"

# Keep log to last 500 lines
tail -500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
