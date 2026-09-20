#!/bin/bash
# ── Tests: lib/secrets.sh ─────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/security.sh"
source "$LODGE_DIR/lib/secrets.sh"

test_start "lib/secrets.sh — Encrypted Secrets Vault"

_ORIG_VAULT_DIR=""
_ORIG_CONFIG_DIR=""
_ORIG_KEYRING_DIR=""

_setup_vault() {
    _TMPDIR_VAULT=$(test_tmpdir)
    _ORIG_CONFIG_DIR="$GEORGE_CONFIG_DIR"
    _ORIG_KEYRING_DIR="${GEORGE_KEYRING_DIR:-$GEORGE_CONFIG_DIR/.keyring}"
    _ORIG_VAULT_DIR="$VAULT_DIR"
    GEORGE_CONFIG_DIR="$_TMPDIR_VAULT/.george"
    GEORGE_KEYRING_DIR="$GEORGE_CONFIG_DIR/.keyring"
    VAULT_DIR="$GEORGE_CONFIG_DIR/.vault"
    mkdir -p "$GEORGE_CONFIG_DIR" "$GEORGE_KEYRING_DIR"
    # Create a signing key for the vault
    openssl rand -hex 32 > "$GEORGE_KEYRING_DIR/signing.key" 2>/dev/null
    chmod 600 "$GEORGE_KEYRING_DIR/signing.key"
}

_teardown_vault() {
    GEORGE_CONFIG_DIR="$_ORIG_CONFIG_DIR"
    GEORGE_KEYRING_DIR="$_ORIG_KEYRING_DIR"
    VAULT_DIR="$_ORIG_VAULT_DIR"
    rm -rf "$_TMPDIR_VAULT"
}

# ── Initialization ─────────────────────────────────────────────
describe "secrets_init"

  it "creates vault directory" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    assert_dir_exists "$VAULT_DIR"
    _teardown_vault
  }

  it "sets correct permissions (700)" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    _perms=$(stat -c '%a' "$VAULT_DIR" 2>/dev/null || stat -f '%A' "$VAULT_DIR" 2>/dev/null)
    assert_eq "$_perms" "700"
    _teardown_vault
  }

# ── Validation ─────────────────────────────────────────────────
describe "_vault_validate_name"

  it "accepts valid names" && {
    _vault_validate_name "my_api_key" 2>/dev/null
    assert_ok $?
  }

  it "accepts names with hyphens and dots" && {
    _vault_validate_name "google-oauth2.token" 2>/dev/null
    assert_ok $?
  }

  it "rejects names with path separators" && {
    _vault_validate_name "../etc/passwd" 2>/dev/null
    assert_fail $?
  }

  it "rejects empty names" && {
    _vault_validate_name "" 2>/dev/null
    assert_fail $?
  }

  it "rejects names with spaces" && {
    _vault_validate_name "my key" 2>/dev/null
    assert_fail $?
  }

# ── Set & Get ──────────────────────────────────────────────────
describe "secrets_set / secrets_get"

  it "stores and retrieves a simple value" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "test_key" "hello_world" >/dev/null 2>&1
    _result=$(secrets_get "test_key" 2>/dev/null)
    assert_eq "$_result" "hello_world"
    _teardown_vault
  }

  it "stores and retrieves a value with special characters" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "special" 'p@$$w0rd!#%^&*()' >/dev/null 2>&1
    _result=$(secrets_get "special" 2>/dev/null)
    assert_eq "$_result" 'p@$$w0rd!#%^&*()'
    _teardown_vault
  }

  it "creates an encrypted file on disk" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "disk_key" "secret_value" >/dev/null 2>&1
    assert_file_exists "$VAULT_DIR/disk_key.enc"
    _teardown_vault
  }

  it "encrypted file doesn't contain plaintext" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "plain_test" "my_super_secret_password" >/dev/null 2>&1
    _contents=$(cat "$VAULT_DIR/plain_test.enc" 2>/dev/null)
    assert_not_contains "$_contents" "my_super_secret_password"
    _teardown_vault
  }

  it "overwrites an existing secret" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "overwrite" "value1" >/dev/null 2>&1
    secrets_set "overwrite" "value2" >/dev/null 2>&1
    _result=$(secrets_get "overwrite" 2>/dev/null)
    assert_eq "$_result" "value2"
    _teardown_vault
  }

  it "returns error for non-existent secret" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_get "nonexistent" 2>/dev/null
    assert_fail $?
    _teardown_vault
  }

# ── Exists ─────────────────────────────────────────────────────
describe "secrets_exists"

  it "returns true for existing secret" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "exists_test" "val" >/dev/null 2>&1
    secrets_exists "exists_test"
    assert_ok $?
    _teardown_vault
  }

  it "returns false for missing secret" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_exists "missing_secret"
    assert_fail $?
    _teardown_vault
  }

# ── Delete ─────────────────────────────────────────────────────
describe "secrets_delete"

  it "removes a secret" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "to_delete" "goodbye" >/dev/null 2>&1
    secrets_delete "to_delete" >/dev/null 2>&1
    secrets_exists "to_delete"
    assert_fail $?
    _teardown_vault
  }

  it "removes the encrypted file from disk" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "disk_del" "val" >/dev/null 2>&1
    secrets_delete "disk_del" >/dev/null 2>&1
    assert_file_not_exists "$VAULT_DIR/disk_del.enc"
    _teardown_vault
  }

# ── List ───────────────────────────────────────────────────────
describe "secrets_list"

  it "lists stored secret names" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "alpha" "a" >/dev/null 2>&1
    secrets_set "beta" "b" >/dev/null 2>&1
    secrets_set "gamma" "c" >/dev/null 2>&1
    _list=$(secrets_list 2>/dev/null)
    assert_contains "$_list" "alpha"
    assert_contains "$_list" "beta"
    assert_contains "$_list" "gamma"
    _teardown_vault
  }

  it "returns empty for fresh vault" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    _list=$(secrets_list 2>/dev/null)
    assert_empty "$_list"
    _teardown_vault
  }

# ── Import File ────────────────────────────────────────────────
describe "secrets_import_file"

  it "imports a file as a secret" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    _tmpfile=$(mktemp)
    echo "file_contents_here" > "$_tmpfile"
    secrets_import_file "imported_file" "$_tmpfile" >/dev/null 2>&1
    _result=$(secrets_get "imported_file" 2>/dev/null)
    assert_eq "$_result" "file_contents_here"
    rm -f "$_tmpfile"
    _teardown_vault
  }

  it "auto-names from filename if no label given" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    _tmpfile="$_TMPDIR_VAULT/my_key.pem"
    echo "KEY_DATA" > "$_tmpfile"
    secrets_import_file "my_key.pem" "$_tmpfile" >/dev/null 2>&1
    _result=$(secrets_get "my_key.pem" 2>/dev/null)
    assert_eq "$_result" "KEY_DATA"
    _teardown_vault
  }

# ── Export Env ─────────────────────────────────────────────────
describe "secrets_export_env"

  it "outputs export statement" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "api_token" "tok_123" >/dev/null 2>&1
    _output=$(secrets_export_env "api_token" "API_TOKEN" 2>/dev/null)
    assert_contains "$_output" "export API_TOKEN="
    assert_contains "$_output" "tok_123"
    _teardown_vault
  }

# ── Secrets With (subshell) ───────────────────────────────────
describe "secrets_with"

  it "makes secret available as env var in subshell" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "sub_secret" "hidden_value" >/dev/null 2>&1
    _result=$(secrets_with "sub_secret" "MY_VAR" 'echo $MY_VAR' 2>/dev/null)
    assert_contains "$_result" "hidden_value"
    _teardown_vault
  }

  it "env var is not available after subshell" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "temp_secret" "temp_val" >/dev/null 2>&1
    secrets_with "temp_secret" "TEMP_VAR" "true" >/dev/null 2>&1
    assert_empty "${TEMP_VAR:-}"
    _teardown_vault
  }

# ── Rotate Key ────────────────────────────────────────────────
describe "secrets_rotate_key"

  it "re-encrypts secrets with new key" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "rotate_test" "keep_this_value" >/dev/null 2>&1
    _old_key=$(cat "$GEORGE_KEYRING_DIR/signing.key")
    secrets_rotate_key >/dev/null 2>&1
    _new_key=$(cat "$GEORGE_KEYRING_DIR/signing.key")
    assert_neq "$_old_key" "$_new_key"
    _result=$(secrets_get "rotate_test" 2>/dev/null)
    assert_eq "$_result" "keep_this_value"
    _teardown_vault
  }

# ── Status ─────────────────────────────────────────────────────
describe "secrets_status"

  it "shows vault status without error" && {
    _setup_vault
    secrets_init >/dev/null 2>&1
    secrets_set "stat1" "v1" >/dev/null 2>&1
    secrets_set "stat2" "v2" >/dev/null 2>&1
    secrets_status >/dev/null 2>&1
    assert_ok $?
    _teardown_vault
  }

test_end
