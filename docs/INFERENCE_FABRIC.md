# Inference Fabric — Remote GPU Tier

George supports a three-tier inference fabric: **Central GPU** → **Cloud** → **Edge**.

## Architecture

Typical deployment: George runs on mobile (proot/Termux) or Crostini.
The SSH target may be the GPU server directly, or a **jump host**
(hypervisor/router) that NATs through to the GPU VM.

```
┌─────────────────────┐     SSH Tunnel      ┌──────────────────┐      ┌─────────────────────────┐
│   George Node       │ ──────────────────── │  Jump Host       │ ──── │  GPU Server (VM)        │
│   Phone / Laptop /  │   localhost ports    │  192.168.1.10    │ NAT  │  10.0.0.100             │
│   Crostini / WSL    │                      │  (hypervisor)    │      │  AMD 5700 XT Vulkan     │
│                     │                      └──────────────────┘      │                         │
│   lib/llm.sh        │ ◄─── HTTP ────────────────────────────────────► │  llama-server :8080     │
│   lib/remote.sh     │     127.0.0.1:8080                             │  Ollama :11434          │
│   lib/mcp_server_   │                                                │  33/33 GPU layers       │
│     inference.sh    │                                                │  60 tok/s (8B Q4_K_M)   │
└─────────────────────┘                                                └─────────────────────────┘
```

When the SSH target IS the GPU server, set `REMOTE_FORWARD_HOST=localhost` (default).
When tunnelling through a jump host, set `REMOTE_FORWARD_HOST=10.0.0.100`.

## Tiers

| Tier | Models | Where | Speed |
|------|--------|-------|-------|
| **Central** | 8B-12B (`qwen35-9b-inst`, `granite41-8b-inst`, `gemma4-12b-inst`) | GPU VM via SSH tunnel | ~60 tok/s |
| **Cloud** | Provider-dependent | Free-tier APIs | Varies |
| **Edge** | 2-4B (`gemma4-e2b-inst`, `gemma4-e4b-inst`, `qwen35-4b-think`) | On device | ~10-15 tok/s |

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
./scripts/inference-server-deploy.sh user@192.168.1.10 --install --models blue-lodge-gemma4-inst:4b
```

Or SSH in manually and run:

```bash
bash inference-server-install.sh            # one-time: deps, Vulkan, Ollama, build llama.cpp
bash inference-server-models.sh blue-lodge-gemma4-inst:4b    # resolve model + start llama-server on GPU
```

See [GPU Server Setup](#gpu-server-setup) for details.

### 1. Configure SSH Access (from George)

```bash
/remote setup user@192.168.1.10
```

Generates an ed25519 key (if needed), copies it to the remote, and tests the connection.

### 2. Set Forward Host (jump host topology)

If the SSH target is a jump host (not the GPU server itself):

```bash
/remote forward 10.0.0.100
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
/remote pull blue-lodge-gemma4-inst:4b
/remote pull blue-lodge-qwen35-inst:9b
/remote pull blue-lodge-granite41-inst:8b
```

### 6. Switch Models

Once connected, switch the active model on the remote llama-server:

```bash
/models single qwen35-9b-inst
```

George resolves the GGUF from Ollama's blob store, restarts llama-server
with the new model (via systemd override or nohup), waits for the health
check, and confirms the switch.  Requires passwordless sudo if
llama-server runs as a systemd service (see
[Sudoers Setup](#sudoers-setup-for-model-switching)).

### 7. Benchmark

```bash
/remote benchmark
```

## How It Works

### Dual-Path SSH Architecture (lib/remote.sh)

George uses a **dual-path** SSH design that separates the data plane
(port-forwarded tunnel) from the control plane (remote command execution).

#### Data Plane — SSH Tunnel

The tunnel carries all HTTP traffic (Ollama API, llama-server prompts)
over port-forwarded localhost connections.  It connects **one hop**
to the nearest SSH host:

**Direct topology** (SSH target = GPU server):
```
ssh -N -f -L 8080:localhost:8080 user@gpu-server
```

**Jump host topology** (tunnel to jump host, forward to GPU LAN IP):
```
ssh -N -f -L 8080:10.0.0.100:8080 user@jump-host
```

The tunnel target is chosen by `_remote_tunnel_target()`: when
`REMOTE_JUMP_HOST` is set, the tunnel terminates at the jump host
(NOT the GPU server).  The `-L` forwards resolve from the jump host's
perspective via `REMOTE_FORWARD_HOST`.  There is **no `-J` ProxyJump**
in the tunnel path — it's a single-hop SSH connection.

`REMOTE_FORWARD_HOST` controls the middle part of `-L local:FORWARD_HOST:remote`.

All HTTP code in `lib/llm.sh` hits `http://127.0.0.1:PORT` — zero changes needed.

#### Control Plane — Remote Execution

Commands that run on the GPU server (GPU detection, binary detection,
model switching, systemd operations) use `_remote_exec()`, which
connects to `REMOTE_SSH_TARGET` with `-J $REMOTE_JUMP_HOST` when a
jump host is configured.  This gives each path its optimal route:

```
┌──────────────┐
│  Data Plane  │  ssh -N -L ... jump-host        (one hop, no -J)
│  (tunnel)    │  Carries: HTTP to Ollama + llama-server
├──────────────┤
│ Control Plane│  ssh -J jump-host gpu-server CMD (ProxyJump)
│  (_remote_   │  Carries: systemctl, GPU probe, binary detect,
│   exec)      │  GGUF resolution, model restart
└──────────────┘
```

In direct topology (no jump host), both paths connect to the same host.

#### Tunnel Resilience

- **autossh** (preferred): Install on the edge device (`apt install autossh`).
  George uses `autossh -M 0` with `ServerAliveInterval` for monitoring.
  Automatically reconnects on network drops.

- **Bash watchdog** (fallback): When `autossh` is not available, a background
  loop checks the tunnel PID every 15 seconds and respawns it if dead.
  Killed cleanly by `/remote disconnect`.

Both methods keep the tunnel alive without occupying a terminal session.

#### Session Reattachment

When lodge starts, `_remote_auto_reattach()` (called at module load time)
checks whether a tunnel from a prior session is still alive.  If the PID
file exists and the process is running, it silently restores
`OLLAMA_URL`, `LLAMA_CPP_URL`, `_REMOTE_CONNECTED`, and clears the
backend detection cache so the next LLM call re-probes the tunneled
endpoints.  No user interaction needed — just restart lodge and you're
back on the remote GPU.

#### Backend Cache

Both `remote_connect()` and `_remote_auto_reattach()` clear
`_LLM_BACKEND_CACHE` after updating URLs.  This forces `_llm_detect_backend()`
to re-probe whether the tunneled endpoint is Ollama or llama-server,
preventing stale cache hits that pointed at the old local backend.

### Remote Model Switching

When connected to a remote llama-server, George can switch models
automatically — no manual SSH required.

#### How It Works

1. **User selects a model**: `/models single qwen35-9b-inst`
2. **Eager switch in main shell**: `models_select()` detects
   `_REMOTE_CONNECTED=1` and backend `llamacpp`, then calls
   `_remote_restart_llamacpp()` directly — in the main shell process,
   not inside a subshell.  This is critical because bash subshells
   (like `$(llm_stream ...)`) lose variable state on exit.
3. **GGUF resolution**: The function resolves the model name to a GGUF
   blob path on the GPU server.  It tries the Ollama API first
   (`/api/show` → manifest → blob digest), then falls back to
   `ollama show --modelfile` CLI output.
4. **Restart llama-server**: Three strategies, tried in order:
   - **Systemd override** (preferred): Writes a drop-in override at
     `/etc/systemd/system/llama-server.service.d/model.conf` with a
     new `ExecStart=` line pointing to the resolved GGUF, then runs
     `systemctl daemon-reload && systemctl restart llama-server`.
     Requires passwordless sudo (see [Sudoers Setup](#sudoers-setup-for-model-switching)).
   - **Sudo unavailable**: If systemd exists but sudo needs a password,
     prints the exact sudoers rule to add and returns an error.
   - **Nohup fallback**: If llama-server isn't a systemd service,
     kills the running process and spawns a new one via `nohup`.
5. **Health check**: Polls `/health` on the tunneled endpoint for up to
   60 seconds.  After getting `{"status":"ok"}`, additionally checks
   `/v1/models` to verify a model is actually loaded (llama-server
   returns healthy even with no model).
6. **State update**: On success, sets `_MODELS_ACTIVE` and `LODGE_MODEL`
   in the main shell.  Subsequent `models_ensure_for_scenario()` calls
   short-circuit for remote llamacpp, trusting the eager switch.

#### GPU-Aware Flags

The restart command automatically includes GPU-specific flags based on
`_remote_detect_gpu()` results:

| Backend | Flags added to llama-server |
|---------|----------------------------|
| **CUDA** | `--flash-attn --cache-type-k q8_0 --cache-type-v q8_0` |
| **Vulkan** | (none — defaults to f16 KV cache, no flash-attn) |
| **CPU** | (none) |

#### Example

```bash
/remote connect
/models single qwen35-9b-inst
# → "Restarting remote llama-server with blue-lodge-qwen35-inst:9b..."
# → (waits for health + model load)
# → "Remote model switched to blue-lodge-qwen35-inst:9b"
/q What is the capital of France?
# → response from remote GPU at ~60 tok/s
```

### llama-server Binary Detection

George auto-detects the `llama-server` binary on the GPU server using
5 strategies (tried in order, first match wins):

1. `/proc/PID/exe` symlink of a running llama-server process
2. `ps -eo args` parsing
3. Common install paths: `~/llama.cpp/build/bin/`, `/usr/local/bin/`,
   `/opt/llama.cpp/build/bin/`, `/usr/bin/`
4. `command -v llama-server`
5. `find /home /usr/local /opt` (slow, last resort)

Once found, the path is saved in `REMOTE_LLAMACPP_BIN` in `remote.conf`
so subsequent sessions skip detection.  Override manually:
```bash
/remote config REMOTE_LLAMACPP_BIN /home/user/llama.cpp/build/bin/llama-server
```

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
ollama ls | grep blue-lodge-gemma4-inst:4b
    ↓
~/.ollama/models/manifests/.../blue-lodge-gemma4-inst/4b
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
- `gemma4-12b-inst` — Gemma 4 12B central quality tier
- `qwen35-9b-inst` — Qwen 3.5 9B central coding tier
- `granite41-8b-inst` — Granite 4.1 8B structured central tier

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
| `/remote config` | Show all remote config (SSH topology, GPU, server) |
| `/remote config KEY VALUE` | Set a config key (e.g., `REMOTE_JUMP_HOST`) |

## Configuration

Stored in `.george/remote.conf`:

### SSH & Tunnel

| Variable | Default | Description |
|----------|---------|-------------|
| `REMOTE_SSH_TARGET` | (none) | user@host for SSH tunnel |
| `REMOTE_SSH_PORT` | 22 | SSH port |
| `REMOTE_SSH_KEY` | ~/.ssh/id_ed25519 | Identity file path |
| `REMOTE_JUMP_HOST` | (none) | user@host for SSH ProxyJump. Used by `_remote_exec()` for control-plane commands (`-J`). The tunnel connects directly to this host instead (no `-J`). Set when the SSH target is behind a jump box. |
| `REMOTE_FORWARD_HOST` | localhost | IP/hostname the SSH target forwards to |
| `REMOTE_OLLAMA_PORT` | 11434 | Remote Ollama port |
| `REMOTE_LLAMACPP_PORT` | 8080 | Remote llama-server port |
| `REMOTE_LOCAL_OLLAMA_PORT` | 11434 | Local bind port (Ollama) |
| `REMOTE_LOCAL_LLAMACPP_PORT` | 8080 | Local bind port (llama-server) |

### GPU & Performance

| Variable | Default | Description |
|----------|---------|-------------|
| `REMOTE_LLAMACPP_BIN` | (auto-detected) | Absolute path to `llama-server` binary on the GPU server. Auto-detected via 5 strategies if not set. |
| `REMOTE_GPU_BACKEND` | auto | GPU backend: `cuda`, `vulkan`, or `cpu`. `auto` probes via `nvidia-smi` / `vulkaninfo`. |
| `REMOTE_KV_CACHE_TYPE` | auto | KV cache quantization: `q8_0` (CUDA), `f16` (Vulkan/CPU). `auto` resolves from GPU backend. |
| `REMOTE_FLASH_ATTN` | auto | Flash attention: `on` (CUDA only), `off` (Vulkan/CPU). `auto` resolves from GPU backend. |

## GPU Performance Flags

When `REMOTE_GPU_BACKEND` is `auto` (default), George probes the remote
server via `nvidia-smi` and `vulkaninfo` and resolves the optimal settings:

| Backend | Flash Attention | KV Cache Type | Notes |
|---------|----------------|---------------|-------|
| **CUDA** (NVIDIA) | `--flash-attn` | `--cache-type-k q8_0 --cache-type-v q8_0` | Quantized KV cache saves VRAM; flash-attn improves throughput |
| **Vulkan** (AMD/Intel) | off | `f16` (default) | Vulkan does not support quantized KV or flash attention |
| **CPU** | off | `f16` (default) | No GPU acceleration |

Override any auto-detected value:
```bash
/remote config REMOTE_FLASH_ATTN off      # disable flash attention even on CUDA
/remote config REMOTE_KV_CACHE_TYPE f16    # force f16 KV cache
/remote config REMOTE_GPU_BACKEND vulkan   # skip auto-detection
```

These flags are injected into the `llama-server` command line by
`_remote_restart_llamacpp()` and into the systemd service by
`inference-server-install.sh`.

## GPU Server Setup

The remote VM needs:

1. **Vulkan drivers**: `mesa-vulkan-drivers` (for AMD Navi10)
2. **llama-server**: Built with `-DGGML_VULKAN=ON` (or `-DGGML_CUDA=ON` for NVIDIA)
3. **Ollama**: For model management (CPU-only on AMD gfx1010; GPU-accelerated on NVIDIA)
4. **User in ollama group**: `sudo usermod -aG ollama $USER`
5. **Passwordless sudo** for systemd model switching (see [Sudoers Setup](#sudoers-setup-for-model-switching))

### Provisioning Scripts

Three scripts handle the full lifecycle:

| Script | Runs on | Purpose |
|--------|---------|---------|
| `scripts/inference-server-deploy.sh` | George device | SCP scripts to remote, optionally run install + model load |
| `scripts/inference-server-install.sh` | Remote GPU node | One-time setup: deps, Ollama, build llama.cpp (Vulkan/CUDA) |
| `scripts/inference-server-models.sh` | Remote GPU node | Pull model via Ollama → resolve GGUF blob → start llama-server |

### Deploy from George device

```bash
# Copy scripts + run install + load blue-lodge-gemma4-inst:4b + start llama-server:
./scripts/inference-server-deploy.sh user@192.168.1.10 --install --models blue-lodge-gemma4-inst:4b

# Just copy scripts (manual install later):
./scripts/inference-server-deploy.sh user@192.168.1.10

# Custom SSH port or key:
./scripts/inference-server-deploy.sh user@192.168.1.10 --port 2222 --key ~/.ssh/gpu_key
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
bash inference-server-models.sh --resolve blue-lodge-gemma4-inst:4b # print the GGUF blob path
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
ollama ls | grep blue-lodge-gemma4-inst:4b

# Find the GGUF blob:
MANIFEST=~/.ollama/models/manifests/.../<your-model-path>
GGUF=$(jq -r '.layers[] | select(.mediaType=="application/vnd.ollama.image.model") | .digest' \
  "$MANIFEST")
GGUF_PATH=~/.ollama/models/blobs/${GGUF//:/-}

# Start llama-server:
./build/bin/llama-server -m "$GGUF_PATH" --jinja --port 8080 -ngl 99 --host 0.0.0.0
```

### Sudoers Setup (for model switching)

When llama-server runs as a systemd service, George needs passwordless
sudo on the GPU server to restart it with a new model.  Without this,
`/models single <key>` will print the required sudoers rule and fail.

On the GPU server, create a sudoers drop-in:

```bash
sudo visudo -f /etc/sudoers.d/llama-server
```

Add one line (replace `dabe` with the SSH user):

```
dabe ALL=(ALL) NOPASSWD: /bin/systemctl restart llama-server, /bin/systemctl stop llama-server, /bin/systemctl daemon-reload, /bin/mkdir -p /etc/systemd/system/llama-server.service.d, /usr/bin/tee /etc/systemd/system/llama-server.service.d/*
```

This grants exactly the permissions George needs — systemd control and
the ability to write the model override file — without full root access.

Verify from the George device:
```bash
ssh -J jump-host user@gpu-server 'sudo -n systemctl status llama-server'
```

If llama-server is NOT a systemd service (e.g., started via `nohup`),
sudoers is not needed — George falls back to killing and respawning the
process directly.

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

**Model switch fails — "sudo requires a password"**:
llama-server is a systemd service but passwordless sudo isn't configured.
Follow the [Sudoers Setup](#sudoers-setup-for-model-switching) instructions.
George prints the exact sudoers rule to add.

**Model switch fails — "Cannot resolve GGUF"**:
The model hasn't been pulled via Ollama on the GPU server yet.
Run `/remote pull <tag>` first, then retry the model switch.

**llama-server healthy but no response**:
llama-server returns `{"status":"ok"}` even with no model loaded.
George checks `/v1/models` after health to verify.  If you see
"started but not healthy after 60s", check `/tmp/llama-server.log`
on the GPU server (nohup fallback) or `journalctl -u llama-server`
(systemd path).

**Stale backend after connect**:
If `/remote connect` succeeds but queries still hit the local backend,
the LLM backend cache may be stale.  This should auto-clear on connect.
As a workaround: `/remote disconnect && /remote connect`.

**Commands run on jump host instead of GPU server**:
Set `REMOTE_JUMP_HOST` so `_remote_exec()` uses ProxyJump.
Without it, commands execute on whatever host the tunnel connects to.
See [ProxyJump topology](#proxyjump-george--jump-box--gpu-server-control--data-plane).

## Performance Reference (AMD RX 5700 XT)

| Model | Quant | VRAM | Gen tok/s | Prompt tok/s |
|-------|-------|------|-----------|--------------|
| Llama 3.1 8B | Q4_K_M | 4.4GB | 60.57 | 113.60 |
| 12B (estimated) | Q4_K_M | ~7GB | ~40 | ~70 |

## Network Topology Examples

### Direct: George → GPU Server (same subnet)

```
Phone (192.168.1.50)  ──SSH──►  GPU Server (192.168.1.100)
  REMOTE_SSH_TARGET=user@192.168.1.100
  REMOTE_FORWARD_HOST=localhost              ← default
```

### Jump Host: George → Hypervisor → GPU VM (different subnets)

```
Phone (192.168.1.x)  ──SSH──►  Hypervisor (192.168.1.10)  ──NAT──►  GPU VM (10.0.0.100)
  REMOTE_SSH_TARGET=user@192.168.1.10
  REMOTE_FORWARD_HOST=10.0.0.100            ← must be set
```

The SSH tunnel `-L 8080:FORWARD_HOST:8080` adapts to either topology.
The phone and all George code always talk to `127.0.0.1:8080`.

### ProxyJump: George → Jump Box → GPU Server (control + data plane)

When the jump box and GPU server are **separate hosts**, George uses
the **dual-path architecture** to route data and control traffic
through different SSH paths:

**Data plane (tunnel):** Connects to the jump host directly (no `-J`),
forwards ports through to the GPU server's LAN IP:
```
autossh → jump-host -L 18080:192.168.30.10:8080 -L 21434:192.168.30.10:11434
```

**Control plane (exec):** Uses `-J` ProxyJump through the jump host to
execute commands on the GPU server:
```
ssh -J dabe@192.168.86.18 dabe@george-home 'sudo systemctl restart llama-server'
```

Full topology:
```
Termux (192.168.86.x)
  │
  ├── Tunnel ──SSH──► Jump Box (192.168.86.18) ─L forward─► GPU (192.168.30.10)
  │                   (one hop, no -J)           :8080, :11434
  │
  └── Exec ───SSH -J jump-box──────────────────► GPU (192.168.30.10)
                     (ProxyJump)                  systemctl, detect, probe

  REMOTE_SSH_TARGET=dabe@george-home         ← actual GPU server
  REMOTE_JUMP_HOST=dabe@192.168.86.18        ← ProxyJump hop for exec
  REMOTE_FORWARD_HOST=192.168.30.10          ← LAN IP for -L forwards
```

Without `REMOTE_JUMP_HOST`, commands like `_remote_exec 'nvidia-smi'` run
on the jump box — not the GPU server.  The data plane (tunneled ports) would
work, but control operations (model restart, GPU probe, binary detection)
would fail silently.

Configure with:
```bash
/remote config REMOTE_JUMP_HOST dabe@192.168.86.18
/remote config REMOTE_SSH_TARGET dabe@george-home
/remote config REMOTE_FORWARD_HOST 192.168.30.10
```

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
| 1 | key | Internal lookup ID | `qwen35-9b-inst` |
| 2 | friendly_name | Ollama model name after `ollama create` | `blue-lodge-qwen35-inst:9b` |
| 3 | base_image | Upstream reference (HF, library, or Ollama tag) | `hf.co/unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL` |
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
| 16 | notes | Human description | `Qwen 3.5 9B instruct...` |
| 17 | tier | `edge` (2-4B), `central` (8B+), `any` | `central` |

### Example: Adding A Central-Tier Unsloth Model

Let's say you want to add **Gemma 4 12B** using Unsloth's GGUF quantization.

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

Example: `hf.co/unsloth/gemma-4-12B-it-qat-GGUF:UD-Q4_K_XL`

#### Step 2: Identify the model's chat template and stop token

| Model family | Stop token | nothink_method | Chat template |
|-------------|-----------|----------------|---------------|
| Qwen 3.5 | `<\|im_end\|>` | `qwen` (thinking) / `none` (instruct) | ChatML |
| Gemma 4 | `<end_of_turn>` | `none` | gemma |
| Granite 4.1 | `<\|end_of_text\|>` | `none` | granite |
| Nemotron 3 | `<\|eot_id\|>` | `none` | llama3-style |
| Llama 3.x | `<\|eot_id\|>` | `none` | llama3 |

#### Step 3: Choose sampling parameters

Rules of thumb:
- **Thinking models**: temp 0.6–0.8, top_p 0.95, higher num_predict (32768)
- **Instruct models**: temp 0.15, top_p 0.8–0.9, lower num_predict (8192–16384)
- **repeat_penalty**: 1.0–1.3 (raise it for models that loop or self-repeat)
- **presence_penalty**: 0.0 for instruct, 0.3–0.8 for thinking/reasoning
- Check the model card on HF for vendor-recommended sampling params

#### Step 4: Add the entry to `_MODELS_REGISTRY`

Open `lib/models.sh` and add your line in the `Central Tier` section:

```bash
    # ── Central Tier (8B+, requires remote GPU) ────────────────
    # ... existing entries ...

    # Gemma 4 12B (Unsloth UD-Q4_K_XL): instruct, central GPU quality tier.
    "gemma4-12b-inst^blue-lodge-gemma4-inst:12b^hf.co/unsloth/gemma-4-12B-it-qat-GGUF:UD-Q4_K_XL^instruct^0^none^<end_of_turn>^0.2^1.0^0.0^32768^16384^0.9^40^0.0^Gemma 4 12B QAT instruct. Central GPU quality tier.^central"
```

That's it. No other files to edit.

#### Step 5: Pull it onto the remote GPU server

```bash
# From George:
/remote pull hf.co/unsloth/gemma-4-12B-it-qat-GGUF:UD-Q4_K_XL

# Or via the provisioning script:
./scripts/inference-server-models.sh hf.co/unsloth/gemma-4-12B-it-qat-GGUF:UD-Q4_K_XL
```

Ollama will download the GGUF, and `inference-server-models.sh` resolves
the blob path and starts llama-server with it.

#### Step 6: Select it in George

```bash
# Set as primary:
/models select primary gemma4-12b-inst

# Or keep it in single-model mode on the remote path:
/models single gemma4-12b-inst
```

### Quick Reference: Popular Central-Tier Curated Models

| Model | HF base_image | Role | Stop | Tier |
|-------|--------------|------|------|------|
| Gemma 4 12B | `hf.co/unsloth/gemma-4-12B-it-qat-GGUF:UD-Q4_K_XL` | instruct | `<end_of_turn>` | central |
| Qwen 3.5 9B | `hf.co/unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL` | instruct | `<\|im_end\|>` | central |
| Granite 4.1 8B | `hf.co/unsloth/granite-4.1-8b-GGUF:Q4_K_M` | instruct | `<\|end_of_text\|>` | central |
| Gemma 4 E4B | `hf.co/unsloth/gemma-4-E4B-it-qat-GGUF:UD-Q4_K_XL` | instruct | `<end_of_turn>` | edge |
| Qwen 3.5 4B think | `hf.co/unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL` | thinking | `<\|im_end\|>` | edge |

For thinking variants of the same model, change `role` to `thinking`,
`has_thinking` to `1`, set `nothink_method` appropriately, bump temperature
to 0.6–0.8, and increase `num_predict` to 32768.
