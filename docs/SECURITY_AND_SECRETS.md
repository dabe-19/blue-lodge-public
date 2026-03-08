# Security & Secrets

> The command allowlist, network audit mode, HMAC-SHA256 file signing, AES-256-CBC vault, secure deletion, and per-sandbox permission system.

---

## Table of Contents

- [Design Philosophy](#design-philosophy)
- [Command Allowlist](#command-allowlist)
- [Network Audit Mode](#network-audit-mode)
- [HMAC File Signing](#hmac-file-signing)
- [Encrypted Memory](#encrypted-memory)
- [Secrets Vault](#secrets-vault)
- [Per-Sandbox Permissions](#per-sandbox-permissions)
- [Startup Integrity Check](#startup-integrity-check)
- [Troubleshooting](#troubleshooting)
- [Key Functions Reference](#key-functions-reference)

---

## Design Philosophy

1. **Allowlist, not blocklist** — Instead of trying to enumerate every dangerous command (an impossible task), the system maintains a list of explicitly safe command prefixes. Anything not on the list requires user confirmation. This is the only secure default.
2. **Bodily autonomy** — George's memory files (soul.md, journal.md, GEORGE.md) are HMAC-signed. This means George can detect if someone edited his memory externally. The LLM assistant "owns" its own identity files.
3. **Plaintext never touches disk** — Secrets are encrypted with AES-256-CBC before writing to disk. Decryption goes directly to stdout (piped to wherever it's needed), never to a temporary file.
4. **Secure deletion** — When secrets are deleted, the file is overwritten with random data before `rm`. Uses `shred` when available, falls back to `dd if=/dev/urandom`.
5. **Graceful degradation** — The HMAC system has a three-tier fallback: `openssl` → `sha256sum` → `cksum`. This means signing works even on minimal systems, just with less cryptographic strength.

---

## Command Allowlist

### How It Works

When the LLM generates a command for execution, `security_check_allowlist()` extracts every command word and checks each one against the allowlist. If any command is not allowlisted, the entire command string is flagged.

### The Default Allowlist

Defined as a bash array in `lib/security.sh`:

```bash
LODGE_COMMAND_ALLOWLIST=(
    # Build tools
    "cargo" "rustc" "make" "cmake" "gcc" "g++" "clang"
    # Python
    "python" "python3" "pip" "pip3" "uv" "pytest" "mypy" "ruff" "black" "isort"
    # Node/JS
    "node" "npm" "npx" "yarn" "pnpm" "bun" "deno" "tsc" "eslint"
    # Version control
    "git"
    # Shell utilities (read-only / safe)
    "echo" "printf" "cat" "head" "tail" "grep" "awk" "sed" "sort" "uniq"
    "wc" "find" "ls" "tree" "stat" "file" "which" "type" "dirname" "basename"
    "realpath" "readlink" "date" "env" "printenv" "true" "false" "test"
    # File operations (non-destructive)
    "mkdir" "touch" "cp" "mv" "ln" "tee" "diff" "patch"
    # Archive / compression
    "tar" "gzip" "gunzip" "zip" "unzip"
    # Go, Java, Kotlin, Ruby
    "go" "javac" "java" "gradle" "mvn" "kotlinc" "ruby" "gem" "bundle"
    # System info (safe read-only)
    "uname" "whoami" "id" "pwd" "df" "du" "free" "top" "ps" "lscpu"
    # Tools
    "ollama" "jq"
)
```

### User-Defined Extensions

Users can extend the allowlist without modifying source code. Create `$LODGE_DIR/.george/allowlist.conf`:

```text
# My custom safe commands
terraform
kubectl
docker
helm
```

This file is loaded at startup by `_security_load_user_allowlist()`. Comments (`#`) and blank lines are stripped.

### Command Extraction — How Multi-Command Strings Are Parsed

```bash
security_check_allowlist() {
    local commands="$1"

    # Split on pipe, &&, ||, and ; to extract individual commands
    local cmd_words
    cmd_words=$(echo "$commands" | tr '|' '\n' | tr '&' '\n' | tr ';' '\n' |
        sed 's/^[[:space:]]*//' | awk '{print $1}' | grep -v '^$' | sort -u)
```

**Bash Technique — `tr` as a pipeline splitter**: Rather than building a regex to parse shell syntax, the code uses `tr` to convert every pipe, ampersand, and semicolon into a newline. Then `awk '{print $1}'` extracts just the first word (the command name) from each resulting line. This is a common bash idiom: transform the problem into "one item per line" and then process line by line.

**Bash Technique — `basename` for path stripping**: Commands like `/usr/bin/git` are normalized to `git` with `basename "$word"`, preventing path prefix bypasses.

### Permission Levels

The allowlist interacts with the global permission system:

| Level | Constant | Behavior |
|-------|----------|----------|
| 0 | Ask Always | Every command requires confirmation, even allowlisted ones |
| 1 | Smart (default) | Allowlisted commands auto-approved; others require confirmation |
| 2 | Auto-Approve | All commands auto-approved (**dangerous**) |

---

## Network Audit Mode

When `LODGE_NETWORK_AUDIT=1`, the LLM cannot run commands that access the network. User-initiated commands (via `/web`, `/social`, etc.) are not affected.

### Pattern Matching

```bash
_NETWORK_PATTERNS='(curl|wget|nc|ncat|nmap|ssh|scp|sftp|rsync|ftp|telnet|ping|traceroute|dig|nslookup|host|/dev/tcp|/dev/udp|socat|netcat)'

security_check_network() {
    local commands="$1"
    if [ "$LODGE_NETWORK_AUDIT" -ne 1 ]; then
        return 0  # Audit disabled
    fi
    if echo "$commands" | grep -qE "$_NETWORK_PATTERNS"; then
        return 1  # Network access detected
    fi
    return 0
}
```

This catches all common network tools plus the bash-native `/dev/tcp` and `/dev/udp` special files.

### Enabling

```bash
export LODGE_NETWORK_AUDIT=1
```

Or set permanently in your shell profile.

---

## HMAC File Signing

### Architecture

```
 ┌──────────────────┐      ┌───────────────────────┐
 │ signing.key       │──▶   │ _security_hmac()       │
 │ (256-bit random)  │      │ openssl dgst -sha256   │
 └──────────────────┘      │  -hmac "$key" "$file"  │
                            └───────────┬───────────┘
                                        │
                            ┌───────────▼───────────┐
                            │  soul.md.sig            │
                            │  (hex digest string)    │
                            └─────────────────────────┘
```

### Key Generation

On first run, `security_keyring_init()` generates a 256-bit random key:

```bash
security_keyring_init() {
    mkdir -p "$GEORGE_KEYRING_DIR"
    chmod 700 "$GEORGE_KEYRING_DIR"

    local keyfile="$GEORGE_KEYRING_DIR/signing.key"
    if [ ! -f "$keyfile" ]; then
        if command -v openssl &>/dev/null; then
            openssl rand -hex 32 > "$keyfile"
        else
            # Fallback: /dev/urandom
            head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n' > "$keyfile"
        fi
        chmod 600 "$keyfile"
    fi
}
```

**Key storage**: `$LODGE_DIR/.george/.keyring/signing.key` — mode 600 (owner read/write only), parent directory mode 700.

**Bash Technique — `od -A n -t x1`**: Converts binary data to hexadecimal. `-A n` suppresses the address column, `-t x1` outputs as single-byte hex. Combined with `tr -d ' \n'`, this produces a clean 64-character hex string.

### HMAC Computation — Three-Tier Fallback

```bash
_security_hmac() {
    local filepath="$1" key="$2"

    if command -v openssl &>/dev/null; then
        # Best: true HMAC-SHA256
        openssl dgst -sha256 -hmac "$key" "$filepath" 2>/dev/null | awk '{print $NF}'
    elif command -v sha256sum &>/dev/null; then
        # Fallback: key-prefixed hash (not true HMAC but better than nothing)
        echo -n "${key}" | cat - "$filepath" | sha256sum | awk '{print $1}'
    else
        # Last resort: simple checksum
        cksum "$filepath" | awk '{print $1}'
    fi
}
```

**Tier 1 (openssl)**: True HMAC-SHA256. Cryptographically sound.  
**Tier 2 (sha256sum)**: Concatenates the key as a prefix and hashes the result. Not a true HMAC (vulnerable to length-extension attacks), but sufficient for tamper detection on a local system.  
**Tier 3 (cksum)**: CRC only. Detects accidental corruption, not malicious tampering. Only used on extremely minimal systems.

### Sign and Verify

```bash
# Signing: creates/updates the .sig companion file
security_sign_file() {
    local filepath="$1"
    local key=$(_security_get_key)
    local sig=$(_security_hmac "$filepath" "$key")
    echo "$sig" > "${filepath}.sig"
    chmod 600 "${filepath}.sig"
}

# Verification: returns 0=valid, 1=tampered, 2=unsigned
security_verify_file() {
    local filepath="$1"
    local sigfile="${filepath}.sig"
    [ ! -f "$sigfile" ] && return 2   # Unsigned
    local key=$(_security_get_key)
    local expected=$(cat "$sigfile")
    local actual=$(_security_hmac "$filepath" "$key")
    [ "$expected" = "$actual" ] && return 0 || return 1
}
```

### Share Tokens

George can prove a file's authenticity to a third party without exposing the signing key:

```bash
security_generate_share_token() {
    local filepath="$1"
    local key=$(_security_get_key)
    local sig=$(_security_hmac "$filepath" "$key")
    # Token = sha256(sig + filepath) — proves authenticity without key exposure
    echo -n "${sig}:${filepath}" | sha256sum | awk '{print $1}'
}
```

The share token is `SHA256(HMAC(file) + ":" + filepath)`. A verifier can check this matches without ever seeing the signing key.

---

## Encrypted Memory

### In-Place File Encryption

George can encrypt his identity files so only he can read them:

```bash
security_encrypt_file() {
    local filepath="$1"
    local key=$(_security_get_key)

    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in "$filepath" -out "${filepath}.enc" \
        -pass "pass:${key}" 2>/dev/null

    mv "${filepath}.enc" "$filepath"    # Replace original
    security_sign_file "$filepath"      # Sign the encrypted version
}
```

**Parameters**: AES-256-CBC with PBKDF2 key derivation using 100,000 iterations. The `-salt` flag ensures the same plaintext produces different ciphertext on each encryption.

### Encrypted File Detection

```bash
security_is_encrypted() {
    local filepath="$1"
    local header
    header=$(head -c 8 "$filepath" 2>/dev/null | od -A n -t x1 | tr -d ' \n' | head -c 16)
    [ "$header" = "53616c7465645f5f" ]  # "Salted__" in hex
}
```

**Bash Technique**: OpenSSL encrypted files always start with the ASCII string "Salted__" (hex `53616c7465645f5f`). Checking the first 8 bytes is a reliable heuristic for detecting encrypted files.

---

## Secrets Vault

### Architecture

```
$LODGE_DIR/.george/.vault/
├── api_key_openai.enc      # Each secret is a separate encrypted file
├── github_token.enc
└── smtp_password.enc
```

Each secret is independently encrypted with AES-256-CBC (PBKDF2, 100k iterations) using the same signing key from the keyring.

### Name Validation

```bash
_vault_validate_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]]
}
```

Names must start with a letter or underscore, followed by alphanumeric, underscore, dot, or dash. This prevents directory traversal attacks (`../../../etc/passwd`) and shell injection via filenames.

### Store a Secret

```bash
secrets_set "api_key_openai" "sk-abc123..."
```

The value is encrypted with `openssl enc -aes-256-cbc -pbkdf2 -iter 100000` and written to `$VAULT_DIR/api_key_openai.enc` with mode 600.

### Retrieve a Secret

```bash
key=$(secrets_get "api_key_openai")
```

Decrypted directly to stdout. Never logged, never stored in a temp file.

### Secure Deletion

```bash
secrets_delete() {
    local enc_file="$VAULT_DIR/${name}.enc"

    if command -v shred &>/dev/null; then
        shred -u "$enc_file" 2>/dev/null
    else
        dd if=/dev/urandom of="$enc_file" \
            bs=$(stat -c %s "$enc_file" 2>/dev/null || echo 256) count=1 2>/dev/null
        rm -f "$enc_file"
    fi
}
```

**Bash Technique — Secure deletion fallback**: `shred -u` overwrites the file with random data multiple times, then deletes it. On systems without `shred` (e.g., Termux), `dd if=/dev/urandom` does a single-pass overwrite before `rm`. This is a best-effort approach — on flash storage (phones) or CoW filesystems (btrfs), the old data may persist in unallocated blocks.

### Import From File

```bash
secrets_import_file "ssh_key" "$HOME/.ssh/id_rsa" 1  # 1 = delete original
```

Reads the file, encrypts it into the vault, and optionally securely deletes the original.

### Export to Environment

```bash
eval "$(secrets_export_env "api_key_openai" "OPENAI_API_KEY")"
```

Outputs `export OPENAI_API_KEY='decrypted_value'` for `eval`. The single-quote wrapping prevents shell expansion of special characters in the value.

### One-Shot Usage

```bash
secrets_with "api_key" "API_KEY" 'curl -H "Authorization: Bearer $API_KEY" ...'
```

Runs the command in a subshell with the secret as an environment variable. When the subshell exits, the variable is gone — it never leaks into the parent shell's environment.

### Key Rotation

```bash
secrets_rotate_key
```

This atomically:
1. Decrypts all secrets with the old key (stored in a bash associative array)
2. Generates a new 256-bit key
3. Re-encrypts every secret with the new key
4. Reports any failures

**Bash Technique — Associative array as in-memory store**: During rotation, decrypted values live only in `local -A decrypted` — a bash associative array that exists only in the function's stack frame. When the function returns, the memory is freed.

### Vault Status

```bash
/vault status
```

Shows: vault location, secret count, encryption algorithm, total size on disk.

---

## Per-Sandbox Permissions

Each sandbox can have its own permission level, overriding the global `LODGE_PERMISSION`:

```bash
# Set
security_sandbox_set_permission "my-project" 0   # Ask Always

# Get (falls back to global if not set)
level=$(security_sandbox_get_permission "my-project")

# List all
security_sandbox_list_permissions
```

**Storage**: `$LODGE_DIR/.george/sandbox_permissions.conf` — simple `name=level` format, one per line.

### Permission Levels

| Level | Name | Behavior |
|-------|------|----------|
| 0 | Ask Always | Confirm every LLM-generated command |
| 1 | Smart | Auto-approve allowlisted commands, confirm others |
| 2 | Auto-Approve | Run everything without confirmation (**use with caution**) |

---

## Startup Integrity Check

`security_startup_check()` runs on every George startup:

1. Initializes the keyring (creates key if first run)
2. Loads user allowlist extensions
3. Verifies `soul.md` signature — warns if tampered
4. Verifies `journal.md` signature — warns if tampered
5. Returns non-zero if any issues found

After every write to an identity file, `security_sign_identity_files()` re-signs both files.

---

## Troubleshooting

### "Signature mismatch" on soul.md

This means someone (or something) edited soul.md outside of George. If you intentionally edited it, re-sign it:

```bash
# In the REPL:
/security sign
```

Or manually:

```bash
source lib/security.sh
security_sign_file "$LODGE_DIR/soul.md"
```

### Secrets won't decrypt after system change

If you moved the `$LODGE_DIR` directory or restored from backup, the keyring may be missing or corrupted. The signing key in `.george/.keyring/signing.key` must match the key used to encrypt the secrets. There is no recovery if the key is lost — this is by design.

### Adding a command to the allowlist

Two options:

1. **Temporary** (current session): `LODGE_COMMAND_ALLOWLIST+=("mycommand")`
2. **Permanent**: Add `mycommand` to `$LODGE_DIR/.george/allowlist.conf`

### Network audit false positives

If a legitimate command is being blocked by network audit mode, check if it matches any pattern in `_NETWORK_PATTERNS`. The audit mode is a simple regex check — it doesn't analyze actual network behavior. You can disable it: `export LODGE_NETWORK_AUDIT=0`.

### openssl not installed

The system degrades gracefully:
- **Signing**: Falls back to `sha256sum` (key-prefixed), then `cksum`
- **Vault encryption**: **Will not work** — openssl is mandatory for the vault
- **Key generation**: Falls back to `/dev/urandom` + `od`

Install openssl: `pkg install openssl-tool` (Termux) or `apt install openssl` (Debian).

---

## Key Functions Reference

### security.sh

| Function | Purpose |
|----------|---------|
| `security_check_allowlist()` | Check if command string uses only allowlisted commands |
| `security_check_network()` | Check if command accesses the network (audit mode) |
| `security_keyring_init()` | Generate 256-bit signing key |
| `security_sign_file()` | Create HMAC-SHA256 signature for a file |
| `security_verify_file()` | Verify file against its signature (0=ok, 1=tampered, 2=unsigned) |
| `security_check_integrity()` | Verify + print human-readable status |
| `security_encrypt_file()` | AES-256-CBC encrypt a file in place |
| `security_decrypt_file()` | Decrypt an encrypted file in place |
| `security_is_encrypted()` | Check if file starts with "Salted__" header |
| `security_generate_share_token()` | Create one-time verification token |
| `security_verify_share_token()` | Verify a share token |
| `security_sandbox_set_permission()` | Set per-sandbox permission level |
| `security_sandbox_get_permission()` | Get sandbox permission (falls back to global) |
| `security_startup_check()` | Full integrity check on startup |
| `security_sign_identity_files()` | Re-sign soul.md and journal.md |
| `security_status()` | Print security dashboard |

### secrets.sh

| Function | Purpose |
|----------|---------|
| `secrets_init()` | Initialize vault directory and key |
| `secrets_set()` | Encrypt and store a secret |
| `secrets_get()` | Decrypt a secret to stdout |
| `secrets_exists()` | Check if a secret exists |
| `secrets_delete()` | Securely delete a secret |
| `secrets_list()` | List secret names (never values) |
| `secrets_list_pretty()` | List with metadata (size, date) |
| `secrets_import_file()` | Import a file as a secret, optionally shred original |
| `secrets_export_env()` | Output export statement for eval |
| `secrets_with()` | Run command with secret as env var (subshell) |
| `secrets_rotate_key()` | Re-encrypt all secrets with new key |
| `secrets_status()` | Print vault dashboard |

---

*Previous: [UI & Terminal Rendering](UI_AND_TERMINAL.md) | Next: [Bash Techniques Reference](BASH_TECHNIQUES.md)*
