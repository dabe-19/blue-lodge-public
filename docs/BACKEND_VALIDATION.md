# Backend Validation Guide

How to verify that Ollama and llama.cpp (llama-server) are working
correctly, confirm GPU vs CPU inference, and troubleshoot issues.

---

## Table of Contents

1. [Quick Health Checks](#1-quick-health-checks)
2. [Sending Test Messages](#2-sending-test-messages)
3. [Verifying GPU Usage](#3-verifying-gpu-usage)
4. [GPU Validation Script Walkthrough](#4-gpu-validation-script-walkthrough)
5. [Performance Benchmarking](#5-performance-benchmarking)
6. [Modelfiles: Ollama vs llama.cpp](#6-modelfiles-ollama-vs-llamacpp)
7. [GPU Troubleshooting (llama.cpp)](#7-gpu-troubleshooting-llamacpp)
8. [GPU Troubleshooting (Ollama)](#8-gpu-troubleshooting-ollama)
9. [Side-by-Side Comparison](#9-side-by-side-comparison)

---

## 1. Quick Health Checks

### Ollama

```bash
# Is the server responding?
curl -s http://127.0.0.1:11434/api/tags | jq .

# Expected: {"models":[...]} listing your pulled models

# Is a model loaded in memory?
curl -s http://127.0.0.1:11434/api/ps | jq .

# Expected: {"models":[{"name":"qwen3:8b",...}]} if loaded
```

### llama-server

```bash
# Is the server responding?
curl -s http://127.0.0.1:8080/health | jq .

# Expected: {"status":"ok"}
# Other statuses:
#   "loading model" — model is still loading into memory
#   "no slot available" — all slots busy processing requests

# Server properties (model info, capabilities)
curl -s http://127.0.0.1:8080/props | jq .
```

### From Inside Blue Lodge

```
/backend status
```

This shows health of both backends simultaneously.

---

## 2. Sending Test Messages

### Ollama — Test Generate

```bash
# Simple completion (non-streaming)
curl -s http://127.0.0.1:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3:8b","prompt":"Say hello in one word.","stream":false,"options":{"num_predict":10}}' \
  | jq '{response, eval_count, eval_duration, prompt_eval_count}'
```

**Key fields in response:**
- `response` — the generated text
- `eval_count` — output tokens generated
- `eval_duration` — time spent generating (nanoseconds)
- `prompt_eval_count` — input tokens processed
- `prompt_eval_duration` — time for prompt processing (nanoseconds)

**Calculate tokens/second:**
```bash
# From the response JSON:
# tok/s = eval_count / (eval_duration / 1e9)
echo "scale=1; 50 / (2500000000 / 1000000000)" | bc
# = 20.0 tok/s
```

### llama-server — Test Completion

```bash
# Simple completion (non-streaming, OpenAI format)
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":10}' \
  | jq '{choices: [.choices[0].message.content], usage}'
```

**Key fields in response:**
- `choices[0].message.content` — the generated text
- `usage.prompt_tokens` — input tokens
- `usage.completion_tokens` — output tokens

### llama-server — Detailed Timing (the /slots endpoint)

This is where llama-server **does** report GPU/performance info:

```bash
# Show active slots with timing data
curl -s http://127.0.0.1:8080/slots | jq '.[0] | {
  state,
  n_predict,
  prompt_tokens: .n_past,
  generated_tokens: .n_decoded,
  prompt_ms: (.t_prompt_processing // 0),
  generation_ms: (.t_token_generation // 0),
  prompt_tok_per_sec: (.prompt_per_second // 0),
  generation_tok_per_sec: (.predicted_per_second // 0)
}'
```

> **Note:** The `/slots` endpoint is only available when llama-server is
> started with `--slots` or `--metrics`. Add `--metrics` to your start
> command for full visibility.

### llama-server — Prometheus Metrics

```bash
# If started with --metrics flag:
curl -s http://127.0.0.1:8080/metrics | grep -E "^llama_"

# Key metrics:
#   llama_prompt_tokens_seconds     — prompt processing speed
#   llama_tokens_second_total       — generation speed (tok/s)
#   llama_kv_cache_usage_ratio      — memory pressure indicator
```

---

## 3. Verifying GPU Usage

### The Big Question: Is My GPU Actually Being Used?

Both backends can run on CPU silently — you won't get an error, just
slower speeds. Here's how to confirm GPU offload for each.

### Ollama — GPU Verification

Ollama reports GPU info in `ollama ps`:

```bash
# Show loaded model and processor info
ollama ps

# Expected (GPU):
# NAME        ID            SIZE     PROCESSOR    UNTIL
# qwen3:8b    abc123...     5.2 GB   100% GPU     4 minutes from now

# If CPU:
# PROCESSOR column will show "100% CPU" or "CPU"
```

Also check the Ollama model details:

```bash
curl -s http://127.0.0.1:11434/api/show \
  -d '{"name":"qwen3:8b"}' | jq '.details'
```

### llama-server — GPU Verification

llama-server reports GPU offload **at startup in its log output**. This
is the most reliable way to verify:

```bash
# Check the server startup log
cat ${TMPDIR:-/tmp}/lodge-llama-server.log | grep -E "offload|VULKAN|GPU|VRAM|ggml_vulkan"
```

**What GPU success looks like:**

```
ggml_vulkan: Found 1 Vulkan device:
ggml_vulkan: 0 = Adreno (TM) 830 (Qualcomm) | uma: 1 | fp16: 1 | warp size: 64
llm_load_tensors: offloading 32 layers to GPU
llm_load_tensors: VULKAN buffer size = 4403.12 MiB
llm_load_tensors:   CPU buffer size =   70.31 MiB
```

**What CPU-only looks like (bad):**

```
llm_load_tensors: offloading 0 layers to GPU
# or no VULKAN/GPU lines at all
```

#### Runtime GPU Check (Without Server Restart)

llama-server's `/health` and completion responses don't explicitly say
"GPU" or "CPU". However, you can **infer** it from speed:

```bash
# Time a test completion
time curl -s http://127.0.0.1:8080/v1/chat/completions \
  -d '{"messages":[{"role":"user","content":"Count from 1 to 20."}],"max_tokens":100}' \
  -H "Content-Type: application/json" > /dev/null
```

**Expected speeds on Adreno 830 (8B Q4_K_M):**
| Mode | tok/s (approx) |
|------|---------------|
| Vulkan GPU | 15-30 tok/s |
| CPU only | 3-8 tok/s |

If your speed is below 10 tok/s on an 8B model, GPU likely isn't engaged.

#### Android GPU Monitor (Termux)

```bash
# Watch GPU frequency (confirms GPU is active during inference)
# This requires root or specific device support
while true; do
    cat /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null \
        || cat /sys/class/kgsl/kgsl-3d0/clock_mhz 2>/dev/null \
        || echo "GPU freq not accessible"
    sleep 1
done

# Alternative: dumpsys (may require adb or specific permissions)
dumpsys gpu 2>/dev/null | head -20
```

---

## 4. Performance Benchmarking

### Quick Benchmark Script

Run this from Termux to compare both backends:

```bash
#!/bin/bash
# Save as ~/bench-backends.sh

PROMPT='Write a haiku about the ocean.'
TOKENS=50

echo "═══ Ollama ═══"
if curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
    START=$(date +%s%N)
    RESULT=$(curl -s http://127.0.0.1:11434/api/generate \
        -d "{\"model\":\"qwen3:8b\",\"prompt\":\"$PROMPT\",\"stream\":false,\"options\":{\"num_predict\":$TOKENS}}")
    END=$(date +%s%N)
    ELAPSED=$(echo "scale=2; ($END - $START) / 1000000000" | bc)
    EVAL_COUNT=$(echo "$RESULT" | jq -r '.eval_count // 0')
    EVAL_DUR=$(echo "$RESULT" | jq -r '.eval_duration // 0')
    TPS=$(echo "scale=1; $EVAL_COUNT / ($EVAL_DUR / 1000000000)" | bc 2>/dev/null || echo "?")
    echo "  Time: ${ELAPSED}s | Tokens: $EVAL_COUNT | Speed: ${TPS} tok/s"
    echo "  Response: $(echo "$RESULT" | jq -r '.response' | head -3)"
else
    echo "  Not running"
fi

echo ""
echo "═══ llama-server ═══"
if curl -sf http://127.0.0.1:8080/health &>/dev/null; then
    START=$(date +%s%N)
    RESULT=$(curl -s http://127.0.0.1:8080/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT\"}],\"max_tokens\":$TOKENS}")
    END=$(date +%s%N)
    ELAPSED=$(echo "scale=2; ($END - $START) / 1000000000" | bc)
    COMP_TOKENS=$(echo "$RESULT" | jq -r '.usage.completion_tokens // 0')
    PROMPT_TOKENS=$(echo "$RESULT" | jq -r '.usage.prompt_tokens // 0')
    TPS=$(echo "scale=1; $COMP_TOKENS / $ELAPSED" | bc 2>/dev/null || echo "?")
    echo "  Time: ${ELAPSED}s | Tokens: $COMP_TOKENS | Speed: ${TPS} tok/s"
    echo "  Response: $(echo "$RESULT" | jq -r '.choices[0].message.content' | head -3)"
else
    echo "  Not running"
fi
```

### Expected Results Table (Adreno 830, 8B Q4_K_M)

| Metric | Ollama (GPU) | llama-server (Vulkan) | CPU-only |
|--------|-------------|----------------------|----------|
| Prompt processing | ~200-400 tok/s | ~300-600 tok/s | ~50-100 tok/s |
| Token generation | 15-25 tok/s | 15-30 tok/s | 3-8 tok/s |
| First token latency | 1-3s | 0.5-2s | 3-10s |
| VRAM usage | ~5 GB (auto) | ~4.5 GB (-ngl 99) | ~0 (all RAM) |

> llama-server with Vulkan often has a slight edge because it talks
> directly to the Vulkan driver without Ollama's abstraction layer.

---

## 5. GPU Troubleshooting (llama.cpp)

### Problem: "offloading 0 layers to GPU"

**Cause:** Vulkan not detected at build time or runtime.

**Fix checklist:**

1. **Was llama.cpp built with Vulkan?**
   ```bash
   # Re-check cmake config output
   grep -i vulkan ~/llama.cpp/build/CMakeCache.txt
   # Should show: GGML_VULKAN:BOOL=ON
   ```

2. **Is the Vulkan driver accessible?**
   ```bash
   # Test Vulkan directly
   vulkaninfo --summary 2>/dev/null | head -10
   
   # If "Cannot create Vulkan instance" → driver not found
   
   # Copy the driver (Adreno)
   cp /vendor/lib64/hw/vulkan.adreno.so $PREFIX/lib/
   # or for 32-bit:
   cp /vendor/lib/hw/vulkan.adreno.so $PREFIX/lib/
   ```

3. **Is the driver the right architecture?**
   ```bash
   file $PREFIX/lib/vulkan.adreno.so
   # Should say "ELF 64-bit" for aarch64 Termux
   ```

4. **Rebuild after fixing Vulkan:**
   ```bash
   cd ~/llama.cpp
   rm -rf build
   cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -G Ninja
   cmake --build build --config Release -j$(nproc)
   ```

### Problem: Vulkan works but low tok/s

1. **Not enough layers offloaded:**
   ```bash
   # Start with ALL layers on GPU
   llama-server -m model.gguf -ngl 99
   
   # Check log for "offloading N layers" — N should match
   # the model's actual layer count (e.g., 32 for 8B models)
   ```

2. **Thermal throttling:**
   ```bash
   # Check thermal zone (may vary by device)
   cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null
   
   # If temps > 80000 (80°C), the GPU is throttling
   # Solution: reduce context (-c 4096), wait for cooldown,
   # or use a fan/cooling case
   ```

3. **Memory pressure (model too big for VRAM):**
   ```bash
   # If you see "VULKAN buffer size" > your available VRAM,
   # some layers fall back to CPU
   
   # Try a smaller quantization:
   # Q8_0 (8.5 GB) → Q4_K_M (4.9 GB) for 8B models
   
   # Or partially offload:
   llama-server -m model.gguf -ngl 20  # only 20 layers to GPU
   ```

### Problem: Server crashes or hangs

```bash
# Check the log for errors
tail -50 ${TMPDIR:-/tmp}/lodge-llama-server.log

# Common causes:
# - "cudaMalloc failed" / "vkAllocateMemory failed" → out of GPU memory
#   Fix: use -ngl with fewer layers, or smaller quant
#
# - "Segmentation fault" → usually a driver issue
#   Fix: update Termux packages, re-copy Vulkan driver
#
# - "SIGKILL" → Android killed the process (OOM)
#   Fix: close other apps, use termux-wake-lock
```

### Problem: "llama-server: command not found"

```bash
# The binary is in the build directory, not in PATH
# Either use the full path:
~/llama.cpp/build/bin/llama-server -m ...

# Or add to PATH in .bashrc / .zshrc:
export PATH="$HOME/llama.cpp/build/bin:$PATH"

# Or from Blue Lodge:
export LLAMA_CPP_SERVER_BIN="$HOME/llama.cpp/build/bin/llama-server"
/backend start model.gguf
```

---

## 6. GPU Troubleshooting (Ollama)

### Problem: `ollama ps` shows "CPU" instead of "GPU"

1. **Check Ollama build supports GPU:**
   ```bash
   ollama --version
   # Termux Ollama may be CPU-only depending on how it was installed
   ```

2. **Force GPU via environment:**
   ```bash
   # Some Ollama builds respect these:
   export OLLAMA_GPU=vulkan
   export OLLAMA_NUM_GPU=99
   ollama serve
   ```

3. **Check Ollama's logs:**
   ```bash
   cat /tmp/lodge-ollama.log 2>/dev/null | grep -iE "gpu|vulkan|cuda|metal"
   ```

### Problem: Ollama is slow on Termux

Ollama's Termux support is unofficial and often **CPU-only**. This is a
primary reason for using llama.cpp directly — it gives you explicit
Vulkan GPU control that Ollama on Termux may not provide.

---

## 7. Side-by-Side Comparison

### What Each Backend Reports

| Capability | Ollama | llama-server |
|-----------|--------|-------------|
| **GPU usage indicator** | `ollama ps` → PROCESSOR column | Startup log ("offloading N layers") |
| **Tokens/second** | `eval_count / eval_duration` in response | `/metrics` endpoint or wall-clock timing |
| **Memory usage** | `ollama ps` → SIZE column | Startup log ("VULKAN buffer size") |
| **Prompt tokens** | `prompt_eval_count` in response | `usage.prompt_tokens` in response |
| **Output tokens** | `eval_count` in response | `usage.completion_tokens` in response |
| **Model details** | `/api/show` endpoint | `/props` endpoint |
| **Live monitoring** | `ollama ps` (limited) | `/metrics` + `/slots` (detailed) |

### Recommendation

For **Termux on Adreno GPUs**, llama-server is the better choice because:

1. **Explicit Vulkan control** — you see exactly which layers are on GPU
2. **Better performance visibility** — `/metrics` and startup logs give
   detailed insight that Ollama on Termux doesn't expose
3. **Direct GPU access** — no abstraction layer, better tok/s
4. **Ollama on Termux is often CPU-only** — unofficial build, no GPU guarantee

Use Ollama when:
- You need easy model management (pull/create/push)
- You're on a platform with official Ollama GPU support (Linux desktop, macOS)
- You want the Modelfile/template system

### Blue Lodge Quick Validation

From inside a lodge session, the fastest way to validate everything:

```
/backend status          # See which backend is active + health
/backend start qwen3:8b  # Start llama-server with Ollama's GGUF
/ask "Say hello"         # Test a quick generation
/debug on                # Enable timing info
/ask "Count to 10"       # See tok/s in debug output
/debug off
```
