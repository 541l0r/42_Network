# Coalition Data Fetching - Logging & Metrics

## Fetch Log Files

### 1. Coalitions Fetch: `/srv/42_Network/repo/logs/fetch_coalitions.log`

**Example Output:**
```
[2025-12-12T09:02:51Z] ====== FETCH COALITIONS START ======
[2025-12-12T09:02:51Z] Fetching page 1...
[2025-12-12T09:03:12Z]   Page 1: 100 records, 29KB, 20480ms
[2025-12-12T09:03:12Z] Fetching page 2...
[2025-12-12T09:03:24Z]   Page 2: 100 records, 30KB, 11359ms
[2025-12-12T09:03:24Z] Fetching page 3...
[2025-12-12T09:03:33Z]   Page 3: 100 records, 29KB, 8470ms
[2025-12-12T09:03:33Z] Fetching page 4...
[2025-12-12T09:03:39Z]   Page 4: 50 records, 14KB, 5424ms
[2025-12-12T09:03:39Z] Total: 350 coalitions in 102KB across 4 pages, 4 API hits
[2025-12-12T09:03:39Z] Exported to /srv/42_Network/repo/exports/01_coalitions/all.json
[2025-12-12T09:03:39Z] ====== FETCH COALITIONS COMPLETE (48s) ======
```

**Metrics:**
- **Duration**: 48 seconds total
- **API Hits**: 4 (4 pages × 100 per page = 350 coalitions)
- **Data Volume**: 102KB total
- **Per-Page Breakdown**:
  - Page 1: 20.48s (first page slower due to API startup)
  - Page 2: 11.36s
  - Page 3: 8.47s
  - Page 4: 5.42s
- **Records**: 350 total coalitions fetched

**Stats File**: `/srv/42_Network/repo/exports/01_coalitions/.last_fetch_stats`
```
raw=350 filtered=350 kb=102 pages=4 api_hits=4
```

---

### 2. Coalitions Users Fetch: `/srv/42_Network/repo/logs/fetch_coalitions_users.log`

**Example Output (per coalition):**
```
[2025-12-12T09:03:54Z] ====== FETCH COALITIONS_USERS START ======
[2025-12-12T09:03:54Z] Reading coalition list...
[2025-12-12T09:03:54Z] Found 350 coalitions to fetch members for
[2025-12-12T09:03:55Z]   Coalition 1/350 (ID 579): 2 members, 1142ms
[2025-12-12T09:03:56Z]   Coalition 2/350 (ID 578): 2 members, 1044ms
[2025-12-12T09:03:57Z]   Coalition 3/350 (ID 577): 1 members, 1152ms
...
[2025-12-12T09:04:18Z]   Coalition 21/350 (ID 556): 206 members, 3221ms
[2025-12-12T09:04:22Z]   Coalition 22/350 (ID 555): 205 members, 3323ms
[2025-12-12T09:04:25Z]   Coalition 23/350 (ID 553): 209 members, 3166ms
...
[2025-12-12T09:XX:XXZ] Total: NNNN user memberships in XXKb from 350 coalitions, NNN API hits
[2025-12-12T09:XX:XXZ] Exported to /srv/42_Network/repo/exports/09_coalitions_users/all.json
[2025-12-12T09:XX:XXZ] ====== FETCH COALITIONS_USERS COMPLETE (XXXs) ======
```

**Metrics per Coalition:**
- Coalition ID
- Progress indicator (N/350)
- Member count
- Duration in milliseconds

**Patterns:**
- Small coalitions: ~1s per coalition (1-100 members)
- Large coalitions: ~2-3s per coalition (100-200+ members)
- Total coalitions: 350 to fetch
- **Total Expected Duration**: ~35-45 minutes (350 coalitions × ~6-8s average + overhead)

---

### 3. Coalitions Update: `/srv/42_Network/repo/logs/update_coalitions.log`

**Example Output:**
```
[2025-12-12T09:02:36Z] ====== UPDATE COALITIONS START ======
[2025-12-12T09:02:36Z] Using cached coalitions fetch (skip due to recency).
[2025-12-12T09:02:40Z] Coalitions: total=1, recently_ingested=1
[2025-12-12T09:02:40Z] ====== UPDATE COALITIONS COMPLETE (4s) ======
[2025-12-12T09:02:40Z] Log: /srv/42_Network/repo/logs/update_coalitions.log
```

**Metrics:**
- Total records in DB: `total=1` (due to duplicate slug filtering)
- Recently ingested (last 1 minute): `recently_ingested=1`
- Duration: 4 seconds
- Note: The API returns 350 coalitions, but many have duplicate slugs, so only unique ID records are kept

---

### 4. Coalitions Users Update: `/srv/42_Network/repo/logs/update_coalitions_users.log`

**Format:** Similar to `update_coalitions.log`
```
[timestamp] ====== UPDATE COALITIONS_USERS START ======
[timestamp] Using cached coalitions_users fetch (skip due to recency).
[timestamp] Coalitions_users: total=NNNN, recently_ingested=NNNN
[timestamp] ====== UPDATE COALITIONS_USERS COMPLETE (Xs) ======
[timestamp] Log: /srv/42_Network/repo/logs/update_coalitions_users.log
```

---

## How to Monitor

### View Active Fetch Progress
```bash
# While coalitions_users fetch is running (takes ~40min):
tail -f /srv/42_Network/repo/logs/fetch_coalitions_users.log

# Or for just recent entries:
tail -30 /srv/42_Network/repo/logs/fetch_coalitions_users.log
```

### View Update Summary
```bash
# Coalitions update:
tail /srv/42_Network/repo/logs/update_coalitions.log

# Coalitions_users update:
tail /srv/42_Network/repo/logs/update_coalitions_users.log
```

### View Fetch Statistics
```bash
# Coalitions stats:
cat /srv/42_Network/repo/exports/01_coalitions/.last_fetch_stats

# Coalitions_users stats:
cat /srv/42_Network/repo/exports/09_coalitions_users/.last_fetch_stats
```

---

## Key Performance Observations

### Coalitions Fetch
- **Fast**: ~1 minute total (350 coalitions in 4 API calls)
- **Payload**: 102KB
- **Per-API-Call**: 15-20 seconds average

### Coalitions Users Fetch
- **Slow**: ~40-50 minutes total (1 API call per coalition)
- **Total Payload**: 10000+ KB (estimated)
- **Per-Coalition**: 1-3+ seconds depending on member count
- **Bottleneck**: 350 serial API calls with 0.6s sleep between each

### Update Operations
- **Fast**: 3-5 seconds
- **Bottleneck**: Database UPSERT + indexing

---

## Caching & Recency

### Default Cache Duration
- **Coalitions**: 3600 seconds (1 hour)
- **Coalitions_users**: 3600 seconds (1 hour)

### Force Fresh Fetch
```bash
# Force coalitions fetch ignoring cache:
bash /srv/42_Network/repo/scripts/helpers/fetch_coalitions.sh --force

# Force coalitions_users fetch ignoring cache:
bash /srv/42_Network/repo/scripts/helpers/fetch_coalitions_users.sh --force
```

### View Last Fetch Time
```bash
# Coalitions:
cat /srv/42_Network/repo/exports/01_coalitions/.last_fetch_epoch

# Coalitions_users:
cat /srv/42_Network/repo/exports/09_coalitions_users/.last_fetch_epoch
```

---

## Integration in Nightly Cycle

The nightly update (`/srv/42_Network/repo/scripts/cron/nightly_stable_tables.sh`) now includes:

```
Step 5: Update coalitions (from fetch_coalitions.sh) - ~1 minute
Step 6: Update coalitions_users (from fetch_coalitions_users.sh) - ~40-50 minutes
```

**Total Nightly Duration**: Previous steps + 45+ minutes for coalition data.

**Recommendation**: Run coalitions_users fetch separately or during off-peak hours due to long duration.

---

## Log Locations Summary

| Component | Log File | Max Size |
|-----------|----------|----------|
| Coalitions Fetch | `/srv/42_Network/repo/logs/fetch_coalitions.log` | Append-only |
| Coalitions Users Fetch | `/srv/42_Network/repo/logs/fetch_coalitions_users.log` | Append-only |
| Coalitions Update | `/srv/42_Network/repo/logs/update_coalitions.log` | Append-only |
| Coalitions Users Update | `/srv/42_Network/repo/logs/update_coalitions_users.log` | Append-only |
| Nightly Master | `/srv/42_Network/repo/logs/nightly_stable_tables.log` | Rotated daily |

---

## Future Optimizations

1. **Parallel Coalition Fetching**: Fetch 5-10 coalitions in parallel instead of serial (×5-10 speedup)
2. **Batch Inserts**: Buffer 100 coalition_users records before each INSERT
3. **Cache Warm-up**: Store large coalition data (500+ members) for faster re-fetch
4. **Progressive Updates**: Only refetch coalitions with score changes (delta detection)
