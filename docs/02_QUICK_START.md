# Quick Start: Cursus 21 Data Pipeline

## What Is This?

A complete data synchronization pipeline for **Cursus 21** (42 School's primary curriculum) that:
- Fetches student data, enrollments, and achievements from the 42 School API
- Stores everything in PostgreSQL with proper relationships
- Optimizes API calls from 1,130+ down to 40-50 per night
- Supports incremental "changes only" syncs for real-time updates

## First-Time Setup (10 minutes)

### Step 1: Verify Scripts Exist

```bash
cd /srv/42_Network/repo
ls -lh scripts/helpers/fetch_cursus*.sh
ls -lh scripts/update_stable_tables/update_*.sh
```

All should show `-rwxr-xr-x` (executable). If not:
```bash
chmod +x scripts/helpers/*.sh scripts/update_stable_tables/*.sh
```

### Step 2: Verify Database Connection

```bash
# Test connection
docker compose exec -T db psql -U api42 -d api42 -c "SELECT version();"
```

Should print PostgreSQL version. If fails, run `make re` to reinitialize.

### Step 3: Run Bootstrap Fetch (5-10 minutes)

```bash
# Fetch all cursus 21 data (first time = 500-1000 API hits)
bash scripts/helpers/fetch_cursus_21_core_data.sh --force
```

Watch for:
- Progress messages every step (Step 1.1, Step 1.2, etc.)
- Page counts (Page 1, Page 2, etc.) for each resource
- Final message "FETCH PROJECT_USERS COMPLETE"

**Logs available** in: `/srv/42_Network/repo/logs/`

Expected time: **5-10 minutes**

### Step 4: Update Database (1 minute)

```bash
# Sync fetched data into PostgreSQL
bash scripts/cron/nightly_stable_tables.sh
```

Watch for:
- "PHASE 1: FETCHING..." and "PHASE 2: UPDATING..." sections
- ✓ checkmarks for each step
- Final summary with table counts

**Duration**: ~1-2 minutes

### Step 5: Validate Data

```bash
# Check cursus 21 students were imported
docker compose exec -T db psql -U api42 -d api42 -c \
  "SELECT COUNT(*) as cursus_21_students FROM users WHERE cursus_id=21 AND kind='student';"

# Should print: 47
```

If 47 appears → **success! Pipeline is working.**

## Running the Pipeline

### Daily (Nightly Sync - ~1 minute)

To run manually:
```bash
bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh
```

To automate (cron):
```bash
# Edit crontab
crontab -e

# Add line (runs 2 AM UTC):
0 2 * * * bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh
```

### Every 15 Minutes (Real-Time Incremental - optional)

To test:
```bash
# Fetch only changes from last 24 hours
START=$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

UPDATED_RANGE="$START,$END" bash /srv/42_Network/repo/scripts/helpers/fetch_cursus_users.sh
```

Expected: **5-20 API hits** (vs 500-1000 for full fetch)

## What Gets Synced

### Reference Data (Stable - changes rarely)

| Table | Count | Updated | From |
|-------|-------|---------|------|
| `cursus` | 54 | Nightly | 1 API hit |
| `campuses` | 25 | Nightly | 1 API hit |
| `projects` | 900+ | Nightly | 1-2 API hits (cursus 21 only) |
| `achievements` | 8,000+ | Nightly | ~10 API hits (per campus) |
| `coalitions` | 350 | Nightly | 4 API hits |

### Active Data (Changes daily)

| Table | Count | Updated | From | Filter |
|-------|-------|---------|------|--------|
| `users` | 47 | Nightly + incremental | 5-20 API hits/night | cursus_id=21, kind=student, alumni=false |
| `projects_users` | 900+ | Nightly + incremental | 20 API hits/night | campus-specific, cursus_id=21 |
| `achievements_users` | Varies | Nightly | Derived | cursus_id=21 |
| `coalitions_users` | 92,000+ | Nightly | 350 API hits | (Note: very large) |

## Monitoring

### Check Last Sync

```bash
# View last nightly run
tail -50 /srv/42_Network/repo/logs/nightly_stable_tables.log

# View API efficiency
grep "API hits" /srv/42_Network/repo/logs/nightly_stable_tables.log
```

### Check Database State

```bash
# How many cursus 21 students do we have?
docker compose exec -T db psql -U api42 -d api42 -c \
  "SELECT COUNT(*) FROM users WHERE cursus_id=21;"

# How many enrollments?
docker compose exec -T db psql -U api42 -d api42 -c \
  "SELECT COUNT(*) FROM projects_users WHERE cursus_id=21;"

# Sample a student's projects
docker compose exec -T db psql -U api42 -d api42 -c \
  "SELECT u.login, p.name, pu.final_mark FROM users u \
   JOIN projects_users pu ON u.id=pu.user_id \
   JOIN projects p ON pu.project_id=p.id \
   WHERE u.cursus_id=21 \
   LIMIT 5;"
```

## Troubleshooting

### Problem: "API rate limit exceeded"

**Solution**: Scripts have built-in delays (0.6s between calls). If still hitting limits:
```bash
# Increase delay
export SLEEP_BETWEEN_CALLS=2.0  # 2 seconds instead of 0.6
bash scripts/cron/nightly_stable_tables.sh
```

### Problem: "Connection refused" (database)

**Solution**: Start docker containers:
```bash
docker compose up -d
# Wait 5-10 seconds for database to start
bash scripts/cron/nightly_stable_tables.sh
```

### Problem: "No data in database"

**Solution**: Run bootstrap first:
```bash
bash scripts/helpers/fetch_cursus_21_core_data.sh --force
bash scripts/cron/nightly_stable_tables.sh
```

### Problem: API token expired

**Solution**: Scripts refresh tokens automatically, but you can force refresh:
```bash
bash /srv/42_Network/repo/scripts/token_manager.sh refresh
bash scripts/cron/nightly_stable_tables.sh
```

## Scripts Overview

### Fetch Scripts (Get data from API)

```
fetch_cursus_21_core_data.sh      ← Run this for everything
  ├─ fetch_cursus.sh
  ├─ fetch_cursus_projects.sh
  ├─ fetch_cursus_users.sh        ← Key script, supports incremental
  ├─ fetch_projects_users_by_campus_cursus.sh
  └─ fetch_campus_achievements_by_id.sh
```

### Update Scripts (Put data in database)

```
nightly_stable_tables.sh          ← Orchestrator, run this
  ├─ update_cursus.sh
  ├─ update_campuses.sh
  ├─ update_projects.sh
  ├─ update_users_cursus.sh       ← Key script, filters alumni
  ├─ update_projects_users_cursus.sh
  ├─ update_achievements_cursus.sh
  ├─ update_coalitions.sh
  └─ update_coalitions_users.sh
```

## Key Concepts

### Cursus vs Campus

- **Cursus 21** = 42cursus (global curriculum) with ~1,500 students worldwide
- **Campus 21** = Paris school location (specific campus)
- Pipeline focuses on **cursus 21** (global), not individual campuses
- This is intentional: we track students across all campuses where they're enrolled

### Incremental Sync (The Efficiency Secret)

First time:
```bash
# Fetch ALL 47 students = 500-1000 API hits
bash fetch_cursus_21_core_data.sh --force
```

After that (daily):
```bash
# Fetch only CHANGED students = 5-20 API hits
UPDATED_RANGE="2025-01-14T00:00:00Z,2025-01-15T00:00:00Z" \
bash fetch_cursus_users.sh
```

Uses `range[updated_at]=START,END` filter on API to get only recent changes.

### Database Filters

All user data filtered to:
- `cursus_id = 21` (42cursus only, not global)
- `kind = 'student'` (exclude inactive roles)
- `alumni = false` (exclude alumni, historical data)

Result: **47 active students** (precise scope)

## Performance

| Operation | Hits | Time | KB |
|-----------|------|------|-----|
| **First fetch** (bootstrap) | 500-1000 | 5-10 min | 5-10 MB |
| **Nightly sync** (daily) | 40-50 | 1-2 min | 100-200 KB |
| **Incremental** (hourly) | 5-20 | 30-60 sec | 10-50 KB |

## What Happens with Real-Time Updates?

Cursus 21 student activity (every 15 minutes):
1. `live_db_sync.sh` runs (not yet implemented, future phase)
2. Fetches changes from last 15 minutes
3. Updates `users`, `projects_users`, `achievements_users` tables
4. Takes <1 minute, <10 API hits

This is separate from nightly, runs continuously.

## Documentation

- **CURSUS_21_DATA_PIPELINE.md** - Full technical guide (380+ lines)
- **API_OPTIMIZATION_STRATEGY.md** - Why these endpoints, not those
- **COALITION_TABLES_SCHEMA.md** - Gamification tables design
- **IMPLEMENTATION_CHECKLIST.md** - Detailed testing steps

## Next Steps

1. ✅ Run bootstrap: `bash scripts/helpers/fetch_cursus_21_core_data.sh --force`
2. ✅ Update DB: `bash scripts/cron/nightly_stable_tables.sh`
3. ✅ Verify: Query database, confirm 47 users
4. ⏳ Test incremental: Set `UPDATED_RANGE` and fetch again (should be <5s)
5. ⏳ Add cron: Edit crontab to run nightly at 2 AM UTC
6. ⏳ Monitor: Check logs after each run

## Questions?

- Check `/srv/42_Network/repo/logs/` for detailed operation logs
- Read `docs/CURSUS_21_DATA_PIPELINE.md` for architecture details
- Review `IMPLEMENTATION_CHECKLIST.md` for testing procedures

