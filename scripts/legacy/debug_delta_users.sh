#!/bin/bash

# Debug script to test delta_users_stage creation

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_CONFIG="$ROOT_DIR/scripts/config/agents.config"

get_conf_val() {
  local key="$1"
  [[ -f "$AGENTS_CONFIG" ]] || return
  grep -E "^\s*${key}=" "$AGENTS_CONFIG" | head -1 | cut -d= -f2 | tr -d '"'
}

DB_HOST_CFG=$(get_conf_val "DB_HOST" || true)
DB_PORT_CFG=$(get_conf_val "DB_PORT" || true)
DB_USER_CFG=$(get_conf_val "DB_USER" || true)
DB_NAME_CFG=$(get_conf_val "DB_NAME" || true)
DB_PASSWORD_CFG=$(get_conf_val "DB_PASSWORD" || true)

DB_HOST="${DB_HOST:-$DB_HOST_CFG}"
DB_PORT="${DB_PORT:-$DB_PORT_CFG}"
DB_USER="${DB_USER:-$DB_USER_CFG}"
DB_NAME="${DB_NAME:-$DB_NAME_CFG}"
DB_PASSWORD="${DB_PASSWORD:-$DB_PASSWORD_CFG}"

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-api42}"
DB_NAME="${DB_NAME:-api42}"
DB_PASSWORD="${DB_PASSWORD:-api42}"

echo "[1] Testing delta_users table existence..."
/usr/bin/docker compose exec -T db psql -U "$DB_USER" -d "$DB_NAME" -c "\d delta_users" 2>&1 | head -20

echo ""
echo "[2] Testing delta_users_stage creation..."
timeout 10 /usr/bin/docker compose exec -T db psql -U "$DB_USER" -d "$DB_NAME" \
    -c "CREATE TABLE IF NOT EXISTS delta_users_stage (LIKE delta_users INCLUDING DEFAULTS); TRUNCATE delta_users_stage;" 2>&1

if [ $? -eq 124 ]; then
  echo "ERROR: Command timed out after 10 seconds!"
else
  echo "Success!"
fi

echo ""
echo "[3] Checking if delta_users_stage exists..."
/usr/bin/docker compose exec -T db psql -U "$DB_USER" -d "$DB_NAME" -c "\d delta_users_stage" 2>&1 | head -20
