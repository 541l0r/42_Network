# Orchestra Completion Notes

- **Scope**: Orchestration flow finalised (metadata fetch/fallback + DB load, bootstrap modes `empty/raw`, optional worker, API pacing).
- **Config**: All knobs now live in `scripts/config/orchestra.conf` (metadata fetch/snapshot/fallback, DB bootstrap path/mode, API health, rate-limit, worker toggle, DB check bypass).
- **Run**: `bash scripts/orchestrate/orchestra.sh` (uses config defaults; snapshots auto-refresh when enabled; fallbacks restore exports if fetch disabled/failed).
- **Worker**: Managed via `scripts/backlog_worker_manager.sh {start|stop|status}`; consumes `.backlog/pending_users.txt`.
- **DB checks**: Can be bypassed with `ORCHESTRA_DB_CHECK_BYPASS=1`; otherwise runs extended integrity + freshness checks (metadata + user tables).
- **Metadata snapshots**: Timestamped `metadata_snapshot_*.json` plus `metadata_snapshot_latest.json` (ignored by git) used for fallback and epoch alignment.
