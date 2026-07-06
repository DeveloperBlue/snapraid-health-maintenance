#!/bin/bash
# Disk usage checks for mounts on physical disks.

SHM_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SHM_ROOT_DIR/lib/common.sh"

run_disk_usage_check() {
    shm_log "--- Running: Disk Usage Checks ---"

    local all_physical_disks base_dev mount usage

    all_physical_disks=$(shm_get_physical_disks)
    DISK_WARNINGS=""
    DISK_SPACE_MOUNTS=()

    while read -r mount; do
        DISK_SPACE_MOUNTS+=("$mount")
        if shm_is_disk_usage_ignored "$mount"; then
            continue
        fi
        usage=$(df --output=pcent "$mount" 2>/dev/null | awk 'NR==2 { gsub(/[^0-9]/, ""); print }')
        if [ -n "$usage" ] && [[ "$usage" =~ ^[0-9]+$ ]] && [ "$usage" -ge "$DISK_USAGE_WARN_PERCENT" ]; then
            DISK_WARNINGS+="⚠️  $mount is at ${usage}% capacity\n"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(
        for base_dev in $all_physical_disks; do
            [ ! -b "$base_dev" ] && continue
            lsblk -ln -o MOUNTPOINT "$base_dev" 2>/dev/null
        done | sed '/^$/d' | sort -u
    )
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    shm_require_root
    shm_load_config
    shm_setup_logging

    shm_log "=================================================="
    shm_log "Disk usage check started"
    shm_log "=================================================="
    run_disk_usage_check

    if [ ${#DISK_SPACE_MOUNTS[@]} -gt 0 ]; then
        df -h "${DISK_SPACE_MOUNTS[@]}" 2>/dev/null
    else
        echo "(no mounted filesystems on physical disks)"
    fi
    if [ -n "$DISK_WARNINGS" ]; then
        printf '%b\n' "$DISK_WARNINGS"
    fi

    shm_log "Disk usage check finished. Errors: $ERRORS"
    [ "$ERRORS" -gt 0 ] && exit 1
    exit 0
fi
