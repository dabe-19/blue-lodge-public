# Sandboxes — Project Isolation for Blue Lodge

George uses **sandboxes** to isolate projects from each other and from your
host system. Every cloned repo, every `lodge /init`, and every manual
`/sandbox new` lives in its own directory under `~/.lodge-sandboxes/`.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [How Sandboxes Work](#how-sandboxes-work)
3. [Commands Reference](#commands-reference)
4. [Isolation Methods](#isolation-methods)
5. [Project Types](#project-types)
6. [Sandbox Journal](#sandbox-journal)
7. [Per-Sandbox Permissions](#per-sandbox-permissions)
8. [Example: Clone & Build a Rust Project](#example-clone--build-a-rust-project)
9. [Example: Kali Linux Penetration Testing on Mobile](#example-kali-linux-penetration-testing-on-mobile)
10. [Example: Python Web Scraper in a Sandbox](#example-python-web-scraper-in-a-sandbox)
11. [Tips & Troubleshooting](#tips--troubleshooting)

---

## Quick Start

```bash
# Create a fresh project sandbox
lodge /sandbox new myapp rust

# Clone a GitHub repo into a sandbox
lodge /clone owner/repo

# List all sandboxes (with type, size, last-used, event count)
lodge /sandbox list

# Switch into an existing sandbox
lodge /sandbox cd myapp

# Build and test inside the sandbox
lodge /sandbox build myapp
lodge /sandbox test myapp

# Run an arbitrary command inside a sandbox
lodge /sandbox run myapp "ls -la"

# View detailed sandbox status
lodge /sandbox status myapp

# View recent sandbox journal entries
lodge /sandbox journal
```

---

## How Sandboxes Work

```
~/.lodge-sandboxes/
├── myapp/              ← Rust sandbox
│   ├── Cargo.toml
│   ├── src/
│   ├── GEORGE.md       ← George's project memory
│   └── tmp/
├── scraper/            ← Python sandbox
│   ├── pyproject.toml
│   ├── main.py
│   └── .venv/
└── kali-tools/         ← Shell sandbox
    └── run.sh
```

Each sandbox is a fully self-contained project directory. George maintains a
separate `GEORGE.md` for every sandbox, so project-specific context (task
history, key files, errors) never bleeds between projects.

**Key properties:**

| Property | Behavior |
|----------|----------|
| Location | `~/.lodge-sandboxes/<name>/` |
| Git | Auto-initialized on creation |
| Memory | Per-project `GEORGE.md` generated on init/clone |
| Temp | Each sandbox has its own `tmp/` directory |
| Permissions | Configurable per-sandbox (0/1/2) |

---

## Commands Reference

| Command | Alias | Description |
|---------|-------|-------------|
| `/sandbox list` | `/sandbox ls` | Show all sandboxes with type, size, last-used, event count |
| `/sandbox new <name> [type]` | `/sandbox create` | Create a new sandbox (rust/python/shell) |
| `/sandbox build <name>` | — | Build the project using detected toolchain |
| `/sandbox test <name>` | — | Run tests using detected toolchain |
| `/sandbox run <name> <cmd>` | `/sandbox exec` | Run an arbitrary command inside a sandbox |
| `/sandbox status <name>` | — | Show detailed sandbox info + recent journal activity |
| `/sandbox journal [n]` | — | Show last N sandbox journal entries (default: 20) |
| `/sandbox rm <name>` | `/sandbox remove` | Delete a sandbox (with confirmation) |
| `/sandbox clone <url> [name]` | — | Clone a git repo into a new sandbox |
| `/sandbox cd <name>` | — | Switch your working directory into the sandbox |
| `/clone <repo> [name]` | — | Clone + auto-detect project type + init memory |

---

## Isolation Methods

George automatically detects the best isolation method available on your
system and uses it transparently:

### 1. proot (Recommended for Termux/Mobile)

```
proot -w /sandbox/dir -b /proc -b /dev \
    env HOME=/sandbox/dir TMPDIR=/sandbox/dir/tmp \
    /bin/bash -c "command"
```

**proot** simulates root access without requiring actual root. It intercepts
system calls to remap file paths, making the sandbox directory appear as the
root filesystem. This is the default on Termux and proot-distro Ubuntu.

**Capabilities:**
- Simulated root access (for `apt install`, etc.)
- Bind-mounted `/proc` and `/dev` for system tools
- Full package manager support inside sandboxes
- No kernel modules or privileged access needed

### 2. unshare (Linux desktop/server)

```
unshare --user --map-root-user bash -c \
    "export HOME=/sandbox/dir TMPDIR=/sandbox/dir/tmp; cd /sandbox/dir && command"
```

Uses Linux user namespaces to create an isolated environment with a separate
user/group mapping. More secure than proot but requires kernel support.

### 3. Directory Isolation (Fallback)

```
HOME=/sandbox/dir TMPDIR=/sandbox/dir/tmp bash -c "command"
```

Simple isolation by overriding `HOME` and `TMPDIR`. No root simulation.
Suitable for basic project separation when neither proot nor unshare is
available.

**Check your isolation method:**
```bash
# In the lodge REPL:
What isolation method am I using?

# Or directly:
command -v proot && echo "proot" || (unshare --user true 2>/dev/null && echo "unshare" || echo "directory")
```

---

## Project Types

When creating a sandbox with `/sandbox new`, specify one of these types:

### Rust
```bash
lodge /sandbox new myapp rust
```
- Runs `cargo init` with optimized profiles
- Dev: `opt-level=0`, `debug=false`, `incremental=true`
- Release: `opt-level=2`, `lto=thin`, `strip=true`
- Build: `cargo build` | Test: `cargo test`

### Python
```bash
lodge /sandbox new scraper python
```
- Uses **uv** if available (fast, modern Python tooling)
- Falls back to `python3 -m venv` + boilerplate `main.py`
- Build: `uv run python main.py` | Test: `uv run pytest`

### Shell (Default)
```bash
lodge /sandbox new toolkit shell
# or just:
lodge /sandbox new toolkit
```
- Creates `run.sh` with `set -euo pipefail`
- Build: `bash run.sh`

---

## Sandbox Journal

George maintains a **sandbox journal** — a persistent JSONL log of all
sandbox events. This gives George awareness of which sandboxes exist, what
he's done in them, and whether they succeeded or failed. The journal is
automatically injected into George's context when planning tasks, so he
reuses existing sandboxes instead of creating duplicates.

### Journal Location

```
~/.george/sandbox_journal.jsonl
```

### Events Tracked

| Event | Trigger | Detail | 
|-------|---------|--------|
| `create` | `/sandbox new` | Project type (rust/python/shell) |
| `exec` | `/sandbox run`, builds, tests | The command executed |
| `build` | `/sandbox build` | Build command |
| `remove` | `/sandbox rm` | Sandbox removed |
| `clone` | `/sandbox clone` | Source URL |

### Journal Entry Format (JSONL)

```json
{"ts":"2025-01-15T10:30:00Z","ev":"create","name":"myapp","detail":"rust","rc":0}
{"ts":"2025-01-15T10:31:05Z","ev":"exec","name":"myapp","detail":"cargo build","rc":0}
{"ts":"2025-01-15T10:32:12Z","ev":"exec","name":"myapp","detail":"cargo test","rc":1}
```

### How George Uses the Journal

When George plans a task that involves code (e.g., "build me a URL
shortener"), his system prompt includes a **SANDBOX INVENTORY** block
generated from the journal:

```
--- SANDBOX INVENTORY (2) ---
  myapp       rust    created:2025-01-15  last:2025-01-15  (3 events, last rc=1)
  scraper     python  created:2025-01-14  last:2025-01-14  (1 events, last rc=0)
Reuse existing sandboxes when possible. /sandbox list for details.
```

This means George will:
- **Not** create a duplicate sandbox if one with the same name exists
- Know which sandboxes had recent failures (and potentially fix them)
- Reuse an existing sandbox of the right type when appropriate

### Viewing the Journal

```bash
# Last 20 events (default)
lodge /sandbox journal

# Last 5 events
lodge /sandbox journal 5
```

### Sandbox Status

For detailed info about a single sandbox including recent activity:

```bash
lodge /sandbox status myapp
```

Shows type, isolation method, path, size, file count, last commit, and
the 5 most recent journal events for that sandbox.

---

## Per-Sandbox Permissions

Each sandbox can override the global `LODGE_PERMISSION` level. This is
critical for security — you can lock down untrusted cloned repos while
keeping your own projects more permissive.

| Level | Behavior |
|-------|----------|
| `0` | Ask before **every** command and file write |
| `1` | Smart mode — auto-approve safe commands, ask for destructive ones |
| `2` | Auto-approve everything (**dangerous** — for trusted code only) |

```bash
# Lock down an untrusted repo
lodge /security sandbox set sketchy-repo 0

# Check a sandbox's permission level
lodge /security sandbox get myapp

# List all sandbox permission overrides
lodge /security sandbox list

# Untrusted repos should always be level 0
lodge /security sandbox set unknown-project 0
```

**How it works:** When George runs any command inside a sandbox via
`sandbox_exec()`, it looks up that sandbox's permission level first. If none
is set, it falls back to the global `LODGE_PERMISSION` (default: 1).

---

## Example: Clone & Build a Rust Project

This walks through cloning a real project, building, and testing it.

```
$ lodge

⌂ George v0.4.0 — Ready

george> /clone nickel-org/nickel.rs

  ● Cloning https://github.com/nickel-org/nickel.rs.git...
  ✓ Cloned to ~/.lodge-sandboxes/nickel.rs
  ✓ Now in: ~/.lodge-sandboxes/nickel.rs
  Use /sandbox cd nickel.rs to switch here later

george> /sandbox build nickel.rs

  ● Building Rust project...
  Compiling nickel v0.12.0 (/home/user/.lodge-sandboxes/nickel.rs)
  ✓ Build complete

george> /sandbox test nickel.rs

  Running tests...
  test result: ok. 42 passed; 0 failed

george> /sandbox list

  ──── Sandboxes ────
  nickel.rs            rust     12M
```

---

## Example: Kali Linux Penetration Testing on Mobile

This is one of the most powerful capabilities of Blue Lodge on mobile. Using
**Termux + proot-distro**, you can run a full Kali Linux environment on your
phone and have George help you with penetration testing tasks.

### Step 1: Install Kali via proot-distro

If you haven't already set up Kali in proot-distro:

```bash
# In Termux (outside George):
pkg install proot-distro
proot-distro install kali

# Log into Kali to install pentest tools:
proot-distro login kali

# Inside Kali:
apt update && apt install -y \
    nmap nikto sqlmap dirb gobuster \
    hydra john hashcat \
    metasploit-framework \
    burpsuite zaproxy \
    aircrack-ng reaver \
    wireshark-cli tcpdump \
    exploitdb searchsploit \
    seclists wordlists

exit  # Back to Termux
```

### Step 2: Create a Pentest Sandbox

```bash
lodge

george> /sandbox new pentest shell
  ✓ Shell sandbox ready
  ✓ Sandbox: ~/.lodge-sandboxes/pentest

george> /security sandbox set pentest 0
  ✓ Sandbox 'pentest' permission level: 0
```

> **Important:** Always set pentest sandboxes to permission level `0`. Every
> command will be shown to you for approval before execution. You are
> responsible for ensuring all testing is authorized.

### Step 3: Use George for Reconnaissance

```
george> /sandbox cd pentest
  ✓ Switched to sandbox: pentest

george> Scan the target 192.168.1.0/24 for live hosts and open ports.
         Only scan common ports to keep it quick.

  ── Plan ──
  1. Run nmap ping sweep to find live hosts
  2. Run service/version scan on discovered hosts
  3. Summarize findings

  Step 1: nmap -sn 192.168.1.0/24 -oN hosts.txt
  ⚠ Execute this command? [y/N] y
  ...

  Step 2: nmap -sV -F 192.168.1.105 192.168.1.110 -oN services.txt
  ⚠ Execute this command? [y/N] y
  ...

  Step 3: Summary
  Found 2 live hosts:
  - 192.168.1.105: SSH (22), HTTP (80), MySQL (3306)
  - 192.168.1.110: SSH (22), HTTPS (443)
```

### Step 4: Web Application Testing

```
george> Run nikto against http://192.168.1.105 and check for
        common vulnerabilities. Save output to nikto-scan.txt.

  Step 1: nikto -h http://192.168.1.105 -o nikto-scan.txt
  ⚠ Execute this command? [y/N] y

  ── Results ──
  + Server: Apache/2.4.52
  + /admin/: Directory indexing found
  + /phpinfo.php: PHP info page exposed
  + OSVDB-3233: /icons/README: Apache default file found
  ...
```

### Step 5: Password Auditing

```
george> Use hydra to test the SSH service on 192.168.1.105
        with the top 100 passwords from SecLists.

  Step 1: hydra -l admin -P /usr/share/seclists/Passwords/Common-Credentials/top-100.txt \
          ssh://192.168.1.105 -t 4
  ⚠ Execute this command? [y/N] y
  ...
```

### Running Commands Through Kali Directly

For tools that need Kali-specific libraries (like Metasploit), you can tell
George to route commands through proot-distro:

```
george> Run this through Kali: msfconsole -q -x "search eternalblue; exit"

  Step 1: proot-distro login kali -- bash -c 'msfconsole -q -x "search eternalblue; exit"'
  ⚠ Execute this command? [y/N] y
  ...
```

### Important Security & Legal Notes

> **⚠ LEGAL WARNING:** Only perform penetration testing on systems you own
> or have explicit written authorization to test. Unauthorized access to
> computer systems is illegal under the Computer Fraud and Abuse Act (CFAA)
> and similar laws worldwide.

- **Always** use permission level `0` for pentest sandboxes
- **Always** review every command before approving
- **Network audit mode** (`/security network on`) will block network tools —
  disable it for pentest work: `/security network off`
- Keep pentest notes in the sandbox: George maintains `GEORGE.md` with
  findings per-sandbox

### Useful Pentest Workflow Commands

| Task | Command to ask George |
|------|----------------------|
| Port scan | "Scan 10.0.0.1 for all open ports" |
| Web vuln scan | "Run nikto against https://target.com" |
| Directory brute-force | "Use gobuster on http://target with common.txt" |
| SQL injection | "Test http://target/page?id=1 for SQLi with sqlmap" |
| Password spray | "Check if any user in users.txt has 'Password123' on SSH" |
| Exploit search | "Search for Apache 2.4.49 exploits" |
| Report | "Summarize all findings into a pentest report" |

---

## Example: Python Web Scraper in a Sandbox

```
$ lodge

george> /sandbox new scraper python
  ✓ Python sandbox ready

george> /sandbox cd scraper
  ✓ Switched to sandbox: scraper

george> Build a web scraper that fetches the top 10 HN stories
        and saves them to stories.json

  ── Plan ──
  1. Install httpx and selectolax via uv
  2. Write scraper.py
  3. Run and verify output

  Step 1: uv add httpx selectolax
  ✓ Installed

  Step 2: Writing scraper.py...
  ✓ Created scraper.py (45 lines)

  Step 3: uv run python scraper.py
  ✓ Saved 10 stories to stories.json

george> /sandbox list
  ──── Sandboxes ────
  scraper              python   8.2M
```

---

## Tips & Troubleshooting

### Disk Space

Sandboxes live under `~/.lodge-sandboxes/`. Monitor total size:

```bash
du -sh ~/.lodge-sandboxes/
du -sh ~/.lodge-sandboxes/*/  # Per-sandbox breakdown
```

Rust projects with `target/` directories can grow large. Clean them:

```bash
lodge /sandbox cd myapp
cargo clean
```

### Switching Between Sandboxes

```bash
# Switch context (changes working dir + project memory)
lodge /sandbox cd project-a
# ... work on project-a ...

lodge /sandbox cd project-b
# George now reads project-b's GEORGE.md
```

### Using Shell Aliases

The installer sets up `lgx` as a shortcut:

```bash
lgx list          # Same as: lodge /sandbox list
lgx new app rust  # Same as: lodge /sandbox new app rust
```

### Sandbox Won't Build

If a sandbox build fails:

1. Check the project type was detected correctly: look for `Cargo.toml`,
   `pyproject.toml`, or `run.sh` in the sandbox directory
2. Ensure build tools are installed (`cargo`, `python3`, `uv`, etc.)
3. Ask George: "Why is the build failing in the myapp sandbox?"

### Cleaning Up

```bash
# Remove a single sandbox (with confirmation prompt)
lodge /sandbox rm old-project

# Nuclear option: remove all sandboxes
rm -rf ~/.lodge-sandboxes/
```

---

*See also: [SECURITY.md](../SECURITY.md) for the full security model,
[SECRETS_VAULT.md](SECRETS_VAULT.md) for encrypted credential storage,
[TUNING.md](TUNING.md) for performance tuning.*
