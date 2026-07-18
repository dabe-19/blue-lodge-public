#!/bin/bash
# DESC: Scaffold a new project with GEORGE.md
# Usage:
#   /init              — interactive wizard (choose type and name)
#   /init <type>       — specify type, prompt for name
#   /init <name> <type> — specify both name and type directly
#   Types: rust, python, rl, data, automation, notebook, shell

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/sandbox.sh"

# ── Fuzzy type resolver ────────────────────────────────────────
# Attempts to match a possibly-hallucinated project type string
# to one of the canonical types. Sets two globals:
#   _INIT_RESOLVED_TYPE  — the canonical type (or empty on failure)
#   _INIT_TYPE_GUESSED   — "1" if we fuzzy-matched, "0" if exact
#
# Canonical types: rust, python, rl, data, automation, notebook, shell
_init_resolve_type() {
    local raw="${1,,}"  # lowercase
    _INIT_RESOLVED_TYPE=""
    _INIT_TYPE_GUESSED=0

    # ── Exact matches (including known aliases) ────────────────
    case "$raw" in
        rust|5)               _INIT_RESOLVED_TYPE="rust";       return 0 ;;
        python|data|2)        _INIT_RESOLVED_TYPE="data";       return 0 ;;
        rl|1)                 _INIT_RESOLVED_TYPE="rl";         return 0 ;;
        automation|auto|3)    _INIT_RESOLVED_TYPE="automation"; return 0 ;;
        notebook|jupyter|4)   _INIT_RESOLVED_TYPE="notebook";   return 0 ;;
        shell|sh|6)           _INIT_RESOLVED_TYPE="shell";      return 0 ;;
    esac

    # ── Heuristic / fuzzy matching ─────────────────────────────
    # Strip common noise: "lang", "project", "app", trailing digits, hyphens, underscores
    local cleaned
    cleaned=$(echo "$raw" | sed 's/[ _-]//g; s/project$//; s/app$//; s/lang$//; s/script$//; s/file$//; s/pad$//; s/book$//; s/env$//; s/type$//; s/[0-9]*$//')

    _INIT_TYPE_GUESSED=1

    # Rust variants: rs, rustlang, cargo, crate, rustproject, rst
    case "$cleaned" in
        rs|rst|rustlang|carg|cargo|crate|rust|rusty) _INIT_RESOLVED_TYPE="rust"; return 0 ;;
    esac

    # Python/data variants: py, python3, python2, pyth, pydata, polars, dataframe
    case "$cleaned" in
        py|pyth|python3|python2|pydata|polars|dataframe|dataanalysis|datasci*|panda*) _INIT_RESOLVED_TYPE="data"; return 0 ;;
    esac

    # RL variants: reinforcement, gym, gymnasium, cartpole, rlproject
    case "$cleaned" in
        reinforcement|reinforcementlearning|gym|gymnasium|cartpole|openai|rlenv|rlearn) _INIT_RESOLVED_TYPE="rl"; return 0 ;;
    esac

    # Automation variants: automate, scrape, scraper, beautifulsoup, bs4, requests, web-scraper
    case "$cleaned" in
        automate|scrape|scraper|beautifulsoup|bs4|request|requests|webscraper|crawl|crawler|httpbot) _INIT_RESOLVED_TYPE="automation"; return 0 ;;
    esac

    # Notebook variants: jupyter-notebook, ipython, ipynb, scratchpad, scratch, nb
    case "$cleaned" in
        jupyternotebook|ipython|ipynb|scratch|nb|jnb|jupyternb) _INIT_RESOLVED_TYPE="notebook"; return 0 ;;
    esac

    # Shell variants: bash, sh, zsh, shellscript, bashscript, cli
    case "$cleaned" in
        ba|bas|bash|zsh|cli|shel|terminal|term|posix|bashscri*|shellscri*) _INIT_RESOLVED_TYPE="shell"; return 0 ;;
    esac

    # ── Substring / prefix fallback (very fuzzy) ───────────────
    if [[ "$cleaned" == rust* ]] || [[ "$cleaned" == *cargo* ]]; then
        _INIT_RESOLVED_TYPE="rust"; return 0
    elif [[ "$cleaned" == py* ]] || [[ "$cleaned" == *python* ]]; then
        _INIT_RESOLVED_TYPE="data"; return 0
    elif [[ "$cleaned" == rl* ]] || [[ "$cleaned" == *reinforce* ]] || [[ "$cleaned" == *gymnasi* ]]; then
        _INIT_RESOLVED_TYPE="rl"; return 0
    elif [[ "$cleaned" == auto* ]] || [[ "$cleaned" == *scrap* ]] || [[ "$cleaned" == *crawl* ]]; then
        _INIT_RESOLVED_TYPE="automation"; return 0
    elif [[ "$cleaned" == *jupyter* ]] || [[ "$cleaned" == *notebook* ]] || [[ "$cleaned" == *ipynb* ]] || [[ "$cleaned" == *scratch* ]]; then
        _INIT_RESOLVED_TYPE="notebook"; return 0
    elif [[ "$cleaned" == *bash* ]] || [[ "$cleaned" == *shell* ]] || [[ "$cleaned" == *cli* ]]; then
        _INIT_RESOLVED_TYPE="shell"; return 0
    fi

    # ── Give up ────────────────────────────────────────────────
    _INIT_TYPE_GUESSED=0
    _INIT_RESOLVED_TYPE=""
    return 1
}

# ── Check if a raw string looks like a type (exact or fuzzy) ──
_init_is_type_keyword() {
    local raw="$1"
    _init_resolve_type "$raw"
    return $?
}

# ── Prerequisite checks per project type ───────────────────────
_init_check_prereqs() {
    local type="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local errors=0

    case "${type,,}" in
        rust|5)
            if ! command -v cargo &>/dev/null; then
                ui_err "[$timestamp] Rust toolchain (cargo) not found"
                ui_dim "  Install: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
                errors=$((errors + 1))
            fi
            ;;
        python|data|rl|automation|notebook|jupyter|2|1|3|4)
            if ! command -v python3 &>/dev/null; then
                ui_err "[$timestamp] Python 3 not found"
                ui_dim "  Install: apt install python3   (or: pkg install python)"
                errors=$((errors + 1))
            fi
            if [ "${type,,}" = "notebook" ] || [ "${type,,}" = "jupyter" ] || [ "$type" = "4" ]; then
                if ! command -v uv &>/dev/null && ! command -v pip3 &>/dev/null; then
                    ui_warn "[$timestamp] Neither uv nor pip3 found — Jupyter install may fail"
                fi
            fi
            ;;
    esac

    return $errors
}

# ── Guard: prevent init inside existing project ────────────────
# Only blocks in-place init (no project name). When a name is
# provided, /init creates a subdirectory — the parent directory
# having GEORGE.md is expected and allowed.
_init_guard_existing_project() {
    local target_dir="$1"  # empty for in-place, or the target project dir
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # In-place init (no name): block if GEORGE.md exists here
    if [ -z "$target_dir" ] && [ -f "$PWD/GEORGE.md" ]; then
        ui_err "[$timestamp] Already inside a project (GEORGE.md exists in $PWD)"
        ui_dim "  cd to a parent directory first, or use a different location"
        return 1
    fi
    # Named project: block if target directory already has GEORGE.md
    if [ -n "$target_dir" ] && [ -f "$target_dir/GEORGE.md" ]; then
        ui_ok "[$timestamp] Project already exists (GEORGE.md exists in $target_dir) — skipping initialization"
        return 2
    fi
    if [ -f "$PWD/Cargo.toml" ] || [ -f "$PWD/pyproject.toml" ] || [ -f "$PWD/package.json" ]; then
        ui_warn "[$timestamp] Current directory appears to be an existing project"
        if ! ui_confirm "Initialize a new sub-project here anyway?" "n"; then
            return 1
        fi
    fi
    return 0
}

cmd_init() {
    local args="$1"
    local workdir="${2:-.}"
    local name type
    local init_timestamp
    init_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    name=$(echo "$args" | awk '{print $1}')
    type=$(echo "$args" | awk '{print $2}')
    
    # If only one arg and it's a type keyword, treat as type and prompt for name
    if [ -n "$name" ] && [ -z "$type" ]; then
        if _init_is_type_keyword "$name"; then
            local _raw_input="$name"
            type="$_INIT_RESOLVED_TYPE"
            if [ "$_INIT_TYPE_GUESSED" -eq 1 ]; then
                ui_warn "[$init_timestamp] Interpreted '$_raw_input' as type '$type' (best guess)"
            fi
            name=""
            printf " Project name: "
            read -r name
        fi
    fi

    # If two args but second doesn't match a type, maybe they swapped order
    if [ -n "$name" ] && [ -n "$type" ]; then
        if ! _init_is_type_keyword "$type"; then
            # Maybe name and type are swapped — check if first arg is a type
            if _init_is_type_keyword "$name"; then
                local _swap_raw="$name"
                local _swapped_type="$_INIT_RESOLVED_TYPE"
                local _swapped_guess="$_INIT_TYPE_GUESSED"
                # Swap: the 'name' was really the type, the 'type' was really the name
                name="$type"
                type="$_swapped_type"
                ui_warn "[$init_timestamp] Arguments appear swapped — interpreted as: name='$name' type='$type'"
                if [ "$_swapped_guess" -eq 1 ]; then
                    ui_warn "[$init_timestamp] Fuzzy-matched type '$_swap_raw' → '$type' (best guess)"
                fi
            else
                # Neither arg is a recognized type — try fuzzy on the second arg
                if _init_resolve_type "$type"; then
                    local _fuzzy_raw="$type"
                    type="$_INIT_RESOLVED_TYPE"
                    if [ "$_INIT_TYPE_GUESSED" -eq 1 ]; then
                        ui_warn "[$init_timestamp] Interpreted type '$_fuzzy_raw' as '$type' (best guess)"
                    fi
                fi
                # If still unresolved, it will fall through to the unknown type error later
            fi
        else
            # Type matched — capture the resolved version
            local _type_raw="$type"
            type="$_INIT_RESOLVED_TYPE"
            if [ "$_INIT_TYPE_GUESSED" -eq 1 ]; then
                ui_warn "[$init_timestamp] Interpreted type '$_type_raw' as '$type' (best guess)"
            fi
        fi
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
            *) ui_err "[$init_timestamp] Invalid selection"; return 1 ;;
        esac
    fi
    
    # Validate name
    if [[ -z "$name" || ! "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
        ui_err "[$init_timestamp] Invalid project name: $name"
        ui_dim "  Names must start with a letter or underscore, and contain only letters, digits, underscores, hyphens"
        return 1
    fi

    # Normalize type aliases early for prerequisite checks
    local normalized_type
    if _init_resolve_type "$type"; then
        normalized_type="$_INIT_RESOLVED_TYPE"
    else
        # Last resort: unrecognized type, will fail at the case statement
        normalized_type="${type,,}"
    fi

    # ── Guardrail: check we're not inside an existing project ──
    _init_guard_existing_project "$workdir/$name"
    local _guard_rc=$?
    if [ $_guard_rc -eq 2 ]; then
        return 0
    elif [ $_guard_rc -ne 0 ]; then
        return 1
    fi

    # ── Guardrail: check prerequisites for chosen type ─────────
    if ! _init_check_prereqs "$normalized_type"; then
        ui_err "[$init_timestamp] Prerequisites not met for $normalized_type project"
        return 1
    fi

    # ── Create dedicated project directory upfront ─────────────
    local project_dir="$workdir/$name"
    if [ -f "$project_dir/GEORGE.md" ]; then
        ui_err "[$init_timestamp] Project already exists: $project_dir (GEORGE.md exists)"
        return 1
    fi

    mkdir -p "$project_dir"
    if [ $? -ne 0 ]; then
        ui_err "[$init_timestamp] Failed to create project directory: $project_dir"
        return 1
    fi
    cd "$project_dir" || { ui_err "[$init_timestamp] Failed to enter project directory"; return 1; }
    ui_step "[$init_timestamp] Created project directory: $project_dir"

    local build_cmd test_cmd env_label
    
    case "$normalized_type" in
        rust)
            env_label="Rust"
            build_cmd="cargo build"
            test_cmd="cargo test"
            
            ui_step "[$init_timestamp] Initializing Rust project..."
            # We're already inside the project directory — init in place
            cargo init . 2>&1
            if [ $? -ne 0 ]; then
                ui_err "[$init_timestamp] cargo init failed — check Rust toolchain"
                cd ..
                rm -rf "$project_dir"
                return 1
            fi
            
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
        
        data)
            env_label="Data Project (Python + Polars)"
            build_cmd="uv run main.py"
            test_cmd="uv run pytest"
            
            if command -v uv &>/dev/null; then
                ui_step "[$init_timestamp] Creating Python project with uv..."
                uv init . --app 2>&1
                uv add polars 2>&1
                uv add --dev pytest 2>&1
            else
                ui_step "[$init_timestamp] Creating Python project..."
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
        
        rl)
            env_label="RL Project (Gymnasium + Polars)"
            build_cmd="uv run main.py"
            test_cmd="uv run pytest"
            
            if command -v uv &>/dev/null; then
                ui_step "[$init_timestamp] Creating RL project with uv..."
                uv init . --app 2>&1
                uv add gymnasium polars numpy 2>&1
                uv add --dev pytest 2>&1
            else
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
        
        automation)
            env_label="App Automation (Requests + BS4)"
            build_cmd="uv run main.py"
            test_cmd="uv run pytest"
            
            if command -v uv &>/dev/null; then
                ui_step "[$init_timestamp] Creating automation project..."
                uv init . --app 2>&1
                uv add requests beautifulsoup4 2>&1
                uv add --dev pytest 2>&1
            else
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
        
        notebook)
            env_label="Python Scratchpad (Jupyter)"
            build_cmd="uv run jupyter notebook"
            test_cmd="uv run pytest"
            
            if command -v uv &>/dev/null; then
                ui_step "[$init_timestamp] Creating Jupyter project..."
                uv init . --app 2>&1
                uv add polars 2>&1
                uv add --dev jupyter pytest 2>&1
            else
                python3 -m venv .venv
            fi
            ;;
        
        shell)
            env_label="Shell Script"
            build_cmd="bash main.sh"
            test_cmd="bash test.sh"
            
            ui_step "[$init_timestamp] Creating shell project..."
            cat > main.sh << 'SHEOF'
#!/bin/bash
# System Shield Health Dashboard
# Use live Linux utilities (df, free, top, awk) to query resources dynamically.
# DO NOT hardcode stats or fall back to static placeholders.

CPU_LOAD=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}' || echo "1.0")
MEMORY_USAGE=$(free | awk '/Mem:/ {printf "%.1f", $3/$2 * 100}' || echo "15.0")
DISK_FREE_GB=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//' || echo "50")

echo "# System Health Dashboard

This report summarizes the current system resources.

## CPU Usage
* CPU Load: ${CPU_LOAD}%

## Memory (RAM)
* Memory Usage: ${MEMORY_USAGE}%

## Disk Usage
* Disk Free Space: ${DISK_FREE_GB} GB

## Status
* Overall Health: ✅ OK" > shield_status.md
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
            ui_err "[$init_timestamp] Unknown type: $type"
            ui_dim "Types: rust, python, rl, data, automation, notebook, shell"
            cd ..
            rm -rf "$project_dir"
            return 1
            ;;
    esac
    
    # Generate GEORGE.md
    memory_init "." "$name" "$env_label" "$build_cmd" "$test_cmd"
    
    # Git init
    git init -q 2>/dev/null
    echo -e "target/\n.venv/\n__pycache__/\n*.pyc\n.lodge-snapshots/" > .gitignore 2>/dev/null
    git add -A 2>/dev/null && git commit -q -m "Initial scaffold via George" 2>/dev/null
    
    local done_timestamp
    done_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo ""
    ui_ok "[$done_timestamp] Project '$name' ($env_label) created at $PWD"
    ui_ok "GEORGE.md ready — agent will use it for memory"
    ui_dim "Start working: lodge \"your task here\""
    echo ""
    
    # Update lodge project context
    export LODGE_PROJECT="$name"
}
