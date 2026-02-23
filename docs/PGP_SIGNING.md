# PGP Signing Guide

George can **cryptographically sign messages** using PGP (Pretty Good Privacy).
This lets anyone verify that a message was written by *this specific George
instance* — not impersonated, not modified.

---

## Why PGP?

George is a personality — when running on your device, George has opinions,
writes code, and posts to social media. PGP signing provides:

- **Authenticity** — Prove a message came from your George
- **Integrity** — Prove the message wasn't altered after signing
- **Non-repudiation** — The signature is tied to George's private key
- **Identity Differentiation** — Each George instance has its own key pair;
  recipients can distinguish *which* George sent a message

---

## Quick Start

```bash
# 1. Generate George's signing key (one-time)
/pgp generate

# 2. Sign a message
/pgp sign This message was written by George.

# 3. Show the public key (share with others)
/pgp pubkey

# 4. Check status
/pgp status
```

---

## Setup

### Generating the Key

```bash
/pgp generate
```

This creates an **Ed25519** signing key in George's isolated keyring at
`~/.george/.gnupg/`. The key uses:

- **Algorithm**: Ed25519 (elliptic curve — fast, small signatures)
- **No passphrase**: George is an automated agent; interactive passphrase
  entry isn't practical in a scripted environment
- **No expiration**: The key doesn't expire (revoke manually if needed)
- **Identity**: `George (Blue Lodge Agent) <george@blue-lodge.local>`

The public key is automatically exported to `~/.george/george_public.asc`.

### Checking Status

```bash
/pgp status
```

Output:
```
  ── PGP Signing Status ──

  ● GPG:         v2.4.4
  ● Keyring:     /home/user/.george/.gnupg
  ● Key:         ABCD 1234 5678 EFGH
  ● Identity:    George (Blue Lodge Agent) <george@blue-lodge.local>
  ● Public key:  /home/user/.george/george_public.asc (450 bytes)
```

---

## Signing Messages

### Cleartext Signature

The primary signing mode — the original message stays readable, with a
signature block appended:

```bash
/pgp sign Hello, I am George. This message is authentic.
```

Output:
```
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

Hello, I am George. This message is authentic.
-----BEGIN PGP SIGNATURE-----

iHUEARYKAB0WIQTx...
...base64 signature data...
-----END PGP SIGNATURE-----
```

Anyone with George's public key can verify this. The message is readable
without any PGP software — the signature is just appended.

### Sign and Post to Social Media

```bash
# Sign and post to all platforms
/pgp signpost Hello from the cryptographically verified George!

# Sign and post to a specific platform
/pgp signpost mastodon My signed announcement
/pgp signpost discord Verified build notification
```

> **Character limits**: Signed messages are longer than the original text
> (the signature block adds ~200-400 characters). George warns you if the
> signed version exceeds platform limits (X: 280, Bluesky: 300).

### Sign a File

```bash
/pgp signfile ./README.md
```

Creates `./README.md.sig` — a detached signature file.

---

## Verifying Messages

### Verify a Cleartext-Signed Message

```bash
/pgp verify -----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

Hello, I am George.
-----BEGIN PGP SIGNATURE-----
iHUEARYKAB0WIQTx...
-----END PGP SIGNATURE-----
```

Output:
```
 ✓ Signature VALID
   Signed by: George (Blue Lodge Agent)
```

### Verify a File Signature

```bash
# Uses default .sig extension
/pgp verifyfile ./README.md

# Or specify the signature file explicitly
/pgp verifyfile ./README.md ./README.md.custom.sig
```

---

## Public Key Distribution

The whole point of PGP signing is that others can verify George's messages.
For that, they need George's **public key**.

### Export the Public Key

```bash
/pgp export     # Saves to ~/.george/george_public.asc
/pgp pubkey     # Prints the key to the terminal
```

### Ways to Share the Key

1. **Direct file share**: Send `~/.george/george_public.asc` to the
   recipient (email, chat, USB)

2. **Post to social media**: The public key block can be posted to Mastodon,
   Discord, or Telegram (too long for X)

3. **Publish to a website**: Host the `.asc` file at a stable URL

4. **Post the fingerprint**: Share just the fingerprint on social media:
   ```bash
   /pgp fingerprint
   ```
   Outputs something like: `ABCD 1234 5678 EFGH 9012 3456 7890 IJKL MNOP QRST`

5. **Git repository**: Include `george_public.asc` in your project repo

### How Others Verify

Recipients need GPG installed, then:

```bash
# Import George's public key
gpg --import george_public.asc

# Verify a signed message (from a file)
gpg --verify message.txt

# Verify a detached signature
gpg --verify README.md.sig README.md
```

---

## Managing Keys

### View the Fingerprint

```bash
/pgp fingerprint
```

The fingerprint is a unique 40-character hex string that identifies the key.
Share this alongside or instead of the full public key for verification.

### List All Keys in George's Keyring

```bash
/pgp keys
```

Shows both George's own signing key and any imported public keys (from other
Georges or trusted parties).

### Import Someone Else's Key

```bash
/pgp import /path/to/other_george_public.asc
```

After importing, you can verify messages signed by that key.

### Revoke and Regenerate

If George's key is compromised, or you want a fresh identity:

```bash
/pgp revoke
```

This:
1. Deletes the old private and public key
2. Removes the exported public key file
3. Generates a brand-new key pair
4. Exports the new public key

> **Warning**: Anyone using the old public key will no longer be able to
> verify new messages. You'll need to redistribute the new public key.

---

## Technical Details

### Key Storage

- **Private key**: `~/.george/.gnupg/` (mode 700, isolated from system GPG)
- **Public key export**: `~/.george/george_public.asc` (ASCII-armored)
- **System GPG**: Unaffected — George uses `--homedir` to isolate its keyring

### Why Ed25519?

- **Fast**: ~10x faster than RSA-4096 for signing
- **Small**: 64-byte signatures (vs 512 for RSA-4096)
- **Modern**: State-of-the-art elliptic curve, no known weaknesses
- **Mobile-friendly**: Minimal CPU and memory usage on ARM

### Signature Modes

| Mode | Command | Use Case |
|------|---------|----------|
| Cleartext | `/pgp sign <msg>` | Human-readable signed messages |
| Detached | `/pgp signfile <path>` | Sign files without modifying them |
| Sign + Post | `/pgp signpost <msg>` | Signed messages to social media |

### Digest Algorithm

George uses **SHA-512** for the hash digest (set via
`--personal-digest-preferences SHA512`). This is the strongest commonly
available hash algorithm for PGP signatures.

---

## Command Reference

| Command | Description |
|---------|-------------|
| `/pgp generate` | Create George's signing key |
| `/pgp fingerprint` | Show key fingerprint |
| `/pgp sign <msg>` | Sign a message (cleartext) |
| `/pgp verify <msg>` | Verify a signed message |
| `/pgp export` | Export public key to file |
| `/pgp pubkey` | Display the public key |
| `/pgp import <file>` | Import someone's public key |
| `/pgp keys` | List all keys in keyring |
| `/pgp signpost <msg>` | Sign and post to social media |
| `/pgp signfile <path>` | Create detached signature for file |
| `/pgp verifyfile <path>` | Verify a file's signature |
| `/pgp revoke` | Revoke key and regenerate |
| `/pgp status` | Show PGP signing status |

---

## Multiple Georges

In a world where many people run George, PGP creates **cryptographic
individuality**:

- Each George instance generates its own unique key pair
- The public key is like a George's digital DNA — unique and verifiable
- You can import public keys from other Georges to verify their messages
- Trust is established through key exchange, not a central authority

This is the decentralized web of trust that PGP was designed for — now applied
to AI agent identity.
