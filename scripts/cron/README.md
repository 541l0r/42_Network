# Cron Jobs

Wrapper scripts in this folder are intended to be run via cron. They both log with a UTC timestamp header into `logs/`.

## Scheduled entries (current crontab)

- `5 * * * * cd /srv/42_Network/repo/scripts && ./cron/run_token_refresh.sh >/srv/42_Network/logs/42_token_refresh.log 2>&1`
  - Refreshes the 42 API token hourly at minute 5.
- `0 3 * * * cd /srv/42_Network/repo/scripts && ./cron/run_daily_update.sh >> /srv/42_Network/logs/update_tables_daily.log 2>&1`
  - Runs the daily tables update at 03:00 UTC and appends output to the daily log.

## Scripts

- `run_token_refresh.sh`: calls `token_manager.sh refresh`, appends to `logs/42_token_refresh.log`.
- `run_daily_update.sh`: calls `update_tables.sh`, appends to `logs/update_tables_daily.log`.
- `run_rotate_logs.sh`: rotates both logs daily, keeps 30 days by default (override with `KEEP_DAYS`).

Adjust times/paths in crontab as needed. Run scripts manually for testing:

```bash
cd /srv/42_Network/repo/scripts
./cron/run_token_refresh.sh
./cron/run_daily_update.sh
```
