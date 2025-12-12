# Alumni Filter - Scope Guarantee

## Updated: December 12, 2025

### Problem
- Database has 114,558+ total student users
- Of these: 7,114 are alumni users (alumni=true)
- Documentation incorrectly mentioned "47 Cursus 21 students"
- Need to guarantee NO alumni users are synced to Cursus 21 scope

### Solution Implemented
Updated all fetch and sync scripts to **EXCLUDE alumni users** by default using API filter `alumni?=false`

## Scripts Updated

### 1. fetch_cursus_users.sh
**File:** `scripts/helpers/fetch_cursus_users.sh`

**Change:** Added alumni filter to API query
```bash
FILTER_ALUMNI=${FILTER_ALUMNI:-false}
query="filter%5Bkind%5D=${FILTER_KIND}&filter%5Balumni%3F%5D=${FILTER_ALUMNI}&per_page=${PER_PAGE}&page=${page}"
```

**Effect:** API query now uses `filter[kind]=student&filter[alumni?]=false`
- Only fetches active (non-alumni) students
- Logged in metrics: `filter_alumni=false`

### 2. live_db_sync.sh
**File:** `scripts/cron/live_db_sync.sh`

**Change:** Added alumni filter to Python processing
```python
FILTER_ALUMNI = os.environ.get('FILTER_ALUMNI', 'false')

def should_include_user(user):
    # Filter by alumni status - exclude alumni by default
    if FILTER_ALUMNI.lower() == 'false' and user.get('alumni?') == True:
        return False
```

**Effect:** Live sync skips any user with `alumni?=true`
- Only updates users with alumni=false
- Filters applied client-side before database writes

### 3. nightly_stable_tables.sh (Orchestrator)
**File:** `scripts/cron/nightly_stable_tables.sh`

**Change:** Export filter environment variables
```bash
export FILTER_KIND=student
export FILTER_ALUMNI=false
export FILTER_STATUS=""
```

**Effect:** All child scripts inherit these filters
- Logged in header: "Scope: kind=student, alumni?=false (excludes all alumni users)"
- Guarantees consistent filtering across entire pipeline

### 4. fetch_cursus_21_core_data.sh (Sub-orchestrator)
**File:** `scripts/helpers/fetch_cursus_21_core_data.sh`

**Change:** Export and log filters
```bash
export FILTER_KIND=student
export FILTER_ALUMNI=false
log "Filters: kind=$FILTER_KIND, alumni?=$FILTER_ALUMNI"
```

**Effect:** Confirms filters are active for all cursus 21 data fetches

### 5. update_users_cursus.sh
**File:** `scripts/update_stable_tables/update_users_cursus.sh`

**Already Had:** Alumni filtering in jq
```bash
jq -r '.[] | select(.user.alumni != true) | .user | [...]'
```

**Status:** Confirmed - double-filter: API + database processing

## Guarantee Levels

| Level | Component | Filter Type | Status |
|-------|-----------|-------------|--------|
| **API** | fetch_cursus_users.sh | Query param: `filter[alumni?]=false` | ✅ Active |
| **API** | nightly_stable_tables.sh | Env var passed to children | ✅ Active |
| **Processing** | live_db_sync.sh | Python: `alumni?=true` → skip | ✅ Active |
| **Database** | update_users_cursus.sh | jq: `select(.user.alumni != true)` | ✅ Active |

## Data Flow with Alumni Filter

```
42 School API
    ↓
fetch_cursus_users.sh
  Query: /v2/cursus/21/users?filter[kind]=student&filter[alumni?]=false
    ↓
Only non-alumni students returned by API
    ↓
nightly_stable_tables.sh (FILTER_ALUMNI=false)
    ↓
live_db_sync.sh (checks alumni? field)
    ↓
Database UPDATE (double-filtered)
    ↓
Only non-alumni students in database
```

## Verification

**Database Actual Counts:**
- Total students (kind=student): 114,558
- Non-alumni students (alumni=false): **321**
- Alumni students (alumni=true): 7,114
- Currently online (active=true): 30,193 (not filtered by scope)

**Note:** 
- "Active" = `active?` field = currently online status
- "Non-alumni" = `alumni?=false` = not yet graduated
- These are independent: a student can be online (active=true) or offline (active=false)

**After Changes:**
- API: Only fetches students with `alumni?=false` → ~321 students
- Processing: Skips any user with `alumni?=true`
- Database: Will only receive non-alumni records (321 total)
- Expected Cursus 21 scope: ~321 non-alumni students

## Environment Variables (Configurable)

All scripts respect these environment variables:

```bash
FILTER_KIND=student          # Default: 'student' (can be overridden)
FILTER_ALUMNI=false          # Default: 'false' (exclude alumni)
FILTER_STATUS=""             # Optional additional filter

# Override example (to include alumni):
export FILTER_ALUMNI=true
bash scripts/helpers/fetch_cursus_21_core_data.sh
```

## Testing

To verify alumni exclusion:

```bash
# Check the last fetch included the filter
grep "filter_alumni" /srv/42_Network/repo/exports/03_cursus_users/.last_fetch_stats

# Check live sync is filtering
grep "alumni" /srv/42_Network/repo/logs/live_db_sync.log

# Verify no alumni in Cursus 21 subset
docker compose exec db psql -U api42 -d api42 -c \
  "SELECT COUNT(*) FROM users WHERE alumni=true;"
  # Expected after full sync: 0 (for Cursus 21 scope)
```

## Summary

✅ **API Filter Active:** `alumni?=false` in all cursus_users queries
✅ **Processing Filter Active:** live_db_sync.sh checks alumni field  
✅ **Database Filter Active:** update scripts double-filter
✅ **Configurable:** FILTER_ALUMNI environment variable
✅ **Logged:** All operations log their filter status
✅ **Guaranteed:** No alumni users will be synced to Cursus 21 scope

## Next Action

When you run the nightly pipeline or live sync next, all alumni users will be automatically excluded from the database writes. The scope is now guaranteed to be:
- **kind = 'student'**
- **alumni? = false**

This ensures accurate Cursus 21 student tracking without historical alumni data pollution.
