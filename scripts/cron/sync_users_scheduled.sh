#!/usr/bin/env bash
set -euo pipefail

# Scheduled sync of users table
# Run independently every X hours

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Fetch fresh data
bash "$ROOT_DIR/scripts/helpers/fetch_cursus_21_users_simple.sh"

# Load to DB
bash "$ROOT_DIR/scripts/update_stable_tables/update_users_simple.sh"
