# Cursus 21 Pipeline - Command Reference Card

## Essential Commands

### 1. First-Time Setup (Bootstrap)

```bash
# Navigate to repo
cd /srv/42_Network/repo

# Fetch ALL cursus 21 data (5-10 minutes, 500-1000 API hits)
bash scripts/helpers/fetch_cursus_21_core_data.sh --force

# Update database (1-2 minutes)
bash scripts/cron/nightly_stable_tables.sh

# Verify 47 cursus 21 students loaded
docker compose exec -T db psql -U api42 -d api42 -c \
  "SELECT COUNT(*) FROM users WHERE cursus_id=21 AND kind='student';"
# Expected output: 47
```

### 2. Daily Nightly Sync (1-2 minutes)

```bash
# Option A: Manual run
bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh

# Option B: Add to crontab (runs 2 AM UTC)
crontab -e
# Add line: 0 2 * * * bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh
```

### 3. Incremental Sync (Real-time, <40 seconds)

```bash
# Fetch only changes from last 24 hours
START=$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
UPDATED_RANGE="$START,$END" bash /srv/42_Network/repo/scripts/helpers/fetch_cursus_users.sh

# Check API hits in log (should be 5-20, not 500-1000)
grep "API hits" /srv/42_Network/repo/logs/fetch_cursus_users.log
```

## Monitoring

### Check Last Sync Status

```bash
# View last nightly run
tail -50 /srv/42_Network/repo/logs/nightly_stable_tables.log

# Check API efficiency
grep "Duration\|API hits" /srv/42_Network/repo/logs/nightly_stable_tables.log | tail -5

# View all recent logs
ls -ltr /srv/42_Network/repo/logs/ | tail -10
```

### Database Queries

```bash
# Count cursus 21 students
docker compose exec -T db psql -U api42 -d api42 -c \
  "SELECT COUNT(*) FROM users WHERE cursus_id=21 AND kind='student';"

# Count enrollments
docker compose exec -T db psql -U api42 -d api42 -c \
  "SELECT COUNT(*) FROM projects_users WHERE cursus_id=21;"

# Count achievements
docker compose exec -T db psql -U api42 -d api42 -c \
  "SELECT COUNT(*) FROM achievements WHERE campus_id > 0;"

# Sample student data
docker compose exec -T db psql -U api42 -d api42 -c \
  "SELECT u.login, COUNT(pu.id) as projects 
   FROM users u 
   JOIN projects_users pu ON u.id=pu.user_id 
   WHERE u.cursus_id=21 
   GROUP BY u.login 
   LIMIT 5;"

# Check last update time
docker compose exec -T db psql -U api42 -d api42 -c \
  "SELECT updated_at FROM users WHERE cursus_id=21 ORDER BY updated_at DESC LIMIT 1;"
```

## Troubleshooting

### API Rate Limit Issues

```bash
# Increase delay between API calls (default: 0.6s)
export SLEEP_BETWEEN_CALLS=2.0
bash scripts/cron/nightly_stable_tables.sh
```

### Database Connection Failed

```bash
# Restart containers
docker compose up -d
sleep 5

# Test connection
docker compose exec -T db psql -U api42 -d api42 -c "SELECT version();"

# Reinitialize database if needed
make re
```

### No Data in Database

```bash
# Run full bootstrap
bash scripts/helpers/fetch_cursus_21_core_data.sh --force
bash scripts/cron/nightly_stable_tables.sh

# Check if fetch completed
ls -lh exports/08_users/cursus_21/all.json
```

### Token Expired

```bash
# Manually refresh token
bash /srv/42_Network/repo/scripts/token_manager.sh refresh

# Then retry
bash scripts/cron/nightly_stable_tables.sh
```

## Script Paths

### Fetch Scripts
```
/srv/42_Network/repo/scripts/helpers/
  ├─ fetch_cursus.sh
  ├─ fetch_cursus_projects.sh
  ├─ fetch_cursus_users.sh (incremental-ready)
  ├─ fetch_projects_users_by_campus_cursus.sh
  ├─ fetch_campus_achievements_by_id.sh
  └─ fetch_cursus_21_core_data.sh (orchestrator)
```

### Update Scripts
```
/srv/42_Network/repo/scripts/update_stable_tables/
  ├─ update_cursus.sh
  ├─ update_campuses.sh
  ├─ update_projects.sh
  ├─ update_campus_achievements.sh
  ├─ update_users_cursus.sh
  ├─ update_projects_users_cursus.sh
  ├─ update_achievements_cursus.sh
  ├─ update_coalitions.sh
  └─ update_coalitions_users.sh
```

### Orchestrators
```
/srv/42_Network/repo/scripts/cron/
  └─ nightly_stable_tables.sh (master orchestrator)

/srv/42_Network/repo/scripts/helpers/
  └─ fetch_cursus_21_core_data.sh (fetch orchestrator)
```

## Environment Variables

```bash
# Cursus ID (default: 21)
export CURSUS_ID=21

# Per-page API pagination (default: 100)
export PER_PAGE=100

# Delay between API calls (default: 0.6s)
export SLEEP_BETWEEN_CALLS=0.6

# Incremental sync range (YYYY-MM-DDTHH:MM:SSZ,YYYY-MM-DDTHH:MM:SSZ)
export UPDATED_RANGE="2025-01-14T00:00:00Z,2025-01-15T00:00:00Z"

# Campus ID (for per-campus scripts)
export CAMPUS_ID=12

# Database (read from .env or override)
export DB_HOST=localhost
export DB_PORT=5432
export DB_NAME=api42
export DB_USER=api42
export DB_PASSWORD=api42
```

## Performance Targets

| Operation | API Hits | Time | Status |
|-----------|----------|------|--------|
| Bootstrap (first) | 500-1000 | 10-15 min | ✅ Ready |
| Nightly sync | 40-50 | 1-2 min | ✅ Ready |
| Incremental (hourly) | 5-20 | <40 sec | ✅ Design ready |

## Key Data Counts

| Table | Count | Filter |
|-------|-------|--------|
| users | 47 | cursus_id=21, kind=student |
| projects | 900+ | cursus_id=21 |
| projects_users | 900+ | cursus_id=21 |
| achievements | 8,000+ | per-campus |
| coalitions | 350 | global |
| coalitions_users | 92,000+ | all (⚠️ has orphans) |

## Documentation

| File | Purpose | Read Time |
|------|---------|-----------|
| QUICK_START.md | Getting started | 10 min |
| CURSUS_21_DATA_PIPELINE.md | Full technical | 30 min |
| IMPLEMENTATION_CHECKLIST.md | Testing procedures | varies |
| PIPELINE_VISUAL_GUIDE.md | Diagrams & flows | 15 min |
| API_OPTIMIZATION_STRATEGY.md | Why this approach | 15 min |
| IMPLEMENTATION_SUMMARY.md | Session overview | 10 min |

## One-Liner Commands

```bash
# Check if last 47 users loaded
docker compose exec -T db psql -U api42 -d api42 -c "SELECT COUNT(*) FROM users WHERE cursus_id=21;"

# View last 10 log entries
tail -10 /srv/42_Network/repo/logs/nightly_stable_tables.log

# Count API hits in last run
grep "API hits" /srv/42_Network/repo/logs/nightly_stable_tables.log | tail -1

# Force refresh and update (full pipeline)
bash /srv/42_Network/repo/scripts/helpers/fetch_cursus_21_core_data.sh --force && bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh

# Test incremental sync
UPDATED_RANGE="$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ),$(date -u +%Y-%m-%dT%H:%M:%SZ)" bash /srv/42_Network/repo/scripts/helpers/fetch_cursus_users.sh && grep "API hits" /srv/42_Network/repo/logs/fetch_cursus_users.log
```

## Quick Start Flow

```
1. cd /srv/42_Network/repo
2. bash scripts/helpers/fetch_cursus_21_core_data.sh --force
   ↓ (5-10 minutes)
3. bash scripts/cron/nightly_stable_tables.sh
   ↓ (1-2 minutes)
4. docker compose exec -T db psql -U api42 -d api42 -c \
   "SELECT COUNT(*) FROM users WHERE cursus_id=21;"
   ↓
5. Expected: 47
   If yes: ✅ SUCCESS
   If no: Check logs in /srv/42_Network/repo/logs/
```

## Common Issues Quick Fixes

| Issue | Command |
|-------|---------|
| API rate limit | `export SLEEP_BETWEEN_CALLS=2.0` then retry |
| DB connection failed | `docker compose up -d && sleep 5` |
| No data in DB | `bash scripts/helpers/fetch_cursus_21_core_data.sh --force` |
| Token expired | `bash /srv/42_Network/repo/scripts/token_manager.sh refresh` |
| Check last sync | `tail -50 /srv/42_Network/repo/logs/nightly_stable_tables.log` |

