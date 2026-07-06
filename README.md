# snapraid-health-maintenance

My own personal maintenance script used for automating SnapRAID and SMART health checks.

Wired into my self-hosted [usesend](https://usesend.dev) instance to avoid sending emails out my personal inbox.

## Why `nice` and `ionice`?

SnapRAID sync and scrub are long-running, disk-heavy jobs. On a home NAS that also serves media, downloads, and other services, you don't want maintenance to monopolize the machine.

The cron entries wrap the script with:

- **`nice -n 19`** — lowest CPU scheduling priority. The maintenance job yields CPU time to anything else that needs it.
- **`ionice -c 3`** — idle I/O priority class. Disk reads and writes only happen when the storage subsystem is otherwise idle, so normal workloads stay responsive during a sync or scrub.

Together, maintenance runs in the background without noticeably slowing down day-to-day use.

## Commands

### `sync` (daily)

Updates the SnapRAID parity to match the data disks. After files are added, changed, or deleted on the array, parity is stale until a sync runs.

The script runs:

1. **`snapraid touch`** — records which files have not changed since the last sync, so the next step can skip them.
2. **`snapraid sync`** — scans for changes and rewrites parity blocks as needed.

A successful daily sync suppresses the summary email; you only get notified when something goes wrong.

### `scrub` (weekly)

Verifies data on the array against parity by reading blocks and checking them. If a mismatch is found and parity is available, SnapRAID can repair the bad copy.

The script runs `snapraid scrub -p 20`, scrubbing **20% of the array per run** (configurable via `SCRUB_PERCENT` in the script). Over five weekly runs, the full array is checked. Scrub is slower than sync but catches silent bit rot and other latent corruption that sync alone would not find.

Each scrub run also includes SMART health checks and sends a summary email with the past week's run history.

### Other modes

| Command       | SnapRAID | SMART |
|---------------|----------|-------|
| `sync`        | sync     | yes   |
| `scrub`       | scrub    | yes   |
| `health`      | no       | yes   |
| `sync-only`   | sync     | no    |
| `scrub-only`  | scrub    | no    |

# Install

Copy the script to the expected bin directory:

```sh
cp ./snapraid-health-maintenance.sh /usr/local/bin/snapraid-health-maintenance.sh
chmod +x /usr/local/bin/snapraid-health-maintenance.sh
```

# Cron job

Add the script to root's crontab (SnapRAID and SMART checks require root):

```sh
sudo crontab -l
sudo crontab -e
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
