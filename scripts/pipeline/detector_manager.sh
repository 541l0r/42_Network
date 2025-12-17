#!/usr/bin/env bash
#
# detector_manager.sh - manage the periodic change detector
# Usage:
#   scripts/pipeline/detector_manager.sh start   # launch in background
#   scripts/pipeline/detector_manager.sh stop    # stop if running
#   scripts/pipeline/detector_manager.sh status  # show status
#   scripts/pipeline/detector_manager.sh restart # stop then start

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
PID_FILE="$LOG_DIR/detector.pid"
AGENTS_CONFIG="$ROOT_DIR/scripts/config/agents.config"
DETECT_SCRIPT="$ROOT_DIR/scripts/agents/detector.sh"

mkdir -p "$LOG_DIR"

# Read interval from env or agents.config
DETECTOR_INTERVAL="${DETECTOR_INTERVAL:-}"
if [[ -z "$DETECTOR_INTERVAL" && -f "$AGENTS_CONFIG" ]]; then
  DETECTOR_INTERVAL=$(grep -E '^\s*DETECTOR_INTERVAL=' "$AGENTS_CONFIG" | head -1 | cut -d= -f2 | tr -d '"')
fi
DETECTOR_INTERVAL="${DETECTOR_INTERVAL:-120}"

is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && ps -p "$pid" -o pid= >/dev/null 2>&1
}

read_pid() {
  [[ -f "$PID_FILE" ]] && cat "$PID_FILE"
}

start_detector() {
  local pid
  pid=$(read_pid || true)
  if is_running "$pid"; then
    echo "Detector already running (pid: $pid)"
    exit 0
  fi

  if [[ ! -x "$DETECT_SCRIPT" ]]; then
    echo "Detect script not found or not executable: $DETECT_SCRIPT"
    exit 1
  fi

  # Run in background, looping every DETECTOR_INTERVAL seconds
  nohup bash -c "cd '$ROOT_DIR'; while true; do bash '$DETECT_SCRIPT'; sleep '$DETECTOR_INTERVAL'; done" \
    >>"$LOG_DIR/detect_changes.log" 2>&1 &
  pid=$!
  echo "$pid" > "$PID_FILE"
  echo "Detector started (pid: $pid, interval: ${DETECTOR_INTERVAL}s)"
  echo "Log: $LOG_DIR/detect_changes.log"
}

stop_detector() {
  local pid
  pid=$(read_pid || true)
  if is_running "$pid"; then
    kill "$pid"
    rm -f "$PID_FILE"
    echo "Detector stopped (pid: $pid)"
  else
    rm -f "$PID_FILE"
    echo "Detector not running"
  fi
}

status_detector() {
  local pid
  pid=$(read_pid || true)
  if is_running "$pid"; then
    echo "Detector running (pid: $pid, interval: ${DETECTOR_INTERVAL}s)"
  else
    echo "Detector not running"
  fi
}

case "${1:-}" in
  start)   start_detector ;;
  stop)    stop_detector ;;
  restart) stop_detector; start_detector ;;
  status|stat|st) status_detector ;;
  *)
    echo "Usage: $0 {start|stop|status|stat|st|restart}"
    exit 1
    ;;
esac
