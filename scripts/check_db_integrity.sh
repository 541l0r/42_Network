#!/usr/bin/env bash
set -euo pipefail

# Database integrity check for Cursus 21 core tables
# Validates row counts, FK consistency, and data freshness

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$ROOT_DIR/../.env" ]]; then
  source "$ROOT_DIR/../.env"
fi

DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-api42}
DB_USER=${DB_USER:-api42}
DB_PASSWORD=${DB_PASSWORD:-api42}
PSQL_CONN="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export PGPASSWORD="$DB_PASSWORD"

run_psql() {
  if command -v psql >/dev/null 2>&1; then
    psql "$PSQL_CONN" "$@"
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose exec -T -e PGPASSWORD="$DB_PASSWORD" db psql -h db -U "$DB_USER" -d "$DB_NAME" "$@"
  else
    echo "psql is not available locally and docker compose is unavailable." >&2
    exit 1
  fi
}

echo "════════════════════════════════════════════════════════════"
echo "DATABASE INTEGRITY CHECK - Cursus 21 Core Tables"
echo "════════════════════════════════════════════════════════════"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "════════════════════════════════════════════════════════════"
echo ""

errors=0

# ============================================================
# 1. CORE TABLES (5 TABLES) - Validates row count changes & ID uniqueness
# ============================================================
echo "1. CORE TABLES (5 TABLES) - Row counts & ID uniqueness"
echo "────────────────────────────────────────────────────────────"

declare -A prev_counts
prev_counts[cursus]=1
prev_counts[campuses]=54
prev_counts[projects]=519
prev_counts[coalitions]=350
prev_counts[achievements]=1042

for table in cursus campuses projects coalitions achievements; do
  count=$(run_psql -Atc "SELECT COUNT(*) FROM $table;")
  prev=${prev_counts[$table]}
  
  # Check for duplicate IDs (should never happen with PRIMARY KEY, but verify)
  dup_ids=$(run_psql -Atc "
    SELECT COUNT(*) FROM (
      SELECT id FROM $table GROUP BY id HAVING COUNT(*) > 1
    ) t;
  ")
  
  if [ "$count" -eq "$prev" ]; then
    if [ "$dup_ids" = "0" ] || [ "$dup_ids" = "" ]; then
      echo "  ✅ $table: $count (no changes, all IDs unique)"
    else
      echo "  ❌ $table: $count ($dup_ids duplicate IDs found!)"
      errors=$((errors + 1))
    fi
  else
    change=$((count - prev))
    if [ $change -gt 0 ]; then
      if [ "$dup_ids" = "0" ] || [ "$dup_ids" = "" ]; then
        echo "  ⚠️  $table: $count (+$change added, all IDs unique)"
      else
        echo "  ❌ $table: $count (+$change added, but $dup_ids duplicate IDs!)"
        errors=$((errors + 1))
      fi
    else
      if [ "$dup_ids" = "0" ] || [ "$dup_ids" = "" ]; then
        echo "  ⚠️  $table: $count ($change removed, all IDs unique)"
      else
        echo "  ❌ $table: $count ($change removed, and $dup_ids duplicate IDs!)"
        errors=$((errors + 1))
      fi
    fi
  fi
done

# ============================================================
# 2. LINKING TABLES (2 TABLES) - N-to-N relationships
# ============================================================
echo ""
echo "2. LINKING TABLES (2 TABLES) - N-to-N relationships"
echo "────────────────────────────────────────────────────────────"

declare -A linking_prev
linking_prev[campus_projects]=20937
linking_prev[campus_achievements]=5495

for table in campus_projects campus_achievements; do
  count=$(run_psql -Atc "SELECT COUNT(*) FROM $table;")
  prev=${linking_prev[$table]}
  
  # Check for duplicate composite keys
  if [ "$table" = "campus_projects" ]; then
    dup_keys=$(run_psql -Atc "
      SELECT COUNT(*) FROM (
        SELECT campus_id, project_id FROM $table GROUP BY campus_id, project_id HAVING COUNT(*) > 1
      ) t;
    ")
  else
    dup_keys=$(run_psql -Atc "
      SELECT COUNT(*) FROM (
        SELECT campus_id, achievement_id FROM $table GROUP BY campus_id, achievement_id HAVING COUNT(*) > 1
      ) t;
    ")
  fi
  
  if [ "$count" -eq "$prev" ]; then
    if [ "$dup_keys" = "0" ] || [ "$dup_keys" = "" ]; then
      echo "  ✅ $table: $count (no changes, all keys unique)"
    else
      echo "  ❌ $table: $count ($dup_keys duplicate keys found!)"
      errors=$((errors + 1))
    fi
  else
    change=$((count - prev))
    if [ $change -gt 0 ]; then
      if [ "$dup_keys" = "0" ] || [ "$dup_keys" = "" ]; then
        echo "  ⚠️  $table: $count (+$change added, all keys unique)"
      else
        echo "  ❌ $table: $count (+$change added, but $dup_keys duplicate keys!)"
        errors=$((errors + 1))
      fi
    else
      if [ "$dup_keys" = "0" ] || [ "$dup_keys" = "" ]; then
        echo "  ⚠️  $table: $count ($change removed, all keys unique)"
      else
        echo "  ❌ $table: $count ($change removed, and $dup_keys duplicate keys!)"
        errors=$((errors + 1))
      fi
    fi
  fi
done

# ============================================================
# 3. JUNCTION TABLES (1 table)
# ============================================================
# 3. DEPENDENT TABLES (1 TABLE) - Many-to-one (project_sessions → projects)
# ============================================================
echo ""
echo "3. DEPENDENT TABLES (1 TABLE) - Many-to-one relationships"
echo "────────────────────────────────────────────────────────────"

count=$(run_psql -Atc "SELECT COUNT(*) FROM project_sessions;")
prev=7256

# Check for duplicate IDs
dup_ids=$(run_psql -Atc "
  SELECT COUNT(*) FROM (
    SELECT id FROM project_sessions GROUP BY id HAVING COUNT(*) > 1
  ) t;
")

if [ "$count" -eq "$prev" ]; then
  if [ "$dup_ids" = "0" ] || [ "$dup_ids" = "" ]; then
    echo "  ✅ project_sessions: $count (no changes, all IDs unique)"
  else
    echo "  ❌ project_sessions: $count ($dup_ids duplicate IDs found!)"
    errors=$((errors + 1))
  fi
else
  change=$((count - prev))
  if [ $change -gt 0 ]; then
    if [ "$dup_ids" = "0" ] || [ "$dup_ids" = "" ]; then
      echo "  ⚠️  project_sessions: $count (+$change added, all IDs unique)"
    else
      echo "  ❌ project_sessions: $count (+$change added, but $dup_ids duplicate IDs!)"
      errors=$((errors + 1))
    fi
  else
    if [ "$dup_ids" = "0" ] || [ "$dup_ids" = "" ]; then
      echo "  ⚠️  project_sessions: $count ($change removed, all IDs unique)"
    else
      echo "  ❌ project_sessions: $count ($change removed, and $dup_ids duplicate IDs!)"
      errors=$((errors + 1))
    fi
  fi
fi

# ============================================================
# 4. LINKING TABLE INTEGRITY (All foreign key relationships)
# ============================================================
echo ""
echo "4. LINKING TABLE INTEGRITY (FOREIGN KEY RELATIONSHIPS)"
echo "────────────────────────────────────────────────────────────"

# campus_projects: campus_id -> campuses (core)
invalid=$(run_psql -Atc "
  SELECT COUNT(*) FROM campus_projects cp
  WHERE NOT EXISTS (SELECT 1 FROM campuses c WHERE c.id = cp.campus_id);
")
if [ "$invalid" = "0" ]; then
  echo "  ✅ campus_projects.campus_id → campuses.id"
else
  echo "  ❌ campus_projects.campus_id → campuses.id ($invalid orphaned)"
  errors=$((errors + 1))
fi

# campus_projects: project_id -> projects (core)
invalid=$(run_psql -Atc "
  SELECT COUNT(*) FROM campus_projects cp
  WHERE NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = cp.project_id);
")
if [ "$invalid" = "0" ]; then
  echo "  ✅ campus_projects.project_id → projects.id"
else
  echo "  ❌ campus_projects.project_id → projects.id ($invalid orphaned)"
  errors=$((errors + 1))
fi

# campus_achievements: campus_id -> campuses (core)
invalid=$(run_psql -Atc "
  SELECT COUNT(*) FROM campus_achievements ca
  WHERE NOT EXISTS (SELECT 1 FROM campuses c WHERE c.id = ca.campus_id);
")
if [ "$invalid" = "0" ]; then
  echo "  ✅ campus_achievements.campus_id → campuses.id"
else
  echo "  ❌ campus_achievements.campus_id → campuses.id ($invalid orphaned)"
  errors=$((errors + 1))
fi

# campus_achievements: achievement_id -> achievements (core)
invalid=$(run_psql -Atc "
  SELECT COUNT(*) FROM campus_achievements ca
  WHERE NOT EXISTS (SELECT 1 FROM achievements a WHERE a.id = ca.achievement_id);
")
if [ "$invalid" = "0" ]; then
  echo "  ✅ campus_achievements.achievement_id → achievements.id"
else
  echo "  ❌ campus_achievements.achievement_id → achievements.id ($invalid orphaned)"
  errors=$((errors + 1))
fi

# project_sessions: project_id -> projects (core)
invalid=$(run_psql -Atc "
  SELECT COUNT(*) FROM project_sessions ps
  WHERE NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = ps.project_id);
")
if [ "$invalid" = "0" ]; then
  echo "  ✅ project_sessions.project_id → projects.id"
else
  echo "  ❌ project_sessions.project_id → projects.id ($invalid orphaned)"
  errors=$((errors + 1))
fi

# ============================================================
# 5. UNIQUENESS CHECKS
# ============================================================
echo ""
echo "5. UNIQUENESS CHECKS"
echo "────────────────────────────────────────────────────────────"

# Project slugs - should be unique (business rule)
dup_project_slugs=$(run_psql -Atc "
  SELECT COUNT(*) FROM (
    SELECT slug FROM projects GROUP BY slug HAVING COUNT(*) > 1
  ) t;
")
if [ "$dup_project_slugs" = "0" ] || [ "$dup_project_slugs" = "" ]; then
  echo "  ✅ projects.slug: all unique"
else
  echo "  ❌ projects.slug: $dup_project_slugs duplicates"
  errors=$((errors + 1))
fi

# Coalition slugs - duplicates allowed (multiple coalitions can have same name)
dup_coalition_slugs=$(run_psql -Atc "
  SELECT COUNT(*) FROM (
    SELECT slug FROM coalitions GROUP BY slug HAVING COUNT(*) > 1
  ) t;
")
if [ "$dup_coalition_slugs" = "0" ] || [ "$dup_coalition_slugs" = "" ]; then
  echo "  ✅ coalitions.slug: all unique"
else
  echo "  ⚠️  coalitions.slug: $dup_coalition_slugs duplicates (allowed)"
fi

# Campus names - should be unique
dup_campus_names=$(run_psql -Atc "
  SELECT COUNT(*) FROM (
    SELECT name FROM campuses GROUP BY name HAVING COUNT(*) > 1
  ) t;
")
if [ "$dup_campus_names" = "0" ] || [ "$dup_campus_names" = "" ]; then
  echo "  ✅ campuses.name: all unique"
else
  echo "  ⚠️  campuses.name: $dup_campus_names duplicates"
fi

# ============================================================
# 6. DATA FRESHNESS
# ============================================================
echo ""
echo "6. DATA FRESHNESS (< 24h = green)"
echo "────────────────────────────────────────────────────────────"

format_duration() {
  local seconds=$1
  local days=$((seconds / 86400))
  local hours=$(((seconds % 86400) / 3600))
  local mins=$(((seconds % 3600) / 60))
  local secs=$((seconds % 60))
  
  if [ $days -gt 0 ]; then
    printf "%dd %dh %dm %ds" $days $hours $mins $secs
  elif [ $hours -gt 0 ]; then
    printf "%dh %dm %ds" $hours $mins $secs
  elif [ $mins -gt 0 ]; then
    printf "%dm %ds" $mins $secs
  else
    printf "%ds" $secs
  fi
}

# Check ingested_at timestamps
echo ""
for table in cursus campuses projects coalitions campus_projects project_sessions achievements campus_achievements; do
  age_seconds=$(run_psql -Atc "
    SELECT EXTRACT(EPOCH FROM (NOW() - MAX(ingested_at)))::INT FROM $table;
  " 2>/dev/null || echo "0")
  
  if [ -z "$age_seconds" ]; then
    age_seconds="0"
  fi
  
  age_formatted=$(format_duration "$age_seconds")
  
  # 24 hours = 86400 seconds
  if [ "$age_seconds" -lt 86400 ]; then
    printf "  ✅ %-25s %s (< 24h)\n" "$table:" "$age_formatted ago"
  else
    printf "  ⚠️  %-25s %s (> 24h)\n" "$table:" "$age_formatted ago"
  fi
done

# ============================================================
# 7. SCHEMA VALIDATION (8 TABLES) - All required tables exist
# ============================================================
echo ""
echo "7. SCHEMA VALIDATION (8 TABLES) - Table existence check"
echo "────────────────────────────────────────────────────────────"

# Check that all required tables exist
for table in cursus campuses projects coalitions achievements campus_projects campus_achievements project_sessions; do
  if run_psql -Atc "SELECT 1 FROM information_schema.tables WHERE table_name = '$table';" 2>/dev/null | grep -q "1"; then
    echo "  ✅ $table"
  else
    echo "  ❌ $table: does not exist"
    errors=$((errors + 1))
  fi
done

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "════════════════════════════════════════════════════════════"

if [ $errors -eq 0 ]; then
  echo "✅ ALL CHECKS PASSED"
  exit 0
else
  echo "❌ $errors ERROR(S) FOUND"
  exit 1
fi
