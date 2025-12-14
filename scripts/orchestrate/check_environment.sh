#!/bin/bash
# ============================================================================ #
#  check_environment.sh - Simplified pre-deployment check
#
#  Quick validation: Docker running? DB accessible? Token valid?
#
#  Usage: bash scripts/orchestrate/check_environment.sh
#
# ============================================================================ #

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARENT_DIR="$(cd "$ROOT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

ISSUES=0

log_check() {
  printf "%-40s " "$1"
}

log_pass() {
  echo -e "${GREEN}✅${NC}"
}

log_fail() {
  echo -e "${RED}❌${NC} $1"
  ((ISSUES++))
}

log_info() {
  echo -e "${BLUE}ℹ️  $1${NC}"
}

# ============================================================================ #

echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Transcendence Environment Check${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

# 1. Docker daemon
log_check "Docker daemon"
if ! timeout 5 docker ps >/dev/null 2>&1; then
  log_fail "Not running"
  exit 1
fi
log_pass

# 2. docker-compose
log_check "docker-compose"
if ! docker compose version >/dev/null 2>&1; then
  log_fail "Not available"
  exit 1
fi
log_pass

# 3. Exports directory writable
log_check "Exports directory"
mkdir -p "$ROOT_DIR/exports/09_users" 2>/dev/null
if ! touch "$ROOT_DIR/exports/.write_test" 2>/dev/null; then
  log_fail "Not writable"
else
  rm -f "$ROOT_DIR/exports/.write_test"
  log_pass
fi

# 4. Repo structure
log_check "Repo structure"
if [[ ! -f "$ROOT_DIR/docker-compose.yml" ]] || [[ ! -d "$ROOT_DIR/scripts" ]]; then
  log_fail "Missing files"
  exit 1
fi
log_pass

# 5. Token
log_check "OAuth token (.env)"
env_file="$PARENT_DIR/.env"
if [[ ! -f "$env_file" ]]; then
  log_fail "Not found at $PARENT_DIR/.env"
  exit 1
fi
if ! grep -q "REFRESH_TOKEN=" "$env_file"; then
  log_fail "REFRESH_TOKEN not in .env"
  exit 1
fi
log_pass

# 6. Database
log_check "Database container"
if timeout 5 docker ps --format "{{.Names}}" 2>/dev/null | grep -q "transcendence_db"; then
  log_pass
  log_info "Running"
  
  log_check "Database connectivity"
  if timeout 5 docker exec transcendence_db psql -U api42 -d api42 -c "SELECT 1" >/dev/null 2>&1; then
    log_pass
  else
    log_fail "Cannot connect"
  fi
else
  log_pass
  log_info "Not running (will start during deploy)"
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"

if [[ $ISSUES -eq 0 ]]; then
  echo -e "${GREEN}✅ READY FOR DEPLOYMENT${NC}"
  echo ""
  exit 0
else
  echo -e "${RED}❌ $ISSUES ISSUE(S)${NC}"
  exit 1
fi
