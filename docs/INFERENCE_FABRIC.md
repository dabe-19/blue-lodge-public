# Inference Fabric — Remote GPU Tier

George supports a three-tier inference fabric: **Central GPU** → **Cloud** → **Edge**.

## Architecture

Typical deployment: George runs on mobile (proot/Termux) or Crostini.
The SSH target may be the GPU server directly, or a **jump host**
(hypervisor/router) that NATs through to the GPU VM.

```
┌─────────────────────┐     SSH Tunnel      ┌──────────────────┐      ┌─────────────────────────┐
│   George Node       │ ──────────────────── │  Jump Host       │ ──── │  GPU Server (VM)        │
│   Galaxy Fold /     │   localhost ports    │  192.168.86.18   │ NAT  │  192.168.30.10          │
│   Crostini / WSL    │                      │  (hypervisor)    │      │  AMD 5700 XT Vulkan     │
│                     │                      └──────────────────┘      │                         │
│   lib/llm.sh        │ ◄─── HTTP ────────────────────────────────────► │  llama-server :8080     │
│   lib/remote.sh     │     127.0.0.1:8080                             │  Ollama :11434          │
│   lib/mcp_server_   │                                                │  33/33 GPU layers       │
│     inference.sh    │                                                │  60 tok/s (8B Q4_K_M)   │
└─────────────────────┘                                                └─────────────────────────┘
```

When the SSH target IS the GPU server, set `REMOTE_FORWARD_HOST=localhost` (default).
When tunnelling through a jump host, set `REMOTE_FORWARD_HOST=192.168.30.10`.

## Tiers

| Tier | Models | Where | Speed |
|------|--------|-------|-------|
| **Central** | 8B-12B (Qwen3-8B, Llama-3.1-8B, Mistral-Nemo-12B) | GPU VM via SSH tunnel | ~60 tok/s |
| **Cloud** | Provider-dependent | Free-tier APIs | Varies |
| **Edge** | 2-4B (Qwen3-4B, Ministral-3B, Phi-4-mini) | On device | ~10-15 tok/s |

## Quick Start

This walks through setting up remote GPU inference from scratch.

### Prerequisites (George / edge device)

The George device needs an SSH client and optionally `autossh` for
auto-reconnecting tunnels:

```bash
# Debian / Ubuntu / Crostini / WSL:
sudo apt install openssh-client autossh

# Termux (Android / proot):
pkg install openssh autossh

# iSH (iPhone / iPad — Alpine Linux):
apk add openssh-client autossh
```

`autossh` is **optional** — if it's not installed, George falls back to
a bash watchdog that polls the tunnel every 15 seconds and respawns it.
`autossh` is better because it detects drops instantly via
`ServerAliveInterval` and reconnects without any polling delay.

### 0. Provision the GPU Server

If the remote machine doesn't have Ollama + llama-server yet, deploy from
any George device:

```bash
./scripts/inference-server-deploy.sh dabe@192.168.86.18 --install --models qwen3:8b
```

Or SSH in manually and run:

```bash
bash inference-server-install.sh            # one-time: deps, Vulkan, Ollama, build llama.cpp
bash inference-server-models.sh qwen3:8b    # pull model + start llama-server on GPU
```

See [GPU Server Setup](#gpu-server-setup) for details.

### 1. Configure SSH Access (from George)

```bash
/remote setup dabe@192.168.86.18
```

Generates an ed25519 key (if needed), copies it to the remote, and tests the connection.

### 2. Set Forward Host (jump host topology)

If the SSH target is a jump host (not the GPU server itself):

```bash
/remote forward 192.168.30.10
```

Skip this step if the SSH target IS the GPU server.

### 3. Connect

```bash
/remote connect
```

Opens an SSH tunnel forwarding ports 11434 (Ollama) and 8080 (llama-server)
through the jump host to the GPU VM.  Uses `autossh` for auto-reconnect
when available; falls back to a bash watchdog.

### 4. Check Status

```bash
/remote status
/remote models
/remote ps
```

### 5. Pull Models

```bash
/remote pull qwen3:8b
/remote pull llama3.1:8b
/remote pull mistral-nemo:12b
```

### 6. Benchmark

```bash
/remote benchmark
```

## How It Works

### SSH Tunnel Transport (lib/remote.sh)

The tunnel is the foundation. It uses standard SSH port forwarding.

**Direct topology** (SSH target = GPU server):
```
ssh -N -f -L 8080:localhost:8080 dabe@gpu-server
```

**Jump host topology** (SSH target = hypervisor, GPU server behind NAT):
```
ssh -N -f -L 8080:192.168.30.10:8080 dabe@192.168.86.18
```

The `REMOTE_FORWARD_HOST` config controls the middle part of `-L local:FORWARD_HOST:remote`.

All existing HTTP code in `lib/llm.sh` hits `http://127.0.0.1:PORT` — zero changes needed.

#### Tunnel Resilience

- **autossh** (preferred): Install on the edge device (`apt install autossh`).
  George uses `autossh -M 0` with `ServerAliveInterval` for monitoring.
  Automatically reconnects on network drops.

- **Bash watchdog** (fallback): When `autossh` is not available, a background
  loop checks the tunnel PID every 15 seconds and respawns it if dead.
  Killed cleanly by `/remote disconnect`.

Both methods keep the tunnel alive without occupying a terminal session.

### Why No Modelfiles on Remote

The remote node runs two services with separate roles:

1. **Ollama** (port 11434) — **Model manager only.**  Downloads, stores, and
   catalogs GGUF files.  On AMD gfx1010 (Navi 10), Ollama runs CPU-only
   because ROCm doesn't support that GPU.  You only talk to Ollama for
   `pull`, `models`, `ps`, and `load`.

2. **llama-server** (port 8080) — **GPU inference engine.**  Loads a GGUF from
   Ollama's blob store, runs it on GPU via Vulkan at full speed (60 tok/s
   on 5700 XT).  George's `lib/llm.sh` sends all prompts here.

#### How models flow: Ollama → GGUF blob → llama-server

```
ollama pull qwen3:8b
    ↓
~/.ollama/models/manifests/registry.ollama.ai/library/qwen3/8b
    ↓  (jq: extract digest for mediaType "application/vnd.ollama.image.model")
~/.ollama/models/blobs/sha256-XXXXX   ← this is the raw GGUF file
    ↓
llama-server -m /path/to/sha256-XXXXX --jinja --port 8080 -ngl 99
```

The `--jinja` flag tells llama-server to read the chat template directly
from the GGUF metadata — no Modelfile or template file needed.

`scripts/inference-server-models.sh` automates this entire flow.

#### Why llama-server is a dumb GPU pipe

llama-server doesn't need system prompts, thinking directives, or sampling
config baked in. George's `lib/llm.sh` injects everything at request time:

- **System prompt**: `models_default_system()` / identity fallback
- **Thinking directive**: `models_thinking_directive()` prepended to system
- **Sampling params**: `_llm_build_llamacpp_payload()` from `_MODELS_REGISTRY[]`
- **Chat template**: `--jinja` reads GGUF-embedded template

The remote server just needs raw GGUF files loaded.

### MCP Server (lib/mcp_server_inference.sh)

A JSON-RPC 2.0 MCP server with 5 tools:

| Tool | Description |
|------|-------------|
| `inference_status` | Health check for both endpoints |
| `inference_models` | List Ollama models (name, size, quant, family) |
| `inference_ps` | Show loaded model and VRAM usage |
| `inference_pull` | Download a model by exact Ollama tag |
| `inference_load` | Pre-warm a model into memory |

Install: `/mcp install george-inference`

### Model Registry Tier Field

Field 17 in `_MODELS_REGISTRY[]` (^-delimited):

- `edge` — 2-4B models, runs on phone/laptop
- `central` — 8B+ models, requires GPU server
- `any` — runs anywhere (backward compat default)

Central-tier models in registry:
- `qwen3-8b-think` / `qwen3-8b-inst` — Qwen3 8B
- `llama31-8b` — Llama 3.1 8B (proven 60 tok/s on 5700 XT)
- `mistral-nemo-12b` — Mistral Nemo 12B (~7GB VRAM)

## /remote Command Reference

| Subcommand | Description |
|------------|-------------|
| `/remote` or `/remote status` | Show tunnel status and endpoint health |
| `/remote connect [user@host]` | Open SSH tunnel (autossh or ssh+watchdog) |
| `/remote disconnect` | Close SSH tunnel, kill watchdog, restore URLs |
| `/remote setup [user@host]` | Interactive SSH key configuration |
| `/remote forward [host]` | Show/set forward host for jump host topology |
| `/remote models` | List all models on remote Ollama |
| `/remote ps` | Show currently loaded model(s) + VRAM |
| `/remote pull <tag>` | Pull model by exact Ollama tag |
| `/remote load <model>` | Pre-warm model into memory |
| `/remote url [ollama] [llama]` | Show/set remote endpoint URLs |
| `/remote benchmark` | Quick tok/s benchmark |

## Configuration

Stored in `.george/remote.conf`:

| Variable | Default | Description |
|----------|---------|-------------|
| `REMOTE_SSH_TARGET` | (none) | user@host for SSH tunnel |
| `REMOTE_SSH_PORT` | 22 | SSH port |
| `REMOTE_SSH_KEY` | ~/.ssh/id_ed25519 | Identity file path |
| `REMOTE_FORWARD_HOST` | localhost | IP/hostname the SSH target forwards to |
| `REMOTE_OLLAMA_PORT` | 11434 | Remote Ollama port |
| `REMOTE_LLAMACPP_PORT` | 8080 | Remote llama-server port |
| `REMOTE_LOCAL_OLLAMA_PORT` | 11434 | Local bind port (Ollama) |
| `REMOTE_LOCAL_LLAMACPP_PORT` | 8080 | Local bind port (llama-server) |

## GPU Server Setup

The remote VM needs:

1. **Vulkan drivers**: `mesa-vulkan-drivers` (for AMD Navi10)
2. **llama-server**: Built with `-DGGML_VULKAN=ON` (or `-DGGML_CUDA=ON` for NVIDIA)
3. **Ollama**: For model management (CPU-only on AMD gfx1010; GPU-accelerated on NVIDIA)
4. **User in ollama group**: `sudo usermod -aG ollama $USER`

### Provisioning Scripts

Three scripts handle the full lifecycle:

| Script | Runs on | Purpose |
|--------|---------|---------|
| `scripts/inference-server-deploy.sh` | George device | SCP scripts to remote, optionally run install + model load |
| `scripts/inference-server-install.sh` | Remote GPU node | One-time setup: deps, Ollama, build llama.cpp (Vulkan/CUDA) |
| `scripts/inference-server-models.sh` | Remote GPU node | Pull model via Ollama → resolve GGUF blob → start llama-server |

### Deploy from George device

```bash
# Copy scripts + run install + pull qwen3:8b + start llama-server:
./scripts/inference-server-deploy.sh dabe@192.168.86.18 --install --models qwen3:8b

# Just copy scripts (manual install later):
./scripts/inference-server-deploy.sh dabe@192.168.86.18

# Custom SSH port or key:
./scripts/inference-server-deploy.sh dabe@192.168.86.18 --port 2222 --key ~/.ssh/gpu_key
```

### What `inference-server-install.sh` does

1. Installs build tools: `build-essential cmake git curl jq`
2. Auto-detects GPU: Vulkan (AMD/Intel), CUDA (NVIDIA), or CPU-only
3. Installs GPU-specific packages (`mesa-vulkan-drivers` or `nvidia-cuda-toolkit`)
4. Verifies GPU access via `vulkaninfo` or `nvidia-smi`
5. Installs Ollama via official installer
6. Clones + builds llama.cpp with the detected backend
7. Optionally creates systemd service for llama-server (`INSTALL_SYSTEMD=1`)

### What `inference-server-models.sh` does

1. Pulls the model via `ollama pull <ref>` (downloads GGUF to blob store)
2. Resolves the GGUF blob path from Ollama's manifest + digest
3. Unloads the model from Ollama (frees VRAM for llama-server)
4. Starts `llama-server -m <gguf_blob> --jinja -ngl 99 --port 8080`
5. Waits for healthy, verifies GPU offload

Also supports:
```bash
bash inference-server-models.sh --list            # show all models + GGUF resolution status
bash inference-server-models.sh --resolve qwen3:8b # print the GGUF blob path
bash inference-server-models.sh --stop             # stop running llama-server
```

### Manual setup (without scripts)

```bash
# On the GPU server:
sudo apt install mesa-vulkan-drivers vulkan-tools build-essential cmake git curl jq
git clone --depth 1 https://github.com/ggerganov/llama.cpp.git
cd llama.cpp && cmake -B build -DGGML_VULKAN=ON && cmake --build build -j$(nproc) -- llama-server
curl -fsSL https://ollama.com/install.sh | sh
sudo usermod -aG ollama $USER

# Pull a model:
ollama pull qwen3:8b

# Find the GGUF blob:
GGUF=$(jq -r '.layers[] | select(.mediaType=="application/vnd.ollama.image.model") | .digest' \
  ~/.ollama/models/manifests/registry.ollama.ai/library/qwen3/8b)
GGUF_PATH=~/.ollama/models/blobs/${GGUF//:/-}

# Start llama-server:
./build/bin/llama-server -m "$GGUF_PATH" --jinja --port 8080 -ngl 99 --host 0.0.0.0
```

## Troubleshooting

**Tunnel dies silently**:
`/remote status` detects stale PID and cleans up. With `autossh`, reconnection
is automatic. With the bash watchdog fallback, the tunnel respawns within 15s.
Run `/remote disconnect && /remote connect` for an immediate manual reconnect.

**Port already in use**:
Change `REMOTE_LOCAL_OLLAMA_PORT` / `REMOTE_LOCAL_LLAMACPP_PORT` in remote.conf.

**Ollama shows CPU-only**:
Expected on AMD gfx1010. ROCm doesn't support Navi 10. Use llama-server with Vulkan for GPU inference; Ollama is the model manager.

**VRAM exceeded**:
The 5700 XT has 8GB. Q4_K_M fits: 8B (~4.5GB), 12B (~7GB). Larger models need more aggressive quantization.

## Performance Reference (AMD RX 5700 XT)

| Model | Quant | VRAM | Gen tok/s | Prompt tok/s |
|-------|-------|------|-----------|--------------|
| Llama 3.1 8B | Q4_K_M | 4.4GB | 60.57 | 113.60 |
| 12B (estimated) | Q4_K_M | ~7GB | ~40 | ~70 |

## Network Topology Examples

### Direct: George → GPU Server (same subnet)

```
Fold 7 (192.168.86.50)  ──SSH──►  GPU Server (192.168.86.100)
  REMOTE_SSH_TARGET=dabe@192.168.86.100
  REMOTE_FORWARD_HOST=localhost              ← default
```

### Jump Host: George → Hypervisor → GPU VM (different subnets)

```
Fold 7 (192.168.86.x)  ──SSH──►  Hypervisor (192.168.86.18)  ──NAT──►  GPU VM (192.168.30.10)
  REMOTE_SSH_TARGET=dabe@192.168.86.18
  REMOTE_FORWARD_HOST=192.168.30.10         ← must be set
```

The SSH tunnel `-L 8080:FORWARD_HOST:8080` adapts to either topology.
The phone and all George code always talk to `127.0.0.1:8080`.

---

## Adding New Models (Step-by-Step Guide)

You **only** need to edit one file: `lib/models.sh`.  Nothing in `agent.sh`,
`llm.sh`, or anywhere else needs to change — those are model-agnostic.

### The Registry Format

Each model is a single `^`-delimited string in the `_MODELS_REGISTRY` array:

```
key^friendly_name^base_image^role^has_thinking^nothink_method^stop_token^temperature^repeat_penalty^presence_penalty^num_ctx^num_predict^top_p^top_k^min_p^notes^tier
```

| # | Field | What it is | Example |
|---|-------|-----------|---------|
| 1 | key | Internal lookup ID | `qwen3-8b-think` |
| 2 | friendly_name | Ollama model name after `ollama create` | `blue-lodge-qwen3-think:8b` |
| 3 | base_image | Upstream reference (HF, library, or Ollama tag) | `hf.co/unsloth/Qwen3-8B-GGUF:Q4_K_M` |
| 4 | role | `thinking` or `instruct` | `thinking` |
| 5 | has_thinking | `1` = emits `<think>` blocks, `0` = no | `1` |
| 6 | nothink_method | How to suppress thinking: `qwen`, `system`, `none` | `qwen` |
| 7 | stop_token | Model's EOS token | `<\|im_end\|>` |
| 8 | temperature | Sampling temp | `0.6` |
| 9 | repeat_penalty | Anti-repetition | `1.3` |
| 10 | presence_penalty | Topic diversity | `0.8` |
| 11 | num_ctx | Context window | `32768` |
| 12 | num_predict | Max output tokens | `32768` |
| 13 | top_p | Nucleus sampling | `0.95` |
| 14 | top_k | Top-K sampling | `20` |
| 15 | min_p | Min-P sampling | `0.0` |
| 16 | notes | Human description | `Qwen3 8B thinking...` |
| 17 | tier | `edge` (2-4B), `central` (8B+), `any` | `central` |

### Example: Adding a 12B Unsloth Model

Let's say you want to add **Mistral Nemo 12B** using Unsloth's GGUF quantization.

#### Step 1: Find the Unsloth GGUF on HuggingFace

Go to `https://huggingface.co/unsloth` and search for your model.
Look for quantized GGUF files — common choices for 8GB VRAM:

| Quant | VRAM (12B) | Quality | When to use |
|-------|-----------|---------|-------------|
| Q4_K_M | ~7 GB | Good | Fits 8GB GPU with headroom |
| Q5_K_M | ~8.5 GB | Better | Tight fit on 8GB, good on 12GB |
| UD-Q4_K_XL | ~7 GB | Best at size | Unsloth dynamic quant, preferred |

The HF reference format is:
```
hf.co/unsloth/<ModelName>-GGUF:<QuantTag>
```

Example: `hf.co/unsloth/Mistral-Nemo-Instruct-2407-GGUF:Q4_K_M`

#### Step 2: Identify the model's chat template and stop token

| Model family | Stop token | nothink_method | Chat template |
|-------------|-----------|----------------|---------------|
| Qwen / Qwen3 / Qwen3.5 | `<\|im_end\|>` | `qwen` (thinking) / `none` (instruct) | ChatML |
| Llama 3.x | `<\|eot_id\|>` | `none` | llama3 |
| Mistral / Ministral | `</s>` | `system` (reasoning) / `none` (instruct) | mistral |
| Phi-4 | `<\|end\|>` | `system` (reasoning) / `none` (instruct) | phi4 |
| Gemma 3 | `<end_of_turn>` | `none` | gemma |
| Granite 4 | `<\|end_of_text\|>` | `system` (preview) / `none` (instruct) | granite |

#### Step 3: Choose sampling parameters

Rules of thumb:
- **Thinking models**: temp 0.6–0.8, top_p 0.95, higher num_predict (32768)
- **Instruct models**: temp 0.15, top_p 0.8–0.9, lower num_predict (8192–16384)
- **repeat_penalty**: 1.0–1.3 (higher for models that loop, e.g., Ministral needs 1.2)
- **presence_penalty**: 0.0 for instruct, 0.3–0.8 for thinking/reasoning
- Check the model card on HF for vendor-recommended sampling params

#### Step 4: Add the entry to `_MODELS_REGISTRY`

Open `lib/models.sh` and add your line in the `Central Tier` section:

```bash
    # ── Central Tier (8B+, requires remote GPU) ────────────────
    # ... existing entries ...

    # Mistral Nemo 12B (Unsloth Q4_K_M): instruct, fits 5700 XT (~7GB VRAM).
    "mistral-nemo-12b-unsloth^blue-lodge-mistral-nemo-unsloth:12b^hf.co/unsloth/Mistral-Nemo-Instruct-2407-GGUF:Q4_K_M^instruct^0^none^</s>^0.15^1.1^0.0^32768^8192^0.9^40^0.0^Mistral Nemo 12B Unsloth quant. Fits 5700 XT VRAM.^central"
```

That's it. No other files to edit.

#### Step 5: Pull it onto the remote GPU server

```bash
# From George:
/remote pull hf.co/unsloth/Mistral-Nemo-Instruct-2407-GGUF:Q4_K_M

# Or via the provisioning script:
./scripts/inference-server-models.sh hf.co/unsloth/Mistral-Nemo-Instruct-2407-GGUF:Q4_K_M
```

Ollama will download the GGUF, and `inference-server-models.sh` resolves
the blob path and starts llama-server with it.

#### Step 6: Select it in George

```bash
# Set as primary (thinking/planning):
/model primary blue-lodge-mistral-nemo-unsloth:12b

# Or as secondary (fast/code):
/model secondary blue-lodge-mistral-nemo-unsloth:12b
```

### Quick-Reference: Popular ~12B Unsloth Models

| Model | HF base_image | Role | Stop | VRAM (Q4_K_M) |
|-------|--------------|------|------|----------------|
| Mistral Nemo 12B | `hf.co/unsloth/Mistral-Nemo-Instruct-2407-GGUF:Q4_K_M` | instruct | `</s>` | ~7 GB |
| Qwen2.5 14B | `hf.co/unsloth/Qwen2.5-14B-Instruct-GGUF:Q4_K_M` | instruct | `<\|im_end\|>` | ~8 GB |
| Llama 3.1 8B | `hf.co/unsloth/Meta-Llama-3.1-8B-Instruct-GGUF:Q5_K_M` | instruct | `<\|eot_id\|>` | ~5.5 GB |
| Phi-4 14B | `hf.co/unsloth/phi-4-GGUF:Q4_K_M` | instruct | `<\|end\|>` | ~8 GB |
| Gemma 3 12B | `hf.co/unsloth/gemma-3-12b-it-GGUF:Q4_K_M` | instruct | `<end_of_turn>` | ~7 GB |

For thinking variants of the same model, change `role` to `thinking`,
`has_thinking` to `1`, set `nothink_method` appropriately, bump temperature
to 0.6–0.8, and increase `num_predict` to 32768.
