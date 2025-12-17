#!/usr/bin/env python3
# events_logs_generator.py
# Generate events_logs.jsonl from detector output, splitting by event type, internal/external, and handling new_seen events.

import os
import json
import sys
from datetime import datetime

def load_json(path, default=None):
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except Exception:
        return default

def main():
    # Paths (adjust as needed)

    baseline_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../logs/.eventifier_baseline'))
    detector_json = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../.backlog/detector_hashes.json'))
    # Find the latest users_*.json in .cache/raw_detect
    import glob
    raw_detect_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../.cache/raw_detect'))
    user_files = sorted(glob.glob(os.path.join(raw_detect_dir, 'users_*.json')))
    users_json = user_files[-1] if user_files else None
    output_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../.backlog/events_logs.jsonl'))

    # Load detector hashes and latest users
    hashes = load_json(detector_json, {})
    users = load_json(users_json, []) if users_json else []
    if not users:
        print('No users found.')
        return

    # Only compare these scalar fields (from detector_fields.json)
    detector_fields = [
        'login', 'first_name', 'last_name', 'correction_point', 'wallet', 'location'
    ]

    rejected_moves = []
    with open(output_path, 'w') as out:
        for user in users:
            uid = user.get('id')
            if uid is None:
                continue
            uid_str = str(uid)
            campus_id = None
            # Try to get campus_id from user or hash
            if 'campus_users' in user and user['campus_users']:
                for cu in user['campus_users']:
                    if cu.get('is_primary'):
                        campus_id = cu.get('campus_id')
                        break
                if not campus_id:
                    campus_id = user['campus_users'][0].get('campus_id')
            if not campus_id and 'campus' in user and user['campus']:
                campus_id = user['campus'][0].get('id')
            if not campus_id and uid_str in hashes:
                campus_id = hashes[uid_str].get('campus_id')
            # Baseline path
            baseline_path = os.path.join(baseline_dir, f'user_{uid}.json')
            baseline = load_json(baseline_path, None)
            # Event detection
            events = []
            changes = []
            move_rejected = False
            if not baseline:
                events.append('new_seen')
            else:
                # Only compare detector scalar fields
                loc_old = baseline.get('location')
                loc_new = user.get('location')
                # Filter out location-to-location moves (moves: location1 -> location2)
                if loc_old != loc_new:
                    if loc_old is None and loc_new:
                        changes.append({'field': 'location', 'old': loc_old, 'new': loc_new})
                        events.append('connection')
                    elif loc_old and loc_new is None:
                        changes.append({'field': 'location', 'old': loc_old, 'new': loc_new})
                        events.append('deconnection')
                    elif loc_old and loc_new:
                        # moves (location1 -> location2) are excluded from logs
                        move_rejected = True
                cp_old = baseline.get('correction_point')
                cp_new = user.get('correction_point')
                if cp_old is not None and cp_new is not None and cp_old != cp_new:
                    changes.append({'field': 'correction_point', 'old': cp_old, 'new': cp_new})
                    delta = cp_new - cp_old
                    if delta < 0:
                        events.append('evaluation')
                    elif delta > 0:
                        events.append('correction')
                wallet_old = baseline.get('wallet')
                wallet_new = user.get('wallet')
                if wallet_old != wallet_new:
                    changes.append({'field': 'wallet', 'old': wallet_old, 'new': wallet_new})
                    events.append('wallet')
                for k in ('login', 'first_name', 'last_name'):
                    if baseline.get(k) != user.get(k):
                        changes.append({'field': k, 'old': baseline.get(k), 'new': user.get(k)})
                        events.append('data')
                        break
                # If there are changes but no known event, fallback to 'data' (never empty, never error/unknown_change)
                if not events and changes:
                    events.append('data')
            # Always use the official event list, never emit empty events
            if not events:
                continue  # skip writing this log entry
            # Internal/external
            fingerprint_key = hashes.get(uid_str, {}).get('fingerprint_key', 'unknown')
            # Compose log entry
            log_entry = {
                'user_id': uid,
                'user_login': user.get('login'),
                'campus_id': campus_id,
                'updated_at': user.get('updated_at'),
                'events': events,
                'changes': changes,
                'internal_external': fingerprint_key,
                'ts': int(datetime.utcnow().timestamp())
            }
            out.write(json.dumps(log_entry) + '\n')
            if move_rejected:
                rejected_moves.append(uid)
    # Optionally, log rejected moves to a separate file
    if rejected_moves:
        with open(os.path.abspath(os.path.join(os.path.dirname(__file__), '../../.backlog/rejected_moves.log')), 'w') as rm:
            for uid in rejected_moves:
                rm.write(f"{uid}\n")

if __name__ == '__main__':
    main()
