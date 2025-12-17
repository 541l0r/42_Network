#!/bin/bash

# detector.sh - Fetch users updated in a short time window and manage queues.
# Responsibilities:
#   • Fetch /v2/cursus/21/users delta window (student, non alumni)
#   • Compare fingerprints to detector_hashes.json (location collapsed to connect flag)
#   • Enqueue internal/external fetch_queue_* with dedupe + backlog policy
#   • Emit WARN when queues cross thresholds (edge-triggered via detector_backlog_level)
#   • Append event payloads directly to .backlog/events_queue.jsonl (replaces eventifier)

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

BACKLOG_DIR="$ROOT_DIR/.backlog"
LOG_DIR="$ROOT_DIR/logs"
CACHE_DIR="$ROOT_DIR/.cache/raw_detect"
EXPORTS_DIR="$ROOT_DIR/exports/09_users"

mkdir -p "$BACKLOG_DIR" "$LOG_DIR" "$CACHE_DIR" "$EXPORTS_DIR"

HASH_FILE="$BACKLOG_DIR/detector_hashes.json"
INTERNAL_QUEUE="$BACKLOG_DIR/fetch_queue_internal.txt"
EXTERNAL_QUEUE="$BACKLOG_DIR/fetch_queue_external.txt"
INTERNAL_LOCK="${INTERNAL_QUEUE}.lock"
EXTERNAL_LOCK="${EXTERNAL_QUEUE}.lock"
DROPPED_EXT_FILE="$BACKLOG_DIR/fetch_queue_external_dropped.txt"
BACKLOG_LEVEL_FILE="$BACKLOG_DIR/detector_backlog_level"
EVENTS_QUEUE="$BACKLOG_DIR/events_queue.jsonl"
EVENTS_QUEUE_LOCK="$BACKLOG_DIR/events_queue.lock"

mkdir -p "$BACKLOG_DIR"
touch "$HASH_FILE" "$INTERNAL_QUEUE" "$EXTERNAL_QUEUE" "$DROPPED_EXT_FILE" \
  "$BACKLOG_LEVEL_FILE" "$EVENTS_QUEUE" "$EVENTS_QUEUE_LOCK"

LOG_FILE="$LOG_DIR/detect_changes.log"
LOG_TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
PID=$$

CONFIG_FILE="$ROOT_DIR/scripts/config/agents.config"
CONFIG_TIME_WINDOW=""
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_TIME_WINDOW=$(grep -E '^[[:space:]]*TIME_WINDOW=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}' || echo "")
fi
DEFAULT_MAX_WINDOW="${CONFIG_TIME_WINDOW:-65}"
MAX_WINDOW="${TIME_WINDOW:-$DEFAULT_MAX_WINDOW}"

INTERNAL_CAMPUS_ID="${CAMPUS_ID:-21}"

CONFIG_BACKLOG_NINT=""
CONFIG_BACKLOG_N1=""
CONFIG_BACKLOG_NEXT=""
CONFIG_BACKLOG_N2=""
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_BACKLOG_NINT=$(grep -E '^[[:space:]]*BACKLOG_NINT_THRESHOLD=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}' || echo "")
  CONFIG_BACKLOG_N1=$(grep -E '^[[:space:]]*BACKLOG_N1_THRESHOLD=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}' || echo "")
  CONFIG_BACKLOG_NEXT=$(grep -E '^[[:space:]]*BACKLOG_NEXT_THRESHOLD=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}' || echo "")
  CONFIG_BACKLOG_N2=$(grep -E '^[[:space:]]*BACKLOG_N2_THRESHOLD=' "$CONFIG_FILE" | head -1 | cut -d= -f2 | awk '{print $1}' || echo "")
fi
DEFAULT_BACKLOG_NINT="100"
DEFAULT_BACKLOG_NEXT="500"
BACKLOG_NINT_THRESHOLD="${BACKLOG_NINT_THRESHOLD:-${BACKLOG_N1_THRESHOLD:-${CONFIG_BACKLOG_NINT:-${CONFIG_BACKLOG_N1:-$DEFAULT_BACKLOG_NINT}}}}"
BACKLOG_NEXT_THRESHOLD="${BACKLOG_NEXT_THRESHOLD:-${BACKLOG_N2_THRESHOLD:-${CONFIG_BACKLOG_NEXT:-${CONFIG_BACKLOG_N2:-$DEFAULT_BACKLOG_NEXT}}}}"

RAW_JSON=$(WINDOW_SECONDS="$MAX_WINDOW" FILTER_KIND=student FILTER_CURSUS_ID=21 FILTER_ALUMNI=false \
  bash "$ROOT_DIR/scripts/helpers/fetch_users_by_updated_at_window.sh" "$MAX_WINDOW" student 21 2>/dev/null || echo "[]")

if ! echo "$RAW_JSON" | jq empty >/dev/null 2>&1; then
  echo "[${LOG_TIMESTAMP}] [pid=${PID}] ERROR: Invalid JSON response" >> "$LOG_FILE"
  exit 0
fi

COUNT=$(echo "$RAW_JSON" | jq 'length' 2>/dev/null || echo "0")
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  COUNT=0
fi

if [[ "$COUNT" -eq 0 ]]; then
  CUR_QINT=$(wc -l < "$INTERNAL_QUEUE" 2>/dev/null || echo 0)
  CUR_QEXT=$(wc -l < "$EXTERNAL_QUEUE" 2>/dev/null || echo 0)
  echo "[${LOG_TIMESTAMP}] [pid=${PID}] detect=0 fp=0 int=0 ext=0 qint=${CUR_QINT} qext=${CUR_QEXT} drop=0 WARN=empty_window" >> "$LOG_FILE"
  exit 0
fi

cache_file="$CACHE_DIR/users_latest.json"
tmp_json=$(mktemp)
echo "$RAW_JSON" | jq '.' > "$tmp_json"
cp "$tmp_json" "$cache_file"

exec 4>"$INTERNAL_LOCK"
exec 5>"$EXTERNAL_LOCK"
flock -x 4
flock -x 5

PY_OUT=$(ROOT_DIR="$ROOT_DIR" TMP_JSON="$tmp_json" HASH_FILE="$HASH_FILE" INTERNAL_QUEUE="$INTERNAL_QUEUE" EXTERNAL_QUEUE="$EXTERNAL_QUEUE" \
  INTERNAL_CAMPUS_ID="$INTERNAL_CAMPUS_ID" DROPPED_EXT_FILE="$DROPPED_EXT_FILE" \
  BACKLOG_LEVEL_FILE="$BACKLOG_LEVEL_FILE" BACKLOG_NINT_THRESHOLD="$BACKLOG_NINT_THRESHOLD" BACKLOG_NEXT_THRESHOLD="$BACKLOG_NEXT_THRESHOLD" \
  EVENTS_QUEUE="$EVENTS_QUEUE" EVENTS_QUEUE_LOCK="$EVENTS_QUEUE_LOCK" python3 <<'PYTHON_DETECTOR'
import datetime
import fcntl
import hmac
import hashlib
import json
import os
import time

root = os.environ.get("ROOT_DIR", "/srv/42_Network/repo")
if not os.path.isdir(root) and os.path.isdir("/app"):
    root = "/app"
exports_dir = os.path.join(root, "exports", "09_users")
os.makedirs(exports_dir, exist_ok=True)

tmp_json = os.environ["TMP_JSON"]
hash_file = os.environ["HASH_FILE"]
internal_queue = os.environ["INTERNAL_QUEUE"]
external_queue = os.environ["EXTERNAL_QUEUE"]
dropped_ext_file = os.environ["DROPPED_EXT_FILE"]
level_file = os.environ.get("BACKLOG_LEVEL_FILE") or os.path.join(os.path.dirname(internal_queue), "detector_backlog_level")
backlog_nint_threshold = int(os.environ.get("BACKLOG_NINT_THRESHOLD", os.environ.get("BACKLOG_N1_THRESHOLD", "100")))
backlog_next_threshold = int(os.environ.get("BACKLOG_NEXT_THRESHOLD", os.environ.get("BACKLOG_N2_THRESHOLD", "500")))
try:
    internal_campus_id = int(os.environ.get("INTERNAL_CAMPUS_ID", "21"))
except Exception:
    internal_campus_id = 21

config_file = os.path.join(root, "scripts", "config", "detector_fields.json")
config = {}
try:
    with open(config_file, "r") as f:
        config = json.load(f)
except Exception:
    pass
internal_fields = config.get("internals", {}).get("fields", [])
external_fields = config.get("externals", {}).get("fields", [])
if not external_fields:
    external_fields = internal_fields
hmac_keys = config.get("hmac_keys", {})
hmac_key_internal = hmac_keys.get("internal", "42network_internal_detection")
hmac_key_external = hmac_keys.get("external", "42network_external_detection")
fetcher_fields_path = os.path.join(root, "scripts", "config", "fetcher_fields.json")
fetcher_config = {}
try:
    with open(fetcher_fields_path, "r") as f:
        fetcher_config = json.load(f)
        if not isinstance(fetcher_config, dict):
            fetcher_config = {}
except Exception:
    fetcher_config = {}

EVENT_ORDER = (
    "data",
    "connection",
    "deconnection",
    "evaluation",
    "correction",
    "wallet",
)
TRACKED_EVENTS = ["connection", "deconnection", "wallet", "correction", "evaluation", "data", "new_seen"]
SNAPSHOT_FIELDS = ["login", "first_name", "last_name", "correction_point", "wallet", "location"]


def bucket_for(fp_key):
    return "int" if fp_key == "internal" else "ext"


def init_event_counters():
    return {name: {"int": 0, "ext": 0} for name in TRACKED_EVENTS}


def resolve_priority(fp_key, event_types):
    mapping = fetcher_config.get(fp_key, {})
    priority = 0
    for event_type in event_types:
        try:
            value = int(mapping.get(event_type, None))
        except (TypeError, ValueError):
            value = None
        if value is None:
            value = 2
        if value > priority:
            priority = value
    return max(priority, 0)


def load_json(path, default):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except json.JSONDecodeError:
        return default


def write_json(path, payload):
    with open(path, "w") as f:
        json.dump(payload, f)


def read_queue(path):
    if not os.path.isfile(path):
        return []
    with open(path, "r") as f:
        return [line.strip() for line in f if line.strip().isdigit()]


def write_queue(path, items):
    with open(path, "w") as f:
        for uid in items:
            f.write(f"{uid}\n")


def dedup_preserve(items):
    seen = set()
    out = []
    for uid in items:
        if uid in seen:
            continue
        seen.add(uid)
        out.append(uid)
    return out


def apply_priority_queue(existing, updates):
    if not updates:
        return existing
    top_ids = []
    bottom_ids = []
    for item in updates:
        try:
            priority = int(item.get("priority", 0))
        except (TypeError, ValueError):
            priority = 0
        uid = item.get("uid")
        if not uid:
            continue
        if priority >= 2:
            top_ids.append(uid)
        elif priority > 0:
            bottom_ids.append(uid)
    if not top_ids and not bottom_ids:
        return existing
    return dedup_preserve(top_ids + existing + bottom_ids)


def fingerprint(user, fields, hmac_key):
    filtered = {}
    for key in fields:
        if key not in user:
            continue
        value = user.get(key)
        if key == "location":
            filtered[key] = 0 if value in (None, "") else 1
        else:
            filtered[key] = value
    payload = json.dumps(filtered, sort_keys=True, separators=(",", ":"))
    return hmac.new(hmac_key.encode(), payload.encode(), hashlib.sha256).hexdigest()


def get_campus_id(user):
    campus_users = user.get("campus_users")
    if isinstance(campus_users, list) and campus_users:
        for cu in campus_users:
            if isinstance(cu, dict) and cu.get("is_primary"):
                return cu.get("campus_id")
        first = campus_users[0]
        if isinstance(first, dict):
            return first.get("campus_id")
    campus_list = user.get("campus")
    if isinstance(campus_list, list) and campus_list:
        first = campus_list[0]
        if isinstance(first, dict):
            return first.get("id")
    return None


def get_updated_timestamp(user):
    updated = user.get("updated_at")
    if not updated:
        return None
    try:
        dt = datetime.datetime.fromisoformat(updated.replace('Z', '+00:00'))
        return dt.timestamp()
    except Exception:
        return None



def to_number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def normalize_location(value):
    if value in (None, ""):
        return None
    return value


def build_event_changes(baseline, current):
    events = {}
    if not isinstance(baseline, dict) or not isinstance(current, dict):
        return events

    def add_change(event_type, change):
        events.setdefault(event_type, []).append(change)

    for key in ("login", "first_name", "last_name"):
        old = baseline.get(key)
        new = current.get(key)
        if old != new:
            add_change("data", {"path": key, "old": old, "new": new})

    old_loc = normalize_location(baseline.get("location"))
    new_loc = normalize_location(current.get("location"))
    if old_loc != new_loc:
        change = {"path": "location", "old": old_loc, "new": new_loc}
        if old_loc is None and new_loc is not None:
            add_change("connection", change)
        elif old_loc is not None and new_loc is None:
            add_change("deconnection", change)

    old_cp = to_number(baseline.get("correction_point"))
    new_cp = to_number(current.get("correction_point"))
    if old_cp is not None and new_cp is not None and old_cp != new_cp:
        change = {"path": "correction_point", "old": old_cp, "new": new_cp}
        delta = new_cp - old_cp
        if delta < 0:
            add_change("evaluation", change)
        elif delta > 0:
            add_change("correction", change)

    old_wallet = to_number(baseline.get("wallet"))
    new_wallet = to_number(current.get("wallet"))
    if old_wallet is not None and new_wallet is not None and old_wallet != new_wallet:
        add_change("wallet", {"path": "wallet", "old": old_wallet, "new": new_wallet})

    return events


def build_snapshot(user):
    snap = {}
    for field in SNAPSHOT_FIELDS:
        if field == "location":
            snap[field] = normalize_location(user.get(field))
        elif field in ("correction_point", "wallet"):
            snap[field] = to_number(user.get(field))
        else:
            snap[field] = user.get(field)
    return snap


users = load_json(tmp_json, [])
hashes = load_json(hash_file, {})
existing_internal = dedup_preserve(read_queue(internal_queue))
existing_external = dedup_preserve(read_queue(external_queue))

changed_internal = []
changed_external = []
events_payload = []
dropped_ids = []
fp_changes = 0
event_counts = init_event_counters()
error_counts = {"int": 0, "ext": 0}
queue_updates_internal = []
queue_updates_external = []
skip_internal_count = 0
skip_external_count = 0
send_internal_uids = set()
send_external_uids = set()


def bump_counts(types, fp_key):
    bucket = bucket_for(fp_key)
    for ev in types:
        if ev in event_counts:
            event_counts[ev][bucket] += 1


def bump_error(fp_key=None):
    bucket = bucket_for(fp_key)
    error_counts[bucket] += 1


for user in users:
    if not isinstance(user, dict):
        bump_error()
        continue
    if user.get("label") == "error":
        bump_error()
        continue
    uid = user.get("id")
    if uid is None:
        bump_error()
        continue
    uid_str = str(uid)

    campus_id_raw = get_campus_id(user)
    try:
        campus_id = int(campus_id_raw) if campus_id_raw is not None else None
    except Exception:
        campus_id = campus_id_raw

    last_entry = hashes.get(uid_str)
    if campus_id is None and isinstance(last_entry, dict):
        campus_id = last_entry.get("campus_id")
    if campus_id is None:
        campus_id = internal_campus_id

    new_ts = get_updated_timestamp(user)
    old_ts = None
    last_hash_value = None
    if isinstance(last_entry, dict):
        old_ts = last_entry.get("timestamp")
        last_hash_value = last_entry.get("hash")
    elif isinstance(last_entry, str):
        last_hash_value = last_entry

    fingerprint_key = "internal" if campus_id == internal_campus_id else "external"
    fields = internal_fields if fingerprint_key == "internal" else external_fields
    hmac_key = hmac_key_internal if fingerprint_key == "internal" else hmac_key_external
    fp = fingerprint(user, fields, hmac_key)

    if last_hash_value == fp:
        continue

    baseline = None
    if isinstance(last_entry, dict):
        baseline = last_entry.get("snapshot")
    location_changed = False
    wallet_changed = False
    name_changed = False
    cp_delta = None
    new_seen_event = False
    if baseline is not None:
        location_changed = normalize_location(baseline.get("location")) != normalize_location(user.get("location"))
        wallet_changed = to_number(baseline.get("wallet")) != to_number(user.get("wallet"))
        cp_old = to_number(baseline.get("correction_point"))
        cp_new = to_number(user.get("correction_point"))
        if cp_old is not None and cp_new is not None:
            cp_delta = cp_new - cp_old
        name_changed = any(baseline.get(k) != user.get(k) for k in ("login", "first_name", "last_name"))
    else:
        new_seen_event = True

    is_location_only = bool(baseline is not None and location_changed and not (wallet_changed or name_changed or (cp_delta not in (None, 0))))
    target = changed_internal if fingerprint_key == "internal" else changed_external
    target.append({
        "uid": uid_str,
        "is_location_only": is_location_only,
        "campus_id": campus_id
    })

    current_snapshot = build_snapshot(user)
    new_events = []
    trigger_types = set()
    if new_seen_event:
        new_events.append({
            "user_id": int(uid),
            "user_login": user.get("login"),
            "campus_id": campus_id,
            "updated_at": user.get("updated_at"),
            "first_snapshot": True,
            "types": ["new_seen"],
            "changes": [],
            "source": "detector",
            "ts": int(time.time())
        })
        trigger_types.add("new_seen")
        bump_counts(["new_seen"], fingerprint_key)
    else:
        type_changes = build_event_changes(baseline, user) if baseline is not None else {}
        if type_changes:
            for event_type in EVENT_ORDER:
                if event_type in type_changes:
                    change_list = type_changes[event_type]
                    new_events.append({
                        "user_id": int(uid),
                        "user_login": user.get("login"),
                        "campus_id": campus_id,
                        "updated_at": user.get("updated_at"),
                        "first_snapshot": False,
                        "types": [event_type],
                        "changes": change_list,
                        "source": "detector",
                        "ts": int(time.time())
                    })
                    trigger_types.add(event_type)
                    bump_counts([event_type], fingerprint_key)
        if not new_events:
            new_events.append({
                "user_id": int(uid),
                "user_login": user.get("login"),
                "campus_id": campus_id,
                "updated_at": user.get("updated_at"),
                "first_snapshot": False,
                "types": ["error"],
                "changes": [],
                "source": "detector",
                "ts": int(time.time())
            })
            trigger_types.add("error")
            bump_error(fingerprint_key)

    events_payload.extend(new_events)
    event_type_list = list(trigger_types) or ["error"]
    priority_value = resolve_priority(fingerprint_key, event_type_list)
    if priority_value <= 0:
        if fingerprint_key == "internal":
            skip_internal_count += 1
        else:
            skip_external_count += 1
    else:
        target_queue = queue_updates_internal if fingerprint_key == "internal" else queue_updates_external
        send_set = send_internal_uids if fingerprint_key == "internal" else send_external_uids
        send_set.add(uid_str)
        target_queue.append({
            "uid": uid_str,
            "is_location_only": is_location_only,
            "priority": priority_value
        })

    hashes[uid_str] = {
        "hash": fp,
        "timestamp": new_ts,
        "campus_id": campus_id,
        "fingerprint_key": fingerprint_key,
        "snapshot": current_snapshot
    }
    fp_changes += 1

internal_ids = apply_priority_queue(existing_internal, queue_updates_internal)
external_ids = apply_priority_queue(existing_external, queue_updates_external)

internal_set = set(internal_ids)
external_ids = [uid for uid in external_ids if uid not in internal_set]

drop_candidates = {item["uid"] for item in queue_updates_external if item["is_location_only"]}
internal_reached = len(internal_ids) >= backlog_nint_threshold
external_reached = len(external_ids) >= backlog_next_threshold
if external_reached and drop_candidates:
    new_external = []
    for uid in external_ids:
        if uid in drop_candidates:
            dropped_ids.append(uid)
            continue
        new_external.append(uid)
    external_ids = new_external

write_queue(internal_queue, internal_ids)
write_queue(external_queue, external_ids)

if dropped_ids:
    with open(dropped_ext_file, "a") as f:
        for uid in dropped_ids:
            f.write(f"{uid}\n")

level_state = load_json(level_file, {"int": 0, "ext": 0}) or {"int": 0, "ext": 0}
warns = []
if len(internal_ids) >= backlog_nint_threshold:
    if not level_state.get("int"):
        warns.append("Nint_backlog")
    level_state["int"] = 1
else:
    level_state["int"] = 0

if len(external_ids) >= backlog_next_threshold:
    if not level_state.get("ext"):
        warns.append("Next_backlog")
    level_state["ext"] = 1
else:
    level_state["ext"] = 0

write_json(level_file, level_state)

if events_payload:
    lock_path = os.environ["EVENTS_QUEUE_LOCK"]
    queue_path = os.environ["EVENTS_QUEUE"]
    with open(lock_path, "w") as lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX)
        except Exception:
            pass
        with open(queue_path, "a") as eq:
            for event in events_payload:
                eq.write(json.dumps(event) + "\n")

def count_pair(name):
    data = event_counts.get(name, {"int": 0, "ext": 0})
    return data.get("int", 0), data.get("ext", 0)


conn_int, conn_ext = count_pair("connection")
disc_int, disc_ext = count_pair("deconnection")
wallet_int, wallet_ext = count_pair("wallet")
corr_int, corr_ext = count_pair("correction")
eval_int, eval_ext = count_pair("evaluation")
data_int, data_ext = count_pair("data")
new_int, new_ext = count_pair("new_seen")
err_int = error_counts.get("int", 0)
err_ext = error_counts.get("ext", 0)

result = {
    "detect": len(users),
    "fp": fp_changes,
    "int": len(changed_internal),
    "ext": len(changed_external),
    "skip_internal": skip_internal_count,
    "skip_external": skip_external_count,
    "send_internal": len(send_internal_uids),
    "send_external": len(send_external_uids),
    "qint": len(internal_ids),
    "qext": len(external_ids),
    "drop": len(dropped_ids),
    "warn": "+".join(warns),
    "events": len(events_payload),
    "events_connection_int": conn_int,
    "events_connection_ext": conn_ext,
    "events_deconnection_int": disc_int,
    "events_deconnection_ext": disc_ext,
    "events_wallet_int": wallet_int,
    "events_wallet_ext": wallet_ext,
    "events_correction_int": corr_int,
    "events_correction_ext": corr_ext,
    "events_evaluation_int": eval_int,
    "events_evaluation_ext": eval_ext,
    "events_data_int": data_int,
    "events_data_ext": data_ext,
    "events_new_seen_int": new_int,
    "events_new_seen_ext": new_ext,
    "events_error_int": err_int,
    "events_error_ext": err_ext
}

write_json(hash_file, hashes)
print(json.dumps(result))
PYTHON_DETECTOR
)
status=$?

flock -u 5
flock -u 4
exec 5>&-
exec 4>&-
rm -f "$tmp_json"

if [[ $status -ne 0 || -z "$PY_OUT" ]]; then
  echo "[${LOG_TIMESTAMP}] [pid=${PID}] ERROR: detector python block failed" >> "$LOG_FILE"
  exit 1
fi

DETECT_COUNT=$(echo "$PY_OUT" | jq -r '.detect // 0')
FP_COUNT=$(echo "$PY_OUT" | jq -r '.fp // 0')
EVENTS_COUNT=$(echo "$PY_OUT" | jq -r '.events // 0')
SKIP_INT=$(echo "$PY_OUT" | jq -r '.skip_internal // 0')
SKIP_EXT=$(echo "$PY_OUT" | jq -r '.skip_external // 0')
SEND_INT=$(echo "$PY_OUT" | jq -r '.send_internal // 0')
SEND_EXT=$(echo "$PY_OUT" | jq -r '.send_external // 0')
EVT_CONN_INT=$(echo "$PY_OUT" | jq -r '.events_connection_int // 0')
EVT_CONN_EXT=$(echo "$PY_OUT" | jq -r '.events_connection_ext // 0')
EVT_DISC_INT=$(echo "$PY_OUT" | jq -r '.events_deconnection_int // 0')
EVT_DISC_EXT=$(echo "$PY_OUT" | jq -r '.events_deconnection_ext // 0')
EVT_WALLET_INT=$(echo "$PY_OUT" | jq -r '.events_wallet_int // 0')
EVT_WALLET_EXT=$(echo "$PY_OUT" | jq -r '.events_wallet_ext // 0')
EVT_CORR_INT=$(echo "$PY_OUT" | jq -r '.events_correction_int // 0')
EVT_CORR_EXT=$(echo "$PY_OUT" | jq -r '.events_correction_ext // 0')
EVT_EVAL_INT=$(echo "$PY_OUT" | jq -r '.events_evaluation_int // 0')
EVT_EVAL_EXT=$(echo "$PY_OUT" | jq -r '.events_evaluation_ext // 0')
EVT_DATA_INT=$(echo "$PY_OUT" | jq -r '.events_data_int // 0')
EVT_DATA_EXT=$(echo "$PY_OUT" | jq -r '.events_data_ext // 0')
EVT_NEW_INT=$(echo "$PY_OUT" | jq -r '.events_new_seen_int // 0')
EVT_NEW_EXT=$(echo "$PY_OUT" | jq -r '.events_new_seen_ext // 0')
EVT_ERR_INT=$(echo "$PY_OUT" | jq -r '.events_error_int // 0')
EVT_ERR_EXT=$(echo "$PY_OUT" | jq -r '.events_error_ext // 0')
WARN_VAL=$(echo "$PY_OUT" | jq -r '.warn // ""')

log_line="[${LOG_TIMESTAMP}] [pid=${PID}] detect=${DETECT_COUNT} fp=${FP_COUNT} events=${EVENTS_COUNT}"
log_line+=" send=(${SEND_INT}/${SEND_EXT}) skip=(${SKIP_INT}/${SKIP_EXT})"
log_line+=" disconnection=(${EVT_DISC_INT}/${EVT_DISC_EXT}) connection=(${EVT_CONN_INT}/${EVT_CONN_EXT})"
log_line+=" wallet=(${EVT_WALLET_INT}/${EVT_WALLET_EXT}) correction=(${EVT_CORR_INT}/${EVT_CORR_EXT})"
log_line+=" evaluation=(${EVT_EVAL_INT}/${EVT_EVAL_EXT}) data=(${EVT_DATA_INT}/${EVT_DATA_EXT})"
log_line+=" new_seen=(${EVT_NEW_INT}/${EVT_NEW_EXT}) error=(${EVT_ERR_INT}/${EVT_ERR_EXT})"
if [[ -n "$WARN_VAL" && "$WARN_VAL" != "null" ]]; then
  log_line+=" WARN=${WARN_VAL}"
fi

echo "$log_line" >> "$LOG_FILE"
