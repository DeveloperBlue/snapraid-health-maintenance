# HTML and plain-text maintenance report builders.

if [ -n "${SHM_REPORT_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
SHM_REPORT_LOADED=1

EMAIL_BODY_TEXT=""
EMAIL_BODY_HTML=""

shm_html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

shm_get_repo_commit_info() {
    if ! git -C "$SHM_ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '%s' "unknown"
        return 0
    fi

    git -C "$SHM_ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf '%s' "unknown"
}

shm_is_snapraid_chart_line() {
    local line="$1"
    [[ "$line" == *"|"* ]] || return 1
    local after="${line#*|}"
    echo "$after" | grep -Eq '^[ *o_]+$'
}

shm_html_colorize_chart_line() {
    local line="$1"
    local before="${line%%|*}"
    local after="${line#*|}"
    local colored i c

    colored="$(shm_html_escape "$before")|"
    for ((i = 0; i < ${#after}; i++)); do
        c="${after:i:1}"
        case "$c" in
            '*')
                colored+='<span style="color:#2e7d32;font-weight:bold;">*</span>'
                ;;
            o)
                colored+='<span style="color:#ef6c00;font-weight:bold;">o</span>'
                ;;
            _)
                colored+='<span style="color:#bdbdbd;">_</span>'
                ;;
            ' ')
                colored+='&nbsp;'
                ;;
            *)
                colored+=$(shm_html_escape "$c")
                ;;
        esac
    done
    printf '%s' "$colored"
}

shm_html_format_snapraid_status() {
    local text="$1"
    local html="" in_chart=false chart_lines=""

    if [ -z "$text" ]; then
        printf '%s' '<p style="color:#666;">(no status output)</p>'
        return 0
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        if shm_is_snapraid_chart_line "$line"; then
            if [ "$in_chart" = false ]; then
                in_chart=true
                chart_lines=""
            fi
            chart_lines+="$(shm_html_colorize_chart_line "$line")"$'\n'
            continue
        fi

        if [ "$in_chart" = true ]; then
            html+='<div style="font-family:Courier New,Courier,monospace;font-size:11px;line-height:1.2;background:#fafafa;border:1px solid #e0e0e0;border-radius:4px;padding:12px 14px;overflow-x:auto;margin:12px 0;white-space:pre;">'
            html+="$chart_lines"
            html+='</div>'
            html+='<p style="font-size:12px;color:#666;margin:4px 0 12px 0;">'
            html+='<span style="margin-right:16px;"><span style="color:#2e7d32;font-weight:bold;">*</span> scrubbed</span>'
            html+='<span><span style="color:#ef6c00;font-weight:bold;">o</span> synced, not yet scrubbed</span>'
            html+='</p>'
            in_chart=false
            chart_lines=""
        fi

        if [ -n "$line" ]; then
            html+="<div style=\"margin:2px 0;font-size:13px;\">$(shm_html_escape "$line")</div>"
        else
            html+='<div style="height:8px;"></div>'
        fi
    done <<< "$text"

    if [ "$in_chart" = true ]; then
        html+='<div style="font-family:Courier New,Courier,monospace;font-size:11px;line-height:1.2;background:#fafafa;border:1px solid #e0e0e0;border-radius:4px;padding:12px 14px;overflow-x:auto;margin:12px 0;white-space:pre;">'
        html+="$chart_lines"
        html+='</div>'
        html+='<p style="font-size:12px;color:#666;margin:4px 0 12px 0;">'
        html+='<span style="margin-right:16px;"><span style="color:#2e7d32;font-weight:bold;">*</span> scrubbed</span>'
        html+='<span><span style="color:#ef6c00;font-weight:bold;">o</span> synced, not yet scrubbed</span>'
        html+='</p>'
    fi

    printf '%s' "$html"
}

shm_html_usage_bar() {
    local pct="$1"
    local color="#43a047"

    if [ "$pct" -ge 95 ] 2>/dev/null; then
        color="#c62828"
    elif [ "$pct" -ge "$DISK_USAGE_WARN_PERCENT" ] 2>/dev/null; then
        color="#ef6c00"
    fi

    printf '<span style="display:inline-block;width:72px;height:8px;background:#e0e0e0;border-radius:4px;vertical-align:middle;margin-right:8px;"><span style="display:block;width:%d%%;max-width:100%%;height:8px;background:%s;border-radius:4px;"></span></span>%s%%' \
        "$pct" "$color" "$pct"
}

shm_disk_space_identity() {
    local source="$1"
    local model serial

    model=$(shm_get_disk_model "$source")
    serial=$(shm_get_disk_serial "$source")
    [ -z "$model" ] && model="Unknown"
    [ -z "$serial" ] && serial="—"
    printf '%s\t%s' "$model" "$serial"
}

shm_text_disk_space_table() {
    local mounts=("$@")
    local line source size used avail pcent target pct model serial

    if [ ${#mounts[@]} -eq 0 ]; then
        printf '%s' '(no mounted filesystems on physical disks)'
        return 0
    fi

    printf '%-16s %-28s %-16s %6s %6s %6s %5s %s\n' \
        "Filesystem" "Model" "Serial" "Size" "Used" "Avail" "Use%" "Mount"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        read -r source size used avail pcent target <<< "$line"
        pct="${pcent%%%}"
        [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
        IFS=$'\t' read -r model serial <<< "$(shm_disk_space_identity "$source")"

        printf '%-16s %-28s %-16s %6s %6s %6s %4s%% %s\n' \
            "$source" "$model" "$serial" "$size" "$used" "$avail" "$pct" "$target"
    done < <(df -h --output=source,size,used,avail,pcent,target "${mounts[@]}" 2>/dev/null | tail -n +2)
}

shm_html_disk_space_table() {
    local mounts=("$@")
    local line source size used avail pcent target pct model serial

    if [ ${#mounts[@]} -eq 0 ]; then
        printf '%s' '<p style="color:#666;">(no mounted filesystems on physical disks)</p>'
        return 0
    fi

    printf '%s' '<table style="border-collapse:collapse;width:100%%;font-size:13px;margin-top:4px;">'
    printf '%s' '<tr style="background:#f5f5f5;">'
    printf '%s' '<th style="padding:10px 12px;text-align:left;border-bottom:2px solid #e0e0e0;">Filesystem</th>'
    printf '%s' '<th style="padding:10px 12px;text-align:left;border-bottom:2px solid #e0e0e0;">Model</th>'
    printf '%s' '<th style="padding:10px 12px;text-align:left;border-bottom:2px solid #e0e0e0;">Serial</th>'
    printf '%s' '<th style="padding:10px 12px;text-align:right;border-bottom:2px solid #e0e0e0;">Size</th>'
    printf '%s' '<th style="padding:10px 12px;text-align:right;border-bottom:2px solid #e0e0e0;">Used</th>'
    printf '%s' '<th style="padding:10px 12px;text-align:right;border-bottom:2px solid #e0e0e0;">Avail</th>'
    printf '%s' '<th style="padding:10px 12px;text-align:left;border-bottom:2px solid #e0e0e0;">Use</th>'
    printf '%s' '<th style="padding:10px 12px;text-align:left;border-bottom:2px solid #e0e0e0;">Mount</th>'
    printf '%s' '</tr>'

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        read -r source size used avail pcent target <<< "$line"
        pct="${pcent%%%}"
        [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
        IFS=$'\t' read -r model serial <<< "$(shm_disk_space_identity "$source")"

        printf '<tr>'
        printf '<td style="padding:10px 12px;border-bottom:1px solid #eee;font-family:Courier New,Courier,monospace;font-size:12px;">%s</td>' "$(shm_html_escape "$source")"
        printf '<td style="padding:10px 12px;border-bottom:1px solid #eee;">%s</td>' "$(shm_html_escape "$model")"
        printf '<td style="padding:10px 12px;border-bottom:1px solid #eee;font-family:Courier New,Courier,monospace;font-size:12px;">%s</td>' "$(shm_html_escape "$serial")"
        printf '<td style="padding:10px 12px;border-bottom:1px solid #eee;text-align:right;">%s</td>' "$(shm_html_escape "$size")"
        printf '<td style="padding:10px 12px;border-bottom:1px solid #eee;text-align:right;">%s</td>' "$(shm_html_escape "$used")"
        printf '<td style="padding:10px 12px;border-bottom:1px solid #eee;text-align:right;">%s</td>' "$(shm_html_escape "$avail")"
        printf '<td style="padding:10px 12px;border-bottom:1px solid #eee;white-space:nowrap;">%s</td>' "$(shm_html_usage_bar "$pct")"
        printf '<td style="padding:10px 12px;border-bottom:1px solid #eee;">%s</td>' "$(shm_html_escape "$target")"
        printf '</tr>'
    done < <(df -h --output=source,size,used,avail,pcent,target "${mounts[@]}" 2>/dev/null | tail -n +2)

    printf '%s' '</table>'
}

shm_is_smart_drive_line() {
    echo "$1" | grep -qE '/dev/[^[:space:]]+ \[.+\] \(.+\):$'
}

shm_html_format_smart_report() {
    local text="$1"
    local html="" drive_line="" line expanded

    if [ -z "$text" ]; then
        printf '%s' '<p style="color:#666;">(no SMART data)</p>'
        return 0
    fi

    expanded=$(printf '%b' "$text")

    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue

        if shm_is_smart_drive_line "$line"; then
            [ -n "$drive_line" ] && html+='</div>'
            html+='<div style="background:#fafafa;border:1px solid #e8e8e8;border-radius:6px;padding:14px 16px;margin-bottom:14px;">'
            html+="<div style=\"font-size:14px;font-weight:600;margin-bottom:8px;\">$(shm_html_escape "$line")</div>"
            drive_line="$line"
            continue
        fi

        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#• }"
        html+="<div style=\"font-size:13px;color:#555;margin:4px 0;padding-left:4px;\">$(shm_html_escape "$line")</div>"
    done <<< "$expanded"

    [ -n "$drive_line" ] && html+='</div>'
    printf '%s' "$html"
}

shm_html_format_result_lines() {
    local text="$1"
    local html="" line class

    if [ -z "$text" ]; then
        printf '%s' '<p style="color:#666;">(no results)</p>'
        return 0
    fi

    html+='<div style="font-size:13px;line-height:1.6;">'
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        class=""
        case "$line" in
            *FAILED*|❌*) class='color:#c62828;' ;;
            *⚠️*) class='color:#ef6c00;' ;;
            *✅*) class='color:#2e7d32;' ;;
        esac
        html+="<div style=\"margin:6px 0;${class}\">$(shm_html_escape "$line")</div>"
    done <<< "$(printf '%b' "$text")"
    html+='</div>'
    printf '%s' "$html"
}

shm_html_format_preformatted() {
    local text="$1"
    printf '<pre style="font-family:Courier New,Courier,monospace;font-size:12px;background:#f5f5f5;padding:12px 14px;border-radius:4px;overflow-x:auto;white-space:pre-wrap;margin:0;">%s</pre>' \
        "$(shm_html_escape "$text")"
}

shm_html_section() {
    local title="$1"
    local body="$2"
    printf '<section style="margin-bottom:36px;padding-bottom:28px;border-bottom:1px solid #e8e8e8;">'
    printf '<h2 style="font-size:14px;font-weight:600;color:#555;text-transform:uppercase;letter-spacing:0.4px;margin:0 0 14px 0;">%s</h2>' \
        "$(shm_html_escape "$title")"
    printf '<div>%s</div>' "$body"
    printf '</section>'
}

shm_text_section() {
    local title="$1"
    local body="$2"
    printf '\n\n%s\n%s' "$title" "$body"
}

shm_build_maintenance_report() {
    local hostname="$1"
    local run_date="$2"
    local run_desc="$3"
    local duration="$4"
    local errors="$5"
    local log_file="$6"
    local run_disk_usage="$7"
    local run_smart="$8"
    local run_snapraid_scrub="$9"

    local repo_commit disk_space_text disk_space_html warnings_html warnings_text
    local status_html smart_html results_html history_text sections_html=""

    repo_commit=$(shm_get_repo_commit_info)

    EMAIL_BODY_TEXT=$(cat <<EOF
Maintenance Report for $hostname
Run date:   $run_date
Execution:  $run_desc
Duration:   $duration minutes
Errors:     $errors
Commit ID:  $repo_commit
EOF
)

    local status_color="#2e7d32"
    [ "$errors" -gt 0 ] && status_color="#c62828"

    local summary_html
    summary_html=$(cat <<EOF
<h1 style="font-size:22px;margin:0 0 16px 0;color:#222;">Maintenance Report</h1>
<table style="border-collapse:collapse;font-size:14px;margin-bottom:8px;">
<tr><td style="padding:5px 20px 5px 0;color:#666;font-weight:500;">Host</td><td style="padding:5px 0;">$(shm_html_escape "$hostname")</td></tr>
<tr><td style="padding:5px 20px 5px 0;color:#666;font-weight:500;">Run date</td><td style="padding:5px 0;">$(shm_html_escape "$run_date")</td></tr>
<tr><td style="padding:5px 20px 5px 0;color:#666;font-weight:500;">Execution</td><td style="padding:5px 0;">$(shm_html_escape "$run_desc")</td></tr>
<tr><td style="padding:5px 20px 5px 0;color:#666;font-weight:500;">Duration</td><td style="padding:5px 0;">${duration} minutes</td></tr>
<tr><td style="padding:5px 20px 5px 0;color:#666;font-weight:500;">Errors</td><td style="padding:5px 0;color:${status_color};font-weight:600;">$errors</td></tr>
<tr><td style="padding:5px 20px 5px 0;color:#666;font-weight:500;">Commit ID</td><td style="padding:5px 0;font-family:Courier New,Courier,monospace;font-size:13px;">$(shm_html_escape "$repo_commit")</td></tr>
</table>
EOF
)

    sections_html="$summary_html"

    if shm_any_snapraid && [ -n "$REPORT" ]; then
        results_html=$(shm_html_format_result_lines "$REPORT")
        sections_html+=$(shm_html_section "SnapRAID Results" "$results_html")
        EMAIL_BODY_TEXT+=$(shm_text_section "--- SnapRAID Results ---" "$(printf '%b' "$REPORT")")
    fi

    if [ "$run_disk_usage" = true ] || [ "$run_smart" = true ]; then
        if [ ${#DISK_SPACE_MOUNTS[@]} -gt 0 ]; then
            disk_space_text=$(shm_text_disk_space_table "${DISK_SPACE_MOUNTS[@]}")
            disk_space_html=$(shm_html_disk_space_table "${DISK_SPACE_MOUNTS[@]}")
        else
            disk_space_text="(no mounted filesystems on physical disks)"
            disk_space_html='<p style="color:#666;">(no mounted filesystems on physical disks)</p>'
        fi

        sections_html+=$(shm_html_section "Disk Space Allocation" "$disk_space_html")
        EMAIL_BODY_TEXT+=$(shm_text_section "--- Disk Space Allocation ---" "$disk_space_text")

        if [ -n "$DISK_WARNINGS" ]; then
            warnings_text=$(printf '%b' "$DISK_WARNINGS")
            warnings_html='<div style="margin-top:14px;">'
            while IFS= read -r line || [ -n "$line" ]; do
                [ -z "$line" ] && continue
                warnings_html+="<p style=\"margin:8px 0;color:#ef6c00;font-size:13px;\">$(shm_html_escape "$line")</p>"
            done <<< "$warnings_text"
            warnings_html+='</div>'
            sections_html+=$(shm_html_section "Disk Usage Warnings" "$warnings_html")
            EMAIL_BODY_TEXT+=$(shm_text_section "--- Disk Usage Warnings ---" "$warnings_text")
        fi
    fi

    if [ "$run_smart" = true ]; then
        smart_html=$(shm_html_format_smart_report "$SMART_REPORT")
        sections_html+=$(shm_html_section "Global SMART Hardware Health Report" "$smart_html")
        EMAIL_BODY_TEXT+=$(shm_text_section "--- Global SMART Hardware Health Report ---" "$(printf '%b' "$SMART_REPORT")")
    fi

    if [ "$run_snapraid_scrub" = true ]; then
        history_text=$(grep -h "maintenance finished\." "$LOG_DIR"/snapraid-*.log 2>/dev/null | sort | tail -n 7)
        if [ -n "$history_text" ]; then
            sections_html+=$(shm_html_section "Past 7 Days Run Summaries" "$(shm_html_format_preformatted "$history_text")")
            EMAIL_BODY_TEXT+=$(shm_text_section "--- Past 7 Days Run Summaries ---" "$history_text")
        fi
    fi

    if shm_any_snapraid && [ -n "$STATUS_OUTPUT" ]; then
        status_html=$(shm_html_format_snapraid_status "$STATUS_OUTPUT")
        sections_html+=$(shm_html_section "SnapRAID Status Snapshot" "$status_html")
        EMAIL_BODY_TEXT+=$(shm_text_section "--- SnapRAID Status Snapshot ---" "$STATUS_OUTPUT")
    fi

    sections_html+=$(shm_html_section "Log Reference Location" "$(shm_html_format_preformatted "$log_file")")
    EMAIL_BODY_TEXT+=$(shm_text_section "--- Log Reference Location ---" "$log_file")

    EMAIL_BODY_HTML=$(cat <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
</head>
<body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#333;line-height:1.5;max-width:820px;margin:0 auto;padding:20px 16px 32px 16px;background:#fff;">
$sections_html
</body>
</html>
EOF
)
}
