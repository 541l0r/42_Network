#!/usr/bin/env bash
set -euo pipefail

# Live Delta Monitor - Track real-time user changes in time window

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
STATE_DIR="$LOG_DIR/.monitor_state"

mkdir -p "$STATE_DIR"

WINDOW_SECONDS="${1:-30}"
COMPACT_MODE=0

[[ "${2:-}" == "--compact" ]] && COMPACT_MODE=1

CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $COMPACT_MODE -eq 1 ]]; then
  echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  LIVE DELTA MONITOR - REAL-TIME USER CHANGE TRACKING  ║${NC}"
  echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
  echo ""
  
  echo -e "  Time Window: ${YELLOW}${WINDOW_SECONDS}s${NC}"
  echo ""
  
  echo -e "  Users Changed: ${GREEN}●${NC} ${MAGENTA}(checking logs...)${NC}"
  
  if [[ -f "$LOG_DIR/live_db_sync.log" ]]; then
    echo -e ""
    echo -e "  ${BLUE}Recent Activity:${NC}"
    tail -2 "$LOG_DIR/live_db_sync.log" 2>/dev/null | sed 's/^/    /' || echo "    (no activity yet)"
  fi
else
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  LIVE DELTA MONITOR - REAL-TIME USER CHANGES${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""
  
  echo -e "  ${BLUE}Window:${NC} ${YELLOW}${WINDOW_SECONDS}${NC} seconds"
  echo -e "  ${BLUE}Current Time:${NC} $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo ""
  
  echo -e "  ${BLUE}🔄 Users Changed:${NC}"
  echo -e "    ${YELLOW}○${NC} Monitoring for changes (check live_db_sync.log)"
  echo ""
  
  echo -e "  ${BLUE}📝 Last Sync Activity:${NC}"
  if [[ -f "$LOG_DIR/live_db_sync.log" ]]; then
    tail -3 "$LOG_DIR/live_db_sync.log" 2>/dev/null | sed 's/^/    /' || echo "    (no previous syncs)"
  else
    echo "    (no previous syncs)"
  fi
  
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
fi
