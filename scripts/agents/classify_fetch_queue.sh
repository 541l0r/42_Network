#!/usr/bin/env bash
# classify_fetch_queue.sh
# Adjusts internal/external fetch queues without reshuffling:
#   - Keep queue order as-is.
#   - If internal backlog reaches Nint: push location-only items to bottom.
#   - If external backlog reaches Next: drop external location-only noise.
# Inputs:
#   - Latest snapshot: .cache/raw_detect/users_latest.json (from detector)
#   - Baseline: exports/09_users/campus_<id>/user_<id>.json (last fetched)
# Outputs:
#   - Rewrites queues in-place:
#       .backlog/fetch_queue_internal.txt
#       .backlog/fetch_queue_external.txt
#   - Appends dropped externals (location-only) to:
#       .backlog/fetch_queue_external_dropped.txt

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"
LATEST_JSON="$ROOT_DIR/.cache/raw_detect/users_latest.json"
INTERNAL_QUEUE="$BACKLOG_DIR/fetch_queue_internal.txt"
EXTERNAL_QUEUE="$BACKLOG_DIR/fetch_queue_external.txt"
INTERNAL_LOCK="${INTERNAL_QUEUE}.lock"
EXTERNAL_LOCK="${EXTERNAL_QUEUE}.lock"
DROPPED_FILE="$BACKLOG_DIR/fetch_queue_external_dropped.txt"
EXPORT_BASE="$ROOT_DIR/exports/09_users"
INTERNAL_CAMPUS_ID="${CAMPUS_ID:-21}"

# Thresholds:
# - Nint: internal queue threshold (push location-only to bottom)
# - Next: external queue threshold (drop external location-only)
CONFIG_FILE="$ROOT_DIR/scripts/config/agents.config"
CONFIG_BACKLOG_NINT=""
CONFIG_BACKLOG_N1=""
CONFIG_BACKLOG_NEXT=""
CONFIG_BACKLOG_N2=""
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_BACKLOG_NINT=$(grep -E '^\s*BACKLOG_NINT_THRESHOLD=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}' || echo "")
  CONFIG_BACKLOG_N1=$(grep -E '^\s*BACKLOG_N1_THRESHOLD=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}' || echo "")
  CONFIG_BACKLOG_NEXT=$(grep -E '^\s*BACKLOG_NEXT_THRESHOLD=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}' || echo "")
  CONFIG_BACKLOG_N2=$(grep -E '^\s*BACKLOG_N2_THRESHOLD=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}' || echo "")
fi
DEFAULT_BACKLOG_NINT="100"
DEFAULT_BACKLOG_NEXT="500"
BACKLOG_NINT_THRESHOLD="${BACKLOG_NINT_THRESHOLD:-${BACKLOG_N1_THRESHOLD:-${CONFIG_BACKLOG_NINT:-${CONFIG_BACKLOG_N1:-$DEFAULT_BACKLOG_NINT}}}}"
BACKLOG_NEXT_THRESHOLD="${BACKLOG_NEXT_THRESHOLD:-${BACKLOG_N2_THRESHOLD:-${CONFIG_BACKLOG_NEXT:-${CONFIG_BACKLOG_N2:-$DEFAULT_BACKLOG_NEXT}}}}"

mkdir -p "$BACKLOG_DIR" "$LOG_DIR"
touch "$INTERNAL_QUEUE" "$EXTERNAL_QUEUE" "$DROPPED_FILE"

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG_DIR/switcher.log"
}

if [[ ! -f "$LATEST_JSON" ]]; then
  log "classify_fetch_queue: missing $LATEST_JSON; nothing to do"
  exit 0
fi

exec 3>"$INTERNAL_LOCK"
exec 4>"$EXTERNAL_LOCK"
flock -x 3
flock -x 4

BACKLOG_NINT_THRESHOLD="$BACKLOG_NINT_THRESHOLD" BACKLOG_NEXT_THRESHOLD="$BACKLOG_NEXT_THRESHOLD" python3 - "$LATEST_JSON" "$EXPORT_BASE" "$INTERNAL_QUEUE" "$EXTERNAL_QUEUE" "$DROPPED_FILE" "$LOG_DIR/switcher.log" "$INTERNAL_CAMPUS_ID" <<'PY'
import json, os, sys, time

latest_json, export_base, internal_q, external_q, dropped_file, log_file, internal_campus = sys.argv[1:]
internal_campus = int(internal_campus)
def env_int(name, default):
    try:
        return int(os.environ.get(name, str(default)))
    except Exception:
        return default

backlog_nint_threshold = env_int("BACKLOG_NINT_THRESHOLD", env_int("BACKLOG_N1_THRESHOLD", 100))
backlog_next_threshold = env_int("BACKLOG_NEXT_THRESHOLD", env_int("BACKLOG_N2_THRESHOLD", 500))

def log(msg):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(log_file, "a") as f:
        f.write(f"[{ts}] {msg}\n")

def load_latest(path):
    try:
        with open(path) as f:
            users = json.load(f)
        return {str(u.get("id")): u for u in users if isinstance(u, dict) and u.get("id") is not None}
    except Exception as e:
        log(f"classify_fetch_queue: failed to load latest snapshot: {e}")
        return {}

def read_queue(path):
    try:
        with open(path) as f:
            return [line.strip() for line in f if line.strip().isdigit()]
    except FileNotFoundError:
        return []

def get_campus(user):
    cu = user.get("campus_users") or []
    if cu:
        for entry in cu:
            if isinstance(entry, dict) and entry.get("is_primary"):
                return entry.get("campus_id")
        return cu[0].get("campus_id")
    camps = user.get("campus") or []
    if camps:
        return camps[0].get("id")
    return None

def load_baseline(export_base, user):
    uid = user.get("id")
    campus_id = get_campus(user)
    if campus_id is None:
        return None
    path = os.path.join(export_base, f"campus_{campus_id}", f"user_{uid}.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

def to_number(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None

latest = load_latest(latest_json)
internal_ids = read_queue(internal_q)
external_ids = read_queue(external_q)

internal_reached = len(internal_ids) >= backlog_nint_threshold
drop_enabled = len(external_ids) >= backlog_next_threshold

def is_location_only(uid):
    user = latest.get(uid)
    if not user:
        return False, None
    campus_id = get_campus(user)
    baseline = load_baseline(export_base, user)
    if baseline is None:
        return False, campus_id

    location_changed = baseline.get("location") != user.get("location")
    wallet_changed = baseline.get("wallet") != user.get("wallet")
    cp_old, cp_new = to_number(baseline.get("correction_point")), to_number(user.get("correction_point"))
    cp_delta = None
    if cp_old is not None and cp_new is not None:
        cp_delta = cp_new - cp_old
    name_changed = any(baseline.get(k) != user.get(k) for k in ("login", "first_name", "last_name"))

    loc_only = location_changed and not (wallet_changed or (cp_delta not in (None, 0)) or name_changed)
    return bool(loc_only), campus_id

# Internal queue: stable partition (only when Nint reached).
if internal_reached:
    internal_keep = []
    internal_loc = []
    seen = set()
    for uid in internal_ids:
        if uid in seen:
            continue
        seen.add(uid)
        loc_only, _ = is_location_only(uid)
        (internal_loc if loc_only else internal_keep).append(uid)
    internal_ordered = internal_keep + internal_loc
else:
    internal_ordered = list(dict.fromkeys(internal_ids))

# External queue: keep order; drop location-only externals only when Next reached.
external_ordered = []
dropped_ext = []
seen_ext = set()
internal_final = set(internal_ordered)
for uid in external_ids:
    if uid in internal_final:
        continue
    if uid in seen_ext:
        continue
    seen_ext.add(uid)
    loc_only, campus_id = is_location_only(uid)
    if drop_enabled and campus_id is not None and int(campus_id) != internal_campus and loc_only:
        dropped_ext.append(uid)
        continue
    external_ordered.append(uid)

with open(internal_q, "w") as f:
    for uid in internal_ordered:
        f.write(f"{uid}\n")

with open(external_q, "w") as f:
    for uid in external_ordered:
        f.write(f"{uid}\n")

if dropped_ext:
    with open(dropped_file, "a") as f:
        for uid in dropped_ext:
            f.write(f"{uid}\n")

log(
    f"classify_fetch_queue: int_in={len(internal_ids)} int_out={len(internal_ordered)} "
    f"ext_in={len(external_ids)} ext_out={len(external_ordered)} ext_dropped_location_only={len(dropped_ext)} "
    f"nint={backlog_nint_threshold} next={backlog_next_threshold} drop_enabled={int(drop_enabled)}"
)
PY

flock -u 4
flock -u 3
exec 4>&-
exec 3>&-
