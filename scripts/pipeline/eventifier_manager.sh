#!/usr/bin/env bash
#
# eventifier_manager.sh - manage the periodic eventifier
# Usage:
#   scripts/pipeline/eventifier_manager.sh start   # launch in background
#   scripts/pipeline/eventifier_manager.sh stop    # stop if running
#   scripts/pipeline/eventifier_manager.sh status  # show status
#   scripts/pipeline/eventifier_manager.sh restart # stop then start

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
PID_FILE="$LOG_DIR/eventifier.pid"
AGENTS_CONFIG="$ROOT_DIR/scripts/config/agents.config"
EVENTIFY_SCRIPT="$ROOT_DIR/scripts/cron/eventifier.sh"
LOG_FILE="$LOG_DIR/eventifier.log"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# Read interval from env or agents.config (seconds).
EVENTIFIER_INTERVAL="${EVENTIFIER_INTERVAL:-}"
if [[ -z "$EVENTIFIER_INTERVAL" && -f "$AGENTS_CONFIG" ]]; then
  EVENTIFIER_INTERVAL=$(grep -E '^\s*EVENTIFIER_INTERVAL=' "$AGENTS_CONFIG" | head -1 | cut -d= -f2 | tr -d '"' | xargs || true)
fi
EVENTIFIER_INTERVAL="${EVENTIFIER_INTERVAL:-30}"

is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && ps -p "$pid" -o pid= >/dev/null 2>&1
}

read_pid() {
  [[ -f "$PID_FILE" ]] && cat "$PID_FILE"
}

start_eventifier() {
  local pid
  pid=$(read_pid || true)
  if is_running "$pid"; then
    echo "Eventifier already running (pid: $pid)"
    exit 0
  fi

  if [[ ! -x "$EVENTIFY_SCRIPT" ]]; then
    echo "Eventifier script not found or not executable: $EVENTIFY_SCRIPT"
    exit 1
  fi

  nohup bash -c "cd '$ROOT_DIR'; while true; do bash '$EVENTIFY_SCRIPT'; sleep '$EVENTIFIER_INTERVAL'; done" \
    >>"$LOG_FILE" 2>&1 &
  pid=$!
  echo "$pid" > "$PID_FILE"
  echo "Eventifier started (pid: $pid, interval: ${EVENTIFIER_INTERVAL}s)"
  echo "Log: $LOG_FILE"
}

stop_eventifier() {
  local pid
  pid=$(read_pid || true)
  if is_running "$pid"; then
    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "Eventifier stopped (pid: $pid)"
  else
    rm -f "$PID_FILE"
    echo "Eventifier not running"
  fi
}

status_eventifier() {
  local pid
  pid=$(read_pid || true)
  if is_running "$pid"; then
    echo "Eventifier running (pid: $pid, interval: ${EVENTIFIER_INTERVAL}s)"
  else
    echo "Eventifier not running"
  fi
}

case "${1:-}" in
  start)   start_eventifier ;;
  stop)    stop_eventifier ;;
  restart) stop_eventifier; start_eventifier ;;
  status|stat|st) status_eventifier ;;
  *)
    echo "Usage: $0 {start|stop|status|stat|st|restart}"
    exit 1
    ;;
esac

