# Phone Setup Guide — From Android to Blue Lodge

This guide walks you through setting up Blue Lodge on an Android phone (Galaxy Fold, Galaxy S-series, or similar high-end device with 8GB+ RAM). The stack is:

**F-Droid → Termux → Ubuntu (via Andronix/proot-distro) → Ollama → Blue Lodge**

---

## Prerequisites

- Android phone with **8GB+ RAM** (12GB recommended)
- **Snapdragon 8 Gen 2** or newer (for reasonable LLM inference speed)
- ~8GB free storage (for Ubuntu + Ollama + model)
- A keyboard is highly recommended (Bluetooth or Samsung DeX)

## Step 1: Install F-Droid

The Play Store version of Termux is **outdated and broken**. You need the F-Droid version.

1. Open your phone's browser and go to: **https://f-droid.org**
2. Tap **"Download F-Droid"** and install the APK
3. You may need to enable **"Install from unknown sources"** in Settings → Apps → Special access
4. Open F-Droid and let it update its repository index (takes 1-2 minutes)

> **Why F-Droid?** Google removed Termux's ability to update on the Play Store due to policy changes around executing downloaded code. The F-Droid version is maintained by the Termux developers and is the only version that works correctly.

## Step 2: Install Termux from F-Droid

1. Open F-Droid
2. Search for **"Termux"**
3. Install **Termux** (by Fredrik Fornwall)
4. Also install **Termux:API** — this enables phone integration (clipboard, notifications, battery, etc.)

After installing, open Termux and run:

```bash
# Update packages
pkg update && pkg upgrade -y

# Install essential tools
pkg install -y git curl jq proot-distro
```

## Step 3: Install Ubuntu via proot-distro

Termux includes `proot-distro`, which lets you run full Linux distributions without root access.

```bash
# Install Ubuntu
proot-distro install ubuntu

# Log into Ubuntu
proot-distro login ubuntu
```

You're now running Ubuntu inside Termux. Your home directory is isolated.

### Make it easy to launch

Back in **Termux** (exit Ubuntu first with `exit`), create an alias:

```bash
echo 'alias ubuntu="proot-distro login ubuntu"' >> ~/.bashrc
source ~/.bashrc
```

Now you can type `ubuntu` to drop into your Ubuntu environment.

### Alternative: Andronix

If you prefer a GUI or a more guided setup, **Andronix** (available on the Play Store) provides one-tap installation of Ubuntu and other distros on Termux. It uses the same proot technology under the hood.

1. Install Andronix from the Play Store
2. Select **Ubuntu** → **CLI Only** (no desktop needed)
3. Copy the generated command and paste it into Termux
4. Follow the prompts

Both methods give you a working Ubuntu environment. The `proot-distro` method is lighter.

## Step 4: Set Up Ubuntu Environment

Inside Ubuntu (`proot-distro login ubuntu`):

```bash
# Update
apt update && apt upgrade -y

# Install dependencies
apt install -y curl git jq build-essential

# Install uv (fast Python package manager — optional, for Python projects)
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.bashrc
```

## Step 5: Install Ollama

Ollama provides local LLM inference. Install it inside your Ubuntu environment:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Start the Ollama server:

```bash
ollama serve &
```

Verify it's running:

```bash
curl -s http://127.0.0.1:11434/api/tags | jq .
```

### Auto-start Ollama

Add to your `~/.bashrc` inside Ubuntu:

```bash
# Start Ollama if not running
if ! curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
    ollama serve > /tmp/ollama.log 2>&1 &
    sleep 2
fi
```

## Step 6: Install Blue Lodge

```bash
# Clone
git clone https://github.com/YOUR_USERNAME/blue-lodge.git ~/blue-lodge

# Install (creates model, sets up aliases)
bash ~/blue-lodge/install.sh

# Reload shell
source ~/.bashrc
```

The installer will:
- Check dependencies (curl, jq, git)
- Verify Ollama is running
- Download the Qwen3-4B model (~3GB, one-time)
- Create the `blue-lodge` Ollama model
- Set up shell aliases

## Step 7: First Run

```bash
lodge
```

You should see the Blue Lodge header and a prompt. Try:

```
/status          # Check everything is connected
/help            # See all commands
What is a linked list?   # Quick question
```

## Recommended Termux Configuration

### Keep Termux alive in background

Android aggressively kills background apps. To prevent Termux from being killed:

1. **Acquire wake lock**: In Termux, run `termux-wake-lock`
2. **Battery optimization**: Go to Settings → Apps → Termux → Battery → Unrestricted
3. **Lock in recents**: In the recent apps view, tap the Termux icon and select "Lock"

### Termux:API setup

For phone integration features (`/phone` commands):

```bash
# In Termux (not Ubuntu)
pkg install termux-api
```

Then grant permissions when prompted (notifications, clipboard, etc.).

> **Note:** Termux:API commands (`termux-notification`, `termux-clipboard-set`, etc.) must be run from Termux itself, not from inside the proot Ubuntu environment. Blue Lodge detects availability automatically.

### Keyboard shortcuts (Samsung DeX / Bluetooth keyboard)

| Shortcut | Action |
|----------|--------|
| `Ctrl+C` | Cancel current operation (gracefully unloads model) |
| `Ctrl+D` | Exit Lodge |
| `Tab` | Bash completion (files, directories) |
| `Up/Down` | Command history |

## Storage Layout

After setup, your storage looks like:

```
~/
├── blue-lodge/           # Blue Lodge installation (~1MB)
│   ├── lodge             # Main script
│   ├── journal.md        # Agent's living memory
│   └── ...
├── .lodge-sandboxes/     # Project sandboxes (varies)
│   ├── my_app/
│   └── scraper/
└── .ollama/              # Ollama models (~3-4GB)
    └── models/
```

## Memory Management Tips

On a 12GB device, RAM is precious:

| Component | RAM Usage |
|-----------|-----------|
| Android OS | ~4GB |
| Termux + Ubuntu | ~200MB |
| Ollama (idle) | ~50MB |
| Ollama (model loaded) | ~3-4GB |
| **Available for builds** | **~4-6GB** |

Blue Lodge automatically:
- Unloads the model after each task completes
- Unloads on Ctrl+C cancellation
- Unloads on session exit
- Uses `keep_alive: 5m` so the model auto-unloads after 5 minutes of inactivity

You can tune `LLM_KEEP_ALIVE` in your `.bashrc`:

```bash
export LLM_KEEP_ALIVE="2m"   # Unload after 2 minutes (aggressive)
export LLM_KEEP_ALIVE="30m"  # Keep loaded for 30 minutes (if you have RAM)
export LLM_KEEP_ALIVE="0"    # Unload immediately after each request
```

## Troubleshooting

### "Ollama not found" after entering Ubuntu

Ollama needs to be installed **inside** the proot Ubuntu environment, not in Termux directly.

### Model is very slow

- Check you're using a quantized model (Q5_K_M or Q4_K_M)
- Close other apps to free RAM
- Try a smaller model: edit `Modelfile` to use a 1.5B model

### "Process killed" during model loading

Android killed Termux due to memory pressure. Solutions:
- Close background apps
- Use `termux-wake-lock`
- Disable battery optimization for Termux
- Try a smaller quantization (Q4_K_M instead of Q5_K_M)

### Termux closes when phone screen turns off

Run `termux-wake-lock` before starting Lodge, or add it to your `.bashrc`.

### Can't access Termux:API from Ubuntu

Termux:API commands don't work inside proot. Blue Lodge's phone features (`/phone battery`, etc.) require running Lodge from Termux directly, or setting up a wrapper script.

---

## Quick Reference: Daily Workflow

```bash
# Open Termux
# Enter Ubuntu
ubuntu

# Start working
cd ~/my-project
lodge

# Or one-shot
lodge "add input validation to the signup form"

# When done, Ctrl+C or /quit
# Model automatically unloads, freeing ~4GB RAM
```
