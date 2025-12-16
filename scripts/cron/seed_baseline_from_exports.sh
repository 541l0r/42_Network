#!/usr/bin/env bash
set -euo pipefail

# seed_baseline_from_exports.sh - Build/refresh eventifier baselines from current exports
# Copies each exports/09_users/campus_*/user_<id>.json into logs/.eventifier_baseline/user_<id>.json
# Existing baselines are overwritten to align with current exports.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORTS_DIR="$ROOT_DIR/exports/09_users"
BASELINE_DIR="$ROOT_DIR/logs/.eventifier_baseline"

mkdir -p "$BASELINE_DIR"

export ROOT_DIR EXPORTS_DIR BASELINE_DIR

python3 - << 'PY'
import json, os, glob, pathlib

root = os.environ["ROOT_DIR"]
exports_dir = os.environ["EXPORTS_DIR"]
baseline_dir = os.environ["BASELINE_DIR"]

paths = glob.glob(os.path.join(exports_dir, "campus_*", "user_*.json"))
written = 0
errors = 0

for path in paths:
    try:
        data = json.load(open(path))
    except Exception as e:
        errors += 1
        print(f"⚠️  skip {path}: {e}")
        continue
    uid = data.get("id")
    if uid is None:
        errors += 1
        print(f"⚠️  skip {path}: missing id")
        continue
    baseline_path = os.path.join(baseline_dir, f"user_{uid}.json")
    try:
        pathlib.Path(baseline_path).write_text(json.dumps(data, indent=2))
        written += 1
    except Exception as e:
        errors += 1
        print(f"⚠️  write failed {baseline_path}: {e}")

print(f"Seeded baselines: {written} files (errors={errors}) from {len(paths)} exports")
PY
