# Command-line flag parsing for snapraid-health-maintenance.sh.

if [ -n "${SHM_ARGS_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
SHM_ARGS_LOADED=1

RUN_SNAPRAID_SYNC=false
RUN_SNAPRAID_SCRUB=false
RUN_SNAPRAID_STATUS=false
RUN_SMART=false
RUN_DISK_USAGE=false
SKIP_SUCCESS_REPORT=false
RUN_DESC=""

shm_usage() {
    cat <<EOF
Usage: snapraid-health-maintenance.sh [OPTIONS]

Options:
  --snapraid-sync         Run touch, sync, and status
  --snapraid-scrub        Run scrub and status
  --snapraid-status       Run snapraid status only (read-only)
  --smart                 Run SMART hardware checks
  --disk-usage            Run disk usage checks
  --skip-success-report   Suppress summary email when no errors
  --status                Preset: --snapraid-status --smart --disk-usage

With no options, all check modes run (snapraid-sync, snapraid-scrub, smart, disk-usage).
EOF
}

shm_build_run_desc() {
    local -a parts=()
    [ "$RUN_SNAPRAID_SYNC" = true ] && parts+=("snapraid-sync")
    [ "$RUN_SNAPRAID_SCRUB" = true ] && parts+=("snapraid-scrub")
    [ "$RUN_SNAPRAID_STATUS" = true ] && parts+=("snapraid-status")
    [ "$RUN_DISK_USAGE" = true ] && parts+=("disk-usage")
    [ "$RUN_SMART" = true ] && parts+=("smart")
    if [ ${#parts[@]} -eq 0 ]; then
        RUN_DESC="(none)"
    else
        RUN_DESC=$(IFS=', '; echo "${parts[*]}")
    fi
}

shm_parse_args() {
    RUN_SNAPRAID_SYNC=false
    RUN_SNAPRAID_SCRUB=false
    RUN_SNAPRAID_STATUS=false
    RUN_SMART=false
    RUN_DISK_USAGE=false
    SKIP_SUCCESS_REPORT=false

    if [ $# -eq 0 ]; then
        RUN_SNAPRAID_SYNC=true
        RUN_SNAPRAID_SCRUB=true
        RUN_SMART=true
        RUN_DISK_USAGE=true
        shm_build_run_desc
        return 0
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --snapraid-sync)
                RUN_SNAPRAID_SYNC=true
                ;;
            --snapraid-scrub)
                RUN_SNAPRAID_SCRUB=true
                ;;
            --snapraid-status)
                RUN_SNAPRAID_STATUS=true
                ;;
            --smart)
                RUN_SMART=true
                ;;
            --disk-usage)
                RUN_DISK_USAGE=true
                ;;
            --skip-success-report)
                SKIP_SUCCESS_REPORT=true
                ;;
            --status)
                RUN_SNAPRAID_STATUS=true
                RUN_SMART=true
                RUN_DISK_USAGE=true
                ;;
            -h|--help)
                shm_usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo >&2
                shm_usage >&2
                exit 1
                ;;
        esac
        shift
    done

    shm_build_run_desc
}

shm_any_snapraid() {
    [ "$RUN_SNAPRAID_SYNC" = true ] || [ "$RUN_SNAPRAID_SCRUB" = true ] || [ "$RUN_SNAPRAID_STATUS" = true ]
}
