# Shared configuration, logging, and helpers for snapraid-health-maintenance.

if [ -n "${SHM_COMMON_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
SHM_COMMON_LOADED=1

SHM_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SNAPRAID_HEALTH_CONFIG:-$SHM_ROOT_DIR/snapraid-health-maintenance.conf}"

TEMP_FILES=()
ERRORS=0
REPORT=""
STATUS_OUTPUT=""
SMART_REPORT=""
DISK_WARNINGS=""
DISK_SPACE_MOUNTS=()

shm_load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: Config not found at $CONFIG_FILE"
        echo "Copy snapraid-health-maintenance.conf.example to snapraid-health-maintenance.conf and edit it."
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    LOG_DIR="${LOG_DIR:-/var/log/snapraid-health-maintenance}"
    SCRUB_PERCENT="${SCRUB_PERCENT:-20}"
    HOSTNAME="${HOSTNAME:-$(hostname)}"
    SNAPRAID_BIN="${SNAPRAID_BIN:-}"
    SMART_BIN="${SMART_BIN:-}"
    DISK_USAGE_WARN_PERCENT="${DISK_USAGE_WARN_PERCENT:-90}"
    DISK_USAGE_IGNORE_MOUNTS="${DISK_USAGE_IGNORE_MOUNTS:-}"
    LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-60}"
    USESEND_API_URL="${USESEND_API_URL:-}"
    USESEND_FROM="${USESEND_FROM:-}"
    USESEND_API_KEY="${USESEND_API_KEY:-}"

    set -uo pipefail

    if [ -z "${EMAIL:-}" ]; then
        echo "ERROR: EMAIL is not set in $CONFIG_FILE"
        echo "Set EMAIL to the address that should receive alerts."
        exit 1
    fi

    if [ -z "$SNAPRAID_BIN" ]; then
        SNAPRAID_BIN=$(which snapraid 2>/dev/null || echo "/usr/bin/snapraid")
    fi
    if [ -z "$SMART_BIN" ]; then
        SMART_BIN=$(which smartctl 2>/dev/null || echo "/usr/sbin/smartctl")
    fi
}

shm_require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: This script must be run as root (use sudo)."
        exit 1
    fi
}

shm_cleanup_temp_files() {
    rm -f "${TEMP_FILES[@]}"
}

shm_mktemp_or_exit() {
    local tmp
    tmp=$(mktemp) || {
        echo "ERROR: mktemp failed"
        exit 1
    }
    TEMP_FILES+=("$tmp")
    printf '%s' "$tmp"
}

shm_setup_logging() {
    if ! mkdir -p "$LOG_DIR"; then
        echo "ERROR: Cannot create log directory: $LOG_DIR"
        exit 1
    fi

    LOG_FILE="$LOG_DIR/snapraid-$(date +%Y-%m-%d).log"
    trap shm_cleanup_temp_files EXIT INT TERM
    shm_rotate_old_logs
}

shm_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

shm_rotate_old_logs() {
    [ "$LOG_RETENTION_DAYS" -eq 0 ] 2>/dev/null && return 0

    local deleted
    deleted=$(find "$LOG_DIR" -maxdepth 1 -name 'snapraid-*.log' -type f -mtime +"$LOG_RETENTION_DAYS" 2>/dev/null | wc -l)
    [ "$deleted" -eq 0 ] && return 0

    find "$LOG_DIR" -maxdepth 1 -name 'snapraid-*.log' -type f -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
    shm_log "Rotated $deleted log file(s) older than ${LOG_RETENTION_DAYS} days."
}

# shellcheck source=lib/mail.sh
source "$SHM_ROOT_DIR/lib/mail.sh"

shm_normalize_mount_path() {
    local path="${1%/}"
    [ -z "$path" ] && path="/"
    printf '%s' "$path"
}

shm_is_disk_usage_ignored() {
    local mount="$1"
    local normalized_mount ignored normalized_ignored
    normalized_mount=$(shm_normalize_mount_path "$mount")
    for ignored in $DISK_USAGE_IGNORE_MOUNTS; do
        normalized_ignored=$(shm_normalize_mount_path "$ignored")
        [ "$normalized_mount" = "$normalized_ignored" ] && return 0
    done
    return 1
}

shm_get_physical_disks() {
    lsblk -d -n -o NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}'
}

shm_smartctl_invoke() {
    local dev="$1"
    shift
    local -a args=()
    case "$dev" in
        /dev/nvme*) args=(-d nvme) ;;
    esac
    $SMART_BIN "${args[@]}" "$@" "$dev" 2>&1
}

shm_is_smart_unsupported() {
    echo "$1" | grep -qiE 'Unavailable|unable to detect device type|Read SMART Data failed|Unsupported|Unknown USB bridge'
}
