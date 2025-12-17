#!/usr/bin/env bash
set -euo pipefail

# events_diff.sh - Inspect the latest events emitted by detector.
# - Reads from .backlog/events_queue.jsonl (append-only log).
# - Shows the last N entries with their change summary (types + fields).
# - Does not mutate the queue.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"
EVENTS_QUEUE="$BACKLOG_DIR/events_queue.jsonl"
DEFAULT_LIMIT=50
LIMIT="${1:-$DEFAULT_LIMIT}"

export EVENTS_QUEUE LIMIT

python3 - << 'PY'
import json, os, sys, time

queue_file = os.environ["EVENTS_QUEUE"]
limit = int(os.environ.get("LIMIT", "50"))

if not os.path.isfile(queue_file):
    print(f"❌ events_queue file not found: {queue_file}", file=sys.stderr)
    sys.exit(1)

with open(queue_file, "r") as f:
    lines = [line.strip() for line in f if line.strip()]

if not lines:
    print("No events recorded yet.")
    sys.exit(0)

events = lines[-limit:]
print(f"=== Last {len(events)} events (tail of events_queue) ===")
for raw in events:
    try:
        ev = json.loads(raw)
    except json.JSONDecodeError:
        print(f"(invalid json) {raw}")
        continue
    uid = ev.get("user_id")
    login = ev.get("user_login")
    campus = ev.get("campus_id")
    ts = ev.get("updated_at")
    primary = ev.get("primary_type")
    types = ev.get("types") or []
    print(f"- user={uid} ({login}) campus={campus} updated_at={ts} primary={primary} types={types}")
    for change in ev.get("changes", []):
        path = change.get("path")
        old = change.get("old")
        new = change.get("new")
        print(f"    • {path}: {old!r} -> {new!r}")
print("")
PY
