#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts"

usage() {
  cat <<EOF
Usage: CAMPUS_ID=76 bash scripts/orchestrate/deploy_orchestra.sh [options]

Options:
  --dry-run          Run the orchestra worker without saving data
  --skip-monitor     Skip launching the user/ pipeline monitors
  --skip-workers     Skip the campus worker run (fetch+load)
  --help             Show this usage message

Environment:
  CAMPUS_ID                    Campus to sync when workers run (default: 76)
  ORCHESTRA_DB_BOOTSTRAP_MODE  fresh | empty | restore (from .env)
  ORCHESTRA_DB_RESTORE_PATH    Path to SQL dump when mode=restore
EOF
  exit 1
}

DRY_RUN=0
SKIP_MONITOR=0
SKIP_WORKER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --skip-monitor) SKIP_MONITOR=1 ;;
    --skip-workers) SKIP_WORKER=1 ;;
    --help) usage ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
  shift
done

LOG_FILE="$ROOT_DIR/logs/deploy_orchestra_$(date +%s).log"
mkdir -p "$ROOT_DIR/logs"

log() {
  local level="$1"
  shift
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [$level] $*" | tee -a "$LOG_FILE"
}

run_step() {
  log INFO "└─ $*"
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

log INFO "══════════════════════════════════════════════════════════"
log INFO "42 Network orchestra launcher"
log INFO "  Campus ID: ${CAMPUS_ID:-76}"
log INFO "  Dry run: ${DRY_RUN}"
log INFO "  Log file: $LOG_FILE"

export CAMPUS_ID="${CAMPUS_ID:-76}"

# Step 0: ensure Docker stack is running
log INFO "Starting docker-compose services (transcendence_db + helpers)"
run_step docker compose -f "$ROOT_DIR/docker-compose.yml" up -d

# Step 1: environment validation
run_step bash "$SCRIPTS_DIR/orchestrate/check_environment.sh"

# Step 2: initialize database schema
run_step bash "$SCRIPTS_DIR/orchestrate/init_db.sh"

# Step 3: detector & monitors
if [[ $SKIP_MONITOR -eq 0 ]]; then
  run_step bash "$SCRIPTS_DIR/monitoring/live_delta_monitor.sh" 45 --compact
  run_step bash "$SCRIPTS_DIR/monitoring/pipeline_monitor.sh"
else
  log INFO "Monitors skipped (--skip-monitor)"
fi

# Step 4: run campus worker (fetch + load + metadata/bootstrap via orchestra)
if [[ $SKIP_WORKER -eq 0 ]]; then
  ORCHESTRA_CMD=(bash "$SCRIPTS_DIR/orchestrate/orchestra.sh")
  [[ $DRY_RUN -eq 1 ]] && ORCHESTRA_CMD+=(--dry-run)
  run_step "${ORCHESTRA_CMD[@]}"
else
  log INFO "Worker run skipped (--skip-workers)"
fi

log INFO "══════════════════════════════════════════════════════════"
log INFO "Orchestra deploy sequence complete"
log INFO "Logs written to $LOG_FILE"
