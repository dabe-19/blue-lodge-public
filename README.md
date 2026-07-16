# George: A Lightweight, Offline-First AI Coding Agent Framework

George is a local-first, privacy-respecting AI coding agent written in Bash. Designed to run entirely offline on edge hardware, standard laptops, and sandboxed workstations, George leverages scenario-routed prompt structures to enable small, highly optimized models (2B–12B parameters) to execute complex, multi-step development tasks.

By running directly in a POSIX-compliant shell environment, the framework integrates native system commands, full filesystem interaction, full-text search databases, and the Model Context Protocol (MCP) to provide a zero-cost, private alternative to cloud-based agent systems.

---

## Key Capabilities

* **Dual-Loop Agent Architecture**: A macro-loop (Strategist) decomposes tasks into concrete deliverables ("honeydew list"), while an inner-loop (Executor) selects tools, runs commands, and evaluates outcomes using multi-tier verification gates.
* **Scenario-Routed Prompts**: Dynamically matches prompt context size and style to the task at hand (ranging from lightweight ~250-token quick questions to ~3,500-token execution contexts). This allows small edge models to operate within strict context limits without performance degradation.
* **Integrated Agentic Dev Team**: Includes preconfigured workflows under [`.agents/workflows/`](file:///home/wsl-ops/blue-lodge/.agents/workflows/) that organize distinct agent roles (e.g., dispatcher, architect, style warden, security tyler, specialist coders) to execute project tasks, run build gates, and perform self-auditing.
* **Workstation Container Sandboxing**: Out-of-the-box support for isolated sandboxes via `proot`, user namespaces, or GPU-accelerated Docker containers (CUDA, Vulkan, and ROCm profiles) to run agent-led code optimization safely.
* **Memory & Retrieval-Augmented Generation**: Features a persistent project memory (`GEORGE.md`), a temporal decaying journal (`journal.md`), and an ultra-lightweight SQLite FTS5 full-text search database with BM25 ranking (<1ms lookup, 0 RAM overhead).
* **Pure-Bash MCP Client**: Direct JSON-RPC 2.0 implementation over stdio to communicate with any standard Model Context Protocol server (e.g., fetch, database, filesystem tools).

---

## Core Technology Stack

George is built to leverage modern edge-inference techniques to maximize token throughput and task execution accuracy on consumer hardware:

### Curated Model Suite
The framework supports hot-swapping between edge-optimized models and larger central models:

| Model Family | Tier | Strengths & Capabilities |
|--------------|------|--------------------------|
| **Gemma 4** | Edge (2B/4B) / Central (12B) | Default boot family. Employs **Unsloth QAT (Quantization-Aware Training)** GGUF formats (`UD-Q4_K_XL`) for high instruct accuracy. Includes multi-modal support via vision towers (`mmproj`). |
| **Qwen 3.5** | Edge (2B/4B) / Central (9B) | Broad general capability, featuring native reasoning/thinking models (e.g., `qwen35-4b-think`) for planning. |
| **Granite 4.1** | Edge (3B) / Central (8B) | Tailored for deterministic structured output and JSON tool routing. |
| **Nemotron 3** | Edge (4B) | NVIDIA-optimized instruct model for fast, edge-based execution. |

### Performance & Hardware Acceleration
George is optimized to run at high speed on edge devices using local backends (**Ollama** or **llama.cpp/llama-server**):

* **Speculative Decoding & Multi-Token Prediction (MTP)**: Utilizing embedded MTP draft heads in Gemma 4 Unsloth GGUFs, `llama-server` accelerates inference by **1.4x to 2.2x** without quality degradation.
* **Vision Tower Integration**: Supports visual context analysis by binding multimodal projectors (`gemma4-e2b-mmproj.gguf`) to the execution pipeline.
* **Dynamic Memory Management**: Automatically unloads/swaps models from memory between agent loops, freeing up system RAM (e.g., reclaiming ~4GB) to run local compilation commands and tests.

#### Execution Benchmarks (Galaxy Fold 7 / Snapdragon 8 Elite / 12GB RAM)
Running entirely on the raw hardware of the Galaxy Fold 7 in a Termux environment, George achieves:
* **Sustained Generation**: 15–30 tokens/second.
* **Load-Amortized Throughput**: 5–12 tokens/second (accounting for model loading and swapping overhead).
* **High Multi-Step Success**: Reliable execution of multi-file scaffolding, test runs, build verifications, and error recovery sequences.

---

## Agentic Development Team & Workspace Sandbox

In addition to acting as an interactive coding assistant, the project features a structured **Agentic Dev Team** workflow system located in [`.agents/`](file:///home/wsl-ops/blue-lodge/.agents/). This enables automated, agent-led code generation, verification, and audit pipelines on your local machine.

### Workflow Orchestration
The team operates using a strict role hierarchy and contract-driven process:
1. **Dispatcher**: Manages the orchestration pipeline, reading the project contract (`implementation_plan.md`) and routing tasks to the appropriate specialists.
2. **Quartermaster**: Manages packages, runtime SDKs, and build environment states.
3. **Specialists**: Targeted agents for code writing, UI adjustments, and test writing.
4. **Tester**: Automates test harness operations.
5. **George (Auditor)**: Evaluates the implementation, delegating style audits to **The Warden** and security audits to **The Tyler** before rendering a final verdict.

### CUDA/Vulkan Workstation Sandbox
To safely run agent-led operations, the repository includes a multi-profile Docker sandbox. The script `scripts/start-cuda-sandbox.sh` automatically detects host hardware and spins up the environment:

* **CUDA Profile**: Passes through physical GPUs (e.g., RTX 3060/4090) to the container for accelerated CUDA inference.
* **Vulkan Profile**: Utilizes integrated AMD/Intel graphics cards via Vulkan-loader bridges.
* **ROCm Profile**: Supports AMD Radeon discrete GPUs.
* **CPU Profile**: Falls back to optimized multi-threaded CPU execution.

Using this workstation sandbox, users can safely conduct agent-led optimization, customize prompting strategies, and run test loops without affecting the host filesystem.

---

## Quick Start

### Installation
Clone the repository and run the setup script:

```bash
git clone https://github.com/dabe-19/blue-lodge-public.git ~/blue-lodge
bash ~/blue-lodge/install.sh
source ~/.bashrc
```

* **Android (Termux)**: Follow the [Phone Setup Guide](docs/PHONE_SETUP.md) for optimized Termux setups.
* **Chromebook / Debian**: Refer to the [Debian/ChromeOS Setup Guide](docs/DEBIAN_CHROMEOS_SETUP.md).

### Basic Commands
Run the interactive REPL to interact with George or execute single-line tasks:

```bash
lodge                              # Open the interactive REPL
lodge /init myapp rust             # Scaffold a Rust project
lodge "add JSON error handling"    # Run a coding task in the current workspace
lodge /q "how does BM25 work?"     # Quick question (uses conversation memory)
lodge /models list                 # View and configure active models
```

---

## Architecture Deep Dive

### 1. Dual-Loop Agent Execution
George organizes reasoning and execution into two distinct loops to prevent context bloat:

```
User Task Input
  │
  ▼
┌────────────────────────────────────────────────────────┐
│ MACRO LOOP (Strategist)                                │
│ Decomposes task into "Honeydew List" (3-5 milestones)  │
│ Selects current milestone, tracks macro status         │
│                                                        │
│   For each Milestone:                                  │
│   ┌──────────────────────────────────────────────────┐ │
│   │ INNER LOOP (Executor)                            │ │
│   │ 1. Eligibility Gate (shortlists valid tools)     │ │
│   │ 2. Router (selects next tool)                    │ │
│   │ 3. Specialist (generates execution command)      │ │
│   │ 4. P1 Evaluator (verifies command output)        │ │
│   │ 5. Honeydew Evaluator (checks milestone completion)│ │
│   └──────────────────────────────────────────────────┘ │
│                                                        │
│ Evaluates overall task state, updates memory, exits    │
└────────────────────────────────────────────────────────┘
```

### 2. SQLite FTS5 Recall & Caching
Rather than relying on resource-intensive vector database engines, George uses a file-backed **SQLite FTS5 full-text search database** with BM25 ranking.
* **Context Retrieval**: Header-chunked source documentation and journals are queried instantly (<1ms), injecting relevant context directly into prompts.
* **Filesystem-Backed LRU Cache**: To survive bash subshell forks (where in-memory variables are lost), George employs an O(1) directory-based LRU cache. It uses file modification times (`mtime`) as the access tracker and generation counters for immediate O(1) cache namespace invalidation when source files change.

### 3. Pure-Bash Model Context Protocol (MCP) Client
The built-in MCP client allows the agent to discover and invoke tools from external servers:
* **Transport**: Implements JSON-RPC 2.0 using atomic FIFO pipes for stdout writing and standard file polls for responses to prevent subshell reader deadlocks.
* **Built-in Fetch Server**: Includes a native MCP fetch server (`mcp_server_fetch.sh`) exposing HTML-to-text extraction, JSON scraping, and web search capabilities.

### 4. Cloud Fallback & Low-Resource Support
For devices that lack the hardware resources to run models locally (e.g., an older iOS device using the iSH shell), George can route inference through 10 optional cloud API providers (including Google AI Studio, Groq, Mistral, and Anthropic).
* **Free Tier Rate-Limiting**: George includes exponential backoff algorithms designed to optimize throughput while staying strictly under free-tier API rate limits.
* **Network Remoting**: Supports routing local inference tasks to Ollama or `llama-server` endpoints running elsewhere on your local network (LAN).

### 5. Session Transcripts & Fine-Tuning Datasets
Every execution run in George automatically produces structured, timestamped trajectory logs and execution events under `~/.george/transcripts/` and `.george/`. These files are structured specifically with downstream model evaluation and fine-tuning (e.g., DPO, RLHF, and SFT) in mind:
* **Rich Session Transcripts**: Every task records the complete sequence of agent behaviors, labeled by role (`[strategist]`, `[router]`, `[specialist]`, `[eval-p1]`, `[eval-hd]`). Evaluations contain not just binary verdicts, but natural language rationale (e.g., `"UNSATISFIED — project compiled but FizzBuzz logic not implemented"`).
* **Deterministic Route Tracing**: Detailed routing traces containing classifier outputs, active eligibility gates, command shortlists, and final selections are logged per milestone to `.george/routing_trace.jsonl`.
* **Auto-Labeled Preference Pairs**: If a milestone is evaluated as `INCOMPLETE` or fails, the resulting loop escalation captures both the rejected trajectory and the subsequent corrected trajectory. These form natural chosen/rejected pairs for Direct Preference Optimization (DPO).

---

## Commands Reference

The framework registers over 50 slash commands for direct user interaction and agent tool routing. Here is a brief categorization:

<details>
<summary><strong>Expand Commands Catalog</strong></summary>

### System & Planning
| Command | Alias | Description |
|---------|-------|-------------|
| `/help` | `lghelp` | Show all commands |
| `/q <question>` | — | Quick question (lightweight, conversation memory) |
| `/brainstorm <topic>` | — | Run offline self-reasoning loop without user input |
| `/ask <question>` | — | Ask the user a question during task execution |
| `/plan <task>` | — | Generate a milestone plan without executing it |
| `/models [list\|status\|select\|spec]` | — | Manage model selection and speculative decoding settings |
| `/backend [status\|auto\|start\|stop]` | — | Manage local Ollama or llama-server services |
| `/status` | `lgs` | View agent memory, token load, and device health |

### Coding & Development
| Command | Alias | Description |
|---------|-------|-------------|
| `/init <name> <type>` | `lgi` | Scaffold Rust, Python, shell, or data science projects |
| `/fix [file\|error]` | `lgf` | Detect, diagnose, and repair compilation/test errors |
| `/test [name]` | `lgt` | Execute test suites in the current workspace |
| `/build [release]` | `lgb` | Trigger target compilers/build systems |
| `/commit [files]` | `lgc` | Draft conventional git commits |
| `/push [branch]` | `lgp` | Push changes to remote origin (SSH config) |
| `/clone <repo>` | `lgcl` | Safe-clone a git repository into an isolated sandbox |

### Filesystem & Sandbox
| Command | Alias | Description |
|---------|-------|-------------|
| `/write <file> <text>` | — | Write content to a file (creates directories dynamically) |
| `/read <file>` | — | View a file's contents |
| `/ls` | — | View workspace directory structure as a clean tree |
| `/sandbox [cmd]` | `lgx` | Manage sandbox environment mount paths and permissions |
| `/container [cmd]` | — | Login to or run commands inside proot-distro containers |

### Memory & Integrations
| Command | Alias | Description |
|---------|-------|-------------|
| `/memory` | `lgm` | Display current active GEORGE.md memory board |
| `/journal [cmd]` | — | Add or read decay-based temporal journal entries |
| `/recall <query>` | — | Query the SQLite FTS5 index for relevant code/docs |
| `/ingest <file>` | — | Parse and index documents (PDF, MD, HTML, DOCX) |
| `/social [post\|read]` | — | Interface with X, Mastodon, Bluesky, Discord, and Telegram |
| `/email [send\|inbox]` | — | Interface with Gmail, ProtonMail, Tuta, or Guerrilla Mail |
| `/gsuite [gmail\|drive]` | — | Authenticate and interact with Google Workspace APIs |
| `/mcp [install\|start\|call]` | — | Configure, run, and invoke Model Context Protocol servers |
| `/secret [set\|get]` | — | Store API tokens in the AES-256-CBC secrets vault |

</details>

---

## Testing Framework

George is backed by an automated testing suite comprising **43 test modules** and over **3,500 assertions**, written entirely in pure Bash with zero external dependencies.

Run the test suite locally to verify environment compatibility:

```bash
bash tests/run_all.sh              # Run all tests (compact output)
bash tests/run_all.sh -v           # Verbose mode showing every assertion
bash tests/run_all.sh test_llm     # Run only the LLM integration test module
```

---

## Contributing & Support

We welcome contributions, bug reports, and architectural feedback:
* **Bugs**: Open an issue detailing the model configuration, backend (Ollama vs. llama.cpp), and terminal environment.
* **Feedback**: We seek reviews on the shell caching systems, prompt-routing boundaries, and sandbox configurations.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
