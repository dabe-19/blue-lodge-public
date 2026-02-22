# ⌂ George — Blue Lodge Coding Agent

A lightweight, mobile-first coding agent and personal AI assistant powered by local LLMs via Ollama. Meet **George** — named for Brother George Washington, with the wit of Benjamin Franklin and the moral philosophy of Adam Smith. He runs entirely offline, no cloud required.

## Why?

Cloud-based coding agents like Claude Code don't work with small local models. The massive system prompts, streaming protocol mismatches, and token-hungry architectures cause them to hang on 4B parameter models. George replaces all of that with a purpose-built agent that:

- **Calls Ollama directly** — no proxy, no API keys, no internet needed
- **Uses small, focused prompts** — ~1-2K tokens per step, fits in 8K context
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

> **On Android?** See the [Phone Setup Guide](docs/PHONE_SETUP.md) for F-Droid → Termux → Ubuntu → Ollama instructions.

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
│   ├── api.sh         # REST API client (curl, auth, retry, rate-limit)
│   ├── social.sh      # Social media (X, Mastodon, Bluesky, Discord, Telegram)
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
│   └── backup-repo/   # Git-based backup repository
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
| `/backup <cmd>` | — | Backup & restore George's identity |
| `/phone <cmd>` | — | Termux integration (battery/clip/notify/open/share/toast) |
| `/ask <question>` | — | Quick question (no file changes) |
| `/read <file>` | — | Read a file |
| `/files` | — | List workspace files |
| `/compact` | — | Compress memory file |
| `/snapshot` | — | Checkpoint memory |
| `/cd <dir>` | — | Change directory |
| `/clear` | — | Clear screen |
| `/quit` | — | Exit |

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
export LLM_MAX_TOKENS="8192"  # Max output tokens (default)
```

## Cancellation

Ctrl+C is always safe:

- **During generation** → kills the HTTP request to Ollama, unloads the model, returns to the REPL
- **Between steps** → stops the task, records progress in CLAUDE.md, returns to the REPL
- **At the prompt** → exits cleanly, unloads the model

All persistence (CLAUDE.md, journal) lives in files, not model state. Unloading the model never loses progress.

## Sandboxes

Lightweight project isolation without Docker:

```bash
lodge /sandbox new my_app rust    # Create Rust sandbox
lodge /sandbox new scraper python # Create Python sandbox
lodge /sandbox list               # List all sandboxes
lodge /sandbox cd my_app          # Switch to sandbox
lodge /sandbox build my_app       # Build in sandbox
lodge /sandbox clone owner/repo   # Clone + setup repo
```

## Phone Integration (Termux)

When running in Termux, George integrates with your phone:

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

George can spin up full Linux environments using `proot-distro` — no Docker, no root required. These are real distro rootfs running under proot: lightweight, fast to install, and they share the host kernel.

```bash
lodge /container install ubuntu    # Install Ubuntu container
lodge /container install kali      # Install Kali Nethunter
lodge /container install alpine    # Install Alpine (lightweight)
lodge /container list              # List installed containers
lodge /container login ubuntu      # Interactive shell
lodge /container exec kali nmap -sV target.com  # Run a command
lodge /container here ubuntu make  # Run with current dir at /workspace
lodge /container info ubuntu       # Show container size/details
lodge /container pentest           # One-command Kali + top tools setup
lodge /container rm ubuntu         # Remove a container
```

### Pentest Quick-Start

```bash
lodge /container pentest    # Installs Kali + nmap, sqlmap, nikto, hydra, metasploit...
lodge /container login kali # Drop into Kali shell
# Now you have a full pentest toolkit on your phone
```

## Security

George executes LLM-generated code. Security measures include:

- **Permission system** — asks before running destructive commands (default)
- **Workspace sandboxing** — refuses to write files outside the project directory
- **Dangerous command detection** — blocks `rm -rf`, `curl|bash`, reverse shells, `sudo`, etc.
- **No network dependency** — everything runs locally, no data leaves the device
- **Graceful cancellation** — Ctrl+C cleanly kills requests and frees resources

See [SECURITY.md](SECURITY.md) for the full audit, threat model, and recommendations.

## Hardware Targets

| Device | RAM | Status |
|--------|-----|--------|
| Galaxy Fold 7 (Snapdragon 8 Elite) | 12GB | Primary target |
| Galaxy S25 Ultra | 12GB | Supported |
| Chromebooks (ARM) | 8GB+ | Supported |
| Any Linux device | 8GB+ | Supported |
| Raspberry Pi 5 | 8GB | Should work (slower) |

## Model

Ships with **Qwen3-4B-Instruct** (Q5_K_M quantization) via Ollama. ~3GB download, ~4GB loaded RAM.

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

George includes a comprehensive pure-bash test suite with **400+ assertions** across 15 test modules. No external test dependencies required.

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
| `test_backup.sh` | 32 | Local/git backup, restore, pruning |
| `test_commands.sh` | 19 | Slash command registration & dispatch |
| `test_container.sh` | 28 | Container management, distro resolution |
| `test_journal.sh` | 21 | Temporal memory, decay, greetings |
| `test_llm.sh` | 23 | LLM config, token estimation, cancellation |
| `test_lodge.sh` | 35 | Main script, command wiring, REPL heuristic |
| `test_memory.sh` | 27 | CLAUDE.md sections, compaction, snapshots |
| `test_providers.sh` | 32 | 10 AI providers, dispatcher, aliases |
| `test_sandbox.sh` | 15 | Sandbox lifecycle, build, remove |
| `test_social.sh` | 31 | 5 platforms, missing key handling |
| `test_tools.sh` | 28 | Code extraction, file ops, safety checks |
| `test_ui.sh` | 39 | Colors, print functions, markdown rendering |
| `test_web.sh` | 27 | Web fetch, HTML parsing, cache |

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