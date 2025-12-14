#!/bin/bash
# ============================================================================ #
#  init_db.sh - Initialize PostgreSQL schema for Transcendence
#  
#  Usage: bash scripts/orchestrate/init_db.sh
#  
#  Purpose:
#    1. Wait for PostgreSQL to be ready
#    2. Load schema from data/schema.sql
#    3. Verify tables created
# ============================================================================ #

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_FILE="$ROOT_DIR/logs/init_db_$(date +%s).log"
mkdir -p "$ROOT_DIR/logs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ============================================================================ #
#  Functions
# ============================================================================ #

log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

wait_for_db() {
  local max_attempts=30
  local attempt=0

  log "🔄 Waiting for PostgreSQL to be ready..."
  
  while [ $attempt -lt $max_attempts ]; do
    if docker exec transcendence_db pg_isready -U api42 >/dev/null 2>&1; then
      log "✅ PostgreSQL is ready"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  
  log "❌ PostgreSQL failed to start after $max_attempts attempts"
  return 1
}

load_schema() {
  local schema_file="$ROOT_DIR/data/schema.sql"
  
  if [ ! -f "$schema_file" ]; then
    log "⚠️  Schema file not found: $schema_file"
    log "   Creating minimal schema..."
    create_minimal_schema
    return
  fi

  log "📋 Loading schema from $schema_file..."
  
  docker exec -i transcendence_db psql -U api42 -d api42 < "$schema_file" >> "$LOG_FILE" 2>&1

  log "✅ Schema loaded"
}

create_minimal_schema() {
  log "⚠️  Creating minimal schema (tables only)..."
  
  docker exec -i transcendence_db psql -U api42 -d api42 <<'EOF' >> "$LOG_FILE" 2>&1
-- Minimal schema for Transcendence MVP
-- Focuses on Brussels campus, static metadata + live users

-- Metadata tables (01-08)
CREATE TABLE IF NOT EXISTS cursus (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS campuses (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  slug VARCHAR(255),
  city VARCHAR(255),
  country VARCHAR(255),
  zip_code VARCHAR(10),
  website VARCHAR(255),
  active BOOLEAN DEFAULT true
);

CREATE TABLE IF NOT EXISTS projects (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  slug VARCHAR(255),
  description TEXT,
  difficulty INT,
  parent_id INT,
  FOREIGN KEY (parent_id) REFERENCES projects(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS coalitions (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  slug VARCHAR(255),
  color VARCHAR(7)
);

CREATE TABLE IF NOT EXISTS achievements (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  slug VARCHAR(255),
  description TEXT,
  image_url VARCHAR(512),
  difficulty INT
);

CREATE TABLE IF NOT EXISTS campus_projects (
  id SERIAL PRIMARY KEY,
  campus_id INT NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
  project_id INT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  UNIQUE(campus_id, project_id)
);

CREATE TABLE IF NOT EXISTS campus_achievements (
  id SERIAL PRIMARY KEY,
  campus_id INT NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
  achievement_id INT NOT NULL REFERENCES achievements(id) ON DELETE CASCADE,
  UNIQUE(campus_id, achievement_id)
);

CREATE TABLE IF NOT EXISTS project_sessions (
  id SERIAL PRIMARY KEY,
  project_id INT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  campus_id INT NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
  begins_at TIMESTAMP,
  ends_at TIMESTAMP
);

-- Live tables (09-12)
CREATE TABLE IF NOT EXISTS users (
  id SERIAL PRIMARY KEY,
  login VARCHAR(255) NOT NULL UNIQUE,
  email VARCHAR(255),
  first_name VARCHAR(255),
  last_name VARCHAR(255),
  image_url VARCHAR(512),
  cursus_users_id INT,
  coalition_user_id INT,
  campus_id INT REFERENCES campuses(id),
  student BOOLEAN DEFAULT true,
  alumni BOOLEAN DEFAULT false,
  level DECIMAL(3,1) DEFAULT 0.0,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS project_users (
  id SERIAL PRIMARY KEY,
  user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  project_id INT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  status VARCHAR(50),
  occurrence INT DEFAULT 0,
  final_mark INT,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(user_id, project_id)
);

CREATE TABLE IF NOT EXISTS achievements_users (
  id SERIAL PRIMARY KEY,
  user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  achievement_id INT NOT NULL REFERENCES achievements(id) ON DELETE CASCADE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(user_id, achievement_id)
);

CREATE TABLE IF NOT EXISTS coalitions_users (
  id SERIAL PRIMARY KEY,
  user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  coalition_id INT NOT NULL REFERENCES coalitions(id) ON DELETE CASCADE,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(user_id, coalition_id)
);

CREATE INDEX IF NOT EXISTS idx_users_campus ON users(campus_id);
CREATE INDEX IF NOT EXISTS idx_project_users_user ON project_users(user_id);
CREATE INDEX IF NOT EXISTS idx_achievements_users_user ON achievements_users(user_id);
CREATE INDEX IF NOT EXISTS idx_coalitions_users_user ON coalitions_users(user_id);
EOF

  log "✅ Minimal schema created"
}

verify_tables() {
  log "🔍 Verifying tables..."
  
  local tables=("cursus" "campuses" "projects" "coalitions" "achievements" "users" "project_users" "achievements_users" "coalitions_users")
  local missing=0

  for table in "${tables[@]}"; do
    if docker exec transcendence_db psql -U api42 -d api42 -t -c \
      "SELECT 1 FROM information_schema.tables WHERE table_name='$table'" 2>/dev/null | grep -q 1; then
      log "  ✅ $table"
    else
      log "  ❌ $table (MISSING)"
      missing=$((missing + 1))
    fi
  done

  if [ $missing -eq 0 ]; then
    log "✅ All tables verified"
    return 0
  else
    log "⚠️  $missing tables missing"
    return 1
  fi
}

# ============================================================================ #
#  Main
# ============================================================================ #

log "🚀 Initializing Transcendence database..."
log "   Log: $LOG_FILE"

if ! wait_for_db "db" "api42"; then
  log "❌ Database initialization failed"
  exit 1
fi

load_schema
verify_tables

log "✅ Database initialization complete"
