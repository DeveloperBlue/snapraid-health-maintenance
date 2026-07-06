#!/bin/bash
# SMART hardware health checks for physical disks.

SHM_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SHM_ROOT_DIR/lib/common.sh"

shm_smart_get_serial() {
    local info_out="$1"
    local serial
    serial=$(shm_smart_info_field "$info_out" "Serial Number")
    [ -z "$serial" ] && serial=$(shm_smart_info_field "$info_out" "Serial number")
    [ -n "$serial" ] && printf '%s' "$serial"
}

shm_smart_get_power_on_hours() {
    local smart_out="$1"
    local hours
    hours=$(shm_smart_nvme_field "$smart_out" "Power On Hours")
    [ -z "$hours" ] && hours=$(shm_smart_attr_raw "$smart_out" "Power_On_Hours")
    [ -n "$hours" ] && printf '%s' "$hours"
}

shm_smart_get_ssd_wear() {
    local smart_out="$1"
    local used remaining
    used=$(echo "$smart_out" | grep -iE '^Percentage Used:' | head -n 1 | grep -o '[0-9]\+' | head -n 1)
    if [ -n "$used" ]; then
        printf '%s used' "${used}%"
        return 0
    fi
    remaining=$(echo "$smart_out" | grep -i 'Percent_Lifetime_Remain' | awk '{print $4}' | grep -o '[0-9]\+' | head -n 1)
    if [ -n "$remaining" ]; then
        printf '%s remaining' "${remaining}%"
        return 0
    fi
    remaining=$(echo "$smart_out" | grep -i 'Media_Wearout_Indicator' | awk '{print $4}' | grep -o '[0-9]\+' | head -n 1)
    if [ -n "$remaining" ]; then
        printf '%s remaining' "${remaining}%"
    fi
}

shm_smart_get_temperature() {
    local smart_out="$1"
    local temp
    if echo "$smart_out" | grep -qi "Temperature_Celsius"; then
        temp=$(echo "$smart_out" | grep -i "Temperature_Celsius" | awk '{print $10}')
    elif echo "$smart_out" | grep -qi "Temperature Sensor 1"; then
        temp=$(echo "$smart_out" | grep -i "Temperature Sensor 1" | grep -o '[0-9]\+' | head -n 1)
    else
        temp=$(echo "$smart_out" | grep -i "Temperature:" | grep -o '[0-9]\+' | head -n 1)
    fi
    [ -n "$temp" ] && printf '%s' "$temp"
}

shm_smart_flag_warning() {
    local -n emoji_ref=$1
    [ "$emoji_ref" != "❌" ] && emoji_ref="⚠️ "
    ERRORS=$((ERRORS + 1))
}

run_smart_check() {
    if [ ! -x "$SMART_BIN" ]; then
        shm_send_email "SnapRAID ERROR - smartctl not found" \
            "smartctl binary not found at $SMART_BIN. Please install 'smartmontools'."
        exit 1
    fi

    shm_log "--- Running: SMART Hardware Checks ---"

    local all_physical_disks base_dev info_out all_out drive_model drive_size
    local temp status_txt status_emoji health_details media_errs realloc pending
    local serial power_on_hours ssd_wear offline_uncorrect reported_uncorrect udma_crc temp_limit
    local errors_before=$ERRORS

    all_physical_disks=$(shm_get_physical_disks)
    SMART_REPORT=""

    for base_dev in $all_physical_disks; do
        [ ! -b "$base_dev" ] && continue

        info_out=$(shm_smartctl_invoke "$base_dev" -i)
        drive_model=$(echo "$info_out" | grep -iE "Device Model:|Model Number:" | sed -e 's/.*:[[:space:]]*//')
        drive_size=$(lsblk -dno SIZE "$base_dev" | xargs)
        [ -z "$drive_model" ] && drive_model="Unknown Device"

        serial=$(shm_smart_get_serial "$info_out")
        all_out=$(shm_smartctl_invoke "$base_dev" -a)
        power_on_hours=$(shm_smart_get_power_on_hours "$all_out")

        temp=$(shm_smart_get_temperature "$all_out")
        [ -z "$temp" ] && temp="N/A"

        if echo "$all_out" | grep -qiE 'SMART overall-health self-assessment test result:[[:space:]]*PASSED|PASSED|SMART Health Status:[[:space:]]*OK'; then
            status_txt="PASSED"
            status_emoji="✅"
        elif shm_is_smart_unsupported "$all_out"; then
            status_txt="UNSUPPORTED"
            status_emoji="ℹ️ "
            SMART_REPORT+="$status_emoji $base_dev [$drive_model] ($drive_size):\n"
            SMART_REPORT+="   • Hardware Health:  $status_txt\n"
            [ -n "$serial" ] && SMART_REPORT+="   • Serial:           $serial\n"
            SMART_REPORT+="\n"
            continue
        else
            status_txt="FAILED"
            status_emoji="❌"
            ERRORS=$((ERRORS + 1))
        fi

        if echo "$all_out" | grep -qi "Media and Data Integrity Errors"; then
            media_errs=$(echo "$all_out" | grep -i "Media and Data Integrity Errors" | grep -o '[0-9]\+' | head -n 1)
            [ -z "$media_errs" ] && media_errs=0
            [ "$media_errs" -gt 0 ] && shm_smart_flag_warning status_emoji
            health_details="Media Errors: $media_errs"
        else
            reallocated=$(shm_smart_attr_raw "$all_out" "Reallocated_Sector_Ct")
            pending=$(shm_smart_attr_raw "$all_out" "Current_Pending_Sector")
            [ -z "$reallocated" ] && reallocated=0
            [ -z "$pending" ] && pending=0
            { [ "$reallocated" -gt 0 ] || [ "$pending" -gt 0 ]; } && shm_smart_flag_warning status_emoji
            health_details="Reallocated Sectors: $reallocated | Pending Sectors: $pending"
        fi

        offline_uncorrect=$(shm_smart_attr_raw "$all_out" "Offline_Uncorrectable")
        reported_uncorrect=$(shm_smart_attr_raw "$all_out" "Reported_Uncorrect")
        [ -z "$offline_uncorrect" ] && offline_uncorrect=0
        [ -z "$reported_uncorrect" ] && reported_uncorrect=0
        { [ "$offline_uncorrect" -gt 0 ] || [ "$reported_uncorrect" -gt 0 ]; } && shm_smart_flag_warning status_emoji

        udma_crc=$(shm_smart_attr_raw "$all_out" "UDMA_CRC_Error_Count")
        [ -z "$udma_crc" ] && udma_crc=0
        [ "$udma_crc" -gt 0 ] && shm_smart_flag_warning status_emoji

        if [[ "$temp" =~ ^[0-9]+$ ]]; then
            if shm_is_ssd_device "$base_dev"; then
                temp_limit=$SMART_TEMP_WARN_SSD
            else
                temp_limit=$SMART_TEMP_WARN_HDD
            fi
            [ "$temp" -ge "$temp_limit" ] && shm_smart_flag_warning status_emoji
        fi

        ssd_wear=""
        if shm_is_ssd_device "$base_dev"; then
            ssd_wear=$(shm_smart_get_ssd_wear "$all_out")
        fi

        SMART_REPORT+="$status_emoji $base_dev [$drive_model] ($drive_size):\n"
        SMART_REPORT+="   • Hardware Health:  $status_txt\n"
        [ -n "$serial" ] && SMART_REPORT+="   • Serial:           $serial\n"
        [ -n "$power_on_hours" ] && SMART_REPORT+="   • Power-On Hours:   $power_on_hours\n"
        SMART_REPORT+="   • Temperature:      ${temp}°C\n"
        SMART_REPORT+="   • Disk Integrity:    $health_details\n"
        SMART_REPORT+="   • Uncorrectable:    Offline: $offline_uncorrect | Reported: $reported_uncorrect\n"
        SMART_REPORT+="   • Interface Errors: UDMA CRC: $udma_crc\n"
        [ -n "$ssd_wear" ] && SMART_REPORT+="   • SSD Wear:         $ssd_wear\n"
        SMART_REPORT+="\n"
    done

    if [ -n "$SMART_REPORT" ]; then
        local show_console=false
        [ "$ERRORS" -gt "$errors_before" ] && show_console=true
        shm_log_multiline "SMART report:" "$(printf '%b' "$SMART_REPORT")" "$show_console"
    else
        shm_log "SMART: no physical disks found"
    fi
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
