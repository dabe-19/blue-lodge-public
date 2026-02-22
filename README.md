# ⌂ Blue Lodge

A lightweight, mobile-first coding agent powered by local LLMs via Ollama. Built for developers who code on phones and tablets.

## Why?

Claude Code doesn't work with small local models. The protocol translation, massive system prompts, and streaming format mismatches cause it to hang indefinitely on 4B parameter models. Blue Lodge replaces it with a purpose-built agent that:

- Calls Ollama directly (no proxy needed)
- Uses small, focused prompts (~1-2K tokens per step)
- Persists memory to `CLAUDE.md` files (survives restarts)
- Runs entirely in bash (no Node.js, no Python runtime needed)
- Designed for 12GB RAM ARM devices

## Quick Start

```bash
# Clone
git clone https://github.com/YOUR_USERNAME/blue-lodge.git ~/blue-lodge

# Install
bash ~/blue-lodge/install.sh

# Reload shell
source ~/.zshrc  # or ~/.bashrc

# Use
lodge              # Interactive mode
lodge /init myapp rust  # Scaffold a project
lodge "add error handling to main.rs"  # Give it a task
```

## Architecture

```
~/blue-lodge/
├── lodge              # Main TUI shell (entry point)
├── Modelfile          # Ollama model definition
├── soul.md            # Agent personality & rules
├── install.sh         # One-command setup
├── lib/
│   ├── ui.sh          # TUI rendering (colors, spinners, prompts)
│   ├── llm.sh         # Ollama API wrapper
│   ├── memory.sh      # CLAUDE.md management
│   ├── agent.sh       # Plan → Execute → Memory loop
│   ├── tools.sh       # File/shell operations + phone integration
│   ├── commands.sh    # Slash command dispatcher
│   └── sandbox.sh     # Project isolation
└── commands/
    ├── init.sh        # /init — scaffold projects
    ├── fix.sh         # /fix — diagnose & fix errors
    ├── test.sh        # /test — run tests
    ├── build.sh       # /build — build project
    ├── commit.sh      # /commit — AI commit messages
    ├── push.sh        # /push — push to GitHub
    └── clone.sh       # /clone — clone+setup repos
```

## Slash Commands

| Command | Alias | Description |
|---------|-------|-------------|
| `/help` | `lghelp` | Show all commands |
| `/init <name> <type>` | `lgi` | Scaffold project (rust/python/rl/data/automation/notebook/shell) |
| `/fix [file]` | `lgf` | Detect and fix errors |
| `/test [name]` | `lgt` | Run project tests |
| `/build [release]` | `lgb` | Build the project |
| `/commit [files]` | `lgc` | AI-generated commit message |
| `/push [branch]` | `lgp` | Push to GitHub |
| `/status` | `lgs` | Show agent + device status |
| `/memory` | `lgm` | Show current CLAUDE.md |
| `/soul` | — | Show agent personality |
| `/sandbox <cmd>` | `lgx` | Manage sandboxes (list/new/build/rm/cd/clone) |
| `/clone <repo>` | `lgcl` | Clone + auto-setup a repo |
| `/compact` | — | Compress memory file |
| `/snapshot` | — | Checkpoint memory |
| `/phone <cmd>` | — | Termux integration (battery/clip/notify/open/share/toast) |
| `/ask <question>` | — | Quick question (no file changes) |
| `/read <file>` | — | Read a file |
| `/files` | — | List workspace files |
| `/cd <dir>` | — | Change directory |
| `/clear` | — | Clear screen |
| `/quit` | — | Exit |

## Memory System

Blue Lodge uses `CLAUDE.md` files (compatible with the Claude Code convention) as persistent memory:

- **Per-project**: Each project gets its own `CLAUDE.md` with task state, plans, errors, and key files
- **Global personality**: `soul.md` defines the agent's behavior rules
- **Auto-compact**: Old completed steps get compressed to keep token count low
- **Snapshots**: `/snapshot` saves checkpoints you can roll back to

## Sandboxes

Lightweight project isolation without Docker:

```bash
lodge /sandbox new my_app rust    # Create Rust sandbox
lodge /sandbox new scraper python # Create Python sandbox
lodge /sandbox list               # List all sandboxes
lodge /sandbox cd my_app          # Switch to sandbox
lodge /sandbox build my_app       # Build in sandbox
lodge /sandbox clone owner/repo   # Clone + setup
```

## Phone Integration (Termux)

When running in Termux, Blue Lodge can interact with your phone:

```bash
lodge /phone battery    # Check battery
lodge /phone clip text  # Set clipboard
lodge /phone notify msg # Send notification
lodge /phone open URL   # Open URL in browser
lodge /phone share file # Share a file
lodge /phone toast msg  # Show toast message
```

## Hardware Targets

Designed for:
- Galaxy Fold 7 (Snapdragon 8 Elite, 12GB RAM)
- Samsung Galaxy S-series with Termux + Ubuntu
- Chromebooks (ARM or x86)
- Any device running Termux or Linux with 8GB+ RAM

## Model

Ships with Qwen3-4B-Instruct (Q5_K_M quantization) via Ollama. You can swap the model by editing `Modelfile` and running:

```bash
ollama create blue-lodge -f ~/blue-lodge/Modelfile
```

## License

MIT
