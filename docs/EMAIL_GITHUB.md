# Email, Git & GitHub Setup

George can own his identity end-to-end: email address, SSH key,
GPG signing key, git configuration, and GitHub account. This guide
covers everything from zero to a fully authenticated, signing-enabled
`git push`.

---

## Zero-to-Push (Fastest Path)

```
/email setup              # Pick a provider, enter credentials
/git setup                # One-shot: SSH + GPG + identity + GitHub test
```

That's the entire operator workflow. George handles key generation,
persistent SSH configuration, GPG commit signing, and git identity
automatically. The only manual steps are:

1. Pasting George's **SSH public key** into GitHub
2. Pasting George's **GPG public key** into GitHub (for verified commits)

Both keys are printed during setup with direct URLs to GitHub's settings pages.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│  ~/.george/                                                  │
│  ├── email.conf              Email provider credentials      │
│  ├── gpg-george.sh           GPG wrapper (sets GNUPGHOME)    │
│  ├── george_public.asc       GPG public key (armored)        │
│  ├── .ssh/                                                   │
│  │   ├── id_ed25519          SSH private key (mode 600)      │
│  │   ├── id_ed25519.pub      SSH public key  (mode 644)      │
│  │   └── config              SSH config (GitHub host entry)  │
│  └── .gnupg/                                                 │
│      └── (keyring files)     Isolated GPG keyring            │
├──────────────────────────────────────────────────────────────┤
│  ~/.password-store/          Pass keychain (Bridge keyring)  │
│  ~/.config/protonmail/       Bridge config, data, cache      │
└──────────────────────────────────────────────────────────────┘

┌───────────────────────┐   ┌───────────────────────┐
│  lib/email.sh         │   │  lib/pgp.sh           │
│  - Email providers    │   │  - GPG key management │
│  - SSH key generation │   │  - Isolated GNUPGHOME │
│  - ProtonMail Bridge  │   │  - Sign / verify      │
│  - GitHub push guard  │   │                       │
└─────────┬─────────────┘   └─────────┬─────────────┘
          │                           │
          └─────────┬─────────────────┘
                    ▼
          ┌─────────────────────┐
          │  lib/git.sh         │
          │  - Git identity     │
          │  - SSH persistence  │
          │  - GPG commit sign  │
          │  - Remote management│
          │  - Full auto-setup  │
          └─────────────────────┘
```

George's SSH and GPG keys live in `~/.george/`, isolated from any
system-level keys. This means George never touches, reads, or
conflicts with the operator's personal keys.

---

## Step 1: Set Up an Email Address

George needs an email to register for services and to use as his
git identity.

```
/email setup
```

Interactive prompt — choose a provider:

| # | Provider     | Best For                           | Persistence |
|---|-------------|------------------------------------|-------------|
| 1 | ProtonMail  | Privacy-first, encrypted           | Permanent   |
| 2 | Gmail       | Easiest setup, Google App Password | Permanent   |
| 3 | Zoho Mail   | Free tier, standard SMTP/IMAP      | Permanent   |
| 4 | Tuta        | Encrypted, no SMTP/IMAP            | Permanent   |
| 5 | Disposable  | Guerrilla Mail, ~60 min expiry     | Temporary   |

Or pass the provider directly:

```
/email setup protonmail
/email setup gmail
/email setup zoho
/email setup disposable
```

**What George automates:**
- Creates `~/.george/email.conf` (mode 600)
- Stores password in the secrets vault (`/secret get email_password`)
- For disposable: generates the address via API (no input needed)

**What the operator provides:**
- Email address and password (or app password)
- For Gmail: a Google App Password (requires 2-Step Verification)
- For ProtonMail: Proton credentials for Bridge login (interactive, with optional 2FA)

> **Recommendation**: Use **Gmail** for the easiest setup, **ProtonMail**
> for maximum privacy, or **Zoho** for a free alternative.
> Use **Disposable** only for throwaway service signups.

### Gmail Setup

Gmail uses standard IMAP/SMTP with Google App Passwords. No extra
software or bridge required — just an email address and app password.

> **Requirement**: 2-Step Verification must be enabled on the Google
> account before you can create an App Password.

#### Steps

1. Enable 2-Step Verification: https://myaccount.google.com/security
2. Create an App Password: https://myaccount.google.com/apppasswords
3. Select "Mail" as the app type and generate a 16-character password
4. Run `/email setup gmail` and enter the address + app password

Gmail SMTP/IMAP settings (auto-configured by George):

| Service | Host             | Port | Security |
|---------|-----------------|------|----------|
| SMTP    | smtp.gmail.com  | 587  | STARTTLS |
| IMAP    | imap.gmail.com  | 993  | SSL/TLS  |

### ProtonMail Bridge Setup

ProtonMail uses end-to-end encryption, so standard IMAP/SMTP access
requires **Proton Mail Bridge** — a local daemon that decrypts messages
on-the-fly and exposes them on localhost ports.

> **Requirement**: A **paid Proton Mail plan** (Mail Plus, Unlimited,
> or Business). Bridge is not available on the free tier.

#### Architecture

```
  Proton servers (encrypted) ──► ProtonMail Bridge (daemon)
                                    │
                              ┌─────┴─────┐
                              │           │
                         SMTP 1025   IMAP 1143
                         (localhost) (localhost)
                              │           │
                          George sends   George reads
                          via curl       via curl
```

The Bridge uses `pass` (password-store.org) as its keychain backend
on headless Linux / Termux. `pass` encrypts secrets with a GPG key —
this is a **separate** key from George's PGP signing identity.

```
~/.password-store/           pass keychain (Bridge uses this)
~/.george/.gnupg/            George's PGP signing key (separate)
~/.config/protonmail/        Bridge config, cache, data
```

#### Full Automated Setup

```
/email bridge setup
```

Walks through 5 steps:

| Step | Action                  | Automated? | What Happens                                 |
|------|------------------------|:----------:|----------------------------------------------|
| 1    | Check dependencies     | ✓          | Verifies `gnupg`, `pass`, `protonmail-bridge` |
| 2    | Initialize pass store  | ✓          | Generates GPG key, runs `pass init`           |
| 3    | Bridge login           | **Manual** | Operator enters Proton credentials + 2FA      |
| 4    | Configure George       | ✓          | Writes `email.conf`, stores bridge password   |
| 5    | Start bridge daemon    | ✓          | Launches bridge in background (noninteractive)|

Step 3 is the only manual step — Proton requires interactive
credential entry and may prompt for 2FA.

#### Step-by-Step (Manual Control)

If you prefer running each step individually:

```bash
# 1. Install dependencies
/email bridge install          # Installs gnupg + pass (apt/pkg)

# 2. Initialize pass keychain
/email bridge init-pass        # Generates GPG key, runs pass init

# 3. Log in to Proton (interactive)
/email bridge login            # Opens Bridge CLI — type: login

# 4. Get bridge password (from Bridge CLI "info" output)
#    Copy the bridge-generated password (NOT your Proton password)

# 5. Configure George's email with bridge credentials
/email bridge configure        # Prompts for address + bridge password

# 6. Start bridge daemon
/email bridge start            # Launches bridge in background

# 7. Verify
/email bridge test             # Tests SMTP through bridge
/email bridge status           # Full health check
```

#### Bridge CLI Login (Step 3 Detail)

When `/email bridge login` opens the Bridge CLI:

```
>>> login
Username: your.proton.email@protonmail.com
Password: ********
Two-factor code: 123456        (if 2FA enabled)

>>> info                        (shows bridge password, ports, etc.)
>>> exit
```

The **bridge password** shown by `info` is auto-generated by Bridge.
It is **not** your Proton account password. Copy it — you'll need it
for `/email bridge configure`.

#### Installing the Bridge Binary

George automates `gnupg` and `pass` installation, but the Bridge
binary itself must be installed by the operator:

| Platform  | Command                                                       |
|-----------|---------------------------------------------------------------|
| Termux    | `pkg install protonmail-bridge`                               |
| Debian    | Download `.deb` from https://proton.me/mail/bridge            |
| Ubuntu    | `sudo dpkg -i protonmail-bridge_*.deb`                        |
| Arch      | `yay -S protonmail-bridge-bin`                                |
| Fedora    | Download `.rpm` from https://proton.me/mail/bridge            |

After installing, run `/email bridge setup` to continue.

#### Bridge Command Reference

| Command                    | Description                                          |
|----------------------------|------------------------------------------------------|
| `/email bridge setup`      | Full guided setup (deps → login → configure → start) |
| `/email bridge install`    | Install dependencies (gnupg, pass)                   |
| `/email bridge init-pass`  | Initialize pass store (GPG key + keychain)           |
| `/email bridge start`      | Start bridge daemon in background                    |
| `/email bridge stop`       | Stop bridge daemon                                   |
| `/email bridge status`     | Full health check (binary, deps, process, ports)     |
| `/email bridge login`      | Interactive Bridge CLI (enter Proton credentials)    |
| `/email bridge configure`  | Set George's email to use bridge SMTP/IMAP           |
| `/email bridge test`       | Test SMTP authentication through bridge              |

#### Bridge Troubleshooting

**"Bridge is not running"**
→ Start it: `/email bridge start`. If it fails, check that you've
logged in at least once: `/email bridge login`.

**"Pass store not initialized"**
→ Run `/email bridge init-pass`. This creates the GPG keychain
that Bridge uses to store credentials.

**"SMTP authentication failed"**
→ The bridge password may have changed. Run `/email bridge login`,
get the new password from `info`, then `/email bridge configure`.

**Bridge exits immediately after start**
→ Run `protonmail-bridge --cli` manually to see error output. Common
causes: no keychain (run `init-pass`), no logged-in account (run `login`).

**"protonmail-bridge not found"**
→ Install the Bridge binary for your platform (see table above).
After installing, verify with: `which protonmail-bridge`

### Verify Email

```
/email status              # Shows provider, address, auth
/email address             # Prints just the address
```

---

## Step 2: Register a GitHub Account

Using the email from step 1, create a GitHub account for George:

1. Go to [github.com/join](https://github.com/join)
2. Use George's email address
3. Username suggestion: `george-blue-lodge` (or similar)

> **Tip**: For throwaway testing, use `/email setup disposable` to get
> a temporary address for GitHub's verification email.

---

## Step 3: Configure Git & GitHub (Auto)

### One-Shot Setup

```
/git setup
```

This single command runs a 7-step automated sequence:

| Step | Action                      | What Happens                                          |
|------|-----------------------------|-------------------------------------------------------|
| 1    | Verify email                | Checks `~/.george/email.conf` exists                  |
| 2    | SSH key generation          | Creates Ed25519 keypair at `~/.george/.ssh/`           |
| 3    | SSH config (persistent)     | Writes `~/.george/.ssh/config` GitHub host entry       |
| 4    | Git SSH configuration       | Sets `core.sshCommand` in global gitconfig             |
| 5    | Git identity                | Sets `user.name` and `user.email` globally             |
| 6    | GPG commit signing          | Generates GPG key, configures `commit.gpgsign = true`  |
| 7    | GitHub SSH test             | Tests `ssh -T git@github.com`                          |

After `/git setup` completes, George prints any manual steps needed
(adding keys to GitHub) with the exact URLs and commands.

### Manual Steps (GitHub Key Upload)

George can generate keys and configure git entirely on his own.
But GitHub requires two browser-based steps that the operator must do:

#### Add SSH Key to GitHub

1. Get George's SSH public key:
   ```
   /git pubkey
   ```
2. Go to **https://github.com/settings/ssh/new**
3. Title: `George (Blue Lodge)`
4. Paste the public key
5. Click **Add SSH key**

#### Add GPG Key to GitHub (for verified commits)

1. Get George's GPG public key:
   ```
   /git gpg-pub
   ```
2. Go to **https://github.com/settings/gpg/new**
3. Paste the entire armored key block (from `-----BEGIN` to `-----END`)
4. Click **Add GPG key**

After both keys are added:

```
/git test                  # Verify SSH connection works
/git status                # Full configuration overview
```

---

## Step 4: Verify the Setup

```
/git status
```

Output:

```
═══ Git Configuration ═══

  ── Identity ──
  Name:   George (Blue Lodge)
  Email:  george@example.com

  ── SSH ──
  Key:    configured
  Type:   Ed25519
  Pub:    ssh-ed25519 George@blue-lodge
  Config: persistent (ssh config)
  Git:    core.sshCommand set

  ── Commit Signing ──
  Status: enabled
  Key:    ABCD 1234 5678 EFGH
  Scope:  commits + tags

  ── Remotes ──
  origin  git@github.com:george-blue-lodge/my-project.git
```

Everything green = George is fully configured and ready.

---

## Authentication Model

George uses a layered authentication strategy that prioritizes
automation while keeping secrets locked down.

### SSH Authentication

George uses **Ed25519 SSH keys** for GitHub authentication:

```
~/.george/.ssh/
├── id_ed25519          Private key (mode 600, never leaves disk)
├── id_ed25519.pub      Public key  (safe to share)
└── config              SSH client configuration
```

**Persistence mechanisms** (triple-layered):

1. **SSH config file** — `~/.george/.ssh/config` with a `Host github.com`
   entry pointing at George's key. Works with any SSH client invocation.

2. **Git config** — `core.sshCommand` in global gitconfig tells git to
   use George's SSH key and config explicitly.

3. **Environment variable** — `GIT_SSH_COMMAND` is set for the current
   session as an immediate-effect fallback.

This means SSH auth survives session restarts, new terminals, and
cron-like automated invocations.

### GPG Commit Signing

George uses his **PGP key** (from `lib/pgp.sh`) to sign every commit
and tag. This proves the commit came from *this specific George instance*.

```
~/.george/
├── .gnupg/             Isolated GPG keyring (never touches system keyring)
└── gpg-george.sh       Wrapper script: sets GNUPGHOME before calling gpg
```

**How it works:**

1. George's GPG key lives in `~/.george/.gnupg/` (separate from system GPG)
2. A wrapper script (`gpg-george.sh`) sets `GNUPGHOME` to George's
   keyring before calling `gpg`
3. Git config `gpg.program` points at this wrapper
4. `commit.gpgsign = true` and `tag.gpgsign = true` are set globally
5. Every `git commit` and `git tag` is automatically signed

When the GPG public key is added to GitHub, commits show as **Verified**
with a green badge.

### No Passphrases

George's keys (SSH and GPG) have **no passphrase**. This is intentional:

- George is an automated agent — interactive passphrase prompts would
  block execution
- Keys are isolated in `~/.george/` with strict file permissions
- The operator controls access to the machine; George trusts the OS
  for access control

### Secrets Storage

| Secret             | Location                          | Protection      |
|--------------------|-----------------------------------|-----------------|
| Email password     | Secrets vault (`/secret`)         | Encrypted store |
| SSH private key    | `~/.george/.ssh/id_ed25519`       | Mode 600        |
| GPG private key    | `~/.george/.gnupg/`               | Mode 700 dir    |
| Email config       | `~/.george/email.conf`            | Mode 600        |

No credentials ever appear in George's memory, journal, or tool output.

---

## Push Guard

George enforces a **GitHub push guard** — automatic protection against
pushing to GitHub without proper authentication configured.

| Remote Type     | Email | SSH Key | Behavior                 |
|-----------------|:-----:|:-------:|--------------------------|
| Local git       | —     | —       | Always allowed           |
| Non-GitHub      | —     | —       | Always allowed           |
| GitHub (any)    | ✓     | ✓       | Blocked until configured |

If George tries to `/push` or `/backup github` without his identity
fully configured:

```
✗ Cannot push to GitHub — run: /git setup
```

The guard auto-configures SSH if keys exist but the session config
isn't set. This means even if the session restarted, a push attempt
will silently re-establish the SSH configuration before proceeding.

**Local git operations are never blocked.** Only pushes to `github.com`
remotes require the identity gate.

---

## Remote Management

George auto-converts HTTPS GitHub URLs to SSH format:

```
/git remote origin https://github.com/user/repo
```

Internally becomes:

```
git@github.com:user/repo.git
```

This ensures all GitHub pushes use SSH authentication instead of
HTTPS (which would require a personal access token).

```
/git remote                        # List all remotes
/git remote origin <url>           # Add or update a remote
/git remote upstream <url>         # Add an upstream remote
```

---

## Command Reference

### `/git` — Git & GitHub Configuration

| Command                      | Description                                      |
|------------------------------|--------------------------------------------------|
| `/git setup`                 | Full auto-setup (SSH + GPG + identity + test)    |
| `/git status`                | Unified configuration overview                   |
| `/git identity [name email]` | Set or show git user.name and user.email         |
| `/git ssh-keygen`            | Generate SSH key + write persistent SSH config   |
| `/git ssh-config`            | Write persistent SSH config entry for GitHub     |
| `/git sign`                  | Enable GPG commit signing                        |
| `/git sign off`              | Disable GPG commit signing                       |
| `/git remote [name] <url>`   | Add/update remote (auto HTTPS→SSH conversion)    |
| `/git test`                  | Test SSH connection to GitHub                    |
| `/git pubkey`                | Display SSH public key                           |
| `/git gpg-pub`               | Display GPG public key (armored)                 |

### `/email` — Email, Bridge & SSH

| Command                     | Description                             |
|-----------------------------|-----------------------------------------|
| `/email setup [provider]`   | Configure email interactively           |
| `/email status`             | Show email + SSH status                 |
| `/email send <to> <s> <b>`  | Send an email                           |
| `/email inbox [count]`      | Check inbox                             |
| `/email address`            | Print George's email address            |
| `/email bridge <action>`    | ProtonMail Bridge management            |
| `/email ssh-keygen`         | Generate SSH keypair (prefer /git)      |
| `/email github-setup`       | Auto-setup (use /git setup instead)     |
| `/email github-test`        | Test SSH (use /git test instead)        |

> **Note**: The `/email ssh-keygen`, `/email github-setup`, and
> `/email github-test` commands still work but `/git` is preferred
> as it also handles GPG signing and persistent SSH config.
>
> For bridge sub-commands, see the **Bridge Command Reference**
> table in the ProtonMail Bridge Setup section above.

---

## For George (Agent Instructions)

When George needs to push code to GitHub and isn't configured yet,
the recommended self-service workflow is:

```
# Check what's configured
/git status

# If nothing is set up, do everything at once
/git setup

# If just SSH is missing
/git ssh-keygen

# If just GPG signing is missing
/git sign

# Before pushing, verify connectivity
/git test
```

George can determine what's needed by reading the output of `/git status`
and running only the missing steps. The `/git setup` command is idempotent
— running it multiple times is safe. It skips steps that are already done.

### Decision Tree for George

```
Need to push to GitHub?
├── /git status → all green? → /push
├── /git status → no SSH key? → /git ssh-keygen → (operator adds to GitHub) → /git test
├── /git status → no signing? → /git sign
├── /git status → no identity? → /git identity "George" "george@example.com"
└── Nothing configured? → /git setup → (operator adds keys to GitHub) → /git test
```

### What George Can Do Autonomously

- Generate SSH and GPG keys
- Configure git identity (name, email)
- Write persistent SSH config
- Enable/disable GPG commit signing
- Add and convert git remotes
- Test GitHub SSH connectivity
- Run the full setup sequence

### What Requires the Operator

- Creating the GitHub account (browser)
- Adding SSH public key to GitHub (browser)
- Adding GPG public key to GitHub (browser)
- Entering email credentials during `/email setup`

---

## Troubleshooting

**"Cannot push to GitHub — run: /git setup"**
→ George's identity isn't configured. Run `/git setup` and
follow the prompts.

**SSH test fails after setup**
→ The SSH public key hasn't been added to GitHub yet.
Run `/git pubkey`, copy the output, paste at
[github.com/settings/ssh/new](https://github.com/settings/ssh/new).

**Commits not showing as "Verified" on GitHub**
→ The GPG public key hasn't been added to GitHub.
Run `/git gpg-pub`, copy the full armored block, paste at
[github.com/settings/gpg/new](https://github.com/settings/gpg/new).

**"No email configured"**
→ Run `/email setup` first. George needs an email for identity.

**"PGP library not loaded"**
→ GPG isn't installed. Fix: `apt install gnupg` or `pkg install gnupg`.

**"SSH key generation failed"**
→ `ssh-keygen` not available. Fix: `apt install openssh-client`.

**ProtonMail Bridge not reachable**
→ Run `/email bridge status` for a full health check. If the bridge
isn't running, start it: `/email bridge start`. If not set up yet,
run `/email bridge setup` for the full guided workflow.

**Remote shows HTTPS URL after adding SSH**
→ Run `/git remote origin <url>` again. HTTPS URLs are auto-converted
to SSH format.

**GPG signing slows down commits**
→ This is normal for the first commit (key cache warming). Subsequent
commits should be fast. If persistently slow, check `gpg-agent` status.

---

## Security Notes

- George's keys are **isolated** from system keys (separate `~/.george/` tree)
- SSH private key permissions: `600` (owner read/write only)
- GPG keyring directory: `700` (owner only)
- No secrets stored in git history, memory, or journal
- The GPG wrapper script (`gpg-george.sh`) prevents accidental use
  of the system keyring
- ProtonMail Bridge password is stored in the secrets vault, never
  in plaintext (falls back to `email.conf` mode 600 if vault unavailable)
- Bridge keychain (pass store) uses its own GPG key, separate from
  George's PGP signing key — compromise of one does not expose the other
- Revoking George's access: delete `~/.george/` and remove keys from GitHub
- Revoking bridge access: `protonmail-bridge --cli` → `logout`, then
  delete `~/.password-store/` and `~/.config/protonmail/`
