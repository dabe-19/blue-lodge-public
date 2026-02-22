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

test_end
