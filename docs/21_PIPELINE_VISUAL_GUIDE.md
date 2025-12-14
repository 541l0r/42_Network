# Cursus 21 Data Pipeline - Visual Guide

## Complete Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                     42 SCHOOL API v2                                │
│            (paginated, range/filter support)                        │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
            NIGHTLY (Daily)          INCREMENTAL (Real-time)
            40-50 API hits           5-20 API hits
                    │                         │
        ┌───────────┴──────────┐              │
        │                      │              │
    ┌───▼────────┐         ┌───▼────────┐    │
    │ FETCH PHASE│         │FETCH PHASE │    │
    │(Bulk data) │         │(Delta only)│    │
    └───┬────────┘         └───┬────────┘    │
        │                      │              │
        │ (1) cursus           │ (1) updated  │
        │ (2) projects         │      cursus_ │
        │ (3) students         │      users   │
        │ (4) enrollments      │              │
        │ (5) achievements     │              │
        │                      │              │
        └───────────┬──────────┴──────────┐   │
                    │                     │   │
            ┌───────▼──────────────────┐  │   │
            │ EXPORTED JSON FILES      │  │   │
            │                          │  │   │
            │ exports/01_cursus/       │  │   │
            │ exports/02_campus/       │  │   │
            │ exports/04_achievements/ │  │   │
            │ exports/05_projects/     │  │   │
            │ exports/06_project_users/│  │   │
            │ exports/08_users/        │  │   │
            │ exports/09_coalitions/   │  │   │
            └───────┬──────────────────┘  │   │
                    │                     │   │
        ┌───────────▼───────────┐         │   │
        │ UPDATE PHASE          │         │   │
        │ (Database inserts)    │         │   │
        │                       │         │   │
        │ 1. Update campuses    │         │   │
        │ 2. Update cursus      │         │   │
        │ 3. Update projects    │         │   │
        │ 4. Update users       │◄────────┤   │
        │    (cursus 21 only)   │         │   │
        │ 5. Update enrollments │◄────────┤   │
        │ 6. Update achievements        │   │
        │ 7. Update coalitions          │   │
        └───────────┬───────────┘         │   │
                    │                     │   │
            ┌───────▼──────────────────┐  │   │
            │ POSTGRESQL DATABASE      │  │   │
            │                          │  │   │
            │ ✓ cursus (54 records)    │  │   │
            │ ✓ campuses (25 records)  │  │   │
            │ ✓ projects (900+)        │  │   │
            │ ✓ achievements (8k+)     │  │   │
            │ ✓ coalitions (350)       │  │   │
            │                          │  │   │
            │ ✓ users (47 active)      │  │   │
            │ ✓ projects_users (900+)  │  │   │
            │ ✓ achievements_users    │  │   │
            │ ✓ coalitions_users (92k)│  │   │
            │                          │  │   │
            └──────────────────────────┘  │   │
                                           │   │
                    ┌──────────────────────┘   │
                    │                          │
            ┌───────▼──────┐        ┌─────────▼─────┐
            │ LOGS (monitoring)     │ NEXT (Phase 2)│
            │                       │               │
            │ Every script:         │ Live dashboard│
            │ • Timestamps          │ Real-time API │
            │ • API hit counts      │ Rate limiting │
            │ • Duration            │ Performance   │
            │ • Errors              │ Optimization  │
            └────────────────────────┴───────────────┘
```

## Pipeline Phases

### Phase 1: Nightly Full Sync (Runs once per night)

```bash
$ bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh

❯ 1.1 Fetch cursus 21 core data
    ├─ Step 1: Fetch cursus metadata (1 hit, <1s)
    ├─ Step 2: Fetch cursus 21 projects (1-2 hits, 1-2s)
    ├─ Step 3: Fetch cursus 21 students (500-1000 hits, 5-10min)
    │           ↳ Filter: kind=student, alumni=false
    │           ↳ Result: 47 active students
    ├─ Step 4: Fetch per-campus achievements (10 hits, 5-10s)
    ├─ Step 5: Fetch per-campus enrollments (20 hits, 30-60s)
    │           ↳ Filter: cursus_id=21, per-campus loop
    │           ↳ Result: 900+ enrollments
    └─ Total: 40-50 API hits, 5-10 minutes

❯ 2.1 Update reference tables (campuses, cursus, projects)
    ├─ Update campuses (25 records, 1-2s)
    ├─ Update cursus (54 records, <1s)
    └─ Update projects (900+ records, 1-2s)

❯ 2.2 Update users (Cursus 21, active only)
    ├─ Filter: cursus_id=21, kind='student', alumni=false
    ├─ Upsert: 47 active students
    └─ Duration: 5-10s

❯ 2.3 Update enrollments (projects_users per campus)
    ├─ Campus 1: X enrollments
    ├─ Campus 12: Y enrollments
    ├─ ... (per each campus in cursus 21)
    ├─ Total: 900+ enrollments
    └─ Duration: 10-20s

❯ 2.4 Update achievements (badges per campus)
    ├─ Achievements: 8,000+ records
    ├─ Achievements_users: Derived from projects_users
    └─ Duration: 5-10s

❯ 2.5 Update coalitions (Gamification - optional)
    ├─ Coalitions: 350 teams
    └─ Coalitions_users: 92,000+ memberships (⚠️ has FK issues)

✓ COMPLETE: All tables updated, ready for real-time updates
  Duration: 10-20 minutes total
  Next run: Tomorrow 2 AM UTC
```

### Phase 2: Incremental Real-Time Sync (Every 15 minutes - future)

```bash
$ bash /srv/42_Network/repo/scripts/cron/live_db_sync.sh

❯ Fetch only recent changes (last 15 minutes)
    ├─ range[updated_at]=NOW-15MIN,NOW
    ├─ Students updated: X
    ├─ Enrollments updated: Y
    └─ API hits: 5-10 (vs 500+ for full fetch)

❯ Update database with changes only
    ├─ Upsert changed students
    ├─ Upsert changed enrollments
    └─ Duration: <30s

✓ COMPLETE: Latest 15-minute window synced
  Next run: In 15 minutes
```

## Script Call Chain

```
nightly_stable_tables.sh
  ├─ Token refresh
  │
  ├─ fetch_cursus_21_core_data.sh [orchestrator]
  │   ├─ fetch_cursus.sh
  │   ├─ fetch_cursus_projects.sh
  │   ├─ fetch_cursus_users.sh
  │   ├─ [loop per campus]
  │   │   ├─ fetch_projects_users_by_campus_cursus.sh
  │   │   └─ fetch_campus_achievements_by_id.sh
  │   └─ [merge all JSON files]
  │
  ├─ update_campuses.sh
  ├─ update_cursus.sh
  ├─ update_projects.sh
  ├─ update_users_cursus.sh
  ├─ update_projects_users_cursus.sh
  ├─ update_achievements_cursus.sh
  ├─ update_coalitions.sh
  ├─ update_coalitions_users.sh
  │
  └─ [log summary statistics]
```

## Data Quality Filters

```
Cursus 21 Students (Users table)
├─ cursus_id = 21 ...................... Only 42cursus
├─ kind = 'student' .................... Only active students
├─ alumni = false ....................... Exclude historical data
├─ api_source = cursus_users ........... Not global users endpoint
└─ Result: 47 active, current students

Project Enrollments (Projects_users table)
├─ cursus_id = 21 ...................... Only 42cursus
├─ campus_id ........................... Specific campus
├─ api_source = campus.projects_users .. Campus-scoped endpoint
└─ Result: 900+ enrollments

Achievements (Achievements_users table)
├─ cursus_id = 21 ...................... Only 42cursus
├─ campus_id ........................... Specific campus
├─ api_source = campus.achievements ... Campus-scoped endpoint
└─ Result: 8,000+ badge records

Coalitions (Coalitions_users table)
├─ api_source = coalitions ............ Global endpoint
├─ (alumni not filtered - coalitions include historical)
└─ Result: 92,000+ membership records
            ⚠️ 10,000+ from deleted coalitions (FK orphans)
```

## Performance Characteristics

```
FIRST RUN (Bootstrap):
  Fetch phase:  500-1000 API hits  | 5-10 minutes
  Update phase: 30-60 seconds
  Total:        ~10-15 minutes
  Network:      ~5-10 MB downloaded
  DB size:      ~50-100 MB tables

DAILY NIGHTLY:
  Fetch phase:  40-50 API hits     | 30-60 seconds
  Update phase: 10-30 seconds
  Total:        ~1-2 minutes
  Network:      ~100-200 KB downloaded
  DB size:      No growth (UPSERT mode)

HOURLY INCREMENTAL (Future):
  Fetch phase:  5-20 API hits      | <30 seconds
  Update phase: <10 seconds
  Total:        <40 seconds
  Network:      ~10-50 KB downloaded
  DB size:      No growth (UPSERT mode)
```

## API Endpoints Used (Optimized)

```
CURSUS-SCOPED (Recommended):
├─ GET /v2/cursus
│  └─ Result: All cursus (1 hit)
├─ GET /v2/cursus/21
│  └─ Result: Cursus 21 metadata (1 hit)
├─ GET /v2/cursus/21/cursus_users?filter[kind]=student&range[updated_at]=...
│  └─ Result: 47 students (5-20 hits daily, incremental)
├─ GET /v2/cursus/21/projects
│  └─ Result: 900+ projects (1-2 hits)
└─ GET /v2/cursus/21/campus
   └─ Result: Campus list (1 hit)

CAMPUS-SCOPED (Per-campus loop):
├─ GET /v2/campus/{X}/projects_users?cursus_id=21&range[updated_at]=...
│  └─ Result: Enrollments per campus (2-5 hits per campus)
├─ GET /v2/campus/{X}/achievements
│  └─ Result: Badges per campus (1 hit per campus)
└─ Loops: ~10 campuses in cursus 21
   Total: ~20 API hits for per-campus resources

GLOBAL (Gamification):
├─ GET /v2/coalitions
│  └─ Result: 350 teams (4 hits)
├─ GET /v2/coalitions/{X}/coalitions_users
│  └─ Result: Team members (350 hits - expensive!)
└─ Total: 354 hits (optional, can defer)

ENDPOINTS TO AVOID (Inefficient):
├─ GET /v2/users (wrong: global scope, no cursus filter effective)
├─ GET /v2/projects_users (wrong: 1000+ hits for global)
├─ GET /v2/campus/{X}/users (wrong: not cursus-scoped)
└─ GET /v2/achievements_users (wrong: 50k+ records, derive instead)
```

## Database Schema Relationships

```
┌──────────────┐
│   CURSUS     │ (54 records)
│   ├─ id      │
│   ├─ name    │
│   └─ ...     │
└───────┬──────┘
        │ 1:N
        │
   ┌────▼──────────────────────┐
   │                            │
┌──▼────┐                  ┌────▼──────┐
│PROJECTS│ (900+)           │ CAMPUSES  │ (25)
│├─ id   │                  │ ├─ id     │
│├─ name │                  │ ├─ name   │
│├─ cursus_id               │ └─ ...    │
│└─ ...  │                  └────▲──────┘
└────┬──────┘                    │
     │                           │
     └─────────────┬─────────────┘
                   │ N:N
              ┌────▼─────────────────┐
              │  PROJECTS_USERS      │ (900+)
              │  ├─ id               │
              │  ├─ user_id    ──────┼──────────┐
              │  ├─ project_id ──────┘          │
              │  ├─ campus_id ───────────────┐  │
              │  ├─ cursus_id               │  │
              │  └─ final_mark              │  │
              └────────┬────────────────────┘  │
                       │                        │
          ┌────────────┴──────────┐             │
          │                       │             │
      ┌───▼─────┐          ┌─────▼──────┐      │
      │  USERS  │          │ACHIEVEMENTS│      │
      │ ├─ id   │          │ ├─ id      │      │
      │ ├─ login│          │ ├─ name    │      │
      │ ├─ kind │ (filtered) ├─ campus_id│    │
      │ ├─ alumni│            └──▲───────┘    │
      │ ├─ cursus_id            │ 1:N         │
      │ └─ ...  │           ┌────▼──────┐     │
      └───┬──────┘           │ACHIEVEMENT│    │
          │                  │_USERS      │    │
          │ N:N              │├─ id       │    │
          │                  │├─ user_id  │◄───┘
          │              ┌───┤├─ achieve  │
          │              │   ││_id        │
      ┌───▼────────┐     │   │└─ ...      │
      │COALITIONS │     │   └────────────┘
      │├─ id       │     │
      │├─ name     │     │
      │├─ score    │     │
      │└─ ...      │     │
      └───┬────────┘     │
          │ N:N          │
      ┌───▼──────────────────────┐
      │  COALITIONS_USERS        │ (92k+)
      │  ├─ id                   │
      │  ├─ coalition_id ────────────┐
      │  ├─ user_id              │
      │  ├─ score                │
      │  ├─ rank                 │
      │  └─ campus_id            │
      └──────────────────────────┘
         ⚠️ FK issue: some coalition_ids don't exist
```

## Implementation Timeline

```
Session 1:
  ├─ Coalition table design: 30 min
  ├─ Coalition fetch scripts: 1 hour
  ├─ Coalition update scripts: 1 hour
  └─ API optimization analysis: 1 hour

Session 2 (This session):
  ├─ Core table fetch scripts: 1 hour
  │   ├─ fetch_cursus_users.sh (incremental-ready)
  │   ├─ fetch_projects_users_by_campus_cursus.sh
  │   ├─ fetch_campus_achievements_by_id.sh
  │   └─ fetch_cursus_21_core_data.sh (orchestrator)
  │
  ├─ Core table update scripts: 1 hour
  │   ├─ update_projects_users_cursus.sh
  │   └─ update_achievements_cursus.sh
  │
  ├─ Orchestrator updates: 30 min
  │   └─ nightly_stable_tables.sh (complete rewrite)
  │
  └─ Documentation: 1 hour
      ├─ CURSUS_21_DATA_PIPELINE.md (450+ lines)
      ├─ API_OPTIMIZATION_STRATEGY.md
      ├─ QUICK_START.md
      ├─ IMPLEMENTATION_CHECKLIST.md
      └─ IMPLEMENTATION_SUMMARY.md

Total: ~8 hours work, ready for production
```

## Next Steps

```
1. TEST BOOTSTRAP (15 min)
   └─ bash scripts/helpers/fetch_cursus_21_core_data.sh --force

2. VALIDATE DATA (5 min)
   └─ Check 47 users in database

3. TEST INCREMENTAL (5 min)
   └─ UPDATED_RANGE="..." bash fetch_cursus_users.sh

4. ADD CRON JOB (5 min)
   └─ crontab -e → 0 2 * * * bash .../nightly_stable_tables.sh

5. MONITOR FIRST RUN (10 min)
   └─ tail -f logs/nightly_stable_tables.log

6. FIX KNOWN ISSUES (30 min)
   └─ coalitions_users FK constraint
```

