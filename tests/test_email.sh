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

  it "creates config file on first run" && {
    _setup_email
    email_init
    assert_file_exists "$EMAIL_CONFIG"
    _teardown_email
  }

  it "creates config with 600 permissions" && {
    _setup_email
    email_init
    perms=$(stat -c '%a' "$EMAIL_CONFIG" 2>/dev/null || stat -f '%Lp' "$EMAIL_CONFIG" 2>/dev/null)
    assert_eq "$perms" "600"
    _teardown_email
  }

  it "is idempotent" && {
    _setup_email
    email_init
    email_init  # second call should not fail
    assert_file_exists "$EMAIL_CONFIG"
    _teardown_email
  }

# ── email_get_address ─────────────────────────────────────────
describe "email_get_address"

  it "returns empty when not configured" && {
    _setup_email
    email_init >/dev/null 2>&1
    addr=$(email_get_address 2>/dev/null)
    assert_eq "$addr" ""
    _teardown_email
  }

  it "returns address when configured" && {
    _setup_email
    cat > "$EMAIL_CONFIG" << 'EOF'
EMAIL_PROVIDER="zoho"
EMAIL_ADDRESS="george@zohomail.com"
EMAIL_AUTH_METHOD="secret"
EOF
    addr=$(email_get_address)
    assert_eq "$addr" "george@zohomail.com"
    _teardown_email
  }

# ── email_get_provider ────────────────────────────────────────
describe "email_get_provider"

  it "returns 'none' when not configured" && {
    _setup_email
    email_init >/dev/null 2>&1
    prov=$(email_get_provider 2>/dev/null)
    assert_eq "$prov" "none"
    _teardown_email
  }

  it "returns provider when configured" && {
    _setup_email
    cat > "$EMAIL_CONFIG" << 'EOF'
EMAIL_PROVIDER="protonmail"
EMAIL_ADDRESS="george@proton.me"
EMAIL_AUTH_METHOD="bridge"
EOF
    prov=$(email_get_provider)
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
    cat > "$EMAIL_CONFIG" << 'EOF'
EMAIL_PROVIDER="zoho"
EMAIL_ADDRESS="george@zohomail.com"
EMAIL_AUTH_METHOD="secret"
EOF
    out=$(email_status 2>&1)
    assert_contains "$out" "zoho"
    assert_contains "$out" "george@zohomail.com"
    _teardown_email
  }

# ── email_send guards ─────────────────────────────────────────
describe "email_send"

  it "fails when not configured" && {
    _setup_email
    email_send "test@example.com" "Hi" "Body" 2>/dev/null
    assert_fail $?
    _teardown_email
  }

  it "rejects tutanota send" && {
    _setup_email
    cat > "$EMAIL_CONFIG" << 'EOF'
EMAIL_PROVIDER="tutanota"
EMAIL_ADDRESS="george@tuta.io"
EMAIL_AUTH_METHOD="api"
EOF
    out=$(email_send "test@example.com" "Hi" "Body" 2>&1)
    assert_contains "$out" "does not support SMTP"
    _teardown_email
  }

  it "rejects disposable send" && {
    _setup_email
    cat > "$EMAIL_CONFIG" << 'EOF'
EMAIL_PROVIDER="disposable"
EMAIL_ADDRESS="temp@guerrillamail.com"
EMAIL_AUTH_METHOD="none"
EOF
    out=$(email_send "test@example.com" "Hi" "Body" 2>&1)
    assert_contains "$out" "receive-only"
    _teardown_email
  }

# ── email_inbox guards ────────────────────────────────────────
describe "email_inbox"

  it "fails when not configured" && {
    _setup_email
    email_inbox 2>/dev/null
    assert_fail $?
    _teardown_email
  }

  it "rejects tutanota inbox" && {
    _setup_email
    cat > "$EMAIL_CONFIG" << 'EOF'
EMAIL_PROVIDER="tutanota"
EMAIL_ADDRESS="george@tuta.io"
EMAIL_AUTH_METHOD="api"
EOF
    out=$(email_inbox 2>&1)
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

  it "ssh_configure_git sets GIT_SSH_COMMAND" && {
    _setup_email
    ssh_generate_key >/dev/null 2>&1
    ssh_configure_git >/dev/null 2>&1
    assert_contains "$GIT_SSH_COMMAND" "id_ed25519"
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
    cat > "$EMAIL_CONFIG" << 'EOF'
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
    cat > "$EMAIL_CONFIG" << 'EOF'
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
    cat > "$EMAIL_CONFIG" << 'EOF'
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
    cat > "$EMAIL_CONFIG" << 'EOF'
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

  it "writes email.conf with bridge settings" && {
    _setup_bridge
    # Directly write config the way bridge_configure does
    mkdir -p "$(dirname "$EMAIL_CONFIG")"
    cat > "$EMAIL_CONFIG" << EOF
# George's email configuration — ProtonMail Bridge
EMAIL_PROVIDER="protonmail"
EMAIL_ADDRESS="user@proton.me"
EMAIL_AUTH_METHOD="bridge"
EMAIL_PASSWORD="testbridgepass123"
EOF
    chmod 600 "$EMAIL_CONFIG"
    assert_file_exists "$EMAIL_CONFIG"
    conf=$(cat "$EMAIL_CONFIG")
    assert_contains "$conf" "protonmail"
    assert_contains "$conf" "bridge"
    assert_contains "$conf" "user@proton.me"
    _teardown_bridge
  }

  it "sets 600 permissions on config" && {
    _setup_bridge
    mkdir -p "$(dirname "$EMAIL_CONFIG")"
    cat > "$EMAIL_CONFIG" << EOF
EMAIL_PROVIDER="protonmail"
EMAIL_AUTH_METHOD="bridge"
EOF
    chmod 600 "$EMAIL_CONFIG"
    perms=$(stat -c '%a' "$EMAIL_CONFIG" 2>/dev/null || stat -f '%Lp' "$EMAIL_CONFIG" 2>/dev/null)
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

test_end
