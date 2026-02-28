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

## 4. GPU Validation Script Walkthrough

Blue Lodge ships `scripts/validate-gpu.sh` — a fully automated end-to-end
test that starts a temporary llama-server, confirms Vulkan GPU offloading,
streams a test prompt, and reports performance. It runs on a **dedicated
port (8090)** so it won't interfere with your normal llama-server or Ollama
instances.

### Prerequisites

- llama-server binary built with Vulkan (see [ADRENO_GPU_SETUP.md](ADRENO_GPU_SETUP.md))
- At least one model pulled via Ollama (`ollama pull qwen3:8b`) or a direct GGUF file
- `jq` installed (comes with Termux by default)

### Quickstart — Using Ollama Model Names

The simplest workflow: use `ollama ls` to see what you have, then pass
the model name directly to the script.

```bash
# Step 1: See what models are available
$ ollama ls
NAME                  ID            SIZE     MODIFIED
qwen3:8b              abc123...     4.9 GB   2 hours ago
minist-think:latest   def456...     4.7 GB   1 day ago
granite3.3:8b         789abc...     4.8 GB   3 days ago

# Step 2: Run validation with any model name from that list
$ ./scripts/validate-gpu.sh qwen3:8b
```

The script resolves the Ollama model name to its underlying GGUF blob
automatically — no need to know the blob path.

### All Input Methods

| Method | Example | When to Use |
|--------|---------|-------------|
| Ollama model name | `./scripts/validate-gpu.sh qwen3:8b` | Most common — use names from `ollama ls` |
| Registry key | `./scripts/validate-gpu.sh minist-inst` | Blue Lodge registry keys (shorter aliases) |
| Direct GGUF path | `./scripts/validate-gpu.sh /path/to/model.gguf` | Testing a GGUF not managed by Ollama |
| Interactive picker | `./scripts/validate-gpu.sh` | No argument — shows a numbered menu |

### What Each Step Does

The script runs 8 automated steps:

**Step 1 — Resolve Model:**
Takes your input (Ollama name, registry key, or path) and locates the
actual GGUF file. For Ollama names, it reads the manifest at
`~/.ollama/models/manifests/` to find the blob digest, then resolves to
`~/.ollama/models/blobs/sha256-...`.

**Step 2 — Validate Binary:**
Confirms `llama-server` exists and is executable. Checks `--help` output
for Vulkan/GPU flags. Also kills any existing process on port 8090.

**Step 3 — Start Server:**
Launches llama-server on port 8090 with `-ngl 99` (all layers to GPU).
Waits up to 45 seconds for the `/health` endpoint to return `"ok"`.
Server log is captured to a temp file for GPU offload analysis.

**Step 4 — Check GPU Offloading:**
Parses the server startup log for offload confirmation. Looks for:
- `"offloaded N/N layers to GPU"` — confirms layer offloading
- `"ggml_vulkan"` / `"VULKAN"` — confirms Vulkan backend active
- Extracts layer count and GPU device name

**Step 5 — Stream Test Prompt:**
Sends a streaming request to `/v1/chat/completions` and prints tokens in
real time. Default prompt: *"What is the capital of France? Answer in one
sentence."* Override with `VALIDATE_PROMPT` env var.

**Step 6 — Performance Analysis:**
Calculates:
- **TTFT** (Time to First Token) — how fast prompt evaluation completes
- **tok/s** — generation speed after first token
- Performance verdict: `≥15 → GPU confirmed`, `5-14 → partial/small model`, `<5 → likely CPU`

**Step 7 — Server Metrics:**
Pulls Prometheus metrics from `/metrics` (prompt/generation tok/s) and
slot timing from `/slots` if available.

**Step 8 — Summary:**
Prints a results table and overall verdict:
- **PASS** — GPU offloading active and model responding
- **PARTIAL** — Model responding but GPU offload unconfirmed
- **FAIL** — No response from model

### Example Output

```
═══ llama.cpp GPU Offload Validation ═══

[1] Resolving model
  ✓ Resolved: qwen3:8b (ollama)
    GGUF: /home/.ollama/models/blobs/sha256-abc123... (4.9G)

[2] Checking llama-server binary
  ✓ Binary: /home/llama.cpp/build/bin/llama-server
  ✓ Vulkan/GPU flags detected in binary

[3] Starting llama-server with GPU offloading
    Port: 8090 | GPU layers: 99 | Context: 4096
    PID: 12345
[3a] Waiting for server to become healthy...
    Loading model... (8s)
  ✓ Server healthy (8s startup)

[4] Checking GPU offloading
  ✓ GPU offloading CONFIRMED
    Layers offloaded: 33
    Backend: Vulkan
    Device: ggml_vulkan: 0 = Adreno (TM) 830 (Qualcomm)

[5] Sending test prompt (streaming)
    Prompt: "What is the capital of France? Answer in one sentence."

  The capital of France is Paris.

[6] Performance analysis
  ✓ Response received: 9 tokens, 35 chars
    Time to first token:  1200ms
    Total generation:     1850ms
    Generation speed:     12.3 tok/s

  ✓ GPU acceleration CONFIRMED (12.3 tok/s — expected for GPU)

[7] Server metrics
    Prompt eval: 285.4 tok/s
    Generation:  12.3 tok/s

═══ Validation Summary ═══

  Model:                qwen3:8b (ollama)
  GGUF size:            4.9G
  GPU offload:          YES (33 layers)
  GPU backend:          Vulkan
  Response tokens:      9
  Speed:                12.3 tok/s
  Time to first token:  1200ms

  PASS — GPU offloading active, model responding

  Log: /tmp/lodge-gpu-validate-20260228-103045.log
  Server log: /tmp/lodge-gpu-validate-server.log
```

### Environment Overrides

| Variable | Default | Purpose |
|----------|---------|--------|
| `LLAMA_CPP_SERVER_BIN` | `~/llama.cpp/build/bin/llama-server` | Path to llama-server binary |
| `LLAMA_CPP_GPU_LAYERS` | `99` | GPU layers to offload (`-ngl`) |
| `LLAMA_CPP_CTX_SIZE` | `4096` | Context window size (`-c`) |
| `VALIDATE_PORT` | `8090` | Port for temporary test server |
| `VALIDATE_PROMPT` | *"What is the capital of France?..."* | Custom test prompt |

### Interactive Model Picker

When run without arguments, the script lists all available models:

```bash
$ ./scripts/validate-gpu.sh

[1] Resolving model
[1a] Scanning available models...

  #    MODEL                               SIZE
  ---  -----------------------------------  ------
  1    minist-inst (specialist)             4.7G
  2    minist-think (thinking)              4.7G
  3    qwen3:8b (ollama)                    4.9G
  4    granite3.3:8b (ollama)               4.8G

  Select model [1-4]: _
```

Models from the Blue Lodge registry appear first (with their role), then
any additional Ollama models not already in the registry.

### Log Files

Every run produces two log files:
- **Validation log:** `${TMPDIR}/lodge-gpu-validate-YYYYMMDD-HHMMSS.log` — full transcript including server log, response text, and timing data
- **Server log:** `${TMPDIR}/lodge-gpu-validate-server.log` — raw llama-server stdout/stderr (overwritten each run)

The validation log is timestamped so previous runs are preserved.

---

## 5. Performance Benchmarking

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

## 6. Modelfiles: Ollama vs llama.cpp

Blue Lodge uses Ollama Modelfiles to customize model behavior (system
prompt, chat template, sampling parameters). When running the same GGUF
through llama-server instead, it's important to understand what
transfers automatically and what doesn't.

### The Three Layers

Model behavior in Blue Lodge is controlled by three independent layers:

| Layer | Ollama | llama-server | Action Needed |
|-------|--------|-------------|---------------|
| **Chat template** | `TEMPLATE` directive in Modelfile | Read from GGUF `tokenizer.chat_template` metadata | None — GGUF has it built in |
| **System prompt** | `SYSTEM` directive in Modelfile | Injected via API messages array by `llm_stream()` | None — already handled |
| **Sampling params** | `PARAMETER` directives in Modelfile | Sent as API fields by `_llm_build_llamacpp_payload()` | None — already handled |

### Chat Templates: How They Work

Every GGUF file contains a `tokenizer.chat_template` field in its
metadata. This is a Jinja2 template that defines how messages are
formatted into the raw token stream (e.g., `<|im_start|>user\n...` for
ChatML, `[INST]...` for Mistral).

- **Ollama:** Reads the GGUF template, but allows overriding it with a
  `TEMPLATE` directive in the Modelfile (written in Go template syntax).
- **llama-server:** Reads the same GGUF template directly. When you hit
  `/v1/chat/completions`, the server applies the template automatically.

Since both backends read the template from the GGUF, models format
messages identically. No injection or translation is needed.

### System Prompt Injection

Ollama stores the system prompt via `SYSTEM` in the Modelfile. This is
an Ollama-only concept — llama-server doesn't read Modelfiles at all.

Blue Lodge handles this transparently: `llm_stream()` prepends the
George persona system prompt as a `{"role":"system","content":"..."}`
message in the API request. Both Ollama's `/api/chat` and llama-server's
`/v1/chat/completions` accept messages in this format.

### Sampling Parameters

Ollama uses `PARAMETER` directives (`temperature`, `top_p`, `num_predict`,
etc.). llama-server accepts the same parameters as JSON fields in the API
payload.

Blue Lodge's `_llm_build_opts()` reads the model registry and outputs
sampling parameters. For llama-server, `_llm_build_llamacpp_payload()`
merges these into the OpenAI-format request body. Both backends receive
identical sampling configuration.

### The Modelfile Edge Case: Custom TEMPLATE Overrides

Some Blue Lodge Modelfiles override the GGUF's built-in chat template:

- **Ministral models** (`minist-think.Modelfile`): Uses a custom Mistral
  v7 template (`[SYSTEM_PROMPT]...[INST]...`) via the `TEMPLATE` directive.
- **Granite4-preview**: Uses a custom IBM Go template.

These `TEMPLATE` overrides only work in Ollama. When llama-server loads
the same GGUF, it uses the template baked into the GGUF metadata instead.

**In practice this is fine:**
- Unsloth and official GGUFs ship with the correct `tokenizer.chat_template`
  already embedded. The Modelfile overrides exist as a safety net for
  Ollama, not because the GGUF templates are wrong.
- If a model ever misbehaves on llama-server (garbled output, wrong
  formatting), the fix is `--chat-template-file template.jinja` at server
  startup. This hasn't been needed for any current models.

### Summary

Switching from Ollama to llama-server requires **no code changes** for
template handling. Blue Lodge already sends system prompts and sampling
params via the API. The GGUF carries its own chat template. The only
Ollama-specific feature that doesn't transfer is the `TEMPLATE` override,
which is a redundant safety net for models whose GGUFs already contain
the correct template.

---

## 7. GPU Troubleshooting (llama.cpp)

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

## 8. GPU Troubleshooting (Ollama)

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

## 9. Side-by-Side Comparison

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
