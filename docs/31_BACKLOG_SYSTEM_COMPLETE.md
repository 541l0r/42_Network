# 🔄 Backlog System - Complete Guide

**Last Updated:** December 13, 2025

Consolidates: `BACKLOG_SYSTEM.md`, `BACKLOG_README.md`, `MIGRATION_ROLLING_TO_BACKLOG.md`

---

## 🎯 What is the Backlog System?

The backlog system is the **Phase 09** dynamic data fetcher that:
- Polls the 42 API every 5 minutes
- Manages a queue of items to fetch
- Retries failed items automatically
- Stages results in `delta_*` tables
- Loads verified data atomically into stable tables

**Key difference from Phases 1-8**: 
- Phases 1-8 = Static metadata (fetch once, cache 24h)
- Phase 9 = Dynamic data (continuous polling)

---

## 📊 Architecture

```
API (42 School)
    ↓ (curl request)
Backlog Queue (JSON)
    ↓ (fetch batch)
Batch Processor (validate JSON)
    ↓ (transform)
Delta Tables (staging area)
    ↓ (COPY statement)
Stable Tables (production)
    ↓
Exports (JSON API cache)
```

---

## 🚀 How It Works

### Step 1: Queue Management
```bash
# Fetch jobs are stored in backlog queue (file or DB)
# Each job = single API call
# Example: fetch /v2/coalitions/42/members?page=3
```

### Step 2: Batch Fetching
```bash
# Backlog worker pulls 10 items at a time
# Configurable: BACKLOG_FETCH_BATCH_SIZE=10
# Rate limited: 2-second delay between batches
```

### Step 3: Validation
```bash
# Each response validated:
# ✓ Valid JSON format
# ✓ Expected fields present
# ✓ Foreign keys referenced exist
# ✓ No duplicate IDs
```

### Step 4: Staging
```bash
# Data inserted into delta_* tables
# delta_coalitions, delta_campus_projects, etc.
# NOT yet in production tables
```

### Step 5: Atomic Load
```bash
# COPY statements move all deltas → stable tables
# All-or-nothing transaction
# If any error: entire batch rolled back
```

### Step 6: Cleanup
```bash
# Delta tables truncated (emptied)
# Ready for next batch
# Exports updated for API clients
```

---

## ⚙️ Configuration

**File**: `scripts/config/backlog_config.sh`

```bash
# ===== FETCH PARAMETERS =====
BACKLOG_FETCH_BATCH_SIZE=10            # Items per batch
BACKLOG_FETCH_DELAY_SECONDS=2          # Delay between batches
BACKLOG_MAX_RETRIES=3                  # Retry failed items
BACKLOG_RETRY_DELAY=5                  # Seconds between retries
BACKLOG_POLL_INTERVAL=300              # 5 minutes

# ===== DATABASE =====
BACKLOG_TABLE_PREFIX="delta_"          # Staging tables
BACKLOG_BATCH_SIZE_LOAD=100            # Rows per COPY
BACKLOG_VALIDATE_FOREIGN_KEYS=true     # FK validation
BACKLOG_USE_TRANSACTIONS=true          # Atomic loads

# ===== MONITORING =====
BACKLOG_ENABLE_METRICS=true
BACKLOG_METRIC_INTERVAL=300            # 5 minutes
BACKLOG_LOG_LEVEL=INFO                 # DEBUG|INFO|WARN|ERROR
```

---

## 🔧 Core Scripts

### backlog_worker.sh
```bash
bash scripts/backlog_worker.sh
```
**Purpose**: Main polling loop
**Runs**: Every 5 minutes (via cron)
**Actions**:
1. Fetch token (refresh if <1h TTL)
2. Pull up to 10 items from queue
3. Fetch each from 42 API
4. Validate results
5. Stage in delta_* tables
6. Load to stable tables
7. Log metrics

### backlog_status.sh
```bash
bash scripts/backlog_status.sh
```
**Purpose**: Queue status report
**Shows**:
- Items in queue (pending)
- Items failed (with errors)
- Items processed (today)
- Success rate %
- Processing time

### backlog_worker_wrapper.sh
```bash
bash scripts/backlog_worker_wrapper.sh
```
**Purpose**: Cron-safe wrapper
**Features**:
- Prevents concurrent runs (flock)
- Handles environment setup
- Redirects output to logs
- Captures errors

---

## 🗂️ Queue Structure

**Queue is stored as**: `exports/09_backlog/queue.json`

```json
{
  "pending": [
    {"type": "coalition_members", "coalition_id": 42, "page": 1},
    {"type": "project_sessions", "project_id": 123, "page": 1}
  ],
  "processing": [],
  "completed": [
    {"type": "coalition_members", "coalition_id": 42, "page": 1}
  ],
  "failed": [
    {"type": "coalition_members", "coalition_id": 42, "page": 2, "error": "401", "retries": 1}
  ]
}
```

---

## 📋 Delta Table Lifecycle

```
Deployment:
├─ All delta_* tables created (empty)

Per Sync Run:
├─ Start: Insert data into delta_*
├─ Middle: Validate foreign keys
├─ Load: COPY from delta_* → stable_*
└─ End: TRUNCATE delta_*

Result: Delta tables always empty between runs
```

**Why delta tables?**
- ✅ Atomic transactions (all-or-nothing)
- ✅ Easy rollback (just truncate)
- ✅ Preserves stable tables during failures
- ✅ Can compare before/after

---

## 🔄 Migration: Rolling → Backlog

**Old system** (Rolling Sync):
- Concurrent fetches per campus
- No queue management
- Unpredictable load
- Hard to resume on failure

**New system** (Backlog):
- Sequential queue processing
- Automatic retry on failure
- Predictable load profile
- Resume from last checkpoint

**Migration details**:
```bash
# Old: fetch_cursus_21_users_all.sh (campus-focused)
# New: backlog_worker.sh (queue-focused)

# Old: users fetched serially per campus
# New: items fetched in batches, campus-agnostic

# Old: failed requests lost
# New: Failed requests stay in queue, auto-retry
```

---

## 🚨 Error Handling

### API Errors (4xx, 5xx)
```
Response: {"error": "404 Not Found"}
Action: Increment retry counter
Result: Item stays in queue, retried up to 3x
```

### Network Errors (timeout)
```
Timeout after 30s
Action: Log as retriable error
Result: Item stays in queue
```

### Validation Errors (bad JSON)
```
Response: Invalid JSON or missing fields
Action: Log error, move to failed queue
Result: Manual review needed, don't auto-retry
```

### Database Errors (FK violation)
```
COPY failed: Foreign key not found
Action: Rollback all deltas, log error
Result: Item stays in queue, retry next cycle
```

---

## 📊 Performance Characteristics

| Metric | Value | Notes |
|--------|-------|-------|
| Batch size | 10 items | Configurable |
| Delay/batch | 2 seconds | Prevents API overwhelming |
| Retry limit | 3 attempts | Per failed item |
| Poll interval | 5 minutes | Frequency of runs |
| Full queue size | ~10,000 items | Depends on scope |
| Time to process | ~3-5 minutes | For full queue |
| API calls/run | ~100-150 calls | Varies with batch size |

---

## ✅ When to Use Backlog

**Use backlog for**:
- Dynamic data (coalitions, members, sessions)
- High-volume polling (>1000 items)
- Auto-retry on transient failures
- Observability of queue depth

**Don't use backlog for**:
- Static metadata (phases 1-8)
- One-time bulk imports
- Real-time <1min updates

---

## 🔗 Related Documentation

- **Configuration**: `00_CONFIGURATION_CONSOLIDATED.md`
- **Monitoring**: `02_MONITORING_CONSOLIDATED.md`
- **Pipeline**: `CURSUS_21_DATA_PIPELINE.md`
- **Commands**: `COMMAND_REFERENCE.md`
