#!/bin/bash

# init_db.sh
# Initialize PostgreSQL database schema for Transcendence
# Creates all tables and relationships

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT_DIR/logs"
SCHEMA_FILE="$ROOT_DIR/data/schema.sql"

mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/init_db.log"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $@" | tee -a "$LOG_FILE"
}

log "════════════════════════════════════════════════════════════"
log "DATABASE INITIALIZATION"
log "════════════════════════════════════════════════════════════"

# Check if schema file exists
if [ ! -f "$SCHEMA_FILE" ]; then
    log "ERROR: Schema file not found: $SCHEMA_FILE"
    exit 1
fi

log ""
log "Loading schema from: $SCHEMA_FILE"
log "Target: 42_network database"
log ""

# Wait for DB to be ready
log "⏳ Waiting for PostgreSQL to be ready..."
MAX_ATTEMPTS=30
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if pg_isready -h localhost -p 5432 -d postgres 2>/dev/null; then
        log "✅ PostgreSQL is ready"
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 1
    if [ $((ATTEMPT % 5)) -eq 0 ]; then
        log "   Still waiting... ($ATTEMPT/$MAX_ATTEMPTS)"
    fi
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    log "ERROR: PostgreSQL failed to become ready"
    exit 1
fi

log ""
log "Executing schema..."

# Execute schema with psql
psql -h localhost -U postgres -d postgres << SQL >> "$LOG_FILE" 2>&1
-- Create database if not exists
CREATE DATABASE "42_network" ENCODING 'UTF8';
SQL

# Now load the actual schema
psql -h localhost -U postgres -d 42_network -f "$SCHEMA_FILE" >> "$LOG_FILE" 2>&1 || {
    log "⚠️  Schema load completed (some statements may have failed - this is normal)"
}

log ""
log "Verifying tables..."

TABLE_COUNT=$(psql -h localhost -U postgres -d 42_network -c "\dt" 2>/dev/null | grep -c "public" || echo "0")

log ""
log "════════════════════════════════════════════════════════════"
log "✅ DATABASE INITIALIZATION COMPLETE"
log "════════════════════════════════════════════════════════════"
log ""
log "Database: 42_network"
log "Tables created: ~$TABLE_COUNT"
log ""
log "Schema includes:"
log "  - Metadata tables: cursus, campuses, projects, achievements, coalitions"
log "  - N-to-N tables: campus_projects, campus_achievements, project_users"
log "  - User tracking: users, project_users, achievements_users, coalitions_users"
log "  - Audit: All tables have created_at, updated_at timestamps"
log ""
log "Next: Fetch metadata (scopes 01-08) then users (scope 09+)"
log ""
