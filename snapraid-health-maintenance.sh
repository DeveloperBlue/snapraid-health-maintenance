#!/bin/bash
# =============================================================================
# snapraid-health-maintenance.sh
# Orchestrates SnapRAID, SMART, and disk usage health checks.
#
# Install: see README.md (git clone to /opt/snapraid-health-maintenance)
#
# Schedule (cron - run as root):
#   sudo crontab -e
#   0 4 * * * /usr/bin/nice -n 19 /usr/bin/ionice -c 3 /opt/snapraid-health-maintenance/snapraid-health-maintenance.sh --snapraid-sync --smart --disk-usage --skip-success-report
#   0 5 * * 1 /usr/bin/nice -n 19 /usr/bin/ionice -c 3 /opt/snapraid-health-maintenance/snapraid-health-maintenance.sh --snapraid-scrub --smart --disk-usage
#
# Usage:
#   sudo ./snapraid-health-maintenance.sh [OPTIONS]
#
#   With no options: snapraid-sync, snapraid-scrub, smart, disk-usage
#   --status          Preset for post-install verification
#   --skip-success-report   Suppress email when no errors (daily sync cron)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/args.sh
source "$SCRIPT_DIR/lib/args.sh"
# shellcheck source=checks/snapraid-check.sh
source "$SCRIPT_DIR/checks/snapraid-check.sh"
# shellcheck source=checks/smart-check.sh
source "$SCRIPT_DIR/checks/smart-check.sh"
# shellcheck source=checks/disk-usage-check.sh
source "$SCRIPT_DIR/checks/disk-usage-check.sh"

shm_load_config
shm_parse_args "$@"

shm_require_root
shm_setup_logging

START_TIME=$(date +%s)
shm_log "=================================================="
shm_log "SnapRAID maintenance started Mode: $RUN_DESC"
shm_log "=================================================="

if [ "$RUN_SNAPRAID_SYNC" = true ]; then
    run_snapraid_maintenance sync
fi

if [ "$RUN_SNAPRAID_SCRUB" = true ]; then
    run_snapraid_maintenance scrub
fi

if [ "$RUN_SNAPRAID_STATUS" = true ]; then
    run_snapraid_status true
fi

if [ "$RUN_DISK_USAGE" = true ]; then
    run_disk_usage_check
fi

if [ "$RUN_SMART" = true ]; then
    run_smart_check
fi

END_TIME=$(date +%s)
DURATION=$(( (END_TIME - START_TIME) / 60 ))

shm_log "SnapRAID maintenance finished. Duration: ${DURATION}m. Errors: $ERRORS"
shm_log "=================================================="

SHOULD_SEND_EMAIL=true
if [ "$SKIP_SUCCESS_REPORT" = true ] && [ $ERRORS -eq 0 ]; then
    SHOULD_SEND_EMAIL=false
    echo "Run completed cleanly. Suppressing success email notification."
fi

if [ "$SHOULD_SEND_EMAIL" = true ]; then
    if [ $ERRORS -eq 0 ]; then
        SUBJECT="SnapRAID/Health OK - $RUN_DESC completed (${DURATION}m)"
    else
        SUBJECT="SnapRAID/Health WARNING - $ERRORS issue(s) during $RUN_DESC"
    fi

    shm_build_maintenance_report \
        "$HOSTNAME" "$(date)" "$RUN_DESC" "$DURATION" "$ERRORS" "$LOG_FILE" \
        "$RUN_DISK_USAGE" "$RUN_SMART" "$RUN_SNAPRAID_SCRUB"

    shm_send_email "$SUBJECT" "$EMAIL_BODY_TEXT" "$EMAIL_BODY_HTML"
fi

if [ "$ERRORS" -gt 0 ]; then
    exit 1
fi
exit 0
