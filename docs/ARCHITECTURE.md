# Blue Lodge Sovereign Architecture Guide

> **System Blueprint & Technical Specification**  
> **Classification**: Sovereign Local AI Infrastructure  
> **Last Updated**: September 2026

---

## 1. Executive System Overview

Blue Lodge is an autonomous, local-first sovereign development and agentic computing platform named **George**. Combining a robust Bash-native core with a zero-latency Rust Axum web sidecar, an on-device CUDA PRISM inference fabric, and local Git/CI automation, Blue Lodge operates entirely on self-hosted hardware without mandatory external cloud dependencies.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                               OPERATOR WORKSPACE (Host / Browser)                       │
│                                                                                        │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │                      Sovereign Craftsman Web Interface (Port 3000)             │   │
│   │   • Craftsman 88-Column Code Workbench      • George Co-Pilot REPL             │   │
│   │   • Autonomic Task Bay (Steer/Pause/Kill)   • Dual-Pane Split Tiling           │   │
│   │   • Neovim PTY Terminal Integration         • Ported Vim Command Engine        │   │
│   └───────────────────────────────────────┬────────────────────────────────────────┘   │
└───────────────────────────────────────────┼────────────────────────────────────────────┘
                                            │ HTTP / SSE / WebSocket
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                              BLUE LODGE LOCAL SERVICES                                  │
│                                                                                        │
│   ┌────────────────────────┐  ┌─────────────────────────┐  ┌────────────────────────┐  │
│   │   george-web (Rust)    │  │   PRISM Inference       │  │   Local Git & CI/CD    │  │
│   │   Axum Web Sidecar     │  │   llama-server (Port 8080│  │   Gitea (Port 3088/2222)│  │
│   │   Port: 3000           │  │   CUDA (RTX 3060 12GB)  │  │   Act-Runner (Docker)   │  │
│   │   Binary: web/target/  │  │   Model: Ternary Bonsai │  │   Data: .gitea-data/    │  │
│   └───────────┬────────────┘  └───────────┬─────────────┘  └───────────┬────────────┘  │
│               │                           │                            │               │
│               └───────────────────────────┼────────────────────────────┘               │
│                                           │                                            │
│                                           ▼                                            │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │                     CORE ENGINE: LODGE (Bash & Python)                         │   │
│   │   • ReAct Reasoning Engine (lib/react.sh, lib/agent.sh)                        │   │
│   │   • Context & Memory Stack (lib/context_engine.sh, GEORGE.md, SQLite FTS5)     │   │
│   │   • Fusion MCP Multi-Tool Bridge (lib/mcp_server_fusion.py)                    │   │
│   │   • Autonomic Cron Sentinel (.george/cron_jobs/, lib/cron.sh)                  │   │
│   │   • Ephemeral Sandboxes & Isolation (.sandboxes/copilot_*, .sandboxes/task_*)  │   │
│   └────────────────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Service Inventory & Port Mappings

| Service Name | Technology / Container | Port(s) | Description |
| :--- | :--- | :--- | :--- |
| **Sovereign Web Sidecar** (`george-web`) | Rust (Axum, Tokio, Tower) | `3000` (HTTP/WS) | Primary operator cockpit, Craftsman Workbench, file APIs, task trajectory streaming, PTY runner. |
| **PRISM Primary Inference** (`george-prism-server`) | Docker (`george-cuda-sandbox` / `llama-server`) | `8080` (HTTP) | Tier 1 local CUDA LLM reasoning (`Ternary-Bonsai-2-27B-PTQ1_0.gguf`). |
| **PRISM Secondary Inference** | ROCm / AMD Vulkan (optional) | `18080` (HTTP) | Tier 2 secondary local inference server for speculative decoding or worker tasks. |
| **Ollama Fallback** | Native Linux Binary / Systemd | `11434` (HTTP) | Tier 0 local model fallback (e.g. `llama3.2`, `qwen2.5-coder`). |
| **Local Git Forge** (`george-gitea`) | Docker (`gitea/gitea:latest`) | `3088` (HTTP), `2222` (SSH) | Fully self-hosted code repository, pull request gateway, and webhook coordinator. |
| **Act Runner** (`george-act-runner`) | Docker (`gitea/act_runner:latest`) | Stdio / Unix Socket | Automated CI/CD runner executing tests, lint checks, and security scans on push. |
| **Fusion MCP Server** | Python 3 (`lib/mcp_server_fusion.py`) | Stdio (JSON-RPC) | Unified Model Context Protocol server exposing filesystem, ripgrep, memory, and bash tools. |

---

## 3. Directory Topology & Workspace Layout

```
blue-lodge/
├── .act-runner-data/      # Persistent runner daemon state and workdirs
├── .agents/              # Antigravity IDE custom skills, workflows, and rules
├── .george/              # George project state, cron jobs, and memory stores
│   ├── cron_jobs/        # Autonomic cron tasks (e.g. research_publisher.sh)
│   ├── memory.db         # SQLite FTS5 vector & keyword recall database
│   └── journal.md        # Cryptographically signed immutable development ledger
├── .gitea-data/          # Persistent Gitea database, git repositories, and SSH keys
├── .sandboxes/           # Ephemeral runtime directories for executing tasks & copilot jobs
│   └── copilot_<file>_<ts>/ # Dedicated sandbox per refactoring job with PID, trajectory, and abort flags
├── bin/                  # CLI launcher scripts (lodge symlinks)
├── commands/             # Slash command dispatch handlers (e.g. web.sh, status.sh, mcp.sh)
├── docs/                 # Architectural specifications, manuals, and design runbooks
├── lib/                  # Core bash utility modules (ui.sh, agent.sh, react.sh, context_engine.sh)
├── models/               # Host models directory symlink (pointing to /home/wsl-ops/models)
├── web/                  # Rust Axum Web Sidecar source code
│   ├── src/main.rs       # Axum router, REST API handlers, SSE streaming, and process manager
│   ├── static/           # Frontend assets (index.html, app.css, app.js, xterm.js)
│   └── target/release/   # Compiled high-performance native web server binary
├── docker-compose.yml    # Unified multi-container deployment manifest (--no-build default)
├── Dockerfile.cuda-sandbox # Multi-layered CUDA builder for llama.cpp & prism
├── GEORGE.md             # Living sovereign constitution, milestones, and memory anchor
└── lodge                 # Primary command-line entrypoint executable
```

---

## 4. Sandbox Isolation & Autonomic Steering

Every task initiated through the Craftsman Co-Pilot or background autonomic triggers runs inside a segregated sandbox located under `.sandboxes/`:

1. **Directory Lifecycle**:
   - Directory created at `.sandboxes/copilot_<file_slug>_<timestamp>/`.
   - Sandbox metadata written to `task_meta.json`.
   - Process PID written to `.pid`.
   - Live internal monologue and tokens streamed to `trajectory.log`.
2. **Operator Steering & Controls**:
   - **`INJECT`**: Writes guidance tokens to `.steer` or streams directly into stdin.
   - **`PAUSE`**: Sends `SIGSTOP` to the task process tree and sets `.phase` to `paused`.
   - **`RESUME`**: Sends `SIGCONT` to the task process tree and sets `.phase` to `active`.
   - **`TERMINATE`**: Writes `.abort` flag, issues `SIGTERM` / `SIGKILL` to the process tree, and triggers immediate cleanup.
3. **Retention Policy**:
   - Active sandboxes are registered in `/api/tasks`.
   - Completed or aborted sandboxes remain in the Autonomic Task Bay for 45 seconds for operator inspection before being swept.

---

## 5. Inference Architecture & Dual-GPU Target

### Current Single-GPU Baseline (RTX 3060 12GB)
- **VRAM Capacity**: 12,288 MiB.
- **Model**: `Ternary-Bonsai-2-27B-PTQ1_0.gguf` (~9.8 GB footprint).
- **Execution**: 100% offloaded to GPU (`-ngl 99`), leaving ~2.4GB VRAM for KV-cache (8,192 context window).

### Scaled Dual-GPU Topology (2x RTX 3060 12GB = 24GB Total VRAM)
- **Topology 1 (Unified Tensor Split)**:
  `llama-server -m /models/Ternary-Bonsai-2-27B-PTQ1_0.gguf --tensor-split 12,12 -c 32768`
  Expands KV-cache to 32,768 tokens while distributing compute across both GPUs.
- **Topology 2 (Dual Independent Fabric)**:
  - **GPU 0 (Port 8080)**: Master Reasoning Agent (`Ternary-Bonsai-27B`).
  - **GPU 1 (Port 18080)**: High-speed Worker / Speculative Draft (`Qwen2.5-Coder-7B`).

---

## 6. Security Boundaries & Verification Gates

1. **Network Boundary**: Web UI, PRISM server, and Gitea bind strictly to loopback (`127.0.0.1`) or local private network interfaces (`0.0.0.0` inside private LAN). No ports are exposed publicly without an authenticated WireGuard or Tailscale tunnel.
2. **Syntax Validation Gates**: All code modified in Craftsman Workbench is validated via `bash -n` or language-specific linters before writing to disk.
3. **Model Weight Decoupling**: Docker containers mount `/models` strictly as read-only volumes (`:ro`). Model weights are never committed to image layers or repository git history.
