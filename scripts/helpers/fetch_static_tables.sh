#!/usr/bin/env bash
set -euo pipefail

# Fetch static/reference tables: achievements, campuses, cursus, projects.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Fetching achievements..."
"$SCRIPT_DIR/helpers/fetch_all_achievements.sh" --force

echo "Fetching campuses..."
"$SCRIPT_DIR/helpers/fetch_all_campuses.sh" --force

echo "Fetching cursus..."
"$SCRIPT_DIR/helpers/fetch_all_cursus.sh" --force

echo "Fetching projects..."
"$SCRIPT_DIR/helpers/fetch_all_projects.sh" --force

echo "Static tables refreshed."
