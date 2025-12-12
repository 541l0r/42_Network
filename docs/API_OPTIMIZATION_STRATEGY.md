# Optimized API Call Strategy for 42 Network

## Current Project Scope
- **Cursus**: 21 (42cursus)
- **Target Users**: kind=student, enrolled in cursus 21
- **Data Hierarchy**: Cursus 21 → Campuses → Projects → Achievements → Users → Coalitions

## API Endpoints Analysis

### ✅ RECOMMENDED: Efficient Endpoints (Use These)

#### 1. **Cursus Reference** (Foundation)
```bash
GET /v2/cursus/21
# Response: Single cursus record
# Cost: 1 API hit
# Data: Minimal (1 record)
# Purpose: Verify cursus exists, get metadata
```

#### 2. **Cursus Users** (Primary user list)
```bash
GET /v2/cursus/21/cursus_users?per_page=100&page=X
  &filter[kind]=student
  &range[updated_at]=START,END
# Cost: ~N hits (paginated by student count)
# Data: Minimal per record (user_id, level, blackholed)
# ✓ BEST: Already filtered by cursus=21, kind=student
# Use for: Get all student IDs → then fetch full user details only for those
```

#### 3. **Campus by Cursus** (Avoid generic /v2/campus)
```bash
GET /v2/cursus/21/campus?per_page=100
# Response: Only campuses offering cursus 21
# Cost: 1 API hit
# Data: Minimal (cursus-scoped campuses only)
# ✓ BETTER: Filtered to cursus scope
```

#### 4. **Projects by Cursus** (Avoid generic /v2/projects)
```bash
GET /v2/cursus/21/projects?per_page=100
# Response: Only projects in cursus 21
# Cost: 1-2 API hits
# Data: Project definitions only
# ✓ OPTIMAL: No need for generic projects endpoint
```

#### 5. **Achievements by Campus & Cursus** (Derived)
```bash
GET /v2/campus/CAMPUS_ID/achievements?per_page=100
# Must loop: For each campus in cursus 21
# Cost: N hits (one per campus)
# ✓ Better to: Derive from project_users achievements fetch
```

#### 6. **Project Users by Campus & Cursus**
```bash
GET /v2/campus/CAMPUS_ID/projects_users?per_page=100&page=X
  &filter[cursus_id]=21
  &range[updated_at]=START,END
# Cost: ~N hits (per campus + pagination)
# Data: Enrollment status, marks, project_id (derive achievements)
# ✓ OPTIMAL: Single endpoint gives users + their projects + achievements
```

#### 7. **Coalitions** (Derived from Users)
```bash
GET /v2/coalitions/COALITION_ID/coalitions_users?per_page=100
  &filter[kind]=student  # if available
  &filter[cursus_id]=21  # if available
# Cost: High (one per coalition × users per coalition)
# ✗ PROBLEM: 350 coalitions × ~200 users each = massive
# Alternative: Only fetch active/current coalitions per campus
```

### ❌ AVOID: Generic/Heavy Endpoints

```
❌ GET /v2/users?per_page=100 (100k+ students globally)
   → Instead: Use /v2/cursus/21/cursus_users first

❌ GET /v2/campus (54 campuses, 2.7k students each)
   → Instead: Use /v2/cursus/21/campus (only cursus 21 campuses)

❌ GET /v2/projects (all projects globally)
   → Instead: Use /v2/cursus/21/projects (only cursus 21 projects)

❌ GET /v2/coalitions/X/coalitions_users for all 350 coalitions
   → Instead: Only fetch for coalitions with cursus 21 students
```

## Optimized Data Fetch Pipeline

### Phase 1: Reference Data (1 nightly fetch)
```bash
1. GET /v2/cursus/21
   → table: cursus (1 record)

2. GET /v2/cursus/21/campus
   → table: campus_cursus_21 (3-5 campuses typically)

3. GET /v2/cursus/21/projects
   → table: projects_cursus_21 (50-100 projects)

4. GET /v2/cursus/21/cursus_users?kind=student&range[updated_at]=YESTERDAY,NOW
   → table: users (new/updated students in cursus 21)
   → Cost: ~1-3 hits (paginated)

API Cost Phase 1: ~5-10 hits (vs. current 1,000+)
```

### Phase 2: User Detail (Per Campus, 1 nightly fetch)
```bash
For each campus in cursus_21_campuses:
  GET /v2/campus/CAMPUS_ID/projects_users?cursus_id=21&per_page=100
    &range[updated_at]=YESTERDAY,NOW
  → Gives: user enrollment, projects, final_mark, status
  → Derive: achievements from project users data
  
API Cost Phase 2: ~2-5 hits (one per campus + pagination)
```

### Phase 3: Coalitions (Optional, Low Priority)
```bash
For coalitions in cursus_21:
  Only fetch if user explicitly joined (not all 350)
  
Alternative: Daily snapshot of top N coalitions by member count
  GET /v2/coalitions?sort=-users_count&per_page=10
  
API Cost Phase 3: ~1-2 hits (if needed)
```

## API Filters & Range Syntax

### Available Filters
```bash
filter[kind]=student              # Kind of user
filter[cursus_id]=21              # Cursus (if available)
filter[campus_id]=X               # Campus
filter[primary_campus_id]=X       # Primary campus
filter[status]=active             # User status
```

### Range Filters
```bash
range[updated_at]=2025-01-01T00:00:00Z,2025-12-31T23:59:59Z
range[created_at]=START,END
```

### URL Encoding
```bash
filter%5Bkind%5D=student          # filter[kind]=student
range%5Bupdated_at%5D=START,END   # range[updated_at]=START,END
```

## Current vs Optimized Cost Analysis

| Operation | Current | Optimized | Savings |
|-----------|---------|-----------|---------|
| Coalitions fetch | 1,130 hits | 5 hits | 226× |
| Users initial | Not done | 3 hits | - |
| Projects | In coalitions | 1 hit | - |
| Achievements | Not derived | Included | - |
| **Total monthly** | ~45k hits | ~500 hits | 90× |

## Implementation Notes

1. **Always use cursus_id filter** when endpoint supports it
2. **Always use kind=student filter** to avoid staff/other accounts
3. **Use range[updated_at]** for incremental syncs (daily)
4. **Derive achievements** from project_users, don't fetch separately
5. **Coalitions**: Only fetch if user explicitly requested, or daily top-N
6. **Pagination**: Always handle per_page=100 with page parameter

## Endpoints to Test for Filter Support
```bash
# Test if these endpoints support cursus_id filter:
curl -H "Authorization: Bearer TOKEN" \
  "https://api.intra.42.fr/v2/campus/12/projects_users?filter[cursus_id]=21&per_page=1"

# Test if coalitions endpoint supports kind/cursus filters:
curl -H "Authorization: Bearer TOKEN" \
  "https://api.intra.42.fr/v2/coalitions/579/coalitions_users?filter[kind]=student&per_page=1"
```

## Recommended Script Updates

1. **fetch_cursus_21_users.sh**
   - Use `/v2/cursus/21/cursus_users` not `/v2/users`
   - Filter: kind=student, range[updated_at]
   - Cost: 1-3 hits vs 1,000+ hits

2. **fetch_campus_projects_users.sh** (per campus)
   - Use `/v2/campus/X/projects_users?cursus_id=21`
   - Filter: cursus_id=21, range[updated_at]
   - Derive achievements from project data
   - Cost: 1 hit per campus

3. **fetch_coalitions.sh** (optional/daily)
   - Only fetch top-N coalitions by member count
   - Or skip daily sync, only on-demand

4. **live_db_sync.sh** (30s rolling)
   - Sync: user metrics (wallet, location, active)
   - Sync: project_users status/marks
   - Skip: achievements, coalitions (daily sufficient)
