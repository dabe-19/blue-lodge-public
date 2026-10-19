# Blue Lodge: George, a Local-First Sovereign AI Agent Workstation

Blue Lodge is an autonomous, self-hosted agent workstation built around **George**, a sovereign coding, research, and systems operations companion. It runs entirely on hardware you own — from an Android smartphone running Termux to dual-GPU workstation towers, Proxmox hypervisors, and cloud servers.

George combines a high-reliability POSIX Bash core with an asynchronous Rust web cockpit (`george-web`), on-device PRISM CUDA/Vulkan inference, non-blocking FIFO IPC flow control, a formal Google Open Knowledge Graph (OKF), and an interconnected Obsidian-compatible wiki.

> [!IMPORTANT]
> **Zero Required Cloud Dependencies & Sovereign Architecture**:
> Blue Lodge ships **no fixed model list**. You download, verify, profile, and serve your own GGUF weights. The Model Workbench helps you inspect hardware fit, download models with cryptographic verification, manage LoRA adapters, and orchestrate training runs.

---

## Contents

- [What's in the Box](#whats-in-the-box)
- [System Architecture & Topology](#system-architecture--topology)
- [Requirements](#requirements)
- [Installation & First Run](#installation--first-run)
- [Model Workbench & Inference Fabric](#model-workbench--inference-fabric)
- [Instrument Rack & Telemetry](#instrument-rack--telemetry)
- [Using George (CLI & REPL)](#using-george-cli--repl)
- [Web UI & Craftsman Workbench](#web-ui--craftsman-workbench)
- [Open Knowledge Graph & Obsidian Wiki](#open-knowledge-graph--obsidian-wiki)
- [Background Systems & Autonomous Sweeps](#background-systems--autonomous-sweeps)
- [Integrations & Tool Bridges](#integrations--tool-bridges)
- [Security Model & Privacy Flags](#security-model--privacy-flags)
- [Testing & Quality Verification](#testing--quality-verification)
- [Documentation Index](#documentation-index)

---

## What's in the Box

| Subsystem | What It Does | Core Documentation |
| :--- | :--- | :--- |
| **Agent ReAct Loop** | Dual-loop honeydew milestone planner, ReAct step execution, AST tool routing, perturbation recovery, and wall-clock guards | [AGENT_LOOP](docs/AGENT_LOOP.md) · [REFLEXIVE](docs/REFLEXIVE.md) |
| **Model Workbench** | Local GGUF library manager, Hugging Face quant fit tables, sha256-verified downloads, serving presets, LoRA adapters | [MODELS](docs/MODELS.md) · [TUNING](docs/TUNING.md) |
| **Instrument Rack** | Real-time fabric topology inspector: probes Docker control containers, remote CUDA nodes, slot occupancy, ping latency, and role coverage | [INSTRUMENT_RACK](docs/INSTRUMENT_RACK.md) |
| **Craftsman Workbench** | In-browser IDE with 88-column layout floor, zero-latency Vim engine, dual-pane splitting, and George Co-Pilot steering drawer | [CRAFTSMAN_WORKBENCH](docs/CRAFTSMAN_WORKBENCH.md) |
| **Open Knowledge Graph (OKF)** | Google OKF JSON-LD graph with 520+ semantic nodes indexing modules, standards, and wiki docs; CLI search, query, and validation | [OKF_KNOWLEDGE_GRAPH](docs/OKF_KNOWLEDGE_GRAPH.md) |
| **Obsidian Linked Wiki** | 70+ interconnected markdown files with YAML frontmatter, bidirectional wikilinks, and master Map of Content (`INDEX.md`) | [INDEX](docs/INDEX.md) · [ARCHITECTURE_INDEX](docs/ARCHITECTURE_INDEX.md) |
| **FIFO IPC Flow Control** | Kernel-backed POSIX named pipes (v3), sliding-window flow control, keeper processes, atomic locks, and AWK garbage collection | [FIFO_ASYNC_IPC_FLOWCONTROL](docs/FIFO_ASYNC_IPC_FLOWCONTROL.md) |
| **Dataset Forge & Training** | Synthetic recipe-based SFT/DPO corpus generator, token budget accounting, and multi-track local/Colab distillation manager | [DATASET_FORGE](docs/DATASET_FORGE.md) · [TRAINING_RUN_MANAGER](docs/TRAINING_RUN_MANAGER.md) |
| **Research Verifier** | Gate 1 citation verification against Phase-1 evidence ledgers, Crossref fallback resolver, and claim quarantine | [RESEARCH_VERIFIER](docs/RESEARCH_VERIFIER.md) |
| **Discord Bridge** | Multi-turn conversational delivery in-channel, message editing (`discord_edit`), outbox de-duplication, and steering injection | [DISCORD_BRIDGE](docs/DISCORD_BRIDGE.md) |
| **SearXNG Metasearch** | Private 70+ engine metasearch Docker container, MCP stdio server, and fallback cascade (SearXNG → Brave → Serper → DDG) | [SEARXNG_METASEARCH](docs/SEARXNG_METASEARCH.md) |
| **Safety & Privacy** | Centralized operator flags (`data/feature_flags.json`), `/flags` command, and `/forget` protocol for memory scrubbing | [SAFETY_AND_PRIVACY](docs/SAFETY_AND_PRIVACY.md) |
| **Gitea Intake & PRs** | Local forge issue tracker, automated PR reviews, close-to-cancel handling, and continuous test verification | [OPERATOR_GITEA_INTAKE](docs/OPERATOR_GITEA_INTAKE.md) |
| **Encrypted Crypto Keystore** | Multi-chain AES-256-GCM + scrypt keystore (`agent-hot`, `agent-evm`), ISO/IEC 18004 QR codes, payment URIs, and Tier B policy-gated sends | [CRYPTO_WALLETS](docs/CRYPTO_WALLETS.md) |
| **Sovereign Trading** | Autonomous Cardano AMM arbitrage snipers, Unified Order Manager (UCOM), P2P lending underwriting, and Polymarket negative-risk settlement | [SOVEREIGN_DEX_AND_LENDING_GUIDE](docs/SOVEREIGN_DEX_AND_LENDING_GUIDE.md) |
| **Sovereign P25 SDR Lab** | Turnkey Trunk-Recorder P25 scanner decode, Voxtral-Mini-4B LoRA ASR transcription, SQLite/MQTT pipeline, and multimodal `.m4a` analysis (`sdr_query`, `sdr_listen`) | [SDR_LAB_OPERATOR_AND_USER_GUIDE](docs/SDR_LAB_OPERATOR_AND_USER_GUIDE.md) |

---

## System Architecture & Topology

```
                     ┌───────────────────────────────────────────────┐
                     │          OPERATOR INTERFACES                  │
                     │  CLI / REPL (lodge)  ·  Web UI (:3000)        │
                     │  Discord Bot Bridge  ·  Obsidian Wiki Hub     │
                     └──────────────────────┬────────────────────────┘
                                            │
                     ┌──────────────────────▼────────────────────────┐
                     │       GEORGE AUTONOMOUS REASONING CORE        │
                     │  Honeydew Planner  ·  ReAct Loop  ·  Reflexive│
                     │  Context Engine    ·  Three-Tier Memory Store │
                     │  Google Open Knowledge Graph (OKF) AST Engine │
                     └───────┬───────────────────────────────┬───────┘
                             │                               │
       ┌─────────────────────▼─────────────┐   ┌─────────────▼─────────────────────┐
       │   ASYNCHRONOUS FIFO IPC v3        │   │    CONTROL & COMPUTE RACK         │
       │   Named Pipes · Sliding Flow Ctrl │   │    /api/rack Topology Probes      │
       │   Event Bus · OSINT Reactors      │   │    Local Docker Containers:       │
       └───────────────────────────────────┘   │     · george-prism-server (:8080) │
                                               │     · george-searxng (:8081)      │
                                               │     · george-gitea (:3001)        │
                                               │     · george-mosquitto (:1883)    │
                                               │     · george-act-runner (CI)      │
                                               │    Remote / Optional Nodes:       │
                                               │     · cuda-dual-rtx3060-frontier  │
                                               │     · sdr-lab (Trunk-Recorder/ASR)│
                                               └───────────────────────────────────┘
```

---

## Requirements

| Component | Minimum Specification | Recommended Production Setup |
| :--- | :--- | :--- |
| **Host OS** | Linux (Ubuntu/Debian, WSL2), Android Termux, ChromeOS | Dedicated Linux Workstation or Proxmox VE VM with Docker |
| **Core Utilities** | Bash 4.4+, `curl`, `jq`, `sqlite3`, Python 3.10+ | + `git`, `docker`, `docker compose`, `tree-sitter-cli` |
| **Inference** | Local llama-server or OpenAI-compatible endpoint | NVIDIA RTX 3060/4090 (CUDA), Apple Silicon (Metal), or Qualcomm Adreno (Vulkan) |
| **Web Cockpit** | Standalone pre-compiled release binary | Rust toolchain (`cargo`) for compiling `web/` |

Platform setup guides:
- [Phone / Android Termux](docs/PHONE_SETUP.md)
- [Debian / ChromeOS Crostini](docs/DEBIAN_CHROMEOS_SETUP.md)
- [iOS / macOS Local & Remote](docs/IOS_MACOS_SETUP.md)
- [Proxmox GPU Passthrough](docs/PROXMOX_GPU_SETUP.md)
- [Adreno GPU Vulkan Acceleration](docs/ADRENO_GPU_SETUP.md)

---

## Installation & First Run

1. **Clone, initialize local secrets/wallets, and run the bootstrap installer**:
   ```bash
   git clone https://github.com/dabe-19/blue-lodge-public.git ~/blue-lodge
   cd ~/blue-lodge
   bash scripts/infra/init_secrets.sh
   bash install.sh
   source ~/.bashrc
   ```

2. **Launch Docker infrastructure services**:
   ```bash
   # Core containers: SearXNG metasearch, Mosquitto MQTT, and PRISM inference
   docker compose up -d

   # Optional Forge profile: Local Gitea git server and act-runner CI worker
   docker compose --profile forge up -d

   # Optional P25 SDR Radio Lab: Trunk-Recorder + MQTT publisher + retention GC
   docker compose -f deploy/sdr-lab/docker-compose.yml up -d
   ```

3. **Build and launch the Web Cockpit**:
   ```bash
   cd ~/blue-lodge/web && cargo build --release
   ./target/release/george-web  # Accessible at http://127.0.0.1:3000
   ```

   To maintain continuous background service, install as a systemd user unit:
   ```bash
   systemctl --user daemon-reload && systemctl --user enable --now george-web
   ```

---

## Model Workbench & Inference Fabric

Blue Lodge adopts a **model-agnostic philosophy**. You select the GGUF models that match your hardware:

```bash
lodge /models hw                                  # Inspect CPU, RAM, and GPU VRAM capacity
lodge /models                                     # List existing GGUF models in ~/models
lodge /models search "qwen coder gguf"            # Search Hugging Face model repository
lodge /models quants huggingface <repo> --ctx 32k # Generate hardware fit table for each quant
lodge /models draft huggingface <repo> Q4_K_M     # Create verified profile
lodge /models approve <profile>                   # Cryptographically bind approval to SHA256
lodge /models install <profile>                   # Resumable, verified parallel download
lodge /models activate <profile>                  # Hot-swap live llama-server instance
lodge /models status                              # Inspect active model and context limits
```

For advanced multi-node or remote inference clusters, consult the [Inference Fabric Guide](docs/INFERENCE_FABRIC.md) and [Model Expansion Playbook](docs/BLUE_LODGE_MODEL_EXPANSION_PLAYBOOK.md).

---

## Instrument Rack & Telemetry

The **Instrument Rack** provides a unified snapshot of your entire sovereign cluster:
- **CLI Inspection**: Run `lodge /backend rack` or `/status` to view active nodes, container health, ping latencies, and role coverage.
- **REST Endpoint**: Query `http://127.0.0.1:3000/api/rack` for JSON telemetry consumed by dashboards and monitoring scripts.
- **Web UI Drawer**: Click the **RACK** pill in the top navigation bar to inspect real-time slot occupancy, GPU temperatures, and container state.

See the complete guide in [INSTRUMENT_RACK.md](docs/INSTRUMENT_RACK.md).

---

## Using George (CLI & REPL)

Start an interactive session or run one-shot tasks directly from your shell:

```bash
lodge                                   # Start interactive REPL with full history and auto-complete
lodge "Implement unit tests for auth"   # Autonomous task execution in current workspace
lodge /q "Explain POSIX named pipes"    # Fast direct question with conversation memory
lodge /plan "Refactor database engine"  # Generate multi-milestone honeydew plan without execution
lodge /init myproject rust              # Scaffold a new sandboxed project workspace
lodge /help                             # Comprehensive command catalog
```

### Essential Slash Commands

| Command | Args | Description | Subsystem Reference |
| :--- | :--- | :--- | :--- |
| `/backend rack` | — | Inspect live Instrument Rack topology and compute nodes | [INSTRUMENT_RACK](docs/INSTRUMENT_RACK.md) |
| `/models` | `[library\|search\|install\|activate]` | Model Workbench management | [MODELS](docs/MODELS.md) |
| `/flags` | `[get\|set\|list]` | Operator safety and privacy feature flags | [SAFETY_AND_PRIVACY](docs/SAFETY_AND_PRIVACY.md) |
| `/forget` | `<target>` | Targeted memory expungement and privacy scrubbing | [SAFETY_AND_PRIVACY](docs/SAFETY_AND_PRIVACY.md) |
| `/train` | `[job\|start\|status\|logs]` | Distillation run manager and GGUF quantization | [TRAINING_RUN_MANAGER](docs/TRAINING_RUN_MANAGER.md) |
| `/forge` | `[dataset\|build\|inspect]` | Synthetic corpus generator from transcripts | [DATASET_FORGE](docs/DATASET_FORGE.md) |
| `/searxng` | `[search\|query\|test]` | Local 70+ engine private metasearch | [SEARXNG_METASEARCH](docs/SEARXNG_METASEARCH.md) |
| `/okf` | `[search\|query\|tree\|validate]` | Google Open Knowledge Graph explorer | [OKF_KNOWLEDGE_GRAPH](docs/OKF_KNOWLEDGE_GRAPH.md) |
| `/wallet` | `[status\|receive\|send\|keystore\|tax]` | Encrypted multi-chain keystore, QR receive & policy-gated send | [CRYPTO_WALLETS](docs/CRYPTO_WALLETS.md) |
| `/trading` | `[status\|review\|scan\|plan\|confirm\|order]` | Cardano DEX flash-spreads, UCOM orders & P2P lending | [SOVEREIGN_DEX_AND_LENDING_GUIDE](docs/SOVEREIGN_DEX_AND_LENDING_GUIDE.md) |
| `/slash` | `[create\|test\|list]` | Author custom self-extending bash commands | [SLASH_EXTENSIONS](docs/SLASH_EXTENSIONS.md) |

Full command guide: [SLASH_COMMANDS.md](docs/SLASH_COMMANDS.md).

---

## Web UI & Craftsman Workbench

The `george-web` service runs on port `3000` and offers a dual-cockpit experience:
1. **Craftsman Workbench (`[[CRAFTSMAN_WORKBENCH]]`)**:
   - In-browser code editor with strict **88-column minimum layout floor**.
   - Zero-latency native JavaScript Vim engine (`NORMAL`, `INSERT`, ex-commands `:w`, `:q!`, `:bd`, `cs/ds/ysiw` surround).
   - Side-by-side dual-pane code tiling (`[ ◫ SPLIT ]`) with asymmetric resizing.
   - Integrated George Co-Pilot drawer for continuous guided refactorings with streaming diffs.
2. **Model Workbench Modal**:
   - Live browsing of local models, quant fit calculations, and one-click activations.
3. **Sovereign Trading & Wallet Desk**:
   - Live portfolio telemetry, **RECEIVE** QR code / payment URI generator (`GET /api/wallet/receive`), **SEND** Tier B transaction staging (`POST /api/wallet/send`), and resting order management.
4. **Autonomic Task Bay**:
   - Multi-task execution tracker streaming real-time Server-Sent Events (SSE) from the ReAct loop.

---

## Open Knowledge Graph & Obsidian Wiki

All documentation in `docs/` is structured as an **interconnected Obsidian wiki**:
- **YAML Frontmatter**: Every document contains standardized metadata (`title`, `description`, `subsystem`, `tags`, `okf_id`, `related`).
- **Native Wikilinks**: Documents interconnect using `[[DocName]]` syntax, enabling dynamic graph visualization, backlinks, and hover previews in Obsidian.
- **Master Map of Content**: Open [docs/INDEX.md](docs/INDEX.md) as your navigation center.
- **Machine-Readable Graph**: The repository is represented by `okf/blue_lodge_graph.jsonld` (520+ semantic nodes). Use `./bin/okf search <query>` to search across code modules, architectural standards, and wiki articles.

---

## Background Systems & Autonomous Sweeps

| System | Management | Operational Invariant |
| :--- | :--- | :--- |
| **Cron Daemon** | `/cron status\|start\|stop\|logs` | Manages scheduled sweeps (sentinel, PR intake, Discord polling, disk vitals). |
| **Sentinel Watchdog** | Automated cron sweep | Monitors inference socket health, GPU temperature, and deadlocks. Stalled tasks are flagged after 7 min and reaped after 15 min. |
| **Phytology Self-Healing** | `/agents/phytology.sh` | Living tissue autonomous healing: detects syntax degradation, audits diffs, and rolls back regressions. |
| **Failure Remediation Queue** | `/remediation queue\|run\|sweep` | Failing test suites or pull requests undergo bounded automated recovery attempts before escalating to the operator. |
| **Event Bus & OSINT** | `/events`, `/ipc status\|gc` | Sub-millisecond FIFO event dispatching with sliding-window credit flow control. |

---

## Integrations & Tool Bridges

All integrations are strictly opt-in and remain dormant until credentials are provided via the encrypted secrets vault:
- **Cloud AI Providers**: Fallback routing to Anthropic Claude 3.7, Google Gemini 2.0 Flash, OpenAI, Groq, or DeepSeek ([PROVIDERS.md](docs/PROVIDERS.md)).
- **Discord Bot Bridge**: Bidirectional in-channel assistant with message editing and steering ([DISCORD_BRIDGE.md](docs/DISCORD_BRIDGE.md)).
- **Email & Communications**: IMAP/SMTP notifications, disposable inboxes, and Termux SMS ([EMAIL_GITHUB.md](docs/EMAIL_GITHUB.md), [PHONE_INTEGRATION.md](docs/PHONE_INTEGRATION.md)).
- **Encrypted Crypto Wallets & DEX**: Multi-chain AES-256-GCM keystore (`agent-hot`, `agent-evm`), QR receive/send, Cardano AMM flash-spread snipers, P2P loans, and Polymarket risk arbitrage ([CRYPTO_WALLETS.md](docs/CRYPTO_WALLETS.md), [SOVEREIGN_DEX_AND_LENDING_GUIDE.md](docs/SOVEREIGN_DEX_AND_LENDING_GUIDE.md)).
- **Sovereign P25 SDR Radio Lab**: Trunk-Recorder P25 decode, Voxtral-Mini-4B LoRA ASR transcription, SQLite + MQTT event bus, and multimodal `.m4a` scanner queries (`sdr_query`, `sdr_listen`) ([SDR_LAB_OPERATOR_AND_USER_GUIDE.md](docs/SDR_LAB_OPERATOR_AND_USER_GUIDE.md)).
- **Model Context Protocol (MCP)**: JSON-RPC client connecting George to stdio tools ([MCP.md](docs/MCP.md)).

---

## Security Model & Privacy Flags

- **Localhost by Default**: All network services bind to `127.0.0.1`. Remote access requires explicit pairing tokens.
- **Sandboxed Execution**: Agent-executed code runs inside isolated proot, user-namespace, or Docker CUDA containers.
- **Encrypted Keystores & Untracked Vault**: All signing keys reside in `.george/wallets/keystore/*.json` (AES-256-GCM + scrypt) with auto-unlock via `.george/secrets/agent_keystore.key` (`0600`). Outgoing transfers require explicit Tier B confirmation (`confirm P-XXXXXX`) and enforce `floor_ada` reserve protection.
- **Feature Flags**: Operator flags in `data/feature_flags.json` govern memory retention, automated transactions, and network outreach.
- **Targeted Privacy Scrubbing**: The `/forget` protocol permanently expunges sensitive memories, preferences, and transcript traces.
- Review [SECURITY.md](SECURITY.md), [CRYPTO_WALLETS.md](docs/CRYPTO_WALLETS.md), and [SAFETY_AND_PRIVACY.md](docs/SAFETY_AND_PRIVACY.md).

---

## Testing & Quality Verification

Blue Lodge is rigorously tested with over **138 automated test suites**:

```bash
bash tests/run_all.sh                 # Run full Bash test suite
bash tests/run_all.sh -v              # Verbose mode with step-by-step assertions
bash tests/run_all.sh test_model_hub  # Test specific subsystem
cd web && cargo test --release        # Run Rust Axum web tests
./bin/okf validate                    # Validate Google OKF semantic knowledge graph
./bin/lodge-lint                      # Run codebase syntax and style linter
```

---

## Documentation Index

Explore the complete architecture through our documentation hubs:
- **[Master Map of Content (INDEX.md)](docs/INDEX.md)** — Master Obsidian navigation hub connecting all technical documents.
- **[Architecture Index & Component Directory](docs/ARCHITECTURE_INDEX.md)** — Component-to-file mappings and recommended reading sequences.
- **[Sovereign Architecture Guide](docs/ARCHITECTURE.md)** — Architectural invariants, security perimeters, and lifecycle contracts.
- **[Crypto Wallets & Keystore Guide](docs/CRYPTO_WALLETS.md)** — Encrypted multi-chain keystore, QR receive/send, and Tier A/B/C policy gates.
- **[P25 SDR Radio Lab Operator & User Guide](docs/SDR_LAB_OPERATOR_AND_USER_GUIDE.md)** — Trunk-Recorder + Voxtral ASR container deployment and Discord scanner tools.
- **[George Reference Manual](docs/GEORGE_REFERENCE.md)** — Personality, moral sentiments, and working tools of the Craft.

---

## License

MIT License. Designed and maintained with sovereign craftsmanship.
