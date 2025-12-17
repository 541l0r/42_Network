#!/usr/bin/env bash
set -euo pipefail

# Pipeline Monitor CLI - Display dashboard of all sync operations

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  42 NETWORK DATA PIPELINE MONITOR${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}Current Time:${NC} $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo ""

echo -e "${BLUE}📊 FETCH STATUS:${NC}"
echo -e "  Cursus metadata .......... (check .last_fetch_epoch)"
echo -e "  Campuses ................ (check .last_fetch_epoch)"
echo -e "  Campus Achievements .... (check .last_fetch_epoch)"
echo -e "  Projects ................ (check .last_fetch_epoch)"
echo ""

echo -e "${BLUE}🗄️  DATABASE STATUS:${NC}"
echo -e "  Ready for data ingestion (docker-compose up required for counts)"
echo ""

if [[ -f "$LOG_DIR/nightly_stable_tables.log" ]]; then
  echo -e "${BLUE}📝 RECENT LOG ACTIVITY:${NC}"
  echo -e "  Nightly Pipeline:"
  tail -5 "$LOG_DIR/nightly_stable_tables.log" 2>/dev/null | sed 's/^/    /' || echo "    (no log)"
fi

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
