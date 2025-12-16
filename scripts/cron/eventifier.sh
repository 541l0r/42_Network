#!/bin/bash

# eventifier.sh - Process events_pending queue, diff exports vs baselines, emit JSONL events
# Baselines: logs/.eventifier_baseline/user_<id>.json
# Events:    .backlog/events_queue.jsonl (append-only)
# Queue:     .backlog/events_pending.txt (populated by fetcher)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"
EXPORTS_DIR="$ROOT_DIR/exports/09_users"
BASELINE_DIR="$LOG_DIR/.eventifier_baseline"

EVENTS_PENDING="$BACKLOG_DIR/events_pending.txt"
EVENTS_LOCK="$BACKLOG_DIR/events_pending.lock"
EVENTS_QUEUE="$BACKLOG_DIR/events_queue.jsonl"
EVENTS_QUEUE_LOCK="$BACKLOG_DIR/events_queue.lock"

mkdir -p "$BACKLOG_DIR" "$LOG_DIR" "$BASELINE_DIR"
touch "$EVENTS_PENDING" "$EVENTS_LOCK" "$EVENTS_QUEUE" "$EVENTS_QUEUE_LOCK"

EVENT_BATCH="${EVENT_BATCH:-50}"

# Acquire lock and pull a batch of IDs
exec 9>"$EVENTS_LOCK"
flock -x 9
mapfile -t ID_ARR < <(head -n "$EVENT_BATCH" "$EVENTS_PENDING" | sed '/^$/d')

if [[ ${#ID_ARR[@]} -eq 0 ]]; then
  flock -u 9
  exec 9>&-
  echo "eventifier: no IDs in events_pending.txt"
  exit 0
fi

# Rewrite queue without the batch we pulled
tmp_queue=$(mktemp)
tail -n +"$(( ${#ID_ARR[@]} + 1 ))" "$EVENTS_PENDING" > "$tmp_queue" || true
mv "$tmp_queue" "$EVENTS_PENDING"

flock -u 9
exec 9>&-

ID_COUNT=${#ID_ARR[@]}
ID_LIST="$(IFS=,; echo "${ID_ARR[*]}")"
export ROOT_DIR BACKLOG_DIR EXPORTS_DIR BASELINE_DIR EVENTS_PENDING EVENTS_QUEUE EVENTS_QUEUE_LOCK
export IDS="$ID_LIST"
env | grep '^IDS=' >&2 || true
echo "eventifier: ID_LIST='$ID_LIST'" >&2
echo "eventifier: processing ${ID_COUNT} ids from queue" >&2

python3 - << 'PY'
import json, os, glob, sys, time

root = os.environ["ROOT_DIR"]
backlog_dir = os.environ["BACKLOG_DIR"]
exports_dir = os.environ["EXPORTS_DIR"]
baseline_dir = os.environ["BASELINE_DIR"]
events_queue = os.environ["EVENTS_QUEUE"]
events_queue_lock = os.environ["EVENTS_QUEUE_LOCK"]
env_ids = os.environ.get("IDS", "")
print(f"eventifier: env IDS='{env_ids}'")
ids = env_ids.split(",") if env_ids else []

def load_json(path):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except json.JSONDecodeError:
        return None

def find_export(uid: str):
    pattern = os.path.join(exports_dir, "campus_*", f"user_{uid}.json")
    matches = glob.glob(pattern)
    return matches[0] if matches else None

def flatten(value, prefix=""):
    out = {}
    if isinstance(value, dict):
        for k, v in value.items():
            new_prefix = f"{prefix}.{k}" if prefix else str(k)
            out.update(flatten(v, new_prefix))
    elif isinstance(value, list):
        for idx, v in enumerate(value):
            new_prefix = f"{prefix}[{idx}]" if prefix else f"[{idx}]"
            out.update(flatten(v, new_prefix))
    else:
        out[prefix] = value
    return out

def diff_all(old, new):
    flat_old = flatten(old if old is not None else {})
    flat_new = flatten(new if new is not None else {})
    keys = sorted(set(flat_old.keys()) | set(flat_new.keys()))
    deltas = []
    for k in keys:
        if flat_old.get(k) != flat_new.get(k):
            deltas.append({"path": k, "old": flat_old.get(k), "new": flat_new.get(k)})
    return deltas

def get_campus_id(user):
    campus_users = user.get("campus_users", [])
    if isinstance(campus_users, list) and campus_users:
        cu0 = campus_users[0]
        if isinstance(cu0, dict):
            return cu0.get("campus_id")
    campus_list = user.get("campus", [])
    if isinstance(campus_list, list) and campus_list:
        c0 = campus_list[0]
        if isinstance(c0, dict):
            return c0.get("id")
    return None

events = []

for uid in ids:
    export_path = find_export(uid)
    if not export_path:
        events.append({
            "user_id": int(uid),
            "error": f"export not found for user_{uid}.json",
            "ts": int(time.time())
        })
        continue

    current = load_json(export_path)
    if not isinstance(current, dict):
        events.append({
            "user_id": int(uid),
            "error": f"invalid JSON at {export_path}",
            "ts": int(time.time())
        })
        continue

    baseline_path = os.path.join(baseline_dir, f"user_{uid}.json")
    baseline = load_json(baseline_path)

    first_snapshot = baseline is None
    changes = [] if first_snapshot else diff_all(baseline, current)

    event = {
        "user_id": int(uid),
        "user_login": current.get("login"),
        "campus_id": get_campus_id(current),
        "updated_at": current.get("updated_at"),
        "first_snapshot": first_snapshot,
        "changes": changes,
        "source": "eventifier",
        "ts": int(time.time())
    }
    events.append(event)

    # Update baseline to current snapshot
    try:
        with open(baseline_path, "w") as f:
            json.dump(current, f, indent=2)
    except Exception as e:
        events.append({
            "user_id": int(uid),
            "error": f"failed to write baseline {baseline_path}: {e}",
            "ts": int(time.time())
        })

# Append to events_queue with a lock
with open(events_queue_lock, "w") as lf:
    try:
        import fcntl
        fcntl.flock(lf, fcntl.LOCK_EX)
    except Exception:
        pass
    with open(events_queue, "a") as eq:
        for ev in events:
            eq.write(json.dumps(ev) + "\n")

print(f"eventifier: processed {len(ids)} ids, wrote {len(events)} event records to {events_queue}")
PY
