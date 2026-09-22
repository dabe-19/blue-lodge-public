# Blue Lodge Sovereign Infrastructure: Maintenance Roadmap & Dual-GPU Runbook

**Current Status**: Code Editor Complete & Operational  
**Objective**: Pause feature development to execute infrastructure stabilization, documentation overhaul, legacy culling, container layering, and prepare for installing the second 12GB NVIDIA RTX 3060 GPU.

---

## 1. Maintenance Task Queue (Execution Order)

### Phase 1: Documentation Overhaul (`*.md`)
- [ ] **System Architecture Master Guide** (`docs/ARCHITECTURE.md`):
  - Document all current services: Sovereign Web Sidecar (`george-web`), PRISM Inference Server (`llama-server`), Gitea Git Forge, Act Runner CI/CD, Discord Bridge, and Autonomic Sentinel.
  - Document network topology: Ports 3000 (UI/API), 8080 (Primary Tier 1 CUDA), 18080 (Tier 2 ROCm), 11434 (Tier 0 Ollama), 2222 (Gitea SSH), 3088 (Gitea HTTP).
  - Document directory structures: `.sandboxes/`, `.george/`, `commands/`, `lib/`, `web/`.
- [ ] **Craftsman Workbench & Co-Pilot Manual** (`docs/CRAFTSMAN_WORKBENCH.md`):
  - Document the 88-column layout rules and auto-expanding geometry.
  - Document Dual-Pane side-by-side tiling (`[ ◫ SPLIT ]`).
  - Document Autonomic Task Bay integration, live monologue streaming, and operator steering controls (`INJECT`, `PAUSE`, `RESUME`, `TERMINATE`).
  - Document Neovim PTY integration vs. zero-latency Craftsman buffer.
- [ ] **GEORGE.md Ledger & Operational Handbook**:
  - Update milestone markers, active agent capabilities, and command dispatch cheatsheet.

---

### Phase 2: Legacy Code Culling & Refactoring
- [ ] **Purge Specialist/Strategist Loop Obsoletes**:
  - Audit and refactor obsolete workflow loops from early agent implementations (`docs/archive/legacy_agent.sh`, orphaned specialist scripts).
  - Ensure zero references remain in active dispatchers (`commands/*.sh`, `lib/agent.sh`).
- [ ] **Clean and Consolidate Utility Libraries**:
  - Review `lib/` modules (`lib/popup.sh`, `lib/react.sh`, `lib/research_graph.sh`) to eliminate duplicate helpers.
  - Verify all test suites (`tests/test_*.sh`) run green against the cleaned codebase.

---

### Phase 3: Intelligently Layered Dockerfiles & Docker Compose
- [ ] **Persistent Model Volume Decoupling**:
  - Ensure model weights (`/models/*.gguf`) are mounted from host storage (`/models` or `${LODGE_DIR}/models`) into containers as external persistent volumes.
  - Containers must NEVER embed multi-gigabyte GGUF weights in image layers.
- [ ] **Intelligently Layered Dockerfiles**:
  - **Base Layer**: Ubuntu CUDA runtime, core compilers, build tools (changes rarely).
  - **Dependency Layer**: Python/pip, CMake, llama.cpp binary builds (changes on version bumps).
  - **Application Layer**: Sidecar binaries and scripts (rebuilds in < 3 seconds).
- [ ] **Unified `docker-compose.yml`**:
  - Define all services with persistent volumes and health checks:
    - `prism-inference` (CUDA `llama-server` on RTX 3060)
    - `george-web` (Rust Axum Sovereign Craftsman Engine)
    - `george-gitea` & `george-act-runner`
  - Default execution mode: `--no-build` by default so running `docker compose up -d` uses existing cached containers without unnecessary recompiles or network pulls unless `--build` is explicitly flagged.

---

## 2. Hardware Upgrade Runbook: 2nd RTX 3060 12GB Installation

### Graceful Pre-Shutdown Procedure (Run before powering off host)
```bash
# 1. Stop active autonomic cron and sweeps
curl -s -X POST http://localhost:3000/api/cron/daemon/stop

# 2. Terminate background Web sidecar
pkill -f "george-web"

# 3. Stop Docker containers cleanly (flushing database & runner state)
docker stop george-prism-server george-act-runner george-gitea

# 4. Verify all GPU processes have exited
nvidia-smi

# 5. Flush filesystem buffers and sync
sync
```

### Hardware Installation
1. Power down computer, switch off PSU, unplug power cable.
2. Ground yourself and install the second **NVIDIA GeForce RTX 3060 12GB** into PCIe slot 2.
3. Connect dedicated 8-pin PCIe power cables (avoid daisy-chaining if possible).
4. Power on system and boot into Linux/WSL.

### Post-Install Verification & Dual-GPU Startup
```bash
# 1. Verify both GPUs are recognized by NVIDIA driver
nvidia-smi --query-gpu=index,name,memory.total,power.draw,pstate --format=csv

# Expected output:
# 0, NVIDIA GeForce RTX 3060, 12288 MiB, ...
# 1, NVIDIA GeForce RTX 3060, 12288 MiB, ...

# 2. Bring up core containers
docker start george-gitea george-act-runner george-prism-server

# 3. Launch George Web Engine
/home/wsl-ops/blue-lodge/web/target/release/george-web &

# 4. Verify telemetry detects GPU 0 and GPU 1
curl -s http://localhost:3000/api/status | jq '.gpus'
```

### Dual-GPU Scaling Opportunities (Next Milestone)
- **Option A (Tensor Split)**: Run `llama-server --tensor-split 12,12` to pool 24GB total VRAM, enabling 70B quantized models or massive 64k context windows on Tier 1.
- **Option B (Independent Speculative/Worker)**:
  - GPU 0 (12GB): Primary reasoning engine (`ternary-bonsai-27b`).
  - GPU 1 (12GB): Dedicated drafting engine, embedding server, or isolated sandbox worker.
