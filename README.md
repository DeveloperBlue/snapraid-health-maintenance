# snapraid-health-maintenance

My own personal maintenance script used for automating SnapRAID and SMART health checks.

Notifications are sent via a self-hosted [useSend](https://usesend.dev) REST API when configured, with fallback to the system `mail` command.

This script does not manage your SnapRAID array configuration (`/etc/snapraid.conf`). That file defines which disks are data, parity, and content; this repo only automates maintenance runs and health reporting via `snapraid-health-maintenance.conf`.

# Install

Clone the repo into `/opt/snapraid-health-maintenance`. The script loads `snapraid-health-maintenance.conf` from the same directory, so cron runs the script directly from the clone.

```sh
sudo git clone git@github.com:DeveloperBlue/snapraid-health-maintenance.git /opt/snapraid-health-maintenance
cd /opt/snapraid-health-maintenance
sudo cp snapraid-health-maintenance.conf.example snapraid-health-maintenance.conf
sudo chmod +x snapraid-health-maintenance.sh
sudo chmod 600 snapraid-health-maintenance.conf
```

Verify SnapRAID, SMART, disk usage, and email delivery with a read-only status run:

```sh
sudo ./snapraid-health-maintenance.sh status
```

# cron job

Add the script to root's crontab (SnapRAID and SMART checks require root):

```sh
sudo crontab -e
```

```sh
# ---------------------------------------------------------------------
# SnapRAID & System Health Automation
# ---------------------------------------------------------------------

# 1. Daily Sync & Health Check (Every day at 4:00 AM)
0 4 * * * /usr/bin/nice -n 19 /usr/bin/ionice -c 3 /opt/snapraid-health-maintenance/snapraid-health-maintenance.sh sync

# 2. Weekly Parity Scrub & Health Check (Every Monday at 5:00 AM)
0 5 * * 1 /usr/bin/nice -n 19 /usr/bin/ionice -c 3 /opt/snapraid-health-maintenance/snapraid-health-maintenance.sh scrub
```

List crontab

```sh
sudo crontab -l
```


## Notifications

Set `EMAIL` to the address that should receive alerts. To route sending through useSend instead of your personal SMTP account, additionally configure these in `snapraid-health-maintenance.conf`:

| Variable | Description |
|----------|-------------|
| `USESEND_API_URL` | API base URL (e.g. `https://send.example.com/api`) |
| `USESEND_FROM` | Verified sender address in useSend (e.g. `snapraid@yourdomain.com`) |
| `USESEND_API_KEY` | API key from your useSend dashboard |

> Keep `snapraid-health-maintenance.conf` at `chmod 600`; it contains your API key and is not tracked in git.

> Requires `curl` and `jq`. If useSend is unreachable or not configured, the script falls back to `mail`.

## Health checks

During SMART runs, the script checks filesystem usage on every mount found on physical disks. Set `DISK_USAGE_WARN_PERCENT` (default `90`) to control when a mount triggers a warning.

Use `DISK_USAGE_IGNORE_MOUNTS` to exclude specific mount paths from that threshold check. Ignored mounts still appear in the disk space section of summary emails; they just won't count as errors.

SnapRAID parity disks are often intentionally kept nearly full. If you don't want routine high-usage alerts on parity, add those mount points to `DISK_USAGE_IGNORE_MOUNTS` in `snapraid-health-maintenance.conf`, for example:

```
DISK_USAGE_IGNORE_MOUNTS="/mnt/parity"
```

# Modes

| Command       | SnapRAID              | SMART | Disk usage | Email on success |
|---------------|-----------------------|-------|------------|------------------|
| `sync`        | touch + sync          | yes   | yes        | no               |
| `scrub`       | touch + scrub         | yes   | yes        | yes              |
| `status`      | status only           | yes   | yes        | yes              |
| `health`      | no                    | yes   | yes        | yes              |
| `sync-only`   | touch + sync          | no    | no         | yes              |
| `scrub-only`  | touch + scrub         | no    | no         | yes              |


## `sync` (daily)

Updates the SnapRAID parity to match the data disks. After files are added, changed, or deleted on the array, parity is stale until a sync runs.

The script runs:

1. **`snapraid touch`** — records which files have not changed since the last sync, so the next step can skip them.
2. **`snapraid sync`** — scans for changes and rewrites parity blocks as needed.

A successful daily sync suppresses the summary email; you only get notified when something goes wrong.

## `scrub` (weekly)

Verifies data on the array against parity by reading blocks and checking them. If a mismatch is found and parity is available, SnapRAID can repair the bad copy.

The script runs `snapraid scrub -p 20`, scrubbing **20% of the array per run** (configurable via `SCRUB_PERCENT` in `snapraid-health-maintenance.conf`). Over five weekly runs, the full array is checked. Scrub is slower than sync but catches silent bit rot and other latent corruption that sync alone would not find.

Each scrub run also includes SMART health checks and sends a summary email with the past week's run history.

## `status` (verification)

Read-only check to confirm SnapRAID, disk health, and notifications are all working. Use this after initial setup or when troubleshooting — it does not run `touch`, `sync`, or `scrub`.

The script runs:

1. **`snapraid status`** — confirms SnapRAID loads your config and reports array state.
2. **Disk usage** — checks mount points on physical disks against `DISK_USAGE_WARN_PERCENT`.
3. **SMART health** — runs `smartctl` on every physical disk.

A summary email is always sent (unlike a successful daily `sync`).

```sh
sudo /opt/snapraid-health-maintenance/snapraid-health-maintenance.sh status
```

# Why `nice` and `ionice`?

SnapRAID sync and scrub are long-running, disk-heavy jobs. On a home NAS that also serves media, downloads, and other services, you don't want maintenance to monopolize the machine.

The cron entries wrap the script with:

- **`nice -n 19`** — lowest CPU scheduling priority. The maintenance job yields CPU time to anything else that needs it.
- **`ionice -c 3`** — idle I/O priority class. Disk reads and writes only happen when the storage subsystem is otherwise idle, so normal workloads stay responsive during a sync or scrub.

Together, maintenance runs in the background without noticeably slowing down day-to-day use.
