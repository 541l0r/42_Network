# Cron Jobs

Wrapper scripts in this folder are intended to be run via cron. They both log with a UTC timestamp header into `logs/`.

## Scheduled entries (current crontab, UTC)

- `5 * * * * cd /srv/42_Network/repo/scripts && ./cron/run_token_refresh.sh >/srv/42_Network/logs/42_token_refresh.log 2>&1`
  - Refreshes the 42 API token hourly at minute 5.
- `0 1 * * * cd /srv/42_Network/repo/scripts && ./cron/run_daily_update.sh >> /srv/42_Network/logs/update_tables_daily.log 2>&1`
  - Runs the daily stable-table update at 02:00 Europe/Paris (01:00 UTC) and appends output to the daily log.
- `30 0 * * * cd /srv/42_Network/repo/scripts && ./cron/run_rotate_logs.sh`
  - Rotates `42_token_refresh.log` and `update_tables_daily.log` at 01:30 Europe/Paris (00:30 UTC), keeping 30 days by default (`KEEP_DAYS` env).

## Scripts

- `run_token_refresh.sh`: calls `token_manager.sh refresh`, appends to `logs/42_token_refresh.log`.
- `run_daily_update.sh`: calls `update_stable_tables.sh`, appends to `logs/update_tables_daily.log` (via cron or manual run).
- `run_rotate_logs.sh`: rotates both logs daily, keeps 30 days by default (override with `KEEP_DAYS`).

Adjust times/paths in crontab as needed. Run scripts manually for testing:

```bash
cd /srv/42_Network/repo/scripts
./cron/run_token_refresh.sh
./cron/run_daily_update.sh
```
