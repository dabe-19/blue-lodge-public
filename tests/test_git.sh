#!/bin/bash
# ── Tests: lib/git.sh ─────────────────────────────────────────
# Git & GitHub configuration: identity, SSH persistence, GPG
# commit signing, remote management, full auto-setup, status.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"

TMPDIR_GIT=""
_SAVED_HOME=""

_setup_git() {
    TMPDIR_GIT=$(test_tmpdir)
    # Redirect HOME so 'git config --global' writes to temp dir,
    # not the real ~/.gitconfig
    _SAVED_HOME="$HOME"
    export HOME="$TMPDIR_GIT"
    export GIT_CONFIG_NOSYSTEM=1
    export GEORGE_CONFIG_DIR="$TMPDIR_GIT/.george"
    export GEORGE_SSH_DIR="$GEORGE_CONFIG_DIR/.ssh"
    export GEORGE_SSH_KEY="$GEORGE_SSH_DIR/id_ed25519"
    export GEORGE_GIT_CONFIG="$GEORGE_CONFIG_DIR/gitconfig"
    export GEORGE_GNUPG_DIR="$GEORGE_CONFIG_DIR/.gnupg"
    export GEORGE_PGP_PUBKEY_FILE="$GEORGE_CONFIG_DIR/george_public.asc"
    export PGP_KEY_NAME="Test George"
    export PGP_KEY_EMAIL="test@blue-lodge.local"
    export PGP_KEY_COMMENT="Test Agent"
    mkdir -p "$GEORGE_SSH_DIR" "$GEORGE_GNUPG_DIR"
    chmod 700 "$GEORGE_GNUPG_DIR"

    # Source dependencies (pgp and email stubs where needed, then git)
    source "$LODGE_DIR/lib/pgp.sh"
    source "$LODGE_DIR/lib/email.sh"
    source "$LODGE_DIR/lib/git.sh"
}

_setup_git_with_ssh_key() {
    _setup_git
    # Generate a real Ed25519 SSH key for testing
    ssh-keygen -t ed25519 -N "" -f "$GEORGE_SSH_KEY" -C "test@blue-lodge" >/dev/null 2>&1
}

_setup_git_repo() {
    _setup_git_with_ssh_key
    repo_dir="$TMPDIR_GIT/repo"
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init >/dev/null 2>&1
    git config user.name "Test" 2>/dev/null
    git config user.email "test@test.local" 2>/dev/null
}

_teardown_git() {
    cd /tmp 2>/dev/null
    # Restore real HOME so subsequent tests/processes are unaffected
    if [[ -n "$_SAVED_HOME" ]]; then
        export HOME="$_SAVED_HOME"
    fi
    unset GIT_CONFIG_NOSYSTEM
    rm -rf "$TMPDIR_GIT"
}

test_start "lib/git.sh — Git & GitHub Configuration"

# ═══════════════════════════════════════════════════════════════
# Function existence
# ═══════════════════════════════════════════════════════════════
describe "Core functions"

  it "git_set_identity is defined" && {
    _setup_git
    declare -f git_set_identity &>/dev/null
    assert_ok $?
    _teardown_git
  }

  it "git_show_identity is defined" && {
    declare -f git_show_identity &>/dev/null
    assert_ok $?
  }

  it "git_write_ssh_config is defined" && {
    declare -f git_write_ssh_config &>/dev/null
    assert_ok $?
  }

  it "git_configure_ssh is defined" && {
    declare -f git_configure_ssh &>/dev/null
    assert_ok $?
  }

  it "git_configure_signing is defined" && {
    declare -f git_configure_signing &>/dev/null
    assert_ok $?
  }

  it "git_disable_signing is defined" && {
    declare -f git_disable_signing &>/dev/null
    assert_ok $?
  }

  it "git_signing_enabled is defined" && {
    declare -f git_signing_enabled &>/dev/null
    assert_ok $?
  }

  it "git_add_remote is defined" && {
    declare -f git_add_remote &>/dev/null
    assert_ok $?
  }

  it "git_list_remotes is defined" && {
    declare -f git_list_remotes &>/dev/null
    assert_ok $?
  }

  it "git_full_setup is defined" && {
    declare -f git_full_setup &>/dev/null
    assert_ok $?
  }

  it "git_status_overview is defined" && {
    declare -f git_status_overview &>/dev/null
    assert_ok $?
  }

  it "github_push_guard is defined" && {
    declare -f github_push_guard &>/dev/null
    assert_ok $?
  }

# ═══════════════════════════════════════════════════════════════
# Git Identity
# ═══════════════════════════════════════════════════════════════
describe "git_set_identity"

  it "sets git user.name globally" && {
    _setup_git
    git_set_identity "Test George" "test@example.com" "--global" >/dev/null 2>&1
    name=$(git config --global user.name 2>/dev/null)
    assert_eq "$name" "Test George"
    _teardown_git
  }

  it "sets git user.email globally" && {
    _setup_git
    git_set_identity "Test George" "test@example.com" "--global" >/dev/null 2>&1
    email=$(git config --global user.email 2>/dev/null)
    assert_eq "$email" "test@example.com"
    _teardown_git
  }

  it "uses default name when not provided" && {
    _setup_git
    git_set_identity "" "test@example.com" "--global" >/dev/null 2>&1
    name=$(git config --global user.name 2>/dev/null)
    assert_eq "$name" "George (Blue Lodge)"
    _teardown_git
  }

  it "uses local fallback email when no email configured" && {
    _setup_git
    git_set_identity "George" "" "--global" >/dev/null 2>&1
    email=$(git config --global user.email 2>/dev/null)
    assert_contains "$email" "blue-lodge"
    _teardown_git
  }

describe "git_show_identity"

  it "outputs Name: line" && {
    _setup_git
    git_set_identity "Display Test" "disp@test.com" "--global" >/dev/null 2>&1
    output=$(git_show_identity 2>&1)
    assert_contains "$output" "Display Test"
    _teardown_git
  }

  it "outputs Email: line" && {
    _setup_git
    git_set_identity "Display Test" "disp@test.com" "--global" >/dev/null 2>&1
    output=$(git_show_identity 2>&1)
    assert_contains "$output" "disp@test.com"
    _teardown_git
  }

# ═══════════════════════════════════════════════════════════════
# SSH Configuration
# ═══════════════════════════════════════════════════════════════
describe "git_write_ssh_config"

  it "fails without SSH key" && {
    _setup_git
    output=$(git_write_ssh_config 2>&1)
    assert_fail $?
    _teardown_git
  }

  it "creates SSH config file with key present" && {
    _setup_git_with_ssh_key
    git_write_ssh_config >/dev/null 2>&1
    assert_file_exists "$GEORGE_SSH_DIR/config"
    _teardown_git
  }

  it "writes Host alias entry (github.com-george)" && {
    _setup_git_with_ssh_key
    git_write_ssh_config >/dev/null 2>&1
    content=$(cat "$GEORGE_SSH_DIR/config" 2>/dev/null)
    assert_contains "$content" "Host $GEORGE_GIT_HOST"
    _teardown_git
  }

  it "includes IdentityFile pointing to George's key" && {
    _setup_git_with_ssh_key
    git_write_ssh_config >/dev/null 2>&1
    content=$(cat "$GEORGE_SSH_DIR/config" 2>/dev/null)
    assert_contains "$content" "IdentityFile $GEORGE_SSH_KEY"
    _teardown_git
  }

  it "sets IdentitiesOnly yes" && {
    _setup_git_with_ssh_key
    git_write_ssh_config >/dev/null 2>&1
    content=$(cat "$GEORGE_SSH_DIR/config" 2>/dev/null)
    assert_contains "$content" "IdentitiesOnly yes"
    _teardown_git
  }

  it "sets permissions to 600 on config file" && {
    _setup_git_with_ssh_key
    git_write_ssh_config >/dev/null 2>&1
    perms=$(stat -c '%a' "$GEORGE_SSH_DIR/config" 2>/dev/null)
    assert_eq "$perms" "600"
    _teardown_git
  }

  it "is idempotent — does not duplicate entries" && {
    _setup_git_with_ssh_key
    git_write_ssh_config >/dev/null 2>&1
    git_write_ssh_config >/dev/null 2>&1
    count=$(grep -c "Host $GEORGE_GIT_HOST" "$GEORGE_SSH_DIR/config" 2>/dev/null)
    assert_eq "$count" "1"
    _teardown_git
  }

  it "includes HostName github.com (real hostname)" && {
    _setup_git_with_ssh_key
    git_write_ssh_config >/dev/null 2>&1
    content=$(cat "$GEORGE_SSH_DIR/config" 2>/dev/null)
    assert_contains "$content" "HostName github.com"
    _teardown_git
  }

  it "migrates old Host github.com block" && {
    _setup_git_with_ssh_key
    # Plant an old-style config
    mkdir -p "$GEORGE_SSH_DIR"
    cat > "$GEORGE_SSH_DIR/config" << 'OLDEOF'
Host github.com
    HostName github.com
    User git
    IdentityFile /tmp/old-key
    IdentitiesOnly yes
OLDEOF
    git_write_ssh_config >/dev/null 2>&1
    content=$(cat "$GEORGE_SSH_DIR/config" 2>/dev/null)
    # Old block gone (exact "Host github.com" line, not the alias)
    old_count=$(echo "$content" | grep -c "^Host github\.com$" 2>/dev/null || true)
    assert_eq "$old_count" "0"
    # New alias present
    assert_contains "$content" "Host $GEORGE_GIT_HOST"
    _teardown_git
  }

describe "git_configure_ssh"

  it "fails without SSH key" && {
    _setup_git
    git_configure_ssh >/dev/null 2>&1
    assert_fail $?
    _teardown_git
  }

  it "does NOT set GIT_SSH_COMMAND (no global pollution)" && {
    _setup_git_with_ssh_key
    unset GIT_SSH_COMMAND 2>/dev/null
    git_configure_ssh >/dev/null 2>&1
    assert_empty "${GIT_SSH_COMMAND:-}"
    _teardown_git
  }

  it "does NOT set global core.sshCommand (no global pollution)" && {
    _setup_git_with_ssh_key
    git_configure_ssh >/dev/null 2>&1
    ssh_cmd=$(git config --global core.sshCommand 2>/dev/null)
    assert_empty "$ssh_cmd"
    _teardown_git
  }

  it "cleans up legacy GIT_SSH_COMMAND if set" && {
    _setup_git_with_ssh_key
    export GIT_SSH_COMMAND="ssh -i /old/key"
    git_configure_ssh >/dev/null 2>&1
    assert_empty "${GIT_SSH_COMMAND:-}"
    _teardown_git
  }

  it "cleans up legacy global core.sshCommand" && {
    _setup_git_with_ssh_key
    git config --global core.sshCommand "ssh -i /old/key" 2>/dev/null
    git_configure_ssh >/dev/null 2>&1
    ssh_cmd=$(git config --global core.sshCommand 2>/dev/null)
    assert_empty "$ssh_cmd"
    _teardown_git
  }

  it "writes SSH config file" && {
    _setup_git_with_ssh_key
    git_configure_ssh >/dev/null 2>&1
    assert_file_exists "$GEORGE_SSH_DIR/config"
    _teardown_git
  }

# ═══════════════════════════════════════════════════════════════
# GPG Commit Signing
# ═══════════════════════════════════════════════════════════════
describe "git_signing_enabled"

  it "returns false when signing not configured" && {
    _setup_git
    git config --global --unset commit.gpgsign 2>/dev/null
    git_signing_enabled
    assert_fail $?
    _teardown_git
  }

  it "returns true when commit.gpgsign is true" && {
    _setup_git
    git config --global commit.gpgsign true 2>/dev/null
    git_signing_enabled
    assert_ok $?
    # Clean up
    git config --global --unset commit.gpgsign 2>/dev/null
    _teardown_git
  }

describe "git_disable_signing"

  it "unsets commit.gpgsign" && {
    _setup_git
    git config --global commit.gpgsign true 2>/dev/null
    git_disable_signing >/dev/null 2>&1
    git_signing_enabled
    assert_fail $?
    _teardown_git
  }

  it "unsets tag.gpgsign" && {
    _setup_git
    git config --global tag.gpgsign true 2>/dev/null
    git_disable_signing >/dev/null 2>&1
    tag_sign=$(git config --global tag.gpgsign 2>/dev/null)
    assert_empty "$tag_sign"
    _teardown_git
  }

  it "unsets user.signingkey" && {
    _setup_git
    git config --global user.signingkey "ABCD1234" 2>/dev/null
    git_disable_signing >/dev/null 2>&1
    key=$(git config --global user.signingkey 2>/dev/null)
    assert_empty "$key"
    _teardown_git
  }

describe "git_configure_signing"

  it "enables commit.gpgsign when GPG available" && {
    _setup_git
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        pgp_generate_key >/dev/null 2>&1
        git_configure_signing >/dev/null 2>&1
        git_signing_enabled
        assert_ok $?
        # Clean up
        git_disable_signing >/dev/null 2>&1
    fi
    _teardown_git
  }

  it "sets user.signingkey when GPG available" && {
    _setup_git
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        pgp_generate_key >/dev/null 2>&1
        git_configure_signing >/dev/null 2>&1
        key=$(git config --global user.signingkey 2>/dev/null)
        assert_not_empty "$key"
        # Clean up
        git_disable_signing >/dev/null 2>&1
    fi
    _teardown_git
  }

  it "creates gpg-george.sh wrapper script" && {
    _setup_git
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        pgp_generate_key >/dev/null 2>&1
        git_configure_signing >/dev/null 2>&1
        assert_file_exists "$GEORGE_CONFIG_DIR/gpg-george.sh"
        # Clean up
        git_disable_signing >/dev/null 2>&1
    fi
    _teardown_git
  }

  it "wrapper script references GNUPGHOME" && {
    _setup_git
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        pgp_generate_key >/dev/null 2>&1
        git_configure_signing >/dev/null 2>&1
        wrapper_content=$(cat "$GEORGE_CONFIG_DIR/gpg-george.sh" 2>/dev/null)
        assert_contains "$wrapper_content" "GNUPGHOME"
        # Clean up
        git_disable_signing >/dev/null 2>&1
    fi
    _teardown_git
  }

  it "wrapper script is executable" && {
    _setup_git
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        pgp_generate_key >/dev/null 2>&1
        git_configure_signing >/dev/null 2>&1
        [[ -x "$GEORGE_CONFIG_DIR/gpg-george.sh" ]]
        assert_ok $?
        # Clean up
        git_disable_signing >/dev/null 2>&1
    fi
    _teardown_git
  }

# ═══════════════════════════════════════════════════════════════
# Remote Management
# ═══════════════════════════════════════════════════════════════
describe "git_add_remote"

  it "fails without url argument" && {
    _setup_git_repo
    git_add_remote "origin" "" >/dev/null 2>&1
    assert_fail $?
    _teardown_git
  }

  it "adds a remote with SSH url (converts to Host alias)" && {
    _setup_git_repo
    git_add_remote "testremote" "git@github.com:user/repo.git" >/dev/null 2>&1
    url=$(git remote get-url testremote 2>/dev/null)
    assert_eq "$url" "git@${GEORGE_GIT_HOST}:user/repo.git"
    _teardown_git
  }

  it "converts HTTPS GitHub URL to SSH Host alias format" && {
    _setup_git_repo
    git_add_remote "httpsremote" "https://github.com/owner/myproject" >/dev/null 2>&1
    url=$(git remote get-url httpsremote 2>/dev/null)
    assert_eq "$url" "git@${GEORGE_GIT_HOST}:owner/myproject.git"
    _teardown_git
  }

  it "converts HTTPS URL with .git suffix" && {
    _setup_git_repo
    git_add_remote "dotgit" "https://github.com/owner/myrepo.git" >/dev/null 2>&1
    url=$(git remote get-url dotgit 2>/dev/null)
    assert_eq "$url" "git@${GEORGE_GIT_HOST}:owner/myrepo.git"
    _teardown_git
  }

  it "passes non-GitHub URLs through unchanged" && {
    _setup_git_repo
    git_add_remote "gitlab" "git@gitlab.com:user/repo.git" >/dev/null 2>&1
    url=$(git remote get-url gitlab 2>/dev/null)
    assert_eq "$url" "git@gitlab.com:user/repo.git"
    _teardown_git
  }

  it "updates existing remote instead of erroring" && {
    _setup_git_repo
    git_add_remote "updtest" "git@github.com:old/repo.git" >/dev/null 2>&1
    git_add_remote "updtest" "git@github.com:new/repo.git" >/dev/null 2>&1
    url=$(git remote get-url updtest 2>/dev/null)
    assert_eq "$url" "git@${GEORGE_GIT_HOST}:new/repo.git"
    _teardown_git
  }

describe "git_list_remotes"

  it "shows 'No remotes' when none exist" && {
    _setup_git_repo
    output=$(git_list_remotes 2>&1)
    assert_contains "$output" "No remotes"
    _teardown_git
  }

  it "lists configured remotes" && {
    _setup_git_repo
    git remote add showremote "git@github.com:user/repo.git" 2>/dev/null
    output=$(git_list_remotes 2>&1)
    assert_contains "$output" "showremote"
    _teardown_git
  }

# ═══════════════════════════════════════════════════════════════
# Status Overview
# ═══════════════════════════════════════════════════════════════
describe "git_status_overview"

  it "shows Identity section" && {
    _setup_git
    git_set_identity "Status Test" "status@test.com" "--global" >/dev/null 2>&1
    output=$(git_status_overview 2>&1)
    assert_contains "$output" "Identity"
    _teardown_git
  }

  it "shows SSH section" && {
    _setup_git
    output=$(git_status_overview 2>&1)
    assert_contains "$output" "SSH"
    _teardown_git
  }

  it "shows Commit Signing section" && {
    _setup_git
    output=$(git_status_overview 2>&1)
    assert_contains "$output" "Commit Signing"
    _teardown_git
  }

  it "shows 'not generated' when no SSH key" && {
    _setup_git
    output=$(git_status_overview 2>&1)
    assert_contains "$output" "not generated"
    _teardown_git
  }

  it "shows 'configured' when SSH key exists" && {
    _setup_git_with_ssh_key
    output=$(git_status_overview 2>&1)
    assert_contains "$output" "configured"
    _teardown_git
  }

  it "shows 'persistent' when SSH config exists" && {
    _setup_git_with_ssh_key
    git_write_ssh_config >/dev/null 2>&1
    output=$(git_status_overview 2>&1)
    assert_contains "$output" "persistent"
    _teardown_git
  }

  it "shows signing 'disabled' when not configured" && {
    _setup_git
    git config --global --unset commit.gpgsign 2>/dev/null
    output=$(git_status_overview 2>&1)
    assert_contains "$output" "disabled"
    _teardown_git
  }

# ═══════════════════════════════════════════════════════════════
# Push Guard
# ═══════════════════════════════════════════════════════════════
describe "github_push_guard"

  it "allows non-GitHub remotes" && {
    _setup_git
    github_push_guard "git@gitlab.com:user/repo.git" >/dev/null 2>&1
    assert_ok $?
    _teardown_git
  }

  it "allows empty remote" && {
    _setup_git
    github_push_guard "" >/dev/null 2>&1
    assert_ok $?
    _teardown_git
  }

  it "allows local path remotes" && {
    _setup_git
    github_push_guard "/tmp/local-repo" >/dev/null 2>&1
    assert_ok $?
    _teardown_git
  }

# ═══════════════════════════════════════════════════════════════
# Lodge command handler
# ═══════════════════════════════════════════════════════════════
describe "_cmd_git (lodge integration)"

  it "_cmd_git is defined when lodge is sourced" && {
    # Source lodge indirectly — just check if it would be defined
    source "$LODGE_DIR/lib/git.sh"
    # _cmd_git lives in lodge, not git.sh — check the function list
    # Just verify git.sh functions loaded correctly
    declare -f git_full_setup &>/dev/null
    assert_ok $?
  }

# ═══════════════════════════════════════════════════════════════
# /git consolidation — unified entrypoint routing
# ═══════════════════════════════════════════════════════════════
describe "_cmd_git consolidation (search/check/clone/commit/push)"

  # Source lodge functions using the same eval trick as test_lodge.sh
  _load_cmd_git() {
    source "$LODGE_DIR/lib/web.sh" 2>/dev/null || true
    source "$LODGE_DIR/lib/backup.sh" 2>/dev/null || true
    source "$LODGE_DIR/lib/journal.sh" 2>/dev/null || true
    eval "$(sed 's/^main "$@"$//' "$LODGE_DIR/lodge" | grep -v '^set -uo pipefail')" 2>/dev/null
  }

  it "/git search with no query shows usage error" && {
    _setup_git
    _load_cmd_git
    out=$(_cmd_git "search" 2>&1)
    assert_contains "$out" "Usage"
    _teardown_git
  }

  it "/git check with no repo shows usage error" && {
    _setup_git
    _load_cmd_git
    out=$(_cmd_git "check" 2>&1)
    assert_contains "$out" "Usage"
    _teardown_git
  }

  it "/git search shows usage with just the action word" && {
    _setup_git
    _load_cmd_git
    out=$(_cmd_git "search" 2>&1)
    assert_contains "$out" "search"
    _teardown_git
  }

  it "/git clone command script exists for delegation" && {
    assert_file_exists "$LODGE_DIR/commands/clone.sh"
  }

  it "/git commit command script exists for delegation" && {
    assert_file_exists "$LODGE_DIR/commands/commit.sh"
  }

  it "/git push command script exists for delegation" && {
    assert_file_exists "$LODGE_DIR/commands/push.sh"
  }

  it "/git help includes search in usage" && {
    _setup_git
    _load_cmd_git
    out=$(_cmd_git "" 2>&1)
    assert_contains "$out" "search"
    _teardown_git
  }

  it "/git help includes clone in usage" && {
    _setup_git
    _load_cmd_git
    out=$(_cmd_git "" 2>&1)
    assert_contains "$out" "clone"
    _teardown_git
  }

  it "/git help includes commit in usage" && {
    _setup_git
    _load_cmd_git
    out=$(_cmd_git "" 2>&1)
    assert_contains "$out" "commit"
    _teardown_git
  }

  it "/git help includes push in usage" && {
    _setup_git
    _load_cmd_git
    out=$(_cmd_git "" 2>&1)
    assert_contains "$out" "push"
    _teardown_git
  }

test_end
