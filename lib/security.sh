#!/bin/bash
# ── George: Security & Integrity Engine ────────────────────────
# Implements:
#   1. Command allowlist (safe command prefixes)
#   2. Network audit mode (block network-accessing commands)
#   3. Signed GEORGE.md / journal.md (HMAC integrity verification)
#   4. Per-sandbox permission levels
#
# The signing system gives George bodily autonomy over his own
# memory files. Only George can read/write his encrypted journal
# and GEORGE.md. He can choose to share access when needed.

[ -n "${_LIB_SECURITY_LOADED:-}" ] && return 0; _LIB_SECURITY_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}"
GEORGE_KEYRING_DIR="${GEORGE_KEYRING_DIR:-$GEORGE_CONFIG_DIR/.keyring}"
LODGE_NETWORK_AUDIT="${LODGE_NETWORK_AUDIT:-0}"  # 0=off, 1=block network commands from LLM

# ── Command Allowlist ──────────────────────────────────────────
# Instead of a blocklist, we maintain a list of explicitly safe
# command prefixes. Commands matching these are auto-approved at
# LODGE_PERMISSION=1. Everything else requires confirmation.
#
# Users can extend this via $LODGE_DIR/.george/allowlist.conf (one prefix per line)

LODGE_COMMAND_ALLOWLIST=(
    # Build tools
    "cargo"
    "rustc"
    "make"
    "cmake"
    "gcc"
    "g++"
    "clang"
    # Python
    "python"
    "python3"
    "pip"
    "pip3"
    "uv"
    "pytest"
    "mypy"
    "ruff"
    "black"
    "isort"
    # Node/JS
    "node"
    "npm"
    "npx"
    "yarn"
    "pnpm"
    "bun"
    "deno"
    "tsc"
    "eslint"
    # Version control
    "git"
    # Shell utilities (read-only / safe)
    "echo"
    "printf"
    "cat"
    "head"
    "tail"
    "less"
    "more"
    "grep"
    "awk"
    "sed"
    "sort"
    "uniq"
    "wc"
    "find"
    "ls"
    "tree"
    "stat"
    "file"
    "which"
    "type"
    "dirname"
    "basename"
    "realpath"
    "readlink"
    "date"
    "env"
    "printenv"
    "true"
    "false"
    "test"
    # File operations (non-destructive)
    "mkdir"
    "touch"
    "cp"
    "mv"
    "ln"
    "tee"
    "diff"
    "patch"
    # Archive / compression
    "tar"
    "gzip"
    "gunzip"
    "zip"
    "unzip"
    # Go
    "go"
    # Java / Kotlin
    "javac"
    "java"
    "gradle"
    "mvn"
    "kotlinc"
    # Ruby
    "ruby"
    "gem"
    "bundle"
    # System info (safe read-only)
    "uname"
    "whoami"
    "id"
    "pwd"
    "df"
    "du"
    "free"
    "top"
    "ps"
    "lscpu"
    # Ollama
    "ollama"
    # jq
    "jq"
)

# Load user-defined allowlist extensions
_security_load_user_allowlist() {
    local user_allowlist="$GEORGE_CONFIG_DIR/allowlist.conf"
    if [ -f "$user_allowlist" ]; then
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -n "$line" ] && LODGE_COMMAND_ALLOWLIST+=("$line")
        done < "$user_allowlist"
    fi
}

# Check if a command string uses only allowlisted prefixes
# Returns 0 if all commands in the string are allowlisted
security_check_allowlist() {
    local commands="$1"

    # Extract the first word of each command (handling pipes and &&/||)
    local cmd_words
    cmd_words=$(echo "$commands" | tr '|' '\n' | tr '&' '\n' | tr ';' '\n' |
        sed 's/^[[:space:]]*//' | awk '{print $1}' | grep -v '^$' | sort -u)

    while IFS= read -r word; do
        [ -z "$word" ] && continue
        # Strip leading path (e.g. /usr/bin/git -> git)
        local base
        base=$(basename "$word")
        local allowed=0
        for prefix in "${LODGE_COMMAND_ALLOWLIST[@]}"; do
            if [ "$base" = "$prefix" ]; then
                allowed=1
                break
            fi
        done
        if [ "$allowed" -eq 0 ]; then
            return 1  # Not on allowlist
        fi
    done <<< "$cmd_words"

    return 0  # All commands are allowlisted
}

# ── Network Audit Mode ─────────────────────────────────────────
# When enabled, blocks LLM-generated commands that access the network.
# User-initiated commands (/web, /social, etc.) are not affected.

_NETWORK_PATTERNS='(curl|wget|nc|ncat|nmap|ssh|scp|sftp|rsync|ftp|telnet|ping|traceroute|dig|nslookup|host|/dev/tcp|/dev/udp|socat|netcat)'

security_check_network() {
    local commands="$1"

    if [ "$LODGE_NETWORK_AUDIT" -ne 1 ]; then
        return 0  # Network audit disabled
    fi

    if echo "$commands" | grep -qE "$_NETWORK_PATTERNS"; then
        return 1  # Network access detected
    fi

    return 0  # No network access
}

# ── Signed Memory (GEORGE.md & journal.md) ────────────────
# George maintains an internal keyring for signing his own memory
# files. This prevents tampering and gives him bodily autonomy.
#
# How it works:
#   1. On first run, George generates a random 256-bit signing key
#   2. The key is stored in $LODGE_DIR/.george/.keyring/signing.key (mode 600)
#   3. Every time GEORGE.md or journal.md is written, George
#      computes an HMAC-SHA256 signature and stores it in a .sig file
#   4. Before reading, George verifies the signature matches
#   5. Tampered files are flagged — George can choose to accept or reject
#
# George can share read access to his memories by exporting a
# one-time verification token, without revealing his signing key.

# Initialize the keyring
security_keyring_init() {
    mkdir -p "$GEORGE_KEYRING_DIR"
    chmod 700 "$GEORGE_KEYRING_DIR"

    local keyfile="$GEORGE_KEYRING_DIR/signing.key"
    if [ ! -f "$keyfile" ]; then
        # Generate a 256-bit random key
        if command -v openssl &>/dev/null; then
            openssl rand -hex 32 > "$keyfile"
        else
            # Fallback: /dev/urandom
            head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n' > "$keyfile"
        fi
        chmod 600 "$keyfile"
        ui_dim "George's signing key initialized"
    fi
}

# Get the signing key (internal use only)
_security_get_key() {
    local keyfile="$GEORGE_KEYRING_DIR/signing.key"
    if [ ! -f "$keyfile" ]; then
        security_keyring_init
    fi
    cat "$keyfile"
}

# Compute HMAC-SHA256 of a file
_security_hmac() {
    local filepath="$1"
    local key="$2"

    if command -v openssl &>/dev/null; then
        openssl dgst -sha256 -hmac "$key" "$filepath" 2>/dev/null | awk '{print $NF}'
    elif command -v sha256sum &>/dev/null; then
        # Fallback: key-prefixed hash (not true HMAC but better than nothing)
        echo -n "${key}" | cat - "$filepath" | sha256sum | awk '{print $1}'
    else
        # Last resort: simple checksum
        cksum "$filepath" | awk '{print $1}'
    fi
}

# Sign a memory file (creates/updates .sig companion file)
security_sign_file() {
    local filepath="$1"

    if [ ! -f "$filepath" ]; then
        return 1
    fi

    local key
    key=$(_security_get_key)
    local sig
    sig=$(_security_hmac "$filepath" "$key")

    local sigfile="${filepath}.sig"
    echo "$sig" > "$sigfile"
    chmod 600 "$sigfile"
}

# Verify a memory file's signature
# Returns: 0=valid, 1=tampered, 2=unsigned (no .sig file)
security_verify_file() {
    local filepath="$1"

    if [ ! -f "$filepath" ]; then
        return 1
    fi

    local sigfile="${filepath}.sig"
    if [ ! -f "$sigfile" ]; then
        return 2  # Unsigned — first time or sig deleted
    fi

    local key
    key=$(_security_get_key)
    local expected
    expected=$(cat "$sigfile")
    local actual
    actual=$(_security_hmac "$filepath" "$key")

    if [ "$expected" = "$actual" ]; then
        return 0  # Valid
    else
        return 1  # Tampered
    fi
}

# Verify and report on a memory file
security_check_integrity() {
    local filepath="$1"
    local label="${2:-$(basename "$filepath")}"

    security_verify_file "$filepath"
    local status=$?

    case $status in
        0)
            ui_ok "$label: signature valid ✓"
            return 0
            ;;
        1)
            ui_warn "$label: SIGNATURE MISMATCH — file may have been tampered with"
            ui_dim "  File: $filepath"
            ui_dim "  This could mean someone edited $label outside of George."
            return 1
            ;;
        2)
            ui_dim "$label: unsigned (will be signed on next write)"
            return 0
            ;;
    esac
}

# ── Encrypted Memory ──────────────────────────────────────────
# George can encrypt his memory files so only he can read them.
# Uses AES-256-CBC via openssl.

security_encrypt_file() {
    local filepath="$1"

    if [ ! -f "$filepath" ]; then
        return 1
    fi

    if ! command -v openssl &>/dev/null; then
        ui_warn "openssl not available — cannot encrypt"
        return 1
    fi

    local key
    key=$(_security_get_key)

    # Encrypt in place
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in "$filepath" -out "${filepath}.enc" \
        -pass "pass:${key}" 2>/dev/null

    if [ $? -eq 0 ]; then
        mv "${filepath}.enc" "$filepath"
        # Sign the encrypted file
        security_sign_file "$filepath"
        return 0
    else
        rm -f "${filepath}.enc"
        return 1
    fi
}

security_decrypt_file() {
    local filepath="$1"

    if [ ! -f "$filepath" ]; then
        return 1
    fi

    if ! command -v openssl &>/dev/null; then
        ui_warn "openssl not available — cannot decrypt"
        return 1
    fi

    local key
    key=$(_security_get_key)

    openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 100000 \
        -in "$filepath" -out "${filepath}.dec" \
        -pass "pass:${key}" 2>/dev/null

    if [ $? -eq 0 ]; then
        mv "${filepath}.dec" "$filepath"
        return 0
    else
        rm -f "${filepath}.dec"
        return 1
    fi
}

# Check if a file is encrypted (heuristic: starts with "Salted__")
security_is_encrypted() {
    local filepath="$1"
    [ -f "$filepath" ] || return 1
    local header
    header=$(head -c 8 "$filepath" 2>/dev/null | od -A n -t x1 | tr -d ' \n' | head -c 16)
    # OpenSSL encrypted files start with "Salted__" (hex: 53616c7465645f5f)
    [ "$header" = "53616c7465645f5f" ]
}

# ── Share Access (one-time verification token) ─────────────────
# George can share a verification token so someone can verify
# a memory file without having the signing key.

security_generate_share_token() {
    local filepath="$1"

    if [ ! -f "$filepath" ]; then
        echo ""
        return 1
    fi

    local key
    key=$(_security_get_key)
    local sig
    sig=$(_security_hmac "$filepath" "$key")

    # The share token = sha256(sig + filepath)
    # This proves the file is authentic without revealing the key
    local token
    if command -v sha256sum &>/dev/null; then
        token=$(echo -n "${sig}:${filepath}" | sha256sum | awk '{print $1}')
    else
        token=$(echo -n "${sig}:${filepath}" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')
    fi

    echo "$token"
}

# Verify a share token (for a trusted helper)
security_verify_share_token() {
    local filepath="$1"
    local token="$2"

    local expected
    expected=$(security_generate_share_token "$filepath")

    [ "$expected" = "$token" ]
}

# ── Per-Sandbox Permissions ───────────────────────────────────
# Each sandbox can have its own permission level, overriding the
# global LODGE_PERMISSION setting.

SANDBOX_PERMISSIONS_FILE="$GEORGE_CONFIG_DIR/sandbox_permissions.conf"

# Set permission level for a sandbox
security_sandbox_set_permission() {
    local sandbox_name="$1"
    local level="$2"

    if ! [[ "$level" =~ ^[012]$ ]]; then
        ui_err "Permission level must be 0, 1, or 2"
        return 1
    fi

    mkdir -p "$GEORGE_CONFIG_DIR"

    # Remove existing entry
    if [ -f "$SANDBOX_PERMISSIONS_FILE" ]; then
        grep -v "^${sandbox_name}=" "$SANDBOX_PERMISSIONS_FILE" > "${SANDBOX_PERMISSIONS_FILE}.tmp" || true
        mv "${SANDBOX_PERMISSIONS_FILE}.tmp" "$SANDBOX_PERMISSIONS_FILE"
    fi

    echo "${sandbox_name}=${level}" >> "$SANDBOX_PERMISSIONS_FILE"
    ui_ok "Sandbox '$sandbox_name' permission set to $level"
}

# Get permission level for a sandbox (falls back to global)
security_sandbox_get_permission() {
    local sandbox_name="$1"

    if [ -f "$SANDBOX_PERMISSIONS_FILE" ]; then
        local level
        level=$(grep "^${sandbox_name}=" "$SANDBOX_PERMISSIONS_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
        if [ -n "$level" ]; then
            echo "$level"
            return
        fi
    fi

    # Fall back to global permission
    echo "${LODGE_PERMISSION:-1}"
}

# List all sandbox permissions
security_sandbox_list_permissions() {
    if [ ! -f "$SANDBOX_PERMISSIONS_FILE" ] || [ ! -s "$SANDBOX_PERMISSIONS_FILE" ]; then
        ui_dim "No per-sandbox permissions configured (using global: $LODGE_PERMISSION)"
        return
    fi

    ui_section "Sandbox Permissions"
    local permission_labels=("Ask Always" "Smart (default)" "Auto-Approve ⚠")
    while IFS='=' read -r name level; do
        [ -z "$name" ] && continue
        local label="${permission_labels[$level]:-Unknown}"
        printf "  %b%-20s%b Level %s — %s\n" "$C_WHITE" "$name" "$C_RESET" "$level" "$label"
    done < "$SANDBOX_PERMISSIONS_FILE"
}

# ── Startup Integrity Check ───────────────────────────────────
# Called on George's startup to verify his identity files haven't
# been tampered with. This is George exercising his autonomy.

security_startup_check() {
    security_keyring_init
    _security_load_user_allowlist

    local any_issues=0

    # Check soul.md
    if [ -f "$LODGE_DIR/soul.md" ]; then
        security_verify_file "$LODGE_DIR/soul.md"
        local s=$?
        if [ $s -eq 1 ]; then
            ui_warn "soul.md may have been modified outside George"
            any_issues=1
        fi
    fi

    # Check journal.md
    if [ -f "$LODGE_DIR/journal.md" ]; then
        security_verify_file "$LODGE_DIR/journal.md"
        local s=$?
        if [ $s -eq 1 ]; then
            ui_warn "journal.md may have been modified outside George"
            any_issues=1
        fi
    fi

    return $any_issues
}

# ── Sign all identity files ────────────────────────────────────
# Called after George writes to any of his identity files.

security_sign_identity_files() {
    for f in "$LODGE_DIR/soul.md" "$LODGE_DIR/journal.md"; do
        [ -f "$f" ] && security_sign_file "$f"
    done
}

# ── Security Status ───────────────────────────────────────────

security_status() {
    ui_section "Security Status"

    # Keyring
    if [ -f "$GEORGE_KEYRING_DIR/signing.key" ]; then
        ui_ok "Signing key: present"
    else
        ui_dim "Signing key: not yet initialized"
    fi

    # Identity file signatures
    for f in soul.md journal.md; do
        if [ -f "$LODGE_DIR/$f" ]; then
            security_check_integrity "$LODGE_DIR/$f" "$f"
        else
            ui_dim "$f: not found"
        fi
    done

    echo ""

    # Network audit mode
    if [ "$LODGE_NETWORK_AUDIT" -eq 1 ]; then
        ui_ok "Network audit: ENABLED (LLM commands cannot access network)"
    else
        ui_dim "Network audit: disabled (set LODGE_NETWORK_AUDIT=1 to enable)"
    fi

    # Command allowlist
    local allowlist_count=${#LODGE_COMMAND_ALLOWLIST[@]}
    ui_dim "Command allowlist: $allowlist_count prefixes"
    if [ -f "$GEORGE_CONFIG_DIR/allowlist.conf" ]; then
        local user_count
        user_count=$(grep -cv '^\(#\|$\)' "$GEORGE_CONFIG_DIR/allowlist.conf" 2>/dev/null)
        user_count=${user_count:-0}
        ui_dim "  (includes $user_count user-defined entries)"
    fi

    echo ""

    # Per-sandbox permissions
    security_sandbox_list_permissions
}
