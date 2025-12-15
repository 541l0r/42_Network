#!/bin/bash

# Pipeline manager - Start/stop all 3 stages
# Usage: pipeline_manager.sh {start|stop|status|restart}

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
PID_DIR="$LOG_DIR/pids"

mkdir -p "$PID_DIR"

DETECTOR_PID_FILE="$PID_DIR/detector.pid"
FETCHER_PID_FILE="$PID_DIR/fetcher.pid"
UPSERTER_PID_FILE="$PID_DIR/upserter.pid"
UPSERTER2_PID_FILE="$PID_DIR/upserter2.pid"

is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && ps -p "$pid" -o pid= >/dev/null 2>&1
}

read_pid() {
  local file="$1"
  [[ -f "$file" ]] && cat "$file"
}

start_pipeline() {
  echo "Starting 3-stage pipeline..."
  echo ""
  
  # Start detector
  echo "1. Starting detector..."
  nohup bash "$ROOT_DIR/scripts/detector_manager.sh" start >/dev/null 2>&1 &
  sleep 1
  DETECTOR_PID=$(read_pid "$ROOT_DIR/logs/detector.pid" 2>/dev/null || echo "")
  if [[ -n "$DETECTOR_PID" ]] && is_running "$DETECTOR_PID"; then
    echo "   ✓ Detector (PID: $DETECTOR_PID)"
  fi
  
  # Start fetcher
  echo "2. Starting fetcher (API fetch with 4s rate limit)..."
  nohup bash "$ROOT_DIR/scripts/fetcher.sh" >>"$LOG_DIR/fetcher.log" 2>&1 &
  FETCHER_PID=$!
  echo "$FETCHER_PID" > "$FETCHER_PID_FILE"
  sleep 1
  if is_running "$FETCHER_PID"; then
    echo "   ✓ Fetcher (PID: $FETCHER_PID)"
  fi
  
  # Start upserter
  echo "3. Starting upserter (batch DB inserts)..."
  nohup bash "$ROOT_DIR/scripts/upserter.sh" >>"$LOG_DIR/upserter.log" 2>&1 &
  UPSERTER_PID=$!
  echo "$UPSERTER_PID" > "$UPSERTER_PID_FILE"
  sleep 1
  if is_running "$UPSERTER_PID"; then
    echo "   ✓ Upserter 1 (PID: $UPSERTER_PID)"
  fi
  
  # Start upserter 2
  echo "4. Starting upserter 2 (batch DB inserts)..."
  nohup bash "$ROOT_DIR/scripts/upserter2.sh" >>"$LOG_DIR/upserter2.log" 2>&1 &
  UPSERTER2_PID=$!
  echo "$UPSERTER2_PID" > "$UPSERTER2_PID_FILE"
  sleep 1
  if is_running "$UPSERTER2_PID"; then
    echo "   ✓ Upserter 2 (PID: $UPSERTER2_PID)"
  fi
  
  echo ""
  echo "✅ Pipeline started!"
  echo ""
  echo "Architecture:"
  echo "  Detector → fetch_queue → Fetcher → process_queue → [Upserter 1 + Upserter 2]"
  echo ""
  echo "Logs:"
  echo "  • Detector:   $LOG_DIR/detect_changes.log"
  echo "  • Fetcher:    $LOG_DIR/fetcher.log"
  echo "  • Upserter 1: $LOG_DIR/upserter.log"
  echo "  • Upserter 2: $LOG_DIR/upserter2.log"
}

stop_pipeline() {
  echo "Stopping pipeline..."
  
  # Stop detector
  DETECTOR_PID=$(read_pid "$ROOT_DIR/logs/detector.pid" 2>/dev/null || echo "")
  if [[ -n "$DETECTOR_PID" ]] && is_running "$DETECTOR_PID"; then
    kill "$DETECTOR_PID" 2>/dev/null || true
    echo "✓ Stopped detector (PID: $DETECTOR_PID)"
  fi
  
  # Stop fetcher
  FETCHER_PID=$(read_pid "$FETCHER_PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$FETCHER_PID" ]] && is_running "$FETCHER_PID"; then
    kill "$FETCHER_PID" 2>/dev/null || true
    echo "✓ Stopped fetcher (PID: $FETCHER_PID)"
  fi
  
  # Stop upserter
  UPSERTER_PID=$(read_pid "$UPSERTER_PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$UPSERTER_PID" ]] && is_running "$UPSERTER_PID"; then
    kill "$UPSERTER_PID" 2>/dev/null || true
    echo "✓ Stopped upserter 1 (PID: $UPSERTER_PID)"
  fi
  
  # Stop upserter 2
  UPSERTER2_PID=$(read_pid "$UPSERTER2_PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$UPSERTER2_PID" ]] && is_running "$UPSERTER2_PID"; then
    kill "$UPSERTER2_PID" 2>/dev/null || true
    echo "✓ Stopped upserter 2 (PID: $UPSERTER2_PID)"
  fi
  
  echo "✅ Pipeline stopped"
}

status_pipeline() {
  echo "Pipeline Status:"
  echo ""
  
  # Detector
  DETECTOR_PID=$(read_pid "$ROOT_DIR/logs/detector.pid" 2>/dev/null || echo "")
  if [[ -n "$DETECTOR_PID" ]] && is_running "$DETECTOR_PID"; then
    echo "✓ Detector (PID: $DETECTOR_PID)"
  else
    echo "✗ Detector (not running)"
  fi
  
  # Fetcher
  FETCHER_PID=$(read_pid "$FETCHER_PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$FETCHER_PID" ]] && is_running "$FETCHER_PID"; then
    echo "✓ Fetcher (PID: $FETCHER_PID)"
  else
    echo "✗ Fetcher (not running)"
  fi
  
  # Upserter
  UPSERTER_PID=$(read_pid "$UPSERTER_PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$UPSERTER_PID" ]] && is_running "$UPSERTER_PID"; then
    echo "✓ Upserter 1 (PID: $UPSERTER_PID)"
  else
    echo "✗ Upserter 1 (not running)"
  fi
  
  # Upserter 2
  UPSERTER2_PID=$(read_pid "$UPSERTER2_PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$UPSERTER2_PID" ]] && is_running "$UPSERTER2_PID"; then
    echo "✓ Upserter 2 (PID: $UPSERTER2_PID)"
  else
    echo "✗ Upserter 2 (not running)"
  fi
  
  echo ""
  
  # Queue status
  FETCH_QUEUE_SIZE=$(wc -l < "$ROOT_DIR/.backlog/fetch_queue.txt" 2>/dev/null || echo "0")
  PROCESS_QUEUE_SIZE=$(wc -l < "$ROOT_DIR/.backlog/process_queue.txt" 2>/dev/null || echo "0")
  
  echo "Queues:"
  echo "  • fetch_queue:   $FETCH_QUEUE_SIZE users"
  echo "  • process_queue: $PROCESS_QUEUE_SIZE users"
}

case "${1:-}" in
  start)   start_pipeline ;;
  stop)    stop_pipeline ;;
  status|stat|st) status_pipeline ;;
  restart) stop_pipeline; sleep 2; start_pipeline ;;
  *)
    echo "Usage: $0 {start|stop|status|stat|st|restart}"
    exit 1
    ;;
esac
