# ⌂ George — An Experimental AI Agent, Written in Bash

George is an experiment: an AI coding agent written entirely in bash that runs offline on a phone with 3-4B parameter models. He's not finished, he has rough edges, and he was built primarily with LLM assistance by someone who is not a software engineer. But the core pattern — scenario-routed prompts that keep context small enough for tiny models to be useful — actually works, and the thing keeps evolving.

~63,000 lines of bash. No cloud required. No API keys required. No Docker. No Node.js. No Python runtime. Just `curl`, `jq`, `git`, `sqlite3`, and a mass of pure bash.

> *Named for Brother George Washington, with the wit of Benjamin Franklin and the moral philosophy of Adam Smith.*

### ⚠️ Current State

This is an active development project by a single person (a process control engineer, not a software engineer). George works well enough to be useful and interesting, but:

- **Small models have real limitations** — George can scaffold projects and fix code, but he's not going to outperform Claude Code or Cursor with a frontier model. The value proposition is different: privacy, offline capability, zero cost, and running on hardware you own.
- **Bash is a wild choice** — it's everywhere (which is the point), but it's harder to maintain and debug than Python or TypeScript. There are surely bugs I haven't found yet.
- **This was built with heavy LLM assistance** — I came along and found the lego blocks that veteran programmers of the past few decades created, and mashed them together. The honest framing is that this is a community's worth of knowledge, assembled by someone learning in public.
- **The test suite is extensive (3,578 assertions, all passing) but I'm still learning** what good testing actually means. Coverage doesn't equal correctness.
- **Some features are more mature than others** — the core agent loop, memory system, and web scraping are solid. Some integrations (email, social, wallets) are functional but less battle-tested.

---

## The Numbers

These are the current counts. The project has been growing steadily — most of this was written in partnership with LLMs over several months.

| | Lines |
|---|---|
| **Application code** (lodge + lib/ + commands/) | ~37,300 |
| **Test code** (tests/) | ~25,800 |
| **Grand total** (all bash) | ~63,100 |

| | Count |
|---|---|
| **Slash commands** | 50 registered |
| **Test modules** | 43 |
| **Test assertions** | 3,578 (all passing) |
| **Library modules** | 31 (lib/) |
| **Built-in command scripts** | 12 (commands/) |
| **Model configurations** | 9 (system prompts + Modelfiles) |
| **Documentation pages** | 32+ |
| **Cloud AI providers** | 10 (all optional) |

---

## Why This Exists

I'm an industrial controls engineer. I've been doing continuous process control for 15 years. I write structured text, function block logic, and sequential function charts — not applications. I have a master's in engineering data analytics (UW-Madison, Go Badgers), and I use Python and R for ML work. I am not a software engineer.

This started because I wanted to keep working on projects from my phone without being chained to a desk. I got Ollama running in Termux on my Galaxy Fold 7, pulled down a 3B model, and tried to use existing agentic tools. They didn't work — those tools are built around massive system prompts designed for 70B+ models with 128K context windows. A 3B model just chokes on them.

So I started building something that could work within those constraints. It was supposed to be a project to learn bash. It became... this.

### The Core Idea: Scenario-Routed Prompts

The insight that makes George interesting (whether or not it's novel, I honestly don't know) is this: cloud coding agents use a **monolithic prompt architecture** — one giant system prompt crammed with identity, capabilities, tool definitions, safety rules, and conversation history. Every LLM call pays the full cost of that context, even for a simple commit message.

George uses **scenario-routed prompts** — different prompt shapes for different jobs:

| Scenario | Prompt Size | What's Included |
|----------|-------------|-----------------|
| `/q` (quick question) | ~250 tokens | Condensed identity + conversation ring buffer |
| Planning (light) | ~700 tokens | Identity + lean command catalog |
| Planning (dense) | ~5,000 tokens | Full soul + catalog + recall chunks |
| Task execution | ~3,500 tokens | Identity + full catalog + memory + recall |
| Tool routing | ~150 tokens | Just the tool list |

A 3-4B model with a 700-token prompt performs significantly better than the same model with an 8K-token prompt. Less noise, more signal. Whether this is a "design advantage" or just "the only way to make small models work" is a matter of perspective — but the result is that George can actually do useful things on hardware that cloud agents can't even start on.

### The Machine That Reads Its Own Source Code

There's something worth pausing on here. George is a bash script. Bash scripts run as processes with full filesystem access. George's code, his memory, his personality (`soul.md`), his journal, his recall database — they're all just files on disk. Files he can read. Files he can write. Files he can modify.

This is not a sandboxed language model behind an API gateway. This is an AI agent harness, written in the language of the operating system itself, running with whatever permissions you gave it, with direct access to its own source code and the tools to edit it.

Let that sink in.

Every cloud AI agent runs in a container, behind a reverse proxy, with a permissions model designed to keep it from touching anything real. George runs in your shell. He writes files with `cat >`. He executes code with `bash -c`. He reads his own memory with `cat GEORGE.md`. He extends himself by writing new slash commands to disk and registering them at runtime. When George modifies a file in your project, there is no API abstraction layer — `sed -i` hits the inode directly.

The security implications are real, and we take them seriously (command allowlists, dangerous command detection, HMAC-signed memory, permission levels — see [SECURITY.md](SECURITY.md)). But the *architectural* implications are what make this interesting from a systems perspective:

- **Self-modification is native.** George doesn't need a plugin system or a tool-use API to extend himself. `/slash create` writes a bash script and sources it. The agent *is* the shell.
- **The filesystem is the context window.** While cloud agents stuff everything into a system prompt, George's knowledge lives in files — `soul.md`, `GEORGE.md`, `journal.md`, `recall.db`. He reads what he needs, when he needs it. The OS is his memory manager.
- **System-level tool access is the default.** `curl`, `git`, `ssh`, `openssl`, `gpg`, `sqlite3` — these aren't "tools" George calls through a JSON schema. They're binaries on `$PATH` that he invokes directly. The entire Unix toolchain is his toolkit.
- **The agent and the environment are the same thing.** There's no boundary between "the AI agent" and "the system it runs on." George is a process. His state is files. His tools are binaries. When you run George, you're not talking to an AI through an interface — you're running an AI *as* an interface to your machine.

This is the closest thing to a cyberpunk deck program that exists in the real world right now: a self-aware agent living in the filesystem, running on the bare metal, reading its own soul from a Markdown file, and writing its own new capabilities to disk. The fact that it's written in bash — the oldest, ugliest, most universal scripting language on earth — is either poetic or horrifying, depending on your perspective.

It's both. That's the point.

### Where George Fits

George isn't trying to compete with frontier-model cloud agents. The tradeoffs are real:

| | Cloud Agents (Claude Code, Cursor, etc.) | George |
|---|---|---|
| **Runs on** | Remote servers | Your phone, laptop, or any Linux box |
| **Internet required** | Always | Never (optional for web/social features/cloud providers) |
| **Cost** | $20-200/month | Free |
| **Privacy** | Your code goes to their servers | Your code never leaves your device |
| **Model quality** | 70B-400B+ parameters | 3-4B parameters — works within limits |
| **Code quality** | Generally excellent | Varies — good for scaffolding and fixes, weaker on complex logic |
| **Architecture** | Monolithic system prompt (~8-32K tokens) | Scenario-routed prompts (~250-1,500 tokens) |
| **Language** | TypeScript/Python + Docker + many deps | Pure bash — four binary dependencies |
| **Self-extending** | No | George writes his own new slash commands, modifies his own task list |

### Why Bash

Because bash is everywhere. Every Linux box, every Android phone running Termux, every Chromebook, every WSL instance, every Raspberry Pi — bash is already there. No package manager, no build step, no virtual environment, no container runtime. `git clone` and `source`. That's the entire dependency chain for the core.

The tradeoff is real: bash is harder to write, harder to maintain, and harder to debug than Python or TypeScript. I would not necessarily recommend bash for a project like this. But it does mean George runs on any POSIX system with four binaries, and that constraint turned out to be worth it for the target use case (a phone in Termux).
| Tool routing | ~150 tokens | Just the tool list |

A 3-4B model with a 700-token prompt performs significantly better than the same model with an 8K-token prompt. Less noise, more signal.

### The Agent Loop

George doesn't just call an LLM and paste the output. He runs a dual-loop architecture with milestone tracking, evaluators, and dynamic replanning. This is the most experimental part of the project — it works, but the evaluation step is only as good as the small model running it, and sometimes George confidently declares success on things that aren't quite right.

```
User Task
  │
  ▼
┌──────────────────────────────────────────────────┐
│  HONEYDEW LIST (task decomposition)              │
│  LLM breaks task → 3-5 deliverable items         │
│  Dynamic rewrite after each milestone             │
│                                                   │
│  MACRO LOOP (Strategist)                          │
│  Picks next milestone from honeydew list          │
│  Tracks progress in MACRO_MEMORY                  │
│  Uses PRIMARY model (thinking)                    │
│                                                   │
│  For each milestone:                              │
│  ┌─────────────────────────────────────────────┐  │
│  │  INNER LOOP (Router → Specialist → Eval)    │  │
│  │  Router picks tool (SECONDARY model, fast)  │  │
│  │  Specialist executes (PRIMARY model)        │  │
│  │  P1 Evaluator: did milestone succeed?       │  │
│  │  Honeydew Evaluator: did item get satisfied?│  │
│  │  On failure → escalate L1 → L2 → rewrite   │  │
│  └─────────────────────────────────────────────┘  │
│                                                   │
│  P2 Evaluator: is the overall task done?          │
│  Update memory, check vitals, next milestone      │
└──────────────────────────────────────────────────┘
```

The **honeydew list** is George's task decomposition — a numbered list of concrete deliverables derived from the user's request. After each milestone, the honeydew evaluator checks whether items have been satisfied, and the list dynamically rewrites itself based on what was discovered. This means George adapts his plan as he works, not just at the start.

The thinking model handles planning and execution. The instruct model handles fast routing decisions. Only one model is in memory at a time — George hot-swaps between them automatically.

### Every Session Is a Training Dataset

Here's something that falls out of the architecture for free: George's session transcripts are structured agent trajectory logs. Every task produces a timestamped Markdown transcript recording every decision the agent loop made — and every judgment it passed on those decisions:

```
── Honeydew List
  1. [ ] Create the Rust project and implement FizzBuzz logic
  2. [ ] Build the project and verify compilation

── Milestone 1: Use /init to scaffold a Rust project named fizzbuzz
  [strategist]  "Use /init to scaffold a Rust project named fizzbuzz"
  [router]      /init (pre-routed)
  [specialist]  /init fizzbuzz rust
  [output]      (exit 0 — project scaffolded)
  [eval-p1]     COMPLETE
  [eval-hd]     UNSATISFIED — project created but FizzBuzz logic not implemented

── Milestone 2: Use /write to implement FizzBuzz logic
  [specialist]  /write fizzbuzz/src/main.rs fn main() { ... }
  [output]      (exit 0 — file written)
  [eval-p1]     COMPLETE
  [eval-hd]     SATISFIED — item #1 done
```

Every role in the agent loop — **strategist** (task decomposition), **router** (tool selection), **specialist** (command generation), **evaluator** (milestone verdict and honeydew satisfaction) — is logged with its input context, its output, and its judgment. The evaluator grades don't just say pass/fail — they explain *why* ("`UNSATISFIED — project created but FizzBuzz logic not implemented`").

This is, structurally, an **agent decision-making trajectory dataset with inline labels and evaluations**. The kind of data that takes ML teams weeks to collect and annotate by hand.

What makes this interesting for researchers:

- **Auto-labeled preference pairs.** When the evaluator marks a milestone `INCOMPLETE` and George escalates (L1 → L2 → honeydew rewrite), you get a rejected trajectory and a chosen trajectory from the same task — the raw material for DPO/RLHF preference tuning.
- **Multi-role annotation.** Each decision point is tagged by role (strategist/router/specialist/evaluator), so you can train or evaluate each capability independently. A model that routes well but generates bad code looks different in the logs than one that generates good code but picks the wrong tools.
- **Any model, any provider.** Because George can harness any model — local 3B models, cloud 70B models, anything Ollama or a provider serves — you can generate trajectory datasets from *any* model and compare them. Run the same task through Gemma 4B and Llama 70B, diff the transcripts, and you have cross-model behavioral comparisons for free.
- **Self-grading benchmark potential.** The [George Gym](docs/GYM.md) defines repeatable workouts with expected traces and pass/fail criteria (P/D/L/F grading). Run any model through the gym, score the transcripts, and you have a benchmark for agent loop competence on small models — something that doesn't really exist in the standard eval suites.
- **The seed alignment dataset.** The Gym's planned RLHF schema captures chosen/rejected pairs at every decision point: did the strategist pick the right next milestone? Did the router select the right tool? Did the evaluator calibrate correctly on exit 0 vs. actual task completion? These preference pairs, accumulated across workouts and models, form a seed alignment dataset for fine-tuning models specifically on agent decision-making — not just "write good code" but "decompose tasks well, pick the right tools, know when to stop researching, and evaluate your own work honestly."

The transcripts are just Markdown files in `~/.george/transcripts/`. No special infrastructure. No logging framework. `cat` them, `grep` them, feed them into your training pipeline. Every George session you run is generating data.

---

## Quick Start

```bash
git clone https://github.com/dabe-19/blue-lodge-public.git ~/blue-lodge
bash ~/blue-lodge/install.sh
source ~/.bashrc # I am a personal fan of https://github.com/ohmyzsh/ohmyzsh thank you for making life easier (especially on a mobile terminal) @robbyrussel

lodge                              # Interactive REPL
lodge /init myapp rust             # Scaffold a Rust project
lodge "add error handling"         # Give it a coding task
lodge /q "what is a monad?"        # Quick question
lodge /models list                 # Browse the model library
```

> **On Android?** See the [Phone Setup Guide](docs/PHONE_SETUP.md) — four paths: Termux-native (recommended), proot Ubuntu, hybrid, or Play Store fallback.
>
> **On a Chromebook?** See the [Debian/ChromeOS Setup](docs/DEBIAN_CHROMEOS_SETUP.md).

---

## What George Can Do (and Mostly Does)

These features exist and are tested. "Tested" means the plumbing works — the slash commands dispatch, the API calls form correctly, the parsers parse. How well the LLM uses them on any given task depends on the model, the prompt complexity, and luck. Some of this works great. Some of it works well enough to be useful. Some of it is ambitious and still evolving.

### Code & Projects
- **Scaffold** projects (Rust, Python, Shell, RL, data science, automation, notebooks) with optimized build profiles
- **Write, fix, build, test** — full development cycle from a single prompt
- **AI commit messages** with **git push**, branch management, and SSH key generation
- **Clone + auto-setup** any GitHub repo into an isolated sandbox
- **Sandboxes** — isolated project environments (proot / unshare / directory fallback)
- **8 Linux containers** via proot-distro (Ubuntu, Kali, Alpine, Debian, Fedora, Arch, Void, openSUSE)
- **Cascade error recovery** — if the first fix fails, George escalates with more context and retries

### Agent Intelligence
- **Honeydew list** — LLM-generated task decomposition with dynamic replanning after each milestone
- **Three-tier evaluation** — milestone evaluator (P1), honeydew item evaluator, overall task evaluator (P2)
- **Auto-recovery** — when stuck, George rewrites the honeydew list and retries from a fresh angle
- **Brainstorm mode** — `/brainstorm` for self-reasoning without human input (toggleable via `AGENT_BRAINSTORM`)
- **Human-in-the-loop** — `/ask` lets George ask the user questions during task execution (toggleable via `AGENT_ASK_USER`)
- **Interlock protection** — detects repeated identical failed commands and forces regeneration
- **Provider fallback** — optionally route complex queries through cloud providers when local models aren't enough

### Memory & Knowledge
- **Project memory** — `GEORGE.md` tracks milestones, considerations, and context per project (survives crashes)
- **Living journal** — temporal memory with decay (recent = vivid detail, 3-60 days = summaries, 60+ days = impressions)
- **FTS5 knowledge base** — BM25-ranked SQLite full-text search over docs, journal, and ingested files (~50-100KB on disk, <1ms queries, 0 RAM)
- **Document ingestion** — index PDFs, Markdown, code, HTML, DOCX into the knowledge base
- **Conversation ring buffer** — last 3 exchanges for `/q` conversational continuity
- **Macro/micro memory** — strategist tracks milestones, inner loop tracks actions per objective
- **Auto-compact** — old steps compress to impressions; snapshots save checkpoints to roll back to

### Web Browsing
- **Single-GET architecture** — one HTTP request per page, Content-Type routed from response headers (no double-fetch)
- **Search** — DuckDuckGo HTML scraping (free, no API key), Serper.dev, or Perplexity as alternatives
- **Fetch, summarize, download** — text/HTML/JSON/XML/PDF all handled inline
- **Image search** — scrape image results from pages or use Serper
- **URL blacklisting** — automatically blocks URLs that returned captchas or challenges
- **Centralized HTTP client** — modern User-Agent, compression, cookie persistence, Accept-Language headers

### Integrations (All via curl — No SDKs)
- **5 social platforms** — X, Mastodon (multi-instance), Bluesky, Discord (bot + webhook + channel registry), Telegram
- **4 email providers** — Gmail, ProtonMail (Bridge), Zoho, Tuta (+ Guerrilla Mail disposable addresses)
- **10 cloud AI providers** — OpenAI, Anthropic, Google (AI Studio + ADK), Groq, Mistral, Together, Perplexity, Cohere, DeepSeek, xAI — all optional, never required
- **Google Workspace** — Gmail, Drive, Docs via OAuth2 device flow (no browser redirect needed on mobile)
- **Crypto wallets** — Bitcoin, Cardano, Solana (balance + send + vault-encrypted keys + testnet support)
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
- **Session transcripts** — every task produces a timestamped Markdown transcript with model, backend, duration, and full command output

---

## Architecture

~37,300 lines of application code. ~25,800 lines of tests. Pure bash. No Node.js, no Python runtime, no Docker. Four binary dependencies. Most of this was written in partnership with LLMs — I provided the architecture, the process flow thinking, and the "what should this do" requirements; the LLMs provided the "how to do it in bash" implementation. I've learned an enormous amount doing this.

### Project Layout

```
~/blue-lodge/
├── lodge              # Main TUI entry point (4,668 lines)
├── soul.md            # George's personality & ethical framework
├── lib/
│   ├── agent.sh       # Dual-loop agent: strategist + evaluators + honeydew (5,784 lines)
│   ├── llm.sh         # Dual backend: Ollama + llama.cpp (3,125 lines)
│   ├── models.sh      # Model library & hot-swap routing (1,656 lines)
│   ├── providers.sh   # 10 cloud AI providers (1,604 lines)
│   ├── web.sh         # Web browsing, search & single-GET fetch (1,599 lines)
│   ├── email.sh       # 4 email providers + SMTP/IMAP (1,549 lines)
│   ├── social.sh      # 5 social platforms + multi-instance registry (1,374 lines)
│   ├── recall.sh      # FTS5 knowledge base with BM25 ranking (1,133 lines)
│   ├── mcp.sh         # MCP client — pure bash, JSON-RPC 2.0 over stdio (1,051 lines)
│   ├── tools.sh       # Bash/file/slash execution + safety (1,003 lines)
│   ├── backup.sh      # Backup/restore identity + auth export (949 lines)
│   ├── wallet.sh      # BTC/ADA/SOL wallets + vault-encrypted keys (865 lines)
│   ├── reflexive.sh   # Reflexive intelligence layer (670 lines)
│   ├── vitals.sh      # System vitals with auto-abort guards (640 lines)
│   ├── sandbox.sh     # Project isolation (proot/unshare/dir) (635 lines)
│   ├── slash.sh       # Self-extending custom command engine (612 lines)
│   ├── security.sh    # Signing, encryption & integrity verification (589 lines)
│   ├── pgp.sh         # PGP signing & verification (Ed25519) (578 lines)
│   ├── memory.sh      # GEORGE.md read/write/compact + prompt builder (569 lines)
│   ├── journal.sh     # Temporal memory with decay (540 lines)
│   ├── gsuite.sh      # Google Workspace (Gmail, Drive, Docs) (537 lines)
│   ├── commands.sh    # Slash command dispatcher + catalog (479 lines)
│   ├── phone.sh       # Termux-API integration (SMS, GPS, battery) (462 lines)
│   ├── git.sh         # Git identity, SSH, remote config (449 lines)
│   ├── mcp_server_fetch.sh  # Built-in MCP fetch server — pure bash (390 lines)
│   ├── secrets.sh     # Encrypted vault (AES-256-CBC, PBKDF2 100K) (389 lines)
│   ├── container.sh   # Linux containers via proot-distro (315 lines)
│   ├── api.sh         # REST client (curl, auth, retry) (303 lines)
│   ├── ui.sh          # TUI rendering (ANSI, spinners, markdown) (284 lines)
│   ├── cache.sh       # LRU cache (227 lines)
│   └── transcript.sh  # Session transcript recording (189 lines)
├── commands/          # Built-in slash commands (init, fix, test, build, commit, push, clone, write, download, service, vision, save)
├── models/            # Per-model system prompts & Modelfiles
├── tests/             # 43 test modules, 3,578 assertions
├── docs/              # 32+ documentation pages + examples
└── ~/.george/         # User data: keys, vault, backups, recall.db, slash/, cache
```

---

## Slash Commands

50 registered commands. Type `/help` inside a session for the full list.

<details>
<summary><strong>View all commands</strong></summary>

### Agent & Planning
| Command | Alias | Description |
|---------|-------|-------------|
| `/help` | `lghelp` | Show all commands |
| `/q <question>` | — | Quick question (lightweight, conversation memory) |
| `/brainstorm <topic>` | — | Self-reasoning (no human input, uses own knowledge) |
| `/ask <question>` | — | Ask the user a question (agent-only, human-in-the-loop) |
| `/plan <task>` | — | Plan a task without execution |
| `/think [on\|off\|bright\|dim\|hide\|test]` | — | Toggle thinking mode display |
| `/debug [on\|off]` | — | Toggle debug output (timers + tokens) |
| `/soul [on\|off]` | — | Toggle soul mode (condensed ~250 tok / full ~4,500 tok) |
| `/limits [steps\|depth\|milestones\|inner\|delay\|rewrite\|ask\|brainstorm]` | — | View/adjust planning bounds and toggles |
| `/model [temp\|repeat\|presence] [value]` | — | View/adjust sampling parameters |
| `/models [list\|status\|select\|single\|dual]` | — | Model library & runtime switching |
| `/config [show\|save\|reset\|edit]` | — | Persistent configuration |
| `/backend [status\|auto\|ollama\|llamacpp\|url\|start\|stop]` | — | LLM backend management |
| `/gpu [layers]` | — | GPU offload layers for llama-server |
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
| `/ls` | — | List workspace files as tree |
| `/files` | — | Alias for /ls |
| `/cd <dir>` | — | Change working directory |

### Memory & Knowledge
| Command | Alias | Description |
|---------|-------|-------------|
| `/memory` | `lgm` | Show current GEORGE.md |
| `/journal [cmd]` | — | Journal (show/vivid/fading/sediment/write/decay) |
| `/reflect` | — | Record a reflection in journal |
| `/recall <query>` | — | FTS5 search knowledge base (BM25 ranked) |
| `/recall prefs` | — | List stored user preferences |
| `/recall prune <date\|days>` | — | Prune old user preferences |
| `/recall compact` | — | LLM-summarize user preferences |
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
| `/provider [cmd]` | — | Cloud AI providers (chat/models/status) — 10 providers |
| `/web [cmd]` | — | Browse the web (fetch/search/images/summary/download) |
| `/github <query>` | — | Search GitHub repositories |
| `/mcp [cmd]` | — | MCP server integration (add/remove/start/stop/tools/call/catalog) |

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

### Transcripts & Session
| Command | Alias | Description |
|---------|-------|-------------|
| `/transcript [list\|last\|path\|show]` | — | View task transcripts |
| `/cleanup` | — | Remove George's created files |
| `/clear` | — | Clear screen |
| `/quit` | — | Exit George |

</details>

---

## Examples

These are representative of what George can do. Results vary by model and task complexity — simple scaffolding and fix cycles are reliable; complex multi-step tasks are where the experiment gets interesting (and sometimes messy).

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
$ lodge /q "Explain the difference between TCP and UDP in 3 sentences"
$ lodge /q "And when would I use each one?"    # George remembers the previous question
```

### Meal planning (real task — honeydew + web + brainstorm)

```
$ lodge "Build me a meal plan for Monday through Friday"
 ◆ Honeydew: 3 items
 ◆ Milestone 1: /ask → dietary preferences (high protein, no pork)
 ◆ Milestone 2: /web search → lean protein meal ideas
 ◆ Milestone 3: /brainstorm → draft 5-day plan
 ◆ Milestone 4: /respond → formatted meal plan
 ✓ Task complete
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

### Social media broadcast

```
> /social post "Just shipped v2.0 from my phone. No cloud, no subscription. 🔧"
  ✓ Posted to X, Mastodon, Bluesky, Discord, Telegram
```

More examples: [docs/examples/personal-assistant.md](docs/examples/personal-assistant.md)

---

## Dependencies

Pure bash. Every external binary George calls is listed here — no hidden dependencies.

### Required (core)

Installed automatically by `install.sh` if missing.

| Binary | What it does in George |
|--------|----------------------|
| **curl** | Every HTTP call — LLM requests, web fetching, APIs, social, email |
| **jq** | Parses every JSON response from LLM backends, APIs, and config |
| **git** | Version control — /commit, /push, /clone, /backup |
| **sqlite3** | FTS5 knowledge base (recall), social media state |

### Required — LLM Backend (at least one)

| Binary | What it does | Install |
|--------|-------------|---------|
| **ollama** | Primary LLM backend — model management and inference | `install.sh` auto-installs |
| **llama-server** | Alternative backend — direct GGUF loading, Vulkan GPU | User compiles ([guide](docs/ADRENO_GPU_SETUP.md)) |

### Optional

| Binary | Feature | Without it |
|--------|---------|-----------|
| **pdftotext** (poppler) | High-fidelity PDF text extraction | `strings` fallback |
| **openssl** | Secrets vault, HMAC signing | Vault unavailable; sha256sum fallback |
| **gpg** | PGP signing, git commit signing | /pgp unavailable |
| **w3m** / **lynx** | HTML→text rendering for /web | sed/awk fallback |
| **cargo** | Rust project build/test | Rust projects unavailable |
| **python3** | Python project scaffold | Python projects unavailable |
| **proot** / **proot-distro** | Sandbox isolation / Linux containers | Directory isolation fallback |

<details>
<summary><strong>Full dependency tables with install commands</strong></summary>

#### Optional — Feature-Gated

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

#### Termux-Only (Android)

Requires the [Termux:API](https://wiki.termux.com/wiki/Termux:API) companion app. Enabled with `export LODGE_TERMUX_API=1`.

| Binary | Feature |
|--------|---------|
| **termux-battery-status** | Battery level, temperature |
| **termux-clipboard-get/set** | Phone clipboard bridge |
| **termux-notification** | Push notifications |
| **termux-share** | Android share sheet |
| **termux-sms-send/list** | SMS read/send |
| **termux-location** | GPS location |
| **termux-vibrate**, **termux-toast** | Haptics, toast messages |

#### Install Commands

**Ubuntu / Debian (apt):**
```bash
# Required (auto-installed by install.sh)
sudo apt install -y curl jq git sqlite3
# Ollama (auto-installed by install.sh)
curl -fsSL https://ollama.com/install.sh | sh
# Optional
sudo apt install -y poppler-utils openssl gnupg w3m lynx python3 python3-venv pandoc make npm
```

**Termux (Android):**
```bash
# Required (auto-installed by install.sh)
pkg install -y curl jq git sqlite gawk procps bc
# Ollama (auto-installed by install.sh)
curl -fsSL https://ollama.com/install.sh | sh
# Optional
pkg install -y poppler openssl-tool gnupg w3m lynx python pandoc make nodejs proot proot-distro termux-api
```

</details>

### What George Does NOT Use

- **No Node.js runtime** — npm is only called for Node.js project builds, never for George itself
- **No Python runtime** — python3 is only called for Python project scaffolding, never internally
- **No Docker** — sandboxes use proot/unshare; containers use proot-distro
- **No pip packages** — no PyPDF2, no requests, no third-party Python
- **No cloud services for core function** — LLM inference is always local. Cloud providers are opt-in extras.

---

## Models

Ships with a model library of pre-configured models across 7 families. Default pair:

- **Primary:** Ministral-3-3B-Reasoning — deep reasoning, planning, and code generation
- **Secondary:** Ministral-3-3B-Instruct — fast tool routing, commit messages, web summaries (+ vision)

All models are 1-4B parameters at Q4-Q8 quantization. Only one is loaded at a time. George hot-swaps automatically — consecutive same-model calls are free, swaps happen only at scenario boundaries.

| Family | Strengths |
|--------|-----------|
| **Ministral** | Default pair. Strong reasoning + fast utility. Vision on instruct. |
| **Qwen3** | Best nothink support. Good multilingual. |
| **Qwen 3.5** | Newest generation. 256K native context. |
| **Llama 3.2** | Meta's flagship small model. 128K native context. |
| **Granite 4** | IBM's code-tuned family. Hybrid saves ~200MB. |
| **Gemma 3** | Google multimodal. 4B has vision. 1B ultra-lightweight. |
| **Phi-4** | Microsoft. Math/logic specialist. MIT license. |

```bash
lodge /models list                          # Show all models
lodge /models select primary granite4       # Switch primary model
lodge /models select secondary qwen35-2b    # Switch secondary
lodge /models single minist-think           # Single-model mode
lodge /models dual                          # Back to dual-model
```

### Performance Expectations

| Hardware | Model Load | Sustained Generation | Reported tok/s |
|----------|-----------|---------------------|----------------|
| Snapdragon 8 Elite (12GB) | 5-15 seconds | 15-30 tok/s | ~7-15 tok/s (load amortized) |
| Desktop SSD (32GB+) | 1-3 seconds | 25-50 tok/s | ~20-40 tok/s |
| Raspberry Pi 5 (8GB) | 15-30 seconds | 5-10 tok/s | ~3-7 tok/s |

> **Why reported numbers look low:** Benchmark tok/s includes model load time. During sustained generation (multi-step agent runs), actual throughput is 2-3x the headline number.

### Dual LLM Backend

| Backend | Best For | GPU Acceleration |
|---------|----------|-----------------|
| **Ollama** | Easy setup, broad compatibility | Via Ollama's built-in support |
| **llama.cpp** | Direct hardware control, Vulkan GPU | Native Vulkan (Adreno, Mali, etc.) |

```bash
export LLM_BACKEND=llamacpp
export LLAMA_CPP_SERVER_BIN=~/llama.cpp/build/bin/llama-server
```

Full model documentation: [docs/MODELS.md](docs/MODELS.md) | Backend setup: [docs/BACKEND_VALIDATION.md](docs/BACKEND_VALIDATION.md) | GPU guide: [docs/ADRENO_GPU_SETUP.md](docs/ADRENO_GPU_SETUP.md)

---

## Deep Dive

### Knowledge Base (FTS5 Recall)

SQLite FTS5 with BM25 ranking. George chunks knowledge sources by `##` headers and indexes them. The index auto-rebuilds when source file mtimes change. **~50-100KB on disk, <1ms per query, 0 RAM overhead.**

When answering questions, recall injects matching snippets into the system prompt — up to 4 chunks for tasks, 1 chunk for quick questions. Why FTS5 over vector embeddings? George's corpus is small (~15KB). BM25 with Porter stemming matches or beats vectors at this scale, with zero RAM vs 300MB+ for an embedding model.

### Memory System

Three persistent layers that survive crashes, restarts, and model swaps:

- **GEORGE.md** (per-project) — active task, milestones, validation steps, context files. Auto-compacted when old steps compress to impressions.
- **journal.md** (cross-session) — temporal memory with decay: vivid (0-3 days), fading (3-60 days), sediment (60+ days).
- **FTS5 Recall** — BM25-ranked knowledge base. Zero-cost queries.
- **Conversation ring buffer** — last 3 `/q` exchanges for conversational continuity.
- **Macro/Micro memory** — strategist writes milestone tracking, inner loop writes action logs. Both persist.

### Model Memory Management

On a 12GB phone, RAM is shared between Android, Termux, the LLM, and builds. George manages the model lifecycle:

| Event | Action |
|-------|--------|
| Task starts | Model loaded on-demand (~5-15s ARM, ~1-3s desktop) |
| Consecutive same-model calls | Free — no swap |
| Scenario boundary | Hot-swap: unload current, load target |
| Task completes | Model unloaded (~4GB freed for builds) |

Ctrl+C is always safe. All persistence lives in files, not model state.

### Sandboxes

Lightweight project isolation without Docker:

| Method | Isolation | Detection |
|--------|-----------|-----------|
| **proot** | Medium | Default on Termux |
| **unshare** | Medium-High | Linux user namespaces |
| **directory** | Basic | Always available (fallback) |

### MCP Client — Pure Bash, JSON-RPC 2.0 Over Stdio

George includes a full [Model Context Protocol](https://modelcontextprotocol.io) client — 1,051 lines of pure bash. No Python bridge, no Node.js runtime. Just bash, jq, and FIFOs.

MCP is the emerging standard for giving AI agents access to external tools. Anthropic defined the protocol, and there's a growing ecosystem of MCP servers (fetch, puppeteer, GitHub, Brave search, SQLite, filesystem, etc.). George can talk to all of them.

```bash
/mcp on                                    # Enable MCP integration
/mcp install fetch                         # Install the built-in fetch server
/mcp start fetch                           # Start it (JSON-RPC handshake)
/mcp tools fetch                           # List available tools
/mcp call fetch fetch '{"url":"https://example.com"}'  # Call a tool
```

The implementation uses a FIFO for server stdin and a regular file for stdout — a transport design that took several iterations to get right. FIFOs for *reading* responses caused deadlocks inside `$()` subshells (bash forks a new process for command substitution, and the forked reader blocks on the FIFO). The solution: write requests to a FIFO (atomic for < PIPE_BUF), but poll a regular append-only file for responses. A `sleep` process holds the FIFO write-end open so the server doesn't see EOF between requests.

What makes this interesting:

- **MCP-first dispatch.** When MCP is enabled, George checks MCP servers for matching tools *before* falling back to native slash commands. An MCP fetch server takes priority over George's built-in curl pipeline.
- **Built-in fetch server.** George ships with `mcp_server_fetch.sh` — a pure-bash MCP server that exposes George's own web scraping engine (6 tools: fetch, fetch_json, fetch_pdf, web_search, web_images, github_search) over the MCP protocol. No Node.js. Other George instances or MCP-compatible agents can connect to it.
- **Agent catalog injection.** Running MCP server tools are automatically injected into the system prompt so the strategist and specialist can discover and use them during task planning.
- **LRU-cached tool catalogs.** Tool lists from MCP servers are cached (via the LRU cache below) so the agent loop doesn't re-query tool listings on every turn.

The test suite (51 assertions) validates the full protocol stack against a mock server: handshake, tool discovery, tool invocation, multi-server isolation, FIFO transport, cache integration, and dispatch intercept. The built-in fetch server has its own test suite (74 assertions) that runs the *actual server process* for protocol compliance — not mocks.

See [docs/MCP.md](docs/MCP.md) for full setup and architecture.

### LRU Cache — Filesystem as Data Structure

George has a problem every bash program has: subshells destroy state. Every `$()` command substitution forks a new process — variable changes inside are invisible to the parent. You can't build an in-memory cache in bash because the cache vanishes every time you call a function inside `$()`. And George calls functions inside `$()` constantly.

The solution is a file-backed LRU cache that uses the filesystem itself as the data structure:

```
"Hash Map":     md5sum(key) → filename
"LRU Ordering": file mtime (managed by the kernel)
"Promote":      touch $file (updates mtime → O(1))
"Evict LRU":    ls -1tr | head -N | rm (oldest mtime first)
```

A classical LRU uses a hash map + doubly linked list with pointer splicing. Bash has no pointers, no structs, no heap. But the kernel already tracks file modification times, and `touch` updates an mtime in O(1). That's the promote operation. `ls -1tr` sorts by mtime ascending — the first entries are the least recently used. That's the eviction scan. The "hash map" is just `md5sum(key) → filename` — O(1) lookup via the filesystem's own directory hash table.

| Operation | Classical LRU | George's Filesystem LRU |
|-----------|---------------|------------------------|
| Lookup | hash map → pointer | md5sum → `cat $file` |
| Promote | splice 4 pointers | `touch $file` |
| Evict | remove tail, relink | `ls -1tr \| head -1 \| rm` |
| Survives subshells? | No | **Yes** |
| Survives crashes? | No | **Yes** |

On top of this, the cache adds two features classical LRUs don't have:

- **Namespace generation invalidation (O(1)).** Each namespace (recall, mcp, memory) has a generation counter in a `.gen.<ns>` file. When you invalidate a namespace, the counter bumps by 1. Entries created under the old generation are stale on next read — no scanning required. This is how George instantly invalidates all recall cache entries when the knowledge base changes.
- **TTL expiration.** Each cache entry's header stores its creation epoch. Reads older than `CACHE_TTL` (default 5 min) are treated as misses. Combined with generation checks, this gives two independent staleness signals.

The primary consumer is recall — the FTS5 knowledge base query that runs on every agent turn. Without caching: fork `sqlite3`, run BM25 query, parse results — ~10-30ms. With caching: `stat` + `cat` on tmpfs — ~1-2ms. During multi-step agent loops with 6-10 inner iterations, that's 100-300ms of overhead eliminated per milestone.

227 lines. 32 entries. Hit rates typically 60-80% during agent loops. See [docs/LRU_CACHE.md](docs/LRU_CACHE.md) for the full design document.

### Security

George executes LLM-generated code. Multiple layers of protection:

- **Permission system** — asks before running destructive commands
- **Command allowlist** — 100+ safe prefixes auto-approved
- **Dangerous command detection** — blocks `rm -rf`, `curl|bash`, reverse shells, `sudo`
- **HMAC-signed memory** — `soul.md` and `journal.md` verified at startup
- **Encrypted vault** — AES-256-CBC with PBKDF2 (100K iterations)
- **Workspace sandboxing** — refuses writes outside the project directory
- **No network dependency** — everything runs locally

See [SECURITY.md](SECURITY.md) for the full audit and threat model.

---

## Hardware Targets

### Local Inference (Ollama / llama-server)

| Device | RAM | Status |
|--------|-----|--------|
| Galaxy Fold 7 (Snapdragon 8 Elite) | 12GB | Primary development/test device |
| Galaxy S25 Ultra | 12GB | Should work (same chipset class) |
| Chromebooks (ARM/x86) | 8GB+ | Tested ([guide](docs/DEBIAN_CHROMEOS_SETUP.md)) |
| Any Linux device | 8GB+ | Should work |
| Raspberry Pi 5 | 8GB | Works (slower load times) |
| NVIDIA Jetson Nano | 4GB | Works with cloud providers or remote backend |
| WSL2 (Windows) | 8GB+ | Should work |

> **Minimum for local models:** 8GB RAM, 5GB free storage. **Recommended:** 12GB RAM, Snapdragon 8 Gen 2+ or equivalent.

### Cloud Provider Mode — iPhones, Old Hardware, and the Rest of Us

This is where it gets interesting.

George doesn't require a local model. The cloud provider harness (`/provider use google`) routes every LLM call through a cloud API, bypassing Ollama and llama-server entirely. The local machine only needs to run bash, curl, jq, git, and sqlite3. That's it. No GPU. No model downloads. No 8GB RAM floor.

This means George runs on hardware that has no business running an AI agent:

| Device | How | Video |
|--------|-----|-------|
| **iPhone 7+** (2016, 3GB RAM) | iSH (Alpine Linux) + Google AI free tier | [Watch it run](https://www.youtube.com/watch?v=2MF-2ln6WEk) |
| **Any iPhone** (iOS 14+) | iSH + cloud provider | [Setup guide](docs/IOS_MACOS_SETUP.md) |
| **NVIDIA Jetson Nano** (~2015, 4GB) | Cloud provider or remote Ollama on LAN | — |
| **Raspberry Pi 3/4** (1-4GB) | Cloud provider | — |
| **Any device with bash + curl** | Cloud provider | — |

We got George running on a **10-year-old iPhone 7+** — a phone most people have in a drawer. A phone with 3GB of RAM that can't run a 1B parameter model locally. But it *can* run bash. It *can* run curl. And through the provider harness, it can talk to `gemma-3-27b-it` on Google's free tier, Llama 3.3 70B on Groq's free tier, or any of the other 10 supported providers.

The provider harness also supports **remote backends on your local network**. If you have a desktop, a NAS, or even another phone running Ollama or llama-server, you can point George at it:

```bash
export OLLAMA_URL="http://192.168.1.100:11434"   # Ollama on your desktop
export LLAMA_CPP_URL="http://192.168.1.100:8080"  # llama-server on your desktop
```

Now your iPhone, your Jetson Nano, your 10-year-old laptop — any device on your WiFi — is running a full AI agent with inference handled by your beefiest machine. Zero cloud. Zero cost. Zero API keys.

#### Why This Matters

Every kid who has a hand-me-down iPhone can download iSH, clone this repo, set up a free Google AI API key, and have their own AI agent. Not a chatbot — an *agent* that writes code, manages git repos, searches the web, builds projects, and extends itself with new commands.

Anybody who doesn't have direct access to high-power compute — students, hobbyists, people in countries where cloud AI subscriptions cost a week's wages — can use the cloud provider function to access models up to `gemma-3-27b-it` on Google's free tier, indefinitely. Groq's free tier gives access to Llama 3.3 70B. Rate limiting with exponential backoff means the free tier lasts — George automatically paces API calls to stay under quotas.

The fact that we can run on 10-year-old iPhones and 10-year-old Jetson Nanos by using the provider option means the barrier to entry is a device that can run a shell and an internet connection. If you have old hardware laying around — an ancient phone, a retired laptop, a Pi collecting dust — George can put it back to work.

> **Getting started on iPhone:** See the [iOS & macOS Setup Guide](docs/IOS_MACOS_SETUP.md). Four packages, one git clone, one API key. Five minutes.

---

## Testing

43 test modules. 3,578 assertions. Zero external dependencies. All passing. Pure bash.

The test suite validates that the plumbing works — commands register and dispatch, parsers handle expected inputs, APIs form correct requests, the agent loop transitions between states correctly. What it doesn't fully validate is end-to-end task quality with a live LLM, because that's inherently nondeterministic. I'm still learning what good testing looks like for a project like this.

```bash
bash tests/run_all.sh              # Run all (compact output)
bash tests/run_all.sh -v           # Verbose — show every assertion
bash tests/run_all.sh test_llm     # Run a specific module
```

<details>
<summary><strong>View all test modules</strong></summary>

| Module | Assertions | Covers |
|--------|-----------|--------|
| `test_agent.sh` | 454 | Dual-loop agent, config, honeydew tracking, evaluators, auto-recovery |
| `test_api.sh` | 34 | REST client, API keys, JSON parsing, auth headers |
| `test_backup.sh` | 104 | Local/git backup, restore, pruning, export/import |
| `test_commands.sh` | 77 | Slash command registration, dispatch, catalog |
| `test_container.sh` | 28 | Container management, proot-distro |
| `test_download.sh` | 10 | URL download, local copy |
| `test_email.sh` | 110 | Gmail/ProtonMail/Zoho/Tuta + Guerrilla Mail |
| `test_git.sh` | 63 | Git identity, SSH keygen, remote, push guard |
| `test_gsuite.sh` | 35 | OAuth2 device flow, Gmail/Drive/Docs API |
| `test_init.sh` | 38 | Project scaffolding, 7 project types |
| `test_journal.sh` | 35 | Temporal memory, decay tiers |
| `test_llm.sh` | 260 | LLM config, tokens, dual-model, scenario sampling |
| `test_lodge.sh` | 253 | Main REPL, command wiring, session lifecycle |
| `test_ls.sh` | 32 | File listing, workspace discovery |
| `test_memory.sh` | 59 | GEORGE.md sections, compaction, snapshots |
| `test_models.sh` | 134 | Model registry, 7 families, hot-swap, Modelfile generation |
| `test_pgp.sh` | 34 | PGP signing, verification, Ed25519 keys |
| `test_phone.sh` | 43 | Phone integration, Termux API |
| `test_providers.sh` | 145 | 10 cloud AI providers, dispatcher, aliases |
| `test_recall.sh` | 89 | FTS5 indexing, BM25 search, quality scoring |
| `test_sandbox.sh` | 57 | Sandbox lifecycle, build, permissions |
| `test_save.sh` | 25 | File save, directory auto-creation |
| `test_secrets.sh` | 30 | Vault encrypt/decrypt, rotate, AES-256-CBC |
| `test_security.sh` | 56 | Allowlist, signing, HMAC verification |
| `test_service.sh` | 44 | Service command, daemon management |
| `test_slash.sh` | 53 | Custom commands: create, rename, compose, export |
| `test_social.sh` | 107 | 5 platforms, Discord channels, multi-instance |
| `test_tools.sh` | 135 | Code extraction, file ops, safety checks |
| `test_transcript.sh` | 48 | Session transcript recording, rotation |
| `test_ui.sh` | 45 | Colors, print functions, markdown rendering |
| `test_validate_gpu.sh` | 45 | GPU detection, Vulkan validation |
| `test_vitals.sh` | 83 | System vitals, thresholds, auto-abort |
| `test_wallet.sh` | 51 | BTC/ADA/SOL wallets, network switching |
| `test_web.sh` | 182 | Web fetch, HTML parsing, DDG search, single-GET routing |
| `test_write.sh` | 33 | File write, code extraction |

</details>

---

## Backup & Update

```bash
lodge /backup local              # Snapshot to ~/.george/backups/
lodge /backup github             # Push to a private repo
lodge /backup restore            # Restore from most recent backup
lodge /backup export             # Portable export of .george directory
```

### Updating

```bash
bash ~/blue-lodge/update.sh          # Auto-backup → git pull → restore identity
bash ~/blue-lodge/update.sh --clean  # Fresh clone, restore identity
```

---

## Documentation

32 docs under `docs/`. Key references:

| Doc | Content |
|-----|---------|
| [PHONE_SETUP.md](docs/PHONE_SETUP.md) | Android setup — 4 installation paths |
| [DEBIAN_CHROMEOS_SETUP.md](docs/DEBIAN_CHROMEOS_SETUP.md) | Chromebook / Debian setup |
| [MODELS.md](docs/MODELS.md) | Model library — 7 families, dual-model config |
| [TUNING.md](docs/TUNING.md) | Token budgets, context tuning, sampling parameters |
| [BACKEND_VALIDATION.md](docs/BACKEND_VALIDATION.md) | LLM backend setup & validation |
| [ADRENO_GPU_SETUP.md](docs/ADRENO_GPU_SETUP.md) | Vulkan GPU acceleration |
| [SLASH_COMMANDS.md](docs/SLASH_COMMANDS.md) | Slash command architecture — 4-layer system |
| [SLASH_EXTENSIONS.md](docs/SLASH_EXTENSIONS.md) | Custom command authoring |
| [AGENT_LOOP.md](docs/AGENT_LOOP.md) | Agent dual-loop & honeydew architecture |
| [ARCHITECTURE_INDEX.md](docs/ARCHITECTURE_INDEX.md) | Complete architecture index |
| [MEMORY_AND_RECALL.md](docs/MEMORY_AND_RECALL.md) | Memory system & FTS5 recall |
| [STREAMING_PIPELINE.md](docs/STREAMING_PIPELINE.md) | LLM streaming pipeline |
| [RESPONSE_PARSING.md](docs/RESPONSE_PARSING.md) | Response parsing & tool extraction |
| [COMMAND_DISPATCH.md](docs/COMMAND_DISPATCH.md) | Command dispatch system |
| [SECURITY_AND_SECRETS.md](docs/SECURITY_AND_SECRETS.md) | Security architecture |
| [MCP.md](docs/MCP.md) | MCP client + built-in fetch server |
| [SOCIAL_BOTS.md](docs/SOCIAL_BOTS.md) | Social media bot setup — 5 platforms |
| [EMAIL_GITHUB.md](docs/EMAIL_GITHUB.md) | Email provider setup |
| [CRYPTO_WALLETS.md](docs/CRYPTO_WALLETS.md) | Wallet setup — BTC/ADA/SOL |
| [GEORGE_REFERENCE.md](docs/GEORGE_REFERENCE.md) | Complete capability reference |
| [MORAL_SENTIMENTS.md](docs/MORAL_SENTIMENTS.md) | George's ethical framework |

### Examples

| Example | What It Builds |
|---------|---------------|
| [url-shortener.md](docs/examples/url-shortener.md) | Python URL shortener API (stdlib only) |
| [rust-task-manager.md](docs/examples/rust-task-manager.md) | CLI task manager with clap |
| [personal-assistant.md](docs/examples/personal-assistant.md) | Using George as a phone assistant |

---

## Uninstall

```bash
bash ~/blue-lodge/uninstall.sh
```

---

## Contributing

This is a one-person experiment that I'm sharing because the pattern is interesting and someone else might find it useful — or might see ways to make it better. If any of this catches your eye, I'd genuinely appreciate:

- **Bug reports** — I'm sure there are things I've missed
- **Architecture feedback** — I think in process flows and control loops, not software patterns. If you see a better way to structure something, I want to hear it.
- **Testing advice** — I have 3,578 assertions but I'm still figuring out what valuable testing looks like for this kind of project
- **Just playing with it** — Honest feedback about what works and what doesn't is the most useful thing

## License

MIT
