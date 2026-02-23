#!/bin/bash
# ── Tests: lib/pgp.sh ─────────────────────────────────────────
# PGP signing system: key generation, signing, verification,
# export, import, and file signing.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"

TMPDIR_PGP=""
_test_signed=""
_test_fpr=""
_test_output=""
_test_content=""
_test_perms=""

_setup_pgp() {
    TMPDIR_PGP=$(test_tmpdir)
    export GEORGE_CONFIG_DIR="$TMPDIR_PGP/.george"
    export GEORGE_GNUPG_DIR="$GEORGE_CONFIG_DIR/.gnupg"
    export GEORGE_PGP_PUBKEY_FILE="$GEORGE_CONFIG_DIR/george_public.asc"
    export PGP_KEY_NAME="Test George"
    export PGP_KEY_EMAIL="test@blue-lodge.local"
    export PGP_KEY_COMMENT="Test Agent"
    source "$LODGE_DIR/lib/pgp.sh"
}

_teardown_pgp() {
    rm -rf "$TMPDIR_PGP"
}

_setup_with_key() {
    _setup_pgp
    pgp_generate_key >/dev/null 2>&1
}

test_start "lib/pgp.sh — PGP Message Signing"

# ── Availability ───────────────────────────────────────────────
describe "pgp_available"

  it "detects gpg on system" && {
    _setup_pgp
    if command -v gpg &>/dev/null; then
        pgp_available
        assert_ok $?
    else
        skip "gpg not installed"
    fi
    _teardown_pgp
  }

# ── Initialization ─────────────────────────────────────────────
describe "pgp_init"

  it "creates gnupg directory" && {
    _setup_pgp
    pgp_init 2>/dev/null
    assert_dir_exists "$GEORGE_GNUPG_DIR"
    _teardown_pgp
  }

  it "sets gnupg dir to mode 700" && {
    _setup_pgp
    pgp_init 2>/dev/null
    _test_perms=$(stat -c '%a' "$GEORGE_GNUPG_DIR" 2>/dev/null)
    assert_eq "$_test_perms" "700"
    _teardown_pgp
  }

# ── Function existence ─────────────────────────────────────────
describe "Core functions"

  it "pgp_generate_key is defined" && {
    _setup_pgp
    declare -f pgp_generate_key &>/dev/null
    assert_ok $?
    _teardown_pgp
  }

  it "pgp_sign_message is defined" && {
    declare -f pgp_sign_message &>/dev/null
    assert_ok $?
  }

  it "pgp_verify_message is defined" && {
    declare -f pgp_verify_message &>/dev/null
    assert_ok $?
  }

  it "pgp_export_public_key is defined" && {
    declare -f pgp_export_public_key &>/dev/null
    assert_ok $?
  }

  it "pgp_fingerprint is defined" && {
    declare -f pgp_fingerprint &>/dev/null
    assert_ok $?
  }

  it "pgp_import_key is defined" && {
    declare -f pgp_import_key &>/dev/null
    assert_ok $?
  }

  it "pgp_sign_file is defined" && {
    declare -f pgp_sign_file &>/dev/null
    assert_ok $?
  }

  it "pgp_verify_file is defined" && {
    declare -f pgp_verify_file &>/dev/null
    assert_ok $?
  }

  it "pgp_sign_and_post is defined" && {
    declare -f pgp_sign_and_post &>/dev/null
    assert_ok $?
  }

  it "pgp_status is defined" && {
    declare -f pgp_status &>/dev/null
    assert_ok $?
  }

  it "pgp_list_keys is defined" && {
    declare -f pgp_list_keys &>/dev/null
    assert_ok $?
  }

  it "pgp_detached_sign is defined" && {
    declare -f pgp_detached_sign &>/dev/null
    assert_ok $?
  }

# ── Key generation & signing (integration) ────────────────────
describe "Key generation"

  it "generates a key pair" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        pgp_has_key
        assert_ok $?
        _teardown_pgp
    fi
  }

  it "exports public key after generation" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        assert_file_exists "$GEORGE_PGP_PUBKEY_FILE"
        _teardown_pgp
    fi
  }

  it "refuses to generate duplicate key" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        _test_output=$(pgp_generate_key 2>&1)
        assert_contains "$_test_output" "already"
        _teardown_pgp
    fi
  }

describe "Message signing"

  it "cleartext signs a message" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        _test_signed=$(pgp_sign_message "Hello from George" 2>/dev/null)
        assert_contains "$_test_signed" "BEGIN PGP SIGNED MESSAGE"
        _teardown_pgp
    fi
  }

  it "signed message contains original text" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        _test_signed=$(pgp_sign_message "Hello from George" 2>/dev/null)
        assert_contains "$_test_signed" "Hello from George"
        _teardown_pgp
    fi
  }

  it "signed message contains signature block" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        _test_signed=$(pgp_sign_message "Hello from George" 2>/dev/null)
        assert_contains "$_test_signed" "BEGIN PGP SIGNATURE"
        _teardown_pgp
    fi
  }

  it "fails to sign without a key" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_pgp
        pgp_sign_message "test" >/dev/null 2>&1
        assert_fail $?
        _teardown_pgp
    fi
  }

describe "Message verification"

  it "verifies a valid signed message" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        _test_signed=$(pgp_sign_message "Verified test" 2>/dev/null)
        pgp_verify_message "$_test_signed" >/dev/null 2>&1
        assert_ok $?
        _teardown_pgp
    fi
  }

  it "rejects a tampered message" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        _test_signed=$(pgp_sign_message "Original text" 2>/dev/null)
        _test_signed=$(echo "$_test_signed" | sed 's/Original text/TAMPERED text/')
        pgp_verify_message "$_test_signed" >/dev/null 2>&1
        assert_fail $?
        _teardown_pgp
    fi
  }

describe "Fingerprint"

  it "returns a fingerprint after key gen" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        _test_fpr=$(pgp_fingerprint 2>/dev/null)
        assert_not_empty "$_test_fpr"
        _teardown_pgp
    fi
  }

describe "Public key export"

  it "public key contains ASCII armor markers" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        pgp_export_public_key >/dev/null 2>&1
        _test_content=$(cat "$GEORGE_PGP_PUBKEY_FILE")
        assert_contains "$_test_content" "BEGIN PGP PUBLIC KEY BLOCK"
        _teardown_pgp
    fi
  }

describe "File signing"

  it "creates a detached signature for a file" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        echo "File content to sign" > "$TMPDIR_PGP/testfile.txt"
        pgp_sign_file "$TMPDIR_PGP/testfile.txt" >/dev/null 2>&1
        assert_file_exists "$TMPDIR_PGP/testfile.txt.sig"
        _teardown_pgp
    fi
  }

  it "verifies a valid file signature" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        echo "File content to sign" > "$TMPDIR_PGP/testfile.txt"
        pgp_sign_file "$TMPDIR_PGP/testfile.txt" >/dev/null 2>&1
        pgp_verify_file "$TMPDIR_PGP/testfile.txt" >/dev/null 2>&1
        assert_ok $?
        _teardown_pgp
    fi
  }

  it "rejects a tampered file" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        echo "Original content" > "$TMPDIR_PGP/testfile.txt"
        pgp_sign_file "$TMPDIR_PGP/testfile.txt" >/dev/null 2>&1
        echo "TAMPERED content" > "$TMPDIR_PGP/testfile.txt"
        pgp_verify_file "$TMPDIR_PGP/testfile.txt" >/dev/null 2>&1
        assert_fail $?
        _teardown_pgp
    fi
  }

describe "Key import"

  it "imports a public key from file" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        pgp_export_public_key >/dev/null 2>&1
        cp "$GEORGE_PGP_PUBKEY_FILE" "$TMPDIR_PGP/copy.asc"
        pgp_import_key "$TMPDIR_PGP/copy.asc" >/dev/null 2>&1
        assert_ok $?
        _teardown_pgp
    fi
  }

  it "fails to import nonexistent file" && {
    _setup_pgp
    pgp_import_key "/nonexistent/key.asc" >/dev/null 2>&1
    assert_fail $?
    _teardown_pgp
  }

describe "Status"

  it "shows status without a key" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_pgp
        pgp_init 2>/dev/null
        _test_output=$(pgp_status 2>/dev/null)
        assert_contains "$_test_output" "PGP Signing Status"
        _teardown_pgp
    fi
  }

  it "shows status with a key" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        _test_output=$(pgp_status 2>/dev/null)
        assert_contains "$_test_output" "PGP Signing Status"
        _teardown_pgp
    fi
  }

describe "Revoke and regenerate"

  it "revokes and creates a new key" && {
    if ! command -v gpg &>/dev/null; then
        skip "gpg not installed"
    else
        _setup_with_key
        _test_fpr=$(pgp_fingerprint 2>/dev/null | tail -1)
        pgp_revoke_and_regenerate >/dev/null 2>&1
        pgp_has_key
        assert_ok $?
        _teardown_pgp
    fi
  }

test_end
