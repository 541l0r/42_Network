# Cursus 21 Data Pipeline - Complete Guide

## Overview

This document describes the complete data synchronization pipeline for **Cursus 21 (42cursus)** - the primary 42 School curriculum. The pipeline is optimized to:

- **Minimize API calls**: ~40-50 hits per night (vs 1,130+ for inefficient full-scan approach)
- **Scope correctly**: Only students (kind=student), active only (alumni=false), cursus 21 only
- **Support incremental sync**: Daily updates using range[updated_at] filters
- **Maintain data integrity**: Proper dependency order, foreign key constraints, deduplication

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│              42 School API v2                               │
│  (paginated, supports range/filter parameters)              │
└────────────────────┬────────────────────────────────────────┘
                     │
       ┌─────────────┴─────────────┐
       │                           │
   NIGHTLY FETCH             INCREMENTAL FETCH
   (40-50 API hits)          (real-time, 5-20 hits daily)
       │                           │
       ├─ cursus metadata          ├─ cursus_users range[updated_at]
       ├─ cursus projects          ├─ projects_users range[updated_at]
       ├─ cursus students          ├─ achievements_users range[updated_at]
       ├─ per-campus achievements  │
       ├─ per-campus enrollments   │
       └─ coalitions (optional)    │
                     │
       ┌─────────────┴──────────────┐
       │                            │
   ┌───▼───────────────────────────▼──┐
   │   DATABASE (PostgreSQL)           │
   │                                   │
   │ Reference (stable):               │
   │  • cursus                         │
   │  • campuses                       │
   │  • projects                       │
   │  • achievements                   │
   │  • coalitions                     │
   │                                   │
   │ Primary data (daily update):      │
   │  • users (cursus 21)              │
   │  • projects_users (enrollments)   │
   │  • achievements_users (badges)    │
   │  • coalitions_users (teams)       │
   └───────────────────────────────────┘
```

## Data Tables & Relationships

### Reference Tables (Stable - updated nightly)

**cursus** - Curriculum metadata
- PK: id (21 for 42cursus)
- Fields: name, slug, description, duration, capacity
- Updated: Nightly (1 hit to `/v2/cursus`)
- Dependency: None (foundation)

**campuses** - School locations  
- PK: id (1, 12, 13, 14, 16, 20, 21, 22, 25, 26, 28, 29, 30, ...)
- Fields: name, city, country, language, time_zone
- Updated: Nightly (1 hit to `/v2/campuses`)
- Dependency: None (foundation)

**projects** - Curriculum projects
- PK: id
- Fields: name, slug, description, circle (difficulty)
- Updated: Nightly (1-2 hits to `/v2/cursus/21/projects`)
- Dependency: cursus
- Note: Cursus-scoped, not global

**achievements** - Badges/awards
- PK: id
- Fields: name, description, image, campus_id
- Updated: Nightly (1-2 hits per campus to `/v2/campus/X/achievements`)
- Dependency: None
- Note: Per-campus

**coalitions** - Team/group metadata
- PK: id
- Fields: name, slug, image_url, cover_url, color, score, user_id
- Updated: Nightly (4 hits to `/v2/coalitions`)
- Dependency: None
- Note: Gamification, optional

### Primary Data Tables (Dynamic - updated nightly + incremental)

**users** - Student profiles
- PK: id
- Fields: email, login, first_name, last_name, kind, alumni, image links...
- Updated: Nightly (500-1000 hits first time, then 5-20 daily via `/v2/cursus/21/cursus_users?filter[kind]=student`)
- Dependency: cursus
- Filter: kind=student AND alumni=false
- Scope: Cursus 21 only

**projects_users** - Enrollment records
- PK: id
- Fields: user_id, project_id, cursus_id, campus_id, final_mark, status, occurrence
- Updated: Nightly (2-5 hits per campus to `/v2/campus/X/projects_users?cursus_id=21&filter[kind]=student`)
- Dependency: users, projects, cursus, campuses
- Scope: Cursus 21 + campus-specific

**achievements_users** - Badge enrollments
- PK: id
- Fields: user_id, achievement_id, cursus_id, created_at, updated_at
- Updated: Nightly (derived from campus achievements)
- Dependency: users, achievements
- Scope: Cursus 21

**coalitions_users** - Team membership
- PK: id
- Fields: coalition_id, user_id, score, rank, campus_id
- Updated: Nightly (from `/v2/coalitions/X/coalitions_users`)
- Dependency: coalitions, users
- Note: Gamification feature, optional daily update

## API Endpoints & Hit Count

### Cursus 21 Endpoints (Recommended - scoped, efficient)

| Endpoint | Purpose | Hits | Pagination | Filter Support |
|----------|---------|------|-----------|-----------------|
| `/v2/cursus` | Get all cursus | 1 | No | - |
| `/v2/cursus/21` | Get cursus 21 | 1 | No | - |
| `/v2/cursus/21/cursus_users?filter[kind]=student` | Cursus 21 students | 500-1000 (first), 5-20 (daily) | Yes (100/page) | kind, alumni, range[updated_at] |
| `/v2/cursus/21/projects` | Cursus 21 projects | 1-2 | Yes (100/page) | - |
| `/v2/cursus/21/campus` | Cursus 21 campuses | 1-2 | Yes | - |
| `/v2/campus/X/projects_users?cursus_id=21` | Enrollments for cursus 21 | 2-5 per campus | Yes | cursus_id, range[updated_at] |
| `/v2/campus/X/achievements` | Campus badges | 1 per campus | Yes | - |
| `/v2/coalitions` | All teams | 4 | Yes (100/page) | - |
| `/v2/coalitions/X/coalitions_users` | Team members | 350 total | Yes | - |

### Endpoints to AVOID (Inefficient - global scope)

| Endpoint | Why Avoid | Better Alternative |
|----------|-----------|---------------------|
| `/v2/users?range[cursus_ids]=21` | Returns all users globally, filter ineffective | Use `/v2/cursus/21/cursus_users` |
| `/v2/projects_users?filter[cursus_id]=21` | Global pagination, 1000+ hits | Use `/v2/campus/X/projects_users?cursus_id=21` |
| `/v2/achievements_users` | No cursus filter, 50k+ records | Derive from projects_users |
| `/v2/campus/X/users` | Not scoped by cursus | Use `/v2/cursus/21/cursus_users` |

### Daily Incremental Sync Cost

Using `range[updated_at]=YESTERDAY,NOW` filters:
- Users changed: ~5-20 hits (vs 500-1000 for full)
- Projects_users changed: ~2-5 per campus (vs 2-5 for full)
- Coalitions changed: ~1-5 hits (vs 4 for full)
- **Total daily**: ~20-50 hits (vs 1,130+ for non-optimized)

## Data Pipeline Phases

### Phase 1: Nightly Fetch (runs 2 AM UTC)

```bash
bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh
```

**Sub-phase 1.1: Fetch Core Data** (~40-50 API hits, ~5-10 min)
```
Step 1: Fetch cursus metadata (1 hit)
Step 2: Fetch cursus 21 projects (1-2 hits)
Step 3: Fetch cursus 21 students (500-1000 hits first time, 5-20 after)
Step 4: Fetch per-campus achievements (1 hit per campus, ~10 total)
Step 5: Fetch per-campus projects_users (2-5 per campus, ~20 total)
```

**Sub-phase 1.2: Update Database** (~30-60 sec, depends on data volume)
```
Step 1: Update reference tables (campuses, cursus, projects)
Step 2: Update users (cursus 21, kind=student, alumni=false)
Step 3: Update projects_users (enrollments per campus)
Step 4: Update achievements (badges per campus)
Step 5: Update coalitions (gamification, optional)
```

### Phase 2: Daily Incremental Sync (runs live, real-time)

The `live_db_sync.sh` script (separate cron job) handles real-time updates:
```bash
# Every 5-15 minutes:
bash /srv/42_Network/repo/scripts/cron/live_db_sync.sh
```

For cursus 21 students:
```bash
UPDATED_RANGE="$(date -u -d '15 min ago' +%Y-%m-%dT%H:%M:%SZ),$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
bash /srv/42_Network/repo/scripts/helpers/fetch_cursus_users.sh
```

## Script Inventory

### Fetch Scripts (in `/srv/42_Network/repo/scripts/helpers/`)

| Script | Purpose | API Hits | Duration |
|--------|---------|----------|----------|
| `fetch_cursus.sh` | Fetch all cursus | 1 | <1s |
| `fetch_cursus_projects.sh` | Fetch cursus 21 projects | 1-2 | 1-2s |
| `fetch_cursus_users.sh` | Fetch cursus 21 students (incremental-ready) | 500-1000 / 5-20 | 5-10min / 30s |
| `fetch_projects_users_by_campus_cursus.sh` | Fetch enrollments for campus+cursus | 2-5 | 10-30s |
| `fetch_campus_achievements_by_id.sh` | Fetch badges for campus | 1 | 1-2s |
| `fetch_cursus_21_core_data.sh` | Orchestrator: fetch all core data | 40-50 | 5-10min |

### Update Scripts (in `/srv/42_Network/repo/scripts/update_stable_tables/`)

| Script | Purpose | Input | Output | Duration |
|--------|---------|-------|--------|----------|
| `update_cursus.sh` | Sync cursus reference | exports/01_cursus/all.json | cursus table | <1s |
| `update_projects.sh` | Sync projects reference | exports/05_projects/all.json | projects table | 1-2s |
| `update_campuses.sh` | Sync campuses reference | exports/02_campus/all.json | campuses table | 1-2s |
| `update_campus_achievements.sh` | Sync achievements reference | exports/04_campus_achievements/campus_*/all.json | achievements table | 2-5s |
| `update_users_cursus.sh` | Sync cursus 21 students | exports/08_users/cursus_21/all.json | users table (filtered) | 5-10s |
| `update_projects_users_cursus.sh` | Sync enrollments per campus | exports/06_project_users/cursus_21/campus_*/all.json | projects_users table | 10-20s |
| `update_achievements_cursus.sh` | Sync badge enrollments | achievements tables | achievements_users table | 5-10s |
| `update_coalitions.sh` | Sync team metadata | exports/09_coalitions/all.json | coalitions table | <1s |
| `update_coalitions_users.sh` | Sync team membership | exports/09_coalitions_users/all.json | coalitions_users table | 1-2s |

### Orchestrator Scripts

| Script | Purpose | When | Duration |
|--------|---------|------|----------|
| `fetch_cursus_21_core_data.sh` | Fetch all cursus 21 data | Nightly + incremental | 5-10min / 30s |
| `nightly_stable_tables.sh` | Complete nightly update | 2 AM UTC | 10-20min |
| `live_db_sync.sh` | Real-time incremental | Every 5-15 min | 30s-2min |

## Configuration & Environment Variables

### Fetch Script Vars

```bash
# Cursus ID (default: 21)
export CURSUS_ID=21

# Per-page size (default: 100)
export PER_PAGE=100

# Delay between API calls (default: 0.6s)
export SLEEP_BETWEEN_CALLS=0.6

# Incremental sync range
export UPDATED_RANGE="2025-01-01T00:00:00Z,2025-12-31T23:59:59Z"

# Force fresh fetch (skip cache)
bash fetch_cursus_users.sh --force

# Campus ID for per-campus scripts
export CAMPUS_ID=12
```

### Database Vars

```bash
export DB_HOST=localhost
export DB_PORT=5432
export DB_NAME=api42
export DB_USER=api42
export DB_PASSWORD=api42

# Or use .env file (loaded automatically if exists)
# Location: /srv/42_Network/.env
```

## Data Filters & Scope

### Cursus 21 Student Scope

**Query**: `/v2/cursus/21/cursus_users?filter[kind]=student&per_page=100`

**Filters**:
- cursus_id = 21 (42cursus)
- kind = 'student' (exclude inactive, alumni)
- alumni = false (explicitly, if needed)

**Expected**: 47 active students (as of 2025-01)

### Per-Campus Enrollment Scope

**Query**: `/v2/campus/{X}/projects_users?cursus_id=21&filter[kind]=student&per_page=100`

**Filters**:
- campus_id = {X} (each campus in cursus 21)
- cursus_id = 21 (restrict to this curriculum)
- kind = student (implied from cursus_users filtering)

**Campuses**: 1, 12, 13, 14, 16, 20, 21, 22, 25, 26, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37...

## Implementation Examples

### Bootstrap: Initial Full Fetch

```bash
# Fetch all cursus 21 data (first time)
bash /srv/42_Network/repo/scripts/helpers/fetch_cursus_21_core_data.sh --force

# Update all tables
bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh

# Expected: 500-1000 API hits, 10-15 minutes
```

### Daily Incremental: Just Changes

```bash
# Calculate yesterday's range
START=$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Fetch only changed records
UPDATED_RANGE="$START,$END" bash /srv/42_Network/repo/scripts/helpers/fetch_cursus_users.sh
UPDATED_RANGE="$START,$END" bash /srv/42_Network/repo/scripts/helpers/fetch_projects_users_by_campus_cursus.sh

# Update database
bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh

# Expected: 20-50 API hits, 30-60 seconds
```

### Real-Time Live Sync (Every 5-15 min)

```bash
# Fetch changes in last 15 minutes
START=$(date -u -d '15 min ago' +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

UPDATED_RANGE="$START,$END" bash /srv/42_Network/repo/scripts/helpers/fetch_cursus_users.sh

# Update users table
bash /srv/42_Network/repo/scripts/update_stable_tables/update_users_cursus.sh

# Expected: 5-10 API hits, <30 seconds
```

## Cron Schedule

```bash
# In crontab, add:
0 2 * * * bash /srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh
*/15 * * * * bash /srv/42_Network/repo/scripts/cron/live_db_sync.sh
```

## Monitoring & Logging

All fetch and update scripts log to `/srv/42_Network/repo/logs/`:

```
logs/
  ├─ fetch_cursus.log
  ├─ fetch_cursus_projects.log
  ├─ fetch_cursus_users.log
  ├─ fetch_project_users_campus_cursus.log
  ├─ fetch_campus_achievements.log
  ├─ nightly_stable_tables.log
  ├─ update_users_cursus.log
  ├─ update_projects_users_cursus.log
  ├─ update_achievements_cursus.log
  ├─ update_coalitions.log
  └─ update_coalitions_users.log
```

**Log format**:
```
[2025-01-15T09:30:45Z] Step 1.1: Fetching cursus 21 metadata...
[2025-01-15T09:30:46Z]   Fetching page 1...
[2025-01-15T09:30:46Z]   Page 1: 47 records, 5KB, 234ms
[2025-01-15T09:30:46Z] Total: 47 users in 5KB across 1 pages, 1 API hits
```

Check last fetch:
```bash
tail -f logs/fetch_cursus_users.log
tail -f logs/nightly_stable_tables.log
```

## Troubleshooting

### Issue: High API hit count for daily sync

**Cause**: Range filters not working (full refetch every time)

**Solution**:
1. Verify UPDATED_RANGE format: `YYYY-MM-DDTHH:MM:SSZ,YYYY-MM-DDTHH:MM:SSZ`
2. Check URL encoding: ranges must be percent-encoded
3. Verify cache bypass: if scripts always fetch, `--force` flag overrides

### Issue: Missing projects_users data

**Cause**: Per-campus fetches didn't identify all campuses

**Solution**:
1. List campuses in cursus 21: `jq '.[] | select(.cursus_ids | contains([21])) | .id' exports/02_campus/all.json`
2. Or manually add to `fetch_cursus_21_core_data.sh` CAMPUS_IDS list

### Issue: Orphaned FK records in coalitions_users

**Cause**: Users or coalitions deleted since last sync

**Solution**:
- Option A: Drop `achievements_users` data and re-derive from projects_users (clean)
- Option B: Add WHERE filter to skip missing foreign keys
- Option C: Allow NULL FK constraints (sacrifice integrity)

Recommended: Option A (re-derive from authoritative source)

## Performance Characteristics

### First Run (Bootstrap)

```
Phase 1 (Fetch): 500-1000 API hits, 5-10 minutes
Phase 2 (Update): 30-60 seconds
Total: ~10-12 minutes, ~1MB network
Result: 47 users, 900+ enrollments, 350+ coalitions, ~8k achievements
```

### Daily Nightly Run

```
Phase 1 (Fetch): 40-50 API hits, 30-60 seconds
Phase 2 (Update): 10-30 seconds
Total: ~1-2 minutes, ~100KB network
Result: All changed records synced (typically 0-10 new/modified per day)
```

### Real-Time Incremental (Every 15 min)

```
Fetch: 5-20 API hits, <30 seconds
Update: <10 seconds
Total: <40 seconds, ~20-50KB network
Result: Latest 15-minute window synced
```

## References

- 42 School API v2: https://api.intra.42.fr/apidoc
- Cursus 21 ("42cursus"): Primary curriculum with ~1,500 students globally
- Campus 21: Specific school location in Paris (cursus 21 = global, campus 21 = Paris)
- Incremental sync: `range[updated_at]` is the key to efficiency

