#!/bin/bash
# DESC: Scaffold a new project with CLAUDE.md
# Usage:
#   /init              — interactive wizard (choose type and name)
#   /init <type>       — specify type, prompt for name
#   /init <name> <type> — specify both name and type directly
#   Types: rust, python, rl, data, automation, notebook, shell

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/sandbox.sh"

cmd_init() {
    local args="$1"
    local name type
    name=$(echo "$args" | awk '{print $1}')
    type=$(echo "$args" | awk '{print $2}')
    
    # If only one arg and it's a type keyword, treat as type and prompt for name
    if [ -n "$name" ] && [ -z "$type" ]; then
        case "${name,,}" in
            rust|python|rl|data|automation|auto|notebook|jupyter|shell|sh)
                type="${name,,}"
                name=""
                printf " Project name: "
                read -r name
                ;;
        esac
    fi

    # Interactive if no args
    if [ -z "$name" ] && [ -z "$type" ]; then
        echo ""
        ui_section "New Project"
        printf " %b[1]%b RL Project         %b(Python: Gymnasium + Polars)%b\n" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
        printf " %b[2]%b Data Project        %b(Python: Polars)%b\n" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
        printf " %b[3]%b App Automation      %b(Python: Requests + BS4)%b\n" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
        printf " %b[4]%b Python Scratchpad   %b(Jupyter Notebook)%b\n" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
        printf " %b[5]%b Rust Project        %b(Cargo)%b\n" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
        printf " %b[6]%b Shell Script        %b(Bash)%b\n" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
        echo ""
        printf " Select [1-6]: "
        read -r choice
        printf " Project name: "
        read -r name
        
        case "$choice" in
            1) type="rl" ;;
            2) type="data" ;;
            3) type="automation" ;;
            4) type="notebook" ;;
            5) type="rust" ;;
            6) type="shell" ;;
            *) ui_err "Invalid selection"; return 1 ;;
        esac
    fi
    
    # Validate name
    if [[ -z "$name" || ! "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
        ui_err "Invalid project name: $name"
        return 1
    fi
    
    local project_dir="$PWD/$name"
    local build_cmd test_cmd env_label
    
    case "${type,,}" in
        rust|5)
            env_label="Rust"
            build_cmd="cargo build"
            test_cmd="cargo test"
            
            ui_step "Creating Rust project..."
            cargo new "$name" 2>&1
            cd "$name"
            
            # Optimize for mobile builds
            cat >> Cargo.toml << 'EOF'

[profile.dev]
opt-level = 0
debug = false
incremental = true

[profile.release]
opt-level = 2
lto = "thin"
strip = true
EOF
            ;;
        
        python|data|2)
            env_label="Data Project (Python + Polars)"
            build_cmd="uv run main.py"
            test_cmd="uv run pytest"
            
            if command -v uv &>/dev/null; then
                ui_step "Creating Python project with uv..."
                uv init "$name" --app 2>&1
                cd "$name"
                uv add polars 2>&1
                uv add --dev pytest 2>&1
            else
                ui_step "Creating Python project..."
                mkdir -p "$name" && cd "$name"
                python3 -m venv .venv
            fi
            
            cat > main.py << 'PYEOF'
"""Data project entrypoint."""
import polars as pl
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger(__name__)

def main() -> None:
    df = pl.DataFrame({"x": [1, 2, 3], "y": [4, 5, 6]})
    log.info(f"DataFrame: {df.shape}")
    print(df)

if __name__ == "__main__":
    main()
PYEOF
            ;;
        
        rl|1)
            env_label="RL Project (Gymnasium + Polars)"
            build_cmd="uv run main.py"
            test_cmd="uv run pytest"
            
            if command -v uv &>/dev/null; then
                ui_step "Creating RL project with uv..."
                uv init "$name" --app 2>&1
                cd "$name"
                uv add gymnasium polars numpy 2>&1
                uv add --dev pytest 2>&1
            else
                mkdir -p "$name" && cd "$name"
                python3 -m venv .venv
            fi
            
            cat > main.py << 'PYEOF'
"""RL Project entrypoint."""
import gymnasium as gym
import polars as pl
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger(__name__)

def main() -> None:
    log.info("Initializing RL environment")
    env = gym.make("CartPole-v1")
    obs, info = env.reset()
    log.info(f"Observation shape: {obs.shape}")
    env.close()

if __name__ == "__main__":
    main()
PYEOF
            ;;
        
        automation|auto|3)
            env_label="App Automation (Requests + BS4)"
            build_cmd="uv run main.py"
            test_cmd="uv run pytest"
            
            if command -v uv &>/dev/null; then
                ui_step "Creating automation project..."
                uv init "$name" --app 2>&1
                cd "$name"
                uv add requests beautifulsoup4 2>&1
                uv add --dev pytest 2>&1
            else
                mkdir -p "$name" && cd "$name"
                python3 -m venv .venv
            fi
            
            cat > main.py << 'PYEOF'
"""App automation entrypoint."""
import requests
from bs4 import BeautifulSoup
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger(__name__)

def main() -> None:
    log.info("Automation ready")

if __name__ == "__main__":
    main()
PYEOF
            ;;
        
        notebook|jupyter|4)
            env_label="Python Scratchpad (Jupyter)"
            build_cmd="uv run jupyter notebook"
            test_cmd="uv run pytest"
            
            if command -v uv &>/dev/null; then
                ui_step "Creating Jupyter project..."
                uv init "$name" --app 2>&1
                cd "$name"
                uv add polars 2>&1
                uv add --dev jupyter pytest 2>&1
            else
                mkdir -p "$name" && cd "$name"
                python3 -m venv .venv
            fi
            ;;
        
        shell|sh|6)
            env_label="Shell Script"
            build_cmd="bash main.sh"
            test_cmd="bash test.sh"
            
            mkdir -p "$name" && cd "$name"
            cat > main.sh << 'SHEOF'
#!/bin/bash
set -euo pipefail
echo "Hello from $0"
SHEOF
            chmod +x main.sh
            cat > test.sh << 'SHEOF'
#!/bin/bash
set -euo pipefail
echo "Running tests..."
echo "All tests passed."
SHEOF
            chmod +x test.sh
            ;;
        
        *)
            ui_err "Unknown type: $type"
            ui_dim "Types: rust, python, rl, data, automation, notebook, shell"
            return 1
            ;;
    esac
    
    # Generate CLAUDE.md
    memory_init "." "$name" "$env_label" "$build_cmd" "$test_cmd"
    
    # Git init
    git init -q 2>/dev/null
    echo -e "target/\n.venv/\n__pycache__/\n*.pyc\n.lodge-snapshots/" > .gitignore 2>/dev/null
    git add -A 2>/dev/null && git commit -q -m "Initial scaffold via George" 2>/dev/null
    
    echo ""
    ui_ok "Project '$name' ($env_label) created at $PWD"
    ui_ok "CLAUDE.md ready — agent will use it for memory"
    ui_dim "Start working: lodge \"your task here\""
    echo ""
    
    # Update lodge project context
    export LODGE_PROJECT="$name"
}
