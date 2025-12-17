#!/bin/bash

# Pipeline manager - Start/stop all 3 stages
# Usage: pipeline_manager.sh {start|stop|status|restart}

set -euo pipefail

	ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	LOG_DIR="$ROOT_DIR/logs"
	PID_DIR="$LOG_DIR/pids"

mkdir -p "$PID_DIR"

	DETECTOR_PID_FILE="$PID_DIR/detector.pid"
	FETCHER_PID_FILE="$PID_DIR/fetcher.pid"
	UPSERTER_PID_FILE="$PID_DIR/upserter.pid"
	UPSERTER_SCRIPT="$ROOT_DIR/scripts/agents/upserter.sh"
	UPSERTER_LOG="$LOG_DIR/upserter.log"

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
	  nohup bash "$ROOT_DIR/scripts/pipeline/detector_manager.sh" start >/dev/null 2>&1 &
	  sleep 1
	  DETECTOR_PID=$(read_pid "$ROOT_DIR/logs/detector.pid" 2>/dev/null || echo "")
	  if [[ -n "$DETECTOR_PID" ]] && is_running "$DETECTOR_PID"; then
	    echo "   ✓ Detector (PID: $DETECTOR_PID)"
	  fi
	  
	  # Start fetcher
	  echo "2. Starting fetcher (API fetch with 4s rate limit)..."
	  nohup bash "$ROOT_DIR/scripts/agents/fetcher.sh" >>"$LOG_DIR/fetcher.log" 2>&1 &
	  FETCHER_PID=$!
	  echo "$FETCHER_PID" > "$FETCHER_PID_FILE"
	  sleep 1
	  if is_running "$FETCHER_PID"; then
	    echo "   ✓ Fetcher (PID: $FETCHER_PID)"
	  fi

	  # Start upserter (single)
	  echo "3. Starting upserter (batch DB inserts)..."
	  nohup bash "$UPSERTER_SCRIPT" >>"$UPSERTER_LOG" 2>&1 &
	  UPSERTER_PID=$!
	  echo "$UPSERTER_PID" > "$UPSERTER_PID_FILE"
	  sleep 1
	  if is_running "$UPSERTER_PID"; then
	    echo "   ✓ Upserter (PID: $UPSERTER_PID)"
	  fi
  
  echo ""
	  echo "✅ Pipeline started!"
	  echo ""
	  echo "Architecture:"
	  echo "  Detector → fetch_queue → Fetcher → process_queue → Upserter"
	  echo "           ↘ events_queue.jsonl (detector emits app events)"
	  echo ""
	  echo "Logs:"
	  echo "  • Detector:   $LOG_DIR/detect_changes.log"
	  echo "  • Fetcher:    $LOG_DIR/fetcher.log"
	  echo "  • Upserter:   $UPSERTER_LOG"
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
  
  # Stop upserter (single)
  UPSERTER_PID=$(read_pid "$UPSERTER_PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$UPSERTER_PID" ]] && is_running "$UPSERTER_PID"; then
    kill "$UPSERTER_PID" 2>/dev/null || true
    echo "✓ Stopped upserter (PID: $UPSERTER_PID)"
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
    echo "✓ Upserter (PID: $UPSERTER_PID)"
  else
    echo "✗ Upserter (not running)"
  fi
  
	  echo ""
	  
	  # Queue status
	  FETCH_QUEUE_INT=$(wc -l < "$ROOT_DIR/.backlog/fetch_queue_internal.txt" 2>/dev/null || echo "0")
	  FETCH_QUEUE_EXT=$(wc -l < "$ROOT_DIR/.backlog/fetch_queue_external.txt" 2>/dev/null || echo "0")
	  PROCESS_QUEUE_SIZE=$(wc -l < "$ROOT_DIR/.backlog/process_queue.txt" 2>/dev/null || echo "0")
	  EVENTS_QUEUE_SIZE=$(wc -l < "$ROOT_DIR/.backlog/events_queue.jsonl" 2>/dev/null || echo "0")
	  
	  echo "Queues:"
	  echo "  • fetch_queue_internal: $FETCH_QUEUE_INT users"
	  echo "  • fetch_queue_external: $FETCH_QUEUE_EXT users"
	  echo "  • process_queue: $PROCESS_QUEUE_SIZE users"
	  echo "  • events_queue: $EVENTS_QUEUE_SIZE events"
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
