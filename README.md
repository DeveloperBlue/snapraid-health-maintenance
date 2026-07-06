# snapraid-health-maintenance

Maintenance scripts for automating SnapRAID sync/scrub and SMART/disk health checks.

Notifications are sent via a self-hosted [useSend](https://usesend.dev) REST API when configured, with fallback to the system `mail` command.

This project does not manage your SnapRAID array configuration (`/etc/snapraid.conf`). That file defines which disks are data, parity, and content; this repo only automates maintenance runs and health reporting via `snapraid-health-maintenance.conf`.

## Project layout

| File | Purpose |
|------|---------|
| `snapraid-health-maintenance.sh` | Main entry point — orchestrates checks and sends summary emails |
| `checks/snapraid-check.sh` | SnapRAID touch, sync, scrub, and status |
| `checks/smart-check.sh` | SMART hardware health on physical disks |
| `checks/disk-usage-check.sh` | Mount-point usage warnings |
| `lib/common.sh` | Shared config, logging, and helpers |
| `lib/args.sh` | Command-line flag parsing |
| `lib/mail.sh` | useSend and `mail` notification delivery |
| `snapraid-health-maintenance.conf` | Local config (copy from `.example`; not tracked in git) |

For scheduled maintenance, use `snapraid-health-maintenance.sh`. The feature scripts can also be run on their own for targeted checks or troubleshooting.

# Install

Clone the repo into `/opt/snapraid-health-maintenance`.

```sh
sudo git clone https://github.com/DeveloperBlue/snapraid-health-maintenance.git /opt/snapraid-health-maintenance
cd /opt/snapraid-health-maintenance
sudo cp snapraid-health-maintenance.conf.example snapraid-health-maintenance.conf
sudo chmod +x snapraid-health-maintenance.sh checks/snapraid-check.sh checks/smart-check.sh checks/disk-usage-check.sh
sudo chmod 600 snapraid-health-maintenance.conf
```

Edit `snapraid-health-maintenance.conf` and set at least `EMAIL` (see [Notifications](#notifications)).

Verify SnapRAID, SMART, disk usage, and email delivery with a read-only status run:

```sh
sudo ./snapraid-health-maintenance.sh --status
```

View the most recent logs, if necessary
```sh
sudo less /var/log/snapraid-health-maintenance/snapraid-$(date +%Y-%m-%d).log
```

# cron job

Add the main script to root's crontab (SnapRAID and SMART checks require root):

```sh
sudo crontab -e
```

```sh
# ---------------------------------------------------------------------
# SnapRAID & System Health Automation
# ---------------------------------------------------------------------

# 1. Daily Sync & Health Check (Every day at 4:00 AM)
0 4 * * * /usr/bin/nice -n 19 /usr/bin/ionice -c 3 /opt/snapraid-health-maintenance/snapraid-health-maintenance.sh --snapraid-sync --smart --disk-usage --skip-success-report

# 2. Weekly Parity Scrub & Health Check (Every Monday at 5:00 AM)
0 5 * * 1 /usr/bin/nice -n 19 /usr/bin/ionice -c 3 /opt/snapraid-health-maintenance/snapraid-health-maintenance.sh --snapraid-scrub --smart --disk-usage
```

List crontab:

```sh
sudo crontab -l
```

## Notifications

Set `EMAIL` to the address that should receive alerts. `EMAIL` is required; the scripts exit with an error if it is not set.

Summary emails are sent when a run completes, unless `--skip-success-report` is set and there are no errors. Failures always trigger an email.

To route sending through useSend instead of your personal SMTP account, configure these in `snapraid-health-maintenance.conf`:

| Variable | Description |
|----------|-------------|
| `USESEND_API_URL` | API base URL (e.g. `https://send.example.com/api`) |
| `USESEND_FROM` | Verified sender address in useSend (e.g. `snapraid@yourdomain.com`) |
| `USESEND_API_KEY` | API key from your useSend dashboard |

> Keep `snapraid-health-maintenance.conf` at `chmod 600`; it contains your API key.

> Requires `curl` and `jq` for useSend. If useSend is unreachable or not configured, delivery falls back to `mail` (see `lib/mail.sh`).

## Health checks

During full maintenance runs, disk usage and SMART checks run as separate steps. Disk usage checks every mount found on physical disks against `DISK_USAGE_WARN_PERCENT` (default `90`).

Use `DISK_USAGE_IGNORE_MOUNTS` to exclude specific mount paths from that threshold check. Ignored mounts still appear in the disk space section of summary emails; they just won't count as errors.

SnapRAID parity disks are often intentionally kept nearly full. If you don't want routine high-usage alerts on parity, add those mount points to `DISK_USAGE_IGNORE_MOUNTS` in `snapraid-health-maintenance.conf`, for example:

```
DISK_USAGE_IGNORE_MOUNTS="/mnt/parity"
```

# Flags

All checks are invoked via flags on `snapraid-health-maintenance.sh`. Flags are combinable.

| Flag | Runs |
|------|------|
| `--snapraid-sync` | `snapraid touch`, `sync`, and `status` |
| `--snapraid-scrub` | `snapraid scrub` and `status` |
| `--snapraid-status` | `snapraid status` only (read-only) |
| `--smart` | SMART hardware checks on physical disks |
| `--disk-usage` | Mount-point usage warnings |
| `--skip-success-report` | Suppress summary email when no errors |
| `--status` | Preset: `--snapraid-status --smart --disk-usage` |

With **no flags**, all check modes run: `--snapraid-sync --snapraid-scrub --smart --disk-usage`.

## Common combinations

| Use case | Flags |
|----------|-------|
| Daily cron | `--snapraid-sync --smart --disk-usage --skip-success-report` |
| Weekly cron | `--snapraid-scrub --smart --disk-usage` |
| Post-install verification | `--status` |
| SMART and disk usage only | `--smart --disk-usage` |
| SnapRAID sync only | `--snapraid-sync` |
| SnapRAID scrub only | `--snapraid-scrub` |

## Daily sync

Updates parity to match data disks (`touch` + `sync`), then runs SMART and disk usage checks. Uses `--skip-success-report` so you only get emailed when something fails.

## Weekly scrub

Reads 20% of the array against parity each run (`SCRUB_PERCENT` in config), plus SMART and disk usage checks. Sends a summary email with the past week's run history. A full array check takes about five weekly runs.

## Status verification

Read-only check to confirm SnapRAID, disk health, and notifications are all working. Use this after initial setup or when troubleshooting — it does not run `touch`, `sync`, or `scrub`.

```sh
sudo /opt/snapraid-health-maintenance/snapraid-health-maintenance.sh --status
```

This runs `snapraid status`, disk usage checks, and SMART health, then sends a summary email.

# Why `nice` and `ionice`?

SnapRAID sync and scrub are long-running, disk-heavy jobs. On a home NAS that also serves media, downloads, and other services, you don't want maintenance to monopolize the machine.

The cron entries wrap the script with:

- **`nice -n 19`** — lowest CPU scheduling priority. The maintenance job yields CPU time to anything else that needs it.
- **`ionice -c 3`** — idle I/O priority class. Disk reads and writes only happen when the storage subsystem is otherwise idle, so normal workloads stay responsive during a sync or scrub.

Together, maintenance runs in the background without noticeably slowing down day-to-day use.
