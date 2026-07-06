#!/bin/bash
# =============================================================================
# snapraid-health-maintenance.sh
# Runs SnapRAID and/or SMART health reporting based on parameters.
#
# Install: see README.md (git clone to /opt/snapraid-health-maintenance)
#
# Schedule (cron - run as root):
#   sudo crontab -e
#   0 4 * * * /opt/snapraid-health-maintenance/snapraid-health-maintenance.sh sync
#   0 5 * * 1 /opt/snapraid-health-maintenance/snapraid-health-maintenance.sh scrub
#
# Usage:
#   sudo ./snapraid-health-maintenance.sh sync          (Runs SnapRAID Sync + SMART)
#   sudo ./snapraid-health-maintenance.sh scrub         (Runs SnapRAID Scrub + SMART)
#   sudo ./snapraid-health-maintenance.sh health        (Runs SMART Health ONLY)
#   sudo ./snapraid-health-maintenance.sh sync-only     (Runs SnapRAID Sync ONLY)
#   sudo ./snapraid-health-maintenance.sh scrub-only    (Runs SnapRAID Scrub ONLY)
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SNAPRAID_HEALTH_CONFIG:-$SCRIPT_DIR/snapraid-health-maintenance.conf}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config not found at $CONFIG_FILE"
    echo "Copy snapraid-health-maintenance.conf.example to snapraid-health-maintenance.conf and edit it."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

LOG_FILE="$LOG_DIR/snapraid-$(date +%Y-%m-%d).log"
HOSTNAME="${HOSTNAME:-$(hostname)}"
if [ -z "$SMART_BIN" ]; then
    SMART_BIN=$(which smartctl 2>/dev/null || echo "/usr/sbin/smartctl")
fi

# -----------------------------------------------------------------------------
# Argument Parsing & Mode Control
# -----------------------------------------------------------------------------
COMMAND_ARG="${1:-sync}"
RUN_SNAPRAID=true
RUN_SMART=true
SNAPRAID_MODE="sync"

case "$COMMAND_ARG" in
    sync)
        RUN_SNAPRAID=true
        RUN_SMART=true
        SNAPRAID_MODE="sync"
        RUN_DESC="Full Maintenance (sync)"
        ;;
    skip)
        # Fallback handling if needed
        ;;
    scrub)
        RUN_SNAPRAID=true
        RUN_SMART=true
        SNAPRAID_MODE="scrub"
        RUN_DESC="Full Maintenance (scrub)"
        ;;
    health)
        RUN_SNAPRAID=false
        RUN_SMART=true
        RUN_DESC="SMART Health Check Only"
        ;;
    sync-only)
        RUN_SNAPRAID=true
        RUN_SMART=false
        SNAPRAID_MODE="sync"
        RUN_DESC="SnapRAID Sync Only"
        ;;
    scrub-only)
        RUN_SNAPRAID=true
        RUN_SMART=false
        SNAPRAID_MODE="scrub"
        RUN_DESC="SnapRAID Scrub Only"
        ;;
    *)
        echo "Usage: $0 {sync|scrub|health|sync-only|scrub-only}"
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# Setup & Helpers
# -----------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

send_email() {
    local subject="$1"
    local body="$2"
    printf '%s\n' "$body" | mail -s "[$HOSTNAME] $subject" "$EMAIL"
}

# -----------------------------------------------------------------------------
# Pre-flight checks (Scoped to active choices)
# -----------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

if [ "$RUN_SNAPRAID" = true ] && [ ! -x "$SNAPRAID_BIN" ]; then
    send_email "SnapRAID ERROR - snapraid not found" \
        "snapraid binary not found at $SNAPRAID_BIN. Check your installation."
    exit 1
fi

if [ "$RUN_SMART" = true ] && [ ! -x "$SMART_BIN" ]; then
    send_email "SnapRAID ERROR - smartctl not found" \
        "smartctl binary not found at $SMART_BIN. Please install 'smartmontools'."
    exit 1
fi

# -----------------------------------------------------------------------------
# Execution Setup
# -----------------------------------------------------------------------------
START_TIME=$(date +%s)
log "=================================================="
log "SnapRAID maintenance started Mode: $RUN_DESC"
log "=================================================="

ERRORS=0
REPORT=""

# -----------------------------------------------------------------------------
# SnapRAID Operations Block
# -----------------------------------------------------------------------------
if [ "$RUN_SNAPRAID" = true ]; then
    # --- Touch ---
    log "--- Running: snapraid touch ---"
    TOUCH_OUTPUT=$($SNAPRAID_BIN touch 2>&1)
    TOUCH_EXIT=$?
    echo "$TOUCH_OUTPUT" >> "$LOG_FILE"

    if [ $TOUCH_EXIT -ne 0 ]; then
        log "WARNING: snapraid touch exited with code $TOUCH_EXIT"
        ERRORS=$((ERRORS + 1))
        REPORT+="⚠️  touch failed (exit code $TOUCH_EXIT)\n"
    else
        log "touch completed successfully."
        REPORT+="✅ touch completed\n"
    fi

    # --- Sync ---
    if [ "$SNAPRAID_MODE" = "sync" ]; then
        log "--- Running: snapraid sync ---"
        SYNC_TMP=$(mktemp)
        $SNAPRAID_BIN sync 2>&1 | tee "$SYNC_TMP"
        SYNC_EXIT=${PIPESTATUS[0]}

        cat "$SYNC_TMP" >> "$LOG_FILE"
        # FIX: Convert carriage returns to true newlines to break up the progress block
        SYNC_OUTPUT=$(tr '\r' '\n' < "$SYNC_TMP")
        rm -f "$SYNC_TMP"

        if [ $SYNC_EXIT -ne 0 ]; then
            log "ERROR: snapraid sync failed (exit code $SYNC_EXIT)"
            ERRORS=$((ERRORS + 1))
            REPORT+="❌ sync FAILED (exit code $SYNC_EXIT)\n"
            send_email "SnapRAID SYNC FAILED" "Sync failed on $HOSTNAME. Code: $SYNC_EXIT\n\nFull log: $LOG_FILE"
        else
            log "sync completed successfully."
            REPORT+="✅ sync completed\n"
            SYNC_STATS=$(echo "$SYNC_OUTPUT" | grep -E "completed|updated|scanned|added|removed|moved|copied" | tail -5)
            REPORT+="   $SYNC_STATS\n"
        fi
    fi

    # --- Scrub ---
    if [ "$SNAPRAID_MODE" = "scrub" ]; then
        log "--- Running: snapraid scrub -p $SCRUB_PERCENT ---"
        SCRUB_TMP=$(mktemp)
        $SNAPRAID_BIN scrub -p $SCRUB_PERCENT 2>&1 | tee "$SCRUB_TMP"
        SCRUB_EXIT=${PIPESTATUS[0]}

        cat "$SCRUB_TMP" >> "$LOG_FILE"
        # FIX: Convert carriage returns to true newlines to break up the progress block
        SCRUB_OUTPUT=$(tr '\r' '\n' < "$SCRUB_TMP")
        rm -f "$SCRUB_TMP"

        if [ $SCRUB_EXIT -ne 0 ]; then
            log "ERROR: snapraid scrub failed (exit code $SCRUB_EXIT)"
            ERRORS=$((ERRORS + 1))
            REPORT+="❌ scrub FAILED (exit code $SCRUB_EXIT)\n"
            send_email "SnapRAID SCRUB FAILED" "Scrub failed on $HOSTNAME. Code: $SCRUB_EXIT\n\nFull log: $LOG_FILE"
        else
            log "scrub completed successfully."
            REPORT+="✅ scrub completed ($SCRUB_PERCENT% of array)\n"
            SCRUB_ERRORS=$(echo "$SCRUB_OUTPUT" | grep -iE "error|damaged|unrecoverable")
            if [ -n "$SCRUB_ERRORS" ]; then
                REPORT+="⚠️  Scrub reported issues:\n$SCRUB_ERRORS\n"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    fi

    # --- Status ---
    log "--- Running: snapraid status ---"
    STATUS_OUTPUT=$($SNAPRAID_BIN status 2>&1)
    echo "$STATUS_OUTPUT" >> "$LOG_FILE"
fi

# -----------------------------------------------------------------------------
# SMART Hardware & Capacity Check Block
# -----------------------------------------------------------------------------
if [ "$RUN_SMART" = true ]; then
    log "--- Running: Capacity & SMART Hardware Checks ---"

    # Disk space check
    DISK_WARNINGS=""
    while read -r usage mount; do
        [[ "$usage" == "Use%" ]] && continue
        USAGE=$(echo "$usage" | tr -d '%')
        if [ -n "$USAGE" ] && [ "$USAGE" -ge 90 ] 2>/dev/null; then
            DISK_WARNINGS+="⚠️  $mount is at ${USAGE}% capacity\n"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(df --output=pcent,target "$DISK_1" "$DISK_2" "$DISK_3" 2>/dev/null)

    # SMART Check
    SMART_REPORT=""
    ALL_PHYSICAL_DISKS=$(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}')

    for base_dev in $ALL_PHYSICAL_DISKS; do
        [ ! -b "$base_dev" ] && continue

        DRIVE_MODEL=$($SMART_BIN -i "$base_dev" | grep -iE "Device Model:|Model Number:" | sed -e 's/.*:[[:space:]]*//')
        DRIVE_SIZE=$(lsblk -dno SIZE "$base_dev" | xargs)
        [ -z "$DRIVE_MODEL" ] && DRIVE_MODEL="Unknown Device"

        HEALTH_OUT=$($SMART_BIN -H "$base_dev" 2>&1)
        ALL_OUT=$($SMART_BIN -a "$base_dev" 2>&1)

        # Safe multi-architecture temperature check
        if echo "$ALL_OUT" | grep -qi "Temperature_Celsius"; then
            TEMP=$(echo "$ALL_OUT" | grep -i "Temperature_Celsius" | awk '{print $10}')
        else
            TEMP=$(echo "$ALL_OUT" | grep -i "Temperature:" | grep -o '[0-9]\+' | head -n 1)
        fi
        [ -z "$TEMP" ] && TEMP="N/A"

        if echo "$HEALTH_OUT" | grep -qiE "PASSED|OK"; then
            STATUS_TXT="PASSED"
            STATUS_EMOJI="✅"
        elif echo "$ALL_OUT" | grep -qi "Unavailable"; then
            STATUS_TXT="UNSUPPORTED"
            STATUS_EMOJI="ℹ️ "
            SMART_REPORT+="$STATUS_EMOJI $base_dev [$DRIVE_MODEL] ($DRIVE_SIZE):\n   • Hardware Health:  $STATUS_TXT\n\n"
            continue
        else
            STATUS_TXT="FAILED"
            STATUS_EMOJI="❌"
            ERRORS=$((ERRORS + 1))
        fi

        if echo "$ALL_OUT" | grep -qi "Media and Data Integrity Errors"; then
            MEDIA_ERRS=$(echo "$ALL_OUT" | grep -i "Media and Data Integrity Errors" | grep -o '[0-9]\+' | head -n 1)
            [ -z "$MEDIA_ERRS" ] && MEDIA_ERRS=0
            [ "$MEDIA_ERRS" -gt 0 ] && { STATUS_EMOJI="⚠️ "; ERRORS=$((ERRORS + 1)); }
            HEALTH_DETAILS="Media Errors: $MEDIA_ERRS"
        else
            REALLOC=$(echo "$ALL_OUT" | grep -i "Reallocated_Sector_Ct" | awk '{print $10}' | grep -o '[0-9]\+' | head -n 1)
            PENDING=$(echo "$ALL_OUT" | grep -i "Current_Pending_Sector" | awk '{print $10}' | head -n 1)
            [ -z "$REALLOC" ] && REALLOC=0
            [ -z "$PENDING" ] && PENDING=0
            { [ "$REALLOC" -gt 0 ] || [ "$PENDING" -gt 0 ]; } && { STATUS_EMOJI="⚠️ "; ERRORS=$((ERRORS + 1)); }
            HEALTH_DETAILS="Reallocated Sectors: $REALLOC | Pending Sectors: $PENDING"
        fi

        SMART_REPORT+="$STATUS_EMOJI $base_dev [$DRIVE_MODEL] ($DRIVE_SIZE):\n"
        SMART_REPORT+="   • Hardware Health:  $STATUS_TXT\n"
        SMART_REPORT+="   • Temperature:      ${TEMP}°C\n"
        SMART_REPORT+="   • Disk Integrity:    $HEALTH_DETAILS\n\n"
    done
fi

# -----------------------------------------------------------------------------
# Compilation & Summary Email
# -----------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$(( (END_TIME - START_TIME) / 60 ))

# Log the absolute final result line to history before reading the history log file
log "SnapRAID maintenance finished. Duration: ${DURATION}m. Errors: $ERRORS"
log "=================================================="

# Determine email suppression rules
SHOULD_SEND_EMAIL=true
if [ "$COMMAND_ARG" = "sync" ] && [ $ERRORS -eq 0 ]; then
    SHOULD_SEND_EMAIL=false
    echo "Daily sync completed cleanly. Suppressing success email notification."
fi

if [ "$SHOULD_SEND_EMAIL" = true ]; then
    if [ $ERRORS -eq 0 ]; then
        SUBJECT="SnapRAID/Health OK - $RUN_DESC completed (${DURATION}m)"
    else
        SUBJECT="SnapRAID/Health WARNING - $ERRORS issue(s) during $RUN_DESC"
    fi

    EMAIL_BODY=$(cat <<EOF
Maintenance Report for $HOSTNAME
Run date:  $(date)
Execution: $RUN_DESC
Duration:  $DURATION minutes
Errors:    $ERRORS
EOF
)

    if [ "$RUN_SNAPRAID" = true ]; then
        EMAIL_BODY+=$(printf "\n\n--- SnapRAID Results ---\n%b" "$REPORT")
    fi

    if [ "$RUN_SMART" = true ]; then
        EMAIL_BODY+=$(printf "\n\n--- Disk Space Allocation ---\n%s" "$(df -h "$DISK_1" "$DISK_2" "$DISK_3" 2>/dev/null)")
        if [ -n "$DISK_WARNINGS" ]; then
            EMAIL_BODY+=$(printf "\n%b" "$DISK_WARNINGS")
        fi
        EMAIL_BODY+=$(printf "\n\n--- Global SMART Hardware Health Report ---\n%b" "$SMART_REPORT")
    fi

    # If this is the weekly scrub execution, roll up the daily logs
    if [ "$COMMAND_ARG" = "scrub" ]; then
        WEEKLY_HISTORY=$(grep -h "maintenance finished\." "$LOG_DIR"/snapraid-*.log 2>/dev/null | sort | tail -n 7)
        if [ -n "$WEEKLY_HISTORY" ]; then
            EMAIL_BODY+=$(printf "\n\n--- Past 7 Days Run Summaries ---\n%s" "$WEEKLY_HISTORY")
        fi
    fi

    if [ "$RUN_SNAPRAID" = true ]; then
        EMAIL_BODY+=$(printf "\n--- SnapRAID Status Snapshot ---\n%s" "$STATUS_OUTPUT")
    fi

    EMAIL_BODY+=$(printf "\n\n--- Log Reference Location ---\n%s" "$LOG_FILE")

    send_email "$SUBJECT" "$EMAIL_BODY"
    log "Summary email dispatched to $EMAIL"
fi

exit $ERRORS