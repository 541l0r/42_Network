#!/usr/bin/env bash
set -euo pipefail

# events_diff.sh - Inspect events_pending IDs and show JSON deltas vs baseline.
# - Reads IDs from .backlog/events_pending.txt (does NOT modify it).
# - Baselines are expected per-user under logs/.eventifier_baseline/ (created elsewhere).
# - If no baseline exists, just report that no comparison is available (do NOT create one).
# - Compares the full JSON (all fields, nested included).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"
BASELINE_DIR="$LOG_DIR/.eventifier_baseline"

EVENTS_PENDING="$BACKLOG_DIR/events_pending.txt"
DEFAULT_LIMIT=50
LIMIT="${1:-$DEFAULT_LIMIT}"

mkdir -p "$BASELINE_DIR"

export ROOT_DIR BACKLOG_DIR LOG_DIR BASELINE_DIR EVENTS_PENDING LIMIT

python3 - << 'PY'
import json, os, sys, glob, pathlib

root = os.environ["ROOT_DIR"]
backlog = os.environ["BACKLOG_DIR"]
baseline_dir = os.environ["BASELINE_DIR"]
events_pending = os.environ["EVENTS_PENDING"]
limit = int(os.environ.get("LIMIT", "50"))

def load_json(path, default=None):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except json.JSONDecodeError:
        return default

if not os.path.isfile(events_pending):
    print(f"❌ events_pending file not found: {events_pending}", file=sys.stderr)
    sys.exit(1)

with open(events_pending, "r") as f:
    ids = [line.strip() for line in f if line.strip().isdigit()]

ids = ids[:limit]

def find_export(uid: str):
    pattern = os.path.join(root, "exports", "09_users", "campus_*", f"user_{uid}.json")
    matches = glob.glob(pattern)
    return matches[0] if matches else None

def flatten(value, prefix=""):
    """Flatten nested dict/list into path -> value."""
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
            deltas.append((k, flat_old.get(k), flat_new.get(k)))
    return deltas

print("=== EVENTS DIFF ===")
print(f"IDs to inspect (limit {limit}): {len(ids)}")
print("")

for uid in ids:
    export_path = find_export(uid)
    if not export_path:
        print(f"uid={uid}: export not found (expected exports/09_users/campus_*/user_{uid}.json)")
        print("")
        continue

    current = load_json(export_path)
    if not isinstance(current, dict):
        print(f"uid={uid}: export JSON invalid at {export_path}")
        print("")
        continue

    baseline_path = os.path.join(baseline_dir, f"user_{uid}.json")
    baseline = load_json(baseline_path)

    if baseline is None:
        print(f"uid={uid}: no baseline found at {baseline_path} (no comparison)")
        print("")
        continue

    deltas = diff_all(baseline, current)
    if not deltas:
        print(f"uid={uid}: no changes vs baseline ({baseline_path})")
        print("")
        continue

    print(f"uid={uid}: {len(deltas)} change(s) vs baseline ({baseline_path})")
    for f, old, new in deltas:
        print(f"  {f}: {old!r} -> {new!r}")
    print("")
PY
