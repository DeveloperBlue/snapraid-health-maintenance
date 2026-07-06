# snapraid-health-maintenance

My own personal maintenance script used for automating snapraid and SMART Health checks.

Wired into my self-hosted usesend instance to avoid sending emails out my personal inbox.

Uses nice and ionice for ...

Notes:
sync
scrub

# Install

Copy the script to the expected bin directory

```sh
cp ./snapraid-health-maintenance /usr/local/bin/snapraid-health-maintenance.sh
chmod +x /usr/local/bin/snapraid-health-maintenance.sh
```


# cron job

Add the script to the cronjob

```
sudo crontab -l
```

```sh
# ---------------------------------------------------------------------
# SnapRAID & System Health Automation
# ---------------------------------------------------------------------

# 1. Daily Sync & Health Check (Every day at 4:00 AM)
0 4 * * * /usr/bin/nice -n 19 /usr/bin/ionice -c 3 /usr/local/bin/snapraid-health-maintenance.sh sync

# 2. Weekly Parity Scrub & Health Check (Every Monday at 5:00 AM)
0 5 * * 1 /usr/bin/nice -n 19 /usr/bin/ionice -c 3 /usr/local/bin/snapraid-health-maintenance.sh scrub
```