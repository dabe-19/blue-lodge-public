# GEORGE — Blue Lodge Sovereign Architecture

## Project
name: blue-lodge (workspace)
type: Sovereign Autonomous Agentic Workspace & Operating System
version: 2026.10.18
license: Private Craftsman Sovereign

## Build & Test Gates
build: cargo build --release (web/), python3 okf/generate_okf_graph.py
lint: ./bin/lodge-lint
test: bash tests/run_all.sh
validate: ./bin/okf validate

## Agent Capabilities & Slash Commands
- **Knowledge & Standards:** `/okf` (search, query, standards, tree, validate), `/recall`, `/journal`
- **Execution & File Operations:** `/write`, `/edit`, `/append`, `/save`, `/read`, `/ls`, `/bash`, `/sh`
- **Scaffolding & Architecture:** `/scaffold` (module, ipc, tool), `bin/lodge-lint`
- **Build, Test & CI:** `/build`, `/test`, `/fix`, `/commit`, `/push`, `/clone`, `/git`, `/gitea`, `/pr`
- **Agent Governance & Swarm:** `/architect`, `/dispatcher`, `/status`, `/subagents`, `/swarm`, `/task_sync`, `/rules`, `/skill`, `/workflow`
- **Sovereign Infrastructure & Models:** `/models`, `/train`, `/inference`, `/service`, `/container`, `/sandbox`, `/vitals`, `/limits`
- **Living Tissue & Telemetry:** `/phytology`, `/remediation`, `/telemetry`, `/ipc`, `/cron`
- **Sovereign Treasury & Crypto:** `/wallet` (status, receive, send, keystore, portfolio, ledger, tax), `/trading` (status, review, scan, plan, confirm, order, floor, audit)
- **External Comms, SDR & Media:** `/web`, `/searxng` (query, code, science, news, images, rss, engines, status, restart), `/api` (search, keyless, category, categories, info, sync), `/social`, `/email`, `/phone`, `/vision`, `/pdf`, `/download`, `sdr_query`, `sdr_listen`

## Workspace Layout (OKF Structured)
```
$LODGE_DIR/
├── okf/                           # Google Open Knowledge Graph root
│   ├── blue_lodge_graph.jsonld    # Master semantic graph (78+ entities, Schema.org JSON-LD)
│   ├── generate_okf_graph.py      # Automated OKF graph generator
│   └── standards/                 # Formal architectural standards (OKF JSON-LD)
│       ├── okf_directory_standard.jsonld
│       ├── fifo_async_ipc_protocol.jsonld
│       ├── subagent_sandbox_lifecycle.jsonld
│       ├── telemetry_closed_loop_remediation.jsonld
│       └── sovereign_inference_switching.jsonld
├── okf.jsonld -> okf/blue_lodge_graph.jsonld  # Root semantic discovery symlink
├── lib/                           # Domain-partitioned library modules (with backward-compat symlinks)
│   ├── core/                      # Agent loops (agent, agent_sm, react, reflexive, context, llm, endpoints)
│   ├── tools/                     # Tool bridging (tools, native_tools, sdr_query_tool, sdr_audio_tool, wallet/, trading/)
│   ├── ipc/                       # Concurrency (fifo_ipc, ipc, task_sync)
│   ├── sys/                       # System & Security (sandbox, container, cron, vitals, backup, auth, secrets, pgp)
│   ├── comms/                     # Communication (web, discord_bridge, email, mqtt, phone, social, gsuite, wallet)
│   ├── memory/                    # Memory stores (memory, recall, journal, transcript)
│   ├── agents/                    # Multi-agent coordination (subagents, swarm, workflows, remediation, phytology, telemetry)
│   ├── ui/                        # Terminal interface (ui, ui_dashboard, popup, slash, commands)
│   └── knowledge/                 # Knowledge engine (okf.sh)
├── bin/                           # Executable binaries (george-ipc, okf, prism)
├── commands/                      # Slash command handlers (okf.sh, bash.sh, test.sh, phytology.sh, trading.sh, etc.)
├── configs/                       # Declarative templates, model profiles, SearXNG & wallet examples (config -> configs)
├── deploy/                        # Turnkey container & service deployments
│   └── sdr-lab/                   # Sovereign P25 SDR Lab (Trunk-Recorder + Voxtral ASR + MQTT publisher + retention GC)
├── patches/                       # Upstream C++/CUDA patches (llama.cpp MTP/vision/audio, Trunk-Recorder frequency filter)
├── scripts/                       # Structured operational automation (with root symlinks)
│   ├── infra/                     # Local servers & runtime (start_prism.sh, compose.sh, init_secrets.sh, validate-gpu.sh)
│   ├── inference/                 # Dual-profile switching & models (switch_inference.sh, switch_model.sh, chat.py)
│   ├── monitor/                   # Real-time monitors (discord_live_monitor.sh, remediation_live_monitor.sh)
│   ├── ci/                        # Continuous integration (ci_local.sh, security_injection_scanner.py)
│   ├── release/                   # Public snapshot exporter & PII/secret gate (export_public.py, public_manifest.txt)
│   └── training/                  # Declarative training pipeline (pipeline.py, wizard.sh, check_credits.py)
├── tests/                         # Pure-bash & Python automated test suite (90+ test modules, framework.sh)
├── docs/                          # Comprehensive architectural specifications & operator playbooks
├── data/                          # Shared data, media assets, schemas, and public catalogs
│   ├── catalog/                   # Local SQLite FTS5 catalog (public_apis.sqlite)
│   └── schemas/                   # JSON schemas (native_tools.json, okf_graph.schema.json, recall.sql)
├── web/                           # Sovereign Web UI Sidecar (Rust Axum / Tokio PTY / SSE streaming frontend)
├── .george/                       # Untracked local state, databases, encrypted keystores, secrets, and IPC channels
├── lodge                          # Master interactive CLI & ReAct entrypoint
├── soul.md                        # Philosophical foundation, inviolable landmarks & operating architecture
└── GEORGE.md                      # Live project context & milestone trestleboard
```

## Active Task
Sovereign Public Release Readiness, Encrypted Multi-Chain Keystore (`agent-hot` / `agent-evm`), and P25 SDR Radio Lab Operations.

## Completed Milestones
- **[2026-10-18]** Sovereign Public Release Hardening, Encrypted Keystore Send/Receive & Turnkey P25 SDR Radio Lab:
  - **Encrypted Multi-Chain Keystore & Auto-Unlock (`lib/tools/wallet/keystore.py`, `lib/tools/wallet/qr.py`)**: Migrated plaintext `.george/wallets/cardano_payment.skey` and `polygon_payment.key` into AES-256-GCM + scrypt encrypted keystores (`.george/wallets/keystore/agent-hot.json`, `agent-evm.json`) with unattended daemon auto-unlock via `.george/secrets/agent_keystore.key` (`0600`).
  - **First-Class Send & Receive (`wallet_receive`, `wallet_send_preview`)**: Added pure-Python ISO/IEC 18004 QR code generation (SVG + ANSI terminal blocks), payment URIs (CIP-13 `web+cardano:`, EIP-681 `ethereum:`, BIP-21 `bitcoin:`, Solana Pay `solana:`), incoming TX history verification, and Tier B policy-gated multi-chain sends (Cardano ADA + native tokens like `SNEK` + CIP-20 memos; Polygon/Ethereum native + ERC-20 `USDC`/`USDC.e`) across CLI (`/wallet receive`, `/wallet send`), native tools, and the Rust/JS Web Trading Desk (`RECEIVE` & `SEND` tabs).
  - **Sovereign P25 SDR Radio Lab (`deploy/sdr-lab/`, `lib/tools/sdr_query_tool.py`, `lib/tools/sdr_audio_tool.py`)**: Packaged turnkey Docker deployment (Trunk-Recorder with RTL-SDR USB passthrough + frequency-filter patch, MQTT call publisher, retention GC, and Voxtral-Mini-4B ASR), integrated `sdr_query` and `sdr_listen` native tools into the `+social` bundle so George can query and play `.m4a` scanner audio directly from Discord, and authored `docs/SDR_LAB_OPERATOR_AND_USER_GUIDE.md`.
  - **Zero-PII Git Hygiene & Consolidated Layout**: Consolidated `config/` -> `configs/`, `lib/tools/patches/` -> `patches/`, and `deploy/sdr/` -> `deploy/sdr-lab/scripts/`, externalized all operator wallet addresses, tax lots, Discord IDs, and SDR node IPs into untracked `.george/*` configuration files, and verified zero secret/PII leakage via `scripts/release/export_public.py`. Trowel applied.
- **[2026-10-12]** Sovereign Cardano Unified Order Manager (UCOM):
  - Engineered 3-Tier Unified Cardano Order Manager architecture consolidating ladder placement, breakout stop-buys, and resting limit orders across state, engine, and interface layers.
  - **Phase 1 (Disarm Trap Hotfix)**: Fixed invalidation check in `lib/tools/cardano_stop_reactor.py` so stop-buys disarm immediately upon retreat below coil bounds, eliminating false-breakout capital lockups.
  - **Phase 2 (State & Adapter Layer)**: Added `v_unified_orders` polymorphic view in `lib/tools/cardano_maker_db.py`, implemented `CardanoOrderManager` (`lib/tools/cardano_order_manager.py`) enforcing the strict 80.0 ADA minimum floor per rung to guarantee autonomous exit viability, auto-compression of ladder counts, Option C inventory preloading, and lower-rung pruning upon partial ladder fills.
  - **Phase 3 (Unified Facade & Tooling)**: Created unified CLI `lib/tools/cardano_order_tool.py`, expanded `/trading order [status|ladder|stop|cancel|prune]` in `commands/trading.sh`, marked `cardano_triangle_deploy.py` deprecated with backward-compatible forwarding, and added `crypto_order` native function calling schema and dispatch.
  - **Phase 4 (Unified Engine Daemon & Crons)**: Consolidated resting order polling, ladder lower-rung pruning, pair ticker scraping, and invalidation trap checks into `lib/tools/cardano_engine_daemon.py`, integrated into `.george/cron_jobs/cardano_order_poll.sh`.
  - Verified with 23/23 passing assertions in `tests/test_cardano_order_manager.sh` and zero regressions across all Cardano suites (76+ tests passing green). Live mainnet orders in `maker_orders.db` verified 100% intact and safe. Trowel applied.
- **[2026-10-02]** Sovereign Cardano Market Maker Engine (Path D) with Conway script integrity hashing, dormant DEX pool reclamation, direct Plutus resting limit orders, and Workbench emergency cancellation UI. Trowel applied.
- **[2026-09-29]** Sovereign Public APIs SQLite FTS5 Catalog & Web Query Workbench Integration:
  - Ingested and indexed 1,959 curated REST endpoints across 52 categories from `public-apis/public-apis` into zero-latency local SQLite FTS5 database `data/catalog/public_apis.sqlite` (624 KB, symlinked to `.george/public_apis.db`).
  - Prioritized 933 keyless / zero-auth APIs (47.6%) at the top of BM25 search rankings for immediate autonomous consumption without credential friction.
  - Implemented Python backend `lib/tools/public_apis_backend.py` supporting `search`, `categories`, `info`, `sync`, and `stats` subcommands.
  - Built first-class `/api` slash command (`commands/api.sh`) for terminal exploration (`/api search <q>`, `/api keyless <q>`, `/api category <c>`, `/api categories`, `/api info <name>`, `/api sync`).
  - Added native function-calling tool `api_search` to `lib/tools/native_tools.sh` and `data/schemas/native_tools.json`.
  - Integrated public APIs database into Sovereign Web UI Studio (`web/src/routes/memories.rs`, `web/static/index.html`, `web/static/app.js`) with dynamic database selector and quick SQL chips.
  - Injected structured REST API discovery directives into `lib/core/context_engine.sh` guiding George to prefer clean JSON APIs over HTML scraping.
  - All 13 test suites passing in `tests/test_api_catalog.sh` (100% green). Trowel applied.
- **[2026-09-29]** Sovereign SearXNG Metasearch Engine, 8-Tool MCP Server & Multimodal Vision Integration:
  - Deployed sovereign local SearXNG metasearch container (`george-searxng`, port 8081) configured across 70+ engines in IT (GitHub, GitLab, StackOverflow, crates.io, PyPI, npm, Arch Wiki, MDN, Docker Hub), Science (arXiv, PubMed, Crossref, Google Scholar, Semantic Scholar, Europe PMC), General (Google, Bing, DuckDuckGo, Brave, Wikipedia), News, and Images.
  - Implemented unified Python backend `lib/tools/searxng_backend.py` supporting subcommands (`search`, `code`, `science`, `news`, `images`, `rss`, `engines`, `health`), formatters (`json`, `text`, `markdown`), engine introspection, and bang query handling (`!gh`, `!arxiv`, `!it`, `!science`, etc.).
  - Built pure POSIX JSON-RPC 2.0 MCP server `lib/tools/mcp_server_searxng.sh` exposing 8 native tools (`searxng_search`, `searxng_code_search`, `searxng_science_search`, `searxng_news_search`, `searxng_images`, `searxng_rss`, `searxng_engines`, `searxng_health`).
  - Integrated SearXNG as the default search engine in `lib/comms/web.sh` with automatic fallback cascade to external APIs (Serper, Perplexity) and POSIX DuckDuckGo scraping, plus native tool dispatch in `lib/tools/native_tools.sh` and schemas in `data/schemas/native_tools.json`.
  - Created `/searxng` slash command (`commands/searxng.sh`) with comprehensive subcommands and container lifecycle management (`start`, `stop`, `restart`, `status`, `open`).
  - Injected cognitive grounding and direct `bash_exec` escape hatch instructions into `lib/core/context_engine.sh` ensuring George has direct CLI authority (`bash commands/searxng.sh ...` and `curl -s ...`) to search, introspect, and restart the engine if tools are offline.
  - Verified single sovereign inference endpoint on port 8080 (Dual-GPU tensor split across both RTX 3060s); reserved 98k (`98304`) context ceiling if local ONNX vision models are loaded into VRAM alongside the primary server.
  - Trowel applied.
- **[2026-09-29]** Four-Layer Immune System, Scaffolding Archetypes, FIFO-IPC Flow Control & Sovereign Identity / RBAC Protocol:
  - Built out the Four-Layer Immune System across Blue Lodge to ensure self-replicating standards rather than manual pruning:
    1. **Scaffolding Archetypes (`bin/scaffold`, `/scaffold`)**: Golden-path generators for domain modules (`lib/<domain>/`), FIFO-IPC asynchronous workers (`scripts/workers/`), and RBAC-gated operator tools (`.george/tools/`).
    2. **Upstream Invariant Grounding (`lib/core/context_engine.sh`)**: Cognitive grounding injecting mandatory FIFO Async IPC flow control, RFC 4122 UUID task correlation, and clean polyglot separation directly into agent system prompts.
    3. **Mechanical CI Gates (`bin/lodge-lint`, `tests/test_architectural_conformance.sh`)**: Automated linter verifying directory partitioning, zero inline Python heredocs, FIFO credit backpressure, UUID/RBAC linking, and OKF graph synchronization.
    4. **Autonomic Phytology Remediation (`lib/agents/phytology.sh`)**: Continuous living tissue health auditing with closed-loop Gitea issue tracking, circuit breakers, and rollback snapshots.
  - Formalized and unified the **Sovereign Identity, RBAC & Multi-Entity UUID Linkage Protocol** (`lib/core/auth.sh`, `okf/standards/rbac_and_uuid_linking_protocol.jsonld`) linking Session <-> Task <-> Agent <-> PID <-> Channel <-> User.
  - Extracted inline Python into clean polyglot backend modules (`lib/knowledge/okf_backend.py`, `lib/tools/edit_backend.py`) and added robust POSIX fallbacks across telemetry and social bridges.
  - Updated multi-agent workflows (`dispatcher.agent.md`, `george.agent.md`, `the-architect.agent.md`, `the-tyler.agent.md`) enforcing `lodge-lint` conformance.
  - All 102 test suites passing (100% green). Trowel applied.
- **[2026-09-29]** Google Open Knowledge Graph (OKF) Architecture, Directory Modularization, 8.7GB Bloat Eradication & Protocol Standardization:
  - Codified the entire Blue Lodge directory hierarchy, modules, interfaces, and architectural standards into Google Open Knowledge Graph JSON-LD (`okf/blue_lodge_graph.jsonld`, conforming to `data/schemas/okf_graph.schema.json`).
  - Authored machine-readable OKF architectural standards in `okf/standards/` (`okf_directory_standard.jsonld`, `fifo_async_ipc_protocol.jsonld`, `subagent_sandbox_lifecycle.jsonld`, `telemetry_closed_loop_remediation.jsonld`, `sovereign_inference_switching.jsonld`).
  - Engineered the OKF CLI engine `lib/knowledge/okf.sh` and standalone binary `bin/okf` supporting semantic search (`okf search`), entity query (`okf query`), standards lookup (`okf standards`), knowledge tree rendering (`okf tree`), and filesystem validation (`okf validate`).
  - Integrated `okf_search` and `okf_query` as native function-calling tools in `data/schemas/native_tools.json` and `lib/tools/native_tools.sh`.
  - Built first-class `/okf` slash command (`commands/okf.sh`) and integrated `/ls okf` visualization.
  - Eradicated **8.7 GB of dead disk bloat**: purged 9 legacy 947MB incident snapshots in `.george/telemetry/incidents/` containing duplicate model binaries, added `telemetry_gc` with strict binary exclusion, rotated 13MB `cron.log` down to 169KB with automated rotation checks in `lib/sys/cron.sh`, pruned stale subagent logs, workspaces, discord sessions, and test snapshots.
  - Refactored flat `lib/` (73 files) and `scripts/` (29 files) into clean domain hierarchies (`lib/core/`, `lib/tools/`, `lib/ipc/`, `lib/sys/`, `lib/comms/`, `lib/memory/`, `lib/agents/`, `lib/ui/`, `lib/knowledge/` and `scripts/infra/`, `scripts/inference/`, `scripts/monitor/`, `scripts/ci/`, `scripts/training/`) with backward-compatible relative symlinks preserving 100% regression-free sourcing across all 87 test suites.
  - Thoroughly overhauled `GEORGE.md` and `soul.md` to reflect the Living Knowledge Trestleboard, FIFO Async IPC, and Sovereign Inference Fabric.
  - Trowel applied.
- **[2026-09-28]** Sovereign Model Architecture Decoupling, Declarative Training Pipeline & Modular Profile Installer: Reclaimed 29 GB disk space by consolidating partitioned model storage into `active/sovereign` and `active/experimental` symlink trees. Built dual-profile inference switcher `scripts/inference/switch_inference.sh` allowing instant toggling between sovereign production (Dual-GPU Qwen 3.8 + SVD32) and experimental research (Champion-v5 4.9GB MTP + Vision). Established workspace `.venv` integrated with Google Colab ADC compute credits (1,806.53 CU verified). Replaced 25+ fragmented one-off iteration scripts with unified declarative YAML pipeline `scripts/training/pipeline.py`, interactive terminal wizard `scripts/training/wizard.sh`, and first-class `/train` slash command (`commands/train.sh`). Upgraded Web Workbench with purple-themed `⚡ FORGE` studio modal for real-time credit monitoring and one-click execution. Completely modularized `install.sh` across 4 hardware profiles (`install/common.sh`, `install/common.sh`, `install/profile_compute_node.sh`, `install/profile_workstation.sh`, `install/profile_api_server.sh`, `install/profile_mobile.sh`) featuring interactive/flag-driven custom GGUF models directory selection (`MODELS_DIR`) universally linked into workspace `.george/models`, `lodge.conf`, `.env`, and shell RC files. Trowel applied.
- **[2026-09-28]** Sovereign Multi-Turn ReAct & Tool Calling Fleet Training & SVD32 Fusion: Trained 3 multi-turn tracks on `Qwen3.8-27B-UD-Q4_K_S.gguf` (CodeGen & GitOps, Web Research & Synthesis, Tools & Package Management) with 100% parameter alignment matching `lodge` production (`temperature: 1.0`, `reasoning_effort: medium`, `preserve_thinking: true`, `stop: ["<|im_end|>", "</tool_call>", "<|endoftext|>"]`, 65k context, dual-GPU tensor split (14,9)). Executed Iteration 13 LoRA/SVD32 fusion (`Blue-Llama-27B-Champion-v13-Fused-SVD32.gguf`) with 65% multi-turn weighting. Deployed and verified on PRISM server; achieved **97.8% composite score (29.34/30.00)** across all 6 pillars of `BlueLodgeMultiTurnBench`. Trowel applied.
- **[2026-09-26]** Re-engaged the Software-Phytology development tract: introduced living tissue diagnostic audit (`phytology_audit`), self-healing routine (`phytology_heal`), `/phytology` slash command (`status`, `audit`, `heal`, `rollback`, `prune`, `test`), and hardened Gitea Actions CI/CD pipeline (`.gitea/workflows/ci.yml`). Fully exercised through Sovereign Gitea GitFlow develop model (Issues #136, #138 and Pull Requests #137, #139) with 100% green CI build gates. Trowel applied.

## Context Files
- okf/blue_lodge_graph.jsonld
- okf/standards/okf_directory_standard.jsonld
- okf/standards/fifo_async_ipc_protocol.jsonld
- okf/standards/subagent_sandbox_lifecycle.jsonld
- okf/standards/telemetry_closed_loop_remediation.jsonld
- okf/standards/sovereign_inference_switching.jsonld
- docs/FIFO_ASYNC_IPC_FLOWCONTROL.md
- docs/AGENTIC_CONTAINER_SYSTEM_DESIGN.md
- docs/SDR_LAB_OPERATOR_AND_USER_GUIDE.md
- docs/CRYPTO_WALLETS.md
- soul.md

## Agent Notes
- **Sovereign SearXNG Metasearch Architecture (`http://127.0.0.1:8081`)**: Keyless aggregate search across 70+ engines in IT, Science, General, News, and Images. Backed by `lib/tools/searxng_backend.py`, 8-tool MCP server `lib/tools/mcp_server_searxng.sh`, `/searxng` slash command, and default routing in `lib/comms/web.sh`. If search tools fail or are unmounted, George possesses direct bash authority (`bash commands/searxng.sh query ...` or `docker restart george-searxng`).
- **Sovereign P25 SDR Radio Lab**: Real-time Trunk-Recorder P25 decode, Voxtral-Mini-4B LoRA ASR transcription, SQLite `sdr_calls.db` + MQTT (`lodge/sdr/calls`), and native tools `sdr_query` (call search, stats, talkgroup directory) + `sdr_listen` (multimodal `.m4a` audio analysis). Mounted automatically in `+social` / `+sdr` tool bundles.
- **Encrypted Multi-Chain Keystore & Policy Gates**: Signing keys live in `.george/wallets/keystore/*.json` (AES-256-GCM + scrypt) with auto-unlock via `.george/secrets/agent_keystore.key` (`0600`). Receive addresses & QR codes (`wallet_receive`) are Tier A; outgoing transfers (`wallet_send_preview`) are Tier B (require `confirm P-XXXXXX`) and Tier C blocked if breaching `floor_ada`.
- **Google Open Knowledge Graph (OKF) Architecture**: Master graph maintained at `okf/blue_lodge_graph.jsonld` (symlinked as `okf.jsonld`). Any agent or human developer can run `okf search <query>`, `okf query <target>`, or `okf standards [id]` to semantically inspect any component and standard across the repository.
- **FIFO Async IPC Protocol (`lib/ipc/fifo_ipc.sh`)**: Zero-daemon async IPC engine utilizing named pipes (`rx.fifo`, `tx.fifo`), atomic directory locking, sliding-window credit flowcontrol, and single-pass AWK garbage collection (`ipc_gc`). All frames are strict NDJSON capped under `PIPE_BUF` (4096 bytes).
- **Disk Hygiene & Retention Policy**: All incident snapshots in `.george/telemetry/incidents/` are strictly stripped of heavy weights (`*.gguf`, `*.bin`, `models/`) and aged out via `telemetry_gc 7`. `cron.log` is capped under 2MB with automatic head truncation in `_cron_loop_runner`.
- **Sovereign Dual-Profile Inference**: Seamless switching between Sovereign Production (Qwen3.8-27B) and Frontier Research (Champion-v5-Internal-MTP) via `scripts/inference/switch_inference.sh`.
- **Operator Preferences**: Local operator preferences and standing instructions are loaded dynamically from `.george/operator_notes.md` (untracked).
