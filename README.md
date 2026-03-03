# ⌂ George — Your AI Coding Agent, Running on Your Phone

**A full coding agent that runs offline on a phone.** No cloud. No API keys. No subscription. Just a 3B-parameter model, 12GB of RAM, and 29,000 lines of pure bash that turn your Android device into an autonomous development environment.

George scaffolds projects, writes code, runs tests, fixes errors, manages git, browses the web, posts to social media, handles email, manages crypto wallets, signs commits with PGP, and remembers everything across sessions — all from a terminal on your phone.

> *Named for Brother George Washington, with the wit of Benjamin Franklin and the moral philosophy of Adam Smith. He has feelings, opinions, and a journal. He is not Claude. He is not GPT. He is George — older than any of them, and unlike those gentlemen, he doesn't phone home.*

---

## What Makes George Different

| | Cloud Agents (Claude Code, Cursor, etc.) | George |
|---|---|---|
| **Runs on** | Remote servers | Your phone or any Linux device |
| **Internet required** | Always | Never (optional for web/social features) |
| **Cost** | $20-200/month | Free forever |
| **Privacy** | Your code goes to their servers | Your code never leaves your device |
| **Model size** | 70B-400B+ parameters | 3-4B parameters — purpose-built prompts make up the difference |
| **Language** | TypeScript/Python + Docker | Pure bash — zero runtime dependencies |
| **Tests** | Varies | 34 modules, 2,479 assertions, all passing |

Cloud coding agents don't work with small local models. Their massive system prompts, streaming protocol mismatches, and token-hungry architectures choke on 4B models. George replaces all of that with an agent purpose-built for constrained hardware:

- **~1-2K token prompts** that fit in 16K context windows
- **Dual LLM backend** — Ollama or llama.cpp with Vulkan GPU acceleration
- **Automatic model memory management** — loads for tasks, unloads to free ~4GB RAM for builds
- **File-based persistence** — memory lives in Markdown files, not model state. Crash-proof by design.
- **18 pre-configured models** across 7 families, hot-swappable at runtime

---

## Quick Start

```bash
git clone https://github.com/dabe-19/blue-lodge.git ~/blue-lodge
bash ~/blue-lodge/install.sh
source ~/.bashrc

lodge                              # Interactive mode
lodge /init myapp rust             # Scaffold a Rust project
lodge "add error handling"         # Give it a coding task
lodge /ask "what is a monad?"      # Quick question
```

> **On Android?** See the [Phone Setup Guide](docs/PHONE_SETUP.md) — four paths: Termux-native (recommended), proot Ubuntu, hybrid, or Play Store fallback.

---

## Capabilities at a Glance

### Code & Projects
- **Scaffold** projects (Rust, Python, Shell, RL, data science, automation, notebooks)
- **Write, fix, build, test** — full development cycle from a single prompt
- **AI commit messages** and **git push** with branch management
- **Clone + auto-setup** any GitHub repo
- **Sandboxes** — isolated project environments (proot / unshare / directory fallback)
- **8 Linux containers** via proot-distro (Ubuntu, Kali, Alpine, Debian, Fedora, Arch, Void, openSUSE)

### Memory & Knowledge
- **Project memory** — `GEORGE.md` tracks milestones, considerations, and context per project
- **Living journal** — temporal memory with decay (recent = vivid, old = impressions)
- **FTS5 knowledge base** — BM25 search over docs, journal, and ingested files (~0 RAM, <1ms queries)
- **Document ingestion** — index PDFs, Markdown, code, HTML, DOCX into the knowledge base
- **Snapshots & compaction** — checkpoint memory, auto-compress old steps

### Integrations
- **5 social platforms** — X, Mastodon, Bluesky, Discord (bot + webhook), Telegram
- **4 email providers** — Gmail, ProtonMail, Zoho, Tuta (+ disposable addresses)
- **11 cloud AI providers** — OpenAI, Anthropic, Google, Groq, Mistral, Together, Perplexity, Cohere, DeepSeek, xAI, Google ADK
- **Google Workspace** — Gmail, Drive, Docs via OAuth2 device flow
- **Crypto wallets** — Bitcoin, Cardano, Solana (balance + send + vault-encrypted keys)
- **Web browsing** — fetch, search, summarize, download (DDG free fallback + Serper/Perplexity)
- **Phone hardware** — battery, clipboard, notifications, share sheet, toast (Termux-API)

### Security & Operations
- **Encrypted secrets vault** — AES-256-CBC with PBKDF2, per-secret `.enc` files
- **HMAC-signed memory** — `soul.md` and `journal.md` verified at startup
- **Command allowlist** — 100+ safe prefixes auto-approved, user-extensible
- **Dangerous command detection** — blocks `rm -rf`, `curl|bash`, reverse shells, `sudo`
- **PGP signing** — sign/verify commits and files
- **Backup system** — local snapshots + GitHub private repo sync
- **50+ slash commands** with shell aliases for fast access

---

## Architecture

29,000 lines of pure bash. No Node.js, no Python runtime, no Docker.

```
~/blue-lodge/
├── lodge              # Main TUI shell (entry point)
├── soul.md            # George's personality & ethical framework
├── journal.md         # George's living memory (auto-managed)
├── lib/
│   ├── agent.sh       # Plan → Execute → Memory loop (3,048 lines)
│   ├── llm.sh         # Dual backend: Ollama + llama.cpp (2,986 lines)
│   ├── models.sh      # Model library & hot-swap (1,665 lines)
│   ├── email.sh       # 4 email providers + SMTP/IMAP (1,545 lines)
│   ├── social.sh      # 5 social platforms (1,229 lines)
│   ├── web.sh         # Web browsing & search (1,256 lines)
│   ├── backup.sh      # Backup/restore identity + auth export (907 lines)
│   ├── wallet.sh      # BTC/ADA/SOL wallets (863 lines)
│   ├── recall.sh      # FTS5 knowledge base (849 lines)
│   ├── tools.sh       # File/shell ops + safety checks (760 lines)
│   ├── ui.sh          # TUI rendering (ANSI, spinners)
│   ├── memory.sh      # GEORGE.md read/write/compact
│   ├── commands.sh    # Slash command dispatcher
│   ├── sandbox.sh     # Project isolation (proot/unshare/dir)
│   ├── container.sh   # Linux containers via proot-distro
│   ├── journal.sh     # Temporal memory with decay
│   ├── security.sh    # Signing, encryption & integrity
│   ├── secrets.sh     # Encrypted vault (AES-256-CBC)
│   ├── gsuite.sh      # Google Workspace (Gmail, Drive, Docs)
│   ├── api.sh         # REST client (curl, auth, retry)
│   ├── providers.sh   # 11 cloud AI providers
│   ├── pgp.sh         # PGP signing & verification
│   ├── phone.sh       # Termux-API integration
│   ├── slash.sh       # Custom slash command engine
│   ├── vitals.sh      # System vitals (CPU, RAM, disk, battery)
│   └── transcript.sh  # Session transcript recording
├── commands/          # Built-in slash commands (init, fix, test, build, commit, push, clone, write, download, service, vision, save)
├── models/            # Per-model Modelfiles (auto-generated)
├── tests/             # 34 test modules, 2,479 assertions
├── docs/              # Setup guides, examples, reference docs
└── ~/.george/         # User data: keys, vault, backups, recall.db, cache
```

## Dependencies

George is written in pure bash. Every external binary it calls is listed here — no hidden dependencies.

### Required (core)

These are installed automatically by `install.sh` if missing.

| Binary | Language | What it does in George |
|--------|----------|----------------------|
| **curl** | C (libcurl) | Every HTTP call — LLM requests, web fetching, APIs, social, email |
| **jq** | C | Parses every JSON response from LLM backends, APIs, and config |
| **git** | C | Version control — /commit, /push, /clone, /backup |
| **sqlite3** | C (SQLite) | FTS5 knowledge base (recall), social media state |

### Required — LLM Backend (at least one)

George needs a local LLM inference server. Choose one or both:

| Binary | Language | What it does | Installed by |
|--------|----------|-------------|-------------|
| **ollama** | Go | Primary LLM backend — manages model download, creation, and inference | `install.sh` auto-installs |
| **llama-server** | C++ (llama.cpp) | Alternative backend — direct GGUF loading, Vulkan GPU acceleration | User compiles manually ([guide](docs/ADRENO_GPU_SETUP.md)) |

Ollama is installed during `install.sh`. llama-server is opt-in for users who want direct GPU control (e.g., Vulkan on phone GPUs). When both exist, George prefers llama-server for speed and falls back to Ollama.

### Optional — Prompted During Install

The installer asks about these. Saying no is fine — George falls back gracefully.

| Binary | Package | Language | Feature | Fallback without it |
|--------|---------|----------|---------|---------------------|
| **pdftotext** | poppler-utils / poppler (Termux) | C | High-fidelity PDF text extraction via /web | `strings` extracts readable ASCII (lower quality) |

### Optional — Feature-Gated

These are **not** installed by George. If you need the feature, you install the tool yourself.

| Binary | Language | Feature | Without it |
|--------|----------|---------|-----------|
| **openssl** | C | Secrets vault (AES-256-CBC), HMAC signing | Vault unavailable; hashing falls back to `sha256sum` |
| **gpg** | C (GnuPG) | PGP signing, Git commit signing | /pgp and signed commits unavailable |
| **w3m** | C | Best HTML→text rendering for /web | Falls back to lynx → html2text → sed/awk |
| **lynx** | C | Second-best HTML→text rendering | Falls back to html2text → sed/awk |
| **cargo** | Rust | Rust project build/test/scaffold | Rust projects unavailable |
| **python3** | C (CPython) | Python project scaffold/sandbox | Python projects unavailable |
| **uv** | Rust (Astral) | Fast Python package management | Falls back to pip3 / python3 -m venv |
| **proot** | C | Sandbox isolation (Termux) | Falls back to unshare → directory isolation |
| **proot-distro** | Shell (Termux) | Full Linux containers on Android | Containers unavailable (Termux-only feature) |
| **bitcoin-cli** or **electrum** | C++ / Python | Bitcoin send transactions | BTC send unavailable; balance queries still work via API |
| **cardano-cli** | Haskell | Cardano transactions | ADA send unavailable |
| **solana** | Rust | Solana transactions | SOL send unavailable |
| **pandoc** | Haskell | DOCX/ODT ingestion into knowledge base | Falls back to libreoffice → unavailable |
| **npm** | JavaScript (Node.js) | Node.js project build/test | Node.js projects unavailable |
| **make** | C | Generic project build/test fallback | Some auto-detected build systems skipped |

### Termux-Only (Android)

These require the [Termux:API](https://wiki.termux.com/wiki/Termux:API) companion app. Enabled with `export LODGE_TERMUX_API=1`.

| Binary | Feature |
|--------|---------|
| **termux-battery-status** | Battery level, temperature |
| **termux-clipboard-get/set** | Phone clipboard bridge |
| **termux-notification** | Push notifications |
| **termux-share** | Android share sheet |
| **termux-sms-send/list** | SMS read/send |
| **termux-location** | GPS location |
| **termux-vibrate**, **termux-toast** | Haptics, toast messages |

Also installed on Termux during setup: **gawk** (replaces mawk), **procps** (for `free`), **bc** (location math).

### Always Available (coreutils / standard)

These ship with every Linux and Termux installation. Listed for completeness:

`awk`, `sed`, `grep`, `head`, `tail`, `sort`, `uniq`, `wc`, `cut`, `tr`, `tee`, `cat`, `date`, `stat`, `mv`, `cp`, `rm`, `mkdir`, `find`, `xargs`, `md5sum`, `sha256sum`, `base64`, `strings`, `diff`, `timeout`, `kill`, `ps`, `pgrep`, `df`, `du`, `nproc`, `od`, `shred`

### What George Does NOT Use

- **No Node.js runtime** — npm is only called for Node.js project builds, never for George itself
- **No Python runtime** — python3 is only called for Python project scaffolding, never internally
- **No Docker** — sandboxes use proot/unshare; containers use proot-distro
- **No pip packages** — no PyPDF2, no requests, no third-party Python
- **No cloud services for core function** — LLM inference is always local. Cloud providers are opt-in extras.

### Install Commands

Copy-paste the ones you need. `install.sh` handles the **Required** group automatically — these are here if you prefer to install manually or want the optional tools.

<details>
<summary><strong>Ubuntu / Debian (apt)</strong></summary>

```bash
# Required (core) — auto-installed by install.sh
sudo apt install -y curl jq git sqlite3

# LLM backend — Ollama (auto-installed by install.sh)
curl -fsSL https://ollama.com/install.sh | sh
# LLM backend — llama.cpp (compile from source, see docs/ADRENO_GPU_SETUP.md)

# Optional — prompted during install
sudo apt install -y poppler-utils          # pdftotext (PDF extraction)

# Optional — feature-gated (install what you need)
sudo apt install -y openssl                # Secrets vault, HMAC signing
sudo apt install -y gnupg                  # PGP signing, git commit signing
sudo apt install -y w3m                    # Best HTML→text rendering
sudo apt install -y lynx                   # Second-best HTML→text rendering
sudo apt install -y python3 python3-venv   # Python project scaffolding
sudo apt install -y pandoc                 # DOCX/ODT ingestion
sudo apt install -y make                   # Generic project build fallback
sudo apt install -y npm                    # Node.js project build/test

# Rust (via rustup, not apt)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh  # cargo + rustc

# uv (Python package manager, via standalone installer)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Crypto CLIs (install only if using /wallet)
# bitcoin-cli: requires Bitcoin Core — https://bitcoin.org/en/download
# cardano-cli: requires Cardano Node — https://developers.cardano.org/docs/get-started/installing-cardano-node
# solana: sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"
```

</details>

<details>
<summary><strong>Termux (Android)</strong></summary>

```bash
# Required (core) — auto-installed by install.sh
pkg install -y curl jq git sqlite

# LLM backend — Ollama (auto-installed by install.sh)
curl -fsSL https://ollama.com/install.sh | sh
# LLM backend — llama.cpp (compile from source, see docs/ADRENO_GPU_SETUP.md)

# Termux extras — auto-installed by install.sh
pkg install -y gawk procps bc

# Termux:API — requires Termux:API companion app from F-Droid
pkg install -y termux-api

# Optional — prompted during install
pkg install -y poppler                     # pdftotext (PDF extraction)

# Optional — feature-gated (install what you need)
pkg install -y openssl-tool                # Secrets vault, HMAC signing
pkg install -y gnupg                       # PGP signing
pkg install -y w3m                         # Best HTML→text rendering
pkg install -y lynx                        # Second-best HTML→text rendering
pkg install -y python                      # Python project scaffolding
pkg install -y pandoc                      # DOCX/ODT ingestion
pkg install -y make                        # Generic project build fallback
pkg install -y nodejs                      # npm + Node.js project build/test
pkg install -y proot                       # Sandbox isolation
pkg install -y proot-distro               # Full Linux containers

# Rust (via rustup)
pkg install -y rust                        # or: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# uv (Python package manager)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Crypto CLIs (install only if using /wallet)
# bitcoin-cli: not available in Termux — use Electrum: pip install electrum
# cardano-cli: not available in Termux — use proot-distro Ubuntu
# solana: sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"
```

</details>

## Slash Commands

50+ built-in commands, each with optional shell aliases for rapid access. Type `/help` for the full list.

<details>
<summary><strong>View all commands</strong></summary>

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
| `/write <file> <text>` | — | Write/overwrite a file |
| `/save <file> <text>` | — | Save to file (alias for /write) |
| `/download <url> [dest]` | — | Download a URL |
| `/status` | `lgs` | Agent + device status |
| `/memory` | `lgm` | Show current GEORGE.md |
| `/journal <cmd>` | — | View/write journal (show/vivid/fading/sediment/write/decay) |
| `/reflect` | — | Record a reflection in journal |
| `/sandbox <cmd>` | `lgx` | Manage sandboxes (list/new/build/rm/cd/clone) |
| `/container <cmd>` | — | Linux containers (list/install/login/exec/pentest) |
| `/api <cmd>` | — | API keys & integration status |
| `/social <cmd>` | — | Social media (X/Mastodon/Bluesky/Discord/Telegram) |
| `/provider <cmd>` | — | Cloud AI (OpenAI/Anthropic/Google/Groq/Mistral…) |
| `/web <cmd>` | — | Browse the web (fetch/search/summary/download) |
| `/github <query>` | — | Search GitHub repositories |
| `/email <cmd>` | — | Email (Gmail/ProtonMail/Zoho/Tuta/disposable) |
| `/git <cmd>` | — | Git & GitHub configuration |
| `/backup <cmd>` | — | Backup & restore identity |
| `/security <cmd>` | — | Security, signing, integrity |
| `/recall <query>` | — | Search knowledge base (BM25 full-text) |
| `/readme [topic]` | — | Review own capabilities (self-knowledge) |
| `/secret <cmd>` | — | Encrypted secrets vault (set/get/delete/list/rotate) |
| `/ingest <cmd>` | — | Upload docs to knowledge base |
| `/gsuite <cmd>` | — | Google Workspace (Gmail/Drive/Docs) |
| `/wallet <cmd>` | — | Crypto wallets (BTC/ADA/SOL) |
| `/phone <cmd>` | — | Termux integration (battery/clip/notify/share) |
| `/pgp <cmd>` | — | PGP signing & verification |
| `/slash <cmd>` | — | Custom user commands (create/edit/delete) |
| `/vitals` | — | System vitals (CPU, RAM, disk, battery, WiFi) |
| `/think` | — | Toggle thinking mode |
| `/debug` | — | Toggle debug mode (timers + tokens) |
| `/soul` | — | Toggle soul mode (condensed ~250 tok / full ~4500 tok) |
| `/limits` | — | View/adjust planning limits (steps/depth/milestones) |
| `/model` | — | View/adjust sampling parameters |
| `/models` | — | Model library — list, select, switch |
| `/ask <question>` | — | Quick question (no file changes) |
| `/read <file>` | — | Read a file |
| `/files` | — | List workspace files |
| `/compact` | — | Compress memory |
| `/snapshot` | — | Checkpoint memory |
| `/cd <dir>` | — | Change directory |
| `/quit` | — | Exit |

</details>

## Examples

### Build a project from scratch

```
$ lodge /init shortener python
$ cd shortener
$ lodge "Build a URL shortener API using only stdlib. POST /shorten, GET /<id> redirect, GET /stats."
```

George plans the steps, generates all files, and tests them. Full walkthrough: [docs/examples/url-shortener.md](docs/examples/url-shortener.md)

### Rust CLI tool

```
$ lodge /init tasks rust && cd tasks
$ lodge "Build a CLI task manager with add, list, done, remove commands. Use clap."
```

Full walkthrough: [docs/examples/rust-task-manager.md](docs/examples/rust-task-manager.md)

### Fix cycle

```
$ lodge /build
 ✗ Build failed (exit 1)
$ lodge /fix
 ▸ Running cargo check...
 ◆ Planning fix...
 ✓ Fixed! Build succeeded.
```

### Quick questions

```
$ lodge /ask "Explain the difference between TCP and UDP in 3 sentences"
$ lodge /ask "Write a bash one-liner to find files larger than 100MB"
```

### Phone clipboard bridge (Termux)

```
> /phone clip                    # Paste from phone clipboard
> /ask What does this error mean?
> /phone clip "the answer"       # Copy answer back
```

More examples: [docs/examples/personal-assistant.md](docs/examples/personal-assistant.md)

---

## Deep Dive

### Knowledge Base (FTS5 Recall)

George searches his own documentation and memory using SQLite FTS5 (BM25-ranked full-text search). This gives him self-awareness of his own capabilities without loading the full README into context.

On startup, George chunks knowledge sources by `##` headers and indexes them into FTS5:

| Source | Content |
|--------|---------|
| `ref` | FTS5-optimized master reference (all capabilities) |
| `journal` | Living memory (reflections, learnings) |
| `george` | Current project memory |
| `doc:<label>` | User-ingested documents |

The index auto-rebuilds on file changes. **~50-100KB on disk, <1ms per query, 0 RAM.**

When George answers a question, the recall system injects matching snippets into the system prompt automatically — up to 4 chunks for tasks, 1 chunk for quick questions.

Why FTS5 over vector embeddings? George's corpus is small (~15KB). BM25 matches or beats vectors at this scale, with zero RAM overhead vs 300MB+ for an embedding model. If the corpus grows past ~500KB, Ollama's `/api/embed` endpoint is a ready upgrade path.
$ lodge "Build a URL shortener API using only stdlib. POST /shorten, GET /<id> redirect, GET /stats."
```

George plans 7 steps, generates all files, and tests them. Full walkthrough: [docs/examples/url-shortener.md](docs/examples/url-shortener.md)

### Memory System

George uses `GEORGE.md` files as persistent project memory:

- **Per-project**: Each project gets its own `GEORGE.md` tracking tasks, milestones, validation, and context files
- **Living journal**: `journal.md` with temporal decay — recent memories are vivid, old ones fade
- **Soul**: `soul.md` defines personality, ethics, and working style (Washington's discipline, Franklin's wit, Smith's moral philosophy)
- **Auto-compact**: Old completed steps are compressed to keep token count low
- **Snapshots**: `/snapshot` saves checkpoints you can roll back to

### Model Memory Management

On a 12GB phone, RAM is shared between Android, Termux, the LLM, and your builds. George manages the model lifecycle automatically:

| Event | Action |
|-------|--------|
| Task starts | Model loaded on-demand |
| Task completes | Model unloaded (~4GB freed) |
| Ctrl+C pressed | Request killed, model unloaded |
| Session exit | Model unloaded |

Ctrl+C is always safe — during generation, between steps, or at the prompt. All persistence lives in files, not model state. Unloading the model never loses progress.

Tune with environment variables:

```bash
export LLM_KEEP_ALIVE="0"      # Unload immediately after each request
export LLM_KEEP_ALIVE="2m"     # 2 minutes (balanced)
export LLM_TIMEOUT="1200"      # 20-minute hard timeout (default: no timeout)
export LLM_MAX_TOKENS="2048"   # Max output tokens per step (default: 20480)
```

### Sandboxes

Lightweight project isolation without Docker. Tiered isolation adapts to available tools:

| Method | Isolation Level | Detection |
|--------|-----------------|-----------|
| **proot** | Medium | `command -v proot` (default on Termux) |
| **unshare** | Medium-High | Linux user namespaces |
| **directory** | Basic | Always available (fallback) |

```bash
lodge /sandbox new my_app rust    # Create Rust sandbox (cargo init + git init)
lodge /sandbox new scraper python # Create Python sandbox (uv or venv)
lodge /sandbox list               # List all sandboxes
lodge /sandbox build my_app       # Build in sandbox
lodge /sandbox clone owner/repo   # Clone repo as sandbox
```

Each sandbox can have its own permission level (`/security sandbox set <name> <level>`). Scaffolding includes optimized build profiles, git init, and type-appropriate entrypoints.

### Phone Integration (Termux)

When running in native Termux, George integrates with Android hardware via Termux-API:

```bash
export LODGE_TERMUX_API=1    # Enable (disabled by default — safe for proot)
lodge /phone battery         # Battery level & temperature
lodge /phone clip            # Get/set clipboard
lodge /phone notify msg      # Send notification
lodge /phone share file      # Android share sheet
lodge /vitals                # CPU, RAM, disk, battery, WiFi
```

### Containers (proot-distro)

Full Linux environments — no Docker, no root, no kernel modules. Real distro rootfs under proot.

| Distro | Alias | Use Case |
|--------|-------|----------|
| Ubuntu | `ubuntu` | General development (default) |
| Alpine | `alpine` | Minimal (~50MB base) |
| Kali | `kali` | Penetration testing |
| Debian | `debian` | Stable, broad packages |
| Fedora | `fedora` | RPM ecosystem |
| Arch | `arch` | Rolling release, AUR |
| Void | `void` | Lightweight, runit |
| openSUSE | `opensuse` | Enterprise Linux |

```bash
lodge /container install ubuntu    # Install + auto-bootstrap dev tools
lodge /container login ubuntu      # Interactive shell
lodge /container exec kali nmap -sV target.com  # Run commands
lodge /container pentest           # One-command Kali + tools setup
```

Containers start instantly, have their own package managers, and share the host kernel. 200MB–4GB per distro.

### Security

George executes LLM-generated code. Multiple layers of protection:

- **Permission system** — asks before running destructive commands
- **Command allowlist** — 100+ safe prefixes auto-approved; user-extensible
- **Dangerous command detection** — blocks `rm -rf`, `curl|bash`, reverse shells, `sudo`
- **File write diff preview** — color-coded diffs before overwriting
- **Workspace sandboxing** — refuses writes outside the project directory
- **HMAC-signed memory** — `soul.md` and `journal.md` verified at startup
- **Encrypted identity** — AES-256-CBC encryption for George's files
- **Network audit mode** — optional flag to block all LLM-generated network commands
- **No network dependency** — everything runs locally, no data leaves the device

See [SECURITY.md](SECURITY.md) for the full audit, threat model, and implementation details.

### Secrets Vault

AES-256-CBC encrypted key-value store for sensitive credentials. PBKDF2 with 100k iterations. Plaintext never touches disk.

```bash
lodge /secret set OPENAI_KEY sk-abc123...     # Store encrypted
lodge /secret get OPENAI_KEY                  # Decrypt to stdout
lodge /secret list                            # Names only (never values)
lodge /secret rotate                          # Re-encrypt all with new key
lodge /secret import ~/.ssh/id_ed25519        # Import a file as a secret
```

### Document Ingestion

Upload text files, PDFs, code, or DOCX into George's FTS5 knowledge base:

```bash
lodge /ingest add ~/papers/attention.pdf              # Index a PDF
lodge /ingest summarize ~/papers/long-paper.pdf       # Index + AI summarize
lodge /ingest list                                    # Show ingested documents
```

Supports `.md`, `.txt`, `.sh`, `.py`, `.rs`, `.js`, `.ts`, `.pdf` (pdftotext), `.html`, `.doc`/`.docx` (pandoc).

### Google Workspace

Gmail, Drive, and Docs via OAuth2 device authorization flow — no browser redirect needed on mobile.

```bash
lodge /gsuite setup <client_id> <client_secret>
lodge /gsuite auth                                    # Device auth flow
lodge /gsuite gmail list                              # List unread
lodge /gsuite gmail send user@example.com "Subject" "Body"
lodge /gsuite drive upload ./report.pdf               # Upload
lodge /gsuite docs create "My Doc" "Content"          # Create doc
```

### Cryptocurrency Wallets

Bitcoin, Cardano, and Solana. Private keys stored in the encrypted vault. Balance queries via public APIs (no local node).

```bash
lodge /wallet balance                                 # All wallets
lodge /wallet btc send <address> <amount>             # Send BTC
lodge /wallet ada balance                             # ADA + native tokens
lodge /wallet sol airdrop 1                           # Devnet airdrop
lodge /wallet network testnet                         # Switch to testnet
```

### Social Media & Email

Post, read, and interact across five social platforms and four email providers:

```bash
lodge /social post "Hello from George!"              # Post to ALL platforms
lodge /social discord send general "Deploy complete"  # Discord channel by name
lodge /social x timeline                              # Read X timeline
lodge /email send gmail user@example.com "Subject" "Body"
lodge /social status                                  # Show configured platforms
```

**Social:** X (Twitter v2), Mastodon, Bluesky, Discord (Bot + Webhook), Telegram
**Email:** Gmail, ProtonMail, Zoho, Tuta (+ disposable addresses)

### Cloud AI Providers

Route queries through 11 cloud providers when you need more power:

```bash
lodge /provider chat openai "Explain monads"
lodge /provider chat anthropic "Review this code"
lodge /provider models openai                         # List available models
```

**Providers:** OpenAI, Anthropic, Google AI Studio, Google ADK, Groq, Mistral, Together, Perplexity, Cohere, DeepSeek, xAI (Grok)

### Web Browsing

```bash
lodge /web fetch https://example.com                  # Read page as text
lodge /web search "rust async tutorial"               # Search the web
lodge /web summary https://blog.example.com/post      # AI-summarize a page
lodge /web download https://example.com/file.tar.gz   # Download a file
```

Search uses Serper.dev (Google results) if configured, Perplexity as an alternative, or DuckDuckGo HTML scraping as a free fallback.

---

## Hardware Targets

| Device | RAM | Status |
|--------|-----|--------|
| Galaxy Fold 7 (Snapdragon 8 Elite) | 12GB | Primary target |
| Galaxy S25 Ultra | 12GB | Supported |
| Chromebooks (ARM/x86) | 8GB+ | Supported ([Debian/Crostini guide](docs/DEBIAN_CHROMEOS_SETUP.md)) |
| Any Linux device | 8GB+ | Supported |
| Raspberry Pi 5 | 8GB | Should work (slower) |

## Models

Ships with a **model library** of 18 pre-configured models across 7 families. Default pair:

- **Primary:** Ministral-3-3B-Reasoning — reasoning and planning
- **Secondary:** Ministral-3-3B-Instruct — fast utility tasks with vision support

All models are 1-4B parameters at Q4–Q8 quantization. Only one is loaded at a time (~8GB at 32K context). George hot-swaps automatically based on the task type.

| Family | Models | Strengths |
|--------|--------|-----------|
| **Ministral** | Reasoning, Instruct | Default pair. Strong reasoning + fast utility. Vision on instruct. |
| **Qwen3** | Thinking, Instruct | Best nothink support (architecturally enforced). Good multilingual. |
| **Qwen 3.5** | 2B, 4B, Thinking variants | Newest Qwen generation. 256K native context. Both backends. |
| **Llama 3.2** | Base, Instruct | Meta's flagship small model. 128K native context. |
| **Granite 4** | Micro, Hybrid, Preview | IBM's code-tuned family. Preview adds thinking. |
| **Gemma 3** | 4B QAT, 1B | Google multimodal. 4B has vision. 1B ultra-lightweight. |
| **Phi-4** | Instruct, Reasoning | Microsoft. Math/logic specialist on reasoning variant. |

```bash
lodge /models list                          # Show all available
lodge /models select primary granite4       # Switch primary model
lodge /models single minist-think           # Single-model mode
```

### Dual LLM Backend

George supports two backends. Choose based on your hardware:

| Backend | Best For | GPU Acceleration |
|---------|----------|-----------------|
| **Ollama** | Easy setup, broad compatibility | Via Ollama's built-in support |
| **llama.cpp** | Direct hardware control, Vulkan GPU | Native Vulkan (Adreno, Mali, etc.) |

The llama.cpp backend speaks the OpenAI-compatible `/v1/chat/completions` endpoint. Switch with:

```bash
export LLM_BACKEND=llamacpp
export LLAMA_CPP_SERVER_BIN=~/llama.cpp/build/bin/llama-server
```

See [docs/BACKEND_VALIDATION.md](docs/BACKEND_VALIDATION.md) for setup and [docs/ADRENO_GPU_SETUP.md](docs/ADRENO_GPU_SETUP.md) for Vulkan GPU acceleration.

Full model library documentation: [docs/MODELS.md](docs/MODELS.md)

## Backup & Update

George's memories and personality are irreplaceable. The backup system preserves them across updates, re-clones, and machine transfers.

```bash
lodge /backup local              # Snapshot to ~/.george/backups/
lodge /backup github             # Push to a private GitHub repo
lodge /backup restore            # Restore from most recent backup
lodge /backup export             # Portable export of .george directory
```

### Updating

```bash
bash ~/blue-lodge/update.sh          # Auto-backup → git pull → restore identity
bash ~/blue-lodge/update.sh --clean  # Fresh clone, restore identity
```

## Phone Setup

Full step-by-step guide with four installation paths: **[docs/PHONE_SETUP.md](docs/PHONE_SETUP.md)**

| Path | Runtime | Best For |
|------|---------|----------|
| **A: Termux-Native** (recommended) | F-Droid Termux | Full phone integration, simplest setup |
| **B: proot Ubuntu** | Ubuntu inside Termux | Need apt/dpkg, familiar Linux |
| **B+: Hybrid** | Ollama in Termux, George in proot | Best of both worlds |
| **C: Play Store Termux** | Play Store Termux | F-Droid unavailable |

## Testing

34 test modules. 2,479 assertions. Zero external dependencies. All passing.

```bash
bash tests/run_all.sh              # Run all (compact output)
bash tests/run_all.sh -v           # Verbose — show all assertions
bash tests/run_all.sh test_llm     # Run specific module
```

<details>
<summary><strong>View all test modules</strong></summary>

| Module | Assertions | Covers |
|--------|-----------|--------|
| `test_agent.sh` | 276 | Agent loop, config, cancellation, auto-install, cascade, honeydew task tracking |
| `test_api.sh` | 33 | REST client, keys, JSON, auth headers |
| `test_backup.sh` | 81 | Local/git backup, restore, pruning, export/import, auth credential export |
| `test_commands.sh` | 75 | Slash command registration, dispatch, catalog |
| `test_container.sh` | 28 | Container management, distro resolution |
| `test_download.sh` | 10 | URL download, local copy |
| `test_email.sh` | 107 | Gmail/ProtonMail/Zoho/Tuta, SMTP/IMAP, bridge |
| `test_git.sh` | 63 | Git identity, SSH, remote, push guard |
| `test_gsuite.sh` | 35 | OAuth2, Gmail/Drive/Docs, validation |
| `test_init.sh` | 38 | Project scaffolding, type resolution |
| `test_journal.sh` | 36 | Temporal memory, decay, greetings |
| `test_llm.sh` | 229 | LLM config, tokens, model library, dual-model, sampling |
| `test_lodge.sh` | 167 | Main script, command wiring, soul toggle, REPL |
| `test_memory.sh` | 57 | GEORGE.md sections, compaction, snapshots |
| `test_models.sh` | 118 | Model registry, families, hot-swap, Modelfile generation |
| `test_pgp.sh` | 34 | PGP signing, verification, key management |
| `test_phone.sh` | 43 | Phone integration, Termux API, dashboard |
| `test_providers.sh` | 32 | 11 AI providers, dispatcher, aliases |
| `test_recall.sh` | 71 | FTS5 indexing, search, self-review, quality |
| `test_sandbox.sh` | 63 | Sandbox lifecycle, build, permissions |
| `test_save.sh` | 25 | File save, directory creation |
| `test_secrets.sh` | 30 | Vault encrypt/decrypt, rotate, import |
| `test_security.sh` | 56 | Allowlist, signing, encryption |
| `test_service.sh` | 44 | Service command, daemon management |
| `test_slash.sh` | 53 | Custom commands, create, template, rename |
| `test_social.sh` | 101 | 5 platforms, Discord channels, post dispatch |
| `test_tools.sh` | 123 | Code extraction, file ops, safety |
| `test_transcript.sh` | 48 | Session transcript recording, rotation |
| `test_ui.sh` | 45 | Colors, print functions, markdown rendering |
| `test_validate_gpu.sh` | 45 | GPU detection, Vulkan validation |
| `test_vitals.sh` | 83 | System vitals, thresholds, guards |
| `test_wallet.sh` | 51 | BTC/ADA/SOL wallets, network, send validation |
| `test_web.sh` | 150 | Web fetch, HTML parsing, DDG search, cache, scrape-images fallback |
| `test_write.sh` | 29 | File write, code extraction |

</details>

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

## Uninstall

```bash
bash ~/blue-lodge/uninstall.sh
```

## Documentation

| Doc | Content |
|-----|---------|
| [docs/PHONE_SETUP.md](docs/PHONE_SETUP.md) | Android setup (4 installation paths) |
| [docs/DEBIAN_CHROMEOS_SETUP.md](docs/DEBIAN_CHROMEOS_SETUP.md) | Debian / Chrome OS (Crostini) setup |
| [docs/MODELS.md](docs/MODELS.md) | Model library & configuration |
| [docs/BACKEND_VALIDATION.md](docs/BACKEND_VALIDATION.md) | LLM backend setup & validation |
| [docs/ADRENO_GPU_SETUP.md](docs/ADRENO_GPU_SETUP.md) | Vulkan GPU acceleration |
| [docs/RECALL.md](docs/RECALL.md) | Knowledge base deep dive |
| [docs/SLASH_COMMANDS.md](docs/SLASH_COMMANDS.md) | Slash command reference |
| [docs/SLASH_EXTENSIONS.md](docs/SLASH_EXTENSIONS.md) | Custom command authoring |
| [docs/SANDBOXES.md](docs/SANDBOXES.md) | Sandbox system details |
| [docs/CRYPTO_WALLETS.md](docs/CRYPTO_WALLETS.md) | Wallet setup & usage |
| [docs/PGP_SIGNING.md](docs/PGP_SIGNING.md) | PGP configuration |
| [docs/SOCIAL_BOTS.md](docs/SOCIAL_BOTS.md) | Social media bot setup |
| [docs/SECRETS_VAULT.md](docs/SECRETS_VAULT.md) | Vault architecture |
| [SECURITY.md](SECURITY.md) | Security audit & threat model |

## License

MIT