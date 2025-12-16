#!/bin/bash

# Add these shortcuts to your .bashrc or run directly
# cd /srv/42_Network/repo && source scripts/monitor_shortcuts.sh

ROOT_DIR="/srv/42_Network/repo"

# Quick monitoring shortcuts
alias mon='cd "$ROOT_DIR" && bash scripts/monitor_bottleneck.sh status'
alias mon-detect='cd "$ROOT_DIR" && bash scripts/monitor_bottleneck.sh tail-detect 30'
alias mon-fetch='cd "$ROOT_DIR" && bash scripts/monitor_bottleneck.sh tail-fetch 30'
alias mon-all='cd "$ROOT_DIR" && bash scripts/monitor_bottleneck.sh tail-all 15'
alias mon-errors='cd "$ROOT_DIR" && bash scripts/monitor_bottleneck.sh errors'
alias mon-watch='cd "$ROOT_DIR" && bash scripts/monitor_bottleneck.sh watch 3'
alias mon-archive='cd "$ROOT_DIR" && bash scripts/monitor_bottleneck.sh archive'

# Queue status shortcut
alias queue='echo "Fetch queue: $(wc -l < '"$ROOT_DIR"'/.backlog/fetch_queue.txt) | Process queue: $(wc -l < '"$ROOT_DIR"'/.backlog/process_queue.txt)"'

echo "✓ Monitoring aliases loaded:"
echo "  mon                 - Status overview"
echo "  mon-detect 30       - Last 30 detector lines"
echo "  mon-fetch 30        - Last 30 fetcher lines"
echo "  mon-all 15          - Last 15 from all logs"
echo "  mon-errors          - Show errors only"
echo "  mon-watch           - Live monitoring (Ctrl+C to exit)"
echo "  mon-archive         - Archive status"
echo "  queue               - Quick queue check"
