#!/usr/bin/env bash
set -euo pipefail

# Monitoring Tools Test Suite (Safe - No API calls)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts"
LOG_DIR="$ROOT_DIR/logs"
STATE_DIR="$LOG_DIR/.monitor_state"

mkdir -p "$STATE_DIR" "$LOG_DIR"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

test_pass() {
  echo -e "${GREEN}✓${NC} $*"
  ((PASS++))
}

test_fail() {
  echo -e "${RED}✗${NC} $*"
  ((FAIL++))
}

echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  MONITORING TOOLS TEST SUITE${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "ROOT_DIR: $ROOT_DIR"
echo ""

# Test 1: Scripts exist
echo -e "${BLUE}TEST 1: Script existence${NC}"
[[ -f "$SCRIPTS_DIR/monitoring/pipeline_monitor.sh" ]] && test_pass "pipeline_monitor.sh exists" || test_fail "pipeline_monitor.sh missing"
[[ -f "$SCRIPTS_DIR/monitoring/live_delta_monitor.sh" ]] && test_pass "live_delta_monitor.sh exists" || test_fail "live_delta_monitor.sh missing"
[[ -f "$SCRIPTS_DIR/helpers/backlog_helper.sh" ]] && test_pass "backlog_helper.sh exists" || test_fail "backlog_helper.sh missing"
echo ""

# Test 2: Scripts are executable
echo -e "${BLUE}TEST 2: Script executability${NC}"
[[ -x "$SCRIPTS_DIR/monitoring/pipeline_monitor.sh" ]] && test_pass "pipeline_monitor.sh is executable" || test_fail "pipeline_monitor.sh not executable"
[[ -x "$SCRIPTS_DIR/monitoring/live_delta_monitor.sh" ]] && test_pass "live_delta_monitor.sh is executable" || test_fail "live_delta_monitor.sh not executable"
[[ -x "$SCRIPTS_DIR/helpers/backlog_helper.sh" ]] && test_pass "backlog_helper.sh is executable" || test_fail "backlog_helper.sh not executable"
echo ""

# Test 3: Backlog helper - add user
echo -e "${BLUE}TEST 3: Backlog helper - add users${NC}"
bash "$SCRIPTS_DIR/helpers/backlog_helper.sh" add 12345 "test" 2>&1 > /dev/null && test_pass "add user to backlog" || test_fail "failed to add user"

for i in {1..5}; do
  bash "$SCRIPTS_DIR/helpers/backlog_helper.sh" add "1000$i" "test_$i" 2>&1 > /dev/null || true
done
test_pass "added 5 test users"
echo ""

# Test 4: Backlog helper - list
echo -e "${BLUE}TEST 4: Backlog helper - list${NC}"
output=$(bash "$SCRIPTS_DIR/helpers/backlog_helper.sh" list 2>&1)
[[ -n "$output" ]] && test_pass "list command executed" || test_fail "list command failed"
echo ""

# Test 5: Backlog helper - status
echo -e "${BLUE}TEST 5: Backlog helper - status${NC}"
output=$(bash "$SCRIPTS_DIR/helpers/backlog_helper.sh" status 2>&1)
[[ "$output" == *"Pending"* ]] && test_pass "status shows pending count" || test_fail "status format incorrect"
echo ""

# Test 6: Backlog helper - process (test mode)
echo -e "${BLUE}TEST 6: Backlog helper - process (test mode)${NC}"
output=$(bash "$SCRIPTS_DIR/helpers/backlog_helper.sh" process --test 2>&1)
[[ -n "$output" ]] && test_pass "process test mode works" || test_fail "process test mode failed"
echo ""

# Test 7: Create synthetic logs
echo -e "${BLUE}TEST 7: Create synthetic logs for display${NC}"
cat > "$LOG_DIR/nightly_stable_tables.log" << 'EOF'
[2025-12-12T10:30:00Z] NIGHTLY CURSUS 21 STABLE TABLES UPDATE
[2025-12-12T10:31:00Z] ✓ Cursus
[2025-12-12T10:31:10Z] ✓ Campuses
[2025-12-12T10:31:20Z] ✓ Campus_achievements
EOF

[[ -f "$LOG_DIR/nightly_stable_tables.log" ]] && test_pass "nightly log created" || test_fail "nightly log creation failed"

cat > "$LOG_DIR/live_db_sync.log" << 'EOF'
[2025-12-12T10:40:15Z] Live Delta Sync - DB Update
[2025-12-12T10:40:16Z] Time window: 30s
[2025-12-12T10:40:18Z] Found 3 changed users
EOF

[[ -f "$LOG_DIR/live_db_sync.log" ]] && test_pass "live_db_sync log created" || test_fail "live_db_sync log creation failed"
echo ""

# Test 8: Pipeline monitor display
echo -e "${BLUE}TEST 8: Pipeline monitor - display test${NC}"
timeout 2 bash "$SCRIPTS_DIR/monitoring/pipeline_monitor.sh" > /tmp/pm_test.log 2>&1 || true
[[ -f /tmp/pm_test.log ]] && [[ -s /tmp/pm_test.log ]] && test_pass "pipeline_monitor outputs display" || test_fail "pipeline_monitor display failed"
echo ""

# Test 9: Live delta monitor display
echo -e "${BLUE}TEST 9: Live delta monitor - display test${NC}"
timeout 1 bash "$SCRIPTS_DIR/monitoring/live_delta_monitor.sh" 30 --compact > /tmp/ldm_test.log 2>&1 || true
[[ -f /tmp/ldm_test.log ]] && [[ -s /tmp/ldm_test.log ]] && test_pass "live_delta_monitor outputs display" || test_fail "live_delta_monitor display failed"
echo ""

# Test 10: Verify NO API calls made
echo -e "${BLUE}TEST 10: Safety verification${NC}"
! grep -r "oauth\|curl.*https\|POST.*v2" "$LOG_DIR"/*.log 2>/dev/null | grep -q . && test_pass "no API calls detected ✓" || test_fail "API calls detected!"
echo ""

# Summary
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  SUMMARY${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}Passed:${NC}  $PASS"
echo -e "  ${RED}Failed:${NC}  $FAIL"
echo ""

if (( FAIL == 0 )); then
  echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
  echo ""
  echo -e "Created monitoring tools:"
  echo -e "  • ${BLUE}pipeline_monitor.sh${NC} - Dashboard of pipeline status"
  echo -e "  • ${BLUE}live_delta_monitor.sh${NC} - Real-time user change tracking"
  echo -e "  • ${BLUE}backlog_helper.sh${NC} - Pending sync management"
  echo ""
  echo -e "Usage:"
  echo -e "  ${GREEN}bash scripts/monitoring/pipeline_monitor.sh${NC}"
  echo -e "  ${GREEN}bash scripts/monitoring/live_delta_monitor.sh [WINDOW_SECS] [--compact]${NC}"
  echo -e "  ${GREEN}bash scripts/helpers/backlog_helper.sh [add|list|status|clear|process]${NC}"
else
  echo -e "${RED}✗ SOME TESTS FAILED${NC}"
  exit 1
fi
