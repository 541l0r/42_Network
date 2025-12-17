#!/usr/bin/env bash
# Simple manager for backlog worker
# Usage:
#   scripts/backlog_worker_manager.sh start
#   scripts/backlog_worker_manager.sh stop
#   scripts/backlog_worker_manager.sh status
#   scripts/backlog_worker_manager.sh restart

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="$ROOT_DIR/scripts/agents/backlog_worker_wrapper.sh"
LOG_DIR="$ROOT_DIR/logs"
PID_FILE="$LOG_DIR/backlog_worker.pid"
LOG_FILE="$LOG_DIR/backlog_worker.log"

mkdir -p "$LOG_DIR"

is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && ps -p "$pid" -o pid= >/dev/null 2>&1
}

read_pid() {
  [[ -f "$PID_FILE" ]] && cat "$PID_FILE"
}

start_worker() {
  local pid
  pid=$(read_pid || true)
  if is_running "$pid"; then
    echo "Worker already running (pid: $pid)"
    exit 0
  fi

  nohup bash "$WRAPPER" >>"$LOG_FILE" 2>&1 &
  pid=$!
  echo "$pid" > "$PID_FILE"
  echo "Worker started (pid: $pid)"
  echo "Log: $LOG_FILE"
}

stop_worker() {
  local pid
  pid=$(read_pid || true)
  if is_running "$pid"; then
    kill "$pid"
    rm -f "$PID_FILE"
    echo "Worker stopped (pid: $pid)"
  else
    rm -f "$PID_FILE"
    echo "Worker not running"
  fi
}

status_worker() {
  local pid
  pid=$(read_pid || true)
  if is_running "$pid"; then
    echo "Worker running (pid: $pid)"
  else
    echo "Worker not running"
  fi
}

case "${1:-}" in
  start)   start_worker ;;
  stop)    stop_worker ;;
  restart) stop_worker; start_worker ;;
  status)  status_worker ;;
  stat|st) status_worker ;;
  *)
    echo "Usage: $0 {start|stop|status|stat|st|restart}"
    exit 1
    ;;
esac
