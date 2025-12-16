# API Hit Breakdown (42 API Request Count)

## Per User Fetched

### Detector (every 65 seconds)
1. **Token Refresh**: 1 call to `/oauth/token` (if expired)
2. **User Detection**: 1-N calls to `/v2/cursus/21/users` with pagination
   - With `updated_at` range filter
   - With `kind=student` filter
   - `per_page=100`
   - **Pagination**: Calls until page returns 0 results
   
**Example**: Finding 68 users with pagination
- Query 1: `/v2/cursus/21/users?range[updated_at]=...&filter[kind]=student&page=1&per_page=100` → 100 users
- Query 2: `/v2/cursus/21/users?range[updated_at]=...&filter[kind]=student&page=2&per_page=100` → 68 users
- Query 3: `/v2/cursus/21/users?range[updated_at]=...&filter[kind]=student&page=3&per_page=100` → 0 users (stop)
- **Total per cycle**: ~3 API calls for ~68 users found

### Fetcher (for each user in fetch_queue)
Per user ID enqueued by detector:
1. **Token Refresh**: 1 call to `/oauth/token` (if expired, shared/cached)
2. **User Fetch**: 1 call to `/v2/users/{ID}` to get full profile
   - Includes `campus_users`, `achievements`, etc.
   - Full JSON saved to cache

**Example**: Fetching 1000 users in 1 hour
- 1000 × `/v2/users/{ID}` calls
- ~1-2 token refresh calls (tokens last 1 hour)
- **Total per user**: 1 API call (token amortized)

---

## Calculation: 1000 req/hour with 3.0s/call

```
3.0 seconds/call = 20 users/min
20 users/min × 60 min = 1200 requests/hour (theoretical)

BUT:
- Detector pagination adds overhead (3 calls for 68 users = 2-3 users per call on average)
- Token refresh overhead (~2 per hour)
- Retry attempts on failures
- Real-world latency (network, DB, jq processing)

ACTUAL: ~1000 req/hour
```

---

## Full Per-Hour Breakdown

### Peak Hour (68 users/cycle)
```
Cycles per hour:     60 min / (65 sec/cycle) = 55 cycles
Users detected:      68 users/cycle × 55 cycles = 3,740 users detected
API calls (detector):
  - Per cycle: 3 API calls (pagination to find 68 users)
  - Total: 3 × 55 = 165 API calls

Users fetched:       ~1000 users/hour (limited by 3.0s/call rate)
API calls (fetcher): 1000 × 1 = 1000 API calls

Token refresh:       2-3 calls/hour (caching, expires after 1h)

TOTAL: 165 + 1000 + 2 = 1167 API calls/hour
```

### Why Only ~1000 Req/Hour Despite 1200 Capacity?

1. **Detector pagination overhead**: Adds 3 extra calls per cycle
2. **Token manager caching**: Shares tokens, reduces refresh calls
3. **Real-world latency**: Network, DB, jq JSON processing
4. **Error handling**: Retries on failures add extra calls
5. **Upserter bottleneck**: Can't consume faster than 1000/hour

---

## Your Token Analysis

**You said**: 
- "Force token refresh 2 times" = 2 × `/oauth/token` calls
- "User embed page 1" = 1 × `/v2/cursus/21/users?page=1` 
- "Details 3" = 3 × `/v2/users/{ID}` calls

**If this is 1 detector + 3 fetcher = 6 total hits per "operation"**:
- But we're hitting 1000+/hour = ~16+ per minute = different pattern

---

## Solution: If Queue Growing at 50+ users/min

**Detector finding**: 68 users/min in peak
**Fetcher capacity**: 20 users/min @ 3.0s/call
**Gap**: 48 users/min accumulating = queue grows 50/min

**Options**:
1. **Increase fetcher**: 3.0s → 2.5s = 24 users/min (still 44/min gap)
2. **Add 2nd fetcher**: 40 users/min total (still 28/min gap)  
3. **Reduce detector**: Filter by campus (reduce by 70%)
4. **Accept queue**: It's a buffer, will drain when peak ends

---

## Command to Track Real API Hits

```bash
# Monitor actual API calls (from token_manager.sh logs)
tail -f /repo/logs/fetcher.log | grep "→ Fetching\|Fetched"

# Count calls per minute
watch -n 60 'grep -c "Fetched user" /repo/logs/fetcher.log'

# Check for 429 (throttle) errors
grep "429\|rate_limit" /repo/logs/fetcher.log

# Token refresh count
grep "oauth/token\|Refreshed token" /repo/logs/token_refresh.log
```
