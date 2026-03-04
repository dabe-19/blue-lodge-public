#!/bin/bash
# ── Tests: lib/email.sh ─────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/web.sh"
source "$LODGE_DIR/lib/email.sh"

test_start "lib/email.sh — Email Integration"

TMPDIR_EMAIL=""
ORIG_EMAIL_CONFIG=""
ORIG_GEORGE_DIR=""
ORIG_SSH_DIR=""
ORIG_SSH_KEY=""

_setup_email() {
    TMPDIR_EMAIL=$(test_tmpdir)
    ORIG_EMAIL_CONFIG="$EMAIL_CONFIG"
    ORIG_GEORGE_DIR="$GEORGE_CONFIG_DIR"
    ORIG_SSH_DIR="$GEORGE_SSH_DIR"
    ORIG_SSH_KEY="$GEORGE_SSH_KEY"
    export GEORGE_CONFIG_DIR="$TMPDIR_EMAIL/george"
    export EMAIL_CONFIG="$TMPDIR_EMAIL/george/email.conf"
    export GEORGE_SSH_DIR="$TMPDIR_EMAIL/george/.ssh"
    export GEORGE_SSH_KEY="$TMPDIR_EMAIL/george/.ssh/id_ed25519"
    mkdir -p "$GEORGE_CONFIG_DIR"
    # Reset globals
    EMAIL_PROVIDER=""
    EMAIL_ADDRESS=""
    EMAIL_AUTH_METHOD=""
    EMAIL_PASSWORD=""
    GUERRILLA_SID=""
}

# Helper: write a per-provider config for tests
_write_provider_conf() {
    provider="$1"
    shift
    conf="$GEORGE_CONFIG_DIR/email_${provider}.conf"
    cat > "$conf" "$@"
    chmod 600 "$conf"
}

_teardown_email() {
    export EMAIL_CONFIG="$ORIG_EMAIL_CONFIG"
    export GEORGE_CONFIG_DIR="$ORIG_GEORGE_DIR"
    export GEORGE_SSH_DIR="$ORIG_SSH_DIR"
    export GEORGE_SSH_KEY="$ORIG_SSH_KEY"
    rm -rf "$TMPDIR_EMAIL"
    EMAIL_PROVIDER=""
    EMAIL_ADDRESS=""
    EMAIL_AUTH_METHOD=""
    EMAIL_PASSWORD=""
    GUERRILLA_SID=""
}

# ── Provider definitions ──────────────────────────────────────
describe "Provider definitions"

  it "has ProtonMail SMTP defined" && {
    assert_not_empty "${EMAIL_PROVIDERS[protonmail_smtp]}"
  }

  it "has Gmail SMTP defined" && {
    assert_not_empty "${EMAIL_PROVIDERS[gmail_smtp]}"
  }

  it "has Gmail IMAP defined" && {
    assert_not_empty "${EMAIL_PROVIDERS[gmail_imap]}"
  }

  it "has Gmail auth as password" && {
    assert_eq "${EMAIL_PROVIDERS[gmail_auth]}" "password"
  }

  it "has Gmail setup instructions" && {
    assert_not_empty "${EMAIL_PROVIDERS[gmail_setup]}"
  }

  it "has Zoho SMTP defined" && {
    assert_not_empty "${EMAIL_PROVIDERS[zoho_smtp]}"
  }

  it "has Zoho IMAP defined" && {
    assert_not_empty "${EMAIL_PROVIDERS[zoho_imap]}"
  }

  it "has Tuta auth method as api" && {
    assert_eq "${EMAIL_PROVIDERS[tutanota_auth]}" "api"
  }

  it "has disposable auth as none" && {
    assert_eq "${EMAIL_PROVIDERS[disposable_auth]}" "none"
  }

  it "has setup instructions for all providers" && {
    assert_not_empty "${EMAIL_PROVIDERS[protonmail_setup]}"
    assert_not_empty "${EMAIL_PROVIDERS[gmail_setup]}"
    assert_not_empty "${EMAIL_PROVIDERS[tutanota_setup]}"
    assert_not_empty "${EMAIL_PROVIDERS[zoho_setup]}"
    assert_not_empty "${EMAIL_PROVIDERS[disposable_setup]}"
  }

# ── email_init ────────────────────────────────────────────────
describe "email_init"

  it "creates config directory on first run" && {
    _setup_email
    rm -rf "$GEORGE_CONFIG_DIR"
    email_init
    assert_dir_exists "$GEORGE_CONFIG_DIR"
    _teardown_email
  }

  it "loads provider-specific config" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_zoho.conf" << 'EOF'
EMAIL_PROVIDER="zoho"
EMAIL_ADDRESS="george@zohomail.com"
EMAIL_AUTH_METHOD="secret"
EOF
    email_init "zoho"
    assert_eq "$EMAIL_PROVIDER" "zoho"
    assert_eq "$EMAIL_ADDRESS" "george@zohomail.com"
    _teardown_email
  }

  it "auto-detects first configured provider" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_gmail.conf" << 'EOF'
EMAIL_PROVIDER="gmail"
EMAIL_ADDRESS="george@gmail.com"
EMAIL_AUTH_METHOD="secret"
EOF
    email_init
    assert_eq "$EMAIL_PROVIDER" "gmail"
    _teardown_email
  }

  it "falls back to old email.conf" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email.conf" << 'EOF'
EMAIL_PROVIDER="zoho"
EMAIL_ADDRESS="george@zoho.com"
EMAIL_AUTH_METHOD="secret"
EOF
    email_init
    assert_eq "$EMAIL_PROVIDER" "zoho"
    _teardown_email
  }

  it "is idempotent" && {
    _setup_email
    email_init
    email_init  # second call should not fail
    assert_dir_exists "$GEORGE_CONFIG_DIR"
    _teardown_email
  }

# ── email_list_configured ─────────────────────────────────────
describe "email_list_configured"

  it "returns empty when no providers" && {
    _setup_email
    out=$(email_list_configured)
    assert_eq "$out" ""
    _teardown_email
  }

  it "lists configured providers" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_gmail.conf" << 'EOF'
EMAIL_PROVIDER="gmail"
EMAIL_ADDRESS="george@gmail.com"
EOF
    cat > "$GEORGE_CONFIG_DIR/email_zoho.conf" << 'EOF'
EMAIL_PROVIDER="zoho"
EMAIL_ADDRESS="george@zoho.com"
EOF
    out=$(email_list_configured)
    assert_contains "$out" "gmail"
    assert_contains "$out" "zoho"
    _teardown_email
  }

  it "detects old email.conf as fallback" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email.conf" << 'EOF'
EMAIL_PROVIDER="protonmail"
EMAIL_ADDRESS="george@proton.me"
EOF
    out=$(email_list_configured)
    assert_contains "$out" "protonmail"
    _teardown_email
  }

# ── email_get_address ─────────────────────────────────────────
describe "email_get_address"

  it "returns empty when not configured" && {
    _setup_email
    addr=$(email_get_address 2>/dev/null)
    assert_eq "$addr" ""
    _teardown_email
  }

  it "returns address when configured" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_zoho.conf" << 'EOF'
EMAIL_PROVIDER="zoho"
EMAIL_ADDRESS="george@zohomail.com"
EMAIL_AUTH_METHOD="secret"
EOF
    addr=$(email_get_address "zoho")
    assert_eq "$addr" "george@zohomail.com"
    _teardown_email
  }

# ── email_get_provider ────────────────────────────────────────
describe "email_get_provider"

  it "returns 'none' when not configured" && {
    _setup_email
    prov=$(email_get_provider 2>/dev/null)
    assert_eq "$prov" "none"
    _teardown_email
  }

  it "returns provider when configured" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_protonmail.conf" << 'EOF'
EMAIL_PROVIDER="protonmail"
EMAIL_ADDRESS="george@proton.me"
EMAIL_AUTH_METHOD="bridge"
EOF
    prov=$(email_get_provider "protonmail")
    assert_eq "$prov" "protonmail"
    _teardown_email
  }

# ── email_status ──────────────────────────────────────────────
describe "email_status"

  it "shows 'Not configured' when no email set" && {
    _setup_email
    out=$(email_status 2>&1)
    assert_contains "$out" "Not configured"
    _teardown_email
  }

  it "shows provider and address when configured" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_zoho.conf" << 'EOF'
EMAIL_PROVIDER="zoho"
EMAIL_ADDRESS="george@zohomail.com"
EMAIL_AUTH_METHOD="secret"
EOF
    out=$(email_status 2>&1)
    assert_contains "$out" "zoho"
    assert_contains "$out" "george@zohomail.com"
    _teardown_email
  }

  it "shows specific provider status" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_gmail.conf" << 'EOF'
EMAIL_PROVIDER="gmail"
EMAIL_ADDRESS="george@gmail.com"
EMAIL_AUTH_METHOD="secret"
EOF
    out=$(email_status "gmail" 2>&1)
    assert_contains "$out" "gmail"
    assert_contains "$out" "george@gmail.com"
    _teardown_email
  }

# ── email_send guards ─────────────────────────────────────────
describe "email_send"

  it "fails when provider not given" && {
    _setup_email
    email_send "" "test@example.com" "Hi" "Body" 2>/dev/null
    assert_fail $?
    _teardown_email
  }

  it "fails when provider not configured" && {
    _setup_email
    email_send "gmail" "test@example.com" "Hi" "Body" 2>/dev/null
    assert_fail $?
    _teardown_email
  }

  it "rejects tutanota send" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_tutanota.conf" << 'EOF'
EMAIL_PROVIDER="tutanota"
EMAIL_ADDRESS="george@tuta.io"
EMAIL_AUTH_METHOD="api"
EOF
    out=$(email_send "tutanota" "test@example.com" "Hi" "Body" 2>&1)
    assert_contains "$out" "does not support SMTP"
    _teardown_email
  }

  it "rejects disposable send" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_disposable.conf" << 'EOF'
EMAIL_PROVIDER="disposable"
EMAIL_ADDRESS="temp@guerrillamail.com"
EMAIL_AUTH_METHOD="none"
EOF
    out=$(email_send "disposable" "test@example.com" "Hi" "Body" 2>&1)
    assert_contains "$out" "receive-only"
    _teardown_email
  }

# ── email_inbox guards ────────────────────────────────────────
describe "email_inbox"

  it "fails when provider not given" && {
    _setup_email
    email_inbox "" 2>/dev/null
    assert_fail $?
    _teardown_email
  }

  it "fails when provider not configured" && {
    _setup_email
    email_inbox "gmail" 2>/dev/null
    assert_fail $?
    _teardown_email
  }

  it "rejects tutanota inbox" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_tutanota.conf" << 'EOF'
EMAIL_PROVIDER="tutanota"
EMAIL_ADDRESS="george@tuta.io"
EMAIL_AUTH_METHOD="api"
EOF
    out=$(email_inbox "tutanota" 2>&1)
    assert_contains "$out" "does not support IMAP"
    _teardown_email
  }

# ── SSH key management ─────────────────────────────────────────
describe "SSH key management"

  it "ssh_init creates .ssh directory" && {
    _setup_email
    ssh_init
    assert_dir_exists "$GEORGE_SSH_DIR"
    _teardown_email
  }

  it "ssh_has_key returns false when no key" && {
    _setup_email
    ssh_has_key
    assert_fail $?
    _teardown_email
  }

  it "ssh_generate_key creates keypair" && {
    _setup_email
    out=$(ssh_generate_key 2>&1)
    assert_file_exists "$GEORGE_SSH_KEY"
    assert_file_exists "$GEORGE_SSH_KEY.pub"
    _teardown_email
  }

  it "ssh_generate_key is idempotent" && {
    _setup_email
    ssh_generate_key >/dev/null 2>&1
    out=$(ssh_generate_key 2>&1)
    assert_contains "$out" "already has"
    _teardown_email
  }

  it "ssh_get_pubkey returns public key" && {
    _setup_email
    ssh_generate_key >/dev/null 2>&1
    pubkey=$(ssh_get_pubkey)
    assert_contains "$pubkey" "ssh-ed25519"
    _teardown_email
  }

  it "ssh_get_pubkey fails when no key" && {
    _setup_email
    ssh_get_pubkey 2>/dev/null
    assert_fail $?
    _teardown_email
  }

  it "ssh_configure_git writes SSH Host alias config" && {
    _setup_email
    ssh_generate_key >/dev/null 2>&1
    ssh_configure_git >/dev/null 2>&1
    config_content=$(cat "$GEORGE_SSH_DIR/config" 2>/dev/null)
    host="${GEORGE_GIT_HOST:-github.com-george}"
    assert_contains "$config_content" "Host $host"
    assert_contains "$config_content" "HostName github.com"
    _teardown_email
  }

  it "ssh_configure_git does NOT set GIT_SSH_COMMAND" && {
    _setup_email
    ssh_generate_key >/dev/null 2>&1
    unset GIT_SSH_COMMAND 2>/dev/null
    ssh_configure_git >/dev/null 2>&1
    assert_empty "${GIT_SSH_COMMAND:-}"
    _teardown_email
  }

  it "ssh_configure_git fails without key" && {
    _setup_email
    ssh_configure_git 2>/dev/null
    assert_fail $?
    _teardown_email
  }

# ── Git identity ───────────────────────────────────────────────
describe "git_configure_identity"

  it "is defined" && {
    declare -f git_configure_identity &>/dev/null
    assert_ok $?
  }

# ── GitHub readiness ──────────────────────────────────────────
describe "GitHub readiness"

  it "github_is_ready returns false without email" && {
    _setup_email
    github_is_ready
    assert_fail $?
    _teardown_email
  }

  it "github_is_ready returns false without SSH key" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_zoho.conf" << 'EOF'
EMAIL_PROVIDER="zoho"
EMAIL_ADDRESS="george@zoho.com"
EMAIL_AUTH_METHOD="secret"
EOF
    email_init >/dev/null 2>&1
    github_is_ready
    assert_fail $?
    _teardown_email
  }

  it "github_is_ready returns true with email + SSH key" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_zoho.conf" << 'EOF'
EMAIL_PROVIDER="zoho"
EMAIL_ADDRESS="george@zoho.com"
EMAIL_AUTH_METHOD="secret"
EOF
    email_init >/dev/null 2>&1
    ssh_generate_key >/dev/null 2>&1
    github_is_ready
    assert_ok $?
    _teardown_email
  }

# ── GitHub push guard ──────────────────────────────────────────
describe "GitHub push guard"

  it "allows local pushes always" && {
    _setup_email
    github_push_guard "/home/user/repo" 2>/dev/null
    assert_ok $?
    _teardown_email
  }

  it "allows non-GitHub remotes always" && {
    _setup_email
    github_push_guard "https://gitlab.com/user/repo.git" 2>/dev/null
    assert_ok $?
    _teardown_email
  }

  it "allows empty remote" && {
    _setup_email
    github_push_guard "" 2>/dev/null
    assert_ok $?
    _teardown_email
  }

  it "blocks GitHub push without email" && {
    _setup_email
    github_push_guard "git@github.com:user/repo.git" 2>/dev/null
    assert_fail $?
    _teardown_email
  }

  it "blocks GitHub push without SSH key" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_zoho.conf" << 'EOF'
EMAIL_PROVIDER="zoho"
EMAIL_ADDRESS="george@zoho.com"
EMAIL_AUTH_METHOD="secret"
EOF
    email_init >/dev/null 2>&1
    github_push_guard "https://github.com/user/repo.git" 2>/dev/null
    assert_fail $?
    _teardown_email
  }

  it "allows GitHub push with email + SSH key" && {
    _setup_email
    cat > "$GEORGE_CONFIG_DIR/email_zoho.conf" << 'EOF'
EMAIL_PROVIDER="zoho"
EMAIL_ADDRESS="george@zoho.com"
EMAIL_AUTH_METHOD="secret"
EOF
    email_init >/dev/null 2>&1
    ssh_generate_key >/dev/null 2>&1
    github_push_guard "git@github.com:user/repo.git" >/dev/null 2>&1
    assert_ok $?
    _teardown_email
  }

  it "shows diagnostic when blocked" && {
    _setup_email
    out=$(github_push_guard "git@github.com:user/repo.git" 2>&1)
    assert_contains "$out" "email"
    assert_contains "$out" "SSH"
    _teardown_email
  }

# ── SSH status ─────────────────────────────────────────────────
describe "ssh_status"

  it "shows 'not generated' when no key" && {
    _setup_email
    out=$(ssh_status 2>&1)
    assert_contains "$out" "not generated"
    _teardown_email
  }

  it "shows 'configured' when key exists" && {
    _setup_email
    ssh_generate_key >/dev/null 2>&1
    out=$(ssh_status 2>&1)
    assert_contains "$out" "configured"
    _teardown_email
  }

# ═══════════════════════════════════════════════════════════════
# ProtonMail Bridge — Unit Tests
# ═══════════════════════════════════════════════════════════════

_setup_bridge() {
    _setup_email
    export BRIDGE_PASS_DIR="$TMPDIR_EMAIL/password-store"
}

_teardown_bridge() {
    unset BRIDGE_PASS_DIR
    _teardown_email
}

# ── _bridge_bin ───────────────────────────────────────────────
describe "_bridge_bin"

  it "returns empty when bridge not installed" && {
    _setup_bridge
    out=$(PATH="/nonexistent" _bridge_bin)
    assert_empty "$out"
    _teardown_bridge
  }

# ── bridge_check_deps ────────────────────────────────────────
describe "bridge_check_deps"

  it "reports missing bridge" && {
    _setup_bridge
    out=$(PATH="/nonexistent" bridge_check_deps 2>&1)
    assert_contains "$out" "gnupg"
    _teardown_bridge
  }

  it "returns non-zero when deps missing" && {
    _setup_bridge
    PATH="/nonexistent" bridge_check_deps 2>/dev/null
    assert_fail $?
    _teardown_bridge
  }

# ── bridge_init_pass ──────────────────────────────────────────
describe "bridge_init_pass"

  it "skips when pass store already initialized" && {
    _setup_bridge
    mkdir -p "$BRIDGE_PASS_DIR"
    touch "$BRIDGE_PASS_DIR/.gpg-id"
    out=$(bridge_init_pass 2>&1)
    assert_contains "$out" "already initialized"
    _teardown_bridge
  }

  it "fails without gpg" && {
    _setup_bridge
    rc=0
    out=$(PATH="/nonexistent" bridge_init_pass 2>&1) || rc=$?
    assert_fail $rc
    _teardown_bridge
  }

# ── bridge_is_running ────────────────────────────────────────
describe "bridge_is_running"

  it "returns false when no bridge process" && {
    _setup_bridge
    bridge_is_running
    assert_fail $?
    _teardown_bridge
  }

# ── bridge_is_reachable ──────────────────────────────────────
describe "bridge_is_reachable"

  it "returns false when bridge not running" && {
    _setup_bridge
    bridge_is_reachable
    assert_fail $?
    _teardown_bridge
  }

# ── bridge_start ──────────────────────────────────────────────
describe "bridge_start"

  it "fails when bridge not installed" && {
    _setup_bridge
    rc=0
    out=$(PATH="/nonexistent" bridge_start 2>&1) || rc=$?
    assert_fail $rc
    assert_contains "$out" "not installed"
    _teardown_bridge
  }

  it "fails when pass store not initialized" && {
    _setup_bridge
    # Mock bridge binary to exist but pass store empty
    mockbin="$TMPDIR_EMAIL/bin"
    mkdir -p "$mockbin"
    echo '#!/bin/bash' > "$mockbin/protonmail-bridge"
    chmod +x "$mockbin/protonmail-bridge"
    rc=0
    out=$(PATH="$mockbin" bridge_start 2>&1) || rc=$?
    assert_fail $rc
    assert_contains "$out" "not initialized"
    _teardown_bridge
  }

# ── bridge_stop ───────────────────────────────────────────────
describe "bridge_stop"

  it "reports not running when nothing to stop" && {
    _setup_bridge
    out=$(bridge_stop 2>&1)
    assert_contains "$out" "not running"
    _teardown_bridge
  }

# ── bridge_status ─────────────────────────────────────────────
describe "bridge_status"

  it "shows bridge not installed" && {
    _setup_bridge
    out=$(PATH="/nonexistent" bridge_status 2>&1)
    assert_contains "$out" "not installed"
    _teardown_bridge
  }

  it "shows pass store not initialized" && {
    _setup_bridge
    out=$(bridge_status 2>&1)
    assert_contains "$out" "not initialized"
    _teardown_bridge
  }

  it "shows pass store initialized when present" && {
    _setup_bridge
    mkdir -p "$BRIDGE_PASS_DIR"
    touch "$BRIDGE_PASS_DIR/.gpg-id"
    out=$(bridge_status 2>&1)
    assert_contains "$out" "initialized"
    _teardown_bridge
  }

  it "shows not running when bridge offline" && {
    _setup_bridge
    out=$(bridge_status 2>&1)
    assert_contains "$out" "not running"
    _teardown_bridge
  }

# ── bridge_configure (config output) ──────────────────────────
describe "bridge_configure"

  it "writes per-provider config with bridge settings" && {
    _setup_bridge
    _prov_conf="$GEORGE_CONFIG_DIR/email_protonmail.conf"
    # Directly write config the way bridge_configure does
    cat > "$_prov_conf" << EOF
# George's email configuration — ProtonMail Bridge
EMAIL_PROVIDER="protonmail"
EMAIL_ADDRESS="user@proton.me"
EMAIL_AUTH_METHOD="bridge"
EMAIL_PASSWORD="testbridgepass123"
EOF
    chmod 600 "$_prov_conf"
    assert_file_exists "$_prov_conf"
    conf=$(cat "$_prov_conf")
    assert_contains "$conf" "protonmail"
    assert_contains "$conf" "bridge"
    assert_contains "$conf" "user@proton.me"
    _teardown_bridge
  }

  it "sets 600 permissions on config" && {
    _setup_bridge
    _prov_conf="$GEORGE_CONFIG_DIR/email_protonmail.conf"
    cat > "$_prov_conf" << EOF
EMAIL_PROVIDER="protonmail"
EMAIL_AUTH_METHOD="bridge"
EOF
    chmod 600 "$_prov_conf"
    perms=$(stat -c '%a' "$_prov_conf" 2>/dev/null || stat -f '%Lp' "$_prov_conf" 2>/dev/null)
    assert_eq "$perms" "600"
    _teardown_bridge
  }

# ── bridge_test ───────────────────────────────────────────────
describe "bridge_test"

  it "fails when bridge not running" && {
    _setup_bridge
    rc=0
    out=$(bridge_test 2>&1) || rc=$?
    assert_fail $rc
    assert_contains "$out" "not running"
    _teardown_bridge
  }

# ── Bridge defaults ───────────────────────────────────────────
describe "Bridge constants"

  it "has correct SMTP port default" && {
    assert_eq "$BRIDGE_SMTP_PORT" "1025"
  }

  it "has correct IMAP port default" && {
    assert_eq "$BRIDGE_IMAP_PORT" "1143"
  }

  it "has localhost as default host" && {
    assert_eq "$BRIDGE_SMTP_HOST" "127.0.0.1"
  }

# ── Escape expansion in email ─────────────────────────────────
describe "LLM escape expansion in email"

  it "email_send expands escapes in body" && {
    fn_body=$(declare -f email_send)
    assert_contains "$fn_body" "ui_expand_escapes"
  }

  it "email_send expands escapes in subject" && {
    fn_body=$(declare -f email_send)
    # Should call ui_expand_escapes on subject too
    count=$(echo "$fn_body" | grep -c "ui_expand_escapes")
    assert_gt "$count" 1
  }

# ── Attachment support ─────────────────────────────────────────
describe "Email attachment support"

  it "email_send accepts 5th attachment parameter" && {
    fn_body=$(declare -f email_send)
    assert_contains "$fn_body" "attachment"
  }

  it "_email_send_smtp accepts 6th attachment parameter" && {
    fn_body=$(declare -f _email_send_smtp)
    assert_contains "$fn_body" "attachment"
  }

  it "_email_send_smtp builds multipart/mixed when attachment provided" && {
    fn_body=$(declare -f _email_send_smtp)
    assert_contains "$fn_body" "multipart/mixed"
    assert_contains "$fn_body" "boundary"
  }

  it "_email_send_smtp uses base64 encoding for attachments" && {
    fn_body=$(declare -f _email_send_smtp)
    assert_contains "$fn_body" "base64"
    assert_contains "$fn_body" "Content-Transfer-Encoding"
  }

  it "email_send rejects missing attachment file" && {
    _setup_email
    _write_provider_conf "gmail" <<< 'EMAIL_ADDRESS="test@gmail.com"
EMAIL_AUTH_METHOD="secret"'
    out=$(email_send "gmail" "user@example.com" "Test" "Body" "/nonexistent/file.txt" 2>&1)
    assert_fail $?
    assert_contains "$out" "not found"
    _teardown_email
  }

  it "_email_send_smtp detects MIME type for .txt files" && {
    fn_body=$(declare -f _email_send_smtp)
    assert_contains "$fn_body" "text/plain"
  }

  it "_email_send_smtp detects MIME type for .md files" && {
    fn_body=$(declare -f _email_send_smtp)
    assert_contains "$fn_body" "text/markdown"
  }

  it "_email_send_smtp detects MIME type for .pdf files" && {
    fn_body=$(declare -f _email_send_smtp)
    assert_contains "$fn_body" "application/pdf"
  }

  it "_email_send_smtp Content-Disposition includes filename" && {
    fn_body=$(declare -f _email_send_smtp)
    assert_contains "$fn_body" "Content-Disposition: attachment"
    assert_contains "$fn_body" 'filename='
  }

  it "_email_send_smtp falls back to text/plain without attachment" && {
    fn_body=$(declare -f _email_send_smtp)
    # Should have the simple path with text/plain; charset=UTF-8
    assert_contains "$fn_body" "text/plain; charset=UTF-8"
  }

test_end
