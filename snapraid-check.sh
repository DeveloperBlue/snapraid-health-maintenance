#!/bin/bash
# SnapRAID maintenance: touch, sync, scrub, and status.

SHM_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SHM_ROOT_DIR/lib/common.sh"

run_snapraid_maintenance() {
    local mode="$1"

    if [ ! -x "$SNAPRAID_BIN" ]; then
        shm_send_email "SnapRAID ERROR - snapraid not found" \
            "snapraid binary not found at $SNAPRAID_BIN. Check your installation."
        exit 1
    fi

    if [ "$mode" = "sync" ]; then
        shm_log "--- Running: snapraid touch ---"
        TOUCH_OUTPUT=$($SNAPRAID_BIN touch 2>&1)
        TOUCH_EXIT=$?
        echo "$TOUCH_OUTPUT" >> "$LOG_FILE"

        if [ $TOUCH_EXIT -ne 0 ]; then
            shm_log "WARNING: snapraid touch exited with code $TOUCH_EXIT"
            ERRORS=$((ERRORS + 1))
            REPORT+="⚠️  touch failed (exit code $TOUCH_EXIT)\n"
        else
            shm_log "touch completed successfully."
            REPORT+="✅ touch completed\n"
        fi

        shm_log "--- Running: snapraid sync ---"
        SYNC_TMP=$(shm_mktemp_or_exit)
        $SNAPRAID_BIN sync 2>&1 | tee "$SYNC_TMP"
        SYNC_EXIT=${PIPESTATUS[0]}

        cat "$SYNC_TMP" >> "$LOG_FILE"
        SYNC_OUTPUT=$(tr '\r' '\n' < "$SYNC_TMP")

        if [ $SYNC_EXIT -ne 0 ]; then
            shm_log "ERROR: snapraid sync failed (exit code $SYNC_EXIT)"
            ERRORS=$((ERRORS + 1))
            REPORT+="❌ sync FAILED (exit code $SYNC_EXIT)\n"
        else
            shm_log "sync completed successfully."
            REPORT+="✅ sync completed\n"
            SYNC_STATS=$(echo "$SYNC_OUTPUT" | grep -E "completed|updated|scanned|added|removed|moved|copied" | tail -5)
            REPORT+="   $SYNC_STATS\n"
        fi
    fi

    if [ "$mode" = "scrub" ]; then
        shm_log "--- Running: snapraid scrub -p $SCRUB_PERCENT ---"
        SCRUB_TMP=$(shm_mktemp_or_exit)
        $SNAPRAID_BIN scrub -p "$SCRUB_PERCENT" 2>&1 | tee "$SCRUB_TMP"
        SCRUB_EXIT=${PIPESTATUS[0]}

        cat "$SCRUB_TMP" >> "$LOG_FILE"
        SCRUB_OUTPUT=$(tr '\r' '\n' < "$SCRUB_TMP")

        if [ $SCRUB_EXIT -ne 0 ]; then
            shm_log "ERROR: snapraid scrub failed (exit code $SCRUB_EXIT)"
            ERRORS=$((ERRORS + 1))
            REPORT+="❌ scrub FAILED (exit code $SCRUB_EXIT)\n"
        else
            shm_log "scrub completed successfully."
            REPORT+="✅ scrub completed ($SCRUB_PERCENT% of array)\n"
            SCRUB_ERRORS=$(echo "$SCRUB_OUTPUT" | grep -iE "error|damaged|unrecoverable")
            if [ -n "$SCRUB_ERRORS" ]; then
                REPORT+="⚠️  Scrub reported issues:\n$SCRUB_ERRORS\n"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    fi

    run_snapraid_status
}

run_snapraid_status() {
    local report_success="${1:-false}"

    if [ ! -x "$SNAPRAID_BIN" ]; then
        shm_send_email "SnapRAID ERROR - snapraid not found" \
            "snapraid binary not found at $SNAPRAID_BIN. Check your installation."
        exit 1
    fi

    shm_log "--- Running: snapraid status ---"
    STATUS_OUTPUT=$($SNAPRAID_BIN status 2>&1)
    STATUS_EXIT=$?
    echo "$STATUS_OUTPUT" >> "$LOG_FILE"

    if [ $STATUS_EXIT -ne 0 ]; then
        shm_log "ERROR: snapraid status failed (exit code $STATUS_EXIT)"
        ERRORS=$((ERRORS + 1))
        REPORT+="❌ snapraid status FAILED (exit code $STATUS_EXIT)\n"
    elif [ "$report_success" = true ]; then
        shm_log "snapraid status completed successfully."
        REPORT+="✅ snapraid status completed\n"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    shm_require_root
    shm_load_config
    shm_setup_logging

    COMMAND_ARG="${1:-status}"
    case "$COMMAND_ARG" in
        sync|scrub)
            shm_log "=================================================="
            shm_log "SnapRAID maintenance started Mode: $COMMAND_ARG"
            shm_log "=================================================="
            run_snapraid_maintenance "$COMMAND_ARG"
            ;;
        status)
            shm_log "=================================================="
            shm_log "SnapRAID status check started"
            shm_log "=================================================="
            run_snapraid_status true
            ;;
        *)
            echo "Usage: $0 {sync|scrub|status}"
            exit 1
            ;;
    esac

    shm_log "SnapRAID check finished. Errors: $ERRORS"
    [ "$ERRORS" -gt 0 ] && exit 1
    exit 0
fi
