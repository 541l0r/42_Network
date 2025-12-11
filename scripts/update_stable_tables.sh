#!/usr/bin/env bash
set -euo pipefail

# Run all stable-table updaters in order.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script lives in scripts/, repo root is one level up.
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
RUN_LOG="${RUN_LOG:-$LOG_DIR/update_tables_daily.log}"
UPDATE_LOG_HEADER=${UPDATE_LOG_HEADER:-1}
DEBUG_OUTPUT=0

if [[ "${1:-}" == "--debug" ]]; then
  DEBUG_OUTPUT=1
  shift
fi

if [[ -f "$ROOT_DIR/../.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/../.env"
fi

DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-api42}
DB_USER=${DB_USER:-api42}
DB_PASSWORD=${DB_PASSWORD:-api42}
export PGOPTIONS="${PGOPTIONS:--c client_min_messages=warning}"
PSQL_CONN="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export PGPASSWORD="$DB_PASSWORD"
# Default fetch guard (seconds)
MIN_FETCH_AGE_SECONDS=${MIN_FETCH_AGE_SECONDS:-3600}
export MIN_FETCH_AGE_SECONDS
# Propagate fetch guards to helpers (default 86400s).
MIN_FETCH_AGE_SECONDS=${MIN_FETCH_AGE_SECONDS:-86400}
export MIN_FETCH_AGE_SECONDS

run_psql() {
  if command -v psql >/dev/null 2>&1; then
    psql "$PSQL_CONN" "$@"
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose exec -T -e PGPASSWORD="$DB_PASSWORD" db psql -h db -U "$DB_USER" -d "$DB_NAME" "$@"
  else
    echo "psql is not available locally and docker compose is unavailable." >&2
    return 1
  fi
}

run_started=$(date +%s)

update_cursus="$SCRIPT_DIR/update_stable_tables/update_cursus.sh"
update_campuses="$SCRIPT_DIR/update_stable_tables/update_campuses.sh"
update_campus_achievements="$SCRIPT_DIR/update_stable_tables/update_campus_achievements.sh"
update_projects="$SCRIPT_DIR/update_stable_tables/update_projects.sh"

for file in "$update_cursus" "$update_campuses" "$update_campus_achievements" "$update_projects"; do
  if [[ ! -x "$file" ]]; then
    echo "Updater missing or not executable: $file" >&2
    exit 1
  fi
done

mkdir -p "$LOG_DIR"

if [[ "$UPDATE_LOG_HEADER" -eq 1 ]]; then
  echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") =====" >> "$RUN_LOG"
  echo "" >> "$RUN_LOG"
fi

# Run updaters; silence output unless debug.
if [[ "$DEBUG_OUTPUT" -eq 1 ]]; then
  "$update_cursus" "$@"
  "$update_campuses" "$@"
  "$update_campus_achievements" "$@"
  "$update_projects" "$@"
else
  "$update_cursus" "$@" >/dev/null 2>&1
  "$update_campuses" "$@" >/dev/null 2>&1
  "$update_campus_achievements" "$@" >/dev/null 2>&1
  "$update_projects" "$@" >/dev/null 2>&1
fi

# Fetch size summary (kB) based on raw exports.
kb() {
  [[ -f "$1" ]] && du -k "$1" | cut -f1 || echo 0
}

cursus_kb=$(kb "$ROOT_DIR/exports/01_cursus/all.json")
campus_kb=$(kb "$ROOT_DIR/exports/02_campus/all.json")
campus_ach_kb=$(kb "$ROOT_DIR/exports/04_campus_achievements/raw_all.json")
projects_kb=$(kb "$ROOT_DIR/exports/05_projects/raw_all.json")
total_kb=$(( cursus_kb + campus_kb + campus_ach_kb + projects_kb ))

epoch_to_iso() {
  [[ -f "$1" ]] && ts=$(cat "$1") && date -u -d @"$ts" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "n/a"
}

status_from_epoch() {
  local file="$1"
  [[ -f "$file" ]] || { echo "unknown"; return; }
  local ts
  ts=$(cat "$file" 2>/dev/null || echo 0)
  if (( ts >= run_started )); then
    echo "ran"
  else
    echo "cached"
  fi
}

summary_line() {
  local name rows last status
  name="$1"; rows="$2"; last="$3"; status="$4"
  printf "  %-15s rows=%-8s status=%-7s last_fetch=%s\n" "$name" "$rows" "$status" "$last"
}

cursus_rows=$(run_psql -Atc "SELECT count(*) FROM cursus" 2>/dev/null || echo "n/a")
campus_rows=$(run_psql -Atc "SELECT count(*) FROM campuses" 2>/dev/null || echo "n/a")
ach_rows=$(run_psql -Atc "SELECT count(*) FROM achievements" 2>/dev/null || echo "n/a")
campus_ach_rows=$(run_psql -Atc "SELECT count(*) FROM campus_achievements" 2>/dev/null || echo "n/a")
proj_rows=$(run_psql -Atc "SELECT count(*) FROM projects" 2>/dev/null || echo "n/a")
campus_proj_rows=$(run_psql -Atc "SELECT count(*) FROM campus_projects" 2>/dev/null || echo "n/a")
proj_session_rows=$(run_psql -Atc "SELECT count(*) FROM project_sessions" 2>/dev/null || echo "n/a")

cursus_last="$ROOT_DIR/exports/01_cursus/.last_fetch_epoch"
campus_last="$ROOT_DIR/exports/02_campus/.last_fetch_epoch"
campus_ach_last="$ROOT_DIR/exports/04_campus_achievements/.last_fetch_epoch"
projects_last="$ROOT_DIR/exports/05_projects/.last_fetch_epoch"

status_cursus=$(status_from_epoch "$cursus_last")
status_campus=$(status_from_epoch "$campus_last")
status_campus_ach=$(status_from_epoch "$campus_ach_last")
status_projects=$(status_from_epoch "$projects_last")

metric_val() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || { echo 0; return; }
  awk -F= -v k="$key" '$1==k {print $2}' "$file" | tail -n1
}

hits_cursus=$([[ "$status_cursus" == "ran" ]] && metric_val "$ROOT_DIR/exports/01_cursus/.last_fetch_stats" "pages" || echo 0)
hits_campus=$([[ "$status_campus" == "ran" ]] && metric_val "$ROOT_DIR/exports/02_campus/.last_fetch_stats" "pages" || echo 0)
hits_campus_ach=$([[ "$status_campus_ach" == "ran" ]] && metric_val "$ROOT_DIR/exports/04_campus_achievements/.last_fetch_stats" "pages" || echo 0)
hits_projects=$([[ "$status_projects" == "ran" ]] && metric_val "$ROOT_DIR/exports/05_projects/.last_fetch_stats" "pages" || echo 0)
api_hits=$(( hits_cursus + hits_campus + hits_campus_ach + hits_projects ))

download_cursus=$([[ "$status_cursus" == "ran" ]] && metric_val "$ROOT_DIR/exports/01_cursus/.last_fetch_stats" "downloaded_kB" || echo 0)
download_campus=$([[ "$status_campus" == "ran" ]] && metric_val "$ROOT_DIR/exports/02_campus/.last_fetch_stats" "downloaded_kB" || echo 0)
download_campus_ach=$([[ "$status_campus_ach" == "ran" ]] && metric_val "$ROOT_DIR/exports/04_campus_achievements/.last_fetch_stats" "downloaded_kB" || echo 0)
download_projects=$([[ "$status_projects" == "ran" ]] && metric_val "$ROOT_DIR/exports/05_projects/.last_fetch_stats" "downloaded_kB" || echo 0)
download_total=$(( download_cursus + download_campus + download_campus_ach + download_projects ))

summary_block=$(
  printf "%s\n" "All stable tables updated."
  printf "%s\n" "API hits (pages fetched this run): $api_hits"
  printf "%s\n" "Fetched sizes (kB):"
  printf "%s\n" "full fetch: cursus=${cursus_kb}, campuses=${campus_kb}, campus_achievements=${campus_ach_kb}, projects=${projects_kb}, total=${total_kb}"
  printf "%s\n" "this run:   cursus=${download_cursus}, campuses=${download_campus}, campus_achievements=${download_campus_ach}, projects=${download_projects}, total=${download_total}"
  printf "%s\n" "Summary:"
  summary_line "cursus" "$cursus_rows" "$(epoch_to_iso "$cursus_last")" "$status_cursus"
  summary_line "campuses" "$campus_rows" "$(epoch_to_iso "$campus_last")" "$status_campus"
  summary_line "achievements" "$ach_rows" "$(epoch_to_iso "$campus_ach_last")" "$status_campus_ach"
  summary_line "campus_ach" "$campus_ach_rows" "$(epoch_to_iso "$campus_ach_last")" "$status_campus_ach"
  summary_line "projects" "$proj_rows" "$(epoch_to_iso "$projects_last")" "$status_projects"
  summary_line "campus_projects" "$campus_proj_rows" "$(epoch_to_iso "$projects_last")" "$status_projects"
  summary_line "project_sessions" "$proj_session_rows" "$(epoch_to_iso "$projects_last")" "$status_projects"
)

echo "$summary_block" >> "$RUN_LOG"
echo "" >> "$RUN_LOG"

# Summary to stdout
echo "$summary_block"
