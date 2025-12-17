#!/bin/bash

# monitor_bottleneck.sh - Real-time bottleneck monitoring tool
# Shows live detector and fetcher activity for load testing

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
BACKLOG_DIR="$ROOT_DIR/.backlog"

COMMAND="${1:-status}"

case "$COMMAND" in
  status)
    echo "=== BOTTLENECK STATUS ($(date -u +'%Y-%m-%d %H:%M:%S UTC')) ==="
    echo ""
    
    # Queue status with paths
    FETCH_QUEUE=$(wc -l < "$BACKLOG_DIR/fetch_queue.txt" 2>/dev/null || echo 0)
    PROCESS_QUEUE=$(wc -l < "$BACKLOG_DIR/process_queue.txt" 2>/dev/null || echo 0)
    echo "📊 QUEUES:"
    echo "  🔄 Detector → fetch_queue: $FETCH_QUEUE users"
    echo "     Path: $BACKLOG_DIR/fetch_queue.txt"
    echo "  🔄 Fetcher → process_queue: $PROCESS_QUEUE users"
    echo "     Path: $BACKLOG_DIR/process_queue.txt"
    echo ""
    
    # Recent detection activity
    echo "🔍 DETECTOR (last 3 cycles):"
    grep "Found" "$LOG_DIR/detect_changes.log" 2>/dev/null | tail -3 | sed 's/^/  /'
    echo "   Log: $LOG_DIR/detect_changes.log"
    echo ""
    
    # Recent fetcher activity
    echo "⚙️  FETCHER (last 5 fetches):"
    grep "✓ Fetched" "$LOG_DIR/fetcher.log" 2>/dev/null | tail -5 | sed 's/^/  /'
    echo "   Log: $LOG_DIR/fetcher.log"
    echo ""
    
    # Process activity
    echo "📤 UPSERTERS (last 3 upserts):"
    grep "✓ Upserted" "$LOG_DIR/upserter.log" 2>/dev/null | tail -3 | sed 's/^/  /'
    echo "   Log: $LOG_DIR/upserter.log"
    ;;
    
  tail-detect)
    LINES="${2:-20}"
    echo "=== DETECTOR (tail -$LINES) ==="
    tail -n "$LINES" "$LOG_DIR/detect_changes.log"
    ;;
    
  tail-fetch)
    LINES="${2:-20}"
    echo "=== FETCHER (tail -$LINES) ==="
    tail -n "$LINES" "$LOG_DIR/fetcher.log"
    ;;
    
  tail-upsert)
    LINES="${2:-20}"
    echo "=== UPSERTER (tail -$LINES) ==="
    tail -n "$LINES" "$LOG_DIR/upserter.log"
    ;;
    
  tail-all)
    LINES="${2:-10}"
    echo "=== DETECTOR (last $LINES lines) ==="
    tail -n "$LINES" "$LOG_DIR/detect_changes.log"
    echo ""
    echo "=== FETCHER (last $LINES lines) ==="
    tail -n "$LINES" "$LOG_DIR/fetcher.log"
    echo ""
    echo "=== UPSERTER (last $LINES lines) ==="
    tail -n "$LINES" "$LOG_DIR/upserter.log"
    ;;
    
  errors)
    echo "=== FETCHER ERRORS ==="
    grep -E "ERROR|✗|429|403" "$LOG_DIR/fetcher.log" 2>/dev/null || echo "No errors found"
    echo ""
    echo "=== UPSERTER ERRORS ==="
    grep -E "ERROR|✗|timeout" "$LOG_DIR/upserter.log" 2>/dev/null || echo "No errors found"
    ;;
    
  archive)
    echo "=== ARCHIVE STATUS (last 10) ==="
    ARCHIVE_DIR="$BACKLOG_DIR/archive"
    ls -lht "$ARCHIVE_DIR"/*.log 2>/dev/null | head -10 | awk '{printf "  %s (%s)\n", $9, $5}'
    echo ""
    echo "Total archives: $(ls "$ARCHIVE_DIR"/*.log 2>/dev/null | wc -l)"
    ;;
    
  watch)
    # Continuous monitoring
    INTERVAL="${2:-5}"
    clear
    while true; do
      clear
      date
      echo "=== LIVE MONITORING (refresh every ${INTERVAL}s) ==="
      echo ""
      
      FETCH_QUEUE=$(wc -l < "$BACKLOG_DIR/fetch_queue.txt" 2>/dev/null || echo 0)
      PROCESS_QUEUE=$(wc -l < "$BACKLOG_DIR/process_queue.txt" 2>/dev/null || echo 0)
      
      printf "📊 Queues: fetch=%4d  process=%4d\n" "$FETCH_QUEUE" "$PROCESS_QUEUE"
      echo ""
      
      echo "Last detector cycle:"
      tail -1 "$LOG_DIR/detect_changes.log" | sed 's/^/  /'
      echo ""
      
      echo "Last 3 fetcher ops:"
      tail -3 "$LOG_DIR/fetcher.log" | sed 's/^/  /'
      echo ""
      
      echo "Press Ctrl+C to exit"
      sleep "$INTERVAL"
    done
    ;;
    
  *)
    cat << 'EOF'
Usage: monitor_bottleneck.sh [command] [args]

Commands:
  status              Show current queue and last activity (default)
  tail-detect [N]     Show last N lines from detector log (default: 20)
  tail-fetch [N]      Show last N lines from fetcher log (default: 20)
  tail-upsert [N]     Show last N lines from upserter log (default: 20)
  tail-all [N]        Show last N lines from all bottleneck logs (default: 10)
  errors              Show only errors from fetcher and upserter
  archive             Show archive status and recent backups
  watch [SEC]         Live monitoring with refresh interval (default: 5s)

Examples:
  ./monitor_bottleneck.sh status
  ./monitor_bottleneck.sh tail-fetch 50
  ./monitor_bottleneck.sh watch 3
  ./monitor_bottleneck.sh errors
EOF
    ;;
esac
