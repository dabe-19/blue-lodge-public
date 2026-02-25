# Secrets Vault — Encrypted Credential Storage

George includes an **encrypted secrets vault** for storing sensitive data —
API keys, OAuth tokens, cryptocurrency private keys, database passwords, and
any other credentials your projects need. Secrets are encrypted at rest and
decrypted to memory only when actively used.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [How It Works](#how-it-works)
3. [Encryption Details](#encryption-details)
4. [Commands Reference](#commands-reference)
5. [Storing Secrets](#storing-secrets)
6. [Giving George Access to API Keys](#giving-george-access-to-api-keys)
7. [Using Secrets in Commands](#using-secrets-in-commands)
8. [Importing Secrets from Files](#importing-secrets-from-files)
9. [Key Rotation](#key-rotation)
10. [What Happens to Your Secrets](#what-happens-to-your-secrets)
11. [Security Model](#security-model)
12. [Examples](#examples)
13. [FAQ](#faq)

---

## Quick Start

```bash
lodge

# Store an API key
george> /secret set OPENAI_API_KEY sk-proj-abc123...

# Verify it's stored
george> /secret list

# Check vault status
george> /secret status

# Retrieve a secret (outputs plaintext to stdout)
george> /secret get OPENAI_API_KEY
```

---

## How It Works

```
You type:    /secret set MY_KEY super-secret-value
                            │
                            ▼
              ┌─────────────────────────┐
              │  secrets_set("MY_KEY")  │
              │                         │
              │  1. Validate name       │
              │  2. Load signing key    │
              │  3. AES-256-CBC encrypt │
              │  4. Write .enc file     │
              │  5. chmod 600           │
              └─────────────────────────┘
                            │
                            ▼
              ~/.george/.vault/MY_KEY.enc
              (encrypted binary, mode 600)

You type:    /secret get MY_KEY
                            │
                            ▼
              ┌─────────────────────────┐
              │  secrets_get("MY_KEY")  │
              │                         │
              │  1. Load signing key    │
              │  2. AES-256-CBC decrypt │
              │  3. Output to stdout    │
              │  4. Never logged/saved  │
              └─────────────────────────┘
                            │
                            ▼
              "super-secret-value" (in memory only)
```

**Plaintext never touches disk.** The value is encrypted immediately and the
original is never stored. On retrieval, it's decrypted directly to stdout or
into a shell variable that exists only in memory.

---

## Encryption Details

| Property | Value |
|----------|-------|
| **Algorithm** | AES-256-CBC |
| **Key Derivation** | PBKDF2 with 100,000 iterations |
| **Key Size** | 256 bits (generated via `openssl rand -hex 32`) |
| **Key Storage** | `~/.george/.keyring/signing.key` (mode 600) |
| **Per-Secret Storage** | `~/.george/.vault/<name>.enc` (mode 600) |
| **Vault Directory** | `~/.george/.vault/` (mode 700) |
| **Keyring Directory** | `~/.george/.keyring/` (mode 700) |
| **Implementation** | OpenSSL `enc -aes-256-cbc -pbkdf2 -iter 100000` |
| **Secure Delete** | `shred -u` when available, random-overwrite fallback |

### What This Means in Practice

- **AES-256-CBC** is the same encryption used by banks, military systems,
  and full-disk encryption tools like LUKS and BitLocker. It would take
  billions of years to brute-force a 256-bit key with current technology.

- **PBKDF2 with 100,000 iterations** makes it computationally expensive to
  derive the encryption key, protecting against brute-force attacks on the
  signing key.

- **File permissions** (600/700) ensure only your user account can read the
  vault and keyring. Other users on the same system cannot access them.

- **Secure deletion** overwrites the file with random data before removing
  it, preventing recovery with disk forensics tools.

### What This Does NOT Protect Against

- A compromised device with full root access (an attacker who can read your
  process memory or keyring file)
- Keyloggers capturing your input when you type `/secret set`
- Physical access to an unlocked device

**Bottom line:** The vault is secure against casual snooping, disk theft,
and remote file access. It is not a hardware security module (HSM).

---

## Commands Reference

| Command | Description |
|---------|-------------|
| `/secret set <name> <value>` | Encrypt and store a secret |
| `/secret get <name>` | Decrypt and display a secret |
| `/secret delete <name>` | Securely destroy a secret |
| `/secret list` | Show all secret names (never values) |
| `/secret import <file> [name]` | Import a file's contents as a secret |
| `/secret rotate` | Re-encrypt all secrets with a fresh key |
| `/secret status` | Show vault overview (count, encryption, size) |

### Secret Naming Rules

Secret names must match: `[a-zA-Z_][a-zA-Z0-9_.-]*`

- Must start with a letter or underscore
- Can contain letters, digits, underscores, dots, and dashes
- No spaces, slashes, or special characters (prevents path traversal)

**Good names:** `OPENAI_API_KEY`, `github.token`, `aws-secret-key`, `_internal`

**Bad names:** `my secret`, `../escape`, `key/with/slashes`

---

## Storing Secrets

### Direct Input

```bash
george> /secret set GITHUB_TOKEN ghp_xxxxxxxxxxxxxxxxxxxx
george> /secret set AWS_ACCESS_KEY AKIA1234567890EXAMPLE
george> /secret set AWS_SECRET_KEY wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
george> /secret set DATABASE_URL postgresql://user:pass@localhost:5432/mydb
```

### Multi-Line / Complex Values

For values with special characters, quotes, or newlines, use the import
method:

```bash
# Write to a temp file, import it, then the file is destroyed
echo '{"key": "value", "nested": true}' > /tmp/cred.json
george> /secret import /tmp/cred.json service_account

# Or for SSH keys:
george> /secret import ~/.ssh/id_ed25519 ssh_private_key
```

### Verifying Storage

```bash
george> /secret list
  ● GITHUB_TOKEN                   142 bytes  2026-02-22 14:30:00
  ● AWS_ACCESS_KEY                  98 bytes  2026-02-22 14:30:05
  ● AWS_SECRET_KEY                 114 bytes  2026-02-22 14:30:10

george> /secret status
  ──── Secrets Vault ────
  Status:    Active
  Secrets:   3 stored
  Vault:     /home/user/.george/.vault
  Encryption: AES-256-CBC (PBKDF2, 100k iterations)
  Size:      1.2K
```

---

## Giving George Access to API Keys

This is the most important section. George can **use your secrets** to make
API calls, authenticate with services, and perform tasks that require
credentials — all without the plaintext key ever being stored on disk.

### Method 1: Tell George to Use a Stored Secret

Once a secret is stored, you can reference it naturally in your tasks:

```
george> I need to call the OpenAI API. Use my OPENAI_API_KEY secret
        to send a completion request.

  ── Plan ──
  1. Retrieve the OPENAI_API_KEY from the vault
  2. Make the API call with the key in the Authorization header
  3. Display the response

  Step 1: Retrieving secret...
  Step 2: curl -H "Authorization: Bearer $(secrets_get OPENAI_API_KEY)" \
          https://api.openai.com/v1/completions ...
```

### Method 2: Export as Environment Variable

The vault can inject secrets as environment variables for one-shot commands:

```bash
# In your scripts or George's generated commands:
eval "$(secrets_export_env OPENAI_API_KEY)"
# Now $OPENAI_API_KEY is available in the current shell

# Or use secrets_with for scoped access (variable disappears after):
secrets_with "GITHUB_TOKEN" "GH_TOKEN" "curl -H 'Authorization: token \$GH_TOKEN' https://api.github.com/user"
```

The `secrets_with` function runs the command in a **subshell** — the
environment variable exists only for that one command, then it's gone. This
is the safest way to use credentials.

### Method 3: George Auto-Discovers Secrets

When George encounters a task that needs an API key, he can check the vault:

```
george> Deploy this to Vercel

  Checking for VERCEL_TOKEN in vault... found ✓
  Step 1: vercel deploy --token $(secrets_get VERCEL_TOKEN)
```

### Common API Key Setup

Here are the secrets George is most commonly asked to use:

```bash
# GitHub (for /clone, /push with private repos)
/secret set GITHUB_TOKEN ghp_your_personal_access_token

# OpenAI (if using OpenAI-compatible endpoints)
/secret set OPENAI_API_KEY sk-proj-your_key_here

# AWS
/secret set AWS_ACCESS_KEY_ID AKIA...
/secret set AWS_SECRET_ACCESS_KEY wJalr...

# Google Cloud
/secret import ~/service-account.json GCP_SERVICE_ACCOUNT

# Vercel / Netlify / Fly.io
/secret set VERCEL_TOKEN your_token
/secret set NETLIFY_AUTH_TOKEN your_token
/secret set FLY_API_TOKEN your_token

# Database
/secret set DATABASE_URL postgresql://user:pass@host:5432/db

# SSH keys (for remote operations)
/secret import ~/.ssh/id_ed25519 SSH_PRIVATE_KEY

# Cryptocurrency (see docs/CRYPTO_WALLETS.md)
/secret set BTC_PRIVATE_KEY your_btc_private_key
/secret set SOL_PRIVATE_KEY your_solana_key
```

### Telling George About Your Secrets

George doesn't automatically know what secrets are available. You can tell
him directly, or he can discover them:

```
george> What secrets do I have stored?
  Checking vault...
  Found: GITHUB_TOKEN, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY

george> Use my AWS credentials to list S3 buckets
  Step 1: Exporting AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY...
  Step 2: aws s3 ls
```

You can also mention secrets in your project's `GEORGE.md`:

```markdown
## Credentials
- API calls use `OPENAI_API_KEY` from the vault
- Deployment uses `VERCEL_TOKEN` from the vault
```

George reads `GEORGE.md` before every task, so he'll know which secrets are
available for the project.

---

## Using Secrets in Commands

### In George's Tasks

Just describe what you need and mention the secret name:

```
george> Use my GITHUB_TOKEN to create a new private repo called "my-project"

george> Fetch weather data using the WEATHER_API_KEY

george> Push this Docker image to ECR using my AWS credentials
```

### In Shell Scripts

If you're writing scripts that George generates:

```bash
#!/bin/bash
# Load a secret into an environment variable
eval "$(secrets_export_env DATABASE_URL)"

# Use it
psql "$DATABASE_URL" -c "SELECT count(*) FROM users;"
```

### Scoped Access (Safest)

```bash
# The API key exists ONLY for this curl command
secrets_with "OPENAI_API_KEY" "API_KEY" \
    'curl -s https://api.openai.com/v1/models -H "Authorization: Bearer $API_KEY"'
```

---

## Importing Secrets from Files

For complex credentials (JSON service accounts, SSH keys, certificates):

```bash
# Import from a file (the vault copies and encrypts the content)
george> /secret import /path/to/credentials.json gcp_service_account

# Import and DELETE the original file (secure)
# In code: secrets_import_file "name" "/path/to/file" 1
```

When you pass `1` as the third argument to `secrets_import_file`, it uses
`shred -u` (or random-overwrite + delete) to securely destroy the original
file after import.

**Recommended workflow for sensitive files:**

1. Transfer the file to your device (e.g., via `scp` or Termux shared storage)
2. Import it into the vault: `/secret import /path/to/file my_key`
3. Verify: `/secret get my_key | head -c 20` (peek at first 20 chars)
4. Delete the original: `shred -u /path/to/file` (or George will do it if
   you use the programmatic import with `delete_original=1`)

---

## Key Rotation

Rotation generates a fresh 256-bit encryption key and re-encrypts every
secret in the vault with it. The old key is overwritten.

```bash
george> /secret rotate
  Decrypting 5 secrets with old key...
  Generating new 256-bit key...
  Re-encrypting 5 secrets with new key...
  ✓ Key rotation complete
```

**When to rotate:**

- Periodically (monthly, quarterly — depends on your threat model)
- After suspecting your device was compromised
- After sharing your device with someone
- Before decommissioning a device (rotate + delete all)

**What happens during rotation:**

1. All secrets are decrypted with the current key (held in memory)
2. A new random 256-bit key is generated via `openssl rand -hex 32`
3. The new key overwrites the old key file at `~/.george/.keyring/signing.key`
4. Every secret is re-encrypted with the new key
5. If any re-encryption fails, the rotation reports the failure

---

## What Happens to Your Secrets

Here's the full lifecycle of a secret, step by step:

### Storage
```
1. You type: /secret set API_KEY sk-abc123
2. Bash receives the string "sk-abc123" in memory
3. secrets_set() pipes it to: openssl enc -aes-256-cbc -pbkdf2 -iter 100000
4. OpenSSL derives an encryption key from the signing key using PBKDF2
5. The plaintext is encrypted with AES-256-CBC
6. The ciphertext is written to: ~/.george/.vault/API_KEY.enc
7. File permissions are set to 600 (owner read/write only)
8. The plaintext string is gone — it existed only in bash's memory
```

### Retrieval
```
1. You type: /secret get API_KEY  (or George calls secrets_get internally)
2. secrets_get() reads ~/.george/.vault/API_KEY.enc
3. It pipes the file to: openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000
4. The decrypted plaintext is output to stdout
5. If captured in a variable: it lives in bash's process memory
6. When the variable goes out of scope or the subshell exits: gone
```

### Deletion
```
1. You type: /secret delete API_KEY
2. If shred is available: shred -u ~/.george/.vault/API_KEY.enc
   - Overwrites the file with random data 3 times, then deletes
3. If shred is NOT available:
   - dd writes random data over the file (1 pass)
   - rm -f deletes the file
4. The encrypted file is gone from disk
```

### On Device Power-Off
```
- The signing key persists at ~/.george/.keyring/signing.key
- Encrypted vault files persist at ~/.george/.vault/*.enc
- No plaintext secrets are on disk
- On next boot, secrets can be decrypted using the signing key
```

---

## Security Model

### Threat: Someone copies your vault files

They get encrypted blobs. Without the signing key (`~/.george/.keyring/signing.key`),
they cannot decrypt anything. AES-256 with a random 256-bit key is
computationally infeasible to brute-force.

### Threat: Someone copies your signing key

If they also have the `.enc` files, they can decrypt your secrets. This is
why both directories are mode 700 and the key file is mode 600.

**Mitigation:** If you suspect key compromise, run `/secret rotate`
immediately, then change all the secrets themselves (regenerate API keys,
change passwords, etc.).

### Threat: Malicious LLM-generated code reads the vault

George's permission system requires approval for all commands at level 0/1.
A generated command like `cat ~/.george/.keyring/signing.key` would:
- **Level 0:** Ask for approval (you deny it)
- **Level 1:** Flagged as accessing sensitive path, ask for approval
- **Level 2:** Auto-approved (**this is why level 2 is dangerous**)

**Always keep `LODGE_PERMISSION` at 0 or 1.**

### Threat: Process memory inspection

If an attacker has root access and can read `/proc/<pid>/mem`, they could
theoretically find decrypted secrets in bash's memory. This is outside the
vault's threat model — it requires the device to already be fully
compromised.

### Defense in Depth

| Layer | Protection |
|-------|-----------|
| Filesystem | 700/600 permissions on vault and keyring |
| Encryption | AES-256-CBC with PBKDF2 (100k iterations) |
| Key | 256-bit random, never leaves the keyring file |
| Access | `secrets_with` runs in subshell (var scoped) |
| Deletion | `shred -u` overwrites before removing |
| Rotation | Fresh key, all secrets re-encrypted |
| Permission | Level 0/1 blocks unauthorized vault access commands |

---

## Examples

### Example 1: GitHub Private Repo Workflow

```bash
# Store your GitHub PAT
george> /secret set GITHUB_TOKEN ghp_xxxxxxxxxxxxxxxxxxxx

# Clone a private repo (George uses the token)
george> Clone my private repo myuser/secret-project using my GITHUB_TOKEN

# Push changes (George injects auth)
george> Push these changes to origin
```

### Example 2: API Integration

```bash
# Store the key
george> /secret set WEATHER_API_KEY abc123def456

# Use it in a task
george> Write a Python script that fetches the weather for
        New York using my WEATHER_API_KEY and prints a 5-day forecast
```

George will generate code that retrieves the key from the vault:

```python
import os, httpx

api_key = os.environ.get("WEATHER_API_KEY")
resp = httpx.get(f"https://api.weather.com/v1/forecast?key={api_key}&city=NewYork")
```

And run it with:
```bash
secrets_with "WEATHER_API_KEY" "WEATHER_API_KEY" "uv run python forecast.py"
```

### Example 3: Database Migration

```bash
george> /secret set DATABASE_URL postgresql://admin:s3cure@db.example.com:5432/prod

george> Run the pending database migrations using my DATABASE_URL

  Step 1: eval "$(secrets_export_env DATABASE_URL)"
  Step 2: uv run alembic upgrade head
  ✓ 3 migrations applied
```

### Example 4: Crypto Wallet Operations

```bash
# Store private keys in the vault
george> /secret set SOL_PRIVATE_KEY 4xJ9v...

# Check balance (uses wallet_check from lib/wallet.sh)
george> Check my Solana wallet balance

# The wallet system automatically retrieves keys from the vault
```

---

## FAQ

### Where are my secrets physically stored?

```
~/.george/.vault/<name>.enc     ← Encrypted secret files
~/.george/.keyring/signing.key  ← Master encryption key
```

### Can George see my secrets in plaintext?

Only when actively using them for a task. The decrypted value exists in
bash's process memory for the duration of the command, then it's gone.
George never stores plaintext to disk or includes secrets in his journal,
GEORGE.md, or any log.

### What if I forget what secrets I have?

```bash
george> /secret list
# Shows all stored secret names (never values)
```

### Can I back up my vault?

Yes. Copy the entire `~/.george/` directory (includes `.vault/` and
`.keyring/`). Both are needed — the `.enc` files are useless without the
signing key.

```bash
tar czf george-backup.tar.gz ~/.george/.vault ~/.george/.keyring
```

### What if I lose my signing key?

Your secrets are **permanently lost**. AES-256 with a random key cannot be
recovered. Always back up `~/.george/.keyring/signing.key` securely.

### Is this as secure as 1Password / Bitwarden?

No. Those tools use hardware-backed key storage, zero-knowledge
architectures, and extensive auditing. George's vault is a **practical**
encrypted store suitable for development credentials on a personal device.
For production secrets at scale, use a proper secrets manager (Vault, AWS
Secrets Manager, etc.).

### Can multiple users share a vault?

No. The vault is tied to a single signing key. If you need shared secrets,
export them and import them into each user's vault separately.

---

*See also: [SANDBOXES.md](SANDBOXES.md) for project isolation,
[CRYPTO_WALLETS.md](CRYPTO_WALLETS.md) for cryptocurrency wallet
management, [TUNING.md](TUNING.md) for performance tuning.*
