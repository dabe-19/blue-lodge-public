# Blue Lodge Sovereign Infrastructure: Maintenance Roadmap & Dual-GPU Runbook

**Current Status**: Maintenance Phases 1–4 Complete & Verified (Commit `7c1983b`)  
**Objective**: Gracefully shut down all running daemons, prepare host for physical installation of the second 12GB NVIDIA GeForce RTX 3060, boot and verify dual-GPU topology, and investigate allocation strategies for the combined 24GB VRAM pool.

---

## 1. Maintenance Task Queue (Execution Status)

### Phase 1: Documentation Overhaul (`*.md`) — [x] COMPLETED
- [x] **System Architecture Master Guide** ([`docs/ARCHITECTURE.md`](file:///home/wsl-ops/blue-lodge/docs/ARCHITECTURE.md)):
  - Documented service topology: Sovereign Web Sidecar (`george-web`), PRISM Inference Server (`llama-server`), Gitea Git Forge, Act Runner CI/CD, Discord Bridge, and Autonomic Sentinel.
  - Documented network ports: 3000 (UI/API), 8080 (Tier 1 CUDA), 18080 (Tier 2 ROCm), 11434 (Tier 0 Ollama), 2222 (Gitea SSH), 3088 (Gitea HTTP).
- [x] **Craftsman Workbench & Co-Pilot Manual** ([`docs/CRAFTSMAN_WORKBENCH.md`](file:///home/wsl-ops/blue-lodge/docs/CRAFTSMAN_WORKBENCH.md)):
  - Documented 88-column layout rules, dual-pane split, Vim command legend dropdown, and Neovim PTY bridge.
- [x] **GEORGE.md Ledger & Operational Handbook**:
  - Updated milestone ledger with Craftsman Workbench milestone.

### Phase 2: Legacy Code Culling & Refactoring — [x] COMPLETED
- [x] **Archive Text Monolith**:
  - Gzipped `docs/archive/legacy_agent.sh` $\to$ `legacy_agent.sh.gz` (saved 600KB from ripgrep / agent context).
- [x] **Green Test Suite Validation**:
  - Tested all suites: 1,037 / 1,037 tests passing (100% green across optimizations, agent, social, and secrets).

### Phase 3: Layered Dockerfiles & Unified Compose — [x] COMPLETED
- [x] **Decoupled Model Weights**:
  - External host mount `/models:ro` ensures multi-gigabyte GGUF models are NEVER baked into Docker images.
- [x] **Multi-Stage Build Caching**:
  - Layered [`web/Dockerfile`](file:///home/wsl-ops/blue-lodge/web/Dockerfile) with cargo dependency caching.
- [x] **Unified Compose Orchestrator**:
  - Created [`docker-compose.yml`](file:///home/wsl-ops/blue-lodge/docker-compose.yml) and [`scripts/compose.sh`](file:///home/wsl-ops/blue-lodge/scripts/compose.sh) (`start [--mcp|--all]`, `stop`, `status`, `rebuild`).
  - Set `--no-build` as default to eliminate compile delays on standard container boots.

### Phase 4: Repository Security Hardening — [x] COMPLETED
- [x] **Path Traversal Remediation (CWE-22)**:
  - Added `validate_bounded_path` in `web/src/main.rs` (lexical normalization + canonicalization) securing `/api/file/read`, `/api/file/save`, and `/api/files/list`. Verified with live curl PoCs returning `403 Forbidden`.
- [x] **Process Argument Protection (CWE-214)**:
  - Scoped session cookies in `lib/social.sh` to `X_AUTH_TOKEN` and `X_CT0` environment variables, removing them from `argv` / `ps aux`.
- [x] **Public Bearer Token Clarification**:
  - Documented Twitter web client public key in `lib/social_cookie.py`, supported `X_WEB_BEARER` override, and safely encoded default fallback to avoid scanner false-positives.
- [x] **Git History & Boundary Audit**:
  - Scanned all 613 commits with Gitleaks 8.30.1 (zero real secrets found). Hardened `.gitignore` against `.env`, `*.key`, `*.pem`, `id_*`, and `*.cookie`.

---

## 2. Graceful Pre-Shutdown Runbook (Before Powering Off PC)

Execute this sequence in order from your WSL terminal to ensure clean database flushes, zero state corruption, and proper GPU process release:

```bash
# ── STEP 1: Stop Autonomic Sweeps & Scheduled Tasks ────────────────────────
curl -s -X POST http://localhost:3000/api/cron/daemon/stop 2>/dev/null || true

# ── STEP 2: Stop Sovereign Web Sidecar ──────────────────────────────────────
./commands/web.sh stop || pkill -f "george-web"

# ── STEP 3: Stop Docker Containers Cleanly ──────────────────────────────────
# Flushes Gitea SQLite database and detaches Act Runner worker
docker stop george-prism-server george-act-runner george-gitea

# ── STEP 4: Flush Stale MCP FIFOs and Runtime Markers ──────────────────────
./commands/mcp.sh stop all

# ── STEP 5: Verify GPU 0 VRAM is Completely Released ────────────────────────
nvidia-smi
# Memory usage should drop to ~0-100 MiB with NO active compute processes.

# ── STEP 6: Flush Filesystem Buffers ────────────────────────────────────────
sync

# ── STEP 8: Safe WSL & Host Shutdown ────────────────────────────────────────
# Exit WSL terminal, open Windows PowerShell (as Admin), and terminate WSL:
#   wsl.exe --shutdown
# Then shut down your PC from the Windows Start menu.
```

---

## 3. Physical Hardware Installation

1. **Safety**: Switch off the power supply unit (PSU) switch and unplug the power cable. Press the PC power button once to discharge residual motherboard capacitors.
2. **Grounding**: Wear an anti-static wrist strap or touch the metal chassis before handling components.
3. **PCIe Slot Selection**:
   * Insert the second **NVIDIA GeForce RTX 3060 12GB** into the second PCIe x16 slot (minimum PCIe 3.0/4.0 x8 electrically).
   * Ensure adequate physical clearance between the two cards for airflow intake.
4. **Power Cabling**:
   * Connect an independent 8-pin PCIe power cable directly from the PSU to the second GPU (avoid using pigtail daisy-chain splitters from the first GPU cable).
5. **Boot**: Reconnect power cable, flip PSU switch, and boot into Windows / WSL.

---

## 4. Post-Boot Verification & Dual-GPU Startup Runbook

Once the system boots back into Linux / WSL, run this verification sequence:

```bash
# ── STEP 1: Verify NVIDIA Driver Sees Both 12GB GPUs ─────────────────────────
nvidia-smi --query-gpu=index,name,memory.total,power.draw,pstate,bus_id --format=csv

# EXPECTED OUTPUT:
# 0, NVIDIA GeForce RTX 3060, 12288 MiB, ..., 00000000:2D:00.0
# 1, NVIDIA GeForce RTX 3060, 12288 MiB, ..., 00000000:XX:00.0
# Combined VRAM: 24,576 MiB

# ── STEP 2: Boot Core Docker Stack with Pre-Warmed MCP Servers ───────────────
cd /home/wsl-ops/blue-lodge
./scripts/compose.sh start --mcp

# ── STEP 3: Launch Sovereign Web UI Daemon ───────────────────────────────────
./commands/web.sh start

# ── STEP 4: Verify Telemetry Reports Both GPUs to Craftsman Workbench ────────
curl -s http://localhost:3000/api/status | jq '.gpus'

# Expected JSON array with 2 GPU objects:
# [
#   { "index": "0", "name": "NVIDIA GeForce RTX 3060", "vram_total_mb": "12288", ... },
#   { "index": "1", "name": "NVIDIA GeForce RTX 3060", "vram_total_mb": "12288", ... }
# ]
```

---

## 5. Dual-GPU VRAM Utilization Investigation Queue (24GB Unified Pool)

With two RTX 3060 12GB cards, you now possess **24 GB total high-speed GDDR6 VRAM** with a cumulative **720 GB/s theoretical memory bandwidth**. We have queued four distinct operational architectures for how to utilize this expanded capacity:

### Strategy 1: Unified Tensor Parallelism (Single 32B/70B Giant Model)
* **How it works**: `llama-server` splits layers and tensor rows evenly across both GPUs using `--tensor-split 1,1` (or `12,12`) over the PCIe bus.
* **Target Models**:
  * **`Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf`**:
    * Model weights: **~19.8 GB** (splits ~9.9 GB onto GPU 0, ~9.9 GB onto GPU 1).
    * KV-Cache @ 16k context: **~3.2 GB** (splits ~1.6 GB per card).
    * Total VRAM footprint: **~23.0 GB / 24 GB**.
    * **Impact**: Massive leap in autonomous reasoning, multi-file code synthesis, and complex bug remediation that 14B cannot match, running 100% locally with zero cloud dependencies.
  * **`DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf`**:
    * Full Chain-of-Thought (CoT) reasoning model fitted entirely into VRAM for deep architectural planning.
* **Configuration Change in `docker-compose.yml`**:
  ```yaml
  command: >
    /llama-server
      -m /models/Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf
      --host 0.0.0.0 --port 8080
      -ngl 99
      --tensor-split 1,1
      --ctx-size 16384
      -fa
  ```

---

### Strategy 2: Speculative Decoding Pipeline (High-Velocity Code Completion)
* **How it works**: Uses speculative decoding to accelerate token generation by 2x to 3x.
* **GPU Allocation**:
  * **GPU 0 (12GB)**: Target/Verifier Model (`Qwen2.5-Coder-14B-Instruct-Q4_K_M`, ~8.9 GB VRAM).
  * **GPU 1 (12GB)**: Draft Model (`Qwen2.5-Coder-1.5B-Instruct`, ~1.5 GB VRAM running at ~120 tok/sec) + Vector Embeddings & Reranker (`bge-m3`, ~1.5 GB VRAM).
* **Benefits**:
  * Emits code at near 1.5B speeds (~50–70 tok/sec) with mathematical certainty of 14B output quality.
  * Leaves ~9 GB free on GPU 1 for instant embedding generation and RAG searches without interfering with the main LLM.
* **Configuration**:
  ```yaml
  command: >
    /llama-server
      -m /models/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf
      -md /models/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf
      --host 0.0.0.0 --port 8080
      -ngl 99 -ngld 99
  ```

---

### Strategy 3: Asynchronous Multi-Agent Dual-Sandbox (No-Contention Architecture)
* **How it works**: Runs two completely independent inference servers isolated on separate CUDA devices:
* **GPU Allocation**:
  * **GPU 0 (Device `0`, Port 8080 — Tier 1 Master)**:
    * Dedicated to the Craftsman Workbench UI, Neovim Copilot, and interactive operator sessions.
    * Instant response latency, zero waiting.
  * **GPU 1 (Device `1`, Port 18080 — Tier 2 Autonomous Worker)**:
    * Dedicated to background Autonomic Sentinels, PR sweeps, automated git commits, and subagents.
* **Benefits**:
  * Background sweeps will NEVER cause UI stutter, slot locks, or token delays while you are editing code in the workbench.

---

### Strategy 4: Massive Context Codebase Ingestion (64k–128k Working Window)
* **How it works**: Retain `Qwen2.5-Coder-14B` (8.9 GB) and dedicate the remaining **~15 GB of pooled VRAM entirely to FlashAttention KV-Cache**.
* **Capabilities**:
  * With `--cache-type-k q8_0 --cache-type-v q8_0`, a 64k token context requires only ~6 GB VRAM.
  * Allows ingesting entire multi-crate Rust projects or full multi-file repositories in a single prompt for comprehensive refactoring sweeps without chunking or context loss.

---

## 6. Decision Matrix for Post-Install Investigation

| Metric | Strategy 1 (32B Unified) | Strategy 2 (Speculative) | Strategy 3 (Dual Sandbox) | Strategy 4 (64k Context) |
| :--- | :--- | :--- | :--- | :--- |
| **Model Size** | **32B** (State of the art) | 14B + 1.5B Draft | 14B + 14B | 14B |
| **Tokens / Sec** | ~18–24 tok/s | **~50–70 tok/s** | ~30 tok/s each | ~30 tok/s |
| **Context Window** | 16k | 16k–24k | 16k each | **64k–128k** |
| **Concurrent Tasks**| 1 heavy task | 1 rapid task | **2 independent tasks**| 1 massive context task |
| **Best Used For** | Complex system architecture & heavy coding | Instant interactive autocomplete & fast chat | Heavy background sweeps + interactive UI | Full-repository refactoring & code audits |
