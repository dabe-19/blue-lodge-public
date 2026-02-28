# Adreno GPU Setup — llama.cpp with Vulkan on Termux

Blue Lodge supports running local LLMs via llama.cpp with Vulkan GPU
acceleration on Qualcomm Adreno GPUs. This guide covers setup on the
Samsung Galaxy Fold 7 (Snapdragon 8 Elite, Adreno 830) but applies to
any Adreno 7xx/8xx device.

## Prerequisites

- Android device with Adreno GPU (Snapdragon 8 Gen 2+ recommended)
- [Termux](https://f-droid.org/en/packages/com.termux/) installed from F-Droid
- At least 8 GB RAM (16 GB recommended for 8B+ models)
- Storage space for model files (4–10 GB per GGUF)

## Termux vs proot-distro Paths

Blue Lodge runs inside a **proot-distro Ubuntu** container, but Ollama
and llama.cpp are installed in **native Termux**. Steps 1–5 below must
be run from **Termux native** (before entering proot). The build tools,
Vulkan driver, and `$PREFIX` are all Termux-only.

| Context | `$HOME` | `$PREFIX` | llama-server path |
|---------|---------|-----------|-------------------|
| Termux native | `/data/data/com.termux/files/home` | `/data/data/com.termux/files/usr` | `~/llama.cpp/build/bin/llama-server` |
| proot Ubuntu | `/root` | *(unset)* | `/data/data/com.termux/files/home/llama.cpp/build/bin/llama-server` |

Blue Lodge auto-resolves this with `_lodge_termux_home()` — no manual
path configuration needed when using `/backend` commands.

## 1. Install Termux Dependencies

> **Run from Termux native** (not inside proot-distro Ubuntu).

```bash
pkg update && pkg upgrade -y
pkg install -y git cmake ninja clang vulkan-headers \
    vulkan-loader-android vulkan-tools jq curl
```

## 2. Copy Vulkan Driver (Required)

> **Run from Termux native.** `$PREFIX` is a Termux-only variable
> (`/data/data/com.termux/files/usr`) — it does not exist in proot.

Termux can't see the system Vulkan driver by default. Copy it:

```bash
# Find the driver (path varies by device)
ls /vendor/lib64/hw/vulkan.*.so

# Copy to Termux's library path
cp /vendor/lib64/hw/vulkan.adreno.so $PREFIX/lib/

# Verify Vulkan works (this also works from inside proot)
vulkaninfo --summary 2>/dev/null | head -20
```

If `vulkaninfo` shows your GPU (e.g., "Adreno (TM) 830"), you're good.

## 3. Clone and Build llama.cpp

> **Run from Termux native.** cmake/ninja/clang are Termux packages.

```bash
cd ~
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp

cmake -B build \
    -DGGML_VULKAN=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -G Ninja

cmake --build build --config Release -j$(nproc)
```

Build should complete with `[xxx/xxx] Linking CXX executable bin/llama-server`.

### Verify Vulkan Detection

During cmake configuration, look for:

```
-- Found Vulkan: /data/data/com.termux/files/usr/lib/libvulkan.so
```

If it says `Vulkan: not found`, the driver copy in step 2 didn't work.

## 4. Download a GGUF Model

```bash
# Example: Qwen3 8B Q4_K_M (good balance of quality and speed)
mkdir -p ~/models
cd ~/models
curl -LO https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/qwen3-8b-q4_k_m.gguf
```

Common quantizations for mobile:
| Quantization | Size (8B) | Quality | Speed |
|-------------|-----------|---------|-------|
| Q4_K_M      | ~4.9 GB   | Good    | Fast  |
| Q5_K_M      | ~5.7 GB   | Better  | Medium |
| Q6_K        | ~6.6 GB   | Best    | Slower |
| Q8_0        | ~8.5 GB   | Highest | Slowest |

## 5. Start llama-server

From **Termux native**:
```bash
~/llama.cpp/build/bin/llama-server \
    -m ~/models/qwen3-8b-q4_k_m.gguf \
    --port 8080 \
    -ngl 99 \
    -c 8192 \
    --threads $(nproc)
```

Flags:
- `-ngl 99` — Offload all layers to GPU (Vulkan)
- `-c 8192` — Context size (adjust based on available VRAM)
- `--port 8080` — Default port Blue Lodge expects
- `--threads N` — CPU threads for any non-offloaded layers

### Verify GPU Offload

In the server output, look for:
```
llm_load_tensors: offloading 32 layers to GPU
llm_load_tensors: VULKAN buffer size = XXXX MiB
```

If it says `offloading 0 layers`, Vulkan isn't working properly.

## 6. Configure Blue Lodge

Blue Lodge auto-detects llama-server when it's running on port 8080.
No configuration needed if using defaults.

### Manual Configuration

```bash
# In your shell profile or before running lodge:
export LLM_BACKEND=auto          # auto, llamacpp, or ollama
export LLAMA_CPP_URL=http://127.0.0.1:8080  # default

# Or use the /backend slash command in lodge:
/backend status     # Show active backend
/backend llamacpp   # Force llama-server
/backend auto       # Auto-detect (default)
```

### Auto-Detection Logic

1. If `LLM_BACKEND=llamacpp` → use llama-server (skip detection)
2. If `LLM_BACKEND=ollama` → use Ollama (skip detection)
3. If `LLM_BACKEND=auto` (default):
   - Ping `$LLAMA_CPP_URL/health` → if responding, use llama-server
   - Otherwise, fall back to Ollama

## 7. Performance Tips

### Adreno 830 Specific

- **Q4_K_M with 8B models**: Expect 15-30 tok/s generation on Adreno 830
- **Context length**: 8192 is safe; 16384 may work but increases VRAM pressure
- **Batch size**: Default is fine; larger batches help prompt processing
- **Thermal throttling**: Extended generation sessions may throttle. Consider:
  ```bash
  # Lower context if throttling occurs
  -c 4096
  ```

### General Termux Tips

- Run `termux-wake-lock` to prevent Android from killing the process
- Use `tmux` or `screen` for persistent server sessions
- Monitor with `vulkaninfo` and watch for GPU memory pressure

## Troubleshooting

### "llama-server not responding"
- Is the server process running? `pgrep -a llama-server`
- Check the port: `curl http://127.0.0.1:8080/health`
- Check server logs for errors

### "offloading 0 layers to GPU"
- Vulkan driver not found. Re-do step 2
- Try `vulkaninfo --summary` to verify driver

### Slow generation (< 5 tok/s)
- Confirm GPU offload is working (`-ngl 99`)
- Try a smaller quantization (Q4_K_M instead of Q8_0)
- Reduce context size (`-c 4096`)
- Check for thermal throttling

### Model too large for RAM
- Use a smaller quantization or smaller model
- Reduce `-ngl` to partially offload (e.g., `-ngl 20`)
- Close other apps to free RAM

## Architecture Notes

Blue Lodge's llama.cpp integration uses llama-server's OpenAI-compatible
API (`/v1/chat/completions`). Key differences from Ollama:

| Feature | Ollama | llama-server |
|---------|--------|-------------|
| API format | Custom (`/api/generate`) | OpenAI-compatible (`/v1/chat/completions`) |
| Stream format | Raw JSON per line | SSE (`data: {...}`) |
| Thinking API | `.thinking` field + `think:true` | Not supported |
| Model management | Built-in (pull/create) | Manual (load at server start) |
| Keep alive | `keep_alive` parameter | Server manages lifecycle |
| Multi-model | Switches on request | One model per server instance |

The thinking-token parsing (separate-field mode, inline-tag fallback)
only applies to the Ollama path. llama-server output is always treated
as plain content tokens.

## Auto-Start llama-server on Termux Boot

Install the [Termux:Boot](https://f-droid.org/en/packages/com.termux.boot/)
app from F-Droid. Create a boot script:

```bash
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start-llama-server.sh << 'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
# Auto-start llama-server with Vulkan GPU on Termux boot
# Waits 5s for system to settle, then starts the server.

sleep 5

# Config — adjust these for your setup
LLAMA_SERVER="$HOME/llama.cpp/build/bin/llama-server"
MODEL=""  # Set to GGUF path, or leave empty + set DEFAULT_MODEL below
DEFAULT_MODEL="minist-inst"  # Registry key or Ollama model name (resolved at runtime)
PORT=8080
GPU_LAYERS=99
CTX_SIZE=8192
LOG="/data/data/com.termux/files/usr/tmp/llama-server-boot.log"

# If no MODEL set, try to resolve from Blue Lodge registry
if [ -z "$MODEL" ] && [ -f "$HOME/blue-lodge/lib/models.sh" ]; then
    source "$HOME/blue-lodge/lib/models.sh"
    MODEL=$(_models_resolve_gguf "$DEFAULT_MODEL" 2>/dev/null)
fi

# Fallback: try Ollama blob resolution directly
if [ -z "$MODEL" ] || [ ! -f "$MODEL" ]; then
    source "$HOME/blue-lodge/lib/models.sh" 2>/dev/null
    MODEL=$(_models_find_ollama_gguf "$DEFAULT_MODEL" 2>/dev/null)
fi

if [ -z "$MODEL" ] || [ ! -f "$MODEL" ]; then
    echo "$(date): No model found for '$DEFAULT_MODEL'" >> "$LOG"
    exit 1
fi

if [ ! -x "$LLAMA_SERVER" ]; then
    echo "$(date): llama-server not found at $LLAMA_SERVER" >> "$LOG"
    exit 1
fi

echo "$(date): Starting llama-server on port $PORT with $(basename "$MODEL")" >> "$LOG"
"$LLAMA_SERVER" \
    -m "$MODEL" \
    --port "$PORT" \
    -ngl "$GPU_LAYERS" \
    -c "$CTX_SIZE" \
    --threads "$(nproc)" \
    >> "$LOG" 2>&1 &
echo $! > /data/data/com.termux/files/usr/tmp/llama-server.pid
BOOT
chmod +x ~/.termux/boot/start-llama-server.sh
```

After setup:
1. Open Termux once after installing Termux:Boot (required to register)
2. The script runs on device boot / Termux wake
3. Check log: `cat /data/data/com.termux/files/usr/tmp/llama-server-boot.log`
4. George (in Ubuntu proot) auto-detects the server via health check
