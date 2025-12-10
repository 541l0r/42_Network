#!/usr/bin/env bash
set -euo pipefail

# Update reference tables using existing update scripts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/../.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../.env"
elif [[ -f "$SCRIPT_DIR/../../.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../../.env"
fi

DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-api42}
DB_USER=${DB_USER:-api42}
DB_PASSWORD=${DB_PASSWORD:-api42}
PSQL_CONN="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export PGPASSWORD="$DB_PASSWORD"

if command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
else
  COMPOSE_CMD=""
fi

psql_inline() {
  if command -v psql >/dev/null 2>&1; then
    psql "$PSQL_CONN" "$@"
  elif [[ -n "$COMPOSE_CMD" ]]; then
    $COMPOSE_CMD exec -T -e PGPASSWORD="$DB_PASSWORD" db psql -h db -U "$DB_USER" -d "$DB_NAME" "$@"
  else
    return 1
  fi
}

table_count() {
  local table="$1"
  psql_inline -Atqc "SELECT count(*) FROM ${table}" 2>/dev/null || echo "?"
}

read_stamp() {
  local stamp_file="$1"
  if [[ -f "$stamp_file" ]]; then
    local stamp human
    stamp=$(cat "$stamp_file")
    if [[ "$stamp" =~ ^[0-9]+$ ]]; then
      human=$(date -u -d "@$stamp" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$stamp")
    else
      human="$stamp"
    fi
    echo "$human"
  else
    echo "n/a"
  fi
}

read_metric_key() {
  local metric_file="$1" key="$2"
  if [[ -f "$metric_file" ]]; then
    local val
    val=$(grep -E "^${key}=" "$metric_file" | tail -1 | cut -d'=' -f2-)
    if [[ -n "$val" ]]; then
      echo "$val"
      return
    fi
  fi
  echo "0"
}

summarize() {
  local label="$1" table="$2" export_file="$3" stamp_file="$4" metric_file="$5" before="$6"
  local after size_kb stamp delta status
  after=$(table_count "$table")
  if [[ "$after" != "?" && "$before" != "?" ]]; then
    delta=$(( after - before ))
  else
    delta="?"
  fi
  if [[ "$delta" == "?" ]]; then
    status="unknown"
  elif [[ "$delta" -eq 0 ]]; then
    status="skipped"
  else
    status="fetched"
  fi
  if [[ -f "$export_file" ]]; then
    size_kb=$(du -k "$export_file" | cut -f1)
  else
    size_kb="?"
  fi
  stamp=$(read_stamp "$stamp_file")
  local dl_kb
  dl_kb=$(read_metric_key "$metric_file" "downloaded_kB")
  printf "  %-12s rows=%s (Δ %s) status=%s downloaded_kB=%s export_kB=%s last_fetch=%s\n" "$label" "$after" "$delta" "$status" "$dl_kb" "$size_kb" "$stamp"
}

run_step() {
  local label="$1" script="$2" table="$3" metric_file="$4" before="$5"
  shift 5
  local log_file
  log_file=$(mktemp "/tmp/update_${label}.XXXXXX.log")
  printf "• %s..." "$label"
  if "$script" "$@" >"$log_file" 2>&1; then
    local after delta status dl_kb
    after=$(table_count "$table")
    if [[ "$after" != "?" && "$before" != "?" ]]; then
      delta=$(( after - before ))
    else
      delta="?"
    fi
    if [[ "$delta" == "?" ]]; then
      status="unknown"
    elif [[ "$delta" -eq 0 ]]; then
      status="skipped"
    else
      status="fetched"
    fi
    dl_kb=$(read_metric_key "$metric_file" "downloaded_kB")
    printf " %s (Δ %s, downloaded_kB=%s)\n" "$status" "$delta" "$dl_kb"
  else
    printf " failed\n"
    echo "---- log (${log_file}) ----"
    cat "$log_file"
    exit 1
  fi
}

# capture counts before updates for deltas
before_achievements=$(table_count achievements)
before_campuses=$(table_count campuses)
before_cursus=$(table_count cursus)
before_projects=$(table_count projects)

run_step "achievements" "$SCRIPT_DIR/update_achievements.sh" "achievements" "$SCRIPT_DIR/../exports/achievements/.last_fetch_stats" "$before_achievements" "$@"
run_step "campuses" "$SCRIPT_DIR/update_campuses.sh" "campuses" "$SCRIPT_DIR/../exports/campus/.last_fetch_stats" "$before_campuses" "$@"
run_step "cursus" "$SCRIPT_DIR/update_cursus.sh" "cursus" "$SCRIPT_DIR/../exports/cursus/.last_fetch_stats" "$before_cursus" "$@"
run_step "projects" "$SCRIPT_DIR/update_projects.sh" "projects" "$SCRIPT_DIR/../exports/projects/.last_fetch_stats" "$before_projects" "$@"

echo "Summary:"
summarize "achievements" "achievements" "$SCRIPT_DIR/../exports/achievements/all.json" "$SCRIPT_DIR/../exports/achievements/.last_updated_at" "$SCRIPT_DIR/../exports/achievements/.last_fetch_stats" "$before_achievements"
summarize "campuses" "campuses" "$SCRIPT_DIR/../exports/campus/all.json" "$SCRIPT_DIR/../exports/campus/.last_fetch_epoch" "$SCRIPT_DIR/../exports/campus/.last_fetch_stats" "$before_campuses"
summarize "cursus" "cursus" "$SCRIPT_DIR/../exports/cursus/all.json" "$SCRIPT_DIR/../exports/cursus/.last_fetch_epoch" "$SCRIPT_DIR/../exports/cursus/.last_fetch_stats" "$before_cursus"
summarize "projects" "projects" "$SCRIPT_DIR/../exports/projects/all.json" "$SCRIPT_DIR/../exports/projects/.last_updated_at" "$SCRIPT_DIR/../exports/projects/.last_fetch_stats" "$before_projects"
echo "Updates complete."
