# Email notification helpers (useSend with mail fallback).

if [ -n "${SHM_MAIL_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
SHM_MAIL_LOADED=1

shm_send_email_via_mail() {
    local subject="$1"
    local body="$2"

    if ! command -v mail >/dev/null; then
        shm_log "ERROR: mail command not found"
        return 1
    fi

    printf '%s\n' "$body" | mail -s "[$HOSTNAME] $subject" "$EMAIL"
}

shm_send_email_via_usesend() {
    local subject="$1"
    local text_body="$2"
    local html_body="${3:-}"
    local full_subject="[$HOSTNAME] $subject"
    local payload http_code response_file

    response_file=$(shm_mktemp_or_exit)
    if [ -n "$html_body" ]; then
        payload=$(jq -n \
            --arg to "$EMAIL" \
            --arg from "$USESEND_FROM" \
            --arg subject "$full_subject" \
            --arg text "$text_body" \
            --arg html "$html_body" \
            '{to: $to, from: $from, subject: $subject, text: $text, html: $html}') || {
            return 1
        }
    else
        payload=$(jq -n \
            --arg to "$EMAIL" \
            --arg from "$USESEND_FROM" \
            --arg subject "$full_subject" \
            --arg text "$text_body" \
            '{to: $to, from: $from, subject: $subject, text: $text}') || {
            return 1
        }
    fi

    http_code=$(curl -sS -o "$response_file" -w '%{http_code}' \
        -X POST "${USESEND_API_URL%/}/v1/emails" \
        -H "Authorization: Bearer ${USESEND_API_KEY}" \
        -H "Content-Type: application/json" \
        --data "$payload") || {
        return 1
    }

    if [ "$http_code" = "200" ]; then
        return 0
    fi

    shm_log "useSend API error (HTTP $http_code): $(cat "$response_file" 2>/dev/null)"
    return 1
}

shm_send_email() {
    local subject="$1"
    local text_body="$2"
    local html_body="${3:-}"

    if [ -n "$USESEND_API_URL" ] && [ -n "$USESEND_FROM" ] && [ -n "$USESEND_API_KEY" ] && [ -n "$EMAIL" ]; then
        if command -v curl >/dev/null && command -v jq >/dev/null; then
            if shm_send_email_via_usesend "$subject" "$text_body" "$html_body"; then
                shm_log "Notification sent via useSend to $EMAIL"
                return 0
            fi
            shm_log "WARNING: useSend failed; falling back to mail"
        else
            shm_log "WARNING: curl or jq not found; falling back to mail"
        fi
    fi

    if shm_send_email_via_mail "$subject" "$text_body"; then
        shm_log "Notification sent via mail to $EMAIL"
        return 0
    fi
    shm_log "ERROR: Failed to send notification via mail"
    return 1
}
