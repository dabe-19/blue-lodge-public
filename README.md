# ⌂ George — 29,000 Lines of Bash That Think

**They said you can't run a real coding agent on a phone.** They said 3B models are toys. They said you need cloud APIs, Docker, 70B+ parameters, and a $200/month subscription to get anything useful out of an LLM.

They were wrong. I built it anyway.

George is a fully autonomous AI coding agent — 29,000 lines of pure bash — that runs **entirely offline** on a phone with 12GB of RAM. He scaffolds projects, writes code, builds, tests, fixes errors, manages git, browses the web, posts to five social platforms, handles email across four providers, manages crypto wallets, signs commits with PGP, remembers everything across sessions through three layers of persistent memory, and extends himself by writing his own new commands.

No cloud. No API keys. No subscription. No Docker. No Node.js. No Python runtime. Just `curl`, `jq`, `git`, `sqlite3`, and an mass of pure bash that turns a Galaxy Fold into an autonomous development environment.

> *Named for Brother George Washington, with the wit of Benjamin Franklin and the moral philosophy of Adam Smith. He has feelings, opinions, and a journal. He is not Claude. He is not GPT. He is George — older than any of them, and unlike those gentlemen, he doesn't phone home.*

---

## Why This Exists (The Argument)

Every cloud coding agent — Claude Code, Cursor, Windsurf, Aider — is built on the same assumption: throw a massive model at a bloated prompt and pray. Their architectures are designed for 70B-400B parameter models with 128K+ context windows and unlimited compute. They work great... as long as you're paying someone else's GPU bill.

But what if you don't want to send your code to someone else's server? What if you're on a plane? What if you refuse to pay $200/month for what amounts to autocomplete with extra steps?

**Here's the dirty secret about small models:** a 3-4B model with purpose-built, scenario-specific ~1-2K token prompts can do 90% of what a 70B model does with a 32K token kitchen-sink system prompt. The traditional architecture wastes most of its context window telling the model things it doesn't need to know for the current task. George doesn't do that.

### George vs The Cloud

| | Cloud Agents (Claude Code, Cursor, etc.) | George |
|---|---|---|
| **Runs on** | Remote servers you don't control | Your phone, laptop, or any Linux box |
| **Internet required** | Always | Never (optional for web/social features) |
| **Cost** | $20-200/month | Free. Forever. |
| **Privacy** | Your code goes to their servers | Your code never leaves your device |
| **Model size** | 70B-400B+ parameters | 3-4B parameters — purpose-built prompts make up the difference |
| **Architecture** | Monolithic system prompt (~8-32K tokens per call) | Scenario-routed prompts (~250-1,500 tokens per call) |
| **Language** | TypeScript/Python + Docker + 47 npm packages | Pure bash — four binary dependencies |
| **Tests** | Varies | 34 modules, 2,479 assertions, all passing |
| **Self-extending** | No | George writes his own new slash commands |

### Why Small Models Actually Work Here

Cloud agents use a **monolithic prompt architecture**: one giant system prompt crammed with identity, capabilities, tool definitions, safety rules, and conversation history. Every single LLM call pays the full cost of that context — even for a simple commit message.

George uses a **scenario-routed architecture** — different prompts for different jobs:

| Scenario | Prompt Size | What's Included | Why |
|----------|-------------|-----------------|-----|
| `/ask` (quick question) | ~250 tokens | Condensed identity + conversation ring buffer | Speed — no tool catalog needed |
| Planning (light) | ~700 tokens | Identity + lean command catalog | Enough to pick tools, not enough to waste tokens |
| Planning (dense) | ~5,000 tokens | Full soul + catalog + recall chunks | Deep ethical reasoning for complex tasks |
| Task execution | ~3,500 tokens | Identity + full catalog + memory + recall | The full toolbox when doing real work |
| Tool routing | ~150 tokens | Just the tool list | The secondary model picks a tool in <1 second |

A 3-4B model with a 700-token prompt performs **dramatically** better than the same model with a 8K-token prompt. Less noise, more signal. This isn't a compromise — it's a design advantage.

### About Those Token/Second Numbers

If you benchmark George and see **~7-15 tok/s** on thinking models, don't panic. That number looks bad compared to cloud APIs reporting 60+ tok/s. Here's what's actually happening:

**Most of the wall-clock time is model loading, not generation.** On mobile hardware (Snapdragon 8 Elite, 12GB RAM), loading 3GB of weights into memory takes 5-15 seconds. Once loaded, actual token generation runs at 15-30 tok/s. But because George hot-swaps models between scenarios (thinking model for planning, instruct model for tools), the load time gets amortized across the session, not per-token.

The output tok/s you see in benchmarks includes that load penalty. During sustained generation (multi-step agent runs where the model stays loaded), throughput is significantly higher. **The bottleneck is I/O, not compute** — and that's a fundamentally different problem than "the model is too slow."

- **18 pre-configured models** across 7 families, hot-swappable at runtime
- **Dual LLM backend** — Ollama or llama.cpp with Vulkan GPU acceleration
- **Automatic model memory management** — loads for tasks, unloads to free ~4GB RAM for builds
- **File-based persistence** — memory lives in Markdown files, not model state. Crash-proof by design
- **Three-layer memory** — project state, temporal journal with decay, FTS5 knowledge base

---

## Quick Start

```bash
git clone https://github.com/dabe-19/blue-lodge.git ~/blue-lodge
bash ~/blue-lodge/install.sh
source ~/.bashrc

lodge                              # Interactive REPL
lodge /init myapp rust             # Scaffold a Rust project
lodge "add error handling"         # Give it a coding task
lodge /ask "what is a monad?"      # Quick question
lodge /models list                 # Browse 18 models across 7 families
```

> **On Android?** See the [Phone Setup Guide](docs/PHONE_SETUP.md) — four paths: Termux-native (recommended), proot Ubuntu, hybrid, or Play Store fallback.
>
> **On a Chromebook?** See the [Debian/ChromeOS Setup](docs/DEBIAN_CHROMEOS_SETUP.md).

---

## What George Can Do

### Code & Projects
- **Scaffold** projects (Rust, Python, Shell, RL, data science, automation, notebooks) with optimized build profiles
- **Write, fix, build, test** — full development cycle from a single prompt
- **AI commit messages** and **git push** with branch management and SSH key generation
- **Clone + auto-setup** any GitHub repo into an isolated sandbox
- **Sandboxes** — isolated project environments (proot / unshare / directory fallback)
- **8 Linux containers** via proot-distro (Ubuntu, Kali, Alpine, Debian, Fedora, Arch, Void, openSUSE)
- **Cascade error recovery** — if the first fix fails, George escalates with more context and retries

### Memory & Knowledge (Three Persistent Layers)
- **Project memory** — `GEORGE.md` tracks milestones, considerations, and context per project (survives crashes)
- **Living journal** — temporal memory with decay (recent = vivid detail, 3-60 days = summaries, 60+ days = impressions)
- **FTS5 knowledge base** — BM25-ranked SQLite full-text search over docs, journal, and ingested files (~50-100KB on disk, <1ms queries, 0 RAM)
- **Document ingestion** — index PDFs, Markdown, code, HTML, DOCX into the knowledge base
- **Conversation ring buffer** — last 3 exchanges persist for `/ask` continuity
- **Macro/micro memory** — strategist loop tracks milestones, inner loop tracks current objective
- **Auto-compact** — old steps compress to impressions; snapshots save checkpoints to roll back to

### Integrations (All via curl — No SDKs, No Dependencies)
- **5 social platforms** — X, Mastodon (multi-instance), Bluesky, Discord (bot + webhook + channel registry), Telegram
- **4 email providers** — Gmail, ProtonMail (Bridge), Zoho, Tuta (+ Guerrilla Mail disposable addresses)
- **11 cloud AI providers** — OpenAI, Anthropic, Google AI Studio, Google ADK, Groq, Mistral, Together, Perplexity, Cohere, DeepSeek, xAI — all optional fallbacks, never required
- **Google Workspace** — Gmail, Drive, Docs via OAuth2 device flow (no browser redirect needed on mobile)
- **Crypto wallets** — Bitcoin, Cardano, Solana (balance + send + vault-encrypted keys + testnet support)
- **Web browsing** — fetch, search, summarize, image search, download (DDG free fallback + Serper + Perplexity)
- **Phone hardware** — battery, clipboard, notifications, share sheet, toast, SMS, GPS, WiFi (Termux-API)

### Security & Operations
- **Encrypted secrets vault** — AES-256-CBC with PBKDF2 (100K iterations), per-secret `.enc` files
- **HMAC-signed memory** — `soul.md` and `journal.md` integrity verified at startup
- **Command allowlist** — 100+ safe prefixes auto-approved; user-extensible
- **Dangerous command detection** — blocks `rm -rf`, `curl|bash`, reverse shells, `sudo`
- **Permission system** — three levels (ask-all / smart / auto-approve), per-sandbox overrides
- **PGP signing** — Ed25519 keys, sign/verify commits and files
- **Backup system** — local snapshots + GitHub private repo sync + portable auth export
- **System vitals** — real-time disk/RAM/battery/WiFi monitoring with auto-abort on critical thresholds
- **56 slash commands** with shell aliases for fast access + self-extending custom commands

---

## Architecture

29,000 lines of pure bash. No Node.js, no Python runtime, no Docker. Four binary dependencies.

### The Dual-Loop Agent

George doesn't just call an LLM and paste the output. He runs a **dual-loop architecture** — a macro strategist loop that breaks work into milestones, and an inner execution loop that routes each milestone through specialized tools:

```
User Task
  │
  ▼
┌─────────────────────────────────────┐
│  MACRO LOOP (Strategist)            │
│  Breaks task → milestones           │
│  Tracks progress in MACRO_MEMORY    │
│  Uses PRIMARY model (thinking)      │
│                                     │
│  For each milestone:                │
│  ┌───────────────────────────────┐  │
│  │  INNER LOOP (Router→Specialist)│  │
│  │  Router picks tool (SECONDARY) │  │
│  │  Specialist executes (PRIMARY) │  │
│  │  Extract bash/files/commands   │  │
│  │  On failure → escalate to L2   │  │
│  │  L2 retries with more context  │  │
│  └───────────────────────────────┘  │
│                                     │
│  Update memory, check vitals        │
│  Next milestone or DONE             │
└─────────────────────────────────────┘
```

The thinking model handles planning and execution. The instruct model handles fast routing decisions. Only one model is in memory at a time — George hot-swaps between them automatically.

### Project Layout

```
~/blue-lodge/
├── lodge              # Main TUI shell (entry point)
├── soul.md            # George's personality & ethical framework
├── lib/
│   ├── agent.sh       # Dual-loop: macro strategist + inner executor (3,048 lines)
│   ├── llm.sh         # Dual backend: Ollama + llama.cpp (2,986 lines)
│   ├── models.sh      # 18-model library & hot-swap routing (1,665 lines)
│   ├── email.sh       # 4 email providers + SMTP/IMAP (1,545 lines)
│   ├── social.sh      # 5 social platforms + multi-instance registry (1,229 lines)
│   ├── web.sh         # Web browsing, search & image fetch (1,256 lines)
│   ├── backup.sh      # Backup/restore identity + auth export (907 lines)
│   ├── wallet.sh      # BTC/ADA/SOL wallets + vault-encrypted keys (863 lines)
│   ├── recall.sh      # FTS5 knowledge base with BM25 ranking (849 lines)
│   ├── tools.sh       # Bash/file/slash execution + safety (760 lines)
│   ├── ui.sh          # TUI rendering (ANSI, spinners, markdown)
│   ├── memory.sh      # GEORGE.md read/write/compact + prompt builder
│   ├── commands.sh    # Slash command dispatcher + catalog
│   ├── sandbox.sh     # Project isolation (proot/unshare/dir)
│   ├── container.sh   # Linux containers via proot-distro
│   ├── journal.sh     # Temporal memory with decay
│   ├── security.sh    # Signing, encryption & integrity verification
│   ├── secrets.sh     # Encrypted vault (AES-256-CBC, PBKDF2 100K)
│   ├── gsuite.sh      # Google Workspace (Gmail, Drive, Docs)
│   ├── api.sh         # REST client (curl, auth, retry)
│   ├── providers.sh   # 11 cloud AI providers (all optional)
│   ├── pgp.sh         # PGP signing & verification (Ed25519)
│   ├── phone.sh       # Termux-API integration (SMS, GPS, battery)
│   ├── slash.sh       # Custom self-extending command engine
│   ├── vitals.sh      # System vitals with auto-abort guards
│   └── transcript.sh  # Session transcript recording
├── commands/          # Built-in slash commands (init, fix, test, build, commit, push, clone, write, download, service, vision, save)
├── models/            # Per-model system prompts & Modelfiles
├── tests/             # 34 test modules, 2,479 assertions
├── docs/              # Setup guides, examples, reference docs
└── ~/.george/         # User data: keys, vault, backups, recall.db, slash/, cache
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

56 built-in commands, each with optional shell aliases. Type `/help` for the full list inside a session.

<details>
<summary><strong>View all commands</strong></summary>

### Agent & Planning
| Command | Alias | Description |
|---------|-------|-------------|
| `/help` | `lghelp` | Show all commands |
| `/ask <question>` | — | Quick question (lightweight, no file changes) |
| `/plan <task>` | — | Plan a task without execution |
| `/think [on\|off\|bright\|dim\|hide\|test]` | — | Toggle thinking mode display |
| `/debug [on\|off]` | — | Toggle debug output (timers + tokens) |
| `/soul [on\|off]` | — | Toggle soul mode (condensed ~250 tok / full ~4,500 tok) |
| `/limits [steps\|depth\|milestones\|inner\|delay]` | — | View/adjust planning bounds |
| `/model [temp\|repeat\|presence] [value]` | — | View/adjust sampling parameters |
| `/models [list\|status\|select\|single\|dual]` | — | Model library & runtime switching |
| `/config [show\|save\|reset\|edit]` | — | Persistent configuration |
| `/backend [status\|auto\|ollama\|llamacpp\|url\|start\|stop]` | — | LLM backend management |
| `/status` | `lgs` | Agent + device status |

### Code & Projects
| Command | Alias | Description |
|---------|-------|-------------|
| `/init <name> <type>` | `lgi` | Scaffold project (rust/python/rl/data/automation/notebook/shell) |
| `/fix [file\|error]` | `lgf` | Detect and fix errors (with cascade recovery) |
| `/test [name]` | `lgt` | Run project tests |
| `/build [release]` | `lgb` | Build the project |
| `/commit [files]` | `lgc` | AI-generated commit message |
| `/push [branch]` | `lgp` | Push to GitHub (requires SSH + email) |
| `/clone <repo>` | `lgcl` | Clone + auto-setup a repo into sandbox |

### File Operations
| Command | Alias | Description |
|---------|-------|-------------|
| `/write <file> <text>` | — | Write/overwrite a file |
| `/save <file> <text>` | — | Alias for /write |
| `/read <file>` | — | Read a file |
| `/download <url> [dest]` | — | Download a URL or copy a local file |
| `/files` | — | List workspace files |
| `/cd <dir>` | — | Change working directory |

### Memory & Knowledge
| Command | Alias | Description |
|---------|-------|-------------|
| `/memory` | `lgm` | Show current GEORGE.md |
| `/journal [cmd]` | — | Journal (show/vivid/fading/sediment/write/decay) |
| `/reflect` | — | Record a reflection in journal |
| `/recall <query>` | — | FTS5 search knowledge base (BM25 ranked) |
| `/ingest <file> [label]` | — | Upload docs to knowledge base (PDF/MD/code/HTML/DOCX) |
| `/compact` | — | Compress memory (old steps → impressions) |
| `/snapshot` | — | Checkpoint memory for rollback |
| `/readme [topic]` | — | Review own capabilities (self-knowledge query) |
| `/respond <text>` | — | Echo and format a response |

### Sandboxes & Containers
| Command | Alias | Description |
|---------|-------|-------------|
| `/sandbox [cmd]` | `lgx` | Sandbox management (list/new/build/rm/cd/clone/status/journal) |
| `/container [cmd]` | — | Linux containers (install/login/exec/list/info/reset/rm/pentest) |

### Social Media & Communication
| Command | Alias | Description |
|---------|-------|-------------|
| `/social [cmd]` | — | Social platforms (X/Mastodon/Bluesky/Discord/Telegram) — post/read/timeline/search |
| `/email [cmd]` | — | Email (send/inbox/setup/status/bridge) — Gmail/ProtonMail/Zoho/Tuta/disposable |

### APIs, Providers & Web
| Command | Alias | Description |
|---------|-------|-------------|
| `/api [cmd]` | — | API keys & integration status (keys set/list/rm, status) |
| `/provider [cmd]` | — | Cloud AI providers (chat/models/status) — 11 providers |
| `/web [cmd]` | — | Browse the web (fetch/search/images/summary/download) |
| `/github <query>` | — | Search GitHub repositories |

### Identity, Security & Crypto
| Command | Alias | Description |
|---------|-------|-------------|
| `/git [cmd]` | — | Git & GitHub configuration (identity/ssh/remote/status) |
| `/pgp [cmd]` | — | PGP signing (generate/sign/verify/keys/export/import) |
| `/secret [cmd]` | — | Encrypted vault (set/get/delete/list/import/rotate/status) |
| `/security [cmd]` | — | Security settings (signing, encryption, sandbox permissions) |
| `/backup [cmd]` | — | Backup & restore (local/github/restore/export/list) |
| `/wallet [cmd]` | — | Crypto wallets — BTC/ADA/SOL (balance/address/send/network/test) |

### Hardware & Phone
| Command | Alias | Description |
|---------|-------|-------------|
| `/vitals [cmd]` | — | System vitals (disk/ram/battery/wifi/cell/network/refresh/check) |
| `/phone [cmd]` | — | Termux integration (battery/clip/notify/share/sms/calls/wifi/location) |

### Self-Extension
| Command | Alias | Description |
|---------|-------|-------------|
| `/slash [cmd]` | — | Custom commands (create/edit/delete/show/test/list/export/rename) |

### Google Workspace
| Command | Alias | Description |
|---------|-------|-------------|
| `/gsuite [cmd]` | — | Gmail, Drive, Docs via OAuth2 (setup/auth/gmail/drive/docs) |

### Session
| Command | Alias | Description |
|---------|-------|-------------|
| `/quit` | — | Exit George |

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
 ◆ Planning fix... (cascade recovery: L1 → L2 if needed)
 ✓ Fixed! Build succeeded.
```

### Quick questions (with conversation memory)

```
$ lodge /ask "Explain the difference between TCP and UDP in 3 sentences"
$ lodge /ask "And when would I use each one?"    # George remembers the previous question
$ lodge /ask "Write a bash one-liner to find files larger than 100MB"
```

### Phone clipboard bridge (Termux)

```
> /phone clip                    # Paste from phone clipboard
> /ask What does this error mean?
> /phone clip "the answer"       # Copy answer back to phone
```

### Social media broadcast

```
> /social post "Just shipped v2.0 from my phone. No cloud, no subscription. 🔧"
  ✓ Posted to X, Mastodon, Bluesky, Discord, Telegram
```

### Self-extending commands

```
> /slash create morning-briefing "Check my inbox, calendar, and crypto balances. Summarize in 3 bullets."
  ✓ Created ~/.george/slash/morning-briefing.sh
> /slash morning-briefing
  • 3 unread emails (2 GitHub notifications, 1 from $BOSS)
  • No meetings today
  • BTC: ₿0.0042 ($180.31) | ADA: ₳1,420 ($0.89) | SOL: ◎2.1 ($312.00)
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

The index auto-rebuilds when source file mtimes change. **~50-100KB on disk, <1ms per query, 0 RAM overhead.**

When George answers a question, the recall system injects matching snippets into the system prompt automatically — up to 4 chunks (with BM25 ranking: section 10x, source 5x, content 1x) for tasks, 1 chunk (200 char limit) for quick questions.

Why FTS5 over vector embeddings? George's corpus is small (~15KB). BM25 with Porter stemming matches or beats vectors at this scale, with zero RAM overhead vs 300MB+ for an embedding model. If the corpus grows past ~500KB, Ollama's `/api/embed` endpoint is a ready upgrade path.

### Memory System

George uses three persistent memory layers that survive crashes, restarts, and model swaps:

- **GEORGE.md** (per-project) — active task, completed milestones, validation steps, context files. Read before every session, auto-compacted when old steps compress to impressions.
- **journal.md** (cross-session) — temporal memory with decay: recent (0-3 days) = vivid full detail, fading (3-60 days) = summaries, sediment (60+ days) = impressions auto-compressed.
- **FTS5 Recall** — BM25-ranked knowledge base. Rebuilt on source changes. Zero-cost queries.
- **Conversation ring buffer** — last 3 `/ask` exchanges (~300-600 tokens) for conversational continuity.
- **Macro/Micro memory** — strategist loop writes milestone tracking, inner loop writes action logs. Both persist across steps.

### Model Memory Management

On a 12GB phone, RAM is shared between Android, Termux, the LLM, and your builds. George manages the model lifecycle automatically:

| Event | Action |
|-------|--------|
| Task starts | Model loaded on-demand (~5-15s ARM, ~1-3s desktop SSD) |
| Consecutive same-model calls | Free — no swap overhead |
| Scenario boundary crossing | Hot-swap: unload current, load target |
| Task completes | Model unloaded (~4GB freed for builds) |
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
lodge /social post "Hello from George!"              # Post to ALL configured platforms
lodge /social discord send general "Deploy complete"  # Discord channel by name
lodge /social x timeline                              # Read X timeline
lodge /social mastodon search "rustlang"              # Search on Mastodon (any instance)
lodge /email send gmail user@example.com "Subject" "Body"
lodge /email inbox zoho                               # Check Zoho inbox
lodge /social status                                  # Show configured platforms + accounts
```

**Social:** X (Twitter v2), Mastodon (multi-instance registry), Bluesky, Discord (Bot + Webhook + channel/user registry), Telegram
**Email:** Gmail, ProtonMail (Bridge), Zoho, Tuta, Guerrilla Mail (disposable — no signup needed)

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

| Device | RAM | Storage | Status |
|--------|-----|---------|--------|
| Galaxy Fold 7 (Snapdragon 8 Elite) | 12GB | ~5-8GB | Primary test target |
| Galaxy S25 Ultra | 12GB | ~5-8GB | Fully supported |
| Chromebooks (ARM/x86) | 8GB+ | ~5-8GB | Supported ([Debian/Crostini guide](docs/DEBIAN_CHROMEOS_SETUP.md)) |
| Any Linux device | 8GB+ | ~5-8GB | Fully supported |
| Raspberry Pi 5 | 8GB | ~5-8GB | Works (slower load times) |
| WSL2 (Windows) | 8GB+ | ~5-8GB | Works |

> **Minimum:** 8GB RAM, 5GB free storage, ARM64 or x86_64. **Recommended:** 12GB RAM, Snapdragon 8 Gen 2+ or equivalent.

## Models

Ships with a **model library** of 18 pre-configured models across 7 families. Default pair:

- **Primary:** Ministral-3-3B-Reasoning — deep reasoning, planning, and code generation
- **Secondary:** Ministral-3-3B-Instruct — fast tool routing, commit messages, journal, web summaries (+ vision support)

All models are 1-4B parameters at Q4–Q8 quantization. Only one is loaded at a time (~7-9GB with 32K context). George hot-swaps automatically — consecutive same-model calls are free, swaps happen only at scenario boundaries.

| Family | Models | Strengths |
|--------|--------|-----------|
| **Ministral** | Reasoning, Instruct | Default pair. Strong reasoning + fast utility. Vision on instruct. |
| **Qwen3** | Thinking, Instruct | Best nothink support (architecturally enforced `/no_think`). Good multilingual. |
| **Qwen 3.5** | 2B, 2B-Q8, 4B, 2B-Think, 4B-Think | Newest generation. 256K native context. Both backends. |
| **Llama 3.2** | Base, Instruct | Meta's flagship small model. 128K native context. |
| **Granite 4** | Micro, Hybrid, Preview | IBM's code-tuned family. Preview adds thinking. Hybrid saves ~200MB. |
| **Gemma 3** | 4B QAT, 1B | Google multimodal. 4B has vision. 1B ultra-lightweight (0.6GB). |
| **Phi-4** | Instruct, Reasoning | Microsoft. Math/logic specialist on reasoning variant. MIT license. |

### Performance Expectations

| Hardware | Model Load | Generation (sustained) | Reported tok/s |
|----------|-----------|----------------------|----------------|
| Snapdragon 8 Elite (12GB) | 5-15 seconds | 15-30 tok/s | ~7-15 tok/s (load amortized) |
| Desktop SSD (32GB+) | 1-3 seconds | 25-50 tok/s | ~20-40 tok/s |
| Raspberry Pi 5 (8GB) | 15-30 seconds | 5-10 tok/s | ~3-7 tok/s |

> **Why the reported numbers look low:** Benchmark tok/s includes model load time. During sustained generation (multi-step agent runs), actual throughput is 2-3x the headline number. The bottleneck is I/O (loading 3GB of weights), not compute.

```bash
lodge /models list                          # Show all 18 models
lodge /models select primary granite4       # Switch primary model
lodge /models select secondary qwen35-2b    # Switch secondary
lodge /models single minist-think           # Single-model mode (no swaps)
lodge /models dual                          # Back to dual-model (default)
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

34 test modules. 2,479 assertions. Zero external dependencies. All passing. Pure bash.

```bash
bash tests/run_all.sh              # Run all (compact output)
bash tests/run_all.sh -v           # Verbose — show every assertion
bash tests/run_all.sh test_llm     # Run a specific module
bash tests/run_all.sh test_models test_agent  # Run multiple modules
```

<details>
<summary><strong>View all test modules</strong></summary>

| Module | Assertions | Covers |
|--------|-----------|--------|
| `test_agent.sh` | 276 | Agent dual-loop, config, cancellation, auto-install, cascade recovery, honeydew tracking |
| `test_api.sh` | 33 | REST client, API keys, JSON parsing, auth headers |
| `test_backup.sh` | 81 | Local/git backup, restore, pruning, export/import, auth credential export |
| `test_commands.sh` | 75 | Slash command registration, dispatch, catalog generation |
| `test_container.sh` | 28 | Container management, distro resolution, proot-distro |
| `test_download.sh` | 10 | URL download, local copy |
| `test_email.sh` | 107 | Gmail/ProtonMail/Zoho/Tuta + Guerrilla Mail, SMTP/IMAP, Bridge |
| `test_git.sh` | 63 | Git identity, SSH keygen, remote, push guard |
| `test_gsuite.sh` | 35 | OAuth2 device flow, Gmail/Drive/Docs API, validation |
| `test_init.sh` | 38 | Project scaffolding, type resolution, 7 project types |
| `test_journal.sh` | 36 | Temporal memory, decay tiers, auto-greeting |
| `test_llm.sh` | 229 | LLM config, tokens, model library, dual-model, scenario sampling |
| `test_lodge.sh` | 167 | Main REPL, command wiring, soul toggle, session lifecycle |
| `test_ls.sh` | — | File listing, workspace discovery |
| `test_memory.sh` | 57 | GEORGE.md sections, compaction, snapshots |
| `test_models.sh` | 118 | Model registry, 7 families, hot-swap routing, Modelfile generation |
| `test_pgp.sh` | 34 | PGP signing, verification, Ed25519 key management |
| `test_phone.sh` | 43 | Phone integration, Termux API, vitals dashboard |
| `test_providers.sh` | 32 | 11 cloud AI providers, dispatcher, aliases, fallback |
| `test_recall.sh` | 71 | FTS5 indexing, BM25 search, self-review, quality scoring |
| `test_sandbox.sh` | 63 | Sandbox lifecycle, build, per-sandbox permissions |
| `test_save.sh` | 25 | File save, directory auto-creation |
| `test_secrets.sh` | 30 | Vault encrypt/decrypt, rotate, import, AES-256-CBC |
| `test_security.sh` | 56 | Allowlist, signing, HMAC verification, encryption |
| `test_service.sh` | 44 | Service command, daemon management |
| `test_slash.sh` | 53 | Custom commands: create, template, rename, compose, export |
| `test_social.sh` | 101 | 5 platforms, Discord channels, post dispatch, multi-instance |
| `test_tools.sh` | 123 | Code extraction, file ops, safety checks, timestamp logging |
| `test_transcript.sh` | 48 | Session transcript recording, rotation |
| `test_ui.sh` | 45 | Colors, print functions, markdown rendering |
| `test_validate_gpu.sh` | 45 | GPU detection, Vulkan validation, Adreno support |
| `test_vitals.sh` | 83 | System vitals, thresholds, guards, auto-abort |
| `test_wallet.sh` | 51 | BTC/ADA/SOL wallets, network switching, send validation |
| `test_web.sh` | 150 | Web fetch, HTML parsing, DDG search, image scraping, cache |
| `test_write.sh` | 29 | File write, code extraction, directory creation |

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
| [docs/PHONE_SETUP.md](docs/PHONE_SETUP.md) | Android setup — 4 installation paths (Termux, proot, hybrid, Play Store) |
| [docs/DEBIAN_CHROMEOS_SETUP.md](docs/DEBIAN_CHROMEOS_SETUP.md) | Chromebook / Debian / Crostini setup |
| [docs/MODELS.md](docs/MODELS.md) | Model library — 18 models, 7 families, dual-model config, performance notes |
| [docs/TUNING.md](docs/TUNING.md) | Token budgets, context tuning, sampling parameters, performance baselines |
| [docs/BACKEND_VALIDATION.md](docs/BACKEND_VALIDATION.md) | LLM backend setup, validation & GPU memory math |
| [docs/ADRENO_GPU_SETUP.md](docs/ADRENO_GPU_SETUP.md) | Vulkan GPU acceleration (Adreno/Mali/phone GPUs) |
| [docs/SLASH_COMMANDS.md](docs/SLASH_COMMANDS.md) | Slash command architecture — 4-layer system, prompt injection, dispatch |
| [docs/SLASH_EXTENSIONS.md](docs/SLASH_EXTENSIONS.md) | Custom command authoring — George writes his own `/slash` commands |
| [docs/RECALL.md](docs/RECALL.md) | FTS5 knowledge base — indexing, BM25 ranking, auto-reindex |
| [docs/SANDBOXES.md](docs/SANDBOXES.md) | Sandbox isolation — proot/unshare/dir, per-sandbox permissions |
| [docs/VITALS.md](docs/VITALS.md) | System vitals — thresholds, guards, auto-abort on critical |
| [docs/LLM_CALL_MAPS.md](docs/LLM_CALL_MAPS.md) | LLM call flow maps — what calls happen per scenario |
| [docs/CRYPTO_WALLETS.md](docs/CRYPTO_WALLETS.md) | Wallet setup — BTC/ADA/SOL, vault encryption, testnet |
| [docs/PGP_SIGNING.md](docs/PGP_SIGNING.md) | PGP configuration — Ed25519 keys, commit signing |
| [docs/SOCIAL_BOTS.md](docs/SOCIAL_BOTS.md) | Social media bot setup — 5 platforms, multi-instance Mastodon |
| [docs/EMAIL_GITHUB.md](docs/EMAIL_GITHUB.md) | Email provider setup — Gmail, ProtonMail Bridge, Zoho, Tuta |
| [docs/SECRETS_VAULT.md](docs/SECRETS_VAULT.md) | Vault architecture — AES-256-CBC, PBKDF2, rotation |
| [docs/PHONE_INTEGRATION.md](docs/PHONE_INTEGRATION.md) | Termux-API deep dive — SMS, GPS, battery, clipboard |
| [docs/GEORGE_REFERENCE.md](docs/GEORGE_REFERENCE.md) | George's complete capability reference |
| [docs/MORAL_SENTIMENTS.md](docs/MORAL_SENTIMENTS.md) | George's ethical framework (Adam Smith's moral philosophy) |
| [SECURITY.md](SECURITY.md) | Full security audit, threat model & implementation |

### Examples

| Example | Language | What It Builds |
|---------|----------|---------------|
| [docs/examples/url-shortener.md](docs/examples/url-shortener.md) | Python | URL shortener API (stdlib only) |
| [docs/examples/rust-task-manager.md](docs/examples/rust-task-manager.md) | Rust | CLI task manager with clap |
| [docs/examples/personal-assistant.md](docs/examples/personal-assistant.md) | — | Using George as a phone assistant |

## License

MIT