#!/bin/bash
# ── George: Email Integration ──────────────────────────────────
[ -n "${_LIB_EMAIL_LOADED:-}" ] && return 0; _LIB_EMAIL_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/comms/web.sh"

GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}"
EMAIL_CONFIG="${EMAIL_CONFIG:-$GEORGE_CONFIG_DIR/email.conf}"

declare -g -A EMAIL_PROVIDERS 2>/dev/null || declare -A EMAIL_PROVIDERS
EMAIL_PROVIDERS=(
    [protonmail_smtp]="127.0.0.1:1025" [protonmail_imap]="127.0.0.1:1143" [protonmail_auth]="bridge"
    [protonmail_setup]="Install ProtonMail Bridge: https://proton.me/mail/bridge"
    [tutanota_smtp]="" [tutanota_imap]="" [tutanota_auth]="api"
    [tutanota_setup]="Tuta does not support SMTP/IMAP. Use Tuta desktop app or REST API."
    [gmail_smtp]="smtp.gmail.com:587" [gmail_imap]="imap.gmail.com:993" [gmail_auth]="password"
    [gmail_setup]="Use an App Password: Google Account → Security → 2-Step Verification → App Passwords"
    [zoho_smtp]="smtp.zoho.com:587" [zoho_imap]="imap.zoho.com:993" [zoho_auth]="password"
    [zoho_setup]="Create free account: https://www.zoho.com/mail/ — enable IMAP in settings"
    [disposable_smtp]="" [disposable_imap]="" [disposable_auth]="none"
    [disposable_setup]="Guerrilla Mail — temporary address, no signup required"
)

_email_config_path() { echo "${GEORGE_CONFIG_DIR}/email_${1}.conf"; }

email_list_configured() {
    local providers="" conf p
    for conf in "$GEORGE_CONFIG_DIR"/email_*.conf; do
        [ -f "$conf" ] || continue
        p=$(basename "$conf" | sed 's/^email_//;s/\.conf$//')
        providers="${providers:+$providers }$p"
    done
    if [ -z "$providers" ] && [ -f "$GEORGE_CONFIG_DIR/email.conf" ]; then
        local _old_prov; _old_prov=$(sed -n 's/.*EMAIL_PROVIDER="\([^"]*\)".*/\1/p' "$GEORGE_CONFIG_DIR/email.conf" 2>/dev/null)
        [ -n "$_old_prov" ] && providers="$_old_prov"
    fi
    echo "$providers"
}

email_init() {
    local provider="${1:-}"
    mkdir -p "$GEORGE_CONFIG_DIR"
    EMAIL_PROVIDER=""; EMAIL_ADDRESS=""; EMAIL_AUTH_METHOD=""; EMAIL_PASSWORD=""; GUERRILLA_SID=""
    if [ -n "$provider" ]; then
        EMAIL_CONFIG="$(_email_config_path "$provider")"
        [ -f "$EMAIL_CONFIG" ] && source "$EMAIL_CONFIG" 2>/dev/null
        return
    fi
    local conf
    for conf in "$GEORGE_CONFIG_DIR"/email_*.conf; do
        [ -f "$conf" ] || continue
        EMAIL_CONFIG="$conf"; source "$conf" 2>/dev/null; return
    done
    EMAIL_CONFIG="$GEORGE_CONFIG_DIR/email.conf"
    [ -f "$EMAIL_CONFIG" ] && source "$EMAIL_CONFIG" 2>/dev/null
}

email_setup() {
    local provider="${1:-}" choice address password auth_method="secret"
    email_init
    if [ -z "$provider" ]; then
        ui_section "Email Setup"; echo ""
        printf "  %b1%b ProtonMail  %b2%b Gmail  %b3%b Zoho Mail  %b4%b Tuta  %b5%b Disposable\n" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
        printf "  Choose provider [1-5]: "; read -r choice < /dev/tty
        case "$choice" in
            1) provider="protonmail" ;; 2) provider="gmail" ;; 3) provider="zoho" ;;
            4) provider="tutanota" ;; 5) provider="disposable" ;; *) ui_err "Invalid choice"; return 1 ;;
        esac
    fi
    provider="${provider,,}"
    case "$provider" in
        proton|protonmail|pm) provider="protonmail" ;;
        gmail|google) provider="gmail" ;;
        zoho|zohomail) provider="zoho" ;;
        tuta|tutanota) provider="tutanota" ;;
        disposable|temp|guerrilla|throwaway) provider="disposable" ;;
        *) ui_err "Unknown provider: $provider"; return 1 ;;
    esac
    local _setup_key="${provider}_setup"
    if [ -n "${EMAIL_PROVIDERS[$_setup_key]:-}" ]; then
        ui_info "${EMAIL_PROVIDERS[$_setup_key]}"
        echo ""
    fi
    [ "$provider" = "disposable" ] && { _email_setup_disposable; return $?; }

    printf "  Email address: "; read -r address < /dev/tty
    [ -z "$address" ] && { ui_err "Email address required"; return 1; }

    if [ "$provider" = "protonmail" ]; then
        printf "  Run full Bridge setup now? [Y/n]: "; local do_b; read -r do_b < /dev/tty
        [[ "${do_b,,}" != "n" ]] && { bridge_setup; return $?; }
        auth_method="bridge"
    fi
    [ "$provider" = "gmail" ] && { ui_info "Gmail requires a Google App Password (myaccount.google.com/apppasswords)"; }
    printf "  Password (or app password): "; read -rs password < /dev/tty; echo ""
    [ -z "$password" ] && { ui_err "Password required"; return 1; }

    if declare -f secrets_set &>/dev/null; then
        secrets_set "email_password_${provider}" "$password"; ui_ok "Password stored in secrets vault"
    else
        ui_warn "Secrets vault not available — password stored in config"; auth_method="config"
    fi
    EMAIL_CONFIG="$(_email_config_path "$provider")"
    cat > "$EMAIL_CONFIG" << EOF
# George's email configuration — $provider
EMAIL_PROVIDER="$provider"
EMAIL_ADDRESS="$address"
EMAIL_AUTH_METHOD="$auth_method"
${auth_method:+EMAIL_PASSWORD="$password"}
EOF
    chmod 600 "$EMAIL_CONFIG"; password=""
    ui_ok "Email configured: $address ($provider)"
}

_email_setup_disposable() {
    ui_step "Creating disposable email via Guerrilla Mail..."
    local resp; resp=$(curl -sL "https://api.guerrillamail.com/ajax.php?f=get_email_address&lang=en" 2>/dev/null)
    [ -z "$resp" ] && { ui_err "Could not reach Guerrilla Mail API"; return 1; }
    local address sid_token
    address=$(echo "$resp" | sed -n 's/.*"email_addr"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    sid_token=$(echo "$resp" | sed -n 's/.*"sid_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$address" ] && { ui_err "Failed to get disposable address from Guerrilla Mail"; return 1; }
    cat > "$(_email_config_path "disposable")" << EOF
# George's email configuration — DISPOSABLE
EMAIL_PROVIDER="disposable"
EMAIL_ADDRESS="$address"
EMAIL_AUTH_METHOD="none"
GUERRILLA_SID="$sid_token"
EOF
    chmod 600 "$(_email_config_path "disposable")"
    ui_ok "Disposable email ready: $address"; ui_warn "This address expires after ~60 minutes of inactivity"
    echo "$address"
}

email_get_address() {
    email_init "${1:-}"
    [ -n "$EMAIL_ADDRESS" ] && { echo "$EMAIL_ADDRESS"; return 0; }
    return 1
}

email_get_provider() {
    email_init "${1:-}"
    echo "${EMAIL_PROVIDER:-none}"
}

email_provider_reachable() {
    case "$1" in
        protonmail) declare -f bridge_is_reachable &>/dev/null && bridge_is_reachable ;;
        gmail|zoho) api_network_reachable 3 ;;
        disposable) api_network_reachable 3 && api_endpoint_reachable "https://api.guerrillamail.com/ajax.php?f=get_email_address" 4 ;;
        *) return 1 ;;
    esac
}

email_availability_summary() {
    local provider="${1:-}" enabled="yes" configured="no" reachable="no"
    email_init "$provider"
    if [ -n "$EMAIL_PROVIDER" ]; then
        configured="yes"; provider="$EMAIL_PROVIDER"
        email_provider_reachable "$EMAIL_PROVIDER" && reachable="yes"
    else provider="none"; fi
    echo "EMAIL_ENABLED: $enabled"
    echo "EMAIL_CONFIGURED: $configured"
    echo "EMAIL_REACHABLE: $reachable"
    echo "EMAIL_PROVIDER: $provider"
    echo "EMAIL_NETWORK: $(api_network_state 3)"
}

email_send() {
    local provider="$1" to="$2" subject="$3" body="$4" attachment="${5:-}"
    body=$(ui_expand_escapes "$body")
    subject=$(ui_expand_escapes "$subject")
    [ -z "$provider" ] && { ui_err "Provider required. Usage: /email send <provider> <recipient> s=subject b=body [f=file.txt]"; return 1; }
    if [ -n "$attachment" ]; then
        [ ! -f "$attachment" ] && { ui_err "Attachment not found: $attachment"; return 1; }
        command -v base64 &>/dev/null || { ui_err "base64 command required for attachments (apt install coreutils)"; return 1; }
    fi
    email_init "$provider"
    [ -z "$EMAIL_PROVIDER" ] && { ui_err "Provider '$provider' not configured. Run: /email setup $provider"; return 1; }
    case "$EMAIL_PROVIDER" in
        protonmail) email_provider_reachable "protonmail" || { ui_err "ProtonMail Bridge is not reachable. Start/configure bridge first."; return 1; } ;;
        gmail|zoho) email_provider_reachable "$EMAIL_PROVIDER" || { ui_err "Email provider '$EMAIL_PROVIDER' is unreachable (offline network)"; return 1; } ;;
    esac
    case "$EMAIL_PROVIDER" in
        protonmail) _email_send_smtp "$to" "$subject" "$body" "127.0.0.1" "1025" "$attachment" ;;
        gmail)      _email_send_smtp "$to" "$subject" "$body" "smtp.gmail.com" "587" "$attachment" ;;
        zoho)       _email_send_smtp "$to" "$subject" "$body" "smtp.zoho.com" "587" "$attachment" ;;
        tutanota)   ui_err "Tuta does not support SMTP. Use the Tuta app to send email."; return 1 ;;
        disposable) ui_err "Disposable email is receive-only (no outbound SMTP)"; return 1 ;;
        *)          ui_err "Unknown provider: $EMAIL_PROVIDER"; return 1 ;;
    esac
}

_email_send_smtp() {
    local to="$1" subject="$2" body="$3" host="$4" port="$5" attachment="${6:-}" password=""
    if [ "$EMAIL_AUTH_METHOD" = "secret" ] && declare -f secrets_get &>/dev/null; then
        password=$(secrets_get "email_password_${EMAIL_PROVIDER}" 2>/dev/null || secrets_get "email_password" 2>/dev/null)
    elif [ "$EMAIL_AUTH_METHOD" = "bridge" ] || [ "$EMAIL_AUTH_METHOD" = "config" ]; then
        password="${EMAIL_PASSWORD:-}"
    fi
    if [ -z "$password" ] && [ "$EMAIL_AUTH_METHOD" != "bridge" ]; then
        ui_err "Email password not found. Set it with: /secret set email_password_${EMAIL_PROVIDER} <password>"; return 1
    fi
    local msg_file; msg_file=$(mktemp)
    if [ -n "$attachment" ] && [ -f "$attachment" ]; then
        local boundary="----=_LodgeBoundary_$(date +%s%N)_$$" filename; filename=$(basename "$attachment")
        local mimetype="application/octet-stream"
        case "$(echo "$filename" | tr '[:upper:]' '[:lower:]')" in
            *.txt) mimetype="text/plain" ;; *.md) mimetype="text/markdown" ;; *.html) mimetype="text/html" ;;
            *.csv) mimetype="text/csv" ;; *.json) mimetype="application/json" ;; *.pdf) mimetype="application/pdf" ;;
            *.png) mimetype="image/png" ;; *.jpg|*.jpeg) mimetype="image/jpeg" ;; *.gif) mimetype="image/gif" ;; *.zip) mimetype="application/zip" ;;
        esac
        cat > "$msg_file" << MSGEOF
From: $EMAIL_ADDRESS
To: $to
Subject: $subject
Date: $(date -R)
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="$boundary"

--$boundary
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 7bit

$body

--$boundary
Content-Type: $mimetype; name="$filename"
Content-Disposition: attachment; filename="$filename"
Content-Transfer-Encoding: base64

MSGEOF
        base64 "$attachment" >> "$msg_file"
        printf "\n--%s--\n" "$boundary" >> "$msg_file"
    else
        cat > "$msg_file" << MSGEOF
From: $EMAIL_ADDRESS
To: $to
Subject: $subject
Date: $(date -R)
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

$body
MSGEOF
    fi
    local curl_args=(-sS --url "smtp://${host}:${port}" --ssl-reqd --mail-from "$EMAIL_ADDRESS" --mail-rcpt "$to" --upload-file "$msg_file")
    [ -n "$password" ] && curl_args+=(--user "${EMAIL_ADDRESS}:${password}")
    local result; result=$(curl "${curl_args[@]}" 2>&1); local rc=$?
    rm -f "$msg_file"
    if [ $rc -eq 0 ]; then ui_ok "Email sent to $to"; return 0; fi
    result=$(echo "$result" | sed 's/--user [^ ]*/--user ***:***/' | grep -v "Could not resolve host")
    ui_err "Send failed (exit $rc): ${result:-authentication or connection error}"; return 1
}

email_inbox() {
    local provider="$1" count="${2:-5}"
    [ -z "$provider" ] && { ui_err "Provider required. Usage: /email inbox <provider> [count]"; return 1; }
    email_init "$provider"
    [ -z "$EMAIL_PROVIDER" ] && { ui_err "Provider '$provider' not configured. Run: /email setup $provider"; return 1; }
    case "$EMAIL_PROVIDER" in
        protonmail) email_provider_reachable "protonmail" || { ui_err "ProtonMail Bridge is not reachable. Start/configure bridge first."; return 1; } ;;
        gmail|zoho|disposable) email_provider_reachable "$EMAIL_PROVIDER" || { ui_err "Email inbox unavailable for '$EMAIL_PROVIDER' (offline or provider unreachable)"; return 1; } ;;
    esac
    case "$EMAIL_PROVIDER" in
        protonmail) _email_inbox_imap "127.0.0.1" "1143" "$count" ;;
        gmail)      _email_inbox_imap "imap.gmail.com" "993" "$count" ;;
        zoho)       _email_inbox_imap "imap.zoho.com" "993" "$count" ;;
        tutanota)   ui_err "Tuta does not support IMAP. Use the Tuta app."; return 1 ;;
        disposable) _email_inbox_guerrilla "$count" ;;
        *)          ui_err "Unknown provider: $EMAIL_PROVIDER"; return 1 ;;
    esac
}

_email_inbox_imap() {
    local host="$1" port="$2" count="$3" password=""
    if [ "$EMAIL_AUTH_METHOD" = "secret" ] && declare -f secrets_get &>/dev/null; then
        password=$(secrets_get "email_password_${EMAIL_PROVIDER}" 2>/dev/null || secrets_get "email_password" 2>/dev/null)
    elif [ "$EMAIL_AUTH_METHOD" = "bridge" ] || [ "$EMAIL_AUTH_METHOD" = "config" ]; then
        password="${EMAIL_PASSWORD:-}"
    fi
    [ -z "$password" ] && { ui_err "Email password not found. Set it with: /secret set email_password_${EMAIL_PROVIDER} <password>"; return 1; }
    local result; result=$(curl -sS --url "imaps://${host}:${port}/INBOX" --user "${EMAIL_ADDRESS}:${password}" -X "SEARCH RECENT" 2>&1)
    if [ $? -ne 0 ]; then
        result=$(echo "$result" | sed 's/--user [^ ]*/--user ***:***/' | grep -v "Could not resolve host")
        ui_err "IMAP connection failed: ${result:-authentication or connection error}"; return 1
    fi
    ui_section "Inbox ($EMAIL_PROVIDER)"; echo "$result" | head -n "$count"
}

_email_inbox_guerrilla() {
    local count="${1:-5}" sid="${GUERRILLA_SID:-}"
    [ -z "$sid" ] && { ui_err "No Guerrilla Mail session. Run: /email setup disposable"; return 1; }
    local resp; resp=$(curl -sL "https://api.guerrillamail.com/ajax.php?f=check_email&seq=0&sid_token=${sid}" 2>/dev/null)
    [ -z "$resp" ] && { ui_err "Could not check Guerrilla Mail inbox"; return 1; }
    ui_section "Disposable Inbox ($EMAIL_ADDRESS)"
    local emails; emails=$(echo "$resp" | sed -n 's/.*"mail_subject"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n "$count")
    if [ -z "$emails" ]; then ui_info "No messages"
    else
        local i=1; while IFS= read -r subj; do printf "  %b%d%b  %s\n" "$C_CYAN" "$i" "$C_RESET" "$subj"; (( i++ )); done <<< "$emails"
    fi
}

_email_imap_test() {
    local host="$1" port="$2" password=""
    if [ "$EMAIL_AUTH_METHOD" = "secret" ] && declare -f secrets_get &>/dev/null; then
        password=$(secrets_get "email_password_${EMAIL_PROVIDER}" 2>/dev/null || secrets_get "email_password" 2>/dev/null)
    elif [ "$EMAIL_AUTH_METHOD" = "bridge" ] || [ "$EMAIL_AUTH_METHOD" = "config" ]; then
        password="${EMAIL_PASSWORD:-}"
    fi
    [ -z "$password" ] && { printf "  IMAP:     %b%s%b (%s:%s)\n" "$C_DIM" "no password set" "$C_RESET" "$host" "$port"; return; }
    local result; result=$(curl -sS --connect-timeout 5 --max-time 10 --url "imaps://${host}:${port}" --user "${EMAIL_ADDRESS}:${password}" -X "LIST \"\" \"INBOX\"" 2>&1)
    local rc=$?
    if [ $rc -eq 0 ]; then printf "  IMAP:     %b%s%b (%s:%s)\n" "$C_GREEN" "connected" "$C_RESET" "$host" "$port"
    elif [ $rc -eq 67 ]; then printf "  IMAP:     %b%s%b (%s:%s)\n" "$C_RED" "login denied" "$C_RESET" "$host" "$port"
    else printf "  IMAP:     %b%s%b (%s:%s)\n" "$C_RED" "unreachable" "$C_RESET" "$host" "$port"; fi
}

_email_show_provider_status() {
    printf "  Provider: %b%s%b\n" "$C_CYAN" "$EMAIL_PROVIDER" "$C_RESET"
    printf "  Address:  %b%s%b\n" "$C_WHITE" "${EMAIL_ADDRESS:-none}" "$C_RESET"
    printf "  Auth:     %s\n" "${EMAIL_AUTH_METHOD:-none}"
    case "$EMAIL_PROVIDER" in
        protonmail) curl -s --connect-timeout 2 "http://127.0.0.1:1025" &>/dev/null && printf "  Bridge:   %b%s%b\n" "$C_GREEN" "reachable" "$C_RESET" || printf "  Bridge:   %b%s%b\n" "$C_RED" "not reachable" "$C_RESET" ;;
        gmail) _email_imap_test "imap.gmail.com" "993" ;;
        zoho)  _email_imap_test "imap.zoho.com" "993" ;;
        disposable) [ -n "${GUERRILLA_SID:-}" ] && printf "  Session:  %bactive%b\n" "$C_GREEN" "$C_RESET" || printf "  Session:  %bexpired%b\n" "$C_RED" "$C_RESET" ;;
    esac
}

email_status() {
    local provider="${1:-}"
    ui_section "Email"
    if [ -n "$provider" ]; then
        email_init "$provider"
        [ -z "$EMAIL_PROVIDER" ] && { ui_info "Provider '$provider' not configured. Run: /email setup $provider"; return; }
        _email_show_provider_status; return
    fi
    local found=0 conf
    for conf in "$GEORGE_CONFIG_DIR"/email_*.conf; do
        [ -f "$conf" ] || continue
        source "$conf" 2>/dev/null; [ -n "$EMAIL_PROVIDER" ] || continue
        [ $found -gt 0 ] && echo ""; found=$((found + 1)); _email_show_provider_status
    done
    if [ $found -eq 0 ] && [ -f "$GEORGE_CONFIG_DIR/email.conf" ]; then
        source "$GEORGE_CONFIG_DIR/email.conf" 2>/dev/null
        [ -n "$EMAIL_PROVIDER" ] && { found=1; _email_show_provider_status; }
    fi
    [ $found -eq 0 ] && ui_info "Not configured. Run: /email setup <provider>"
}

BRIDGE_SMTP_HOST="${BRIDGE_SMTP_HOST:-127.0.0.1}"
BRIDGE_SMTP_PORT="${BRIDGE_SMTP_PORT:-1025}"
BRIDGE_IMAP_HOST="${BRIDGE_IMAP_HOST:-127.0.0.1}"
BRIDGE_IMAP_PORT="${BRIDGE_IMAP_PORT:-1143}"
BRIDGE_PASS_DIR="${BRIDGE_PASS_DIR:-$HOME/.password-store}"

_bridge_bin() { command -v protonmail-bridge 2>/dev/null || command -v proton-bridge 2>/dev/null || echo ""; }

bridge_check_deps() {
    local missing=()
    command -v gpg &>/dev/null || missing+=("gnupg")
    command -v pass &>/dev/null || missing+=("pass")
    [ -z "$(_bridge_bin)" ] && missing+=("protonmail-bridge")
    [ ${#missing[@]} -gt 0 ] && { echo "${missing[*]}"; return 1; }
    return 0
}

bridge_install_deps() {
    ui_section "ProtonMail Bridge — Dependency Check"
    local needs=0 pkg bin
    for pkg in gnupg pass; do
        if command -v "$pkg" &>/dev/null; then ui_ok "$pkg — installed"
        else
            ui_step "Installing $pkg..."; (pkg install -y "$pkg" || apt install -y "$pkg") 2>&1 | tail -1
            command -v "$pkg" &>/dev/null && ui_ok "$pkg — installed" || { ui_err "$pkg install failed"; needs=1; }
        fi
    done
    bin=$(_bridge_bin); [ -n "$bin" ] && ui_ok "protonmail-bridge — installed ($bin)" || { needs=1; ui_warn "protonmail-bridge not found"; }
    return $needs
}

bridge_init_pass() {
    [ -d "$BRIDGE_PASS_DIR" ] && [ -n "$(ls -A "$BRIDGE_PASS_DIR" 2>/dev/null)" ] && { ui_ok "pass store already initialized at $BRIDGE_PASS_DIR"; return 0; }
    command -v gpg &>/dev/null || { ui_err "gnupg required. Run: /email bridge install"; return 1; }
    command -v pass &>/dev/null || { ui_err "pass required. Run: /email bridge install"; return 1; }
    ui_section "Initializing Pass Store for Bridge Keychain"
    local key_id; key_id=$(gpg --list-keys --with-colons --keyid-format long 2>/dev/null | grep '^pub:' | head -1 | cut -d: -f5)
    if [ -z "$key_id" ]; then
        ui_step "Generating GPG key for pass store..."
        local bf; bf=$(mktemp)
        printf '%%no-protection\nKey-Type: RSA\nKey-Length: 2048\nSubkey-Type: RSA\nSubkey-Length: 2048\nName-Real: ProtonMail Bridge Keychain\nName-Email: bridge-keychain@localhost\nExpire-Date: 0\n%%commit\n' > "$bf"
        gpg --batch --gen-key "$bf" 2>&1 | grep -v '^\[GNUPG\]'; rm -f "$bf"
        key_id=$(gpg --list-keys --with-colons --keyid-format long "bridge-keychain@localhost" 2>/dev/null | grep '^pub:' | head -1 | cut -d: -f5)
        [ -z "$key_id" ] && { ui_err "Could not find generated GPG key"; return 1; }
        ui_ok "GPG key generated: $key_id"
    fi
    pass init "$key_id" 2>&1 | grep -v '^\[GNUPG\]' || { ui_err "pass init failed"; return 1; }
    ui_ok "Pass store initialized — Bridge keychain ready"; return 0
}

bridge_is_running() { pgrep -f "protonmail-bridge\|proton-bridge" &>/dev/null; }

bridge_is_reachable() {
    if command -v curl &>/dev/null; then curl -s --connect-timeout 2 "smtp://${BRIDGE_SMTP_HOST}:${BRIDGE_SMTP_PORT}" &>/dev/null; return $?
    elif command -v nc &>/dev/null; then nc -z -w2 "$BRIDGE_SMTP_HOST" "$BRIDGE_SMTP_PORT" &>/dev/null; return $?
    fi
    (echo >/dev/tcp/"$BRIDGE_SMTP_HOST"/"$BRIDGE_SMTP_PORT") 2>/dev/null
}

bridge_start() {
    local bin; bin=$(_bridge_bin); [ -z "$bin" ] && { ui_err "protonmail-bridge not installed"; return 1; }
    bridge_is_running && { ui_ok "Bridge is already running"; return 0; }
    [ ! -d "$BRIDGE_PASS_DIR" ] || [ -z "$(ls -A "$BRIDGE_PASS_DIR" 2>/dev/null)" ] && { ui_warn "Pass store not initialized — run: /email bridge init-pass"; return 1; }
    ui_step "Starting ProtonMail Bridge in background..."; nohup "$bin" --noninteractive > /dev/null 2>&1 &
    local bpid=$!; sleep 2
    if kill -0 "$bpid" 2>/dev/null; then
        ui_ok "Bridge started (PID: $bpid)"; local tries=0
        while [ $tries -lt 10 ]; do
            bridge_is_reachable && { ui_ok "SMTP port $BRIDGE_SMTP_PORT reachable"; return 0; }
            sleep 1; tries=$((tries + 1))
        done
        ui_warn "Bridge is running but ports not yet reachable"; return 0
    fi
    ui_err "Bridge process exited unexpectedly"; return 1
}

bridge_stop() {
    ! bridge_is_running && { ui_info "Bridge is not running"; return 0; }
    ui_step "Stopping ProtonMail Bridge..."
    pkill -f "protonmail-bridge\|proton-bridge" 2>/dev/null; sleep 1
    bridge_is_running && pkill -9 -f "protonmail-bridge\|proton-bridge" 2>/dev/null
    ui_ok "Bridge stopped"
}

bridge_login() {
    local bin; bin=$(_bridge_bin); [ -z "$bin" ] && { ui_err "protonmail-bridge not installed"; return 1; }
    [ ! -d "$BRIDGE_PASS_DIR" ] || [ -z "$(ls -A "$BRIDGE_PASS_DIR" 2>/dev/null)" ] && { ui_warn "Pass store not initialized — run: /email bridge init-pass"; return 1; }
    ui_section "ProtonMail Bridge — Interactive Login"; "$bin" --cli
}

bridge_status() {
    ui_section "ProtonMail Bridge Status"
    local bin; bin=$(_bridge_bin)
    [ -n "$bin" ] && printf "  Binary:     %b%s%b\n" "$C_GREEN" "installed" "$C_RESET" || printf "  Binary:     %b%s%b\n" "$C_RED" "not installed" "$C_RESET"
    command -v gpg &>/dev/null && printf "  gnupg:      %b%s%b\n" "$C_GREEN" "installed" "$C_RESET" || printf "  gnupg:      %b%s%b\n" "$C_RED" "missing" "$C_RESET"
    command -v pass &>/dev/null && printf "  pass:       %b%s%b\n" "$C_GREEN" "installed" "$C_RESET" || printf "  pass:       %b%s%b\n" "$C_RED" "missing" "$C_RESET"
    [ -d "$BRIDGE_PASS_DIR" ] && [ -n "$(ls -A "$BRIDGE_PASS_DIR" 2>/dev/null)" ] && printf "  Pass store: %b%s%b\n" "$C_GREEN" "initialized" "$C_RESET" || printf "  Pass store: %b%s%b\n" "$C_RED" "not initialized" "$C_RESET"
    bridge_is_running && printf "  Process:    %b%s%b\n" "$C_GREEN" "running" "$C_RESET" || printf "  Process:    %b%s%b\n" "$C_DIM" "not running" "$C_RESET"
    if bridge_is_reachable; then
        printf "  SMTP:       %b%s%b (%s:%s)\n" "$C_GREEN" "reachable" "$C_RESET" "$BRIDGE_SMTP_HOST" "$BRIDGE_SMTP_PORT"
        printf "  IMAP:       %b%s%b (%s:%s)\n" "$C_GREEN" "reachable" "$C_RESET" "$BRIDGE_IMAP_HOST" "$BRIDGE_IMAP_PORT"
    else
        printf "  SMTP:       %b%s%b (%s:%s)\n" "$C_RED" "unreachable" "$C_RESET" "$BRIDGE_SMTP_HOST" "$BRIDGE_SMTP_PORT"
        printf "  IMAP:       %b%s%b (%s:%s)\n" "$C_RED" "unreachable" "$C_RESET" "$BRIDGE_IMAP_HOST" "$BRIDGE_IMAP_PORT"
    fi
}

bridge_configure() {
    ui_section "Configure George's Email for ProtonMail Bridge"
    email_init "protonmail" 2>/dev/null
    local address="${EMAIL_ADDRESS:-}"
    if [ -z "$address" ] || [ "${EMAIL_PROVIDER:-}" != "protonmail" ]; then
        printf "  Proton Mail address: "; read -r address < /dev/tty
        [ -z "$address" ] && { ui_err "Email address required"; return 1; }
    fi
    printf "  Bridge password: "; local bp; read -rs bp < /dev/tty; echo ""
    [ -z "$bp" ] && { ui_err "Bridge password required"; return 1; }
    local _bconf="$(_email_config_path "protonmail")"
    if declare -f secrets_set &>/dev/null; then
        secrets_set "email_password_protonmail" "$bp"
        cat > "$_bconf" << EOF
EMAIL_PROVIDER="protonmail"
EMAIL_ADDRESS="$address"
EMAIL_AUTH_METHOD="bridge"
EOF
    else
        cat > "$_bconf" << EOF
EMAIL_PROVIDER="protonmail"
EMAIL_ADDRESS="$address"
EMAIL_AUTH_METHOD="bridge"
EMAIL_PASSWORD="$bp"
EOF
    fi
    chmod 600 "$_bconf"; ui_ok "Email configured: $address (ProtonMail Bridge)"
}

bridge_test() {
    ! bridge_is_running && { ui_err "Bridge is not running. Start it: /email bridge start"; return 1; }
    ! bridge_is_reachable && { ui_err "Bridge SMTP port not reachable at ${BRIDGE_SMTP_HOST}:${BRIDGE_SMTP_PORT}"; return 1; }
    email_init "protonmail" 2>/dev/null
    local pass=""
    declare -f secrets_get &>/dev/null && pass=$(secrets_get "email_password_protonmail" 2>/dev/null || secrets_get "email_password" 2>/dev/null)
    [ -z "$pass" ] && pass="${EMAIL_PASSWORD:-}"
    [ -z "$pass" ] || [ -z "${EMAIL_ADDRESS:-}" ] && { ui_err "Email not configured for bridge. Run: /email bridge configure"; return 1; }
    ui_step "Testing SMTP connection to Bridge..."
    local res; res=$(curl -sS --connect-timeout 5 --url "smtp://${BRIDGE_SMTP_HOST}:${BRIDGE_SMTP_PORT}" --ssl-reqd --user "${EMAIL_ADDRESS}:${pass}" 2>&1)
    local rc=$?
    if [ $rc -eq 0 ] || [ $rc -eq 56 ]; then ui_ok "SMTP authentication successful!"; return 0
    elif [ $rc -eq 67 ]; then ui_err "SMTP authentication failed — check bridge password"; return 1
    else ui_err "SMTP connection error (curl exit $rc)"; return 1; fi
}

bridge_setup() {
    ui_section "ProtonMail Bridge — Full Setup"
    bridge_check_deps || bridge_install_deps || return 1
    bridge_init_pass || return 1
    bridge_login; bridge_configure || return 1
    bridge_start || return 1
    sleep 2; bridge_test
}

GEORGE_SSH_DIR="${GEORGE_SSH_DIR:-$GEORGE_CONFIG_DIR/.ssh}"
GEORGE_SSH_KEY="${GEORGE_SSH_KEY:-$GEORGE_SSH_DIR/id_ed25519}"

ssh_init() {
    [ -d "$GEORGE_SSH_DIR" ] && return 0
    mkdir -p "$GEORGE_SSH_DIR" && chmod 700 "$GEORGE_SSH_DIR" && ui_dim "Initialized SSH directory at $GEORGE_SSH_DIR"
}

ssh_has_key() { [ -f "$GEORGE_SSH_KEY" ]; }

ssh_generate_key() {
    ssh_init || return 1
    ssh_has_key && { ui_warn "George already has an SSH key"; return 0; }
    local key_comment="george@blue-lodge"
    email_init >/dev/null 2>&1
    [ -n "${EMAIL_ADDRESS:-}" ] && key_comment="$EMAIL_ADDRESS"
    ui_step "Generating Ed25519 SSH key..."
    ssh-keygen -t ed25519 -C "$key_comment" -f "$GEORGE_SSH_KEY" -N "" -q 2>&1 || { ui_err "SSH key generation failed"; return 1; }
    chmod 600 "$GEORGE_SSH_KEY"; chmod 644 "$GEORGE_SSH_KEY.pub"
    ui_ok "SSH key generated"; cat "$GEORGE_SSH_KEY.pub"
}

ssh_get_pubkey() { ssh_has_key || return 1; cat "$GEORGE_SSH_KEY.pub"; }

ssh_configure_git() {
    ssh_has_key || { ui_err "No SSH key found. Run: /email ssh-keygen"; return 1; }
    declare -f git_write_ssh_config &>/dev/null && { git_write_ssh_config; return $?; }
    local ssh_config="$GEORGE_SSH_DIR/config" host="${GEORGE_GIT_HOST:-github.com-george}"
    mkdir -p "$GEORGE_SSH_DIR"
    [ -f "$ssh_config" ] && grep -q "^Host github\.com$" "$ssh_config" 2>/dev/null && sed -i '/^Host github\.com$/,/^$/d' "$ssh_config"
    [ -f "$ssh_config" ] && grep -q "^Host ${host}$" "$ssh_config" 2>/dev/null && return 0
    cat >> "$ssh_config" << EOF

Host $host
    HostName github.com
    User git
    IdentityFile $GEORGE_SSH_KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
    chmod 600 "$ssh_config"
}

git_configure_identity() {
    local scope="${1:---global}"
    email_init >/dev/null 2>&1
    git config $scope user.name "George (Blue Lodge)" 2>/dev/null
    git config $scope user.email "${EMAIL_ADDRESS:-george@blue-lodge.local}" 2>/dev/null
}

ssh_test_github() {
    ssh_has_key || { ui_err "No SSH key. Run: /email ssh-keygen"; return 1; }
    ssh_configure_git 2>/dev/null
    local host="${GEORGE_GIT_HOST:-github.com-george}" ssh_config="$GEORGE_SSH_DIR/config"
    ui_step "Testing SSH connection to GitHub via Host alias ($host)..."
    local res; res=$(ssh -F "$ssh_config" -o ConnectTimeout=10 -T "git@${host}" 2>&1)
    [[ "$res" == *"successfully authenticated"* ]] && { ui_ok "GitHub SSH authenticated!"; return 0; }
    ui_err "GitHub SSH authentication failed"; return 1
}

github_setup() {
    ui_section "GitHub Setup for George"
    email_init >/dev/null 2>&1
    [ -z "${EMAIL_ADDRESS:-}" ] && { ui_err "George needs an email address first"; return 1; }
    ssh_has_key || ssh_generate_key || return 1
    git_configure_identity; ssh_configure_git
    ssh_test_github && { ui_ok "George is ready to push to GitHub!"; return 0; }
    return 1
}

github_is_ready() {
    email_init >/dev/null 2>&1
    [ -n "${EMAIL_ADDRESS:-}" ] && ssh_has_key
}

_is_github_remote() {
    local u="${1:-}"
    [[ "$u" == *"github.com"* ]] || [[ "$u" == *"${GEORGE_GIT_HOST:-github.com-george}"* ]]
}

github_push_guard() {
    local remote_url="${1:-}"
    [ -z "$remote_url" ] || [[ "$remote_url" != *"github.com"* ]] && return 0
    if ! github_is_ready; then
        echo ""; ui_err "Cannot push to GitHub — George's identity is not configured"
        email_init >/dev/null 2>&1
        [ -z "${EMAIL_ADDRESS:-}" ] && ui_info "  Missing: email address  →  /email setup"
        ! ssh_has_key && ui_info "  Missing: SSH key        →  /email ssh-keygen"
        echo ""; ui_info "Run: /email github-setup  (auto-configures everything)"
        return 1
    fi
    ssh_configure_git 2>/dev/null
    return 0
}

ssh_status() {
    ui_section "SSH"
    ssh_has_key && printf "  Key:      %b%s%b\n" "$C_GREEN" "configured" "$C_RESET" || printf "  Key:      %b%s%b\n" "$C_RED" "not generated" "$C_RESET"
}

email_sweep() {
    ui_step "Sweeping configured email inboxes..."
    local config_dir="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}" checked=0 conf prov
    for conf in "$config_dir"/email_*.conf "$config_dir/email.conf"; do
        [ -f "$conf" ] || continue
        prov=$(sed -n 's/.*EMAIL_PROVIDER="\([^"]*\)".*/\1/p' "$conf" 2>/dev/null)
        [ -z "$prov" ] && continue
        if email_provider_reachable "$prov" 2>/dev/null; then
            checked=$((checked + 1)); ui_info "Checking inbox for provider '$prov'..."
            email_inbox "$prov" 5 2>/dev/null || true
        fi
    done
    [ "$checked" -eq 0 ] && ui_dim "  No active email providers configured to sweep." || ui_ok "Email sweep completed ($checked providers checked)."
}
