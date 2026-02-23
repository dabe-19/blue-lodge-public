#!/bin/bash
# ── George: Email Integration ──────────────────────────────────
# Manage email accounts across free providers so George can have
# his own identity (needed for GitHub, package registries, etc.).
#
# Supported providers:
#   protonmail  — ProtonMail (ProtonMail Bridge for SMTP/IMAP)
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
GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-$HOME/.george}"
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

    [zoho_smtp]="smtp.zoho.com:587"
    [zoho_imap]="imap.zoho.com:993"
    [zoho_auth]="password"                     # standard user/pass or app password
    [zoho_setup]="Create free account: https://www.zoho.com/mail/ — enable IMAP in settings"

    [disposable_smtp]=""
    [disposable_imap]=""
    [disposable_auth]="none"                   # no auth needed
    [disposable_setup]="Guerrilla Mail — temporary address, no signup required"
)

# ── Initialize email config ───────────────────────────────────
email_init() {
    mkdir -p "$(dirname "$EMAIL_CONFIG")"
    if [ ! -f "$EMAIL_CONFIG" ]; then
        cat > "$EMAIL_CONFIG" << 'EOF'
# George's email configuration
# Provider: protonmail | tutanota | zoho | disposable
EMAIL_PROVIDER=""
EMAIL_ADDRESS=""
# Auth: "secret" (uses /secret get email_password) or "bridge" (ProtonMail Bridge)
EMAIL_AUTH_METHOD=""
EOF
        chmod 600 "$EMAIL_CONFIG"
        ui_ok "Email config created at $EMAIL_CONFIG"
    fi
    source "$EMAIL_CONFIG" 2>/dev/null
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
        printf "  %b2%b  Zoho Mail   — free tier, standard IMAP/SMTP\n" "$C_CYAN" "$C_RESET"
        printf "  %b3%b  Tuta        — encrypted, no SMTP/IMAP (limited)\n" "$C_CYAN" "$C_RESET"
        printf "  %b4%b  Disposable  — temporary address via Guerrilla Mail\n" "$C_CYAN" "$C_RESET"
        echo ""
        printf "  Choose provider [1-4]: "
        local choice
        read -r choice < /dev/tty
        case "$choice" in
            1) provider="protonmail" ;;
            2) provider="zoho"       ;;
            3) provider="tutanota"   ;;
            4) provider="disposable" ;;
            *) ui_err "Invalid choice"; return 1 ;;
        esac
    fi

    # Normalize provider name
    provider="${provider,,}"
    case "$provider" in
        proton|protonmail|pm) provider="protonmail" ;;
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
        ui_info "ProtonMail requires Bridge running locally on port 1025/1143."
        printf "  Is ProtonMail Bridge installed and running? [y/N]: "
        local bridge_ok
        read -r bridge_ok < /dev/tty
        if [[ "${bridge_ok,,}" != "y" ]]; then
            ui_warn "Install ProtonMail Bridge first: https://proton.me/mail/bridge"
            ui_dim "  Then re-run: /email setup protonmail"
            return 1
        fi
        auth_method="bridge"
    fi

    printf "  Password (or app password): "
    local password
    read -rs password < /dev/tty
    echo ""
    if [ -z "$password" ]; then
        ui_err "Password required"
        return 1
    fi

    # Store password in secrets vault
    if declare -f secrets_set &>/dev/null; then
        secrets_set "email_password" "$password"
        ui_ok "Password stored in secrets vault"
    else
        ui_warn "Secrets vault not available — password will be in config (less secure)"
        # Fall back to config file
        auth_method="config"
    fi

    # Write config
    cat > "$EMAIL_CONFIG" << EOF
# George's email configuration
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

    cat > "$EMAIL_CONFIG" << EOF
# George's email configuration — DISPOSABLE
EMAIL_PROVIDER="disposable"
EMAIL_ADDRESS="$address"
EMAIL_AUTH_METHOD="none"
GUERRILLA_SID="$sid_token"
EOF
    chmod 600 "$EMAIL_CONFIG"

    ui_ok "Disposable email ready: $address"
    ui_warn "This address expires after ~60 minutes of inactivity"
    echo "$address"
}

# ── Get current email address ──────────────────────────────────
email_get_address() {
    email_init
    if [ -z "$EMAIL_ADDRESS" ]; then
        return 1
    fi
    echo "$EMAIL_ADDRESS"
}

# ── Get current provider ──────────────────────────────────────
email_get_provider() {
    email_init
    echo "${EMAIL_PROVIDER:-none}"
}

# ── Send an email ─────────────────────────────────────────────
# Usage: email_send "to@example.com" "Subject" "Body"
email_send() {
    local to="$1"
    local subject="$2"
    local body="$3"

    email_init
    if [ -z "$EMAIL_PROVIDER" ]; then
        ui_err "No email configured. Run: /email setup"
        return 1
    fi

    case "$EMAIL_PROVIDER" in
        protonmail) _email_send_smtp "$to" "$subject" "$body" "127.0.0.1" "1025" ;;
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
        password=$(secrets_get "email_password" 2>/dev/null)
    elif [ "$EMAIL_AUTH_METHOD" = "bridge" ] || [ "$EMAIL_AUTH_METHOD" = "config" ]; then
        password="${EMAIL_PASSWORD:-}"
    fi

    if [ -z "$password" ] && [ "$EMAIL_AUTH_METHOD" != "bridge" ]; then
        ui_err "Email password not found. Run: /secret set email_password <password>"
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

    local curl_auth=""
    if [ -n "$password" ]; then
        curl_auth="--user ${EMAIL_ADDRESS}:${password}"
    fi

    local result
    result=$(curl -sS --url "smtp://${host}:${port}" \
        --ssl-reqd \
        $curl_auth \
        --mail-from "$EMAIL_ADDRESS" \
        --mail-rcpt "$to" \
        --upload-file "$msg_file" 2>&1)
    local rc=$?

    rm -f "$msg_file"

    if [ $rc -eq 0 ]; then
        ui_ok "Email sent to $to"
        return 0
    else
        ui_err "Send failed: $result"
        return 1
    fi
}

# ── Check inbox (IMAP via curl) ────────────────────────────────
# Usage: email_inbox [count]
email_inbox() {
    local count="${1:-5}"

    email_init
    if [ -z "$EMAIL_PROVIDER" ]; then
        ui_err "No email configured. Run: /email setup"
        return 1
    fi

    case "$EMAIL_PROVIDER" in
        protonmail) _email_inbox_imap "127.0.0.1" "1143" "$count" ;;
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
        password=$(secrets_get "email_password" 2>/dev/null)
    elif [ "$EMAIL_AUTH_METHOD" = "bridge" ] || [ "$EMAIL_AUTH_METHOD" = "config" ]; then
        password="${EMAIL_PASSWORD:-}"
    fi

    if [ -z "$password" ]; then
        ui_err "Email password not found. Run: /secret set email_password <password>"
        return 1
    fi

    # Fetch message list via IMAP SEARCH
    local result
    result=$(curl -sS --url "imaps://${host}:${port}/INBOX" \
        --user "${EMAIL_ADDRESS}:${password}" \
        -X "SEARCH RECENT" 2>&1)

    if [ $? -ne 0 ]; then
        ui_err "IMAP connection failed: $result"
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

# ── Email status ──────────────────────────────────────────────
email_status() {
    email_init

    ui_section "Email"
    if [ -z "$EMAIL_PROVIDER" ]; then
        ui_info "Not configured. Run: /email setup"
        return
    fi

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
        disposable)
            if [ -n "${GUERRILLA_SID:-}" ]; then
                printf "  Session:  %bactive%b\n" "$C_GREEN" "$C_RESET"
            else
                printf "  Session:  %bexpired%b\n" "$C_RED" "$C_RESET"
            fi ;;
    esac
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

# ── Configure git to use George's SSH key ─────────────────────
# Sets GIT_SSH_COMMAND so git operations use George's key.
ssh_configure_git() {
    if ! ssh_has_key; then
        ui_err "No SSH key found. Run: /email ssh-keygen"
        return 1
    fi
    export GIT_SSH_COMMAND="ssh -i $GEORGE_SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    ui_dim "Git configured to use George's SSH key"
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

# ── Test SSH connection to GitHub ──────────────────────────────
ssh_test_github() {
    if ! ssh_has_key; then
        ui_err "No SSH key. Run: /email ssh-keygen"
        return 1
    fi

    ui_step "Testing SSH connection to GitHub..."
    local result
    result=$(ssh -i "$GEORGE_SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 -T git@github.com 2>&1)
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

    # Step 4: Configure git to use George's key
    ssh_configure_git

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
    [[ "$remote_url" == *"github.com"* ]]
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

    # Ensure git is configured to use the key for this push
    ssh_configure_git
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
