# ⌂ George — Blue Lodge Coding Agent

A lightweight, mobile-first coding agent and personal AI assistant powered by local LLMs via Ollama. Meet **George** — named for Brother George Washington, with the wit of Benjamin Franklin and the moral philosophy of Adam Smith. He runs entirely offline, no cloud required.

## Why?

Cloud-based coding agents like Claude Code don't work with small local models. The massive system prompts, streaming protocol mismatches, and token-hungry architectures cause them to hang on 4B parameter models. George replaces all of that with a purpose-built agent that:

- **Calls Ollama directly** — no proxy, no API keys, no internet needed
- **Uses small, focused prompts** — ~1-2K tokens per step, fits in 16K context
- **Persists memory to files** — `CLAUDE.md` for projects, `journal.md` for the agent's living memory
- **Runs entirely in bash** — no Node.js, no Python runtime, no Docker
- **Manages model memory** — automatically loads/unloads the LLM to share 12GB RAM with your builds
- **Handles cancellation gracefully** — Ctrl+C kills the request, unloads the model, returns to the prompt

## Quick Start

```bash
git clone https://github.com/anthropic-research/blue-lodge.git ~/blue-lodge
bash ~/blue-lodge/install.sh
source ~/.bashrc

lodge                              # Interactive mode
lodge /init myapp rust             # Scaffold a Rust project
lodge "add error handling"         # Give it a coding task
lodge /ask "what is a monad?"      # Quick question
```

> **On Android?** See the [Phone Setup Guide](docs/PHONE_SETUP.md) — works directly in Termux (no Ubuntu needed) or optionally with proot-distro Ubuntu.

## Architecture

```
~/blue-lodge/
├── lodge              # Main TUI shell (entry point)
├── update.sh          # Safe update with identity preservation
├── Modelfile          # Ollama model definition (Qwen3-4B Q5_K_M)
├── soul.md            # George's personality & ethical framework
├── journal.md         # George's living memory (auto-managed)
├── SECURITY.md        # Security audit & threat model
├── lib/
│   ├── ui.sh          # TUI rendering (ANSI colors, spinners, prompts)
│   ├── llm.sh         # Ollama API: generate, stream, chat, cancel, unload
│   ├── memory.sh      # CLAUDE.md read/write/compact
│   ├── agent.sh       # Plan → Execute → Memory loop with cancellation
│   ├── tools.sh       # File/shell operations + phone integration
│   ├── commands.sh    # Slash command dispatcher
│   ├── sandbox.sh     # Project isolation (proot/directory)
│   ├── container.sh   # Linux containers via proot-distro
│   ├── journal.sh     # Temporal memory with decay
│   ├── security.sh    # Signing, encryption & integrity engine
│   ├── recall.sh      # FTS5 knowledge base (self-review, search & ingestion)
│   ├── secrets.sh     # Encrypted secrets vault (AES-256-CBC)
│   ├── gsuite.sh      # Google Workspace (Gmail, Drive, Docs)
│   ├── wallet.sh      # Cryptocurrency wallets (BTC, ADA, SOL)
│   ├── api.sh         # REST API client (curl, auth, retry, rate-limit)│   ├── email.sh       # Email providers (Gmail, ProtonMail, Zoho, Tuta, disposable)│   ├── social.sh      # Social media (X, Mastodon, Bluesky, Discord, Telegram)
│   ├── providers.sh   # Cloud AI providers (OpenAI, Anthropic, Google, etc.)
│   ├── web.sh         # Web browsing (fetch, search, summarize, download)
│   └── backup.sh      # Backup/restore identity files
├── commands/
│   ├── init.sh        # /init — scaffold projects
│   ├── fix.sh         # /fix — diagnose & fix errors
│   ├── test.sh        # /test — run tests
│   ├── build.sh       # /build — build project
│   ├── commit.sh      # /commit — AI commit messages
│   ├── push.sh        # /push — push to GitHub
│   └── clone.sh       # /clone — clone + setup repos
├── ~/.george/         # User config & data (created on first run)
│   ├── keys.conf      # API keys (chmod 600)
│   ├── cache/         # Web page cache (1h TTL)
│   ├── cookies/       # Session cookies
│   ├── backups/       # Local identity snapshots
│   ├── backup-repo/   # Git-based backup repository
│   ├── .keyring/      # HMAC signing key (auto-generated)
│   ├── .vault/        # Encrypted secrets (per-secret .enc files)
│   ├── allowlist.conf # User command allowlist extensions
│   ├── sandbox_permissions.conf # Per-sandbox permission overrides
│   ├── recall.db      # FTS5 knowledge index (auto-built)
│   └── discord_channels.db  # Discord channel name→ID registry
└── docs/
    ├── PHONE_SETUP.md           # Android setup guide
    └── examples/
        ├── url-shortener.md     # Python project walkthrough
        ├── rust-task-manager.md # Rust project walkthrough
        └── personal-assistant.md # Using Lodge as a phone assistant
```

## Slash Commands

| Command | Alias | Description |
|---------|-------|-------------|
| `/help` | `lghelp` | Show all commands |
| `/init <name> <type>` | `lgi` | Scaffold project (rust/python/rl/data/automation/notebook/shell) |
| `/fix [file]` | `lgf` | Detect and fix errors |
| `/test [name]` | `lgt` | Run project tests |
| `/build [release]` | `lgb` | Build the project |
| `/commit [files]` | `lgc` | AI-generated commit message |
| `/push [branch]` | `lgp` | Push to GitHub |
| `/clone <repo>` | `lgcl` | Clone + auto-setup a repo |
| `/status` | `lgs` | Show agent + device status |
| `/memory` | `lgm` | Show current CLAUDE.md |
| `/soul` | — | Show agent personality |
| `/journal <cmd>` | — | View/write journal (show/vivid/fading/sediment/write/decay) |
| `/reflect` | — | Record a reflection in journal |
| `/sandbox <cmd>` | `lgx` | Manage sandboxes (list/new/build/rm/cd/clone) |
| `/container <cmd>` | — | Linux containers (list/install/login/exec/pentest) |
| `/api <cmd>` | — | API keys & integration status |
| `/social <cmd>` | — | Social media (X/Mastodon/Bluesky/Discord/Telegram) |
| `/provider <cmd>` | — | Cloud AI (OpenAI/Anthropic/Google/Groq/Mistral...) |
| `/web <cmd>` | — | Browse the web (fetch/search/summary/download) |
| `/github <query>` | — | Search GitHub repositories |
| `/email <cmd>` | — | Email (Gmail/ProtonMail/Zoho/Tuta/disposable) |
| `/git <cmd>` | — | Git & GitHub configuration |
| `/backup <cmd>` | — | Backup & restore George's identity |
| `/security <cmd>` | — | Security, signing & integrity (status/sign/verify/encrypt/decrypt) |
| `/readme [topic]` | — | Review George's own README (capabilities self-knowledge) |
| `/recall <query>` | — | Search George's knowledge base (BM25 full-text search) |
| `/secret <cmd>` | — | Encrypted secrets vault (set/get/delete/list/import/rotate) |
| `/ingest <cmd>` | — | Upload docs to knowledge base (add/summarize/list/remove) |
| `/gsuite <cmd>` | — | Google Workspace (Gmail/Drive/Docs) |
| `/wallet <cmd>` | — | Cryptocurrency wallets (BTC/ADA/SOL) |
| `/phone <cmd>` | — | Termux integration (battery/clip/notify/open/share/toast) |
| `/pgp <cmd>` | — | PGP signing & verification (sign/verify/export/signpost) |
| `/slash <cmd>` | — | Custom commands (list/create/edit/delete/test) |
| `/vitals` | — | System vitals (CPU, RAM, disk, battery, WiFi) |
| `/think` | — | Toggle thinking mode on/off |
| `/soul` | — | Toggle soul mode (full personality injection) |
| `/cleanup` | — | Remove George's created files |
| `/ask <question>` | — | Quick question (no file changes) |
| `/read <file>` | — | Read a file |
| `/files` | — | List workspace files |
| `/compact` | — | Compress memory file |
| `/snapshot` | — | Checkpoint memory |
| `/cd <dir>` | — | Change directory |
| `/clear` | — | Clear screen |
| `/quit` | — | Exit |

## Recall (FTS5 Knowledge Base)

George can search his own documentation and memory using SQLite FTS5 (BM25-ranked full-text search). This gives him self-awareness of his own capabilities without loading the full README into context every time.

### How It Works

On startup, George chunks his knowledge sources by `##` headers and indexes them into an FTS5 database:

| Source | File | Content |
|--------|------|---------|
| `readme` | `README.md` | George's architecture, commands, features |
| `soul` | `soul.md` | Personality, ethics, identity |
| `journal` | `journal.md` | Living memory (reflections, learnings) |
| `claude` | `CLAUDE.md` | Current project memory |

The index auto-rebuilds when any source file changes (mtime tracking). Total overhead: **~100-200KB on disk, <1ms per query, 0 RAM**.

### Commands

```bash
lodge /readme              # George reviews his own capabilities
lodge /readme sandboxes    # Review a specific topic from README
lodge /recall sandboxes    # Search all knowledge sources for "sandboxes"
lodge /recall stats        # Show index statistics
lodge /recall reindex      # Force rebuild the index
lodge /recall clear        # Clear the index
```

### Agent Integration

When George answers a question via `/ask`, the recall system automatically searches for relevant knowledge and injects matching snippets into the system prompt. This means George can accurately describe his own features without hallucinating.

### Why FTS5, Not Vector Embeddings?

George's total corpus is ~40KB (README + soul + journal). At this scale:
- **BM25 keyword search matches or beats vector similarity** for structured docs with clear headers
- **Zero RAM overhead** vs 300MB–1.5GB for an embedding model
- **Sub-millisecond queries** vs ~200ms per vector embed + similarity scan
- **No Python/numpy dependency** — just sqlite3 (usually pre-installed)

If the corpus grows past ~500KB or semantic matching becomes critical, Ollama's `/api/embed` endpoint can be added as an upgrade path.

## Examples

### Coding: Build a project from scratch

```
$ lodge /init shortener python
$ cd shortener
$ lodge "Build a URL shortener API using only stdlib. POST /shorten, GET /<id> redirect, GET /stats."
```

George plans 7 steps, generates all files, and tests them. Full walkthrough: [docs/examples/url-shortener.md](docs/examples/url-shortener.md)

### Coding: Rust CLI tool

```
$ lodge /init tasks rust
$ cd tasks
$ lodge "Build a CLI task manager with add, list, done, remove commands. Use clap."
```

Full walkthrough: [docs/examples/rust-task-manager.md](docs/examples/rust-task-manager.md)

### Personal assistant: Quick questions

```
$ lodge
> What's the time complexity of a hash table lookup?
  Average O(1), worst case O(n).

> /ask Explain the difference between TCP and UDP in 3 sentences

> Write a bash one-liner to find files larger than 100MB
  find ~ -type f -size +100M -exec ls -lh {} \;
```

More examples: [docs/examples/personal-assistant.md](docs/examples/personal-assistant.md)

### Fix cycle

```
$ lodge /build
 ✗ Build failed (exit 1)

$ lodge /fix
 ▸ Running cargo check...
 ◆ Planning fix...
 ✓ Fixed! Build succeeded.
```

### Clipboard bridge (Termux)

```
> /phone clip                    # Paste from phone clipboard
> /ask What does this error mean?
> /phone clip "the answer"       # Copy answer back
```

## Memory System

George uses `CLAUDE.md` files (compatible with the Claude Code convention) as persistent project memory:

- **Per-project**: Each project gets its own `CLAUDE.md` tracking tasks, plans, errors, and key files
- **Global personality**: `soul.md` defines the agent's behavior, ethics, and working style
- **Living journal**: `journal.md` stores the agent's reflections with temporal decay — recent memories are vivid, old ones fade into impressions, the oldest dissolve into character
- **Auto-compact**: Old completed steps are compressed to keep token count low
- **Snapshots**: `/snapshot` saves checkpoints you can roll back to

## Model Memory Management

On a 12GB phone, RAM is shared between Android, Termux, the LLM, and your builds. George manages the model lifecycle automatically:

| Event | Action |
|-------|--------|
| Task starts | Model loaded by Ollama (on-demand) |
| Task completes | Model unloaded (~4GB freed) |
| Ctrl+C pressed | Request killed, model unloaded |
| Session exit | Model unloaded |
| Idle for 5 min | Ollama auto-unloads (configurable) |

Tune with environment variables:

```bash
export LLM_KEEP_ALIVE="0"     # Unload immediately after each request (most aggressive)
export LLM_KEEP_ALIVE="2m"    # 2 minutes (balanced)
export LLM_KEEP_ALIVE="30m"   # 30 minutes (if you have plenty of RAM)
export LLM_TIMEOUT="0"        # No timeout (default — cancel with Ctrl+C)
export LLM_TIMEOUT="1200"     # 20-minute hard timeout
export LLM_MAX_TOKENS="1024"   # Max output tokens per task step (default: 1024)
export LODGE_TERMUX_API=1     # Enable Termux-API features (battery, WiFi, GPS, SMS, etc.)
                              # Default: 0 (disabled — safe for proot & non-Android)
```

## Cancellation

Ctrl+C is always safe:

- **During generation** → kills the HTTP request to Ollama, unloads the model, returns to the REPL
- **Between steps** → stops the task, records progress in CLAUDE.md, returns to the REPL
- **At the prompt** → exits cleanly, unloads the model

All persistence (CLAUDE.md, journal) lives in files, not model state. Unloading the model never loses progress.

## Sandboxes

Lightweight project isolation without Docker. Sandboxes give each project its own directory, environment, and optionally its own permission level — keeping untrusted or experimental code away from your main files.

### How It Works

Blue Lodge sandboxes use a **tiered isolation model** that adapts to what's available on the host:

| Method | Detection | Isolation Level | How |
|--------|-----------|-----------------|-----|
| **proot** | `command -v proot` | Medium | Simulates root, rebinds `/proc` and `/dev` into the sandbox directory. No real root needed. |
| **unshare** | `unshare --user true` | Medium-High | Linux user namespaces — maps the user to UID 0 inside a restricted namespace. |
| **directory** | Always available | Basic | Falls back to plain directory isolation: overrides `$HOME` and `$TMPDIR`, runs in a subshell. |

Detection is automatic (`sandbox_detect()`). On Termux/Android, `proot` is the standard path. On desktop Linux, `unshare` is preferred when available. The directory fallback works everywhere.

### Sandbox Lifecycle

```
~/.lodge-sandboxes/
├── my_app/              # Rust sandbox
│   ├── Cargo.toml
│   ├── src/main.rs
│   ├── tmp/
│   └── .git/
├── scraper/             # Python sandbox (uv or venv)
│   ├── pyproject.toml
│   ├── main.py
│   ├── .venv/
│   └── tmp/
└── experiment/          # Shell sandbox
    ├── run.sh
    └── tmp/
```

Each sandbox is scaffolded by type:

| Type | Scaffolding |
|------|-------------|
| `rust` | `cargo init` + optimized `Cargo.toml` profiles (incremental dev, thin LTO release) |
| `python` | `uv init --app` (preferred) or `python3 -m venv` + `main.py` entrypoint |
| `shell` | `run.sh` with `set -euo pipefail` |

Every sandbox gets a `git init` + initial commit automatically.

### Per-Sandbox Permissions

Each sandbox can override the global `LODGE_PERMISSION` level:

```bash
lodge /security sandbox set untrusted_repo 0   # Ask before everything
lodge /security sandbox set my_app 2            # Auto-approve (trusted)
lodge /security sandbox get my_app              # Check current level
lodge /security sandbox list                    # Show all overrides
```

When `sandbox_exec()` runs a command, it checks `~/.george/sandbox_permissions.conf` for a sandbox-specific level and falls back to the global setting if none is found.

### Commands

```bash
lodge /sandbox new my_app rust    # Create Rust sandbox
lodge /sandbox new scraper python # Create Python sandbox
lodge /sandbox list               # List all sandboxes (name, type, size)
lodge /sandbox cd my_app          # Switch to sandbox directory
lodge /sandbox build my_app       # Build in sandbox (auto-detects toolchain)
lodge /sandbox clone owner/repo   # Clone + setup repo as sandbox
lodge /sandbox rm my_app          # Remove sandbox (confirmation required)
```

## Phone Integration (Termux)

When running in **native Termux** (not proot), George can integrate with your phone.
Termux-API features are **disabled by default** to prevent hangs inside proot or
non-Termux environments. Enable them explicitly:

```bash
export LODGE_TERMUX_API=1    # Add to ~/.bashrc for persistence
```

Then use the phone commands:

```bash
lodge /phone battery    # Check battery level & temperature
lodge /phone clip text  # Set clipboard
lodge /phone clip       # Get clipboard
lodge /phone notify msg # Send notification
lodge /phone open URL   # Open URL in browser
lodge /phone share file # Share a file via Android share sheet
lodge /phone toast msg  # Show toast message
```

## Containers (proot-distro)

George can spin up full Linux environments using [`proot-distro`](https://github.com/termux/proot-distro) — no Docker, no root, no kernel modules required. These are real distro rootfs images running under **proot**: a userspace implementation of `chroot` that intercepts syscalls via `ptrace` to translate paths and fake root privileges.

### How It Works

| Layer | Technology | Role |
|-------|-----------|------|
| **Host** | Termux (Android) or native Linux | Provides the kernel and base environment |
| **Syscall interception** | `proot` (via `ptrace`) | Translates file paths, fakes UID 0, rebinds `/proc`, `/dev`, `/sys` |
| **Rootfs** | `proot-distro` managed tarballs | Full distro filesystem (Ubuntu, Kali, Alpine, etc.) installed to `$PREFIX/var/lib/proot-distro/installed-rootfs/` |
| **Bind mounts** | `--bind $PWD:/workspace` | Shares your current project directory into the container at `/workspace` |

Key characteristics:
- **No real root** — proot fakes it via ptrace. You appear as root inside the container but have only your normal user privileges on the host.
- **Shares the host kernel** — unlike VMs, no separate kernel boots. Containers start instantly.
- **Full package managers** — `apt`, `apk`, `dnf`, `pacman` all work normally inside the container.
- **Filesystem overhead** — each container uses 200MB–4GB depending on distro and installed packages.

### Supported Distros

| Name | Alias(es) | proot-distro ID | Use Case |
|------|-----------|-----------------|----------|
| Ubuntu | `ubuntu`, `ubuntu-lts` | `ubuntu` | General development (default) |
| Alpine | `alpine` | `alpine` | Minimal, fast (~50MB base) |
| Debian | `debian` | `debian` | Stable, broad package support |
| Fedora | `fedora` | `fedora` | Red Hat / RPM ecosystem |
| Kali | `kali`, `nethunter` | `kali-nethunter` | Penetration testing |
| Arch | `arch`, `archlinux` | `archlinux` | Rolling release, AUR |
| Void | `void` | `void` | Lightweight, runit init |
| openSUSE | `opensuse` | `opensuse` | Enterprise Linux |

Aliases are resolved by `_container_resolve_distro()` — you can also pass raw proot-distro IDs for unlisted distros.

### Auto-Setup

When a container is installed, George automatically bootstraps dev tools:

| Distro | Auto-installed |
|--------|----------------|
| Ubuntu/Debian | `build-essential`, `git`, `curl` |
| Kali | `kali-tools-top10`, `git`, `curl` |
| Alpine | `build-base`, `git`, `curl`, `bash` |

### Commands

```bash
lodge /container install ubuntu    # Install Ubuntu container
lodge /container install kali      # Install Kali Nethunter
lodge /container install alpine    # Install Alpine (lightweight)
lodge /container list              # List installed containers
lodge /container login ubuntu      # Interactive shell
lodge /container exec kali nmap -sV target.com  # Run a command
lodge /container here ubuntu make  # Run with current dir at /workspace
lodge /container info ubuntu       # Show container size/details
lodge /container reset ubuntu      # Remove and reinstall from scratch
lodge /container pentest           # One-command Kali + top tools setup
lodge /container rm ubuntu         # Remove a container
```

### Sandboxes vs Containers

| Feature | Sandboxes (`/sandbox`) | Containers (`/container`) |
|---------|----------------------|--------------------------|
| **Purpose** | Project isolation | Full OS environment |
| **Technology** | proot / unshare / directory | proot-distro (full rootfs) |
| **Startup** | Instant | Instant (after install) |
| **Disk usage** | Project files only | 200MB–4GB per distro |
| **Package manager** | Host's (Termux/apt) | Container's own (apt/apk/dnf) |
| **Root simulation** | Optional (proot mode) | Always (appears as root inside) |
| **Security permissions** | Per-sandbox overrides | Host permission system |
| **Best for** | Isolating coding projects | Running tools that need a full Linux distro |

Sandboxes are lightweight wrappers for isolating project directories. Containers are full Linux distributions. Use sandboxes for everyday coding projects; use containers when you need a different distro, system packages, or pentesting tools.

### Pentest Quick-Start

```bash
lodge /container pentest    # Installs Kali + nmap, sqlmap, nikto, hydra, metasploit...
lodge /container login kali # Drop into Kali shell
# Now you have a full pentest toolkit on your phone
```

## Security

George executes LLM-generated code. Security measures include:

- **Permission system** — asks before running destructive commands (default)
- **Command allowlist** — 100+ safe command prefixes auto-approved; user-extensible via `~/.george/allowlist.conf`
- **File write diff preview** — color-coded unified diffs shown before overwriting existing files
- **Workspace sandboxing** — refuses to write files outside the project directory
- **Dangerous command detection** — blocks `rm -rf`, `curl|bash`, reverse shells, `sudo`, etc.
- **Network audit mode** — optional flag to block all network commands from LLM output (`/security network on`)
- **Signed memory files** — HMAC-SHA256 signatures on `soul.md` and `journal.md`, verified at startup
- **Encryption** — AES-256-CBC encryption for George's identity files (bodily autonomy)
- **Per-sandbox permissions** — each sandbox can have its own permission level
- **No network dependency** — everything runs locally, no data leaves the device
- **Graceful cancellation** — Ctrl+C cleanly kills requests and frees resources

Manage security features via `/security status`, `/security check`, `/security sign`, `/security encrypt`, etc.

See [SECURITY.md](SECURITY.md) for the full audit, threat model, and implementation details.

## Secrets Vault

George includes an encrypted key-value store for sensitive credentials — API keys, crypto wallet private keys, OAuth tokens, and anything else that should never exist in plaintext on disk.

```bash
lodge /secret set OPENAI_KEY sk-abc123...     # Store encrypted
lodge /secret get OPENAI_KEY                  # Decrypt to stdout
lodge /secret list                            # Show names only (never values)
lodge /secret delete OPENAI_KEY               # Shred + remove
lodge /secret import ~/.ssh/id_ed25519        # Import a file as a secret
lodge /secret rotate                          # Re-encrypt all with new key
lodge /secret status                          # Vault overview
```

**Under the hood:**
- AES-256-CBC encryption with PBKDF2 (100k iterations)
- Each secret stored as a separate `.enc` file in `~/.george/.vault/`
- Key derived from the security keyring (`~/.george/.keyring/signing.key`)
- `secrets_with` runs commands in a subshell with the secret as an env var — var is gone when the command exits
- `secrets_export_env` outputs shell `export` statements (eval-safe)
- `secrets_rotate_key` re-encrypts all secrets with a freshly generated key
- Plaintext never touches disk; `shred` used where available

## Document Ingestion

Upload any text file, PDF, or document into George's FTS5 knowledge base for semantic search. George can then recall the content when answering questions.

```bash
lodge /ingest add ~/papers/attention.pdf              # Index a PDF
lodge /ingest add ~/notes/meeting.md meeting-notes    # Index with custom label
lodge /ingest summarize ~/papers/long-paper.pdf       # Index + AI summarize
lodge /ingest list                                    # Show ingested documents
lodge /ingest remove meeting-notes                    # Remove a document
```

**Supported formats:**
| Extension | Method |
|-----------|--------|
| `.md`, `.txt`, `.sh`, `.py`, `.rs`, `.js`, `.ts` | Direct read |
| `.pdf` | `pdftotext` (install: `apt install poppler-utils`) |
| `.html` | HTML tag stripping via sed |
| `.doc`, `.docx` | `pandoc` (install: `apt install pandoc`) |

Documents are chunked into ~500-character paragraphs, indexed in SQLite FTS5, and searchable via `/recall <query>`. The `summarize` subcommand also generates an LLM summary as an additional searchable chunk.

## Google Workspace (G-Suite)

Gmail, Google Drive, and Google Docs integration via OAuth2 device authorization flow — no browser redirect needed on mobile.

### Setup

1. Create OAuth2 credentials at [Google Cloud Console](https://console.cloud.google.com/apis/credentials) (type: TV/Limited Input)
2. Enable Gmail, Drive, and Docs APIs
3. Configure George:

```bash
lodge /gsuite setup <client_id> <client_secret>
lodge /gsuite auth                               # Opens device auth flow
```

### Gmail

```bash
lodge /gsuite gmail list                          # List unread emails
lodge /gsuite gmail list "from:alice"             # Search emails
lodge /gsuite gmail read <message_id>             # Read an email
lodge /gsuite gmail send user@example.com "Subject" "Body text"
```

### Google Drive

```bash
lodge /gsuite drive list                          # List recent files
lodge /gsuite drive search "quarterly report"     # Search files
lodge /gsuite drive download <file_id>            # Download a file
lodge /gsuite drive upload ./report.pdf           # Upload a file
```

### Google Docs

```bash
lodge /gsuite docs read <doc_id>                  # Read doc as text
lodge /gsuite docs create "My Document" "Initial content here"
```

Tokens are stored in the secrets vault — no plaintext credentials on disk.

## Cryptocurrency Wallets

George can hold and spend Bitcoin, Cardano, and Solana. Private keys are stored in the encrypted secrets vault. Balance queries use public REST APIs (no local node needed).

### Setup

```bash
# Bitcoin
lodge /wallet btc address bc1q...                 # Set your Bitcoin address
lodge /wallet btc key <WIF_private_key>           # Store private key in vault

# Cardano (requires Blockfrost API key — free at blockfrost.io)
lodge /wallet ada address addr1q...
lodge /wallet ada apikey <blockfrost_project_id>
lodge /wallet ada key <signing_key>

# Solana
lodge /wallet sol address 7xKXtg...
lodge /wallet sol key <keypair_json>
```

### Usage

```bash
lodge /wallet balance                             # Show all wallet balances
lodge /wallet btc balance                         # Bitcoin balance
lodge /wallet ada balance                         # Cardano balance (+ native tokens)
lodge /wallet sol balance                         # Solana balance
lodge /wallet btc send <address> <amount_btc>     # Send BTC (needs bitcoin-cli)
lodge /wallet ada send <address> <amount_ada>     # Send ADA (needs cardano-cli)
lodge /wallet sol send <address> <amount_sol>     # Send SOL (needs solana CLI)
lodge /wallet sol airdrop 1                       # Devnet airdrop (testnet only)
lodge /wallet network testnet                     # Switch to testnet
lodge /wallet status                              # Wallet overview
```

**Architecture:**
| Operation | Method |
|-----------|--------|
| Balance queries | Public REST APIs (mempool.space, Blockfrost, Solana RPC) |
| Transaction history | Public REST APIs |
| Sending | CLI tools (bitcoin-cli/electrum, cardano-cli, solana) |
| Key storage | Encrypted vault (`~/.george/.vault/`) |

## Hardware Targets

| Device | RAM | Status |
|--------|-----|--------|
| Galaxy Fold 7 (Snapdragon 8 Elite) | 12GB | Primary target |
| Galaxy S25 Ultra | 12GB | Supported |
| Chromebooks (ARM) | 8GB+ | Supported |
| Any Linux device | 8GB+ | Supported |
| Raspberry Pi 5 | 8GB | Should work (slower) |

## Model

Ships with **Qwen3-4B-Instruct** (Q5_K_M quantization) via Ollama. ~3GB download, ~4.44GB loaded RAM at the default 16K context window (`num_ctx=16384`).

Swap the model by editing `Modelfile`:

```bash
vim ~/blue-lodge/Modelfile
ollama create blue-lodge -f ~/blue-lodge/Modelfile
```

## REST API & Integrations

George can talk to the outside world via pure-curl REST API calls. All credentials are stored in `~/.george/keys.conf` (created on first run).

### API Key Management

```bash
lodge /api keys set OPENAI_API_KEY sk-...     # Set a key
lodge /api keys list                           # List configured keys
lodge /api keys rm OPENAI_API_KEY              # Remove a key
lodge /api status                              # Show all integration status
```

Or edit directly: `~/.george/keys.conf`

### Social Media

Post, read, search, and interact on five platforms:

```bash
lodge /social post "Hello from George!"              # Post to ALL configured platforms
lodge /social post x "Just shipped a new feature"    # Post to X only
lodge /social x timeline                              # Read X timeline
lodge /social x search "bash scripting"               # Search X
lodge /social mastodon post "Hello fediverse!"        # Post to Mastodon
lodge /social mastodon timeline                       # Read Mastodon home feed
lodge /social bluesky post "Building in public"       # Post to Bluesky
lodge /social discord send "Deploy complete"          # Send to Discord webhook
lodge /social discord send general "Deploy complete"  # Send to a channel by name
lodge /social discord validate                         # Test your bot token
lodge /social discord channels sync                    # Sync channel names from Discord
lodge /social telegram send "Build passed ✓"          # Send to Telegram
lodge /social status                                  # Show which platforms are configured
```

**Supported platforms:** X (Twitter v2), Mastodon (any instance), Bluesky (AT Protocol), Discord (Bot + Webhook), Telegram (Bot API)

### Cloud AI Providers

Route queries to cloud LLMs when you need more power than the local model:

```bash
lodge /provider chat openai "Explain monads"
lodge /provider chat anthropic "Review this code"
lodge /provider chat google "Compare Rust and Go"
lodge /provider chat groq "Quick sort implementation"
lodge /provider models openai                         # List available models
lodge /provider status                                # Show configured providers
```

**Supported providers:** OpenAI, Anthropic, Google AI Studio, Google ADK, Groq, Mistral, Together, Perplexity, Cohere, DeepSeek, xAI (Grok)

### Web Browsing

George can read and search the web:

```bash
lodge /web fetch https://example.com                  # Read page as text
lodge /web search "rust async await tutorial"         # Search the web
lodge /web summary https://blog.example.com/post      # AI-summarize a page
lodge /web links https://example.com                  # Extract all links
lodge /web download https://example.com/file.tar.gz   # Download a file
lodge /web ping https://api.example.com               # Check reachability
```

Search uses Serper.dev (Google results) if `SERPER_API_KEY` is set, Perplexity if configured, or DuckDuckGo HTML scraping as a free fallback. For best rendering, install `w3m`: `apt install w3m`.

## Backup & Persistence

George's code can be updated, but his memories and personality are irreplaceable. The backup system preserves them across repo updates, re-clones, and machine transfers.

### Quick Backup

```bash
lodge /backup local              # Snapshot identity files to ~/.george/backups/
lodge /backup list               # Show all backups
lodge /backup restore            # Restore from most recent backup
lodge /backup export             # Copy .george directory to parent directory (portable)
lodge /backup import <dir>       # Restore from a previously exported .george directory
lodge /backup status             # Show backup system health
```

### GitHub Backup

Push George's identity to a **private** GitHub repo:

```bash
lodge /backup git init           # Create local backup repo
lodge /backup github             # Walk through GitHub setup + push
lodge /backup git pull           # Pull on another machine
lodge /backup git clone <url>    # Set up George from a backup on a new machine
```

### What Gets Backed Up

| File | Purpose |
|------|---------|
| `soul.md` | George's personality & ethical framework |
| `journal.md` | Living memory with temporal decay |
| `Modelfile` | LLM configuration |
| `keys.conf` | API keys (~/.george/keys.conf) |
| `CLAUDE.md` | Per-project memory (collected from all projects) |

## Updating George

Two methods:

### Normal Update (git pull)

```bash
bash ~/blue-lodge/update.sh
```

This automatically:
1. Backs up soul.md, journal.md, Modelfile, and keys.conf
2. Pulls the latest code from git
3. Restores your identity files
4. Rebuilds the Ollama model
5. Verifies all files are valid

### Clean Update (fresh clone)

If things are messy and you want a completely fresh start with the code, but **keep your identity**:

```bash
bash ~/blue-lodge/update.sh --clean
```

This removes the entire repo, clones fresh, and restores your backed-up identity.

### Manual Rebuild

If you prefer doing it by hand:

```bash
# 1. Back up George's identity FIRST
lodge /backup local
# or manually:
cp ~/blue-lodge/soul.md ~/soul.md.bak
cp ~/blue-lodge/journal.md ~/journal.md.bak
cp ~/.george/keys.conf ~/keys.conf.bak

# 2. Remove and re-clone
rm -rf ~/blue-lodge
git clone https://github.com/anthropic-research/blue-lodge.git ~/blue-lodge

# 3. Restore identity
cp ~/soul.md.bak ~/blue-lodge/soul.md
cp ~/journal.md.bak ~/blue-lodge/journal.md
cp ~/keys.conf.bak ~/.george/keys.conf

# 4. Rebuild model + shell
bash ~/blue-lodge/install.sh
source ~/.bashrc

# 5. Verify
lodge /status
lodge /backup status
```

## Phone Setup

Running on Android requires: **F-Droid → Termux → Ubuntu (proot-distro) → Ollama → George**

Full step-by-step guide: **[docs/PHONE_SETUP.md](docs/PHONE_SETUP.md)**

Quick version:

```bash
# 1. Install F-Droid from f-droid.org (NOT Play Store Termux)
# 2. Install Termux + Termux:API from F-Droid
# 3. In Termux:
pkg install proot-distro
proot-distro install ubuntu
proot-distro login ubuntu
# 4. In Ubuntu:
apt install curl git jq
curl -fsSL https://ollama.com/install.sh | sh
ollama serve &
git clone https://github.com/anthropic-research/blue-lodge.git ~/blue-lodge
bash ~/blue-lodge/install.sh
```

## Uninstall

```bash
bash ~/blue-lodge/uninstall.sh
# Optionally: rm -rf ~/blue-lodge
```

## Testing

George includes a comprehensive pure-bash test suite with **~700+ assertions** across 30 test modules. No external test dependencies required.

### Run All Tests

```bash
bash tests/run_all.sh          # Compact output
bash tests/run_all.sh -v       # Verbose — show all assertions
```

### Run Specific Tests

```bash
bash tests/run_all.sh test_ui test_llm    # By module name
bash tests/test_api.sh                     # Run a single file directly
```

### Test Modules

| Module | Tests | Covers |
|--------|-------|--------|
| `test_agent.sh` | 10 | Agent loop, config, cancellation |
| `test_api.sh` | 33 | REST client, keys, JSON, auth headers |
| `test_backup.sh` | 46 | Local/git backup, restore, pruning, export/import |
| `test_commands.sh` | 36 | Slash command registration, dispatch, memory loop catalog |
| `test_container.sh` | 28 | Container management, distro resolution |
| `test_journal.sh` | 21 | Temporal memory, decay, greetings |
| `test_llm.sh` | 23 | LLM config, token estimation, cancellation |
| `test_lodge.sh` | 38 | Main script, command wiring, soul toggle, REPL heuristic |
| `test_memory.sh` | 30 | CLAUDE.md sections, compaction, snapshots, soul toggle |
| `test_providers.sh` | 32 | 10 AI providers, dispatcher, aliases |
| `test_sandbox.sh` | 15 | Sandbox lifecycle, build, remove |
| `test_email.sh` | 65 | Gmail/ProtonMail/Zoho/Tuta providers, SMTP/IMAP, bridge |
| `test_social.sh` | 57 | 5 platforms, Discord channels, post/send dispatch |
| `test_tools.sh` | 28 | Code extraction, file ops, safety checks |
| `test_security.sh` | 55 | Allowlist, signing, encryption, sandboxes |
| `test_recall.sh` | 30 | FTS5 indexing, search, self-review |
| `test_secrets.sh` | 30 | Vault encrypt/decrypt, rotate, import, export |
| `test_gsuite.sh` | 28 | OAuth2, Gmail/Drive/Docs, input validation |
| `test_wallet.sh` | 35 | BTC/ADA/SOL wallets, network toggle, send validation |
| `test_ui.sh` | 39 | Colors, print functions, markdown rendering |
| `test_web.sh` | 29 | Web fetch, HTML parsing, DDG search, cache |

### Writing Tests

Tests use a custom framework (`tests/framework.sh`) with no external dependencies:

```bash
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/your_module.sh"

test_start "Module Name"

describe "function_name"
  it "should do something" && {
    result=$(your_function "input")
    assert_eq "$result" "expected"
  }

test_end
```

**Available assertions:** `assert_eq`, `assert_neq`, `assert_contains`, `assert_not_contains`, `assert_match`, `assert_ok`, `assert_fail`, `assert_file_exists`, `assert_file_not_exists`, `assert_dir_exists`, `assert_empty`, `assert_not_empty`, `assert_gt`

**Helpers:** `test_tmpdir` (isolated temp directory), `test_mock`/`test_unmock` (function mocking), `skip` (skip a test with reason)

> **Note:** Test bodies in `it` blocks run at top-level scope (not inside a function). Do not use `local` inside `it` blocks — use plain variable assignment instead.

## License

MIT