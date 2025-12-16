#!/usr/bin/env python3
"""
Quick classifier for eventifier output.

It reads .backlog/events_queue.jsonl (or a provided path) and labels each entry
according to the user-facing event types we care about:
- connection / disconnection / wallet (internals only, campus == CAMPUS_ID)
- correction (cp delta > 0) / evaluation (cp delta < 0)
- project changes (which project slots) + retry hints (retriable_at changes)
- achievements touched
- stable identity fields (login / first_name / last_name)
It also surfaces any remaining paths as "other" so we can spot mismatches.

This is read-only; it never mutates queues or baselines.
"""

import argparse
from datetime import datetime, timezone
import json
import os
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

DEFAULT_QUEUE = ".backlog/events_queue.jsonl"


def to_number(value: Any) -> Optional[float]:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def load_events(path: str) -> Iterable[Dict[str, Any]]:
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


IGNORE_SUFFIXES = (
    "updated_at",
    "created_at",
    "marked_at",
    "anonymize_date",
    "data_erasure_date",
)


def is_ignore_path(path: str) -> bool:
    return path.endswith(IGNORE_SUFFIXES)


def classify_event(event: Dict[str, Any], internal_campus_id: int) -> Dict[str, Any]:
    campus_id = event.get("campus_id")
    changes = event.get("changes", [])

    connection: Optional[Tuple[str, Any, Any]] = None
    wallet: Optional[Tuple[float, float, float]] = None
    cp_change: Optional[Tuple[float, float, float]] = None
    achievements: Dict[str, Dict[str, Any]] = {}
    projects: Dict[str, Dict[str, Any]] = {}
    data_changes: List[Tuple[str, Any, Any]] = []
    retry_projects: Set[str] = set()
    project_status: Dict[str, Tuple[Any, Any]] = {}
    other_paths: Set[str] = set()
    unknown_changes: List[Dict[str, Any]] = []
    ignored_changes: List[Dict[str, Any]] = []
    external_location_change = False
    external_wallet_change = False

    for change in changes:
        path = change.get("path")
        old = change.get("old")
        new = change.get("new")
        if not path:
            continue
        if path.startswith("coalitions"):
            continue
        if is_ignore_path(path):
            ignored_changes.append({"path": path, "old": old, "new": new})
            continue

        # Location events.
        if path.endswith("location"):
            if campus_id == internal_campus_id:
                if connection is None or path == "location":
                    connection = (path, old, new)
            else:
                external_location_change = True
            continue

        # Wallet events.
        if path.endswith("wallet"):
            if campus_id == internal_campus_id:
                old_n = to_number(old)
                new_n = to_number(new)
                if old_n is not None and new_n is not None:
                    wallet = (old_n, new_n, new_n - old_n)
                else:
                    other_paths.add(path)
                    unknown_changes.append({"path": path, "old": old, "new": new})
            else:
                external_wallet_change = True
            continue

        # Correction / evaluation.
        if path.endswith("correction_point"):
            old_n = to_number(old)
            new_n = to_number(new)
            if old_n is not None and new_n is not None:
                cp_change = (old_n, new_n, new_n - old_n)
            else:
                other_paths.add(path)
                unknown_changes.append({"path": path, "old": old, "new": new})
            continue

        # Achievements.
        if path.startswith("achievements["):
            idx = path.split("]")[0].split("[", 1)[1]
            bucket = achievements.setdefault(idx, {})
            field = path.split("].", 1)[1] if "]." in path else path
            bucket[field] = {"old": old, "new": new}
            continue

        # Projects.
        if path.startswith("projects_users["):
            idx = path.split("]")[0].split("[", 1)[1]
            bucket = projects.setdefault(idx, {})
            field = path.split("].", 1)[1] if "]." in path else path
            bucket[field] = {"old": old, "new": new}
            if field == "retriable_at":
                retry_projects.add(idx)
            if field == "status":
                project_status[idx] = (old, new)
            continue

        leaf = path.split(".")[-1]
        if leaf in ("login", "first_name", "last_name"):
            data_changes.append((leaf, old, new))
            continue

        other_paths.add(path)
        unknown_changes.append({"path": path, "old": old, "new": new})

    labels: List[str] = []
    if event.get("first_snapshot") and not changes:
        labels.append("baseline_only")

    if connection:
        _, old, new = connection
        if old is None and new not in (None, ""):
            labels.append(f"connection -> {new}")
        elif old not in (None, "") and new is None:
            labels.append(f"disconnection from {old}")
        else:
            labels.append("location_change")

    if wallet:
        old, new, delta = wallet
        labels.append(f"wallet {old:.0f}->{new:.0f} (Δ {delta:+.0f})")

    if cp_change:
        old, new, delta = cp_change
        if delta > 0:
            labels.append(f"correction (cp {old:.0f}->{new:.0f}, Δ {delta:+.0f})")
        elif delta < 0:
            labels.append(f"evaluation (cp {old:.0f}->{new:.0f}, Δ {delta:+.0f})")
        else:
            labels.append("cp unchanged")

    if projects:
        labels.append(f"projects[{len(projects)}]")
    if achievements:
        labels.append(f"achievements[{len(achievements)}]")
    if data_changes:
        fields = sorted({f for f, _, _ in data_changes})
        labels.append(f"data fields: {', '.join(fields)}")

    # Only surface external wallet/location noise if nothing else classified.
    has_primary_label = bool(labels)
    if external_location_change and not has_primary_label:
        labels.append("error: external location change")
    if external_wallet_change and not has_primary_label:
        labels.append("error: external wallet change")

    return {
        "labels": labels,
        "other_paths": sorted(other_paths),
        "projects": projects,
        "achievements": achievements,
        "data_changes": data_changes,
        "unknown_changes": unknown_changes,
        "ignored_changes": ignored_changes,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Classify eventifier JSONL entries into user-facing event types."
    )
    parser.add_argument(
        "--queue",
        default=DEFAULT_QUEUE,
        help=f"Path to events_queue.jsonl (default: {DEFAULT_QUEUE})",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Max entries to show (0 = all).",
    )
    parser.add_argument(
        "--unknown-only",
        action="store_true",
        help="Only show events that still have other/unclassified paths.",
    )
    parser.add_argument(
        "--campus",
        type=int,
        default=None,
        help="Override internal campus id (defaults to CAMPUS_ID env or 21).",
    )
    args = parser.parse_args()

    internal_campus_id = (
        args.campus
        if args.campus is not None
        else int(os.environ.get("CAMPUS_ID", os.environ.get("INTERNAL_CAMPUS_ID", 21)))
    )

    shown = 0
    for idx, event in enumerate(load_events(args.queue), start=1):
        classification = classify_event(event, internal_campus_id)
        labels = classification["labels"]
        if args.unknown_only:
            if labels:
                continue
        shown += 1
        if args.limit and shown > args.limit:
            break

        labels = labels or ["(no labels)"]
        ts_value = event.get("ts")
        ts_human = "-"
        if isinstance(ts_value, (int, float)):
            ts_human = datetime.fromtimestamp(ts_value, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
        user_name = event.get('user_login') or event.get('user_name') or '-'
        print(
            f"[{str(idx).zfill(2)}] user={event.get('user_id')} user_name={user_name} "
            f"campus={event.get('campus_id')} [{', '.join(labels)}] ts={ts_human}"
        )
        if labels == ["(no labels)"]:
            if classification.get("unknown_changes"):
                print("  unclassified changes:")
                for ch in classification["unknown_changes"]:
                    print(f"    - {ch['path']}: {ch['old']} -> {ch['new']}")
            elif classification.get("ignored_changes"):
                print("  changes (ignored by detector):")
                for ch in classification["ignored_changes"]:
                    print(f"    - {ch['path']}: {ch['old']} -> {ch['new']}")
        print()


if __name__ == "__main__":
    main()
