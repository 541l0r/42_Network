#!/bin/bash

# Fix delta_users table columns if missing

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_CONFIG="$ROOT_DIR/scripts/config/agents.config"

get_conf_val() {
  local key="$1"
  [[ -f "$AGENTS_CONFIG" ]] || return
  grep -E "^\s*${key}=" "$AGENTS_CONFIG" | head -1 | cut -d= -f2 | tr -d '"'
}

# Load DB defaults from agents.config, then allow env/.env to override if explicitly set
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

echo "Adding missing columns to delta_users table..."

PGPASSWORD="$DB_PASSWORD" psql --connect-timeout=5 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<EOF
ALTER TABLE IF EXISTS delta_users ADD COLUMN IF NOT EXISTS image_link TEXT;
ALTER TABLE IF EXISTS delta_users ADD COLUMN IF NOT EXISTS image_large TEXT;
ALTER TABLE IF EXISTS delta_users ADD COLUMN IF NOT EXISTS image_medium TEXT;
ALTER TABLE IF EXISTS delta_users ADD COLUMN IF NOT EXISTS image_small TEXT;
ALTER TABLE IF EXISTS delta_users ADD COLUMN IF NOT EXISTS image_micro TEXT;
ALTER TABLE IF EXISTS delta_users ADD COLUMN IF NOT EXISTS url TEXT;

-- Check the table structure
\d delta_users

EOF

echo "Done."
