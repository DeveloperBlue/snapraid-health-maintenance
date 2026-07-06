#!/bin/bash
# SMART hardware health checks for physical disks.

SHM_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SHM_ROOT_DIR/lib/common.sh"

run_smart_check() {
    if [ ! -x "$SMART_BIN" ]; then
        shm_send_email "SnapRAID ERROR - smartctl not found" \
            "smartctl binary not found at $SMART_BIN. Please install 'smartmontools'."
        exit 1
    fi

    shm_log "--- Running: SMART Hardware Checks ---"

    local all_physical_disks base_dev all_out drive_model drive_size
    local temp status_txt status_emoji health_details media_errs realloc pending

    all_physical_disks=$(shm_get_physical_disks)
    SMART_REPORT=""

    for base_dev in $all_physical_disks; do
        [ ! -b "$base_dev" ] && continue

        drive_model=$(shm_smartctl_invoke "$base_dev" -i | grep -iE "Device Model:|Model Number:" | sed -e 's/.*:[[:space:]]*//')
        drive_size=$(lsblk -dno SIZE "$base_dev" | xargs)
        [ -z "$drive_model" ] && drive_model="Unknown Device"

        all_out=$(shm_smartctl_invoke "$base_dev" -a)

        if echo "$all_out" | grep -qi "Temperature_Celsius"; then
            temp=$(echo "$all_out" | grep -i "Temperature_Celsius" | awk '{print $10}')
        elif echo "$all_out" | grep -qi "Temperature Sensor 1"; then
            temp=$(echo "$all_out" | grep -i "Temperature Sensor 1" | grep -o '[0-9]\+' | head -n 1)
        else
            temp=$(echo "$all_out" | grep -i "Temperature:" | grep -o '[0-9]\+' | head -n 1)
        fi
        [ -z "$temp" ] && temp="N/A"

        if echo "$all_out" | grep -qiE 'SMART overall-health self-assessment test result:[[:space:]]*PASSED|PASSED|SMART Health Status:[[:space:]]*OK'; then
            status_txt="PASSED"
            status_emoji="✅"
        elif shm_is_smart_unsupported "$all_out"; then
            status_txt="UNSUPPORTED"
            status_emoji="ℹ️ "
            SMART_REPORT+="$status_emoji $base_dev [$drive_model] ($drive_size):\n   • Hardware Health:  $status_txt\n\n"
            continue
        else
            status_txt="FAILED"
            status_emoji="❌"
            ERRORS=$((ERRORS + 1))
        fi

        if echo "$all_out" | grep -qi "Media and Data Integrity Errors"; then
            media_errs=$(echo "$all_out" | grep -i "Media and Data Integrity Errors" | grep -o '[0-9]\+' | head -n 1)
            [ -z "$media_errs" ] && media_errs=0
            [ "$media_errs" -gt 0 ] && { status_emoji="⚠️ "; ERRORS=$((ERRORS + 1)); }
            health_details="Media Errors: $media_errs"
        else
            reallocated=$(echo "$all_out" | grep -i "Reallocated_Sector_Ct" | awk '{print $10}' | grep -o '[0-9]\+' | head -n 1)
            pending=$(echo "$all_out" | grep -i "Current_Pending_Sector" | awk '{print $10}' | head -n 1)
            [ -z "$reallocated" ] && reallocated=0
            [ -z "$pending" ] && pending=0
            { [ "$reallocated" -gt 0 ] || [ "$pending" -gt 0 ]; } && { status_emoji="⚠️ "; ERRORS=$((ERRORS + 1)); }
            health_details="Reallocated Sectors: $reallocated | Pending Sectors: $pending"
        fi

        SMART_REPORT+="$status_emoji $base_dev [$drive_model] ($drive_size):\n"
        SMART_REPORT+="   • Hardware Health:  $status_txt\n"
        SMART_REPORT+="   • Temperature:      ${temp}°C\n"
        SMART_REPORT+="   • Disk Integrity:    $health_details\n\n"
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    shm_require_root
    shm_load_config
    shm_setup_logging

    shm_log "=================================================="
    shm_log "SMART health check started"
    shm_log "=================================================="
    run_smart_check

    printf '%b\n' "$SMART_REPORT"

    shm_log "SMART health check finished. Errors: $ERRORS"
    [ "$ERRORS" -gt 0 ] && exit 1
    exit 0
fi
