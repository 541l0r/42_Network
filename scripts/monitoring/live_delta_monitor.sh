#!/usr/bin/env bash
set -euo pipefail

# Live Delta Monitor - Compare latest detector snapshot to previous, show field deltas

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
STATE_DIR="$LOG_DIR/.monitor_state"

mkdir -p "$STATE_DIR"

RAW_FILE="${RAW_FILE:-$ROOT_DIR/.cache/raw_detect/users_latest.json}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/last_detect_snapshot.json}"
LIMIT="${LIMIT:-20}"  # how many users with changes to display
# Set SAVE_BASELINE=1 to persist snapshot locally (detector already tracks hashes elsewhere)
SAVE_BASELINE="${SAVE_BASELINE:-0}"

export ROOT_DIR RAW_FILE STATE_FILE LIMIT

python3 - << 'PY'
import json, os, sys

root = os.environ["ROOT_DIR"]
raw_file = os.environ["RAW_FILE"]
state_file = os.environ["STATE_FILE"]
limit = int(os.environ["LIMIT"])
save_baseline = os.environ.get("SAVE_BASELINE", "0") == "1"

config_path = os.path.join(root, "scripts/config/detector_fields.json")

def load_json(path, default=None):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except json.JSONDecodeError:
        return default

config = load_json(config_path, {})
external_fields = config.get("externals", {}).get("fields", [])
if not external_fields:
    external_fields = config.get("internals", {}).get("fields", [])

current_list = load_json(raw_file, [])
if not isinstance(current_list, list):
    print(f"❌ Current snapshot invalid or missing: {raw_file}", file=sys.stderr)
    sys.exit(1)

previous_list = load_json(state_file, [])
prev_map = {u.get("id"): u for u in previous_list if isinstance(u, dict) and "id" in u}
curr_map = {u.get("id"): u for u in current_list if isinstance(u, dict) and "id" in u}

changed = []
for uid, user in curr_map.items():
    before = prev_map.get(uid)
    if not before:
        # new user in snapshot; treat as all fields new
        deltas = [(f, None, user.get(f)) for f in external_fields if f in user]
    else:
        deltas = []
        for f in external_fields:
            old = before.get(f)
            new = user.get(f)
            if old != new:
                deltas.append((f, old, new))
    if deltas:
        changed.append((uid, deltas, user.get("updated_at")))

changed.sort(key=lambda x: (-(len(x[1])), x[2] or ""))

print("=== LIVE DELTA MONITOR ===")
print(f"Snapshot: {len(curr_map)} users from {raw_file}")
print(f"Previous: {len(prev_map)} users from {state_file}")
print(f"Changed users (tracked fields): {len(changed)}")
print("")

for uid, deltas, updated_at in changed[:limit]:
    print(f"uid={uid} updated_at={updated_at}")
    for f, old, new in deltas:
        print(f"  {f}: {old!r} -> {new!r}")
    print("")

if not changed:
    print("No tracked-field deltas between last two snapshots.")

if save_baseline:
    # Save current snapshot for next comparison (local-only; detector manages its own hashes)
    try:
        with open(state_file, "w") as f:
            json.dump(current_list, f)
    except Exception as e:
        print(f"⚠️  Could not write state file {state_file}: {e}", file=sys.stderr)
else:
    print("Baseline NOT saved (set SAVE_BASELINE=1 to persist local snapshot).")
PY
