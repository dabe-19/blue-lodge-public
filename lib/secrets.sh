#!/bin/bash
# ── George: Secrets Vault ──────────────────────────────────────
# Encrypted key-value store for sensitive credentials.
# Secrets are stored encrypted with AES-256-CBC (PBKDF2).
# Plaintext never touches disk — decrypted to memory only when needed.
#
# Pattern follows Kubernetes/Docker secrets:
#   - Set a secret: plaintext is encrypted and stored, original destroyed
#   - Get a secret: decrypted to stdout (for piping to env vars)
#   - List secrets: shows names only, never values
#   - Delete a secret: securely removed
#
# Storage: $LODGE_DIR/.george/.vault/<name>.enc  (each secret is a separate file)
# Key derivation: Uses the signing key from security.sh keyring

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}"
VAULT_DIR="${VAULT_DIR:-$GEORGE_CONFIG_DIR/.vault}"

# ── Initialize vault ──────────────────────────────────────────
secrets_init() {
    if [ ! -d "$VAULT_DIR" ]; then
        mkdir -p "$VAULT_DIR"
        chmod 700 "$VAULT_DIR"
    fi

    # Ensure we have a keyring (from security.sh or standalone)
    if ! _vault_get_key &>/dev/null; then
        _vault_init_key
    fi

    return 0
}

# ── Internal: get encryption key ──────────────────────────────
# Reuses the security.sh keyring if available, otherwise creates its own
_vault_get_key() {
    local keyring_dir="$GEORGE_CONFIG_DIR/.keyring"
    local key_file="$keyring_dir/signing.key"

    if [ -f "$key_file" ]; then
        cat "$key_file"
        return 0
    fi

    return 1
}

_vault_init_key() {
    local keyring_dir="$GEORGE_CONFIG_DIR/.keyring"
    local key_file="$keyring_dir/signing.key"

    mkdir -p "$keyring_dir"
    chmod 700 "$keyring_dir"

    if [ ! -f "$key_file" ]; then
        if command -v openssl &>/dev/null; then
            openssl rand -hex 32 > "$key_file"
        else
            head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$key_file"
        fi
        chmod 600 "$key_file"
    fi
}

# ── Validate secret name ──────────────────────────────────────
_vault_validate_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]]; then
        return 1
    fi
    return 0
}

# ── Set (store) a secret ──────────────────────────────────────
# Usage: secrets_set "name" "value"
# The value is encrypted and stored. The plaintext is not saved anywhere.
secrets_set() {
    local name="$1"
    local value="$2"

    if [ -z "$name" ]; then
        ui_err "Usage: secrets_set <name> <value>"
        return 1
    fi

    if ! _vault_validate_name "$name"; then
        ui_err "Invalid secret name: '$name' (use alphanumeric, underscore, dot, dash)"
        return 1
    fi

    if [ -z "$value" ]; then
        ui_err "Secret value cannot be empty"
        return 1
    fi

    secrets_init

    local key
    key=$(_vault_get_key) || { ui_err "Keyring not available"; return 1; }

    local enc_file="$VAULT_DIR/${name}.enc"

    # Encrypt the value
    if command -v openssl &>/dev/null; then
        echo -n "$value" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
            -pass "pass:${key}" -out "$enc_file" 2>/dev/null
    else
        ui_err "openssl required for vault encryption"
        return 1
    fi

    if [ $? -eq 0 ] && [ -f "$enc_file" ]; then
        chmod 600 "$enc_file"
        return 0
    else
        ui_err "Failed to encrypt secret '$name'"
        rm -f "$enc_file"
        return 1
    fi
}

# ── Get (retrieve) a secret ───────────────────────────────────
# Decrypts to stdout. Never logs or displays — pipe to where needed.
# Usage: secrets_get "name"
secrets_get() {
    local name="$1"

    if [ -z "$name" ]; then
        return 1
    fi

    local enc_file="$VAULT_DIR/${name}.enc"

    if [ ! -f "$enc_file" ]; then
        return 1
    fi

    local key
    key=$(_vault_get_key) || return 1

    if command -v openssl &>/dev/null; then
        openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
            -pass "pass:${key}" -in "$enc_file" 2>/dev/null
    else
        return 1
    fi
}

# ── Check if a secret exists ─────────────────────────────────
secrets_exists() {
    local name="$1"
    [ -f "$VAULT_DIR/${name}.enc" ]
}

# ── Delete a secret ───────────────────────────────────────────
secrets_delete() {
    local name="$1"

    if [ -z "$name" ]; then
        ui_err "Usage: secrets_delete <name>"
        return 1
    fi

    local enc_file="$VAULT_DIR/${name}.enc"

    if [ ! -f "$enc_file" ]; then
        ui_err "Secret '$name' not found"
        return 1
    fi

    # Overwrite with random data before removing (secure delete)
    if command -v shred &>/dev/null; then
        shred -u "$enc_file" 2>/dev/null
    else
        dd if=/dev/urandom of="$enc_file" bs=$(stat -c %s "$enc_file" 2>/dev/null || echo 256) count=1 2>/dev/null
        rm -f "$enc_file"
    fi

    return 0
}

# ── List secret names ─────────────────────────────────────────
# Shows only names, never values
secrets_list() {
    if [ ! -d "$VAULT_DIR" ]; then
        return 0
    fi

    local found=0
    for f in "$VAULT_DIR"/*.enc; do
        [ -f "$f" ] || continue
        local name
        name=$(basename "$f" .enc)
        echo "$name"
        found=1
    done

    if [ "$found" -eq 0 ]; then
        return 1  # no secrets
    fi
    return 0
}

# ── List secrets with metadata ────────────────────────────────
secrets_list_pretty() {
    if [ ! -d "$VAULT_DIR" ]; then
        ui_dim "  No secrets stored yet."
        return 0
    fi

    local found=0
    for f in "$VAULT_DIR"/*.enc; do
        [ -f "$f" ] || continue
        local name
        name=$(basename "$f" .enc)
        local size
        size=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo "?")
        local mtime
        mtime=$(stat -c %y "$f" 2>/dev/null | cut -d. -f1 || stat -f "%Sm" "$f" 2>/dev/null || echo "?")
        printf "  %b●%b %-30s %b%s bytes%b  %b%s%b\n" \
            "$C_GREEN" "$C_RESET" "$name" \
            "$C_DIM" "$size" "$C_RESET" \
            "$C_DIM" "$mtime" "$C_RESET"
        found=1
    done

    if [ "$found" -eq 0 ]; then
        ui_dim "  No secrets stored yet."
    fi
}

# ── Import a secret from a file ───────────────────────────────
# Reads the file content, encrypts it, optionally deletes the original
secrets_import_file() {
    local name="$1"
    local filepath="$2"
    local delete_original="${3:-0}"  # 1 = delete original after import

    if [ -z "$name" ] || [ -z "$filepath" ]; then
        ui_err "Usage: secrets_import_file <name> <filepath> [delete_original]"
        return 1
    fi

    if [ ! -f "$filepath" ]; then
        ui_err "File not found: $filepath"
        return 1
    fi

    local value
    value=$(cat "$filepath")

    secrets_set "$name" "$value"
    local rc=$?

    if [ $rc -eq 0 ] && [ "$delete_original" -eq 1 ]; then
        if command -v shred &>/dev/null; then
            shred -u "$filepath" 2>/dev/null
        else
            dd if=/dev/urandom of="$filepath" bs=$(stat -c %s "$filepath" 2>/dev/null || echo 256) count=1 2>/dev/null
            rm -f "$filepath"
        fi
    fi

    return $rc
}

# ── Export a secret to environment variable ───────────────────
# Usage: eval "$(secrets_export_env SECRET_NAME ENV_VAR_NAME)"
# This outputs: export ENV_VAR_NAME='decrypted_value'
secrets_export_env() {
    local name="$1"
    local env_var="${2:-$name}"

    local value
    value=$(secrets_get "$name") || return 1

    # Escape single quotes in the value
    value="${value//\'/\'\\\'\'}"

    echo "export ${env_var}='${value}'"
}

# ── Use a secret for a one-shot command ───────────────────────
# Decrypts the secret, sets it as an env var, runs the command,
# then the variable goes out of scope (subshell).
# Usage: secrets_with "api_key" "API_KEY" "curl -H 'Auth: $API_KEY' ..."
secrets_with() {
    local name="$1"
    local env_var="$2"
    local cmd="$3"

    if [ -z "$name" ] || [ -z "$env_var" ] || [ -z "$cmd" ]; then
        ui_err "Usage: secrets_with <secret_name> <env_var> <command>"
        return 1
    fi

    local value
    value=$(secrets_get "$name") || {
        ui_err "Secret '$name' not found"
        return 1
    }

    # Run in subshell so the variable doesn't persist
    (
        export "$env_var"="$value"
        eval "$cmd"
    )
}

# ── Rotate vault key ─────────────────────────────────────────
# Re-encrypts all secrets with a new key
secrets_rotate_key() {
    local old_key
    old_key=$(_vault_get_key) || { ui_err "No current key"; return 1; }

    # Decrypt all secrets with old key
    local -A decrypted
    for f in "$VAULT_DIR"/*.enc; do
        [ -f "$f" ] || continue
        local name
        name=$(basename "$f" .enc)
        local value
        value=$(secrets_get "$name") || {
            ui_err "Failed to decrypt '$name' during rotation"
            return 1
        }
        decrypted["$name"]="$value"
    done

    # Generate new key
    local keyring_dir="$GEORGE_CONFIG_DIR/.keyring"
    local key_file="$keyring_dir/signing.key"

    if command -v openssl &>/dev/null; then
        openssl rand -hex 32 > "${key_file}.new"
    else
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${key_file}.new"
    fi

    mv "${key_file}.new" "$key_file"
    chmod 600 "$key_file"

    # Re-encrypt all secrets with new key
    local failed=0
    for name in "${!decrypted[@]}"; do
        secrets_set "$name" "${decrypted[$name]}" || {
            ui_err "Failed to re-encrypt '$name'"
            (( failed++ ))
        }
    done

    if [ "$failed" -gt 0 ]; then
        ui_err "$failed secret(s) failed to rotate"
        return 1
    fi

    return 0
}

# ── Vault status ──────────────────────────────────────────────
secrets_status() {
    ui_section "Secrets Vault"

    if [ ! -d "$VAULT_DIR" ]; then
        printf "  %bStatus:%b    Not initialized\n" "$C_CYAN" "$C_RESET"
        return
    fi

    local count=0
    for f in "$VAULT_DIR"/*.enc; do
        [ -f "$f" ] || continue
        (( count++ ))
    done

    printf "  %bStatus:%b    Active\n" "$C_CYAN" "$C_RESET"
    printf "  %bSecrets:%b   %d stored\n" "$C_CYAN" "$C_RESET" "$count"
    printf "  %bVault:%b     %s\n" "$C_CYAN" "$C_RESET" "$VAULT_DIR"
    printf "  %bEncryption:%b AES-256-CBC (PBKDF2, 100k iterations)\n" "$C_CYAN" "$C_RESET"

    local vault_size
    vault_size=$(du -sh "$VAULT_DIR" 2>/dev/null | cut -f1)
    printf "  %bSize:%b      %s\n" "$C_CYAN" "$C_RESET" "$vault_size"
}
