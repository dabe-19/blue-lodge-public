# Architecture Index

> Master reference for the Blue Lodge technical documentation. Start here.

---

## What Is Blue Lodge?

Blue Lodge is a **bash-native LLM agent assistant** called George. It runs as a single `lodge` command that provides a REPL with 50+ slash commands, multi-backend LLM integration, an autonomous agent system, and a full memory stack — all implemented in ~20,000 lines of pure bash.

**Primary targets**: Termux on Android (ARM Snapdragon), Debian chroots on ChromeOS, and standard Linux workstations. No Python, Node, or external runtimes required.

---

## Reading Order

For new contributors, read in this order:

| # | Document | What You'll Learn |
|---|----------|-------------------|
| 1 | **[Streaming Pipeline](STREAMING_PIPELINE.md)** | How LLM responses flow from curl to screen — FIFOs, NDJSON/SSE parsing, the thinking-tag state machine, and the /dev/tty trick for concurrent spinner output |
| 2 | **[Response Parsing](RESPONSE_PARSING.md)** | Post-stream processing — spacing fixers, code block extraction, file write detection, slash command extraction, and the smart routing system |
| 3 | **[API & Providers](API_AND_PROVIDERS.md)** | HTTP layer, 10 cloud providers, SSE parsing variants per provider, metering, retry/backoff, and how to add a new provider |
| 4 | **[Agent Loop](AGENT_LOOP.md)** | The two-loop system — macro (honeydew task list) and inner (5-level failure escalation per milestone), router-specialist pipeline, dual evaluator |
| 5 | **[Command Dispatch](COMMAND_DISPATCH.md)** | Associative array registry, dispatch pipeline, auto-route detection, the REPL, and user-created slash extensions |
| 6 | **[Memory, Recall & Journal](MEMORY_AND_RECALL.md)** | GEORGE.md project memory, system prompt construction (3 modes), SQLite FTS5 recall database, journal with temporal decay |
| 7 | **[UI & Terminal Rendering](UI_AND_TERMINAL.md)** | ANSI 256-color system, spinner architecture, markdown-lite rendering, interactive prompts, transcript hooks |
| 8 | **[Security & Secrets](SECURITY_AND_SECRETS.md)** | Command allowlist, network audit mode, HMAC-SHA256 file signing, AES-256-CBC secrets vault, per-sandbox permissions |
| 9 | **[Bash Techniques Reference](BASH_TECHNIQUES.md)** | Every advanced bash pattern used in the codebase — namerefs, FIFOs, process substitution, traps, awk state machines, epoch arithmetic, and more |

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        lodge (REPL)                          │
│                    commands.sh dispatch                       │
├──────────┬──────────┬──────────┬──────────┬─────────────────┤
│ /ask     │ /agent   │ /test    │ /web     │ /save /push ... │
│ /plan    │ /vision  │ /build   │ /social  │ /fix /write ... │
├──────────┴──────────┴──────────┴──────────┴─────────────────┤
│                                                              │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │  agent.sh    │  │  llm.sh       │  │  providers.sh      │  │
│  │  Honeydew    │  │  FIFO stream  │  │  10 cloud backends │  │
│  │  2-loop      │  │  Think tags   │  │  SSE parsing       │  │
│  │  Evaluator   │  │  Sampling     │  │  Metering          │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬─────────────┘  │
│         │                 │                  │                │
│  ┌──────▼───────────────────────────────────▼──────────────┐ │
│  │                    api.sh                                │ │
│  │           HTTP core · Key storage · Rate limits          │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐             │
│  │ memory.sh   │  │ recall.sh   │  │ journal.sh  │            │
│  │ GEORGE.md   │  │ SQLite FTS5 │  │ Temporal    │            │
│  │ System      │  │ Chunk+rank  │  │ decay tiers │            │
│  │ prompts     │  │ BM25 search │  │ (3/14/90d)  │            │
│  └─────────────┘  └─────────────┘  └─────────────┘            │
│                                                              │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐             │
│  │ security.sh │  │ secrets.sh  │  │ ui.sh       │            │
│  │ HMAC sign   │  │ AES vault   │  │ ANSI 256    │            │
│  │ Allowlist   │  │ Shred/dd    │  │ Spinner     │            │
│  │ Net audit   │  │ Key rotate  │  │ Markdown    │            │
│  └─────────────┘  └─────────────┘  └─────────────┘            │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  sandbox.sh · git.sh · backup.sh · email.sh · social.sh │ │
│  │  phone.sh · vitals.sh · wallet.sh · gsuite.sh · pgp.sh  │ │
│  │  container.sh · web.sh · slash.sh · transcript.sh       │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## Data Flow: User Question → Response

```
User types "/ask How do I reverse a list in Python?"
        │
        ▼
  lodge REPL (lodge)
  └─ _lodge_dispatch() → CMD_REGISTRY["ask"] → cmd_ask()
        │
        ▼
  memory.sh: memory_build_system_prompt("ask")
  └─ Loads soul.md + GEORGE.md + recall context + journal
  └─ Constructs system prompt (~2000-4000 tokens)
        │
        ▼
  llm.sh: _llm_check_backends()
  └─ Tries: 1. Ollama  2. llama-server  3. Cloud provider
        │
        ▼
  llm.sh: llm_stream_response()
  └─ mkfifo → curl (background) → while read loop
  └─ Parse NDJSON or SSE per backend
  └─ Handle <think>...</think> tags
  └─ Feed tokens to ui.sh for rendering
        │
        ▼
  tools.sh: _tools_process_response()
  └─ Fix spacing artifacts
  └─ Extract code blocks, file writes, commands
  └─ Auto-route slash commands found in response
        │
        ▼
  ui.sh: ui_render_response()
  └─ Markdown-lite rendering (headings, bullets, code)
  └─ ANSI color output
  └─ Transcript logging (ANSI-stripped)
```

---

## File-to-Subsystem Map

| File | Role | Doc |
|------|------|-----|
| `lodge` | Main entry, REPL, startup | [Command Dispatch](COMMAND_DISPATCH.md) |
| `lib/llm.sh` | Backend detection, streaming, token processing | [Streaming Pipeline](STREAMING_PIPELINE.md) |
| `lib/api.sh` | HTTP wrapper, key storage, rate limiting | [API & Providers](API_AND_PROVIDERS.md) |
| `lib/providers.sh` | Cloud AI providers, SSE parsing, metering | [API & Providers](API_AND_PROVIDERS.md) |
| `lib/models.sh` | Model registry, GGUF resolution, hot-swap | [Streaming Pipeline](STREAMING_PIPELINE.md) |
| `lib/agent.sh` | Two-loop agent, honeydew, evaluator | [Agent Loop](AGENT_LOOP.md) |
| `lib/commands.sh` | Command registration and dispatch | [Command Dispatch](COMMAND_DISPATCH.md) |
| `lib/memory.sh` | GEORGE.md, system prompts | [Memory & Recall](MEMORY_AND_RECALL.md) |
| `lib/recall.sh` | SQLite FTS5, chunking, search | [Memory & Recall](MEMORY_AND_RECALL.md) |
| `lib/journal.sh` | Temporal decay memory | [Memory & Recall](MEMORY_AND_RECALL.md) |
| `lib/tools.sh` | Response parsing, code extraction | [Response Parsing](RESPONSE_PARSING.md) |
| `lib/ui.sh` | Terminal rendering, spinner, prompts | [UI & Terminal](UI_AND_TERMINAL.md) |
| `lib/security.sh` | HMAC signing, allowlist, network audit | [Security & Secrets](SECURITY_AND_SECRETS.md) |
| `lib/secrets.sh` | AES-256-CBC vault | [Security & Secrets](SECURITY_AND_SECRETS.md) |
| `lib/transcript.sh` | Session recording | [UI & Terminal](UI_AND_TERMINAL.md) |
| `lib/sandbox.sh` | Project isolation | [Command Dispatch](COMMAND_DISPATCH.md) |
| `lib/slash.sh` | User-created commands | [Command Dispatch](COMMAND_DISPATCH.md) |
| `lib/web.sh` | Content fetching, search | — |
| `lib/git.sh` | Git operations | — |
| `lib/backup.sh` | Multi-project backups | — |
| `lib/email.sh` | IMAP/SMTP integration | — |
| `lib/social.sh` | Social media posting | — |
| `lib/phone.sh` | SMS/call via Termux API | — |
| `lib/vitals.sh` | System monitoring | — |
| `lib/wallet.sh` | Crypto wallet lookups | — |
| `lib/gsuite.sh` | Google OAuth2 integration | — |
| `lib/pgp.sh` | PGP key management | — |
| `lib/container.sh` | proot-distro wrapper | — |

---

## Design Principles

1. **Offline-first** — Everything works without network. Cloud is a fallback, not a requirement.
2. **Mobile-first** — Designed for Termux on phones. Low memory, ARM CPU, small screen.
3. **Zero dependencies beyond POSIX+** — Only `bash`, `curl`, `jq`, `sqlite3`, `awk`, `sed`, `openssl`.
4. **Fail gracefully** — Every external tool has a fallback or degraded mode.
5. **Allowlist security** — Safe commands are enumerated; everything else needs permission.
6. **LLM autonomy** — George "owns" his memory files and can verify their integrity.

---

## Quick Commands for Contributors

```bash
# Run all tests
./tests/run_all.sh

# Run a specific test file
bash tests/test_llm.sh

# Start the REPL
./lodge

# Check system health
./lodge vitals

# List all slash commands
./lodge ls
```

---

## Cross-References

These existing docs cover additional topics:

| Document | Topic |
|----------|-------|
| [LLM_CALL_MAPS.md](LLM_CALL_MAPS.md) | Which LLM calls happen where |
| [RECALL.md](RECALL.md) | Recall system user guide |
| [MODELS.md](MODELS.md) | Supported model catalog |
| [PROVIDERS.md](PROVIDERS.md) | Cloud provider setup guide |
| [SLASH_COMMANDS.md](SLASH_COMMANDS.md) | Slash command user reference |
| [SLASH_EXTENSIONS.md](SLASH_EXTENSIONS.md) | Creating custom slash commands |
| [SANDBOXES.md](SANDBOXES.md) | Sandbox system user guide |
| [SECRETS_VAULT.md](SECRETS_VAULT.md) | Vault usage guide |
| [PGP_SIGNING.md](PGP_SIGNING.md) | PGP setup and signing |
| [VITALS.md](VITALS.md) | System monitoring reference |
| [TUNING.md](TUNING.md) | Performance tuning guide |

---

*This is the entry point to the Blue Lodge technical documentation. Start with [Streaming Pipeline](STREAMING_PIPELINE.md) and work through the reading order above.*
