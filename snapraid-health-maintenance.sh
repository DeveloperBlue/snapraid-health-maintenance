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
#   sudo ./snapraid-health-maintenance.sh status       (Runs snapraid status + SMART + disk usage)
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
if [ -z "$SNAPRAID_BIN" ]; then
    SNAPRAID_BIN=$(which snapraid 2>/dev/null || echo "/usr/bin/snapraid")
fi
if [ -z "$SMART_BIN" ]; then
    SMART_BIN=$(which smartctl 2>/dev/null || echo "/usr/sbin/smartctl")
fi
DISK_USAGE_WARN_PERCENT="${DISK_USAGE_WARN_PERCENT:-90}"
DISK_USAGE_IGNORE_MOUNTS="${DISK_USAGE_IGNORE_MOUNTS:-}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-60}"
# USESEND_API_KEY is set in snapraid-health-maintenance.conf (keep that file chmod 600).
USESEND_API_KEY="${USESEND_API_KEY:-}"

# -----------------------------------------------------------------------------
# Argument Parsing & Mode Control
# -----------------------------------------------------------------------------
COMMAND_ARG="${1:-sync}"
RUN_SNAPRAID=false
RUN_SNAPRAID_STATUS=false
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
    status)
        RUN_SNAPRAID=false
        RUN_SNAPRAID_STATUS=true
        RUN_SMART=true
        RUN_DESC="Status Check (snapraid status + SMART + disk usage)"
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
        echo "Usage: $0 {sync|scrub|health|status|sync-only|scrub-only}"
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

rotate_old_logs() {
    [ "$LOG_RETENTION_DAYS" -eq 0 ] 2>/dev/null && return 0

    local old_logs deleted
    old_logs=$(find "$LOG_DIR" -maxdepth 1 -name 'snapraid-*.log' -type f -mtime +"$LOG_RETENTION_DAYS" 2>/dev/null)
    [ -z "$old_logs" ] && return 0

    deleted=$(printf '%s\n' "$old_logs" | wc -l)
    printf '%s\n' "$old_logs" | xargs rm -f
    log "Rotated $deleted log file(s) older than ${LOG_RETENTION_DAYS} days."
}

rotate_old_logs

send_email_via_mail() {
    local subject="$1"
    local body="$2"
    printf '%s\n' "$body" | mail -s "[$HOSTNAME] $subject" "$EMAIL"
}

send_email_via_usesend() {
    local subject="$1"
    local body="$2"
    local full_subject="[$HOSTNAME] $subject"
    local payload http_code response_file

    response_file=$(mktemp)
    payload=$(jq -n \
        --arg to "$EMAIL" \
        --arg from "$USESEND_FROM" \
        --arg subject "$full_subject" \
        --arg text "$body" \
        '{to: $to, from: $from, subject: $subject, text: $text}') || {
        rm -f "$response_file"
        return 1
    }

    http_code=$(curl -sS -o "$response_file" -w '%{http_code}' \
        -X POST "${USESEND_API_URL%/}/v1/emails" \
        -H "Authorization: Bearer ${USESEND_API_KEY}" \
        -H "Content-Type: application/json" \
        --data "$payload") || {
        rm -f "$response_file"
        return 1
    }

    if [ "$http_code" = "200" ]; then
        rm -f "$response_file"
        return 0
    fi

    log "useSend API error (HTTP $http_code): $(cat "$response_file" 2>/dev/null)"
    rm -f "$response_file"
    return 1
}

is_disk_usage_ignored() {
    local mount="$1"
    local ignored
    for ignored in $DISK_USAGE_IGNORE_MOUNTS; do
        [ "$mount" = "$ignored" ] && return 0
    done
    return 1
}

send_email() {
    local subject="$1"
    local body="$2"

    if [ -n "$USESEND_API_URL" ] && [ -n "$USESEND_FROM" ] && [ -n "$USESEND_API_KEY" ] && [ -n "$EMAIL" ]; then
        if command -v curl >/dev/null && command -v jq >/dev/null; then
            if send_email_via_usesend "$subject" "$body"; then
                log "Notification sent via useSend to $EMAIL"
                return 0
            fi
            log "WARNING: useSend failed; falling back to mail"
        else
            log "WARNING: curl or jq not found; falling back to mail"
        fi
    fi

    send_email_via_mail "$subject" "$body"
    log "Notification sent via mail to $EMAIL"
}

# -----------------------------------------------------------------------------
# Pre-flight checks (Scoped to active choices)
# -----------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

if { [ "$RUN_SNAPRAID" = true ] || [ "$RUN_SNAPRAID_STATUS" = true ]; } && [ ! -x "$SNAPRAID_BIN" ]; then
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
    STATUS_EXIT=$?
    echo "$STATUS_OUTPUT" >> "$LOG_FILE"
    if [ $STATUS_EXIT -ne 0 ]; then
        log "ERROR: snapraid status failed (exit code $STATUS_EXIT)"
        ERRORS=$((ERRORS + 1))
        REPORT+="❌ snapraid status FAILED (exit code $STATUS_EXIT)\n"
    fi
fi

# -----------------------------------------------------------------------------
# SnapRAID Status-Only Block (read-only verification)
# -----------------------------------------------------------------------------
if [ "$RUN_SNAPRAID_STATUS" = true ]; then
    log "--- Running: snapraid status ---"
    STATUS_OUTPUT=$($SNAPRAID_BIN status 2>&1)
    STATUS_EXIT=$?
    echo "$STATUS_OUTPUT" >> "$LOG_FILE"

    if [ $STATUS_EXIT -ne 0 ]; then
        log "ERROR: snapraid status failed (exit code $STATUS_EXIT)"
        ERRORS=$((ERRORS + 1))
        REPORT+="❌ snapraid status FAILED (exit code $STATUS_EXIT)\n"
    else
        log "snapraid status completed successfully."
        REPORT+="✅ snapraid status completed\n"
    fi
fi

# -----------------------------------------------------------------------------
# SMART Hardware & Capacity Check Block
# -----------------------------------------------------------------------------
if [ "$RUN_SMART" = true ]; then
    log "--- Running: Capacity & SMART Hardware Checks ---"

    ALL_PHYSICAL_DISKS=$(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}')

    # Disk space check (mount points on the same physical disks as SMART)
    DISK_WARNINGS=""
    DISK_SPACE_MOUNTS=()
    while read -r mount; do
        DISK_SPACE_MOUNTS+=("$mount")
        if is_disk_usage_ignored "$mount"; then
            continue
        fi
        USAGE=$(df --output=pcent "$mount" 2>/dev/null | tail -1 | tr -d '% ')
        if [ -n "$USAGE" ] && [ "$USAGE" -ge "$DISK_USAGE_WARN_PERCENT" ] 2>/dev/null; then
            DISK_WARNINGS+="⚠️  $mount is at ${USAGE}% capacity\n"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(
        for base_dev in $ALL_PHYSICAL_DISKS; do
            [ ! -b "$base_dev" ] && continue
            lsblk -ln -o MOUNTPOINT "$base_dev" 2>/dev/null
        done | sed '/^$/d' | sort -u
    )

    # SMART Check
    SMART_REPORT=""

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

    if [ "$RUN_SNAPRAID" = true ] || [ "$RUN_SNAPRAID_STATUS" = true ]; then
        EMAIL_BODY+=$(printf "\n\n--- SnapRAID Results ---\n%b" "$REPORT")
    fi

    if [ "$RUN_SMART" = true ]; then
        if [ ${#DISK_SPACE_MOUNTS[@]} -gt 0 ]; then
            EMAIL_BODY+=$(printf "\n\n--- Disk Space Allocation ---\n%s" "$(df -h "${DISK_SPACE_MOUNTS[@]}" 2>/dev/null)")
        else
            EMAIL_BODY+=$'\n\n--- Disk Space Allocation ---\n(no mounted filesystems on physical disks)'
        fi
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

    if [ "$RUN_SNAPRAID" = true ] || [ "$RUN_SNAPRAID_STATUS" = true ]; then
        EMAIL_BODY+=$(printf "\n--- SnapRAID Status Snapshot ---\n%s" "$STATUS_OUTPUT")
    fi

    EMAIL_BODY+=$(printf "\n\n--- Log Reference Location ---\n%s" "$LOG_FILE")

    send_email "$SUBJECT" "$EMAIL_BODY"
fi

exit $ERRORS