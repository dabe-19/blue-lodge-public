#!/bin/bash
# ── Blue Lodge: Sandbox / Container System ─────────────────────
# Lightweight project isolation for Termux/Ubuntu.
# Uses proot or directory isolation — no Docker needed.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
LODGE_SANDBOXES="${LODGE_SANDBOXES:-$HOME/.lodge-sandboxes}"

# ── Detect available isolation ─────────────────────────────────
sandbox_detect() {
    if command -v proot &>/dev/null; then
        echo "proot"
    elif command -v unshare &>/dev/null && unshare --user true 2>/dev/null; then
        echo "unshare"
    else
        echo "directory"  # fallback: just directory isolation
    fi
}

# ── Create a new sandbox ──────────────────────────────────────
# Usage: sandbox_create "my_project" "rust|python|shell"
sandbox_create() {
    local name="$1"
    local type="${2:-shell}"
    local sandbox_dir="$LODGE_SANDBOXES/$name"
    
    if [ -d "$sandbox_dir" ]; then
        ui_warn "Sandbox '$name' already exists at $sandbox_dir"
        return 0
    fi
    
    mkdir -p "$sandbox_dir"/{src,tmp}
    
    case "$type" in
        rust)
            ui_step "Initializing Rust sandbox..."
            (cd "$sandbox_dir" && cargo init --name "$name" 2>&1) || {
                ui_err "cargo init failed"
                return 1
            }
            # Lighter Cargo.toml
            cat >> "$sandbox_dir/Cargo.toml" << 'RUSTEOF'

[profile.dev]
opt-level = 0
debug = false
incremental = true

[profile.release]
opt-level = 2
lto = "thin"
strip = true
RUSTEOF
            ui_ok "Rust sandbox ready"
            ;;
        
        python)
            ui_step "Initializing Python sandbox..."
            if command -v uv &>/dev/null; then
                (cd "$LODGE_SANDBOXES" && uv init "$name" --app 2>&1) || {
                    ui_err "uv init failed"
                    return 1
                }
            elif command -v python3 &>/dev/null; then
                python3 -m venv "$sandbox_dir/.venv"
                cat > "$sandbox_dir/main.py" << 'PYEOF'
"""Project entrypoint."""
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger(__name__)

def main() -> None:
    log.info("Ready")

if __name__ == "__main__":
    main()
PYEOF
            fi
            ui_ok "Python sandbox ready"
            ;;
        
        shell)
            cat > "$sandbox_dir/run.sh" << 'SHEOF'
#!/bin/bash
set -euo pipefail
echo "Shell sandbox ready"
SHEOF
            chmod +x "$sandbox_dir/run.sh"
            ui_ok "Shell sandbox ready"
            ;;
    esac
    
    # Git init
    (cd "$sandbox_dir" && git init -q && git add -A && git commit -q -m "Initial scaffold" 2>/dev/null) || true
    
    ui_ok "Sandbox: $sandbox_dir"
    echo "$sandbox_dir"
}

# ── Run a command inside a sandbox ─────────────────────────────
sandbox_exec() {
    local name="$1"
    shift
    local cmd="$*"
    local sandbox_dir="$LODGE_SANDBOXES/$name"
    
    if [ ! -d "$sandbox_dir" ]; then
        ui_err "Sandbox '$name' not found"
        return 1
    fi
    
    local method
    method=$(sandbox_detect)
    
    case "$method" in
        proot)
            # Lightweight root simulation
            proot -w "$sandbox_dir" -b /proc -b /dev /bin/bash -c "$cmd"
            ;;
        unshare)
            # User namespace isolation
            unshare --user --map-root-user bash -c "cd '$sandbox_dir' && $cmd"
            ;;
        directory)
            # Simple directory isolation (restricted PATH)
            (
                export HOME="$sandbox_dir"
                export TMPDIR="$sandbox_dir/tmp"
                cd "$sandbox_dir"
                bash -c "$cmd"
            )
            ;;
    esac
}

# ── Build inside sandbox ──────────────────────────────────────
sandbox_build() {
    local name="$1"
    local sandbox_dir="$LODGE_SANDBOXES/$name"
    
    if [ ! -d "$sandbox_dir" ]; then
        ui_err "Sandbox '$name' not found"
        return 1
    fi
    
    if [ -f "$sandbox_dir/Cargo.toml" ]; then
        ui_step "Building Rust project..."
        sandbox_exec "$name" "cargo build 2>&1"
    elif [ -f "$sandbox_dir/pyproject.toml" ]; then
        ui_step "Checking Python project..."
        if command -v uv &>/dev/null; then
            sandbox_exec "$name" "uv run python -c 'print(\"OK\")' 2>&1"
        else
            sandbox_exec "$name" ".venv/bin/python main.py 2>&1"
        fi
    elif [ -f "$sandbox_dir/run.sh" ]; then
        sandbox_exec "$name" "bash run.sh 2>&1"
    else
        ui_warn "Don't know how to build this project"
    fi
}

# ── Test inside sandbox ───────────────────────────────────────
sandbox_test() {
    local name="$1"
    local sandbox_dir="$LODGE_SANDBOXES/$name"
    
    if [ -f "$sandbox_dir/Cargo.toml" ]; then
        sandbox_exec "$name" "cargo test 2>&1"
    elif [ -f "$sandbox_dir/pyproject.toml" ]; then
        sandbox_exec "$name" "uv run pytest 2>&1" || sandbox_exec "$name" "uv run python -m pytest 2>&1"
    fi
}

# ── List sandboxes ────────────────────────────────────────────
sandbox_list() {
    if [ ! -d "$LODGE_SANDBOXES" ]; then
        ui_info "No sandboxes created yet"
        return
    fi
    
    ui_section "Sandboxes"
    for d in "$LODGE_SANDBOXES"/*/; do
        [ -d "$d" ] || continue
        local name
        name=$(basename "$d")
        local type="shell"
        [ -f "$d/Cargo.toml" ] && type="rust"
        [ -f "$d/pyproject.toml" ] && type="python"
        local size
        size=$(du -sh "$d" 2>/dev/null | cut -f1)
        printf "  %b%-20s%b %b%-8s%b %s\n" "$C_WHITE" "$name" "$C_RESET" "$C_CYAN" "$type" "$C_RESET" "$size"
    done
}

# ── Remove sandbox ────────────────────────────────────────────
sandbox_remove() {
    local name="$1"
    local sandbox_dir="$LODGE_SANDBOXES/$name"
    
    if [ ! -d "$sandbox_dir" ]; then
        ui_err "Sandbox '$name' not found"
        return 1
    fi
    
    if ui_confirm "Remove sandbox '$name' and all its contents?" "n"; then
        rm -rf "$sandbox_dir"
        ui_ok "Sandbox '$name' removed"
    fi
}

# ── Clone a repo into a sandbox ───────────────────────────────
sandbox_clone() {
    local repo_url="$1"
    local name="${2:-$(basename "$repo_url" .git)}"
    local sandbox_dir="$LODGE_SANDBOXES/$name"
    
    if [ -d "$sandbox_dir" ]; then
        ui_warn "Sandbox '$name' already exists. Pull instead?"
        (cd "$sandbox_dir" && git pull 2>&1)
        return $?
    fi
    
    mkdir -p "$LODGE_SANDBOXES"
    ui_step "Cloning $repo_url..."
    git clone "$repo_url" "$sandbox_dir" 2>&1
    
    if [ $? -eq 0 ]; then
        ui_ok "Cloned to $sandbox_dir"
    else
        ui_err "Clone failed"
        return 1
    fi
}
