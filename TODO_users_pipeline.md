## User ingestion follow-ups

- Token resilience: ensure every script that calls the 42 API (not just `fetch_users_by_campus.sh`) refreshes the token on 401/revoked responses and retries once. Audit other helpers (`scripts/helpers/*.sh`, cron wrappers) and add the same logic where missing.
- Blackhole data: decide the source for `blackholed_at` (currently only present in detailed `cursus_users` from `/v2/users/:id`); plan a secondary pass if we need that field.
- Cron scheduling: re-enable/reschedule the cron to launch the user fetch once the batch completes and token refresh handling is in place.
- Partial fetch recovery: for any campus that failed mid-run, re-run with `CAMPUS_IDS="<id>" ./scripts/update_users_all_campuses.sh --force` after refreshing the token.

## Post-fetch DB hygiene
- Run integrity checks: row counts per table vs exports, FK consistency, and uniqueness (logins, emails).
- Vacuum/analyze tables after large upserts to keep query plans optimal.
- Spot-check a few users/projects/achievements against API or exports to validate ingestion fidelity.
- Rebuild indexes if needed and review `ingested_at` freshness windows.

## Rate/scale study: fetching ~50k users + linked tables under 1200 req/hour

- User list volume: `/v2/users` (or campus-scoped) at `per_page=100` needs ~500 requests for 50k users. At 1200 req/hour, that fits in ~25 minutes if you pace to ~1 req/3s (allow headroom vs limit). Update helpers to enforce a global throttle (~3s) and backoff on 429.
- Deltas preferred: add `range[updated_at]` to fetch only changed users per day/hour to keep request count low.
- Linked tables strategy:
  - `projects_users`: test multi-id filters (`filter[user_id]=id1,id2,...`). If supported, batch 50–100 IDs per call; otherwise expect 1 call per user (heavy: 50k req) and schedule over many hours/days with resume markers.
  - `achievements_users`: same batching attempt; otherwise per-user calls, throttled.
  - Later `locations` or `coalitions_users`: use available filters (`filter[user_id]` or `filter[coalition_id]`) and batch IDs if the API accepts commas; otherwise per-user with a slow queue.
- Scheduling model: build a queue that (a) resumes from last page/ID, (b) enforces max ~1100 calls/hour (e.g., sleep 3.5s between calls plus adaptive backoff), and (c) retries transient 401/429/500 with jitter.
- Cross-table consistency: fetch users first, then drive downstream fetches from the stored user id list in fixed-size batches to avoid refetching the user list.

## Delta + queue approach (recommended)

- Keep full campus fetches for a nightly/off-peak full sync. For near real-time ingestion, use `range[updated_at]` to fetch only changed users frequently.
- Emit changed user IDs to a queue file (`tmp/user_relations_queue.txt`) and process them via a worker (`scripts/runner/fetch_user_relations_worker.sh`) at a controlled rate with `MAX_PER_RUN_RELATION_USERS`.
- This allows per-user relations to be incremental and avoid full re-scan of large `projects_users` and `achievements_users` endpoints.
- Tune `MAX_PER_RUN_RELATION_USERS` and `CONCURRENCY` to stay under API-limits. For 1200 req/h, prefer < 30 users / 5min run when fetching 2 relations per user.

### Suggested defaults

- `MAX_PER_RUN_RELATION_USERS=25` (per cron run) => yields ~500 users/hour if run every 5 minutes while remaining under API limits (25 users * 2 relations * 12 runs = 600 calls/hour).
- `CONCURRENCY=4` and `SLEEP_BETWEEN_CALLS=0.1` for small per-user endpoints. Increase `SLEEP` or decrease `CONCURRENCY` if you hit 429 or rate-limit errors.

## Coalitions preparation
- Add a `coalitions` table and fetcher to pull coalition metadata before `coalitions_users` ingestion.
- After users are loaded, implement `coalitions_users` fetch (delta-friendly if possible) using user IDs or coalition IDs, respecting rate limits and token refresh logic.

## Pipeline strategy evolution
- Current: local cron + state files (last page/watermark) per endpoint.
- Next: analyze moving to a lightweight bash + SQLite (or JSON) queue with task states (pending/running/done/error), cursors, rate limiter, and token refresh/backoff built in. Define a migration plan: schema for tasks, worker loop design, resume behavior, and how to retire the cron/state files.

## Init/cron setup
- Add an init step that installs or updates the crontab entries for fetchers (users, projects, etc.) with sensible defaults (pacing to stay under 1200 req/hr). Document how to override/disable per environment.

## Backups/DR
- Add automated DB backups (e.g., nightly pg_dump to encrypted storage with rotation) and a quick restore doc/test.
- Back up exports/ state files (including queue state if adopted) so fetch progress can be recovered.
- Document recovery steps and verify periodically.

## Token freshness for long runs
- Add a pre-flight token validity check before long fetches; if expiry is within a safety window (e.g., <10 minutes), refresh proactively.
- Ensure workers/helpers refresh once on 401/expired mid-run and retry the same request.

## Logging
- Add per-fetch log files under `repo/logs/` (endpoint, campus_id, page, counts, status, retries, token refresh events). Rotate/compress to keep size manageable.
- Add a documented integrity check script (`scripts/check_db_integrity.sh`) and keep it up to date when schema/exports change.
