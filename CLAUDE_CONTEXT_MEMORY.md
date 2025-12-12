# Claude Continuation Context & Memory

**Purpose**: Preserve critical knowledge and decision history for AI continuity across sessions  
**Last Updated**: December 12, 2025, 15:00 UTC  
**Scope**: Entire 42_Network project, Stable Databases Phase

---

## Project Overview

**Project**: 42 Network - Cursus 21 Data Pipeline  
**Status**: Stable Databases Phase COMPLETE ✅  
**Next Phase**: Live Tracking (users, enrollments, achievements)  
**Tech Stack**: PostgreSQL 16, Bash, Docker Compose, 42 School API

**Repository**: https://github.com/541l0r/42_Network  
**Current Branch**: main (commit: e96925f)

---

## Critical Context

### Phase Definition

The project is structured in **distinct phases**:

1. **Stable Databases** ✅ COMPLETE
   - Static metadata that rarely changes
   - 8 core tables: cursus, campuses, projects, coalitions, achievements, campus_projects, campus_achievements, project_sessions
   - 36,254 total rows
   - Zero FK violations, all data validated
   - **No user data** in this phase

2. **Live Tracking** (NOT STARTED)
   - Dynamic user data that updates frequently
   - Tables: users, project_users, achievements_users, coalitions_users
   - Will sync hourly/daily after stable tables established
   - All schema exists but tables empty (intentional)

3. **API Integration** (FUTURE)
   - Additional endpoints and features
   - Enhanced filtering and reporting

### Key Design Decisions

**Decision 1: Active Campus Filtering** (CRITICAL)
- Only 54 campuses (active=true AND public=true) are processed
- Filters applied at extraction time (in jq) before database load
- Prevents orphaned project references
- **Result**: 519 projects (down from 538) - all have active campus links
- **Implication**: Non-active campus projects silently excluded (by design)

**Decision 2: Student-Only Data** (CRITICAL)
- Only kind='student' AND alumni=false records are loaded
- Applied in fetch scripts via API filters
- Non-students (staff, mentors) completely excluded
- **Result**: Only genuine student data in user tables

**Decision 3: Delta Staging Pattern** (INFRASTRUCTURE)
- 8 delta tables mirror production tables
- Data staged → validated → upserted → delta truncated
- Enables incremental syncs and atomic operations
- Must truncate _delta tables after every sync

**Decision 4: Token Refresh Strategy** (RESILIENCE)
- Proactive: refresh if <1 hour TTL before starting scripts
- Reactive: auto-recover from 401 errors mid-API-call
- Logging: all operations logged to /srv/42_Network/logs/42_token_refresh.log
- Hourly cron: ensures token always fresh

**Decision 5: Orphaned Data Handling** (DATA QUALITY)
- 3,258 campus_projects deleted (linked to inactive campuses)
- 19 projects deleted (zero active campus links)
- 31 project_sessions deleted (orphaned to deleted projects)
- **Not rolled back** - intentional cleanup before stable commit

---

## Known Quirks & Non-Obvious Behaviors

### The "Analysts" Coalition Issue

```sql
-- Two coalitions both named "Analysts" with identical slugs
SELECT id, name, slug FROM coalitions WHERE name = 'Analysts';
-- Result:
-- id  │  name    │    slug
-- ────┼──────────┼────────────
-- 10  │ Analysts │ analysts
-- 11  │ Analysts │ analysts
```

**Why**: 42 School API returns both; they're legitimate  
**Solution**: Removed UNIQUE constraint on `coalitions.slug`  
**Impact**: Slug lookups must include ID or name for certainty  
**Not a bug** - feature of the actual 42 School data

### NULL Slugs in Projects

```sql
-- 52 projects have NULL slugs
SELECT COUNT(*) FROM projects WHERE slug IS NULL;
-- Result: 52
```

**Why**: API returns some projects without slugs  
**Impact**: Minimal - slug is not critical for operations  
**Action**: Monitor but don't force populate (data integrity)  
**Next phase**: Could enhance fetch to derive slugs if needed

### Disabled FK Constraint on Coalition_Users

```sql
-- NOTE: This table is in LIVE TRACKING phase (not loaded yet)
-- When populated in next phase, ensure FK constraint:
ALTER TABLE coalitions_users
  ADD CONSTRAINT fk_coalitions_users_coalition
  FOREIGN KEY (coalition_id) REFERENCES coalitions(id) ON DELETE CASCADE;
```

**Reason**: 92,368 orphaned coalition_users records during testing  
**Status**: Not critical now (table empty) but fix before going live  
**Action**: Validate coalitions exist before insert in live phase

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         42 SCHOOL API                            │
│              (token: hourly refresh, auto-recovery)              │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    TOKEN MANAGER (bash)                          │
│   - ensure-fresh (proactive refresh <1h TTL)                    │
│   - call-export (API fetch with 401 recovery)                   │
│   - Logs: /srv/42_Network/logs/42_token_refresh.log             │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    FETCH SCRIPTS (bash)                          │
│   - fetch_cursus.sh (1 API hit)                                 │
│   - fetch_campuses.sh (1 API hit)                               │
│   - fetch_cursus_projects.sh (2-5 API hits)                     │
│   - fetch_campus_achievements.sh (54 API hits)                  │
│   - fetch_coalitions.sh (1 API hit)                             │
│   Output: exports/*/all.json                                    │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    NORMALIZATION (jq)                            │
│   - Filter to 54 active campuses                                │
│   - Extract relationships (campus_projects, etc)                │
│   - Validate required fields                                    │
│   Output: Structured JSON ready for load                        │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    DELTA STAGING (SQL)                           │
│   - TRUNCATE *_delta tables                                     │
│   - COPY from JSON into _delta tables                           │
│   - Validate constraints, FK references                         │
│   Status: 8 empty delta tables ready for next sync              │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    PRODUCTION TABLES (PostgreSQL)                │
│   ✅ cursus (1)                                                  │
│   ✅ campuses (54)                                               │
│   ✅ projects (519)                                              │
│   ✅ coalitions (350)                                            │
│   ✅ achievements (1042)                                         │
│   ✅ campus_projects (20937)                                     │
│   ✅ campus_achievements (5495)                                  │
│   ✅ project_sessions (7256)                                     │
│   Status: STABLE, all indexed, all validated                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## File Structure & Navigation

```
/srv/42_Network/
├── repo/
│   ├── scripts/
│   │   ├── token_manager.sh              ← Token auth (call/refresh/ensure-fresh)
│   │   ├── check_db_integrity.sh         ← Validation (run anytime)
│   │   ├── config/
│   │   │   └── logging.conf              ← Centralized log config
│   │   ├── cron/
│   │   │   ├── nightly_stable_tables.sh  ← 01:00 UTC (full pipeline)
│   │   │   └── rotate_logs.sh            ← 02:00 UTC (log cleanup)
│   │   ├── helpers/
│   │   │   ├── fetch_*.sh                ← API fetch scripts (6 total)
│   │   │   └── extract_*.sh              ← Relationship extraction
│   │   └── update_stable_tables/
│   │       ├── update_all_cursus_21_core.sh  ← ORCHESTRATOR
│   │       ├── update_cursus.sh
│   │       ├── update_campuses.sh
│   │       ├── update_projects.sh
│   │       ├── update_coalitions.sh
│   │       └── update_campus_achievements.sh
│   ├── data/
│   │   └── schema.sql                    ← Complete schema (8 stable + 4 live tables)
│   ├── exports/                          ← JSON data files (all.json per table)
│   ├── docs/                             ← Architecture & guide docs
│   ├── PRE_PHASE_END_ANALYSIS.md         ← Comprehensive analysis
│   ├── README.md                         ← Main documentation
│   └── docker-compose.yml                ← PostgreSQL 16 config
│
├── logs/                                  ← All logs (NOT in repo)
│   ├── 42_token_refresh.log
│   ├── nightly_stable_tables.log
│   ├── update_*.log
│   └── archive/                          ← Compressed old logs
│
└── .env                                   ← Secrets (CLIENT_ID, CLIENT_SECRET, etc)
```

---

## Critical Commands & Debugging

### View Current State

```bash
# Check database tables
docker compose exec -T db psql -U api42 -d api42 -c "SELECT * FROM information_schema.tables WHERE table_schema='public' ORDER BY table_name;"

# View row counts
bash scripts/check_db_integrity.sh

# Check token status
bash scripts/token_manager.sh token-info

# View latest logs
tail -50 /srv/42_Network/logs/nightly_stable_tables.log
tail -50 /srv/42_Network/logs/42_token_refresh.log
```

### Manual Testing

```bash
# Full sync (fresh API data, forced)
cd /srv/42_Network/repo
bash scripts/update_stable_tables/update_all_cursus_21_core.sh --force

# Single table update
bash scripts/update_stable_tables/update_projects.sh

# Check integrity after update
bash scripts/check_db_integrity.sh
```

### Troubleshooting

**Problem**: "Token expired" errors  
**Solution**: `bash scripts/token_manager.sh refresh`  
**Prevention**: Cron runs hourly at :05

**Problem**: Orphaned records detected  
**Solution**: Run with `--force` to refetch all data  
**Prevention**: Active campus filter applied at extraction

**Problem**: Delta table not truncated  
**Solution**: Manually: `docker compose exec -T db psql -U api42 -d api42 -c "TRUNCATE cursus_delta;"`  
**Prevention**: Script does this automatically

---

## Cron Schedule (Locked In)

```crontab
# Every hour at :05 - Token refresh
5 * * * * bash /srv/42_Network/repo/scripts/token_manager.sh refresh >> /srv/42_Network/logs/42_token_refresh.log 2>&1

# Daily at 01:00 UTC - Nightly stable tables update
0 1 * * * bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh >> /srv/42_Network/logs/nightly_stable_tables.log 2>&1

# Daily at 02:00 UTC - Log rotation and cleanup
0 2 * * * bash /srv/42_Network/repo/scripts/cron/rotate_logs.sh >> /srv/42_Network/logs/rotation.log 2>&1
```

---

## API Rate Limits & Load Profile

**Rate Limit**: 120 API calls/hour (hard limit)  
**Soft Limit**: 20-40/minute advisable  

**Current Load**:
- Full sync: ~65 API calls over ~3 minutes ✅
- Token refreshes: 12/hour ✅
- **Total: ~77 calls/hour** (64% of limit, comfortable margin)

**Safety**: Large margin allows for future enhancements without hitting limits

---

## What NOT To Do

🔴 **Don't**: Delete delta tables  
→ They're essential for staging data safely

🔴 **Don't**: Modify active campus filter without review  
→ Will create orphaned records

🔴 **Don't**: Force-populate live tracking tables yet  
→ Schema ready but logic not complete

🔴 **Don't**: Disable FK constraints permanently  
→ Use only for testing; enable before going live

🔴 **Don't**: Skip token refresh  
→ API will return 401 errors after 2 hours

---

## Testing Checklist

Before declaring Live Tracking phase ready:

- [ ] Run full load test (5+ consecutive syncs, ~400 API calls)
- [ ] Verify no 429 rate limit errors
- [ ] Check all logs for errors/warnings
- [ ] Validate row counts stable across runs
- [ ] Test token refresh during long sync
- [ ] Confirm cron jobs executed at scheduled times
- [ ] Verify log rotation working (check archive/)
- [ ] Document any API changes observed

---

## Decision Log

| Date | Decision | Rationale | Status |
|------|----------|-----------|--------|
| 2025-12-12 | Stable databases LOCKED | All validation passed, production ready | ✅ DONE |
| 2025-12-12 | Token refresh auto-implemented | 401 resilience, proactive refresh | ✅ DONE |
| 2025-12-12 | Cron schedule finalized | 01:00 UTC nightly, 02:00 UTC cleanup | ✅ DONE |
| TBD | Live tracking gates | Requires load test approval | ⏳ PENDING |
| TBD | User sync implementation | Needs range[updated_at] logic | ⏳ PENDING |

---

## For Next Session (Claude)

**Start here**:
1. Read PRE_PHASE_END_ANALYSIS.md (comprehensive overview)
2. Check current commit: `git log -1`
3. Verify cron running: `crontab -l`
4. Run integrity check: `bash scripts/check_db_integrity.sh`
5. Review latest logs: `tail -50 /srv/42_Network/logs/nightly_stable_tables.log`

**Key files to understand**:
- `scripts/token_manager.sh` - Core auth & API call logic
- `scripts/update_stable_tables/update_all_cursus_21_core.sh` - Orchestrator
- `data/schema.sql` - Complete schema (stable + live tables)
- `scripts/config/logging.conf` - Logging configuration

**Current status**: 
- Stable tables complete and locked
- Infrastructure production-ready
- All logs centralized and rotating
- Token management automated
- Ready for live tracking phase

---

**Document Version**: 2.0  
**Last Updated By**: Claude (AI Assistant)  
**Date**: December 12, 2025, 15:00 UTC  
**Reviewers**: None (first comprehensive context doc)
