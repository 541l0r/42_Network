# Solutions for Growing Backlog (607+ users)

## Current State
- **Queue size**: 607 users
- **Detector**: Finding 68 users/cycle (every 65 seconds)
- **Fetcher**: 3.0s/call = 1200 req/hour theoretical, but actual ~20 users/min
- **Rate**: Queue growing ~50+ users/minute during peak

## Option 1: Increase Fetcher Rate (Reduce delay)
**Current**: 3.0s/call (20 users/min capacity)
**Try**: 2.5s/call = 24 users/min
**Try**: 2.2s/call = 27 users/min
**Limit**: API hard cap at 1000 req/hour

**Pros**: Simple, no code changes needed
**Cons**: Risk 429 throttle if detector finds >27 users/min consistently

---

## Option 2: Add 2nd Fetcher Process (Parallel fetchers)
**Current**: 1x fetcher @ 3.0s/call
**New**: 2x fetcher @ 3.0s/call each = 40 users/min total

```bash
# Fetcher A (existing)
cd /repo && bash scripts/agents/fetcher.sh > logs/fetcher-a.log 2>&1 &

# Fetcher B (new, reads same fetch_queue)
cd /repo && bash scripts/agents/fetcher.sh > logs/fetcher-b.log 2>&1 &
```

**Pros**: No API rate increase, parallel processing
**Cons**: Both read same fetch_queue.txt (race conditions on delete)

---

## Option 3: Reduce Detector Input (Filter output)
**Current**: Detecting ALL cursus 21 students with changes

**3a. Campus filter** - Detect only specific campus
```bash
# Modify detect_changes.sh to add campus_id filter
campus_id=SPECIFIC_ID
```
Reduces input by ~70%

**3b. Limits filter** - Limit detection window to smaller groups
```bash
# Fetch only first 500 results instead of all
--page-size=500
```

**Pros**: Reduces load at source
**Cons**: Missed detections for other groups

---

## Option 4: Increase Upserter Capacity
**Current**: 1× upserter (upserter.sh)
**New**: >1 upserter.sh processes/containers

**Impact**: Faster process_queue consumption → fetcher can focus on fetch_queue

---

## Option 5: Batch Fetching (Group API calls)
Instead of 1 user per call:
```
GET /v2/users?ids=123,456,789  (3 users in 1 call)
```
Reduces calls by 3x

---

## Recommended Action Plan (Least Risk)

### Phase 1: Monitor & Verify Peak
```bash
# Watch queue for 10 minutes to understand growth rate
watch -n 30 'wc -l /repo/.backlog/fetch_queue.txt'
```

### Phase 2: Increase Fetcher Rate Incrementally
```bash
# Try 2.5s/call first (24 users/min)
sed -i 's/3.0/2.5/g' /repo/scripts/agents/fetcher.sh
# Restart and monitor for 429 errors
```

### Phase 3: Add 2nd Fetcher if needed
```bash
# Parallel fetcher reading same queue
cd /repo && bash scripts/agents/fetcher.sh > logs/fetcher-b.log 2>&1 &
```

### Phase 4: Campus Filter if queue stays 600+
```bash
# Reduce detector output
# Modify detect_changes.sh to filter by campus
```

---

## Key Metrics to Watch

| Metric | Target | Current |
|--------|--------|---------|
| Detector rate | <27 users/min | 68/65s = 62.8 users/min 🔴 |
| Fetcher capacity | >20 users/min | ~20 users/min 🟡 |
| Queue size | <200 | 607 🔴 |
| API errors (429) | 0 | Unknown ⚠️ |

---

## Decision Tree

1. **Is detector finding 68 users EVERY cycle?**
   - YES → Peak time, expected backlog growth
   - NO → Temporary spike, queue will shrink when peak ends

2. **If permanent high detection rate:**
   - Option A: Increase fetcher rate to 2.5s
   - Option B: Add 2nd fetcher
   - Option C: Filter detector output (campus)

3. **If you hit 429 throttle errors:**
   - Revert to 3.0s
   - Enable campus filtering
   - Accept queue backlog as buffer

---

## My Recommendation

**DO THIS NOW:**
1. Check if 68 users/min is peak hour or sustained baseline
2. If sustained, increase fetcher to 2.5s/call (test 5 min)
3. If 429 errors appear, add 2nd fetcher instead
4. If queue exceeds 800+, apply campus filter

**QUICK TEST:**
```bash
# Change fetcher rate to 2.5s
sed -i 's/RATE_LIMIT_DELAY=3.0/RATE_LIMIT_DELAY=2.5/' /repo/scripts/agents/fetcher.sh
pkill -f fetcher.sh
cd /repo && bash scripts/agents/fetcher.sh >> logs/fetcher.log 2>&1 &

# Watch for 5 minutes
for i in {1..10}; do sleep 30 && wc -l /repo/.backlog/fetch_queue.txt; done

# Check for errors
grep "429\|error\|ERROR" /repo/logs/fetcher.log
```
