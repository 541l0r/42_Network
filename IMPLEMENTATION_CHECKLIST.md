# Cursus 21 Implementation Checklist

## ✅ Phase 1: Core Data Pipeline (COMPLETED)

### Fetch Scripts
- [x] `fetch_cursus.sh` - Fetch all cursus metadata
- [x] `fetch_cursus_projects.sh` - Fetch cursus 21 projects
- [x] `fetch_cursus_users.sh` - Fetch cursus 21 students (incremental-ready)
- [x] `fetch_projects_users_by_campus_cursus.sh` - Fetch enrollments per campus
- [x] `fetch_campus_achievements_by_id.sh` - Fetch achievements per campus
- [x] `fetch_cursus_21_core_data.sh` - Orchestrator for all fetches

### Update Scripts
- [x] `update_cursus.sh` - Sync cursus reference
- [x] `update_projects.sh` - Sync projects reference
- [x] `update_campuses.sh` - Sync campuses reference
- [x] `update_campus_achievements.sh` - Sync achievements
- [x] `update_users_cursus.sh` - Sync cursus 21 students
- [x] `update_projects_users_cursus.sh` - Sync enrollments per campus
- [x] `update_achievements_cursus.sh` - Sync badge enrollments
- [x] `update_coalitions.sh` - Sync team metadata
- [x] `update_coalitions_users.sh` - Sync team membership

### Orchestrator
- [x] `nightly_stable_tables.sh` - Updated to call cursus 21 pipeline

### Documentation
- [x] `CURSUS_21_DATA_PIPELINE.md` - Comprehensive pipeline guide (380+ lines)
- [x] `API_OPTIMIZATION_STRATEGY.md` - API efficiency analysis
- [x] `COALITION_TABLES_SCHEMA.md` - Coalition table design

## ⏳ Phase 2: Testing & Validation (NEXT STEPS)

### Test Fetch Scripts

Run bootstrap fetch (first time):
```bash
cd /srv/42_Network/repo
bash scripts/helpers/fetch_cursus_21_core_data.sh --force

# Expected: 40-50 API hits, 5-10 minutes, logs to /repo/logs/
# Check: tail -f logs/nightly_stable_tables.log
```

Expected outputs in exports/:
- `01_cursus/all.json` - 1 cursus (id=21)
- `05_projects/all.json` - 900+ projects
- `08_users/cursus_21/all.json` - 47 active students
- `06_project_users/cursus_21/campus_*/all.json` - Per-campus enrollments
- `04_campus_achievements/campus_*/all.json` - Per-campus badges

### Validate Data Quality

```bash
# Check cursus metadata
jq '.[] | select(.id==21)' exports/01_cursus/all.json

# Count students
jq 'length' exports/08_users/cursus_21/all.json
# Expected: 47

# Count total enrollments
find exports/06_project_users/cursus_21 -name "all.json" -exec jq 'length' {} \; | awk '{s+=$1} END {print s}'
# Expected: 900+ enrollments

# Check filter effectiveness (no alumni)
jq '.[] | select(.alumni==true)' exports/08_users/cursus_21/all.json | wc -l
# Expected: 0 (no alumni)
```

### Test Update Scripts

Run database updates:
```bash
cd /srv/42_Network/repo
bash scripts/cron/nightly_stable_tables.sh

# Check logs
tail -20 logs/nightly_stable_tables.log
```

### Validate Database State

```bash
# Connect to database
docker compose exec -T db psql -U api42 -d api42 -c "SELECT COUNT(*) FROM users WHERE cursus_id=21 AND kind='student';"
# Expected: 47

docker compose exec -T db psql -U api42 -d api42 -c "SELECT COUNT(*) FROM projects_users WHERE cursus_id=21;"
# Expected: 900+

docker compose exec -T db psql -U api42 -d api42 -c "SELECT COUNT(*) FROM achievements WHERE campus_id > 0;"
# Expected: 8000+
```

### Test Incremental Sync

```bash
# Fetch only recent changes (last 24 hours)
START=$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

UPDATED_RANGE="$START,$END" bash scripts/helpers/fetch_cursus_users.sh

# Check hits count in log
tail -10 logs/fetch_cursus_users.log | grep "API hits"
# Expected: 5-20 hits (not 500-1000)
```

## ⏳ Phase 3: Cron Integration (NEXT STEPS)

### Setup Nightly Cron Job

```bash
# Edit crontab
crontab -e

# Add line (runs 2 AM UTC):
0 2 * * * bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh >> /srv/42_Network/repo/logs/cron_nightly.log 2>&1
```

### Setup Real-Time Live Sync (Optional)

```bash
# Add line (runs every 15 minutes):
*/15 * * * * bash /srv/42_Network/repo/scripts/cron/live_db_sync.sh >> /srv/42_Network/repo/logs/cron_live.log 2>&1
```

### Verify Cron Execution

```bash
# After first run, check:
ls -lh logs/cron_nightly.log

# Monitor next scheduled run:
tail -f logs/cron_nightly.log
```

## ⏳ Phase 4: Known Issues & Workarounds (OUTSTANDING)

### Issue: coalitions_users FK Constraints

**Status**: PENDING FIX

**Problem**: 92,368 coalition_users records reference coalition_id=10 which doesn't exist in coalitions table

**Root Cause**: Some users enrolled in deleted/inactive coalitions

**Current Workaround**: FK constraint temporarily disabled in update_coalitions_users.sh

**Solution Options**:
1. **Filter orphans** (recommended): Add WHERE clause to skip missing foreign keys:
   ```sql
   INSERT INTO coalitions_users (...)
   SELECT ... FROM coalitions_users_delta d
   WHERE EXISTS (SELECT 1 FROM coalitions c WHERE c.id = d.coalition_id)
   ```
2. **Allow orphans**: Set FK constraint to nullable (sacrifice data integrity)
3. **Fetch missing**: Fetch deleted coalitions (resource intensive)

**Implementation**: Edit `update_coalitions_users.sh` to use Option 1

### Issue: Achievements_users Extraction

**Status**: PARTIAL

**Problem**: Achievements are derived from campus achievements, but users don't have direct achievement_id references

**Current**: Creates dummy records with NULL achievement_id

**Solution**: Enhance extraction to cross-reference with project_users if achievements field available

## ⏳ Phase 5: Performance Optimization (FUTURE)

### Monitor API Hit Count

After nightly run, check:
```bash
grep "API hits" logs/nightly_stable_tables.log
```

Target: 40-50 hits per night, 5-20 for daily incremental

### Identify Slow Steps

```bash
grep "Duration\|complete" logs/nightly_stable_tables.log | tail -20
```

Target: <10 minutes total (phase 1 + phase 2)

### Cache Optimization

Scripts implement smart caching:
- Skip refetch if last run < 1 hour ago
- Use `--force` flag to override cache
- Metrics stored in `.last_fetch_stats` files

## 📋 Quick Reference: Running the Pipeline

### Bootstrap (First Time)

```bash
# Full data fetch + DB update (takes 10-15 minutes)
cd /srv/42_Network/repo
bash scripts/cron/nightly_stable_tables.sh

# Check results
docker compose exec -T db psql -U api42 -d api42 -c "SELECT COUNT(*) FROM users WHERE cursus_id=21;"
```

### Daily Nightly Run

```bash
# Set cron or run manually:
bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh

# Logs available in:
tail -50 /srv/42_Network/repo/logs/nightly_stable_tables.log
```

### Manual Incremental Sync (Testing)

```bash
# Fetch last 24 hours of changes:
START=$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

UPDATED_RANGE="$START,$END" bash /srv/42_Network/repo/scripts/helpers/fetch_cursus_users.sh

# View result:
tail -50 /srv/42_Network/repo/logs/fetch_cursus_users.log
```

## 🔗 Key Files for Future Reference

```
Core Pipeline:
  /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh (orchestrator)
  /srv/42_Network/repo/scripts/helpers/fetch_cursus_21_core_data.sh (fetch orchestrator)

Fetch Scripts:
  /srv/42_Network/repo/scripts/helpers/fetch_cursus_users.sh (incremental-ready)
  /srv/42_Network/repo/scripts/helpers/fetch_projects_users_by_campus_cursus.sh
  /srv/42_Network/repo/scripts/helpers/fetch_campus_achievements_by_id.sh

Update Scripts:
  /srv/42_Network/repo/scripts/update_stable_tables/update_users_cursus.sh
  /srv/42_Network/repo/scripts/update_stable_tables/update_projects_users_cursus.sh
  /srv/42_Network/repo/scripts/update_stable_tables/update_achievements_cursus.sh

Documentation:
  /srv/42_Network/repo/docs/CURSUS_21_DATA_PIPELINE.md (comprehensive)
  /srv/42_Network/repo/docs/API_OPTIMIZATION_STRATEGY.md (API analysis)
  /srv/42_Network/repo/docs/COALITION_TABLES_SCHEMA.md (coalition design)

Database:
  /srv/42_Network/repo/data/schema.sql (tables)
  /srv/42_Network/repo/logs/ (all operation logs)
```

## ✅ Summary of Deliverables

| Item | Status | Location |
|------|--------|----------|
| Fetch scripts (6 total) | ✅ Complete | scripts/helpers/ |
| Update scripts (9 total) | ✅ Complete | scripts/update_stable_tables/ |
| Orchestrators (2) | ✅ Complete | scripts/helpers/, scripts/cron/ |
| Database schema | ✅ In place | data/schema.sql |
| Documentation (3 docs) | ✅ Complete | docs/ |
| API optimization | ✅ Analyzed | 1,130 → 40-50 hits/night |
| Incremental sync | ✅ Designed | UPDATED_RANGE support |
| Cron integration | ⏳ Ready | Edit crontab to activate |
| Testing | ⏳ Next | Run nightly_stable_tables.sh |

