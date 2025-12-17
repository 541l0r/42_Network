import os
import json
import hashlib
import hmac
import glob
from datetime import datetime

ROOT = os.environ.get("ROOT_DIR", "/srv/42_Network/repo")
BACKLOG = os.path.join(ROOT, ".backlog")
BASELINE_DIR = os.path.join(ROOT, ".eventifier_baseline")
EVENTS_LOG = os.path.join(BACKLOG, "events_logs.jsonl")
USERS_LATEST = os.path.join(ROOT, ".cache/raw_detect/users_latest.json")
CONFIG_FILE = os.path.join(ROOT, "scripts/config/detector_fields.json")

# Load config
with open(CONFIG_FILE) as f:
    config = json.load(f)
internal_fields = config.get("internals", {}).get("fields", [])
external_fields = config.get("externals", {}).get("fields", [])
if not external_fields:
    external_fields = internal_fields
hmac_keys = config.get("hmac_keys", {})
hmac_key_internal = hmac_keys.get("internal", "42network_internal_detection")
hmac_key_external = hmac_keys.get("external", "42network_external_detection")

# Load latest users
with open(USERS_LATEST) as f:
    users = json.load(f)

def fingerprint(user, fields, hmac_key):
    filtered = {}
    for k in fields:
        if k not in user:
            continue
        v = user.get(k)
        if k == "location":
            filtered[k] = 0 if v in (None, "") else 1
        else:
            filtered[k] = v
    payload = json.dumps(filtered, sort_keys=True, separators=(",", ":"))
    signature = hmac.new(hmac_key.encode(), payload.encode(), hashlib.sha256).hexdigest()
    return signature

def get_campus_id(user):
    campus_users = user.get("campus_users", [])
    if campus_users and isinstance(campus_users, list):
        for cu in campus_users:
            if isinstance(cu, dict) and cu.get("is_primary"):
                return cu.get("campus_id")
        if campus_users:
            return campus_users[0].get("campus_id")
    campus_list = user.get("campus", [])
    if campus_list and isinstance(campus_list, list):
        return campus_list[0].get("id")
    return None

def to_number(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None

def load_baseline(user, campus_id):
    uid = user.get("id")
    if uid is None:
        return None
    path = None
    if campus_id is not None:
        path = os.path.join(BASELINE_DIR, f"campus_{campus_id}", f"user_{uid}.json")
    if not path or not os.path.isfile(path):
        matches = glob.glob(os.path.join(BASELINE_DIR, "campus_*", f"user_{uid}.json"))
        path = matches[0] if matches else None
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return None

def get_updated_timestamp(user):
    updated = user.get("updated_at")
    if not updated:
        return None
    try:
        updated_dt = datetime.fromisoformat(updated.replace('Z', '+00:00'))
        return int(updated_dt.timestamp())
    except Exception:
        return None

def detect_events_and_changes(user, baseline):
    changes = []
    events = []
    if not baseline:
        return events, changes
    for field in baseline.keys():
        if field in user and baseline[field] != user[field]:
            changes.append({"field": field, "old": baseline[field], "new": user[field]})
            if field == "location":
                events.append("connection")
            elif field == "wallet":
                events.append("wallet")
            elif field == "correction_point":
                events.append("correction")
            elif field in ("login", "first_name", "last_name"):
                events.append("name_change")
    return events, changes

with open(EVENTS_LOG, "a") as evlog:
    for u in users:
        if u.get("label") == "error":
            continue
        uid = u.get("id")
        if uid is None:
            continue
        campus_id_raw = get_campus_id(u)
        try:
            campus_id = int(campus_id_raw) if campus_id_raw is not None else None
        except Exception:
            campus_id = campus_id_raw
        fingerprint_key = "internal" if campus_id == 21 else "external"
        if fingerprint_key == "internal":
            fingerprint_fields = internal_fields
            hmac_key = hmac_key_internal
        else:
            fingerprint_fields = external_fields
            hmac_key = hmac_key_external
        fp = fingerprint(u, fingerprint_fields, hmac_key)
        baseline = load_baseline(u, campus_id)
        if baseline:
            last_fp = fingerprint(baseline, fingerprint_fields, hmac_key)
        else:
            last_fp = None
        if fp != last_fp:
            events, changes = detect_events_and_changes(u, baseline)
            if events or changes:
                event_obj = {
                    "user_id": uid,
                    "user_login": u.get("login"),
                    "campus_id": campus_id,
                    "updated_at": u.get("updated_at"),
                    "events": events,
                    "changes": changes,
                    "internal_external": fingerprint_key,
                    "ts": get_updated_timestamp(u)
                }
                evlog.write(json.dumps(event_obj, separators=(',', ':')) + "\n")
