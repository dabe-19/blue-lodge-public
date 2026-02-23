# Email & GitHub Setup

George can have his own email address, SSH key, and GitHub identity.
This lets him push code, open issues, and interact with remote
services under his own account.

---

## Quick Start (Fastest Path)

```
/email setup              # Pick a provider, enter credentials
/email github-setup       # Auto-generates SSH key, configures git
```

That's it. George handles key generation, git identity, and
connection testing automatically. The only manual step is pasting
his public SSH key into GitHub.

---

## Step-by-Step Guide

### 1. Set Up an Email Address

George needs an email to register a GitHub account (or any service).

```
/email setup
```

You'll be prompted to choose a provider:

| # | Provider     | Notes                                      |
|---|-------------|--------------------------------------------|
| 1 | ProtonMail  | Encrypted, private. Requires Bridge app.   |
| 2 | Zoho Mail   | Free tier. Standard SMTP/IMAP.             |
| 3 | Tuta        | Encrypted. No SMTP/IMAP (limited).         |
| 4 | Disposable  | Guerrilla Mail. Temporary, ~60 min expiry. |

**ProtonMail** and **Zoho** are recommended for persistent use (GitHub
registration, notifications). **Disposable** is useful for one-time
signups where you don't care about follow-up email.

You can also pass the provider directly:

```
/email setup protonmail
/email setup zoho
/email setup disposable
```

#### What George Automates
- Creates `~/.george/email.conf` (mode 600)
- Stores password in the secrets vault (`/secret get email_password`)
- For disposable: auto-creates address via Guerrilla Mail API (no input needed)

#### What You Provide
- Email address and password (or app password)
- For ProtonMail: confirm Bridge is installed and running

### 2. Register a GitHub Account

Using the email from step 1, go to [github.com/join](https://github.com/join)
and create an account for George. Use his email address.

> **Tip**: If you just need a throwaway test, use `/email setup disposable`
> to get a temporary address for GitHub's verification email.

### 3. Generate an SSH Key

```
/email ssh-keygen
```

George auto-generates an Ed25519 keypair at `~/.george/.ssh/id_ed25519`.
No passphrase (George is an automated agent). The public key is
printed to your terminal — copy it.

If George already has a key, the command is a no-op and shows the
existing public key path.

### 4. Add the SSH Key to GitHub

1. Go to: **https://github.com/settings/ssh/new**
2. Title: `George (Blue Lodge)`
3. Paste the public key from step 3
4. Click **Add SSH key**

### 5. Full Auto-Setup (Recommended)

Instead of steps 3-4 individually, run:

```
/email github-setup
```

George will:
1. ✓ Verify email is configured
2. ✓ Generate SSH key (if missing)
3. ✓ Set git user.name and user.email
4. ✓ Configure git to use George's SSH key
5. ✓ Test the SSH connection to GitHub

If the SSH test fails (key not yet added to GitHub), George prints
the public key and the URL to add it. After adding it:

```
/email github-test
```

### 6. Verify Everything

```
/email status
```

Shows email provider, address, auth method, SSH key status, and
whether the GitHub connection is working.

---

## Push Behavior

George enforces a **GitHub push guard**:

| Remote Type     | Email Required | SSH Key Required | Behavior        |
|-----------------|:-:|:-:|------------------------------|
| Local git       | No  | No  | Always allowed               |
| Non-GitHub      | No  | No  | Always allowed               |
| GitHub (SSH)    | Yes | Yes | Blocked until configured     |
| GitHub (HTTPS)  | Yes | Yes | Blocked until configured     |

If George tries to `/push` or `/backup github` without email and SSH
configured, he gets a clear error telling him exactly what's missing
and how to fix it:

```
✗ Cannot push to GitHub — George's identity is not configured
  Missing: email address  →  /email setup
  Missing: SSH key        →  /email ssh-keygen

  Run: /email github-setup  (auto-configures everything)
```

**Local git pushes are never blocked.** Only pushes to `github.com`
remotes require the identity gate.

---

## Command Reference

| Command                     | Description                                |
|-----------------------------|--------------------------------------------|
| `/email setup [provider]`   | Configure email interactively              |
| `/email status`             | Show email + SSH status                    |
| `/email send <to> <subj> <body>` | Send an email                        |
| `/email inbox [count]`      | Check inbox                                |
| `/email address`            | Print George's email address               |
| `/email ssh-keygen`         | Generate SSH keypair                       |
| `/email github-setup`       | Full auto-setup (email → SSH → git → test) |
| `/email github-test`        | Test SSH connection to GitHub              |

---

## Secrets & Security

- Email password is stored in the **secrets vault** (`/secret set email_password`)
- SSH private key lives at `~/.george/.ssh/id_ed25519` (mode 600)
- SSH public key at `~/.george/.ssh/id_ed25519.pub` (mode 644)
- Email config at `~/.george/email.conf` (mode 600)
- No credentials ever appear in George's memory or journal

---

## Troubleshooting

**"Cannot push to GitHub"**
→ Run `/email github-setup` and follow the prompts.

**"GitHub SSH authentication failed"**
→ The public key isn't added to GitHub yet. Copy it from
`/email ssh-keygen` output and paste at github.com/settings/ssh/new.

**"No email configured"**
→ Run `/email setup` first.

**ProtonMail Bridge not reachable**
→ Start ProtonMail Bridge (`protonmail-bridge`). It must be running
on localhost:1025 (SMTP) and localhost:1143 (IMAP).
