# Phone Setup Guide — From Android to Blue Lodge

Two installation paths. **Option A (Termux-native)** is simpler, faster,
and gives you full phone integration. **Option B (proot Ubuntu)** gives
you a full Linux userland if you need `apt`, `build-essential`, etc.

| | Option A: Termux-Native | Option B: proot Ubuntu |
|---|---|---|
| **Complexity** | Simple — 4 steps | More steps — proot layer |
| **Phone integration** | Works natively (`/phone`, SMS, GPS) | Does NOT work (API can't cross proot) |
| **Linux tools** | Termux `pkg` packages | Full `apt` ecosystem |
| **Performance** | Native (no overhead) | ~5-10% proot overhead |
| **Storage** | ~4GB (Ollama + model) | ~5-6GB (+Ubuntu image) |
| **Recommended for** | Most users | Heavy Linux/build-essential needs |

---

## Prerequisites (both paths)

- Android phone with **8GB+ RAM** (12GB recommended)
- **Snapdragon 8 Gen 2** or newer (for reasonable LLM inference speed)
- ~5-8GB free storage (Ollama + model + optional Ubuntu)
- A keyboard is recommended (Bluetooth or Samsung DeX)

## Step 1: Install F-Droid + Termux (both paths)

The Play Store version of Termux is **outdated and broken**. Use F-Droid.

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

### A2. Install Ollama

```bash
# Download the ARM64 binary directly
curl -fSL https://github.com/ollama/ollama/releases/latest/download/ollama-linux-arm64.tgz \
    | tar xz -C $PREFIX/bin/ 2>/dev/null \
    || {
        curl -fSL https://github.com/ollama/ollama/releases/latest/download/ollama-linux-arm64 \
            -o $PREFIX/bin/ollama
        chmod +x $PREFIX/bin/ollama
    }

# Start Ollama
ollama serve &
sleep 3

# Verify
curl -s http://127.0.0.1:11434/api/tags | jq .
```

> **Note:** The `ollama.com/install.sh` script expects systemd, which
> Termux doesn't have. Use the direct binary download above instead.

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
git clone https://github.com/dabe-19/blue-lodge.git ~/blue-lodge
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
git clone https://github.com/dabe-19/blue-lodge.git ~/blue-lodge
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

## Quick Reference

```bash
# Option A: Just open Termux and go
lodge

# Option B: Enter Ubuntu first
ubuntu
lodge

# One-shot task
lodge "add input validation to the signup form"

# When done, Ctrl+C or /quit
# Model auto-unloads, freeing ~4GB RAM
```
