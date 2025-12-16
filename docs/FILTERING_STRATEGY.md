# Client vs Server-Side Filtering in Detector

## Current Implementation (Your Code)

### Server-Side Filtering (API query parameters)
```bash
endpoint="/v2/cursus/$FILTER_CURSUS_ID/users?range%5Bupdated_at%5D=$START_ISO,$END_ISO&filter%5Bkind%5D=$FILTER_KIND&per_page=100&page=$page&sort=-updated_at"
```

**Filters applied AT THE API:**
- `cursus_id=21`
- `kind=student` 
- `updated_at` range (time window)
- `per_page=100` (pagination)

**Result**: API returns only matching students

### Client-Side Filtering (jq processing)
```bash
# Filter out alumni_p==true (keeps null and false)
accum=$(echo "$accum" | jq '[.[] | select(.alumni_p != true)]')
```

**Filter applied AFTER receiving data:**
- `alumni_p != true` (removes graduates)

**Why jq instead of API?**
- The `alumni_p` field can be `null`, `false`, or `true`
- Server API doesn't have reliable alumni filter
- Client-side: safe to filter in local logic

---

## API Calls Comparison

### Current: Server + Client (Hybrid)
```
1 API call to /v2/cursus/21/users?kind=student&range[updated_at]=...&page=1
  ↓
Server filters: ~100 students returned (from 1000+ total)
  ↓
Client jq: Remove alumni_p==true (might remove 5-10 more)
  ↓
Result: ~90-95 active students
```
**Cost: 1 API call per page (2-3 calls per cycle)**

### Server-Only (if alumni filter existed)
```
1 API call to /v2/cursus/21/users?kind=student&alumni=false&range[updated_at]=...&page=1
  ↓
Server filters: ~90-95 active students
  ↓
Result: Done
```
**Cost: 1 API call per page (same)**

### Client-Only (No server filters)
```
1 API call to /v2/users?page=1  (no filters)
  ↓
Server returns: 100 random users (might include staff, alumni, other cursus)
  ↓
Client jq: Filter by cursus_id, kind, updated_at, alumni_p
  ↓
Result: ~90-95 active students
```
**Cost: 10x more API calls (1000 users to find 100 matching)**

---

## Efficiency Comparison

| Method | API Calls | Data Transferred | Processing | Best For |
|--------|-----------|------------------|------------|----------|
| **Server** | ✅ Low (1-3/cycle) | ✅ Low (~100 per call) | ✅ None needed | Fast, precise |
| **Client** | 🔴 High (10-100+) | 🔴 High (100K+ rows) | ⚠️ High (jq) | Rare edge cases |
| **Hybrid** | ✅ Low (1-3/cycle) | ✅ Low (~100 per call) | ⚠️ Minimal (1 jq filter) | **Optimal** |

---

## Your Current Strategy (Optimal)

```
Server-side:        Client-side:
- cursus_id ✅       - alumni_p ✅
- kind=student ✅    (jq: select(.alumni_p != true))
- updated_at ✅
```

**Why this is best:**
1. API does heavy lifting (filter 1000 users → 100)
2. Client only filters edge cases (alumni field unreliable)
3. Minimal API overhead
4. Minimal client processing

---

## If You Needed to Reduce API Calls Further

### Option 1: Batch Request (Hypothetical)
```bash
# Get 3 users in 1 call instead of 1 per call
/v2/users?ids=123,456,789
# Reduces calls by 3x
```
**Pro**: 3x fewer API calls
**Con**: 42 API might not support batch endpoint

### Option 2: Campus Filter (Server-side)
```bash
endpoint="/v2/cursus/21/users?campus_id=1&kind=student&..."
# Filter by single campus first
# Reduces pagination (might be 1 call instead of 3)
```
**Pro**: Could reduce pagination by 70%
**Con**: Must loop per campus (adds complexity)

### Option 3: Detector Output Filter (Your current approach)
```bash
# Keep current detector logic
# But filter output for campus before fetcher
# Only enqueue 1 campus worth of users per cycle
```
**Pro**: Reduces fetch_queue growth (your current problem!)
**Con**: Some users missed per cycle

---

## Your Backlog Problem (607 users)

**Root cause**: Detector finding 68 users/min, fetcher only 30 users/min

**Solution using filtering:**
1. **Server-side campus filter**: Reduce detector output by 50% (1 campus at a time)
2. **Client-side jq filter**: Remove low-priority users (alumni, staff)
3. **Detector cycle filter**: Only queue 30 users/cycle instead of 68

**Example**:
```bash
# In detect_changes.sh, add campus cycling
for campus in 1 2 3 4; do
  endpoint="/v2/cursus/21/users?campus_id=$campus&kind=student..."
  # Process campus per cycle instead of all at once
  # Spreads 68 users over 2+ cycles
done
```

This reduces queue growth from 38 users/min to ~20 users/min (matches fetcher capacity).

---

## Summary

| Layer | Your Code | Cost | Purpose |
|-------|-----------|------|---------|
| **Server** | cursus, kind, time | ✅ Efficient | Heavy filtering |
| **Client** | alumni_p (jq) | ✅ Minimal | Edge cases |
| **Could add** | campus loop | ⚠️ Medium | Solve backlog |

**Recommendation**: Keep hybrid approach. If backlog problem persists, add campus-based cycling in detector to spread load evenly.
