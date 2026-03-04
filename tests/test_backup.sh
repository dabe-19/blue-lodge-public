#!/bin/bash
# ── Tests: lib/backup.sh ──────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/backup.sh"

test_start "lib/backup.sh — Backup & Persistence"

TMPDIR_BACKUP=""
ORIG_CONFIG=""
ORIG_BACKUP=""
ORIG_BACKUP_REPO=""

_setup_backup() {
    TMPDIR_BACKUP=$(test_tmpdir)
    ORIG_CONFIG="$GEORGE_CONFIG_DIR"
    ORIG_BACKUP="$GEORGE_BACKUP_DIR"
    ORIG_BACKUP_REPO="$GEORGE_BACKUP_REPO"
    
    export GEORGE_CONFIG_DIR="$TMPDIR_BACKUP/.george"
    export GEORGE_BACKUP_DIR="$GEORGE_CONFIG_DIR/backups"
    export GEORGE_BACKUP_REPO="$GEORGE_CONFIG_DIR/backup-repo"
}

_teardown_backup() {
    export GEORGE_CONFIG_DIR="$ORIG_CONFIG"
    export GEORGE_BACKUP_DIR="$ORIG_BACKUP"
    export GEORGE_BACKUP_REPO="$ORIG_BACKUP_REPO"
    rm -rf "$TMPDIR_BACKUP"
}

# ── backup_init ────────────────────────────────────────────────
describe "backup_init"

  it "creates backup directories" && {
    _setup_backup
    backup_init
    assert_dir_exists "$GEORGE_BACKUP_DIR"
    assert_dir_exists "$GEORGE_CONFIG_DIR"
    _teardown_backup
  }

  it "sets correct permissions on config dir" && {
    _setup_backup
    backup_init
    perms=$(stat -c '%a' "$GEORGE_CONFIG_DIR" 2>/dev/null)
    assert_eq "$perms" "700"
    _teardown_backup
  }

# ── GEORGE_IDENTITY_FILES ─────────────────────────────────────
describe "Identity file list"

  it "includes soul.md" && {
    found=0
    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        [ "$f" = "soul.md" ] && found=1
    done
    assert_eq "$found" "1"
  }

  it "includes journal.md" && {
    found=0
    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        [ "$f" = "journal.md" ] && found=1
    done
    assert_eq "$found" "1"
  }

  it "includes Modelfile" && {
    found=0
    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        [ "$f" = "Modelfile" ] && found=1
    done
    assert_eq "$found" "1"
  }

# ── backup_local ───────────────────────────────────────────────
describe "backup_local"

  it "creates a timestamped backup" && {
    _setup_backup
    backup_init
    result=$(backup_local 2>/dev/null | tail -1)
    assert_not_empty "$result"
    assert_dir_exists "$result"
    _teardown_backup
  }

  it "backs up soul.md when present" && {
    _setup_backup
    backup_init
    result=$(backup_local 2>/dev/null | tail -1)
    assert_file_exists "$result/soul.md"
    _teardown_backup
  }

  it "backs up Modelfile when present" && {
    _setup_backup
    backup_init
    result=$(backup_local 2>/dev/null | tail -1)
    if [ -f "$LODGE_DIR/Modelfile" ]; then
        assert_file_exists "$result/Modelfile"
    else
        skip "Modelfile not present"
    fi
    _teardown_backup
  }

  it "creates a MANIFEST.md" && {
    _setup_backup
    backup_init
    result=$(backup_local 2>/dev/null | tail -1)
    assert_file_exists "$result/MANIFEST.md"
    content=$(cat "$result/MANIFEST.md")
    assert_contains "$content" "George Backup"
    _teardown_backup
  }

  it "backs up keys.conf when present" && {
    _setup_backup
    backup_init
    mkdir -p "$GEORGE_CONFIG_DIR"
    echo "TEST_KEY=value" > "$GEORGE_CONFIG_DIR/keys.conf"
    result=$(backup_local 2>/dev/null | tail -1)
    assert_file_exists "$result/keys.conf"
    _teardown_backup
  }

# ── backup_list ────────────────────────────────────────────────
describe "backup_list"

  it "shows 'no backups' when empty" && {
    _setup_backup
    backup_init
    out=$(backup_list 2>&1)
    assert_contains "$out" "No backups"
    _teardown_backup
  }

  it "lists backups after creating one" && {
    _setup_backup
    backup_init
    backup_local >/dev/null 2>&1
    out=$(backup_list 2>&1)
    assert_contains "$out" "George Backups"
    _teardown_backup
  }

# ── backup_restore ─────────────────────────────────────────────
describe "backup_restore"

  it "fails when no backups exist" && {
    _setup_backup
    backup_init
    backup_restore "" 2>/dev/null
    assert_fail $?
    _teardown_backup
  }

# ── backup_git_init ────────────────────────────────────────────
describe "backup_git_init"

  it "creates a git repo for backups" && {
    _setup_backup
    backup_init
    backup_git_init >/dev/null 2>&1
    assert_dir_exists "$GEORGE_BACKUP_REPO/.git"
    _teardown_backup
  }

  it "creates a README.md in backup repo" && {
    _setup_backup
    backup_init
    backup_git_init >/dev/null 2>&1
    assert_file_exists "$GEORGE_BACKUP_REPO/README.md"
    _teardown_backup
  }

  it "creates a .gitignore in backup repo" && {
    _setup_backup
    backup_init
    backup_git_init >/dev/null 2>&1
    assert_file_exists "$GEORGE_BACKUP_REPO/.gitignore"
    _teardown_backup
  }

  it "is idempotent" && {
    _setup_backup
    backup_init
    backup_git_init >/dev/null 2>&1
    backup_git_init >/dev/null 2>&1
    assert_ok $?
    _teardown_backup
  }

# ── backup_git_save ────────────────────────────────────────────
describe "backup_git_save"

  it "commits identity files to backup repo" && {
    _setup_backup
    backup_init
    backup_git_init >/dev/null 2>&1
    backup_git_save "test save" >/dev/null 2>&1
    # Verify the commit exists
    log=$(git -C "$GEORGE_BACKUP_REPO" log --oneline 2>&1)
    assert_contains "$log" "test save"
    _teardown_backup
  }

  it "copies identity files to repo" && {
    _setup_backup
    backup_init
    backup_git_init >/dev/null 2>&1
    backup_git_save "test" >/dev/null 2>&1
    assert_file_exists "$GEORGE_BACKUP_REPO/soul.md"
    _teardown_backup
  }

# ── backup_status ──────────────────────────────────────────────
describe "backup_status"

  it "shows backup status" && {
    _setup_backup
    backup_init
    out=$(backup_status 2>&1)
    assert_contains "$out" "Backup Status"
    assert_contains "$out" "Local backups"
    _teardown_backup
  }

  it "shows identity file status" && {
    _setup_backup
    backup_init
    out=$(backup_status 2>&1)
    assert_contains "$out" "Identity files"
    assert_contains "$out" "soul.md"
    _teardown_backup
  }

  it "shows git backup as not configured when no repo" && {
    _setup_backup
    backup_init
    out=$(backup_status 2>&1)
    assert_contains "$out" "not configured"
    _teardown_backup
  }

  it "shows git backup when repo exists" && {
    _setup_backup
    backup_init
    backup_git_init >/dev/null 2>&1
    backup_git_save "init" >/dev/null 2>&1
    out=$(backup_status 2>&1)
    assert_contains "$out" "Git backup"
    _teardown_backup
  }

# ── backup_prune ───────────────────────────────────────────────
describe "backup_prune"

  it "does nothing when fewer backups than keep limit" && {
    _setup_backup
    backup_init
    backup_local >/dev/null 2>&1
    out=$(backup_prune 5 2>&1)
    assert_contains "$out" "Nothing to prune"
    _teardown_backup
  }

# ── backup_restore_from_repo ──────────────────────────────────
describe "backup_restore_from_repo"

  it "fails when no repo exists" && {
    _setup_backup
    backup_init
    backup_restore_from_repo 2>/dev/null
    assert_fail $?
    _teardown_backup
  }

# ── Pre/post update hooks ─────────────────────────────────────
describe "backup_pre_update"

  it "creates a backup before update" && {
    _setup_backup
    backup_init
    out=$(backup_pre_update 2>/dev/null)
    assert_not_empty "$out"
    _teardown_backup
  }

describe "backup_post_update"

  it "runs without error when no backup exists" && {
    _setup_backup
    backup_init
    backup_post_update 2>/dev/null
    assert_ok $?
    _teardown_backup
  }

# ── backup_export ──────────────────────────────────────────────
describe "backup_export"

  it "backup_export is defined" && {
    declare -f backup_export &>/dev/null
    assert_ok $?
  }

  it "exports .george to a target directory" && {
    _setup_backup
    backup_init
    echo "test_key=test_value" > "$GEORGE_CONFIG_DIR/keys.conf"
    mkdir -p "$GEORGE_CONFIG_DIR/vault"
    echo "secret" > "$GEORGE_CONFIG_DIR/vault/test.enc"
    _export_target="$TMPDIR_BACKUP/export-target"
    mkdir -p "$_export_target"
    backup_export "$_export_target" 2>/dev/null
    assert_dir_exists "$_export_target/.george"
    assert_file_exists "$_export_target/.george/keys.conf"
    assert_file_exists "$_export_target/.george/vault/test.enc"
    _teardown_backup
  }

  it "exports to parent of LODGE_DIR by default" && {
    _setup_backup
    backup_init
    echo "data" > "$GEORGE_CONFIG_DIR/keys.conf"
    _orig_lodge="$LODGE_DIR"
    export LODGE_DIR="$TMPDIR_BACKUP/fake-lodge"
    mkdir -p "$LODGE_DIR"
    backup_export 2>/dev/null
    assert_dir_exists "$TMPDIR_BACKUP/.george"
    export LODGE_DIR="$_orig_lodge"
    _teardown_backup
  }

  it "fails when no .george exists" && {
    _setup_backup
    export GEORGE_CONFIG_DIR="$TMPDIR_BACKUP/nonexistent"
    backup_export "$TMPDIR_BACKUP" 2>/dev/null
    assert_fail $?
    _teardown_backup
  }

# ── backup_import ──────────────────────────────────────────────
describe "backup_import"

  it "backup_import is defined" && {
    declare -f backup_import &>/dev/null
    assert_ok $?
  }

  it "fails with no argument" && {
    _setup_backup
    backup_import "" 2>/dev/null
    assert_fail $?
    _teardown_backup
  }

  it "fails when source has no .george" && {
    _setup_backup
    _bad_source="$TMPDIR_BACKUP/empty-source"
    mkdir -p "$_bad_source"
    backup_import "$_bad_source" 2>/dev/null
    assert_fail $?
    _teardown_backup
  }

  it "imports from a directory containing .george" && {
    _setup_backup
    # Create a source .george to import from
    _import_source="$TMPDIR_BACKUP/import-source"
    mkdir -p "$_import_source/.george"
    echo "imported_key=imported_val" > "$_import_source/.george/keys.conf"
    echo "imported_data" > "$_import_source/.george/recall.db"
    # Ensure destination doesn't exist yet
    rm -rf "$GEORGE_CONFIG_DIR"
    backup_import "$_import_source" 2>/dev/null
    assert_file_exists "$GEORGE_CONFIG_DIR/keys.conf"
    assert_file_exists "$GEORGE_CONFIG_DIR/recall.db"
    _content=$(cat "$GEORGE_CONFIG_DIR/keys.conf")
    assert_eq "$_content" "imported_key=imported_val"
    _teardown_backup
  }

  it "imports when pointed directly at .george dir" && {
    _setup_backup
    _import_source="$TMPDIR_BACKUP/direct-source"
    mkdir -p "$_import_source/.george"
    echo "direct" > "$_import_source/.george/keys.conf"
    rm -rf "$GEORGE_CONFIG_DIR"
    backup_import "$_import_source/.george" 2>/dev/null
    assert_file_exists "$GEORGE_CONFIG_DIR/keys.conf"
    _content=$(cat "$GEORGE_CONFIG_DIR/keys.conf")
    assert_eq "$_content" "direct"
    _teardown_backup
  }

# ═══════════════════════════════════════════════════════════════
# Auth & Config Backup
# ═══════════════════════════════════════════════════════════════

describe "backup_auth_create"

  it "creates auth backup with SSH keys" && {
    _setup_backup
    backup_init
    mkdir -p "$GEORGE_CONFIG_DIR/.ssh"
    echo "ssh-rsa AAAA" > "$GEORGE_CONFIG_DIR/.ssh/id_rsa.pub"
    backup_auth_create >/dev/null 2>&1
    auth_dir=$(ls -d "$GEORGE_BACKUP_DIR"/auth-* 2>/dev/null | head -1)
    assert_dir_exists "$auth_dir/.ssh"
    _teardown_backup
  }

  it "creates auth backup with GPG keyring" && {
    _setup_backup
    backup_init
    mkdir -p "$GEORGE_CONFIG_DIR/.gnupg"
    echo "gpg-data" > "$GEORGE_CONFIG_DIR/.gnupg/pubring.kbx"
    backup_auth_create >/dev/null 2>&1
    auth_dir=$(ls -d "$GEORGE_BACKUP_DIR"/auth-* 2>/dev/null | head -1)
    assert_dir_exists "$auth_dir/.gnupg"
    _teardown_backup
  }

  it "creates auth backup with keys.conf" && {
    _setup_backup
    backup_init
    echo "API_KEY=test123" > "$GEORGE_CONFIG_DIR/keys.conf"
    backup_auth_create >/dev/null 2>&1
    auth_dir=$(ls -d "$GEORGE_BACKUP_DIR"/auth-* 2>/dev/null | head -1)
    assert_file_exists "$auth_dir/keys.conf"
    _teardown_backup
  }

  it "creates auth backup with vault directory" && {
    _setup_backup
    backup_init
    mkdir -p "$GEORGE_CONFIG_DIR/.vault"
    echo "encrypted" > "$GEORGE_CONFIG_DIR/.vault/secret.enc"
    backup_auth_create >/dev/null 2>&1
    auth_dir=$(ls -d "$GEORGE_BACKUP_DIR"/auth-* 2>/dev/null | head -1)
    assert_dir_exists "$auth_dir/.vault"
    _teardown_backup
  }

  it "includes email provider configs via glob" && {
    _setup_backup
    backup_init
    echo "GMAIL=yes" > "$GEORGE_CONFIG_DIR/email_gmail.conf"
    echo "OUTLOOK=yes" > "$GEORGE_CONFIG_DIR/email_outlook.conf"
    backup_auth_create >/dev/null 2>&1
    auth_dir=$(ls -d "$GEORGE_BACKUP_DIR"/auth-* 2>/dev/null | head -1)
    assert_file_exists "$auth_dir/email_gmail.conf"
    assert_file_exists "$auth_dir/email_outlook.conf"
    _teardown_backup
  }

  it "includes social config databases" && {
    _setup_backup
    backup_init
    echo "mastodon-data" > "$GEORGE_CONFIG_DIR/mastodon_instances.db"
    echo "discord-data" > "$GEORGE_CONFIG_DIR/discord_channels.db"
    backup_auth_create >/dev/null 2>&1
    auth_dir=$(ls -d "$GEORGE_BACKUP_DIR"/auth-* 2>/dev/null | head -1)
    assert_file_exists "$auth_dir/mastodon_instances.db"
    assert_file_exists "$auth_dir/discord_channels.db"
    _teardown_backup
  }

  it "includes lodge.conf from LODGE_DIR" && {
    _setup_backup
    backup_init
    echo "LODGE_MODEL=test" > "$LODGE_DIR/lodge.conf"
    echo "placeholder" > "$GEORGE_CONFIG_DIR/keys.conf"
    backup_auth_create >/dev/null 2>&1
    auth_dir=$(ls -d "$GEORGE_BACKUP_DIR"/auth-* 2>/dev/null | head -1)
    assert_file_exists "$auth_dir/lodge.conf"
    rm -f "$LODGE_DIR/lodge.conf"
    _teardown_backup
  }

  it "does NOT include recall.db" && {
    _setup_backup
    backup_init
    echo "knowledge" > "$GEORGE_CONFIG_DIR/recall.db"
    echo "placeholder" > "$GEORGE_CONFIG_DIR/keys.conf"
    backup_auth_create >/dev/null 2>&1
    auth_dir=$(ls -d "$GEORGE_BACKUP_DIR"/auth-* 2>/dev/null | head -1)
    [ ! -f "$auth_dir/recall.db" ]
    assert_ok $? "recall.db must not be in auth backup"
    _teardown_backup
  }

  it "does NOT include transcripts" && {
    _setup_backup
    backup_init
    mkdir -p "$GEORGE_CONFIG_DIR/transcripts"
    echo "session" > "$GEORGE_CONFIG_DIR/transcripts/2025-01-01.md"
    echo "placeholder" > "$GEORGE_CONFIG_DIR/keys.conf"
    backup_auth_create >/dev/null 2>&1
    auth_dir=$(ls -d "$GEORGE_BACKUP_DIR"/auth-* 2>/dev/null | head -1)
    [ ! -d "$auth_dir/transcripts" ]
    assert_ok $? "transcripts must not be in auth backup"
    _teardown_backup
  }

  it "returns error when nothing to back up" && {
    _setup_backup
    backup_init
    backup_auth_create >/dev/null 2>&1
    assert_fail $? "Should fail with no auth files"
    _teardown_backup
  }

  it "sets secure permissions on backup" && {
    _setup_backup
    backup_init
    echo "secret" > "$GEORGE_CONFIG_DIR/keys.conf"
    backup_auth_create >/dev/null 2>&1
    auth_dir=$(ls -d "$GEORGE_BACKUP_DIR"/auth-* 2>/dev/null | head -1)
    perms=$(stat -c '%a' "$auth_dir" 2>/dev/null)
    assert_eq "$perms" "700"
    perms=$(stat -c '%a' "$auth_dir/keys.conf" 2>/dev/null)
    assert_eq "$perms" "600"
    _teardown_backup
  }

  it "writes a MANIFEST.md" && {
    _setup_backup
    backup_init
    echo "key" > "$GEORGE_CONFIG_DIR/keys.conf"
    backup_auth_create >/dev/null 2>&1
    auth_dir=$(ls -d "$GEORGE_BACKUP_DIR"/auth-* 2>/dev/null | head -1)
    assert_file_exists "$auth_dir/MANIFEST.md"
    grep -q "Auth & Config Backup" "$auth_dir/MANIFEST.md"
    assert_ok $? "Manifest must have auth backup header"
    _teardown_backup
  }

describe "backup_auth_list"

  it "reports no auth backups when none exist" && {
    _setup_backup
    mkdir -p "$GEORGE_BACKUP_DIR"
    _output=$(backup_auth_list 2>&1)
    echo "$_output" | grep -qi "no auth backups"
    assert_ok $? "Should report no auth backups"
    _teardown_backup
  }

  it "lists existing auth backups" && {
    _setup_backup
    backup_init
    echo "key" > "$GEORGE_CONFIG_DIR/keys.conf"
    backup_auth_create >/dev/null 2>&1
    _output=$(backup_auth_list 2>&1)
    echo "$_output" | grep -q "auth-"
    assert_ok $? "Should list auth backup entries"
    _teardown_backup
  }

describe "backup_auth_restore"

  it "restores auth items to .george" && {
    _setup_backup
    backup_init
    mkdir -p "$GEORGE_CONFIG_DIR/.ssh"
    echo "ssh-key" > "$GEORGE_CONFIG_DIR/.ssh/id_rsa"
    echo "API_KEY=abc" > "$GEORGE_CONFIG_DIR/keys.conf"
    backup_auth_create >/dev/null 2>&1
    # Nuke the originals
    rm -rf "$GEORGE_CONFIG_DIR/.ssh"
    rm -f "$GEORGE_CONFIG_DIR/keys.conf"
    # Restore (auto-selects latest, auto-confirm via task mode)
    export _LODGE_IN_TASK=1
    backup_auth_restore 2>/dev/null
    export _LODGE_IN_TASK=0
    assert_file_exists "$GEORGE_CONFIG_DIR/keys.conf"
    assert_dir_exists "$GEORGE_CONFIG_DIR/.ssh"
    _teardown_backup
  }

  it "restores lodge.conf to LODGE_DIR" && {
    _setup_backup
    backup_init
    echo "key" > "$GEORGE_CONFIG_DIR/keys.conf"
    echo "MY_CONFIG=1" > "$LODGE_DIR/lodge.conf"
    backup_auth_create >/dev/null 2>&1
    rm -f "$LODGE_DIR/lodge.conf"
    export _LODGE_IN_TASK=1
    backup_auth_restore 2>/dev/null
    export _LODGE_IN_TASK=0
    assert_file_exists "$LODGE_DIR/lodge.conf"
    _content=$(cat "$LODGE_DIR/lodge.conf")
    assert_eq "$_content" "MY_CONFIG=1"
    rm -f "$LODGE_DIR/lodge.conf"
    _teardown_backup
  }

  it "fails when no auth backups exist" && {
    _setup_backup
    mkdir -p "$GEORGE_BACKUP_DIR"
    backup_auth_restore 2>/dev/null
    assert_fail $? "Should fail with no auth backups"
    _teardown_backup
  }

  it "sets correct permissions after restore" && {
    _setup_backup
    backup_init
    echo "secret" > "$GEORGE_CONFIG_DIR/keys.conf"
    mkdir -p "$GEORGE_CONFIG_DIR/.ssh"
    echo "key" > "$GEORGE_CONFIG_DIR/.ssh/id_rsa"
    backup_auth_create >/dev/null 2>&1
    rm -rf "$GEORGE_CONFIG_DIR/.ssh" "$GEORGE_CONFIG_DIR/keys.conf"
    export _LODGE_IN_TASK=1
    backup_auth_restore 2>/dev/null
    export _LODGE_IN_TASK=0
    perms=$(stat -c '%a' "$GEORGE_CONFIG_DIR/.ssh" 2>/dev/null)
    assert_eq "$perms" "700"
    perms=$(stat -c '%a' "$GEORGE_CONFIG_DIR/keys.conf" 2>/dev/null)
    assert_eq "$perms" "600"
    _teardown_backup
  }

# ═══════════════════════════════════════════════════════════════
# Code structure — auth backup definitions
# ═══════════════════════════════════════════════════════════════

describe "Auth backup — code structure"

  it "_BACKUP_AUTH_ITEMS includes .ssh" && {
    printf '%s\n' "${_BACKUP_AUTH_ITEMS[@]}" | grep -qx '.ssh'
    assert_ok $? ".ssh must be in auth items"
  }

  it "_BACKUP_AUTH_ITEMS includes .gnupg" && {
    printf '%s\n' "${_BACKUP_AUTH_ITEMS[@]}" | grep -qx '.gnupg'
    assert_ok $? ".gnupg must be in auth items"
  }

  it "_BACKUP_AUTH_ITEMS includes keys.conf" && {
    printf '%s\n' "${_BACKUP_AUTH_ITEMS[@]}" | grep -qx 'keys.conf'
    assert_ok $? "keys.conf must be in auth items"
  }

  it "_BACKUP_AUTH_ITEMS includes .vault" && {
    printf '%s\n' "${_BACKUP_AUTH_ITEMS[@]}" | grep -qx '.vault'
    assert_ok $? ".vault must be in auth items"
  }

  it "_BACKUP_AUTH_ITEMS includes social databases" && {
    printf '%s\n' "${_BACKUP_AUTH_ITEMS[@]}" | grep -q 'mastodon_instances'
    assert_ok $? "mastodon_instances.db must be in auth items"
    printf '%s\n' "${_BACKUP_AUTH_ITEMS[@]}" | grep -q 'discord_channels'
    assert_ok $? "discord_channels.db must be in auth items"
  }

  it "_BACKUP_AUTH_GLOBS matches email provider configs" && {
    printf '%s\n' "${_BACKUP_AUTH_GLOBS[@]}" | grep -q 'email_\*'
    assert_ok $? "Must have email_*.conf glob"
  }

  it "lodge dispatches /backup auth create" && {
    grep -q 'backup_auth_create' "$LODGE_DIR/lodge"
    assert_ok $? "lodge must wire backup_auth_create"
  }

  it "lodge dispatches /backup auth restore" && {
    grep -q 'backup_auth_restore' "$LODGE_DIR/lodge"
    assert_ok $? "lodge must wire backup_auth_restore"
  }

  it "lodge dispatches /backup auth list" && {
    grep -q 'backup_auth_list' "$LODGE_DIR/lodge"
    assert_ok $? "lodge must wire backup_auth_list"
  }

# ═══════════════════════════════════════════════════════════════
# Custom backup directory
# ═══════════════════════════════════════════════════════════════

describe "backup_auth_create — custom directory"

  it "creates auth backup in a custom directory" && {
    _setup_backup
    backup_init
    echo "API_KEY=test" > "$GEORGE_CONFIG_DIR/keys.conf"
    _custom_dir="$TMPDIR_BACKUP/custom-backups"
    mkdir -p "$_custom_dir"
    _result=$(backup_auth_create "$_custom_dir" 2>/dev/null | tail -1)
    assert_not_empty "$_result"
    assert_contains "$_result" "$_custom_dir"
    assert_file_exists "$_result/keys.conf"
    _teardown_backup
  }

  it "creates the custom directory if it does not exist" && {
    _setup_backup
    backup_init
    echo "API_KEY=test" > "$GEORGE_CONFIG_DIR/keys.conf"
    _custom_dir="$TMPDIR_BACKUP/new-dir/sub"
    _result=$(backup_auth_create "$_custom_dir" 2>/dev/null | tail -1)
    assert_dir_exists "$_custom_dir"
    assert_not_empty "$_result"
    _teardown_backup
  }

  it "defaults to GEORGE_BACKUP_DIR when no dir given" && {
    _setup_backup
    backup_init
    echo "API_KEY=test" > "$GEORGE_CONFIG_DIR/keys.conf"
    _result=$(backup_auth_create 2>/dev/null | tail -1)
    assert_contains "$_result" "$GEORGE_BACKUP_DIR"
    _teardown_backup
  }

describe "backup_auth_list — custom directory"

  it "lists backups from a custom directory" && {
    _setup_backup
    backup_init
    echo "API_KEY=test" > "$GEORGE_CONFIG_DIR/keys.conf"
    _custom_dir="$TMPDIR_BACKUP/list-custom"
    backup_auth_create "$_custom_dir" >/dev/null 2>&1
    _output=$(backup_auth_list "$_custom_dir" 2>&1)
    assert_contains "$_output" "auth-"
    assert_contains "$_output" "$_custom_dir"
    _teardown_backup
  }

  it "reports no backups in empty custom directory" && {
    _setup_backup
    _empty_dir="$TMPDIR_BACKUP/empty-custom"
    mkdir -p "$_empty_dir"
    _output=$(backup_auth_list "$_empty_dir" 2>&1)
    assert_contains "$_output" "No auth backups"
    _teardown_backup
  }

describe "backup_auth_restore — custom directory"

  it "restores from a custom directory" && {
    _setup_backup
    backup_init
    echo "API_KEY=custom_restore_test" > "$GEORGE_CONFIG_DIR/keys.conf"
    mkdir -p "$GEORGE_CONFIG_DIR/.ssh"
    echo "ssh-rsa TEST" > "$GEORGE_CONFIG_DIR/.ssh/id_rsa.pub"
    _custom_dir="$TMPDIR_BACKUP/restore-custom"
    backup_auth_create "$_custom_dir" >/dev/null 2>&1
    # Nuke originals
    rm -f "$GEORGE_CONFIG_DIR/keys.conf"
    rm -rf "$GEORGE_CONFIG_DIR/.ssh"
    # Restore from custom dir (auto-selects latest)
    export _LODGE_IN_TASK=1
    backup_auth_restore "" "$_custom_dir" 2>/dev/null
    export _LODGE_IN_TASK=0
    assert_file_exists "$GEORGE_CONFIG_DIR/keys.conf"
    _content=$(cat "$GEORGE_CONFIG_DIR/keys.conf")
    assert_eq "$_content" "API_KEY=custom_restore_test"
    _teardown_backup
  }

  it "restores by name from custom directory" && {
    _setup_backup
    backup_init
    echo "key=val" > "$GEORGE_CONFIG_DIR/keys.conf"
    _custom_dir="$TMPDIR_BACKUP/named-restore"
    _result=$(backup_auth_create "$_custom_dir" 2>/dev/null | tail -1)
    _bname=$(basename "$_result")
    rm -f "$GEORGE_CONFIG_DIR/keys.conf"
    export _LODGE_IN_TASK=1
    backup_auth_restore "$_bname" "$_custom_dir" 2>/dev/null
    export _LODGE_IN_TASK=0
    assert_file_exists "$GEORGE_CONFIG_DIR/keys.conf"
    _teardown_backup
  }

  it "auto-detects directory path as source_dir" && {
    _setup_backup
    backup_init
    echo "key=detect" > "$GEORGE_CONFIG_DIR/keys.conf"
    _custom_dir="$TMPDIR_BACKUP/detect-dir"
    backup_auth_create "$_custom_dir" >/dev/null 2>&1
    rm -f "$GEORGE_CONFIG_DIR/keys.conf"
    export _LODGE_IN_TASK=1
    backup_auth_restore "$_custom_dir" 2>/dev/null
    export _LODGE_IN_TASK=0
    assert_file_exists "$GEORGE_CONFIG_DIR/keys.conf"
    _teardown_backup
  }

test_end
