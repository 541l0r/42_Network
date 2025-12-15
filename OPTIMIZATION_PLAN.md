# OPTIMIZATION STRATEGY

## Current Architecture (Slow)
```
DETECTOR (every 60s)
├─ Fetch users from API (time window)
├─ Hash fingerprint (ignores timestamps)
├─ Enqueue ALL changed-fingerprint users
└─ No JSON comparison

WORKER (4-second rate limit)
├─ Pop user ID from queue
├─ Fetch full user JSON from API
├─ Compare JSON to snapshot (expensive string comparison)
├─ Upsert to DB
├─ Query DB to get old state (log_db_delta)
├─ Compare DB vs API (more queries for logging)
└─ Calculate and log deltas

BOTTLENECK: Worker does JSON comparison + logging queries
Result: ~9 seconds per user (API bottleneck)
```

## Optimized Architecture (Fast)
```
DETECTOR (every 60s) - OPTIMIZED
├─ Fetch users from API (time window)
├─ For each user:
│  ├─ Calculate fingerprint (ignore timestamps)
│  ├─ Check if JSON snapshot exists AND matches
│  └─ Only enqueue if JSON differs (client-side comparison)
├─ Smaller queue (only true changes)
└─ Detector does the work once

WORKER (4-second rate limit) - SIMPLIFIED
├─ Pop user ID from queue
├─ Fetch full user JSON from API
├─ Upsert to DB (simple INSERT ON CONFLICT)
├─ Export snapshot
└─ Done (no comparison, no logging queries)

BENEFITS:
• Worker = 3-4 seconds per user (API fetch only)
• Smaller queue = fewer workers needed
• Clear separation: detector finds changes, worker applies them
• No redundant comparisons
• No expensive DB queries for logging

EXPECTED SPEEDUP: 2-3x faster
```

## Implementation Steps

### 1. Update Detector Configuration
The detector should use `detect_changes_optimized.sh` instead of `detect_changes.sh`

```bash
# In detector_manager.sh, change:
DETECT_SCRIPT="$ROOT_DIR/scripts/cron/detect_changes_optimized.sh"
```

### 2. Update Worker Configuration  
The worker should use `backlog_worker_optimized.sh` instead of `backlog_worker.sh`

```bash
# In backlog_worker_manager.sh or backlog_worker_wrapper.sh, change:
WORKER_SCRIPT="$ROOT_DIR/scripts/backlog_worker_optimized.sh"
```

### 3. Benefits
- **Detector**: Does JSON comparison once when user is found
- **Worker**: Pure upsert engine, no comparison logic
- **Queue**: Smaller (only truly changed users)
- **Speed**: 2-3x faster throughput
- **Cleaner**: Separation of concerns

## Performance Expectations

### Current
- Per user: 9 seconds (4s rate limit + 5s API response)
- Throughput: ~400 users/hour
- Bottleneck: API response time (5-7s), can't avoid

### Optimized
- Per user: 5-6 seconds (4s rate limit + 1-2s API response + upsert)
- Throughput: ~600-700 users/hour
- No DB queries for comparison
- Smaller queue = more responsive

### If using multiple workers
- 2 workers in parallel: 1200-1400 users/hour
- 3 workers in parallel: 1800-2100 users/hour

## Docker Option?
**Not recommended for this use case:**
- Docker adds 500ms-1s overhead per operation
- Network latency if separate container
- Would negate 2x speedup gain
- Keep local bash scripts for performance
