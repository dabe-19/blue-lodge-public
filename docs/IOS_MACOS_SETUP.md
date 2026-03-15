# iOS & macOS Setup Guide

Run George on Apple devices using cloud providers or remote GPU inference. This covers iSH (Alpine Linux on iOS/iPadOS) and macOS via Homebrew Bash.

> **Key constraint:** iSH cannot run Ollama or llama-server locally (i686 emulation). macOS *can* run Ollama natively. On both platforms, George supports two inference paths:
>
> 1. **Cloud providers** — route all LLM calls through a cloud API (Google, Groq, OpenAI, etc.)
> 2. **Remote GPU inference** — SSH tunnel to your own GPU server via `/remote connect` (see [Inference Fabric](INFERENCE_FABRIC.md))

---

## Platform Comparison

| | iSH (iOS/iPadOS) | macOS (Homebrew) |
|---|---|---|
| **Device** | iPhone, iPad | MacBook, iMac, Mac Mini |
| **Shell** | Bash via `apk add bash` | Bash 5+ via `brew install bash` |
| **Local LLM** | No (i686 QEMU, too slow) | No¹ |
| **Cloud providers** | All supported | All supported |
| **Remote GPU inference** | Via SSH tunnel (`/remote connect`) | Via SSH tunnel (`/remote connect`) |
| **Performance bottleneck** | API latency (~1-3s), not local parsing | API latency |
| **Storage** | ~200MB (George + deps) | ~200MB (George + deps) |
| **Recommended provider** | Google (free tier) or Groq (free, fast) | Any |

¹ macOS *can* run Ollama natively, but this guide covers the cloud and remote-GPU paths. If you have Ollama on macOS, George will auto-detect it and you can skip the provider setup.

---

## What Is Cloud-Only Mode?

When `GEORGE_PROVIDER` is set, George routes every LLM call through that provider's API instead of a local model. The entire local inference stack (Ollama, llama-server, model downloads) is bypassed. Everything else — slash commands, memory, recall, git, file writing, sandbox — works identically.

Built-in rate limiting (`PROVIDER_CALL_DELAY=7s` default) with exponential backoff prevents hitting free-tier quotas. Google AI and Groq both offer generous free tiers that work well for interactive use.

## Alternative: Remote GPU Inference

If you have a GPU server on your home network (or reachable via SSH), you can use George's remote inference fabric instead of — or alongside — cloud providers. This gives you local-speed inference (~60 tok/s) without API costs or rate limits.

### Quick Setup from macOS / iSH

```bash
# 1. Configure SSH access to your GPU server
/remote setup user@gpu-server.local

# 2. If connecting through a jump host / router:
/remote config REMOTE_JUMP_HOST user@jump-box.local
/remote config REMOTE_FORWARD_HOST 10.0.0.100

# 3. Connect (opens SSH tunnel)
/remote connect

# 4. Check it works
/remote status
/remote models
```

Once connected, George automatically routes inference through the tunnel.
All slash commands, the agent loop, and memory/recall work identically.

See [Inference Fabric](INFERENCE_FABRIC.md) for full documentation including
GPU server provisioning, ProxyJump topology, and performance tuning.

---

## Option A: iSH on iOS / iPadOS

### Prerequisites

- iPhone or iPad running iOS 14+
- [iSH](https://apps.apple.com/app/ish-shell/id1436902243) from the App Store (free)
- A cloud provider API key (see [Provider Setup](#provider-setup) below)

### Step 1 — Install Dependencies

Open iSH and install the required packages:

```bash
apk add bash curl jq grep sed gawk coreutils git sqlite
```

**Why these packages?**

| Package | Purpose |
|---------|---------|
| `bash` | iSH ships with ash/sh by default; George requires Bash 4+ |
| `curl` | HTTP client for API calls and web fetching |
| `jq` | JSON parsing for LLM responses and provider APIs |
| `grep` | `apk add grep` installs **GNU grep** which supports `-oE` (extended regex) |
| `sed` | Stream editor for text extraction (GNU sed via coreutils) |
| `gawk` | GNU awk — BusyBox awk has NUL byte issues |
| `coreutils` | GNU `readlink`, `mktemp`, `date`, etc. |
| `git` | Version control for `/clone`, `/commit`, `/push` |
| `sqlite` | FTS5 full-text search for the `/recall` knowledge base |

### Step 2 — Clone George

```bash
cd ~
git clone https://github.com/your-org/blue-lodge.git
cd blue-lodge
```

### Step 3 — Run the Installer

```bash
bash install.sh
```

The installer will:
1. Check and install any missing dependencies
2. Detect that Ollama cannot be installed (i686 architecture) — **this is expected**
3. Prompt you to configure a cloud provider (see below)
4. Skip local model setup (no Ollama)
5. Index the knowledge base for `/recall`
6. Write shell config to `~/.bashrc`

### Step 4 — Source Your Shell Config

```bash
source ~/.bashrc
```

### Step 5 — Launch

```bash
lodge
```

Or give it a task directly:

```bash
lodge "scaffold a REST API in Python"
```

### iSH-Specific Caveats

- **Speed:** iSH emulates x86 via QEMU user-mode. Shell operations are ~10-50x slower than native. However, the real bottleneck is API round-trip latency (1-3 seconds), not local parsing, so interactive use feels similar to other platforms.
- **No background processes:** iSH does not fully support backgrounding. If you switch away from iSH, running processes may be suspended by iOS. Keep iSH in the foreground during long tasks.
- **No Ollama/llama-server:** The i686 emulation cannot run these native binaries. Cloud providers are the only path.
- **Filesystem:** iSH mounts a virtual filesystem. Files persist across app restarts but not across app reinstalls. Back up your `~/.george` directory if you have important memory/recall data.
- **No phone integration:** `/phone` commands (SMS, GPS, clipboard) are not available — those require Termux on Android.

---

## Option B: macOS (Homebrew)

### Prerequisites

- macOS 12+ (Monterey or newer)
- [Homebrew](https://brew.sh) installed
- A cloud provider API key (or Ollama installed locally)

### Step 1 — Install Bash 5+ and Dependencies

macOS ships with Bash 3.2 (2007) which lacks features George requires (associative arrays, namerefs, `[[ =~ ]]` regex). Install a modern Bash and GNU tools:

```bash
brew install bash curl jq git sqlite coreutils grep gawk
```

**Important:** Homebrew installs GNU tools prefixed with `g` (e.g., `ggrep`, `gsed`). George uses the standard names, so the Homebrew-installed `grep` and `gawk` packages add unprefixed binaries to `/opt/homebrew/bin` which takes precedence in your PATH.

Verify:
```bash
/opt/homebrew/bin/bash --version   # Should show 5.x
grep --version                      # Should show GNU grep
```

### Step 2 — Clone George

```bash
cd ~/projects   # or wherever you prefer
git clone https://github.com/your-org/blue-lodge.git
cd blue-lodge
```

### Step 3 — Run the Installer

Use the Homebrew Bash explicitly:

```bash
/opt/homebrew/bin/bash install.sh
```

> **Why not just `bash install.sh`?** The macOS default `/bin/bash` is 3.2. The installer requires Bash 4+ features. Using the Homebrew path guarantees the correct version.

The installer will offer to configure a cloud provider or detect your existing Ollama installation.

### Step 4 — Configure Your Shell

Add to your `~/.zshrc` (default macOS shell) or `~/.bashrc`:

```bash
# Use Homebrew Bash for lodge
alias lodge='/opt/homebrew/bin/bash /path/to/blue-lodge/lodge'
```

Or if you've switched your default shell to Homebrew Bash, the installer handles this automatically.

### Step 5 — Launch

```bash
lodge
```

### macOS-Specific Caveats

- **Shell version:** Always use Homebrew Bash (`/opt/homebrew/bin/bash`), not macOS system Bash (`/bin/bash`). The system Bash is 3.2 and will fail on associative arrays, `declare -n`, `readarray`, etc.
- **GNU vs BSD tools:** macOS `sed`, `grep`, and `date` are BSD variants with different flags. Homebrew's GNU versions must be in your PATH first. Verify with `grep --version` (should say "GNU grep").
- **`readlink -f`:** macOS BSD `readlink` doesn't support `-f`. George falls back to `realpath` if available, but `brew install coreutils` ensures `greadlink` exists and the fallback works.
- **Ollama is optional:** If you have Ollama installed on macOS (`brew install ollama`), George will auto-detect it and you can use local models. Cloud providers are only required if you want to skip local inference.

---

## Provider Setup

During installation (or anytime after), configure a cloud provider:

### During Install

The installer prompts you to choose a provider and enter your API key. It writes the config to your shell RC file automatically.

### After Install

Set the environment variables manually:

```bash
export GEORGE_PROVIDER=google
export GOOGLE_AI_API_KEY="your-key-here"
```

Or use the built-in command:

```bash
lodge /provider use google
```

### Supported Providers

| Provider | Env Variable | Free Tier | Get Key |
|----------|-------------|-----------|---------|
| **Google AI** | `GOOGLE_AI_API_KEY` | Yes (generous) | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) |
| **Groq** | `GROQ_API_KEY` | Yes (fast) | [console.groq.com/keys](https://console.groq.com/keys) |
| **Mistral** | `MISTRAL_API_KEY` | Yes | [console.mistral.ai](https://console.mistral.ai) |
| **Together** | `TOGETHER_API_KEY` | Yes | [api.together.xyz](https://api.together.xyz) |
| **Cohere** | `COHERE_API_KEY` | Yes | [dashboard.cohere.com](https://dashboard.cohere.com) |
| **DeepSeek** | `DEEPSEEK_API_KEY` | Very cheap | [platform.deepseek.com](https://platform.deepseek.com) |
| **OpenAI** | `OPENAI_API_KEY` | Paid | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| **Anthropic** | `ANTHROPIC_API_KEY` | Paid | [console.anthropic.com](https://console.anthropic.com) |
| **xAI** | `XAI_API_KEY` | Paid | [console.x.ai](https://console.x.ai) |

> **Recommendation for iOS/free use:** Start with **Google AI** (Gemini). The free tier handles interactive development sessions well, and the built-in rate limiter prevents overuse.

### Rate Limiting

George automatically manages rate limits:

- **Default delay:** 7 seconds between API calls (`PROVIDER_CALL_DELAY`)
- **Exponential backoff:** On 429 (rate limit) responses, retries with increasing delays
- **Per-provider tracking:** RPM, RPD, TPM, TPD counters
- **Configurable:** `lodge /config provider_call_delay 10` to increase delay

---

## Features That Work Everywhere

These features work identically on iOS, macOS, Android, and Linux:

- All slash commands (`/init`, `/build`, `/test`, `/fix`, `/commit`, `/push`, `/write`, `/clone`, etc.)
- Agent loop (strategist → router → specialist → evaluator)
- Memory and recall (`/memory`, `/recall`)
- Git integration (`/commit`, `/push`, `/clone`)
- Web search and fetching (`/web search`, `/web fetch`)
- File operations, sandbox management
- Journal and transcript logging
- PGP signing, email, social integrations (where APIs are configured)

## Features Not Available

| Feature | Reason | Workaround |
|---------|--------|------------|
| Local LLM inference | No Ollama/llama-server on iSH (i686) | Cloud providers or `/remote connect` to a GPU server |
| `/phone` commands | Requires Termux-API on Android | Not applicable on iOS/macOS |
| GPU offloading | No GPU access in iSH | Remote GPU via SSH tunnel or cloud providers |
| Vision (local) | Requires llama-server + mmproj | Remote llama-server or cloud providers with vision support |

---

## Troubleshooting

### "No local LLM backend available on this platform (ish)"

George detected iSH and no cloud provider is configured. Set one:

```bash
export GEORGE_PROVIDER=google
export GOOGLE_AI_API_KEY="your-key"
lodge
```

### Installer says "Ollama install failed (i686 may not be supported)"

This is expected on iSH. The installer continues and prompts for a cloud provider. Ollama requires native ARM64 or x86_64 binaries which iSH's i686 QEMU emulation cannot run.

### "command not found: lodge" after install

Source your shell config:

```bash
source ~/.bashrc    # or ~/.zshrc on macOS
```

### Slow startup on iSH

First launch indexes the knowledge base (FTS5). Subsequent launches are faster. If startup exceeds 30 seconds, the FTS5 indexing may be slow on iSH — this is a one-time cost.

### Rate limit errors

Increase the delay between API calls:

```bash
lodge /config provider_call_delay 10
```

Or switch to a provider with higher limits.

---

## Technical Reference: What Changed

This section documents the code changes that enabled iOS/macOS compatibility, for contributors and anyone debugging issues.

### 1. Perl Regex Elimination (`grep -oP` → `grep -oE` / `sed`)

**Problem:** George used `grep -oP` (Perl-compatible regex) in ~55 call sites across 15 files. Perl regex is a GNU grep extension enabled by linking against libpcre. BusyBox grep (Alpine/iSH default) does not include it, and even `apk add grep` (GNU grep on Alpine) may not be built with PCRE support on all architectures.

**Solution:** Every `grep -oP` call was replaced with either `grep -oE` (POSIX Extended Regular Expressions) or `sed -n 's/.../p'` for patterns that used Perl-only features.

**Perl-only features that required conversion:**

| Perl Feature | POSIX Equivalent | Example |
|---|---|---|
| `\K` (lookbehind reset) | `sed -n 's/.*PREFIX\([^"]*\).*/\1/p'` | Extract value after `KEY="` |
| `(?:...)` (non-capturing group) | `(...)` | Group without capture |
| `\s` (whitespace) | `[[:space:]]` | Match space/tab |
| `\S` (non-whitespace) | `[^[:space:]]` | Match non-space |
| `\d` (digit) | `[0-9]` | Match digit |
| `\w` (word char) | `[a-zA-Z0-9_]` | Match word character |
| `\b` (word boundary) | `(^\|[^a-zA-Z])...($ \|[^a-zA-Z])` | Word boundary emulation |
| `(?=...)` (lookahead) | `sed` with capture group | Match without consuming |

**Files changed (and call count):**

| File | Calls Replaced | Primary Patterns |
|---|---|---|
| `lib/agent.sh` | 11 | URL extraction, embedded `/social`/`/email` detection, placeholder detection, word boundaries in evaluator |
| `lib/web.sh` | 14 | HTTP status, HTML title/tag extraction, DuckDuckGo URL parsing |
| `lib/llm.sh` | 7 | Port extraction from process args, `--ngl` layer count |
| `lib/email.sh` | 4 | JSON value extraction (`\K[^"]+` patterns) |
| `lib/pgp.sh` | 3 | Email from UID, signer name, import count |
| `lib/providers.sh` | 2 | Rate-limit "retry in Xs" hint extraction |
| `lib/social.sh` | 1 | `@mention` extraction |
| `lib/journal.sh` | 1 | Date extraction |
| `lib/tools.sh` | 1 | Dangerous command detection (security pattern) |
| `lodge` | 3 | GPU layer status, email in identity |
| `scripts/validate-gpu.sh` | 3 | GPU layer count, backend detection |
| `scripts/test-llama-server.sh` | 1 | GPU layer count |
| `tests/test_agent_context.sh` | 6 | Embedded command extraction tests |
| `tests/test_journal.sh` | 1 | ANSI escape detection |
| `tests/test_validate_gpu.sh` | 1 | Function definition matching |
| `tests/run_all.sh` | 1 | Test summary parsing |
| `tests/test_tools.sh` | 1 | Dangerous command test |

**Risk:** The `sed` replacements use greedy `.* ` matching where Perl used non-greedy. For JSON-like input with a single key-value pair per line (which all call sites produce), this is equivalent. If future input has multiple quoted values on one line, the `sed` would match the last value instead of the first. All existing call sites were audited for this.

### 2. Hardcoded `/tmp` → `${TMPDIR:-/tmp}`

**Problem:** Five locations hardcoded `/tmp/` for log files and temp files. On some systems `TMPDIR` points elsewhere, and on iSH the `/tmp` mount may have different permissions.

**Solution:** All five occurrences replaced with `"${TMPDIR:-/tmp}"` which respects the system's temp directory while falling back to `/tmp`.

**Files changed:**
- `lib/llm.sh` — Ollama log file (3 locations)
- `lib/recall.sh` — FTS5 test database, libreoffice temp output
- `lib/tools.sh` — Diff preview temp file

### 3. Platform Detection (`lodge` Entry Point)

**Problem:** George assumed a Linux environment with Ollama available. On iSH, Ollama cannot run, and the startup sequence would fail trying to start a local LLM backend.

**Solution:** Added platform detection at the top of the `lodge` entry point:

```bash
LODGE_PLATFORM="linux"    # default
LODGE_CLOUD_ONLY=0

# iSH: /proc/ish/version exists, or Alpine + i686 arch
if [ -f /proc/ish/version ] || (Alpine + i686 detected); then
    LODGE_PLATFORM="ish"
    LODGE_CLOUD_ONLY=1     # unless GEORGE_PROVIDER already set
fi
```

When `LODGE_CLOUD_ONLY=1` and no provider is configured, George exits with a clear error message telling the user to set `GEORGE_PROVIDER`.

### 4. Non-Fatal Ollama Install (`install.sh`)

**Problem:** The installer ran under `set -e` (exit on error). When `curl -fsSL https://ollama.com/install.sh | sh` failed on i686 (Ollama doesn't support that architecture), the entire installer died. Everything after — shell config, knowledge base indexing, path setup — was never completed.

**Solution:**
- Wrapped the Ollama install in `|| { warn "..." }` so `set -e` doesn't kill the script
- Added `_OLLAMA_AVAILABLE` flag (0/1) checked after the install attempt
- Steps 3 (start Ollama), 4 (create models), and 5 (verify API) are gated behind `if [ "$_OLLAMA_AVAILABLE" -eq 1 ]`
- The installer completes fully even with no Ollama, producing a working cloud-only setup

### 5. Cloud Provider Setup in Installer (`install.sh`)

**Problem:** On platforms where Ollama can't install, the user had no guidance on how to configure a cloud provider during installation.

**Solution:** Added step 2b — an interactive cloud provider setup:
- If Ollama is unavailable: presents provider menu as **required** step
- If Ollama is available: offers provider setup as **optional** (`[y/N]`)
- Lists all 9 supported providers with free-tier annotations
- Prompts for API key with dashboard URLs for major providers
- Writes `GEORGE_PROVIDER` and API key exports to shell RC file
- Cleans up old provider blocks on reinstall

### 6. Test Fixes (`tests/test_llm.sh`)

**Problem:** Two tests (`_llm_build_opts includes top_p`, `...min_p`) expected `jq` to output `1.0` and `0.0`, but `jq` versions before 1.7 output `1` and `0` for integer-valued floats.

**Solution:** Added `awk` normalization (`printf "%.1f"`) before assertion so both `jq` versions produce `1.0`/`0.0`.
