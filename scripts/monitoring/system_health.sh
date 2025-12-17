#!/usr/bin/env bash
set -euo pipefail

# system_health.sh - quick operational snapshot for pipeline + infra
# Shows: docker (transcendence), disk usage, API42 reachability, agent PIDs,
# queues, and last log signals.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
PID_DIR="$LOG_DIR/pids"
BACKLOG_DIR="$ROOT_DIR/.backlog"
API_BASE="${API_BASE:-https://api.intra.42.fr}"

section() {
  echo ""
  echo "=== $1 ==="
}

safe_tail() {
  local file="$1"
  local lines="${2:-1}"
  [[ -f "$file" ]] && tail -n "$lines" "$file" || echo "(missing: $file)"
}

section "Timestamp"
echo "UTC now: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"

section "Docker (transcendence containers)"
if command -v docker >/dev/null 2>&1; then
  if timeout 5 docker ps --format '{{.Names}}|{{.Status}}|{{.Ports}}' | grep -i 'transcendence' >/tmp/health_docker.$$ 2>/dev/null; then
    if [[ -s /tmp/health_docker.$$ ]]; then
      while IFS='|' read -r name status ports; do
        echo "- $name :: $status :: ${ports:-no ports}"
      done < /tmp/health_docker.$$
    else
      echo "No transcendence containers running."
    fi
  else
    echo "Docker reachable but no matching containers (timeout/empty)."
  fi
  rm -f /tmp/health_docker.$$ 2>/dev/null || true
else
  echo "Docker not installed/accessible."
fi

section "Disk usage"
# Report root filesystem usage (percentage + free MB)
df -P -k / | awk 'NR==2 {gsub("%","",$5); printf("/ used=%s%% free=%d MB mount=%s\n", $5, $4/1024, $6)}'

section "API42 status"
# Prefer tokened check if .oauth_state exists, fallback to public endpoint
ACCESS_TOKEN=""
if [[ -f "$ROOT_DIR/.oauth_state" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT_DIR/.oauth_state"
fi
if [[ -n "${ACCESS_TOKEN:-}" ]]; then
  read -r code duration <<<"$(curl -s -o /dev/null -w '%{http_code} %{time_total}' -H "Authorization: Bearer $ACCESS_TOKEN" "${API_BASE%/}/v2/me")"
  echo "Authenticated /v2/me -> code=$code time=${duration}s"
else
  read -r code duration <<<"$(curl -s -o /dev/null -w '%{http_code} %{time_total}' "${API_BASE%/}/oauth/authorize")"
  echo "Unauthenticated /oauth/authorize -> code=$code time=${duration}s"
fi

section "Agents (pid files)"
check_pid() {
  local name="$1" pid_file="$2"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$pid" && -e "/proc/$pid" ]]; then
      local cmd
      cmd=$(tr -s ' ' <<<"$(ps -p "$pid" -o cmd= 2>/dev/null)")
      echo "- $name: RUNNING (pid=$pid) cmd=${cmd:-unknown}"
    else
      echo "- $name: stale or not running (pid file present: $pid_file)"
    fi
  else
    echo "- $name: no pid file ($pid_file)"
  fi
}

check_pid "detector" "$LOG_DIR/detector.pid"
check_pid "fetcher" "$PID_DIR/fetcher.pid"
check_pid "upserter" "$PID_DIR/upserter.pid"

section "Process flow overview"
fetch_q_int="$BACKLOG_DIR/fetch_queue_internal.txt"
fetch_q_ext="$BACKLOG_DIR/fetch_queue_external.txt"
process_q="$BACKLOG_DIR/process_queue.txt"
echo "- fetch_queue_internal: $(wc -l < "${fetch_q_int}" 2>/dev/null || echo 0) entries (${fetch_q_int})"
echo "- fetch_queue_external: $(wc -l < "${fetch_q_ext}" 2>/dev/null || echo 0) entries (${fetch_q_ext})"
echo "- process_queue: $(wc -l < "${process_q}" 2>/dev/null || echo 0) entries (${process_q})"

echo ""
echo "Last detector run:"
safe_tail "$LOG_DIR/detect_changes.log" 1

echo ""
echo "Last fetcher log:"
safe_tail "$LOG_DIR/fetcher.log" 1

echo ""
echo "Last upserter log:"
safe_tail "$LOG_DIR/upserter.log" 1

section "Suggested extra KPIs"
echo "- DB availability (psql select 1) and replication lag if any"
echo "- API token TTL (from .oauth_state EXPIRES_AT)"
echo "- Backlog growth trend (fetch/process queue deltas)"
echo "- Detector fingerprint rate (fingerprinted/changed from last N log lines)"
echo "- Docker resource usage (cpu/mem) for transcendence services"
