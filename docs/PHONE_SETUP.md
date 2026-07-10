# Phone Setup Guide — From Android to Blue Lodge

Four installation paths depending on your needs and Termux source.

> **Important:** Phone integration (`/phone` commands — SMS, GPS, battery, clipboard) **only works in native Termux**, not inside proot. If you need both full Linux tools and phone features, use **Option B+ (Hybrid)**.

| | A: Termux-Native (F-Droid) | B: proot Ubuntu | B+: Hybrid | C: Play Store Termux |
|---|---|---|---|---|
| **Termux source** | F-Droid | F-Droid | F-Droid | Google Play Store |
| **Complexity** | Simple — 4 steps | More steps | Most steps | Simple — 4 steps |
| **Phone integration** | Full (`/phone`, SMS, GPS) | **None** (proot blocks API) | Exit proot for `/phone` | Full (`/phone`, SMS, GPS) |
| **Linux tools** | Termux `pkg` packages | Full `apt` ecosystem | Both (switch contexts) | Termux `pkg` packages |
| **proot containers** | Not used | Required | Required | Not available |
| **Performance** | Native | ~5-10% proot overhead | Mixed | Native |
| **Storage** | ~5GB | ~6-8GB | ~6-8GB | ~5GB |
| **Recommended for** | **Most users** | Heavy Linux needs | Power users | Fallback / F-Droid unavailable |

> **Which should I pick?**
> - **Option A** if you just want George working with full phone features.
> - **Option B** if you need `apt`, `build-essential`, GCC, Python headers, etc.
> - **Option B+** if you want both — Ollama + llama-server in native Termux, George in proot Ubuntu.
> - **Option C** if F-Droid is unavailable and you can only get Termux from the Play Store.

---

## Prerequisites (both paths)

- Android phone with **8GB+ RAM** (12GB recommended)
- **Snapdragon 8 Gen 2** or newer (for reasonable LLM inference speed)
- ~5-8GB free storage (Ollama + model + optional Ubuntu)
- A keyboard is recommended (Bluetooth or Samsung DeX)

## Maintenance Refresh (Returning After A Gap)

If your setup is a few months old and model loads start failing, run this in
native Termux before deeper debugging:

```bash
pkg update && pkg upgrade -y
pkg reinstall -y ollama
pkg install -y spirv-headers

cd ~/llama.cpp
git pull --ff-only
rm -rf build
cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -G Ninja
cmake --build build --config Release -j4
```

## Step 1: Install Termux (Options A, B, B+)

The **F-Droid** version of Termux is actively maintained and supports
`proot-distro` for Linux containers. If you need proot (Options B/B+),
you must use F-Droid. If F-Droid is unavailable, see [Option C](#option-c-play-store-termux-fallback) below.

1. Open browser → **https://f-droid.org** → Download F-Droid
2. Enable "Install from unknown sources" if prompted
3. Open F-Droid → Search **"Termux"** → Install
4. Also install **Termux:API** (for phone integration — SMS, GPS, battery, etc.)

Open Termux and update:

```bash
pkg update && pkg upgrade -y
```

---

## Option A: Termux-Native Install (Recommended)

This is the simplest path. Blue Lodge runs directly in Termux with
zero overhead and full phone integration.

### A1. Install dependencies

```bash
pkg install -y git curl jq sqlite gawk procps bc termux-api
```

> `gawk` replaces mawk (which has compatibility issues). `procps`
> provides `free` for system vitals. `termux-api` enables `/phone` commands.

### A2. Install Or Refresh Ollama

```bash
# Preferred on current Termux builds
pkg install -y ollama

# If upgrades leave runner path issues (e.g. ollama.dpkg-tmp)
pkg reinstall -y ollama

# Start Ollama
ollama serve &
sleep 3

# Verify
curl -s http://127.0.0.1:11434/api/tags | jq .
```

> If your Termux mirror does not provide a working `ollama` package yet,
> use the direct ARM64 binary fallback from release assets.

### A3. Auto-start Ollama

Add to your `~/.bashrc`:

```bash
# Start Ollama if not running
if ! curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
    ollama serve > $TMPDIR/ollama.log 2>&1 &
    sleep 2
fi
```

### A4. Install Blue Lodge

```bash
git clone https://github.com/<your-fork>/blue-lodge.git ~/blue-lodge
bash ~/blue-lodge/install.sh
source ~/.bashrc
```

### A5. Enable phone integration

Termux-API features are **disabled by default** (they hang inside proot).
Since Option A runs in native Termux, enable them:

```bash
echo 'export LODGE_TERMUX_API=1' >> ~/.bashrc
source ~/.bashrc
```

Then grant Android permissions — Android 12+ usually does **NOT** auto-prompt:

1. **Settings → Apps → Termux:API → Permissions** — enable Location, Phone, SMS, Call logs, Notifications
2. **Settings → Apps → Termux → Permissions** — enable the same

Then verify inside Lodge:

```
lodge
/phone permissions    # Guided setup + live test
```

### A6. First Run

```bash
lodge
/status              # Check everything is connected
/phone               # Full phone dashboard
/help                # All commands
```

---

## Option B: proot Ubuntu Install

Use this if you need a full Linux environment with `apt`, `build-essential`,
GCC, Python dev headers, etc. Note: `/phone` commands will NOT work inside
proot — exit to native Termux for phone features.

### B1. Install proot-distro

```bash
pkg install -y git curl jq proot-distro
```

### B2. Set up Ubuntu

```bash
proot-distro install ubuntu
proot-distro login ubuntu
```

You're now in Ubuntu. Set up the environment:

```bash
apt update && apt upgrade -y
apt install -y curl git jq sqlite3 gawk bc build-essential

# Optional: Python tooling
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.bashrc
```

### B3. Install Ollama (inside Ubuntu)

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama serve &
sleep 3
curl -s http://127.0.0.1:11434/api/tags | jq .
```

Add to `~/.bashrc` inside Ubuntu:

```bash
if ! curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
    ollama serve > /tmp/ollama.log 2>&1 &
    sleep 2
fi
```

### B4. Install Blue Lodge (inside Ubuntu)

```bash
git clone https://github.com/<your-fork>/blue-lodge.git ~/blue-lodge
bash ~/blue-lodge/install.sh
source ~/.bashrc
```

### B5. Easy launch alias

Back in **Termux** (exit Ubuntu with `exit`):

```bash
echo 'alias ubuntu="proot-distro login ubuntu"' >> ~/.bashrc
source ~/.bashrc
```

### B6. Phone integration with proot

Phone commands don't work inside proot (Termux-API commands hang
indefinitely because the companion app can't cross the proot boundary).
`LODGE_TERMUX_API` defaults to `0` (disabled), so this is safe — George
won't attempt any Termux-API calls and won't hang.

For phone features, either:

- **Exit proot** and run `lodge` from native Termux (with `LODGE_TERMUX_API=1`)
- **Use Option A** entirely (recommended)
- **Use Option B+** for a hybrid approach (see below)

---

## Option B+: Hybrid (Ollama in Termux, George in proot)

This is the power-user setup. Ollama (and optionally llama-server) runs
in **native Termux** where it has direct hardware access, while George
runs in **proot Ubuntu** where you have the full Linux toolchain. Both
share `127.0.0.1` so the LLM API calls cross the boundary seamlessly.

### Why B+ instead of plain B?

- Ollama in native Termux may get **GPU access** that proot can't provide
- llama-server with Vulkan runs best from native Termux (direct driver access)
- You keep the full `apt` ecosystem for development inside proot
- George auto-resolves Termux paths from inside proot (`_lodge_termux_home()`)

### B+1. Set up native Termux (Ollama + optional llama-server)

From **Termux native** (not inside proot):

```bash
# Install or refresh Ollama package
pkg install -y ollama
pkg reinstall -y ollama

# Start Ollama and auto-start on new sessions
ollama serve &
sleep 3
cat >> ~/.bashrc <<BASHRC
if ! curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
    ollama serve > $TMPDIR/ollama.log 2>&1 &
    sleep 2
fi
BASHRC
```

Optional: refresh llama.cpp toolchain before rebuilding
```bash
pkg install -y cmake ninja clang vulkan-headers spirv-headers vulkan-loader-android vulkan-tools
cd ~/llama.cpp && git pull --ff-only
```

For full Vulkan build steps, see [ADRENO_GPU_SETUP.md](ADRENO_GPU_SETUP.md).

### B+2. Set up proot Ubuntu (George)

Follow Option B steps B1–B4, **but skip B3** (don't install Ollama inside
proot — it's already running in native Termux and accessible at
`127.0.0.1:11434`).

```bash
# From Termux native:
pkg install -y proot-distro
proot-distro install ubuntu
proot-distro login ubuntu

# Inside Ubuntu:
apt update && apt upgrade -y
apt install -y curl git jq sqlite3 gawk bc build-essential
git clone https://github.com/<your-fork>/blue-lodge.git ~/blue-lodge
bash ~/blue-lodge/install.sh
source ~/.bashrc
```

### B+3. Verify cross-boundary connectivity

The key insight: Ollama runs in native Termux, George calls it from proot,
both share 127.0.0.1:

```bash
# Inside proot Ubuntu:
curl -s http://127.0.0.1:11434/api/tags | jq .models[].name
# Should list your models — if so, the bridge works

lodge
/backend status    # Should show Ollama: running
```

### B+4. Phone features

Same as B6 — `/phone` doesn't work inside proot. Exit to native Termux
for phone features. You could install a second copy of Blue Lodge in
native Termux with `LODGE_TERMUX_API=1` for phone-only tasks.

### B+5. llama-server from proot

If you built llama-server in native Termux, George can start/manage it
from inside proot because `_lodge_termux_home()` auto-resolves the binary
path to `/data/data/com.termux/files/home/llama.cpp/build/bin/llama-server`:

```bash
# Inside proot Ubuntu:
lodge
/backend start blue-lodge-gemma4-inst:4b  # Starts llama-server using Termux's binary + Ollama's GGUF
```

See [BACKEND_VALIDATION.md](BACKEND_VALIDATION.md) for validation and
[ADRENO_GPU_SETUP.md](ADRENO_GPU_SETUP.md) for building with Vulkan GPU.

---

## Option C: Play Store Termux (Fallback)

If F-Droid is unavailable (shutdown, blocked, corporate policy), George
still works in the **Play Store version of Termux** with some limitations.

### What works

- George core: all slash commands, agent loop, memory, journal, recall
- Ollama: local LLM inference (CPU-only)
- Phone integration: `/phone`, SMS, GPS, clipboard (with Termux:API from Play Store)
- Git, SSH, all standard development commands
- Everything Option A provides

### What doesn't work

- **`proot-distro`** — not available in Play Store Termux (no proot containers)
- **`/container`** — depends on proot-distro
- **`/sandbox proot`** — proot-based sandboxes unavailable (directory sandboxes still work)
- **Package updates** — Play Store Termux may be behind on `pkg` repository versions
- **llama-server with Vulkan** — may have issues with older `vulkan-*` packages;
  build from source if needed (`cmake`, `ninja`, `clang` should still work)

### C1. Install Termux from Play Store

1. Google Play Store → Search **"Termux"** → Install
2. Also install **Termux:API** from Play Store
3. Open Termux:

```bash
pkg update && pkg upgrade -y
```

> **Note:** If `pkg update` fails with repository errors, the Play Store
> version may be too old. Try switching sources:
> ```bash
> termux-change-repo
> ```
> Then pick a mirror and retry `pkg update`.

### C2. Install dependencies

```bash
pkg install -y git curl jq sqlite gawk procps bc termux-api
```

### C3. Install Or Refresh Ollama

Use the same package flow as Option A:

```bash
pkg install -y ollama
pkg reinstall -y ollama

ollama serve &
sleep 3
curl -s http://127.0.0.1:11434/api/tags | jq .
```

### C4. Install Blue Lodge

```bash
git clone https://github.com/<your-fork>/blue-lodge.git ~/blue-lodge
bash ~/blue-lodge/install.sh
source ~/.bashrc
```

`install.sh` detects native Termux and auto-enables `LODGE_TERMUX_API=1`.

### C5. Grant permissions and verify

Same as Option A steps A5–A6:

1. **Settings → Apps → Termux:API → Permissions** — enable Location, Phone, SMS, etc.
2. **Settings → Apps → Termux → Permissions** — enable the same

```bash
lodge
/status              # Check health
/phone permissions   # Guided diagnostic
/help                # All commands
```

### C6. Working around missing proot

Without proot-distro, the `/container` command and proot-based sandboxes
are unavailable. George handles this gracefully:

- `/sandbox new myproject` creates a **directory sandbox** (no isolation,
  but fully functional for coding tasks)
- `/container` will report that proot-distro is not available
- All other commands work identically to Option A

If you later gain access to F-Droid, you can uninstall the Play Store
Termux, install the F-Droid version, and re-clone Blue Lodge — your
Ollama models survive in `~/.ollama/` if you back them up first.

---

## Recommended Termux Configuration

### Keep Termux alive in background

Android aggressively kills background apps:

1. **Acquire wake lock**: `termux-wake-lock`
2. **Battery optimization**: Settings → Apps → Termux → Battery → Unrestricted
3. **Lock in recents**: In recent apps view, tap Termux icon → "Lock"

### Keyboard shortcuts (Samsung DeX / Bluetooth keyboard)

| Shortcut | Action |
|----------|--------|
| `Ctrl+C` | Cancel current operation (gracefully unloads model) |
| `Ctrl+D` | Exit Lodge |
| `Tab` | Bash completion (files, directories) |
| `Up/Down` | Command history |

## Storage Layout

```
~/
├── blue-lodge/           # Blue Lodge installation (~1MB)
│   ├── lodge             # Main script
│   ├── journal.md        # Agent's living memory
│   └── ...
├── .george/              # George's config + recall DB
├── .lodge-sandboxes/     # Project sandboxes (varies)
└── .ollama/              # Ollama models (~3-4GB)
    └── models/
```

## Memory Management

On a 12GB device, RAM is precious:

| Component | RAM Usage |
|-----------|-----------|
| Android OS | ~4GB |
| Termux (native) | ~50MB |
| Termux + Ubuntu (proot) | ~200MB |
| Ollama (idle) | ~50MB |
| Ollama (model loaded) | ~3-4GB |
| **Available for builds** | **~4-6GB** |

Blue Lodge automatically manages model memory:
- Unloads model on task completion, Ctrl+C, and session exit
- Uses `keep_alive: 5m` (auto-unload after 5 min idle)

Tune in `.bashrc`:

```bash
export LLM_KEEP_ALIVE="2m"   # Aggressive (saves RAM faster)
export LLM_KEEP_ALIVE="30m"  # Relaxed (faster subsequent responses)
export LLM_KEEP_ALIVE="0"    # Unload immediately after each request
```

## Troubleshooting

### "Ollama not found"

- **Option A (Termux):** Download the binary directly — see step A2
- **Option B (proot):** Install Ollama inside the Ubuntu environment, not in native Termux

### Model is very slow

- Check you're using a quantized model (Q5_K_M or Q4_K_M)
- Close other apps to free RAM
- Try a smaller model: edit `Modelfile` to use a 1.5B model

### "Process killed" during model loading

Android killed Termux due to memory pressure:
- Close background apps
- Use `termux-wake-lock`
- Disable battery optimization for Termux
- Try a smaller quantization (Q4_K_M instead of Q5_K_M)

### Termux closes when phone screen turns off

Run `termux-wake-lock` before starting Lodge, or add it to `.bashrc`.

### /phone commands hang or return no data

1. **LODGE_TERMUX_API not set?** Run `export LODGE_TERMUX_API=1` (native Termux only)
2. **Inside proot?** Exit proot (`exit`) and run Lodge from native Termux
3. **Permissions missing?** Grant manually: Settings → Apps → Termux:API → Permissions
4. Run `/phone permissions` in Lodge for a guided diagnostic

---

## Next Steps

Once George is running:

- **GPU acceleration:** Build llama-server with Vulkan for 2-4x faster
  inference on Adreno GPUs → [ADRENO_GPU_SETUP.md](ADRENO_GPU_SETUP.md)
- **Validate your backend:** Confirm GPU offloading and compare Ollama
  vs llama-server performance → [BACKEND_VALIDATION.md](BACKEND_VALIDATION.md)
- **Model library:** Switch between models, adjust sampling parameters
  → [MODELS.md](MODELS.md)
- **Knowledge base:** Ingest your own docs for George to reference
  → [RECALL.md](RECALL.md)
- **Phone features:** SMS, calls, clipboard, GPS, battery, notifications
  → [PHONE_INTEGRATION.md](PHONE_INTEGRATION.md)
- **Social bots:** Discord, Telegram, X, Mastodon, Bluesky
  → [SOCIAL_BOTS.md](SOCIAL_BOTS.md)

---

## Quick Reference

```bash
# Option A / C: Just open Termux and go
lodge

# Option B: Enter Ubuntu first
ubuntu
lodge

# Option B+: Start Ollama in Termux, then enter Ubuntu
# (Ollama auto-starts if you set up .bashrc per B+1)
ubuntu
lodge
/backend status    # Verify Ollama reachable from proot

# One-shot task
lodge "add input validation to the signup form"

# When done, Ctrl+C or /quit
# Model auto-unloads, freeing ~4GB RAM
```
