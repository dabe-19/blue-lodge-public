#!/bin/bash
# ── George: G-Suite Integration ────────────────────────────────
# Google Workspace API integration: Gmail, Drive, Docs.
# Uses OAuth2 device authorization flow (no browser redirect needed).
#
# Auth flow:
#   1. User provides client_id and client_secret (from Google Cloud Console)
#   2. George initiates device auth flow — user visits a URL and enters a code
#   3. Access token + refresh token stored in secrets vault
#   4. Tokens auto-refresh when expired
#
# Dependencies: curl, jq, lib/api.sh, lib/secrets.sh

[ -n "${_LIB_GSUITE_LOADED:-}" ] && return 0; _LIB_GSUITE_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
GOOGLE_AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL="https://oauth2.googleapis.com/token"
GOOGLE_DEVICE_URL="https://oauth2.googleapis.com/device/code"
GOOGLE_SCOPES="https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/documents"

GMAIL_API="https://gmail.googleapis.com/gmail/v1"
DRIVE_API="https://www.googleapis.com/drive/v3"
DOCS_API="https://docs.googleapis.com/v1"

# ── Check availability ────────────────────────────────────────
gsuite_available() {
    command -v curl &>/dev/null && command -v jq &>/dev/null
}

# ── Setup OAuth2 credentials ──────────────────────────────────
# User must provide client_id and client_secret from Google Cloud Console
gsuite_setup() {
    local client_id="$1"
    local client_secret="$2"

    if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
        ui_section "Google Workspace Setup"
        ui_info "To use G-Suite features, you need OAuth2 credentials:"
        ui_dim "  1. Go to https://console.cloud.google.com/apis/credentials"
        ui_dim "  2. Create an OAuth 2.0 Client ID (type: TV/Limited Input)"
        ui_dim "  3. Enable Gmail, Drive, and Docs APIs"
        ui_dim "  4. Run: /gsuite setup <client_id> <client_secret>"
        return 1
    fi

    # Ensure secrets vault is available
    if ! declare -f secrets_set &>/dev/null; then
        ui_err "Secrets vault not loaded"
        return 1
    fi

    secrets_set "google_client_id" "$client_id"
    secrets_set "google_client_secret" "$client_secret"
    ui_ok "Google OAuth2 credentials stored in vault"
    return 0
}

# ── Check if authenticated ────────────────────────────────────
gsuite_is_authenticated() {
    declare -f secrets_exists &>/dev/null || return 1
    secrets_exists "google_access_token"
}

# ── Device authorization flow ─────────────────────────────────
# OAuth2 for devices without browsers — user visits a URL on any device
gsuite_auth() {
    if ! gsuite_available; then
        ui_err "curl and jq required for G-Suite integration"
        return 1
    fi

    local client_id client_secret
    client_id=$(secrets_get "google_client_id" 2>/dev/null) || {
        ui_err "No Google credentials. Run: /gsuite setup <client_id> <client_secret>"
        return 1
    }
    client_secret=$(secrets_get "google_client_secret" 2>/dev/null) || {
        ui_err "No Google credentials. Run: /gsuite setup <client_id> <client_secret>"
        return 1
    }

    # Step 1: Request device code
    ui_step "Initiating Google device authorization..."
    local response
    response=$(curl -s -X POST "$GOOGLE_DEVICE_URL" \
        -d "client_id=${client_id}" \
        -d "scope=${GOOGLE_SCOPES}")

    local device_code user_code verification_url interval expires_in
    device_code=$(echo "$response" | jq -r '.device_code // empty')
    user_code=$(echo "$response" | jq -r '.user_code // empty')
    verification_url=$(echo "$response" | jq -r '.verification_url // empty')
    interval=$(echo "$response" | jq -r '.interval // 5')
    expires_in=$(echo "$response" | jq -r '.expires_in // 300')

    if [ -z "$device_code" ] || [ -z "$user_code" ]; then
        ui_err "Device auth failed: $(echo "$response" | jq -r '.error_description // .error // "unknown"')"
        return 1
    fi

    # Step 2: Show user instructions
    echo ""
    ui_section "Google Authorization"
    printf "  Visit: %b%s%b\n" "$C_CYAN" "$verification_url" "$C_RESET"
    printf "  Enter code: %b%s%b\n\n" "$C_WHITE" "$user_code" "$C_RESET"
    ui_dim "  Waiting for authorization (expires in ${expires_in}s)..."

    # Step 3: Poll for token
    local deadline=$(( $(date +%s) + expires_in ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep "$interval"

        local token_response
        token_response=$(curl -s -X POST "$GOOGLE_TOKEN_URL" \
            -d "client_id=${client_id}" \
            -d "client_secret=${client_secret}" \
            -d "device_code=${device_code}" \
            -d "grant_type=urn:ietf:params:oauth:grant_type:device_code")

        local access_token refresh_token error
        access_token=$(echo "$token_response" | jq -r '.access_token // empty')
        refresh_token=$(echo "$token_response" | jq -r '.refresh_token // empty')
        error=$(echo "$token_response" | jq -r '.error // empty')

        if [ -n "$access_token" ]; then
            # Store tokens in vault
            secrets_set "google_access_token" "$access_token"
            [ -n "$refresh_token" ] && secrets_set "google_refresh_token" "$refresh_token"

            local expiry
            expiry=$(echo "$token_response" | jq -r '.expires_in // 3600')
            secrets_set "google_token_expiry" "$(( $(date +%s) + expiry ))"

            echo ""
            ui_ok "Google authorization successful"
            return 0
        fi

        case "$error" in
            authorization_pending) continue ;;
            slow_down) (( interval += 2 )) ;;
            *)
                ui_err "Auth failed: $(echo "$token_response" | jq -r '.error_description // .error')"
                return 1
                ;;
        esac
    done

    ui_err "Authorization timed out"
    return 1
}

# ── Refresh access token ──────────────────────────────────────
_gsuite_refresh_token() {
    local client_id client_secret refresh_token
    client_id=$(secrets_get "google_client_id" 2>/dev/null) || return 1
    client_secret=$(secrets_get "google_client_secret" 2>/dev/null) || return 1
    refresh_token=$(secrets_get "google_refresh_token" 2>/dev/null) || return 1

    local response
    response=$(curl -s -X POST "$GOOGLE_TOKEN_URL" \
        -d "client_id=${client_id}" \
        -d "client_secret=${client_secret}" \
        -d "refresh_token=${refresh_token}" \
        -d "grant_type=refresh_token")

    local access_token
    access_token=$(echo "$response" | jq -r '.access_token // empty')

    if [ -n "$access_token" ]; then
        secrets_set "google_access_token" "$access_token"
        local expiry
        expiry=$(echo "$response" | jq -r '.expires_in // 3600')
        secrets_set "google_token_expiry" "$(( $(date +%s) + expiry ))"
        return 0
    fi

    return 1
}

# ── Get valid access token (auto-refresh if expired) ──────────
_gsuite_get_token() {
    local expiry
    expiry=$(secrets_get "google_token_expiry" 2>/dev/null || echo "0")

    if [ "$(date +%s)" -ge "${expiry:-0}" ]; then
        _gsuite_refresh_token || return 1
    fi

    secrets_get "google_access_token"
}

# ── Authenticated API call ────────────────────────────────────
_gsuite_api() {
    local method="$1"
    local url="$2"
    shift 2
    local extra_args=("$@")

    local token
    token=$(_gsuite_get_token) || {
        ui_err "Not authenticated. Run: /gsuite auth"
        return 1
    }

    curl -s -X "$method" "$url" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        "${extra_args[@]}"
}

# ═══════════════════════════════════════════════════════════════
# Gmail
# ═══════════════════════════════════════════════════════════════

# ── List recent emails ────────────────────────────────────────
gmail_list() {
    local query="${1:-is:unread}"
    local max="${2:-10}"

    local response
    response=$(_gsuite_api GET "${GMAIL_API}/users/me/messages?q=$(printf '%s' "$query" | jq -sRr @uri)&maxResults=${max}")
    
    local messages
    messages=$(echo "$response" | jq -r '.messages[]?.id // empty' 2>/dev/null)

    if [ -z "$messages" ]; then
        ui_dim "  No messages found"
        return 0
    fi

    while read -r msg_id; do
        [ -z "$msg_id" ] && continue
        local msg
        msg=$(_gsuite_api GET "${GMAIL_API}/users/me/messages/${msg_id}?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date")

        local subject from date_header
        subject=$(echo "$msg" | jq -r '.payload.headers[] | select(.name=="Subject") | .value // "No Subject"' 2>/dev/null)
        from=$(echo "$msg" | jq -r '.payload.headers[] | select(.name=="From") | .value // "Unknown"' 2>/dev/null)
        date_header=$(echo "$msg" | jq -r '.payload.headers[] | select(.name=="Date") | .value // ""' 2>/dev/null)

        printf "  %b%s%b  %s\n" "$C_WHITE" "${subject:0:50}" "$C_RESET" "${from:0:40}"
        [ -n "$date_header" ] && printf "    %b%s%b\n" "$C_DIM" "${date_header:0:30}" "$C_RESET"
    done <<< "$messages"
}

# ── Read an email ─────────────────────────────────────────────
gmail_read() {
    local msg_id="$1"
    if [ -z "$msg_id" ]; then
        ui_err "Usage: gmail_read <message_id>"
        return 1
    fi

    local msg
    msg=$(_gsuite_api GET "${GMAIL_API}/users/me/messages/${msg_id}?format=full")

    local subject from body
    subject=$(echo "$msg" | jq -r '.payload.headers[] | select(.name=="Subject") | .value // "No Subject"' 2>/dev/null)
    from=$(echo "$msg" | jq -r '.payload.headers[] | select(.name=="From") | .value // "Unknown"' 2>/dev/null)

    # Try to get plain text body
    body=$(echo "$msg" | jq -r '
        .payload.parts[]? | select(.mimeType=="text/plain") | .body.data // empty
    ' 2>/dev/null | head -1)

    if [ -z "$body" ]; then
        # Fallback to top-level body
        body=$(echo "$msg" | jq -r '.payload.body.data // empty' 2>/dev/null)
    fi

    echo ""
    printf "%bFrom:%b %s\n" "$C_CYAN" "$C_RESET" "$from"
    printf "%bSubject:%b %s\n\n" "$C_CYAN" "$C_RESET" "$subject"

    if [ -n "$body" ]; then
        echo "$body" | base64 -d 2>/dev/null | head -80
    else
        ui_dim "(No plain text body available)"
    fi
}

# ── Send an email ─────────────────────────────────────────────
gmail_send() {
    local to="$1"
    local subject="$2"
    local body="$3"

    if [ -z "$to" ] || [ -z "$subject" ] || [ -z "$body" ]; then
        ui_err "Usage: gmail_send <to> <subject> <body>"
        return 1
    fi

    # Construct RFC 2822 message and base64url encode
    local raw_msg="From: me
To: ${to}
Subject: ${subject}
Content-Type: text/plain; charset=utf-8

${body}"

    local encoded
    encoded=$(echo -n "$raw_msg" | base64 -w 0 | tr '+/' '-_' | tr -d '=')

    local response
    response=$(_gsuite_api POST "${GMAIL_API}/users/me/messages/send" \
        -d "{\"raw\": \"${encoded}\"}")

    local msg_id
    msg_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)

    if [ -n "$msg_id" ]; then
        ui_ok "Email sent (ID: $msg_id)"
    else
        ui_err "Failed to send: $(echo "$response" | jq -r '.error.message // "unknown error"' 2>/dev/null)"
        return 1
    fi
}

# ── Search emails ─────────────────────────────────────────────
gmail_search() {
    local query="$1"
    local max="${2:-10}"
    gmail_list "$query" "$max"
}

# ═══════════════════════════════════════════════════════════════
# Google Drive
# ═══════════════════════════════════════════════════════════════

# ── List files ────────────────────────────────────────────────
drive_list() {
    local query="${1:-}"
    local max="${2:-20}"

    local url="${DRIVE_API}/files?pageSize=${max}&fields=files(id,name,mimeType,modifiedTime,size)"
    [ -n "$query" ] && url="${url}&q=$(printf '%s' "$query" | jq -sRr @uri)"

    local response
    response=$(_gsuite_api GET "$url")

    echo "$response" | jq -r '.files[]? | "\(.name)\t\(.mimeType)\t\(.size // "?")\t\(.id)"' 2>/dev/null | \
    while IFS=$'\t' read -r name mime size fid; do
        printf "  %b%-40s%b %b%-30s%b %s\n" "$C_WHITE" "${name:0:40}" "$C_RESET" "$C_DIM" "${mime:0:30}" "$C_RESET" "$size"
    done
}

# ── Download a file ───────────────────────────────────────────
drive_download() {
    local file_id="$1"
    local output="${2:-}"

    if [ -z "$file_id" ]; then
        ui_err "Usage: drive_download <file_id> [output_path]"
        return 1
    fi

    # Get file metadata for name
    local meta
    meta=$(_gsuite_api GET "${DRIVE_API}/files/${file_id}?fields=name,mimeType")

    local name mime
    name=$(echo "$meta" | jq -r '.name // "download"' 2>/dev/null)
    mime=$(echo "$meta" | jq -r '.mimeType // ""' 2>/dev/null)

    [ -z "$output" ] && output="$name"

    # Google Docs/Sheets/Slides need export, regular files use download
    if [[ "$mime" == application/vnd.google-apps.* ]]; then
        local export_mime
        case "$mime" in
            *document*) export_mime="text/plain" ;;
            *spreadsheet*) export_mime="text/csv" ;;
            *presentation*) export_mime="text/plain" ;;
            *) export_mime="text/plain" ;;
        esac
        local token
        token=$(_gsuite_get_token) || return 1
        curl -s -L -o "$output" \
            -H "Authorization: Bearer $token" \
            "${DRIVE_API}/files/${file_id}/export?mimeType=$(printf '%s' "$export_mime" | jq -sRr @uri)"
    else
        local token
        token=$(_gsuite_get_token) || return 1
        curl -s -L -o "$output" \
            -H "Authorization: Bearer $token" \
            "${DRIVE_API}/files/${file_id}?alt=media"
    fi

    if [ -f "$output" ]; then
        ui_ok "Downloaded: $output ($(du -h "$output" | cut -f1))"
    else
        ui_err "Download failed"
        return 1
    fi
}

# ── Upload a file ─────────────────────────────────────────────
drive_upload() {
    local filepath="$1"
    local folder_id="${2:-}"

    if [ -z "$filepath" ] || [ ! -f "$filepath" ]; then
        ui_err "Usage: drive_upload <filepath> [folder_id]"
        return 1
    fi

    local name
    name=$(basename "$filepath")
    local mime
    mime=$(file -b --mime-type "$filepath" 2>/dev/null || echo "application/octet-stream")

    local token
    token=$(_gsuite_get_token) || return 1

    # Metadata
    local meta="{\"name\": \"$name\""
    [ -n "$folder_id" ] && meta="${meta}, \"parents\": [\"${folder_id}\"]"
    meta="${meta}}"

    # Multipart upload
    local response
    response=$(curl -s -X POST \
        "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart" \
        -H "Authorization: Bearer $token" \
        -F "metadata=$meta;type=application/json" \
        -F "file=@$filepath;type=$mime")

    local file_id
    file_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)

    if [ -n "$file_id" ]; then
        ui_ok "Uploaded: $name (ID: $file_id)"
    else
        ui_err "Upload failed: $(echo "$response" | jq -r '.error.message // "unknown"' 2>/dev/null)"
        return 1
    fi
}

# ── Search Drive ──────────────────────────────────────────────
drive_search() {
    local query="$1"
    if [ -z "$query" ]; then
        ui_err "Usage: drive_search <query>"
        return 1
    fi
    drive_list "fullText contains '${query}'" 20
}

# ═══════════════════════════════════════════════════════════════
# Google Docs
# ═══════════════════════════════════════════════════════════════

# ── Read a Google Doc ─────────────────────────────────────────
docs_read() {
    local doc_id="$1"
    if [ -z "$doc_id" ]; then
        ui_err "Usage: docs_read <doc_id>"
        return 1
    fi

    # Export as plain text
    local token
    token=$(_gsuite_get_token) || return 1
    curl -s -L \
        -H "Authorization: Bearer $token" \
        "${DRIVE_API}/files/${doc_id}/export?mimeType=text/plain"
}

# ── Create a Google Doc ───────────────────────────────────────
docs_create() {
    local title="$1"
    local content="${2:-}"

    if [ -z "$title" ]; then
        ui_err "Usage: docs_create <title> [initial_content]"
        return 1
    fi

    local response
    response=$(_gsuite_api POST "$DOCS_API/documents" \
        -d "{\"title\": \"$title\"}")

    local doc_id
    doc_id=$(echo "$response" | jq -r '.documentId // empty' 2>/dev/null)

    if [ -z "$doc_id" ]; then
        ui_err "Failed to create doc: $(echo "$response" | jq -r '.error.message // "unknown"' 2>/dev/null)"
        return 1
    fi

    # Insert content if provided
    if [ -n "$content" ]; then
        local escaped_content
        escaped_content=$(echo "$content" | jq -sR .)
        _gsuite_api POST "${DOCS_API}/documents/${doc_id}:batchUpdate" \
            -d "{\"requests\": [{\"insertText\": {\"location\": {\"index\": 1}, \"text\": ${escaped_content}}}]}" >/dev/null
    fi

    ui_ok "Created doc: $title (ID: $doc_id)"
    echo "$doc_id"
}

# ═══════════════════════════════════════════════════════════════
# Status
# ═══════════════════════════════════════════════════════════════

gsuite_status() {
    ui_section "Google Workspace"

    local has_creds="No"
    if declare -f secrets_exists &>/dev/null && secrets_exists "google_client_id"; then
        has_creds="Yes"
    fi

    local authenticated="No"
    if gsuite_is_authenticated 2>/dev/null; then
        authenticated="Yes"
    fi

    printf "  %bCredentials:%b  %s\n" "$C_CYAN" "$C_RESET" "$has_creds"
    printf "  %bAuthenticated:%b %s\n" "$C_CYAN" "$C_RESET" "$authenticated"
    printf "  %bScopes:%b       Gmail, Drive, Docs\n" "$C_CYAN" "$C_RESET"
    printf "  %bAuth flow:%b    OAuth2 Device Authorization\n" "$C_CYAN" "$C_RESET"

    if [ "$has_creds" = "No" ]; then
        echo ""
        ui_dim "  Run /gsuite setup <client_id> <client_secret> to configure"
    elif [ "$authenticated" = "No" ]; then
        echo ""
        ui_dim "  Run /gsuite auth to authenticate"
    fi
}
