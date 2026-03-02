#!/bin/bash
# ── George: Email Integration ──────────────────────────────────
# Manage email accounts across free providers so George can have
# his own identity (needed for GitHub, package registries, etc.).
#
# Supported providers:
#   protonmail  — ProtonMail (ProtonMail Bridge for SMTP/IMAP)
#   gmail       — Gmail (App Password for SMTP/IMAP)
#   tutanota    — Tuta (formerly Tutanota) — desktop client API
#   zoho        — Zoho Mail (free tier, standard IMAP/SMTP)
#   disposable  — Guerrilla Mail (temp/one-time addresses via API)
#
# Auth: credentials stored in the secrets vault (/secret set)
# or provided interactively by the operator.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/web.sh"

# ── Config ─────────────────────────────────────────────────────
GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}"
# Per-provider config: email_<provider>.conf (replaces old single email.conf)
# EMAIL_CONFIG is set dynamically by email_init based on provider.
EMAIL_CONFIG="${EMAIL_CONFIG:-$GEORGE_CONFIG_DIR/email.conf}"

# ── Provider definitions ───────────────────────────────────────
# Each provider has:  SMTP host, SMTP port, IMAP host, IMAP port, auth method
declare -A EMAIL_PROVIDERS
EMAIL_PROVIDERS=(
    [protonmail_smtp]="127.0.0.1:1025"        # ProtonMail Bridge local
    [protonmail_imap]="127.0.0.1:1143"
    [protonmail_auth]="bridge"                 # requires ProtonMail Bridge running
    [protonmail_setup]="Install ProtonMail Bridge: https://proton.me/mail/bridge"

    [tutanota_smtp]=""                         # Tuta has no standard SMTP
    [tutanota_imap]=""                         # Tuta has no standard IMAP
    [tutanota_auth]="api"                      # uses Tuta desktop client / REST
    [tutanota_setup]="Tuta does not support SMTP/IMAP. Use Tuta desktop app or REST API."

    [gmail_smtp]="smtp.gmail.com:587"
    [gmail_imap]="imap.gmail.com:993"
    [gmail_auth]="password"                      # Google App Password required
    [gmail_setup]="Use an App Password: Google Account → Security → 2-Step Verification → App Passwords"

    [zoho_smtp]="smtp.zoho.com:587"
    [zoho_imap]="imap.zoho.com:993"
    [zoho_auth]="password"                     # standard user/pass or app password
    [zoho_setup]="Create free account: https://www.zoho.com/mail/ — enable IMAP in settings"

    [disposable_smtp]=""
    [disposable_imap]=""
    [disposable_auth]="none"                   # no auth needed
    [disposable_setup]="Guerrilla Mail — temporary address, no signup required"
)

# ── Per-provider config path helper ────────────────────────────
_email_config_path() {
    local provider="$1"
    echo "${GEORGE_CONFIG_DIR}/email_${provider}.conf"
}

# ── List all configured email providers ────────────────────────
email_list_configured() {
    local providers="" conf
    for conf in "$GEORGE_CONFIG_DIR"/email_*.conf; do
        [ -f "$conf" ] || continue
        local p
        p=$(basename "$conf" | sed 's/^email_//;s/\.conf$//')
        providers="${providers:+$providers }$p"
    done
    # Backward compat: check old email.conf if no per-provider configs
    if [ -z "$providers" ] && [ -f "$GEORGE_CONFIG_DIR/email.conf" ]; then
        local _old_prov=""
        _old_prov=$(grep -oP 'EMAIL_PROVIDER="\K[^"]+' "$GEORGE_CONFIG_DIR/email.conf" 2>/dev/null)
        [ -n "$_old_prov" ] && providers="$_old_prov"
    fi
    echo "$providers"
}

# ── Initialize email config ───────────────────────────────────
# Usage: email_init [provider]
#   provider given  → load that provider's config
#   provider empty  → auto-detect first configured provider
email_init() {
    local provider="${1:-}"
    mkdir -p "$GEORGE_CONFIG_DIR"

    # Reset globals
    EMAIL_PROVIDER=""
    EMAIL_ADDRESS=""
    EMAIL_AUTH_METHOD=""
    EMAIL_PASSWORD=""
    GUERRILLA_SID=""

    if [ -n "$provider" ]; then
        # Load specific provider
        EMAIL_CONFIG="$(_email_config_path "$provider")"
        if [ -f "$EMAIL_CONFIG" ]; then
            source "$EMAIL_CONFIG" 2>/dev/null
        fi
        return
    fi

    # Auto-detect: scan for any email_*.conf files
    local conf
    for conf in "$GEORGE_CONFIG_DIR"/email_*.conf; do
        [ -f "$conf" ] || continue
        EMAIL_CONFIG="$conf"
        source "$conf" 2>/dev/null
        return
    done

    # Backward compat: try old email.conf
    EMAIL_CONFIG="$GEORGE_CONFIG_DIR/email.conf"
    if [ -f "$EMAIL_CONFIG" ]; then
        source "$EMAIL_CONFIG" 2>/dev/null
    fi
}

# ── Setup an email account (interactive) ───────────────────────
# Guides the operator through configuring George's email.
email_setup() {
    local provider="${1:-}"

    email_init

    if [ -z "$provider" ]; then
        ui_section "Email Setup"
        echo ""
        printf "  %b1%b  ProtonMail  — encrypted, private, requires Bridge app\n" "$C_CYAN" "$C_RESET"
        printf "  %b2%b  Gmail       — Google App Password, standard IMAP/SMTP\n" "$C_CYAN" "$C_RESET"
        printf "  %b3%b  Zoho Mail   — free tier, standard IMAP/SMTP\n" "$C_CYAN" "$C_RESET"
        printf "  %b4%b  Tuta        — encrypted, no SMTP/IMAP (limited)\n" "$C_CYAN" "$C_RESET"
        printf "  %b5%b  Disposable  — temporary address via Guerrilla Mail\n" "$C_CYAN" "$C_RESET"
        echo ""
        printf "  Choose provider [1-5]: "
        local choice
        read -r choice < /dev/tty
        case "$choice" in
            1) provider="protonmail" ;;
            2) provider="gmail"      ;;
            3) provider="zoho"       ;;
            4) provider="tutanota"   ;;
            5) provider="disposable" ;;
            *) ui_err "Invalid choice"; return 1 ;;
        esac
    fi

    # Normalize provider name
    provider="${provider,,}"
    case "$provider" in
        proton|protonmail|pm) provider="protonmail" ;;
        gmail|google)         provider="gmail"      ;;
        zoho|zohomail)        provider="zoho"       ;;
        tuta|tutanota)        provider="tutanota"   ;;
        disposable|temp|guerrilla|throwaway) provider="disposable" ;;
        *) ui_err "Unknown provider: $provider"; return 1 ;;
    esac

    local setup_key="${provider}_setup"
    ui_info "${EMAIL_PROVIDERS[$setup_key]:-}"
    echo ""

    if [ "$provider" = "disposable" ]; then
        _email_setup_disposable
        return $?
    fi

    # Standard provider setup — needs email address + credentials
    printf "  Email address: "
    local address
    read -r address < /dev/tty
    if [ -z "$address" ]; then
        ui_err "Email address required"
        return 1
    fi

    # Store credentials via secrets vault
    local auth_method="secret"
    if [ "$provider" = "protonmail" ]; then
        ui_info "ProtonMail uses Bridge for local IMAP/SMTP (ports 1025/1143)."
        printf "  Run full Bridge setup now? [Y/n]: "
        local do_bridge
        read -r do_bridge < /dev/tty
        if [[ "${do_bridge,,}" != "n" ]]; then
            bridge_setup
            return $?
        fi
        # Manual path — operator already has bridge running
        ui_info "Skipping bridge setup. Collecting credentials manually..."
        auth_method="bridge"
    fi

    if [ "$provider" = "gmail" ]; then
        ui_info "Gmail requires a Google App Password (not your regular password)."
        ui_info "Steps to create one:"
        ui_dim "  1. Go to https://myaccount.google.com/security"
        ui_dim "  2. Enable 2-Step Verification (if not already enabled)"
        ui_dim "  3. Go to https://myaccount.google.com/apppasswords"
        ui_dim "  4. Generate an App Password for 'Mail'"
        ui_dim "  5. Paste the 16-character password below (spaces are OK)"
        echo ""
    fi

    printf "  Password (or app password): "
    local password
    read -rs password < /dev/tty
    echo ""
    if [ -z "$password" ]; then
        ui_err "Password required"
        return 1
    fi

    # Store password in secrets vault (provider-specific key)
    if declare -f secrets_set &>/dev/null; then
        secrets_set "email_password_${provider}" "$password"
        ui_ok "Password stored in secrets vault"
    else
        ui_warn "Secrets vault not available — password will be in config (less secure)"
        # Fall back to config file
        auth_method="config"
    fi

    # Write per-provider config
    EMAIL_CONFIG="$(_email_config_path "$provider")"
    cat > "$EMAIL_CONFIG" << EOF
# George's email configuration — $provider
EMAIL_PROVIDER="$provider"
EMAIL_ADDRESS="$address"
EMAIL_AUTH_METHOD="$auth_method"
${auth_method:+EMAIL_PASSWORD="$password"}
EOF
    chmod 600 "$EMAIL_CONFIG"

    # Clear password from memory
    password=""

    ui_ok "Email configured: $address ($provider)"
    return 0
}

# ── Setup disposable email (Guerrilla Mail API) ───────────────
_email_setup_disposable() {
    ui_step "Creating disposable email via Guerrilla Mail..."

    local resp
    resp=$(curl -sL "https://api.guerrillamail.com/ajax.php?f=get_email_address&lang=en" 2>/dev/null)

    if [ -z "$resp" ]; then
        ui_err "Could not reach Guerrilla Mail API"
        return 1
    fi

    local address sid_token
    address=$(echo "$resp" | grep -oP '"email_addr"\s*:\s*"\K[^"]+' || echo "")
    sid_token=$(echo "$resp" | grep -oP '"sid_token"\s*:\s*"\K[^"]+' || echo "")

    if [ -z "$address" ]; then
        ui_err "Failed to get disposable address from Guerrilla Mail"
        return 1
    fi

    cat > "$(_email_config_path "disposable")" << EOF
# George's email configuration — DISPOSABLE
EMAIL_PROVIDER="disposable"
EMAIL_ADDRESS="$address"
EMAIL_AUTH_METHOD="none"
GUERRILLA_SID="$sid_token"
EOF
    chmod 600 "$(_email_config_path "disposable")"

    ui_ok "Disposable email ready: $address"
    ui_warn "This address expires after ~60 minutes of inactivity"
    echo "$address"
}

# ── Get email address for a provider ────────────────────────────
# Usage: email_get_address [provider]
email_get_address() {
    email_init "${1:-}"
    if [ -z "$EMAIL_ADDRESS" ]; then
        return 1
    fi
    echo "$EMAIL_ADDRESS"
}

# ── Get current provider ──────────────────────────────────────
# Usage: email_get_provider [provider] — returns configured name or 'none'
email_get_provider() {
    email_init "${1:-}"
    echo "${EMAIL_PROVIDER:-none}"
}

# ── Send an email ─────────────────────────────────────────────
# Usage: email_send <provider> <to> <subject> <body>
email_send() {
    local provider="$1"
    local to="$2"
    local subject="$3"
    local body="$4"

    if [ -z "$provider" ]; then
        ui_err "Provider required. Usage: /email send <provider> <recipient> s=subject b=body"
        return 1
    fi

    email_init "$provider"
    if [ -z "$EMAIL_PROVIDER" ]; then
        ui_err "Provider '$provider' not configured. Run: /email setup $provider"
        return 1
    fi

    case "$EMAIL_PROVIDER" in
        protonmail) _email_send_smtp "$to" "$subject" "$body" "127.0.0.1" "1025" ;;
        gmail)      _email_send_smtp "$to" "$subject" "$body" "smtp.gmail.com" "587" ;;
        zoho)       _email_send_smtp "$to" "$subject" "$body" "smtp.zoho.com" "587" ;;
        tutanota)
            ui_err "Tuta does not support SMTP. Use the Tuta app to send email."
            return 1 ;;
        disposable)
            ui_err "Disposable email is receive-only (no outbound SMTP)"
            return 1 ;;
        *) ui_err "Unknown provider: $EMAIL_PROVIDER"; return 1 ;;
    esac
}

# ── Send via SMTP (curl) ──────────────────────────────────────
_email_send_smtp() {
    local to="$1" subject="$2" body="$3" host="$4" port="$5"

    local password=""
    if [ "$EMAIL_AUTH_METHOD" = "secret" ] && declare -f secrets_get &>/dev/null; then
        # Try provider-specific key first, fall back to generic
        password=$(secrets_get "email_password_${EMAIL_PROVIDER}" 2>/dev/null)
        [ -z "$password" ] && password=$(secrets_get "email_password" 2>/dev/null)
    elif [ "$EMAIL_AUTH_METHOD" = "bridge" ] || [ "$EMAIL_AUTH_METHOD" = "config" ]; then
        password="${EMAIL_PASSWORD:-}"
    fi

    if [ -z "$password" ] && [ "$EMAIL_AUTH_METHOD" != "bridge" ]; then
        ui_err "Email password not found. Set it with:"
        ui_dim "  /secret set email_password_${EMAIL_PROVIDER} <your-app-password>"
        ui_dim "  Spaces are OK — the full value after the name is captured."
        ui_dim "  Example: /secret set email_password_gmail abcd efgh ijkl mnop"
        return 1
    fi

    # Build RFC 2822 message
    local msg_file
    msg_file=$(mktemp)
    cat > "$msg_file" << MSGEOF
From: $EMAIL_ADDRESS
To: $to
Subject: $subject
Date: $(date -R)
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

$body
MSGEOF

    # Build curl args as an array to prevent word splitting on password
    local curl_args=(
        -sS
        --url "smtp://${host}:${port}"
        --ssl-reqd
        --mail-from "$EMAIL_ADDRESS"
        --mail-rcpt "$to"
        --upload-file "$msg_file"
    )
    if [ -n "$password" ]; then
        curl_args+=(--user "${EMAIL_ADDRESS}:${password}")
    fi

    local result
    result=$(curl "${curl_args[@]}" 2>&1)
    local rc=$?

    rm -f "$msg_file"

    if [ $rc -eq 0 ]; then
        ui_ok "Email sent to $to"
        return 0
    else
        # SECURITY: sanitize error output — never leak credentials
        result=$(echo "$result" | sed 's/--user [^ ]*/--user ***:***/')
        # Strip any hostname-like tokens that might be password fragments
        result=$(echo "$result" | grep -v "Could not resolve host")
        ui_err "Send failed (exit $rc): ${result:-authentication or connection error}"
        return 1
    fi
}

# ── Check inbox (IMAP via curl) ────────────────────────────────
# Usage: email_inbox <provider> [count]
email_inbox() {
    local provider="$1"
    local count="${2:-5}"

    if [ -z "$provider" ]; then
        ui_err "Provider required. Usage: /email inbox <provider> [count]"
        return 1
    fi

    email_init "$provider"
    if [ -z "$EMAIL_PROVIDER" ]; then
        ui_err "Provider '$provider' not configured. Run: /email setup $provider"
        return 1
    fi

    case "$EMAIL_PROVIDER" in
        protonmail) _email_inbox_imap "127.0.0.1" "1143" "$count" ;;
        gmail)      _email_inbox_imap "imap.gmail.com" "993" "$count" ;;
        zoho)       _email_inbox_imap "imap.zoho.com" "993" "$count" ;;
        tutanota)
            ui_err "Tuta does not support IMAP. Use the Tuta app."
            return 1 ;;
        disposable) _email_inbox_guerrilla "$count" ;;
        *) ui_err "Unknown provider: $EMAIL_PROVIDER"; return 1 ;;
    esac
}

# ── IMAP inbox via curl ───────────────────────────────────────
_email_inbox_imap() {
    local host="$1" port="$2" count="$3"

    local password=""
    if [ "$EMAIL_AUTH_METHOD" = "secret" ] && declare -f secrets_get &>/dev/null; then
        # Try provider-specific key first, fall back to generic
        password=$(secrets_get "email_password_${EMAIL_PROVIDER}" 2>/dev/null)
        [ -z "$password" ] && password=$(secrets_get "email_password" 2>/dev/null)
    elif [ "$EMAIL_AUTH_METHOD" = "bridge" ] || [ "$EMAIL_AUTH_METHOD" = "config" ]; then
        password="${EMAIL_PASSWORD:-}"
    fi

    if [ -z "$password" ]; then
        ui_err "Email password not found. Set it with:"
        ui_dim "  /secret set email_password_${EMAIL_PROVIDER} <your-app-password>"
        return 1
    fi

    # Fetch message list via IMAP SEARCH
    local result
    result=$(curl -sS --url "imaps://${host}:${port}/INBOX" \
        --user "${EMAIL_ADDRESS}:${password}" \
        -X "SEARCH RECENT" 2>&1)

    if [ $? -ne 0 ]; then
        # SECURITY: sanitize error output — never leak credentials
        result=$(echo "$result" | sed 's/--user [^ ]*/--user ***:***/')
        result=$(echo "$result" | grep -v "Could not resolve host")
        ui_err "IMAP connection failed: ${result:-authentication or connection error}"
        return 1
    fi

    ui_section "Inbox ($EMAIL_PROVIDER)"
    echo "$result" | head -n "$count"
}

# ── Guerrilla Mail inbox ──────────────────────────────────────
_email_inbox_guerrilla() {
    local count="${1:-5}"

    local sid="${GUERRILLA_SID:-}"
    if [ -z "$sid" ]; then
        ui_err "No Guerrilla Mail session. Run: /email setup disposable"
        return 1
    fi

    local resp
    resp=$(curl -sL "https://api.guerrillamail.com/ajax.php?f=check_email&seq=0&sid_token=${sid}" 2>/dev/null)

    if [ -z "$resp" ]; then
        ui_err "Could not check Guerrilla Mail inbox"
        return 1
    fi

    ui_section "Disposable Inbox ($EMAIL_ADDRESS)"

    # Parse email list from JSON
    local emails
    emails=$(echo "$resp" | grep -oP '"mail_subject"\s*:\s*"\K[^"]+' | head -n "$count")
    if [ -z "$emails" ]; then
        ui_info "No messages"
    else
        local i=1
        while IFS= read -r subj; do
            printf "  %b%d%b  %s\n" "$C_CYAN" "$i" "$C_RESET" "$subj"
            (( i++ ))
        done <<< "$emails"
    fi
}

# ── IMAP connection test (authenticated) ──────────────────────
# Attempts a real IMAP login to verify credentials work.
_email_imap_test() {
    local host="$1" port="$2"

    local password=""
    if [ "$EMAIL_AUTH_METHOD" = "secret" ] && declare -f secrets_get &>/dev/null; then
        # Try provider-specific key first, fall back to generic
        password=$(secrets_get "email_password_${EMAIL_PROVIDER}" 2>/dev/null)
        [ -z "$password" ] && password=$(secrets_get "email_password" 2>/dev/null)
    elif [ "$EMAIL_AUTH_METHOD" = "bridge" ] || [ "$EMAIL_AUTH_METHOD" = "config" ]; then
        password="${EMAIL_PASSWORD:-}"
    fi

    if [ -z "$password" ]; then
        printf "  IMAP:     %b%s%b (%s:%s)\n" "$C_DIM" "no password set" "$C_RESET" "$host" "$port"
        return
    fi

    # Try authenticated IMAP LIST — this verifies login without fetching mail
    local result
    result=$(curl -sS --connect-timeout 5 --max-time 10 \
        --url "imaps://${host}:${port}" \
        --user "${EMAIL_ADDRESS}:${password}" \
        -X "LIST \"\" \"INBOX\"" 2>&1)
    local rc=$?

    if [ $rc -eq 0 ]; then
        printf "  IMAP:     %b%s%b (%s:%s)\n" "$C_GREEN" "connected" "$C_RESET" "$host" "$port"
    elif [ $rc -eq 67 ]; then
        printf "  IMAP:     %b%s%b (%s:%s)\n" "$C_RED" "login denied" "$C_RESET" "$host" "$port"
    else
        printf "  IMAP:     %b%s%b (%s:%s)\n" "$C_RED" "unreachable" "$C_RESET" "$host" "$port"
    fi
}

# ── Single provider status display (internal) ─────────────────
_email_show_provider_status() {
    printf "  Provider: %b%s%b\n" "$C_CYAN" "$EMAIL_PROVIDER" "$C_RESET"
    printf "  Address:  %b%s%b\n" "$C_WHITE" "${EMAIL_ADDRESS:-none}" "$C_RESET"
    printf "  Auth:     %s\n" "${EMAIL_AUTH_METHOD:-none}"

    # Connection test
    case "$EMAIL_PROVIDER" in
        protonmail)
            if curl -s --connect-timeout 2 "http://127.0.0.1:1025" &>/dev/null; then
                printf "  Bridge:   %b%s%b\n" "$C_GREEN" "reachable" "$C_RESET"
            else
                printf "  Bridge:   %b%s%b\n" "$C_RED" "not reachable" "$C_RESET"
            fi ;;
        gmail)
            _email_imap_test "imap.gmail.com" "993" ;;
        zoho)
            _email_imap_test "imap.zoho.com" "993" ;;
        disposable)
            if [ -n "${GUERRILLA_SID:-}" ]; then
                printf "  Session:  %bactive%b\n" "$C_GREEN" "$C_RESET"
            else
                printf "  Session:  %bexpired%b\n" "$C_RED" "$C_RESET"
            fi ;;
    esac
}

# ── Email status ──────────────────────────────────────────────
# Usage: email_status [provider]
#   provider given  → show that provider's status
#   provider empty  → show all configured providers
email_status() {
    local provider="${1:-}"

    ui_section "Email"

    if [ -n "$provider" ]; then
        # Show specific provider
        email_init "$provider"
        if [ -z "$EMAIL_PROVIDER" ]; then
            ui_info "Provider '$provider' not configured. Run: /email setup $provider"
            return
        fi
        _email_show_provider_status
        return
    fi

    # Show all configured providers
    local found=0 conf
    for conf in "$GEORGE_CONFIG_DIR"/email_*.conf; do
        [ -f "$conf" ] || continue
        source "$conf" 2>/dev/null
        [ -n "$EMAIL_PROVIDER" ] || continue
        [ $found -gt 0 ] && echo ""
        found=$((found + 1))
        _email_show_provider_status
    done

    # Backward compat: check old email.conf
    if [ $found -eq 0 ] && [ -f "$GEORGE_CONFIG_DIR/email.conf" ]; then
        source "$GEORGE_CONFIG_DIR/email.conf" 2>/dev/null
        if [ -n "$EMAIL_PROVIDER" ]; then
            found=1
            _email_show_provider_status
        fi
    fi

    if [ $found -eq 0 ]; then
        ui_info "Not configured. Run: /email setup <provider>"
    fi
}

# ═══════════════════════════════════════════════════════════════
# ProtonMail Bridge — Automated Setup & Management
# ═══════════════════════════════════════════════════════════════
# Proton Mail Bridge creates a local IMAP/SMTP server that
# decrypts Proton Mail messages on-the-fly. On headless Linux
# (including Termux), we use `pass` (password-store) as the
# keychain backend, which requires its own GPG key.
#
# Architecture:
#   protonmail-bridge (daemon) ──► SMTP 127.0.0.1:1025
#                               ──► IMAP 127.0.0.1:1143
#   Keychain: pass (GPG-encrypted password store)
#
# Requirements:
#   - Proton Mail PAID plan (Bridge is not available on free tier)
#   - gnupg, pass, protonmail-bridge (or proton-bridge)

# Bridge SMTP/IMAP defaults (set by Proton Mail Bridge)
BRIDGE_SMTP_HOST="${BRIDGE_SMTP_HOST:-127.0.0.1}"
BRIDGE_SMTP_PORT="${BRIDGE_SMTP_PORT:-1025}"
BRIDGE_IMAP_HOST="${BRIDGE_IMAP_HOST:-127.0.0.1}"
BRIDGE_IMAP_PORT="${BRIDGE_IMAP_PORT:-1143}"
BRIDGE_PASS_DIR="${BRIDGE_PASS_DIR:-$HOME/.password-store}"

# ── Detect the bridge binary name ──────────────────────────────
_bridge_bin() {
    if command -v protonmail-bridge &>/dev/null; then
        echo "protonmail-bridge"
    elif command -v proton-bridge &>/dev/null; then
        echo "proton-bridge"
    else
        echo ""
    fi
}

# ── Check all dependencies for bridge ──────────────────────────
bridge_check_deps() {
    local missing=()
    command -v gpg &>/dev/null || missing+=("gnupg")
    command -v pass &>/dev/null || missing+=("pass")
    local bin
    bin=$(_bridge_bin)
    [ -z "$bin" ] && missing+=("protonmail-bridge")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "${missing[*]}"
        return 1
    fi
    return 0
}

# ── Install bridge dependencies ────────────────────────────────
# Installs gnupg and pass via apt/pkg. Bridge itself must be
# installed separately (DEB download or pkg).
bridge_install_deps() {
    ui_section "ProtonMail Bridge — Dependency Check"
    echo ""

    local needs_install=0

    # GPG
    if command -v gpg &>/dev/null; then
        ui_ok "gnupg — installed"
    else
        ui_step "Installing gnupg..."
        if command -v pkg &>/dev/null; then
            pkg install -y gnupg 2>&1 | tail -1
        elif command -v apt &>/dev/null; then
            apt install -y gnupg 2>&1 | tail -1
        fi
        command -v gpg &>/dev/null && ui_ok "gnupg — installed" || { ui_err "gnupg install failed"; needs_install=1; }
    fi

    # pass (password-store)
    if command -v pass &>/dev/null; then
        ui_ok "pass — installed"
    else
        ui_step "Installing pass..."
        if command -v pkg &>/dev/null; then
            pkg install -y pass 2>&1 | tail -1
        elif command -v apt &>/dev/null; then
            apt install -y pass 2>&1 | tail -1
        fi
        command -v pass &>/dev/null && ui_ok "pass — installed" || { ui_err "pass install failed"; needs_install=1; }
    fi

    # protonmail-bridge
    local bin
    bin=$(_bridge_bin)
    if [ -n "$bin" ]; then
        ui_ok "protonmail-bridge — installed ($bin)"
    else
        needs_install=1
        echo ""
        ui_warn "protonmail-bridge not found"
        ui_info "Install it using one of these methods:"
        echo ""
        ui_dim "  Termux:  pkg install protonmail-bridge"
        ui_dim "  Debian:  Download .deb from https://proton.me/mail/bridge"
        ui_dim "           sudo dpkg -i protonmail-bridge_*.deb"
        ui_dim "  Arch:    yay -S protonmail-bridge-bin"
        echo ""
        ui_dim "  Note: Proton Mail Bridge requires a PAID Proton Mail plan."
    fi

    return $needs_install
}

# ── Generate a GPG key for the pass store ──────────────────────
# This is NOT George's PGP signing key (that's in ~/.george/.gnupg).
# This is a separate key used solely by `pass` to encrypt the
# keychain that Proton Mail Bridge needs.
bridge_init_pass() {
    if [ -d "$BRIDGE_PASS_DIR" ] && [ -n "$(ls -A "$BRIDGE_PASS_DIR" 2>/dev/null)" ]; then
        ui_ok "pass store already initialized at $BRIDGE_PASS_DIR"
        return 0
    fi

    if ! command -v gpg &>/dev/null; then
        ui_err "gnupg required. Run: /email bridge install"
        return 1
    fi
    if ! command -v pass &>/dev/null; then
        ui_err "pass required. Run: /email bridge install"
        return 1
    fi

    ui_section "Initializing Pass Store for Bridge Keychain"
    echo ""

    # Check for existing GPG key we can reuse
    local existing_key
    existing_key=$(gpg --list-keys --with-colons 2>/dev/null | grep '^uid:' | head -1)

    local key_id=""
    if [ -n "$existing_key" ]; then
        # Extract the key ID from the first available key
        key_id=$(gpg --list-keys --with-colons --keyid-format long 2>/dev/null | \
                 grep '^pub:' | head -1 | cut -d: -f5)
        if [ -n "$key_id" ]; then
            ui_info "Found existing GPG key: $key_id"
            printf "  Use this key for pass store? [Y/n]: "
            local use_existing
            read -r use_existing < /dev/tty
            if [[ "${use_existing,,}" == "n" ]]; then
                key_id=""
            fi
        fi
    fi

    if [ -z "$key_id" ]; then
        ui_step "Generating GPG key for pass store..."
        ui_dim "  This key encrypts the keychain that Bridge uses."
        ui_dim "  It is separate from George's PGP signing key."
        echo ""

        # Generate a no-passphrase RSA key for pass
        local batch_file
        batch_file=$(mktemp)
        cat > "$batch_file" << 'GPGEOF'
%no-protection
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: ProtonMail Bridge Keychain
Name-Email: bridge-keychain@localhost
Expire-Date: 0
%commit
GPGEOF
        gpg --batch --gen-key "$batch_file" 2>&1 | grep -v '^\[GNUPG\]'
        local rc=$?
        rm -f "$batch_file"

        if [ $rc -ne 0 ]; then
            ui_err "GPG key generation failed"
            return 1
        fi

        key_id=$(gpg --list-keys --with-colons --keyid-format long "bridge-keychain@localhost" 2>/dev/null | \
                 grep '^pub:' | head -1 | cut -d: -f5)

        if [ -z "$key_id" ]; then
            ui_err "Could not find generated GPG key"
            return 1
        fi

        ui_ok "GPG key generated: $key_id"
    fi

    # Initialize pass with the key
    pass init "$key_id" 2>&1 | grep -v '^\[GNUPG\]'
    if [ $? -ne 0 ]; then
        ui_err "pass init failed"
        return 1
    fi

    ui_ok "Pass store initialized — Bridge keychain ready"
    return 0
}

# ── Check if bridge process is running ─────────────────────────
bridge_is_running() {
    pgrep -f "protonmail-bridge\|proton-bridge" &>/dev/null
}

# ── Check if bridge SMTP/IMAP ports are reachable ──────────────
bridge_is_reachable() {
    # Try SMTP port
    if command -v curl &>/dev/null; then
        curl -s --connect-timeout 2 "smtp://${BRIDGE_SMTP_HOST}:${BRIDGE_SMTP_PORT}" &>/dev/null
        return $?
    elif command -v nc &>/dev/null; then
        nc -z -w2 "$BRIDGE_SMTP_HOST" "$BRIDGE_SMTP_PORT" &>/dev/null
        return $?
    fi
    # Fallback: check /dev/tcp
    (echo >/dev/tcp/"$BRIDGE_SMTP_HOST"/"$BRIDGE_SMTP_PORT") 2>/dev/null
    return $?
}

# ── Start bridge as a background daemon ────────────────────────
bridge_start() {
    local bin
    bin=$(_bridge_bin)
    if [ -z "$bin" ]; then
        ui_err "protonmail-bridge not installed"
        ui_dim "Run: /email bridge install"
        return 1
    fi

    if bridge_is_running; then
        ui_ok "Bridge is already running"
        bridge_is_reachable && ui_ok "SMTP/IMAP ports reachable" || ui_warn "Ports not yet reachable (bridge may be initializing)"
        return 0
    fi

    # Ensure pass store exists (bridge needs it for keychain)
    if [ ! -d "$BRIDGE_PASS_DIR" ] || [ -z "$(ls -A "$BRIDGE_PASS_DIR" 2>/dev/null)" ]; then
        ui_warn "Pass store not initialized — Bridge needs a keychain"
        ui_info "Run: /email bridge init-pass"
        return 1
    fi

    ui_step "Starting ProtonMail Bridge in background..."

    # Launch bridge in non-interactive mode (no GUI, no CLI prompt)
    # --noninteractive keeps it running as a daemon without a tty
    nohup "$bin" --noninteractive > /dev/null 2>&1 &
    local bridge_pid=$!

    # Wait a moment for startup
    sleep 2

    if kill -0 "$bridge_pid" 2>/dev/null; then
        ui_ok "Bridge started (PID: $bridge_pid)"
        # Give it time to bind ports
        local tries=0
        while [ $tries -lt 10 ]; do
            if bridge_is_reachable; then
                ui_ok "SMTP port $BRIDGE_SMTP_PORT reachable"
                return 0
            fi
            sleep 1
            tries=$((tries + 1))
        done
        ui_warn "Bridge is running but ports not yet reachable"
        ui_dim "  It may need a moment to initialize. Check: /email bridge status"
        return 0
    else
        ui_err "Bridge process exited unexpectedly"
        ui_dim "  Try running manually: $bin --cli"
        ui_dim "  This may reveal authentication or keychain errors."
        return 1
    fi
}

# ── Stop bridge ────────────────────────────────────────────────
bridge_stop() {
    if ! bridge_is_running; then
        ui_info "Bridge is not running"
        return 0
    fi
    ui_step "Stopping ProtonMail Bridge..."
    pkill -f "protonmail-bridge\|proton-bridge" 2>/dev/null
    sleep 1
    if bridge_is_running; then
        pkill -9 -f "protonmail-bridge\|proton-bridge" 2>/dev/null
    fi
    ui_ok "Bridge stopped"
}

# ── Bridge login (interactive — requires operator) ─────────────
# Launches bridge in CLI mode so the operator can log in.
# This is the ONE manual step that can't be automated because
# Proton requires interactive credential entry + potential 2FA.
bridge_login() {
    local bin
    bin=$(_bridge_bin)
    if [ -z "$bin" ]; then
        ui_err "protonmail-bridge not installed"
        return 1
    fi

    # Ensure pass store exists
    if [ ! -d "$BRIDGE_PASS_DIR" ] || [ -z "$(ls -A "$BRIDGE_PASS_DIR" 2>/dev/null)" ]; then
        ui_warn "Pass store not initialized — run: /email bridge init-pass"
        return 1
    fi

    ui_section "ProtonMail Bridge — Interactive Login"
    echo ""
    ui_info "This will open the Bridge CLI for you to log in."
    ui_info "You will need your Proton Mail credentials (and 2FA code if enabled)."
    echo ""
    ui_dim "  Commands in Bridge CLI:"
    ui_dim "    login              — Log in to your Proton account"
    ui_dim "    info               — Show SMTP/IMAP settings + bridge password"
    ui_dim "    list               — List logged-in accounts"
    ui_dim "    change mode <id>   — Switch between split/combined address mode"
    ui_dim "    help               — Full command list"
    ui_dim "    exit               — Exit Bridge CLI"
    echo ""
    ui_warn "After logging in, run 'info' to see your bridge password."
    ui_info "You'll need that password for: /email bridge configure"
    echo ""
    printf "  Press Enter to launch Bridge CLI..."
    read -r < /dev/tty

    # Launch in CLI/interactive mode
    "$bin" --cli
    local rc=$?

    echo ""
    if [ $rc -eq 0 ]; then
        ui_ok "Bridge CLI session ended"
        ui_info "Next steps:"
        ui_dim "  1. /email bridge configure  — Set up George's email with bridge credentials"
        ui_dim "  2. /email bridge start       — Launch bridge in background"
    fi
    return $rc
}

# ── Show bridge status ─────────────────────────────────────────
bridge_status() {
    ui_section "ProtonMail Bridge Status"

    # Binary
    local bin
    bin=$(_bridge_bin)
    if [ -n "$bin" ]; then
        local version
        version=$("$bin" --version 2>/dev/null | head -1 || echo "unknown")
        printf "  Binary:     %b%s%b (%s)\n" "$C_GREEN" "installed" "$C_RESET" "$version"
    else
        printf "  Binary:     %b%s%b\n" "$C_RED" "not installed" "$C_RESET"
    fi

    # Dependencies
    local deps_ok=true
    if command -v gpg &>/dev/null; then
        printf "  gnupg:      %b%s%b\n" "$C_GREEN" "installed" "$C_RESET"
    else
        printf "  gnupg:      %b%s%b\n" "$C_RED" "missing" "$C_RESET"
        deps_ok=false
    fi
    if command -v pass &>/dev/null; then
        printf "  pass:       %b%s%b\n" "$C_GREEN" "installed" "$C_RESET"
    else
        printf "  pass:       %b%s%b\n" "$C_RED" "missing" "$C_RESET"
        deps_ok=false
    fi

    # Pass store
    if [ -d "$BRIDGE_PASS_DIR" ] && [ -n "$(ls -A "$BRIDGE_PASS_DIR" 2>/dev/null)" ]; then
        printf "  Pass store: %b%s%b\n" "$C_GREEN" "initialized" "$C_RESET"
    else
        printf "  Pass store: %b%s%b\n" "$C_RED" "not initialized" "$C_RESET"
    fi

    # Process
    if bridge_is_running; then
        local pid
        pid=$(pgrep -f "protonmail-bridge\|proton-bridge" | head -1)
        printf "  Process:    %b%s%b (PID: %s)\n" "$C_GREEN" "running" "$C_RESET" "$pid"
    else
        printf "  Process:    %b%s%b\n" "$C_DIM" "not running" "$C_RESET"
    fi

    # Ports
    if bridge_is_reachable; then
        printf "  SMTP:       %b%s%b (%s:%s)\n" "$C_GREEN" "reachable" "$C_RESET" "$BRIDGE_SMTP_HOST" "$BRIDGE_SMTP_PORT"
        printf "  IMAP:       %b%s%b (%s:%s)\n" "$C_GREEN" "reachable" "$C_RESET" "$BRIDGE_IMAP_HOST" "$BRIDGE_IMAP_PORT"
    else
        printf "  SMTP:       %b%s%b (%s:%s)\n" "$C_RED" "unreachable" "$C_RESET" "$BRIDGE_SMTP_HOST" "$BRIDGE_SMTP_PORT"
        printf "  IMAP:       %b%s%b (%s:%s)\n" "$C_RED" "unreachable" "$C_RESET" "$BRIDGE_IMAP_HOST" "$BRIDGE_IMAP_PORT"
    fi

    # Email config
    email_init "protonmail" 2>/dev/null
    if [ "${EMAIL_PROVIDER:-}" = "protonmail" ] && [ -n "${EMAIL_ADDRESS:-}" ]; then
        printf "  Account:    %b%s%b\n" "$C_CYAN" "$EMAIL_ADDRESS" "$C_RESET"
    else
        printf "  Account:    %b%s%b\n" "$C_DIM" "not configured" "$C_RESET"
    fi
}

# ── Configure George's email for bridge ────────────────────────
# Interactively collects the bridge password and email address,
# then writes email.conf for ProtonMail via Bridge.
bridge_configure() {
    ui_section "Configure George's Email for ProtonMail Bridge"
    echo ""

    email_init "protonmail" 2>/dev/null

    # Get email address
    local address="${EMAIL_ADDRESS:-}"
    if [ -z "$address" ] || [ "${EMAIL_PROVIDER:-}" != "protonmail" ]; then
        printf "  Proton Mail address: "
        read -r address < /dev/tty
        if [ -z "$address" ]; then
            ui_err "Email address required"
            return 1
        fi
    else
        ui_ok "Email address: $address"
    fi

    echo ""
    ui_info "Enter the bridge password from the Bridge CLI 'info' command."
    ui_dim "  This is NOT your Proton account password — it's generated by Bridge."
    printf "  Bridge password: "
    local bridge_password
    read -rs bridge_password < /dev/tty
    echo ""

    if [ -z "$bridge_password" ]; then
        ui_err "Bridge password required"
        ui_dim "  Run: /email bridge login  → then type 'info' to see it"
        return 1
    fi

    # Store password in secrets vault (provider-specific key)
    if declare -f secrets_set &>/dev/null; then
        secrets_set "email_password_protonmail" "$bridge_password"
        ui_ok "Bridge password stored in secrets vault"

        local _bridge_conf
        _bridge_conf="$(_email_config_path "protonmail")"
        cat > "$_bridge_conf" << EOF
# George's email configuration — ProtonMail Bridge
EMAIL_PROVIDER="protonmail"
EMAIL_ADDRESS="$address"
EMAIL_AUTH_METHOD="bridge"
# Password stored in secrets vault: /secret get email_password_protonmail
EOF
    else
        # Fall back to config file if vault unavailable
        local _bridge_conf
        _bridge_conf="$(_email_config_path "protonmail")"
        cat > "$_bridge_conf" << EOF
# George's email configuration — ProtonMail Bridge
EMAIL_PROVIDER="protonmail"
EMAIL_ADDRESS="$address"
EMAIL_AUTH_METHOD="bridge"
EMAIL_PASSWORD="$bridge_password"
EOF
    fi
    chmod 600 "$(_email_config_path "protonmail")"

    # Clear password from memory
    bridge_password=""

    ui_ok "Email configured: $address (ProtonMail Bridge)"
    echo ""
    ui_info "George can now send and receive email via Bridge."
    ui_dim "  Send:  /email send protonmail to=user@proton.me s=Subject here b=Body here"
    ui_dim "  Inbox: /email inbox protonmail"
    ui_dim "  Test:  /email bridge test"
    return 0
}

# ── Test bridge connectivity ───────────────────────────────────
# Sends a test SMTP connection to verify bridge is working.
bridge_test() {
    if ! bridge_is_running; then
        ui_err "Bridge is not running. Start it: /email bridge start"
        return 1
    fi

    if ! bridge_is_reachable; then
        ui_err "Bridge SMTP port not reachable at ${BRIDGE_SMTP_HOST}:${BRIDGE_SMTP_PORT}"
        return 1
    fi

    email_init "protonmail" 2>/dev/null
    local password=""
    if [ "$EMAIL_AUTH_METHOD" = "bridge" ] || [ "$EMAIL_AUTH_METHOD" = "secret" ]; then
        if declare -f secrets_get &>/dev/null; then
            password=$(secrets_get "email_password_protonmail" 2>/dev/null)
            [ -z "$password" ] && password=$(secrets_get "email_password" 2>/dev/null)
        fi
        [ -z "$password" ] && password="${EMAIL_PASSWORD:-}"
    fi

    if [ -z "$password" ] || [ -z "${EMAIL_ADDRESS:-}" ]; then
        ui_err "Email not configured for bridge. Run: /email bridge configure"
        return 1
    fi

    ui_step "Testing SMTP connection to Bridge..."
    local result
    result=$(curl -sS --connect-timeout 5 \
        --url "smtp://${BRIDGE_SMTP_HOST}:${BRIDGE_SMTP_PORT}" \
        --ssl-reqd \
        --user "${EMAIL_ADDRESS}:${password}" \
        2>&1)
    local rc=$?

    # curl returns 67 for login failed, 0 or 56 for success (SMTP session opened)
    if [ $rc -eq 0 ] || [ $rc -eq 56 ]; then
        ui_ok "SMTP authentication successful!"
        ui_ok "Bridge is fully operational"
        return 0
    elif [ $rc -eq 67 ]; then
        ui_err "SMTP authentication failed — check bridge password"
        ui_dim "  Run: /email bridge login → 'info' to get the correct password"
        ui_dim "  Then: /email bridge configure"
        return 1
    else
        ui_err "SMTP connection error (curl exit $rc)"
        ui_dim "$result"
        return 1
    fi
}

# ── Full bridge setup orchestrator ─────────────────────────────
# Walks the operator through the complete setup flow.
bridge_setup() {
    ui_section "ProtonMail Bridge — Full Setup"
    echo ""
    ui_info "This will walk you through setting up ProtonMail Bridge."
    ui_warn "Requirement: A paid Proton Mail plan (Bridge is not free-tier)."
    echo ""

    # Step 1: Dependencies
    ui_step "Step 1/5: Checking dependencies..."
    local missing
    missing=$(bridge_check_deps)
    if [ $? -ne 0 ]; then
        ui_info "Missing: $missing"
        printf "  Install now? [Y/n]: "
        local do_install
        read -r do_install < /dev/tty
        if [[ "${do_install,,}" != "n" ]]; then
            bridge_install_deps || {
                echo ""
                ui_err "Some dependencies could not be installed automatically."
                ui_info "Install them manually, then re-run: /email bridge setup"
                return 1
            }
        else
            ui_info "Install dependencies manually, then re-run: /email bridge setup"
            return 1
        fi
    else
        ui_ok "All dependencies installed"
    fi
    echo ""

    # Step 2: Pass store
    ui_step "Step 2/5: Initializing pass store (keychain)..."
    bridge_init_pass || return 1
    echo ""

    # Step 3: Bridge login (manual — requires Proton credentials)
    ui_step "Step 3/5: Logging into Proton Mail..."
    ui_info "This step is interactive — you'll enter your Proton credentials."
    printf "  Ready to log in? [Y/n]: "
    local do_login
    read -r do_login < /dev/tty
    if [[ "${do_login,,}" == "n" ]]; then
        echo ""
        ui_info "Skipped login. When ready, run: /email bridge login"
        ui_info "Then: /email bridge configure"
        return 0
    fi
    bridge_login
    echo ""

    # Step 4: Configure George's email
    ui_step "Step 4/5: Configuring George's email..."
    bridge_configure || return 1
    echo ""

    # Step 5: Start bridge daemon
    ui_step "Step 5/5: Starting bridge daemon..."
    bridge_start || return 1
    echo ""

    # Final test
    ui_step "Verifying..."
    sleep 2
    if bridge_test; then
        echo ""
        ui_ok "ProtonMail Bridge is fully set up!"
        ui_info "George can now send/receive email via his Proton address."
    else
        echo ""
        ui_warn "Bridge is running but test connection failed."
        ui_dim "  Try: /email bridge test  (after a few seconds)"
    fi
}

# ═══════════════════════════════════════════════════════════════
# SSH Key Management — George's SSH identity for GitHub/remotes
# ═══════════════════════════════════════════════════════════════

GEORGE_SSH_DIR="${GEORGE_SSH_DIR:-$GEORGE_CONFIG_DIR/.ssh}"
GEORGE_SSH_KEY="${GEORGE_SSH_KEY:-$GEORGE_SSH_DIR/id_ed25519}"

# ── Initialize SSH directory ───────────────────────────────────
ssh_init() {
    if [ -d "$GEORGE_SSH_DIR" ]; then
        return 0
    fi
    mkdir -p "$GEORGE_SSH_DIR"
    chmod 700 "$GEORGE_SSH_DIR"
    ui_dim "Initialized SSH directory at $GEORGE_SSH_DIR"
}

# ── Check if George has an SSH key ─────────────────────────────
ssh_has_key() {
    [ -f "$GEORGE_SSH_KEY" ]
}

# ── Generate SSH keypair ──────────────────────────────────────
# Creates an Ed25519 key (fast, secure, small).
# No passphrase — George is an automated agent.
ssh_generate_key() {
    ssh_init || return 1

    if ssh_has_key; then
        ui_warn "George already has an SSH key"
        ui_dim "Public key: $GEORGE_SSH_KEY.pub"
        return 0
    fi

    # Use George's email as the key comment if configured
    local key_comment="george@blue-lodge"
    email_init >/dev/null 2>&1
    [ -n "${EMAIL_ADDRESS:-}" ] && key_comment="$EMAIL_ADDRESS"

    ui_step "Generating Ed25519 SSH key..."
    ssh-keygen -t ed25519 -C "$key_comment" -f "$GEORGE_SSH_KEY" -N "" -q 2>&1
    if [ $? -ne 0 ]; then
        ui_err "SSH key generation failed"
        return 1
    fi
    chmod 600 "$GEORGE_SSH_KEY"
    chmod 644 "$GEORGE_SSH_KEY.pub"

    ui_ok "SSH key generated"
    ui_dim "  Private: $GEORGE_SSH_KEY"
    ui_dim "  Public:  $GEORGE_SSH_KEY.pub"
    echo ""
    ui_info "Public key (add this to GitHub → Settings → SSH keys):"
    echo ""
    cat "$GEORGE_SSH_KEY.pub"
    echo ""
    return 0
}

# ── Get the public key ─────────────────────────────────────────
ssh_get_pubkey() {
    if ! ssh_has_key; then
        return 1
    fi
    cat "$GEORGE_SSH_KEY.pub"
}

# ── Configure git to use George's SSH key (Host alias) ────────
# Writes an SSH Host alias so git@github.com-george routes
# through George's key. Does NOT export GIT_SSH_COMMAND or
# set global core.sshCommand — operator's git is untouched.
ssh_configure_git() {
    if ! ssh_has_key; then
        ui_err "No SSH key found. Run: /email ssh-keygen"
        return 1
    fi

    # Delegate to git.sh if loaded (preferred — single source of truth)
    if declare -f git_write_ssh_config &>/dev/null; then
        git_write_ssh_config
        return $?
    fi

    # Fallback: write config directly (same logic as git_write_ssh_config)
    local ssh_config="$GEORGE_SSH_DIR/config"
    mkdir -p "$GEORGE_SSH_DIR"
    local host="${GEORGE_GIT_HOST:-github.com-george}"

    # Migrate old block
    if [ -f "$ssh_config" ] && grep -q "^Host github\.com$" "$ssh_config" 2>/dev/null; then
        sed -i '/^Host github\.com$/,/^$/d' "$ssh_config"
    fi

    # Idempotent
    if [ -f "$ssh_config" ] && grep -q "^Host ${host}$" "$ssh_config" 2>/dev/null; then
        return 0
    fi

    cat >> "$ssh_config" << EOF

# George's GitHub SSH identity (Host alias)
Host $host
    HostName github.com
    User git
    IdentityFile $GEORGE_SSH_KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
    chmod 600 "$ssh_config"
    ui_dim "SSH config: Host $host → $ssh_config"
}

# ── Configure git identity (user.name + user.email) ───────────
# Automatically sets git config from George's email address.
git_configure_identity() {
    local scope="${1:---global}"

    email_init >/dev/null 2>&1
    local git_email="${EMAIL_ADDRESS:-george@blue-lodge.local}"
    local git_name="George (Blue Lodge)"

    git config $scope user.name "$git_name" 2>/dev/null
    git config $scope user.email "$git_email" 2>/dev/null
    ui_dim "Git identity: $git_name <$git_email>"
}

# ── Test SSH connection to GitHub (via Host alias) ────────────
ssh_test_github() {
    if ! ssh_has_key; then
        ui_err "No SSH key. Run: /email ssh-keygen"
        return 1
    fi

    # Ensure SSH config exists
    ssh_configure_git 2>/dev/null

    local host="${GEORGE_GIT_HOST:-github.com-george}"
    local ssh_config="$GEORGE_SSH_DIR/config"

    ui_step "Testing SSH connection to GitHub via Host alias ($host)..."
    local result
    result=$(ssh -F "$ssh_config" -o ConnectTimeout=10 -T "git@${host}" 2>&1)
    if [[ "$result" == *"successfully authenticated"* ]]; then
        ui_ok "GitHub SSH authenticated!"
        echo "$result"
        return 0
    else
        ui_err "GitHub SSH authentication failed"
        ui_dim "$result"
        ui_info "Make sure this public key is added to GitHub:"
        cat "$GEORGE_SSH_KEY.pub"
        return 1
    fi
}

# ── Full GitHub setup (auto-configure as much as possible) ─────
# Generates SSH key, configures git, tests connection.
# Returns 0 if GitHub push-ready, 1 if manual steps remain.
github_setup() {
    ui_section "GitHub Setup for George"
    echo ""

    local needs_manual=0

    # Step 1: Email (required for GitHub)
    email_init >/dev/null 2>&1
    if [ -z "${EMAIL_ADDRESS:-}" ]; then
        ui_err "George needs an email address first"
        ui_info "Run: /email setup"
        return 1
    fi
    ui_ok "Email: $EMAIL_ADDRESS"

    # Step 2: SSH key (auto-generate if missing)
    if ! ssh_has_key; then
        ui_step "No SSH key found — generating one..."
        ssh_generate_key || return 1
    else
        ui_ok "SSH key: $(cat "$GEORGE_SSH_KEY.pub" | awk '{print $1, substr($3,1,30)}')"
    fi

    # Step 3: git identity
    git_configure_identity
    ui_ok "Git identity configured"

    # Step 4: Write SSH Host alias config (no global pollution)
    ssh_configure_git
    ui_ok "SSH Host alias configured (${GEORGE_GIT_HOST:-github.com-george})"

    # Step 5: Test GitHub connection
    echo ""
    if ssh_test_github; then
        ui_ok "George is ready to push to GitHub!"
        return 0
    else
        echo ""
        ui_warn "Manual step required:"
        ui_info "1. Copy the public key above"
        ui_info "2. Go to: https://github.com/settings/ssh/new"
        ui_info "3. Paste the key and save"
        ui_info "4. Run: /email github-test  (to verify)"
        needs_manual=1
    fi

    return $needs_manual
}

# ── Check if George is GitHub-ready ────────────────────────────
# Returns 0 if email + SSH key exist (doesn't test connection).
github_is_ready() {
    email_init >/dev/null 2>&1
    [ -n "${EMAIL_ADDRESS:-}" ] && ssh_has_key
}

# ── Check if a git remote is GitHub ───────────────────────────
_is_github_remote() {
    local remote_url="${1:-}"
    [[ "$remote_url" == *"github.com"* ]] || [[ "$remote_url" == *"${GEORGE_GIT_HOST:-github.com-george}"* ]]
}

# ── GitHub push guard ─────────────────────────────────────────
# Call before any push to a GitHub remote. Returns 0 if allowed,
# 1 if blocked (missing email or SSH key). Local pushes always allowed.
github_push_guard() {
    local remote_url="${1:-}"

    # No remote or local remote — always allow
    [ -z "$remote_url" ] && return 0
    [[ "$remote_url" != *"github.com"* ]] && return 0

    # GitHub remote — check prerequisites
    if ! github_is_ready; then
        echo ""
        ui_err "Cannot push to GitHub — George's identity is not configured"
        email_init >/dev/null 2>&1
        if [ -z "${EMAIL_ADDRESS:-}" ]; then
            ui_info "  Missing: email address  →  /email setup"
        fi
        if ! ssh_has_key; then
            ui_info "  Missing: SSH key        →  /email ssh-keygen"
        fi
        echo ""
        ui_info "Run: /email github-setup  (auto-configures everything)"
        return 1
    fi

    # Ensure SSH Host alias config is written
    ssh_configure_git 2>/dev/null
    return 0
}

# ── SSH status ─────────────────────────────────────────────────
ssh_status() {
    ui_section "SSH"
    if ssh_has_key; then
        printf "  Key:      %b%s%b\n" "$C_GREEN" "configured" "$C_RESET"
        printf "  Type:     Ed25519\n"
        printf "  Pub:      %s\n" "$(cat "$GEORGE_SSH_KEY.pub" 2>/dev/null | awk '{print $1, substr($0,length($0)-30)}')"
    else
        printf "  Key:      %b%s%b\n" "$C_RED" "not generated" "$C_RESET"
        ui_dim "  Generate: /email ssh-keygen"
    fi
}
