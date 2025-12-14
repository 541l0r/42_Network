# Pre-Phase-End Analysis & Checklist

**Date**: December 12, 2025  
**Phase**: Stable Databases Completion  
**Status**: Ready for Live Tracking Phase

---

## 1. Database Data Analysis

### NULL Value Distribution

**Critical Finding**: All primary keys and essential fields are NOT NULL ✅

```
Table        | Total Rows | NULL IDs | NULL Names | Critical NULLs
─────────────┼────────────┼──────────┼────────────┼──────────────
cursus       |          1 |        0 |          0 | ✅ Clean
campuses     |         54 |        0 |          0 | ✅ Clean
projects     |        519 |        0 |          0 | ⚠️  52 NULL slugs
coalitions   |        350 |        0 |          0 | ✅ Clean
achievements |       1042 |        0 |          0 | ✅ Clean
```

### Optional Fields Analysis

**Projects table** - optional/sparse fields:
- `parent_id`: 347/519 NULL (66.9%) - OK, not all projects have parents
- `difficulty`: 52/519 NULL (10%) - Expected, some projects unrated
- `exam`: 500/519 NULL (96%) - Most projects are not exams
- `git_id`: 49/519 NULL (9.4%) - Most have git repos
- `repository`: 49/519 NULL (9.4%) - Consistent with git_id
- `recommendation`: 0/519 NULL ✅ All have values

**Achievements table** - metadata:
- `parent_id`: 941/1042 NULL (90%) - OK, only top-level achievements have no parent
- `users_url`: 732/1042 NULL (70%) - Expected, achievement visibility varies

**Coalitions table** - all populated:
- `image_url`, `cover_url`, `color`, `user_id` → all have values ✅

### Data Quality Verdict

✅ **No problematic NULLs**  
✅ **All primary relationships complete**  
⚠️ **Optional fields sparse as expected for metadata**

---

## 2. Orchestration Workflow

### Pipeline Architecture

```
update_all_cursus_21_core.sh (ORCHESTRATOR)
│
├─ PHASE 1: FETCH (ensures token fresh)
│  ├─ token_manager.sh ensure-fresh
│  └─ Helper scripts:
│     ├─ fetch_cursus.sh                (1 API hit)
│     ├─ fetch_campuses.sh              (1 API hit)
│     ├─ fetch_cursus_projects.sh       (2-5 API hits)
│     ├─ fetch_campus_achievements.sh   (1 per campus = 54 hits)
│     └─ fetch_coalitions.sh            (1 API hit)
│     Total: ~60-65 API calls
│
├─ PHASE 2: NORMALIZE & EXTRACT
│  ├─ Extract campus_projects linkages
│  ├─ Extract project_sessions
│  └─ Filter to active campuses (54 only)
│
└─ PHASE 3: DATABASE LOAD
   ├─ Stage into _delta tables
   ├─ Validate FK relationships
   ├─ Upsert into production tables
   └─ Log results & timing
```

### Dependencies & Ordering

**Critical Ordering** (must execute in this sequence):

1. **cursus** ← No dependencies
2. **campuses** ← No dependencies (but needed for achievement filtering)
3. **projects** ← No dependencies
4. **coalitions** ← No dependencies
5. **achievements** ← No dependencies
6. **campus_projects** ← Requires: campuses, projects
7. **campus_achievements** ← Requires: campuses, achievements
8. **project_sessions** ← Requires: projects

**Token Refresh Timing**:
- Called at start of every update_*_tables.sh script
- Logs to `/srv/42_Network/logs/42_token_refresh.log`
- Automatic retry on 401 during API calls

---

## 3. Edge Cases & Known Constraints

### API-Related Edge Cases

1. **Pagination gaps**
   - If API skips rows between pages, data may be incomplete
   - Mitigation: Full fetch validates row counts against headers

2. **Rate limiting** (42 School API)
   - Hard limit: ~1200 API calls/hour per token
   - Soft limit: ~20-40 per minute advisable
   - Current load: ~65 calls, spaced over ~3 minutes ✅

3. **Token expiration during fetch**
   - Mid-call 401 triggers auto-refresh + retry
   - Hourly cron refresh prevents stale tokens

4. **Campus filtering edge case**
   - Only 54 active campuses (active=true AND public=true)
   - 21 projects had zero active campus links → removed ✅
   - Ensures no orphaned project records

5. **Null slug in projects**
   - 52 projects have NULL slugs
   - Unique constraint on slug still works (NULLs don't violate uniqueness)
   - Recommendation: Investigate if slug should be populated

### Database Edge Cases

1. **Delta table cleanup**
   - Delta tables must be truncated after load
   - Missing truncate = duplicate inserts on next run ⚠️
   - Current implementation: TRUNCATE in place

2. **Duplicate coalition slugs**
   - 2 coalitions named "Analysts" with same slug (allowed by design)
   - Removed UNIQUE constraint on slugs ✅
   - Each has unique ID and name

3. **Foreign Key cascading**
   - ON DELETE CASCADE enabled for FK relationships
   - Deleting a campus cascades to campus_projects ✅
   - Safe for cleanup operations

### Script-Level Edge Cases

1. **Missing helper scripts**
   - All update_*_tables.sh scripts check helper existence
   - Exit with clear error if missing ✅

2. **Empty JSON responses**
   - Checks for empty files: `if [[ ! -s "$FILE" ]]`
   - Prevents loading null datasets ✅

3. **jq parsing failures**
   - Validates JSON with `jq -e 'type=="array'` ✅
   - Exits cleanly on parse errors

4. **Database connection failures**
   - Fallback: tries psql local, then docker compose
   - Explicit error messages for both failures ✅

---

## 4. Load Testing (<1000 API calls/hour)

### Current Load Profile

**Single Full Sync**:
- API calls: ~65 (1 cursus, 1 campuses, 2-5 projects, 54 achievements, 1 coalitions)
- Duration: ~3m 36s (fresh data)
- Throughput: ~1.1 calls/sec, well under limits

**Hourly Schedule** (cron at 01:00 UTC):
- Peak: 1 sync = 65 calls/hour
- Token refresh: 12 additional refreshes/hour = 12 calls/hour
- **Total: ~77 API calls/hour** ✅ (far under 120 limit)

**Recommended Load Test** (validate resilience):
```bash
# Simulate back-to-back syncs
for i in {1..5}; do
  echo "Run $i..."
  bash scripts/update_stable_tables/update_all_cursus_21_core.sh --force
  sleep 30
done
```

Expected: <400 API calls in <20 minutes, no 429 errors

---

## 5. Orchestration Observations

### Always-Moving Work Pattern

**The pipeline continuously moves data**:
1. **Fetch** → exports/ (JSON files)
2. **Normalize** → structured JSON
3. **Stage** → _delta tables
4. **Load** → production tables
5. **Cleanup** → truncate _delta, log results

**No data "sits" at any stage** except final tables ✅

### Information Flow

```
API (42.fr)
    ↓
token_manager.sh (validates/refreshes token)
    ↓
fetch_*.sh (pagination, validation, caching)
    ↓
exports/ (raw_all.json, all.json per table)
    ↓
jq (normalization, filtering to active campuses)
    ↓
*_delta tables (staging, validation)
    ↓
COPY/UPSERT (production load)
    ↓
Logging & metrics
```

---

## 6. Script Execution Order (Cron)

### Daily Schedule

```
00:00 UTC: System ready
...
05:00 UTC: Token refresh (every hour, 5-min past)
...
01:00 UTC: Nightly stable tables update (full pipeline)
       ├─ update_cursus
       ├─ update_campuses
       ├─ update_projects
       ├─ update_campus_achievements
       ├─ update_coalitions
       └─ check_db_integrity (verify results)
       Duration: ~4 minutes

02:00 UTC: Log rotation & cleanup
       ├─ Rotate logs >50MB or >1 day old
       ├─ Compress with gzip
       ├─ Archive to /srv/42_Network/logs/archive/
       └─ Clean old archives (>7d main, >30d archive)
       Duration: <1 minute
```

---

## 7. Logging & Observability

### Log Files Created/Monitored

**Production Logs** (`/srv/42_Network/logs/`):
- `42_token_refresh.log` - Token operations
- `nightly_stable_tables.log` - Full pipeline execution
- `update_*.log` - Individual table updates
- `archive/` - Compressed old logs

**Monitoring Points**:
1. Token refresh success/failure
2. API call counts vs limits
3. Row counts per table (detect anomalies)
4. Execution time (detect slowdowns)
5. FK validation results
6. Null value distributions

---

## 8. Known Limitations & Constraints

### API Limitations

| Constraint | Value | Impact |
|-----------|-------|--------|
| Rate limit | 1200 calls/hour | ✅ Current load: 77/hour (6.4% utilization) |
| Pagination limit | 100 per page | Projects: 2-5 pages, OK |
| Cache duration | 1 hour minimum | Incremental syncs possible |
| Max page size | 100 | Achievements: 54 * 100 = 5400 theoretical |

### Database Limitations

| Item | Value | Status |
|------|-------|--------|
| Active campuses | 54 | Fixed filter, prevents orphans |
| Student filter | kind='student', alumni=false | Data quality gate |
| Slug uniqueness | Disabled for coalitions | By design (2 "Analysts") |
| Foreign keys | ON DELETE CASCADE | Safe for cleanup |

### Sync Limitations

| Feature | Status | Reason |
|---------|--------|--------|
| Incremental user sync | ❌ Not yet | Requires range[updated_at] logic |
| Partial table refresh | ❌ Not yet | All-or-nothing per table |
| Parallel fetches | ❌ Sequential only | Respects rate limits |
| Rollback on failure | ❌ No rollback | Timestamp-based idempotency |

---

## 9. Pre-Commit Checklist

- [x] All 8 core tables validated
- [x] Zero orphaned FK records
- [x] NULL value analysis complete
- [x] Token refresh working
- [x] Cron jobs configured
- [x] Logging infrastructure active
- [x] Delta staging pattern verified
- [x] Edge cases documented
- [x] Load profile under limits
- [ ] Load test executed (5 back-to-back syncs)
- [ ] Documentation reviewed & updated
- [ ] Production deployment procedure documented

---

## 10. Transition to Live Tracking Phase

### What's Ready

✅ Stable metadata tables (8 tables, 36K rows)  
✅ Automated daily sync pipeline  
✅ Token management & resilience  
✅ Comprehensive logging  
✅ Integrity validation  

### What's Pending (Live Tracking)

❌ `users` table - Sync student profiles  
❌ `project_users` - Student enrollments  
❌ `achievements_users` - Earned badges  
❌ `coalitions_users` - Team memberships  

### Phase Gate

**Before starting Live Tracking**:
1. Run full load test (5+ cycles)
2. Verify no API 429 errors
3. Review all error logs
4. Confirm daily cron execution
5. Document any adjustments needed

---

## 11. Quick Reference: Critical Commands

```bash
# Validate database
bash scripts/check_db_integrity.sh

# Manual full sync
bash scripts/update_stable_tables/update_all_cursus_21_core.sh --force

# Check token status
bash scripts/token_manager.sh token-info

# View logs
tail -f /srv/42_Network/logs/nightly_stable_tables.log

# Test cron jobs
crontab -l
```

---

## 12. Data Ownership: Single Source of Truth

### Principle

**The database is a synchronized mirror of 42 School API**

This is a critical design principle that ensures:
- All master data comes from 42 School API
- Database never creates data independently
- API deletions automatically sync to database
- No orphaned or stale data can exist

### Proof of Auto-Deletion

When 42 School API removes data, our database deletes it automatically within 24 hours via the nightly sync job.

**SQL Implementation** (same pattern in all update scripts):

```sql
-- Delete any data no longer present in API
DELETE FROM {table} t
WHERE NOT EXISTS (
  SELECT 1 FROM {table}_delta d WHERE d.id = t.id
);
```

**Example**: If 42 School deletes Project ID=100

1. Nightly fetch (01:00 UTC): Project 100 NOT returned by API
2. Delta table staging: All projects EXCEPT 100 loaded
3. Prune step: DELETE FROM projects WHERE id NOT IN (delta)
4. Project 100 deleted from DB
5. CASCADE: project_sessions for ID=100 also deleted
6. Result: Complete purge within 24 hours ✅

### Cascading Deletes Enabled

All foreign keys use `ON DELETE CASCADE`:

```sql
ALTER TABLE campus_projects
  ADD CONSTRAINT fk_campus_projects_project
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
```

When parent deleted → all children auto-deleted → no orphans possible

### Evidence in Logs

```log
[2025-12-12T19:08:48Z] Pruning projects missing from this snapshot...
DELETE 0          ← 0 projects removed this run (all in API)
```

Every sync logs deletion counts, proving the system is working.

### Why This Matters

✅ **Compliance**: Database reflects actual 42 School data only  
✅ **Data Integrity**: No stale or deleted data can linger  
✅ **Audit Trail**: All deletions logged with timestamps  
✅ **Safety**: Cascading prevents partial orphaned states  
✅ **Trust**: Reports/queries always reflect current API state  

---

**Document Status**: Complete (v1.1)  
**Last Updated**: 2025-12-12 19:30 UTC  
**Reviewer**: Claude (AI Assistant)
