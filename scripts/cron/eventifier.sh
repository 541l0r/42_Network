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
import glob
import json
import os
import time

exports_dir = os.environ["EXPORTS_DIR"]
baseline_dir = os.environ["BASELINE_DIR"]
events_queue = os.environ["EVENTS_QUEUE"]
events_queue_lock = os.environ["EVENTS_QUEUE_LOCK"]

env_ids = os.environ.get("IDS", "")
print(f"eventifier: env IDS='{env_ids}'")
ids = [x for x in env_ids.split(",") if x] if env_ids else []


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


def to_number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def normalize_location(value):
    if value in (None, ""):
        return None
    return value


def snapshot(user):
    return {
        "login": user.get("login"),
        "first_name": user.get("first_name"),
        "last_name": user.get("last_name"),
        "correction_point": user.get("correction_point"),
        "wallet": user.get("wallet"),
        "location": normalize_location(user.get("location")),
    }


EVENT_TYPE_ORDER = (
    "data",
    "connection",
    "deconnection",
    "evaluation",
    "correction",
    "wallet",
)


def build_changes(old_snap, new_snap):
    changes = []
    present_types = set()

    for key in ("login", "first_name", "last_name"):
        old = old_snap.get(key)
        new = new_snap.get(key)
        if old != new:
            changes.append({"path": key, "old": old, "new": new})
            present_types.add("data")

    old_loc = normalize_location(old_snap.get("location"))
    new_loc = normalize_location(new_snap.get("location"))
    if old_loc != new_loc:
        if old_loc is None and new_loc is not None:
            changes.append({"path": "location", "old": None, "new": new_loc})
            present_types.add("connection")
        elif old_loc is not None and new_loc is None:
            changes.append({"path": "location", "old": old_loc, "new": None})
            present_types.add("deconnection")

    old_cp = to_number(old_snap.get("correction_point"))
    new_cp = to_number(new_snap.get("correction_point"))
    if old_cp is not None and new_cp is not None and old_cp != new_cp:
        changes.append({"path": "correction_point", "old": old_cp, "new": new_cp})
        delta = new_cp - old_cp
        if delta < 0:
            present_types.add("evaluation")
        elif delta > 0:
            present_types.add("correction")

    old_wallet = to_number(old_snap.get("wallet"))
    new_wallet = to_number(new_snap.get("wallet"))
    if old_wallet is not None and new_wallet is not None and old_wallet != new_wallet:
        changes.append({"path": "wallet", "old": old_wallet, "new": new_wallet})
        present_types.add("wallet")

    ordered_types = [t for t in EVENT_TYPE_ORDER if t in present_types]
    return changes, ordered_types


def get_campus_id(user):
    campus_users = user.get("campus_users", [])
    if isinstance(campus_users, list) and campus_users:
        for cu in campus_users:
            if isinstance(cu, dict) and cu.get("is_primary"):
                return cu.get("campus_id")
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
        events.append(
            {
                "user_id": int(uid),
                "error": f"export not found for user_{uid}.json",
                "ts": int(time.time()),
            }
        )
        continue

    current = load_json(export_path)
    if not isinstance(current, dict):
        events.append(
            {
                "user_id": int(uid),
                "error": f"invalid JSON at {export_path}",
                "ts": int(time.time()),
            }
        )
        continue

    baseline_path = os.path.join(baseline_dir, f"user_{uid}.json")
    baseline_raw = load_json(baseline_path)
    baseline_snap = snapshot(baseline_raw) if isinstance(baseline_raw, dict) else None
    current_snap = snapshot(current)

    first_snapshot = baseline_snap is None
    changes = []
    types = []
    if not first_snapshot:
        changes, types = build_changes(baseline_snap, current_snap)

    try:
        with open(baseline_path, "w") as f:
            json.dump(current_snap, f, indent=2)
    except Exception as e:
        events.append(
            {
                "user_id": int(uid),
                "error": f"failed to write baseline {baseline_path}: {e}",
                "ts": int(time.time()),
            }
        )
        continue

    if first_snapshot or not types:
        continue

    events.append(
        {
            "user_id": int(uid),
            "user_login": current.get("login"),
            "campus_id": get_campus_id(current),
            "updated_at": current.get("updated_at"),
            "first_snapshot": first_snapshot,
            "types": types,
            "primary_type": types[0] if types else None,
            "changes": changes,
            "source": "eventifier",
            "ts": int(time.time()),
        }
    )

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
