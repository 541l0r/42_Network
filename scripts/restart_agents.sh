#!/usr/bin/env bash
# Restart all agents (detector, fetcher, upserter, backlog worker)
# Options:
#   --clear-logs       Truncate *.log files in logs/
#   --clear-queues     Truncate .backlog queues (events_queue, fetch_queue, process_queue, events_pending)
#   --renew-baseline   Reseed eventifier baselines from exports (seed_baseline_from_exports.sh)
#   --help             Show usage

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
BACKLOG_DIR="$ROOT_DIR/.backlog"
PIPELINE="$ROOT_DIR/scripts/pipeline_manager.sh"
BACKLOG_WORKER="$ROOT_DIR/scripts/backlog_worker_manager.sh"
SEED_BASELINE="$ROOT_DIR/scripts/cron/seed_baseline_from_exports.sh"

CLEAR_LOGS=0
CLEAR_QUEUES=0
RENEW_BASELINE=0

usage() {
  cat <<'EOF'
Usage: scripts/restart_agents.sh [--clear-logs] [--clear-queues] [--renew-baseline]

Restarts pipeline (detector, fetcher, upserter) and backlog worker.
Options:
  --clear-logs       Truncate log files in logs/*.log
  --clear-queues     Truncate .backlog queues (events_queue, fetch_queue, process_queue, events_pending)
  --renew-baseline   Reseed eventifier baselines from exports
  --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clear-logs) CLEAR_LOGS=1; shift ;;
    --clear-queues) CLEAR_QUEUES=1; shift ;;
    --renew-baseline) RENEW_BASELINE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

log() { echo "[restart] $*"; }

log "Stopping pipeline..."
bash "$PIPELINE" stop || true
log "Stopping backlog worker..."
bash "$BACKLOG_WORKER" stop || true

if [[ $CLEAR_QUEUES -eq 1 ]]; then
  log "Clearing backlog queues..."
  : > "$BACKLOG_DIR/events_queue.jsonl"
  : > "$BACKLOG_DIR/fetch_queue.txt"
  : > "$BACKLOG_DIR/process_queue.txt"
  : > "$BACKLOG_DIR/events_pending.txt"
fi

if [[ $CLEAR_LOGS -eq 1 ]]; then
  log "Truncating logs/*.log ..."
  mkdir -p "$LOG_DIR"
  find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' -print0 | while IFS= read -r -d '' f; do
    : > "$f"
  done
fi

if [[ $RENEW_BASELINE -eq 1 ]]; then
  log "Reseeding eventifier baselines from exports..."
  bash "$SEED_BASELINE"
fi

log "Starting pipeline..."
bash "$PIPELINE" start
log "Starting backlog worker..."
bash "$BACKLOG_WORKER" start

log "Done."
