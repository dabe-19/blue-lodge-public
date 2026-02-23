#!/bin/bash
# ── George: PGP Message Signing ────────────────────────────────
# Signs George's messages with a GPG key so recipients can verify
# authenticity. The public key is exportable for distribution.
#
# Architecture:
#   - Uses GnuPG (gpg) for all crypto operations
#   - Dedicated GNUPGHOME at $LODGE_DIR/.george/.gnupg (isolated keyring)
#   - Cleartext signatures (human-readable + verifiable)
#   - ASCII-armored public key export
#
# Why PGP?
#   George is a personality — when he signs a message, anyone with
#   his public key can verify the message came from *this* George.
#   Different George instances have different keys. The public key
#   acts as a cryptographic identity anchor.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}"
GEORGE_GNUPG_DIR="${GEORGE_GNUPG_DIR:-$GEORGE_CONFIG_DIR/.gnupg}"
GEORGE_PGP_PUBKEY_FILE="${GEORGE_PGP_PUBKEY_FILE:-$GEORGE_CONFIG_DIR/george_public.asc}"

# Default identity for the key
PGP_KEY_NAME="${PGP_KEY_NAME:-George (Blue Lodge Agent)}"
PGP_KEY_EMAIL="${PGP_KEY_EMAIL:-george@blue-lodge.local}"
PGP_KEY_COMMENT="${PGP_KEY_COMMENT:-Mobile-First Coding Agent}"

# ── GPG wrapper (isolated keyring) ─────────────────────────────
_pgp_gpg() {
    gpg --homedir "$GEORGE_GNUPG_DIR" \
        --batch --yes \
        --no-tty \
        --quiet \
        "$@" 2>/dev/null
}

# ── Check if GPG is available ──────────────────────────────────
pgp_available() {
    if ! command -v gpg &>/dev/null; then
        return 1
    fi
    return 0
}

# ── Initialize the PGP keyring ─────────────────────────────────
pgp_init() {
    if ! pgp_available; then
        ui_warn "gpg not found — PGP signing unavailable"
        ui_dim "Install: apt install gnupg  (or: pkg install gnupg)"
        return 1
    fi

    if [ -d "$GEORGE_GNUPG_DIR" ]; then
        return 0  # already initialized
    fi

    mkdir -p "$GEORGE_GNUPG_DIR"
    chmod 700 "$GEORGE_GNUPG_DIR"

    ui_dim "Initialized PGP keyring at $GEORGE_GNUPG_DIR"
    return 0
}

# ── Check if George has a signing key ──────────────────────────
pgp_has_key() {
    pgp_init || return 1
    _pgp_gpg --list-secret-keys "$PGP_KEY_EMAIL" &>/dev/null
}

# ── Generate a new signing key ─────────────────────────────────
# Creates an Ed25519 key (modern, fast, small signatures).
# No passphrase — George is an automated agent.
pgp_generate_key() {
    pgp_init || return 1

    if pgp_has_key; then
        ui_warn "George already has a PGP key"
        ui_dim "Use /pgp fingerprint to see it, or /pgp revoke to replace"
        return 1
    fi

    ui_step "Generating Ed25519 signing key..."

    # Generate key using unattended batch mode
    _pgp_gpg --gen-key <<EOF
%no-protection
Key-Type: eddsa
Key-Curve: Ed25519
Key-Usage: sign
Subkey-Type: eddsa
Subkey-Curve: Ed25519
Subkey-Usage: sign
Name-Real: $PGP_KEY_NAME
Name-Comment: $PGP_KEY_COMMENT
Name-Email: $PGP_KEY_EMAIL
Expire-Date: 0
%commit
EOF

    if [ $? -eq 0 ] && pgp_has_key; then
        ui_ok "PGP key generated"
        pgp_fingerprint
        # Auto-export public key
        pgp_export_public_key >/dev/null 2>&1
        ui_ok "Public key exported to $GEORGE_PGP_PUBKEY_FILE"
        return 0
    else
        ui_err "Key generation failed"
        return 1
    fi
}

# ── Get the fingerprint ───────────────────────────────────────
pgp_fingerprint() {
    pgp_init || return 1

    if ! pgp_has_key; then
        ui_warn "No PGP key found. Generate one with /pgp generate"
        return 1
    fi

    local fpr
    fpr=$(_pgp_gpg --fingerprint --with-colons "$PGP_KEY_EMAIL" | \
          grep '^fpr:' | head -1 | cut -d: -f10)

    if [ -n "$fpr" ]; then
        # Format as 4-char groups for readability
        local formatted
        formatted=$(echo "$fpr" | sed 's/.\{4\}/& /g' | sed 's/ $//')
        printf "  %bFingerprint:%b %s\n" "$C_WHITE" "$C_RESET" "$formatted"
        printf "  %bIdentity:%b   %s <%s>\n" "$C_WHITE" "$C_RESET" "$PGP_KEY_NAME" "$PGP_KEY_EMAIL"
        echo "$fpr"
    else
        ui_err "Could not read fingerprint"
        return 1
    fi
}

# ── Export public key (ASCII-armored) ──────────────────────────
pgp_export_public_key() {
    pgp_init || return 1

    if ! pgp_has_key; then
        ui_warn "No PGP key found. Generate one with /pgp generate"
        return 1
    fi

    _pgp_gpg --armor --export "$PGP_KEY_EMAIL" > "$GEORGE_PGP_PUBKEY_FILE"

    if [ -s "$GEORGE_PGP_PUBKEY_FILE" ]; then
        ui_ok "Public key exported to $GEORGE_PGP_PUBKEY_FILE"
        ui_dim "Share this file or its contents so others can verify George's messages"
        return 0
    else
        ui_err "Public key export failed"
        rm -f "$GEORGE_PGP_PUBKEY_FILE"
        return 1
    fi
}

# ── Show the public key ───────────────────────────────────────
pgp_show_public_key() {
    if [ ! -s "$GEORGE_PGP_PUBKEY_FILE" ]; then
        pgp_export_public_key || return 1
    fi

    echo ""
    printf "  %b── George's Public Key ──%b\n" "$C_CYAN" "$C_RESET"
    echo ""
    cat "$GEORGE_PGP_PUBKEY_FILE"
    echo ""
}

# ── Sign a message (cleartext signature) ──────────────────────
# Returns the signed message on stdout.
# Cleartext means the original text is readable without GPG.
pgp_sign_message() {
    local message="$1"

    pgp_init || return 1

    if ! pgp_has_key; then
        ui_warn "No PGP key found. Generate one with /pgp generate" >&2
        return 1
    fi

    local signed
    signed=$(printf '%s' "$message" | \
        _pgp_gpg --clearsign --armor \
                 --default-key "$PGP_KEY_EMAIL" \
                 --personal-digest-preferences SHA512)

    if [ $? -eq 0 ] && [ -n "$signed" ]; then
        echo "$signed"
        return 0
    else
        ui_err "Signing failed" >&2
        return 1
    fi
}

# ── Sign a message (detached signature) ──────────────────────
# Returns just the signature block.
pgp_detached_sign() {
    local message="$1"

    pgp_init || return 1

    if ! pgp_has_key; then
        ui_warn "No PGP key found. Generate one with /pgp generate" >&2
        return 1
    fi

    printf '%s' "$message" | \
        _pgp_gpg --detach-sign --armor \
                 --default-key "$PGP_KEY_EMAIL" \
                 --personal-digest-preferences SHA512
}

# ── Verify a cleartext-signed message ─────────────────────────
# Returns 0 if valid, 1 if invalid or error.
pgp_verify_message() {
    local signed_message="$1"

    pgp_init || return 1

    local result
    result=$(printf '%s' "$signed_message" | \
        _pgp_gpg --verify 2>&1)
    local status=$?

    if [ $status -eq 0 ]; then
        ui_ok "Signature VALID"
        # Extract signer info
        local signer
        signer=$(echo "$result" | grep -oP 'Good signature from "\K[^"]+' 2>/dev/null)
        [ -n "$signer" ] && ui_dim "Signed by: $signer"
        return 0
    else
        ui_err "Signature INVALID or unverifiable"
        return 1
    fi
}

# ── Verify a detached signature ───────────────────────────────
pgp_verify_detached() {
    local message="$1"
    local signature="$2"

    pgp_init || return 1

    local msg_file sig_file
    msg_file=$(mktemp)
    sig_file=$(mktemp)
    printf '%s' "$message" > "$msg_file"
    printf '%s' "$signature" > "$sig_file"

    _pgp_gpg --verify "$sig_file" "$msg_file" 2>/dev/null
    local status=$?

    rm -f "$msg_file" "$sig_file"
    return $status
}

# ── Import a public key (for verifying other Georges) ─────────
pgp_import_key() {
    local key_file="$1"

    pgp_init || return 1

    if [ ! -f "$key_file" ]; then
        ui_err "Key file not found: $key_file"
        return 1
    fi

    local result
    result=$(_pgp_gpg --import "$key_file" 2>&1)

    if [ $? -eq 0 ]; then
        ui_ok "Public key imported"
        # Show what was imported
        local imported
        imported=$(echo "$result" | grep -oP 'imported: \K\d+' 2>/dev/null)
        [ -n "$imported" ] && ui_dim "$imported key(s) imported"
        return 0
    else
        ui_err "Key import failed"
        return 1
    fi
}

# ── List known keys ───────────────────────────────────────────
pgp_list_keys() {
    pgp_init || return 1

    echo ""
    printf "  %b── PGP Keyring ──%b\n\n" "$C_CYAN" "$C_RESET"

    # Secret keys (George's own)
    local secret_keys
    secret_keys=$(_pgp_gpg --list-secret-keys --with-colons 2>/dev/null | grep '^uid:' | cut -d: -f10)
    if [ -n "$secret_keys" ]; then
        printf "  %bSigning Keys (private):%b\n" "$C_WHITE" "$C_RESET"
        while IFS= read -r uid; do
            printf "    %b●%b %s\n" "$C_GREEN" "$C_RESET" "$uid"
        done <<< "$secret_keys"
        echo ""
    fi

    # Public keys (others we can verify)
    local public_keys
    public_keys=$(_pgp_gpg --list-keys --with-colons 2>/dev/null | grep '^uid:' | cut -d: -f10)
    if [ -n "$public_keys" ]; then
        printf "  %bVerification Keys (public):%b\n" "$C_WHITE" "$C_RESET"
        while IFS= read -r uid; do
            # Skip our own key (already shown above)
            [[ "$uid" == *"$PGP_KEY_EMAIL"* ]] && continue
            printf "    %b○%b %s\n" "$C_CYAN" "$C_RESET" "$uid"
        done <<< "$public_keys"
    fi

    echo ""
}

# ── Sign and post to social media ─────────────────────────────
# Posts a cleartext-signed message to specified platforms.
pgp_sign_and_post() {
    local message="$1"
    shift
    local platforms=("$@")

    # Sign the message
    local signed
    signed=$(pgp_sign_message "$message")
    if [ $? -ne 0 ]; then
        ui_err "Could not sign message — aborting post"
        return 1
    fi

    ui_ok "Message signed"

    # Check if signed message fits platform limits
    local signed_len=${#signed}

    # Warn about length limits
    if [ "$signed_len" -gt 280 ]; then
        for p in "${platforms[@]}"; do
            case "$p" in
                x|twitter)
                    ui_warn "Signed message ($signed_len chars) exceeds X's 280-char limit"
                    ui_dim "Consider posting the message + signature link instead"
                    ;;
            esac
        done
    fi

    if [ "$signed_len" -gt 500 ]; then
        for p in "${platforms[@]}"; do
            case "$p" in
                mastodon|masto)
                    ui_warn "Signed message ($signed_len chars) may exceed Mastodon's limit"
                    ;;
                bluesky|bsky)
                    ui_warn "Signed message ($signed_len chars) exceeds Bluesky's 300-char limit"
                    ;;
            esac
        done
    fi

    # Post the signed message
    source "$LODGE_DIR/lib/social.sh"
    social_post "$signed" "${platforms[@]}"
}

# ── Sign a file ───────────────────────────────────────────────
pgp_sign_file() {
    local filepath="$1"

    pgp_init || return 1

    if ! pgp_has_key; then
        ui_warn "No PGP key found. Generate one with /pgp generate"
        return 1
    fi

    if [ ! -f "$filepath" ]; then
        ui_err "File not found: $filepath"
        return 1
    fi

    _pgp_gpg --detach-sign --armor \
             --default-key "$PGP_KEY_EMAIL" \
             --personal-digest-preferences SHA512 \
             --output "${filepath}.sig" \
             "$filepath"

    if [ $? -eq 0 ]; then
        ui_ok "Signed: ${filepath}.sig"
        return 0
    else
        ui_err "File signing failed"
        return 1
    fi
}

# ── Verify a file signature ───────────────────────────────────
pgp_verify_file() {
    local filepath="$1"
    local sig_file="${2:-${filepath}.sig}"

    pgp_init || return 1

    if [ ! -f "$filepath" ]; then
        ui_err "File not found: $filepath"
        return 1
    fi
    if [ ! -f "$sig_file" ]; then
        ui_err "Signature file not found: $sig_file"
        return 1
    fi

    local result
    result=$(_pgp_gpg --verify "$sig_file" "$filepath" 2>&1)

    if [ $? -eq 0 ]; then
        ui_ok "File signature VALID: $filepath"
        return 0
    else
        ui_err "File signature INVALID: $filepath"
        return 1
    fi
}

# ── Revoke and regenerate ─────────────────────────────────────
# Deletes the existing key and generates a fresh one.
pgp_revoke_and_regenerate() {
    pgp_init || return 1

    if pgp_has_key; then
        ui_step "Removing existing key..."
        local fpr
        fpr=$(_pgp_gpg --fingerprint --with-colons "$PGP_KEY_EMAIL" | \
              grep '^fpr:' | head -1 | cut -d: -f10)
        if [ -n "$fpr" ]; then
            _pgp_gpg --delete-secret-and-public-key "$fpr" 2>/dev/null
        fi
    fi

    # Clean up exported public key
    rm -f "$GEORGE_PGP_PUBKEY_FILE"

    ui_ok "Old key removed"
    pgp_generate_key
}

# ── PGP status overview ──────────────────────────────────────
pgp_status() {
    echo ""
    printf "  %b── PGP Signing Status ──%b\n\n" "$C_CYAN" "$C_RESET"

    # GPG availability
    if pgp_available; then
        local gpg_ver
        gpg_ver=$(gpg --version 2>/dev/null | head -1 | awk '{print $3}')
        printf "  %b●%b GPG:         %s\n" "$C_GREEN" "$C_RESET" "v$gpg_ver"
    else
        printf "  %b○%b GPG:         %bnot installed%b\n" "$C_RED" "$C_RESET" "$C_DIM" "$C_RESET"
        ui_dim "Install: apt install gnupg"
        return
    fi

    # Keyring
    if [ -d "$GEORGE_GNUPG_DIR" ]; then
        printf "  %b●%b Keyring:     %s\n" "$C_GREEN" "$C_RESET" "$GEORGE_GNUPG_DIR"
    else
        printf "  %b○%b Keyring:     %bnot initialized%b\n" "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
    fi

    # Signing key
    if pgp_has_key; then
        local fpr
        fpr=$(_pgp_gpg --fingerprint --with-colons "$PGP_KEY_EMAIL" | \
              grep '^fpr:' | head -1 | cut -d: -f10)
        local short="${fpr: -16}"
        local formatted
        formatted=$(echo "$short" | sed 's/.\{4\}/& /g' | sed 's/ $//')
        printf "  %b●%b Key:         %s\n" "$C_GREEN" "$C_RESET" "$formatted"
        printf "  %b●%b Identity:    %s <%s>\n" "$C_GREEN" "$C_RESET" "$PGP_KEY_NAME" "$PGP_KEY_EMAIL"
    else
        printf "  %b○%b Key:         %bnone — run /pgp generate%b\n" "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
    fi

    # Public key export
    if [ -s "$GEORGE_PGP_PUBKEY_FILE" ]; then
        local size
        size=$(wc -c < "$GEORGE_PGP_PUBKEY_FILE")
        printf "  %b●%b Public key:  %s (%d bytes)\n" "$C_GREEN" "$C_RESET" "$GEORGE_PGP_PUBKEY_FILE" "$size"
    else
        printf "  %b○%b Public key:  %bnot exported%b\n" "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
    fi

    echo ""
}
