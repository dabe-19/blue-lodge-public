#!/bin/bash
# ── George: Sandbox / Project Isolation ─────────────────────────
# Lightweight project isolation for Termux/Ubuntu.
# Uses proot or directory isolation — no Docker needed.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
LODGE_SANDBOXES="${LODGE_SANDBOXES:-${LODGE_DIR:-.}/.sandboxes}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR:-.}/.george}"
SANDBOX_JOURNAL="${SANDBOX_JOURNAL:-$GEORGE_DIR/sandbox_journal.jsonl}"
LODGE_RUST_TOOLCHAIN="${LODGE_RUST_TOOLCHAIN:-stable}"  # Default Rust toolchain (stable, nightly, etc.)
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

# ── Prerequisite checks per sandbox type ───────────────────────
# Verifies tools are installed AND configured before creating or
# building. Returns 0 on success, 1+ on missing prereqs.
# Sets _SANDBOX_PREREQ_MSG with a human-readable diagnosis.
sandbox_check_prereqs() {
    local type="${1:-shell}"
    _SANDBOX_PREREQ_MSG=""
    local errors=0

    case "$type" in
        rust)
            if ! command -v rustup &>/dev/null; then
                _SANDBOX_PREREQ_MSG="rustup not found. Install: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
                return 1
            fi
            # Check that a default toolchain is set (the exact failure from the log)
            local default_tc
            default_tc=$(rustup default 2>&1)
            if [[ "$default_tc" == *"no default"* ]] || [[ "$default_tc" == *"is not installed"* ]] || [[ "$default_tc" == *"could not"* ]]; then
                ui_warn "No default Rust toolchain set"
                ui_dim "  Auto-fixing: rustup default $LODGE_RUST_TOOLCHAIN"
                if rustup default "$LODGE_RUST_TOOLCHAIN" 2>&1; then
                    ui_ok "Rust toolchain set to $LODGE_RUST_TOOLCHAIN"
                    _SANDBOX_PREREQ_MSG=""
                else
                    # Toolchain not installed — download it
                    ui_dim "  Toolchain '$LODGE_RUST_TOOLCHAIN' not installed. Installing..."
                    if rustup install "$LODGE_RUST_TOOLCHAIN" 2>&1 && rustup default "$LODGE_RUST_TOOLCHAIN" 2>&1; then
                        ui_ok "Installed and set Rust toolchain: $LODGE_RUST_TOOLCHAIN"
                        _SANDBOX_PREREQ_MSG=""
                        return 0
                    fi
                    _SANDBOX_PREREQ_MSG="Failed to install Rust toolchain '$LODGE_RUST_TOOLCHAIN'. Run manually: rustup install $LODGE_RUST_TOOLCHAIN && rustup default $LODGE_RUST_TOOLCHAIN"
                    return 1
                fi
            fi
            if ! command -v cargo &>/dev/null; then
                _SANDBOX_PREREQ_MSG="cargo not found despite rustup being installed. Run: rustup default $LODGE_RUST_TOOLCHAIN"
                return 1
            fi
            ;;
        python)
            if command -v uv &>/dev/null; then
                : # uv handles everything — no further checks needed
            elif command -v python3 &>/dev/null; then
                : # fallback to python3 venv
            else
                _SANDBOX_PREREQ_MSG="Neither uv nor python3 found. Install: apt install python3  (or: pip install uv)"
                return 1
            fi
            ;;
        shell)
            : # bash is always available
            ;;
    esac

    return $errors
}

# ── Toolchain version summary (for LLM context) ───────────────
# Returns a compact one-liner with detected tool versions.
sandbox_toolchain_info() {
    local type="${1:-}"
    local info=""

    case "$type" in
        rust)
            local cargo_v rustup_v
            cargo_v=$(cargo --version 2>/dev/null | head -1 || echo "not found")
            rustup_v=$(rustup default 2>/dev/null | awk '{print $1}' || echo "none")
            info="cargo: $cargo_v (toolchain: $rustup_v)"
            ;;
        python)
            if command -v uv &>/dev/null; then
                local uv_v
                uv_v=$(uv --version 2>/dev/null | head -1)
                info="uv: $uv_v"
            elif command -v python3 &>/dev/null; then
                local py_v
                py_v=$(python3 --version 2>/dev/null)
                info="$py_v"
            else
                info="no python toolchain"
            fi
            ;;
        shell)
            info="bash ${BASH_VERSION:-unknown}"
            ;;
    esac

    [ -n "$info" ] && echo "$info"
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

    # ── Prerequisite gate — abort before creating dirs ─────────
    if ! sandbox_check_prereqs "$type"; then
        ui_err "Cannot create $type sandbox: $_SANDBOX_PREREQ_MSG"
        return 1
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
    
    # Log to sandbox journal
    if declare -f sandbox_journal_log &>/dev/null; then
        sandbox_journal_log "create" "$name" "$type" "0"
    fi

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
    
    # Apply per-sandbox permissions if security.sh is loaded
    if declare -f security_sandbox_get_permission &>/dev/null; then
        local sandbox_perm
        sandbox_perm=$(security_sandbox_get_permission "$name")
        export LODGE_PERMISSION="$sandbox_perm"
    fi
    
    # ── Preserve toolchain environments across HOME override ───
    # Sandbox sets HOME=$sandbox_dir, which breaks tools like rustup/cargo
    # that look for ~/.rustup and ~/.cargo. Pin the real paths explicitly.
    local _real_home="${HOME:-/root}"
    local _rustup_home="${RUSTUP_HOME:-$_real_home/.rustup}"
    local _cargo_home="${CARGO_HOME:-$_real_home/.cargo}"
    local _extra_path="$_cargo_home/bin"
    local _path_with_cargo="$_extra_path:$PATH"
    
    local method
    method=$(sandbox_detect)
    
    case "$method" in
        proot)
            # Lightweight root simulation — pass toolchain env through
            proot -w "$sandbox_dir" -b /proc -b /dev \
                env HOME="$sandbox_dir" TMPDIR="$sandbox_dir/tmp" \
                RUSTUP_HOME="$_rustup_home" CARGO_HOME="$_cargo_home" \
                PATH="$_path_with_cargo" \
                /bin/bash -c "$cmd"
            ;;
        unshare)
            # User namespace isolation — pass toolchain env through
            unshare --user --map-root-user bash -c \
                "export HOME='$sandbox_dir' TMPDIR='$sandbox_dir/tmp' \
                 RUSTUP_HOME='$_rustup_home' CARGO_HOME='$_cargo_home' \
                 PATH='$_path_with_cargo'; cd '$sandbox_dir' && $cmd"
            ;;
        directory)
            # Simple directory isolation — pass toolchain env through
            (
                export HOME="$sandbox_dir"
                export TMPDIR="$sandbox_dir/tmp"
                export RUSTUP_HOME="$_rustup_home"
                export CARGO_HOME="$_cargo_home"
                export PATH="$_path_with_cargo"
                cd "$sandbox_dir"
                bash -c "$cmd"
            )
            ;;
    esac

    local _exec_rc=$?
    # Log to sandbox journal
    if declare -f sandbox_journal_log &>/dev/null; then
        sandbox_journal_log "exec" "$name" "$cmd" "$_exec_rc"
    fi
    return $_exec_rc
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

    local _build_rc=$?
    if declare -f sandbox_journal_log &>/dev/null; then
        sandbox_journal_log "build" "$name" "build" "$_build_rc"
    fi
    return $_build_rc
}

# ── Test inside sandbox ───────────────────────────────────────
sandbox_test() {
    local name="$1"
    local sandbox_dir="$LODGE_SANDBOXES/$name"

    if [ ! -d "$sandbox_dir" ]; then
        ui_err "Sandbox '$name' not found"
        return 1
    fi

    if [ -f "$sandbox_dir/Cargo.toml" ]; then
        ui_step "Running Rust tests..."
        sandbox_exec "$name" "cargo test 2>&1"
    elif [ -f "$sandbox_dir/pyproject.toml" ]; then
        ui_step "Running Python tests..."
        sandbox_exec "$name" "uv run pytest 2>&1" || sandbox_exec "$name" "uv run python -m pytest 2>&1"
    elif [ -f "$sandbox_dir/run.sh" ]; then
        ui_step "Running shell sandbox..."
        sandbox_exec "$name" "bash run.sh 2>&1"
    else
        ui_warn "No recognized test runner for sandbox '$name'"
        return 1
    fi
}

# ── List sandboxes ────────────────────────────────────────────
sandbox_list() {
    if [ ! -d "$LODGE_SANDBOXES" ]; then
        ui_info "No sandboxes created yet"
        return
    fi

    local count=0
    ui_section "Sandboxes"
    printf "  %b%-18s %-8s %-7s %-12s %s%b\n" "$C_DIM" "NAME" "TYPE" "SIZE" "LAST USED" "EVENTS" "$C_RESET"

    for d in "$LODGE_SANDBOXES"/*/; do
        [ -d "$d" ] || continue
        local name
        name=$(basename "$d")
        local type="shell"
        [ -f "$d/Cargo.toml" ] && type="rust"
        [ -f "$d/pyproject.toml" ] && type="python"
        local size
        size=$(du -sh "$d" 2>/dev/null | cut -f1)

        # Journal info
        local last_used="never" exec_count=0
        if [ -f "$SANDBOX_JOURNAL" ]; then
            exec_count=$(grep -c "\"name\":\"$name\"" "$SANDBOX_JOURNAL" 2>/dev/null || echo 0)
            local last_line
            last_line=$(grep "\"name\":\"$name\"" "$SANDBOX_JOURNAL" | tail -1)
            if [ -n "$last_line" ]; then
                last_used=$(echo "$last_line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' | cut -dT -f1)
            fi
        fi

        printf "  %b%-18s%b %b%-8s%b %-7s %-12s %s\n" \
            "$C_WHITE" "$name" "$C_RESET" \
            "$C_CYAN" "$type" "$C_RESET" \
            "$size" "$last_used" "$exec_count"
        (( count++ ))
    done

    if [ "$count" -eq 0 ]; then
        ui_info "No sandboxes created yet"
    fi
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
        if declare -f sandbox_journal_log &>/dev/null; then
            sandbox_journal_log "remove" "$name" "removed" "0"
        fi
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
    local _clone_rc=$?

    if [ $_clone_rc -eq 0 ]; then
        if declare -f sandbox_journal_log &>/dev/null; then
            sandbox_journal_log "clone" "$name" "$repo_url" "0"
        fi
        ui_ok "Cloned to $sandbox_dir"
    else
        ui_err "Clone failed"
        return 1
    fi
}

# ── Sandbox Journal ───────────────────────────────────────────
# Persistent log of all sandbox events — lets George know what
# sandboxes exist, which ones he's used, and what happened in them.
# Stored as JSONL: one JSON object per line.
#
# Format: {"ts":"ISO8601","ev":"EVENT","name":"NAME","detail":"...","rc":0}
# Events: create, exec, build, test, remove, clone

# Log a sandbox event to the journal.
# Usage: sandbox_journal_log "event" "name" "detail" "exit_code"
sandbox_journal_log() {
    local event="$1" name="$2" detail="$3" rc="${4:-0}"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    mkdir -p "$(dirname "$SANDBOX_JOURNAL")"
    # Escape double quotes and newlines in detail
    detail="${detail//\"/\\\"}"
    detail="${detail//$'\n'/\\n}"
    printf '{"ts":"%s","ev":"%s","name":"%s","detail":"%s","rc":%s}\n' \
        "$ts" "$event" "$name" "$detail" "$rc" >> "$SANDBOX_JOURNAL"
}

# Read last N journal entries (raw JSONL).
# Usage: sandbox_journal_read [n]
sandbox_journal_read() {
    local n="${1:-20}"
    [ -f "$SANDBOX_JOURNAL" ] || return 0
    tail -n "$n" "$SANDBOX_JOURNAL"
}

# Generate a compact sandbox inventory for LLM context injection.
# Returns nothing (rc=0) if no sandboxes exist.
sandbox_journal_summary() {
    if [ ! -d "$LODGE_SANDBOXES" ]; then
        return 0
    fi

    local sandbox_count=0
    local lines=""

    for d in "$LODGE_SANDBOXES"/*/; do
        [ -d "$d" ] || continue
        local name
        name=$(basename "$d")
        local type="shell"
        [ -f "$d/Cargo.toml" ] && type="rust"
        [ -f "$d/pyproject.toml" ] && type="python"

        # Creation date from filesystem
        local created
        created=$(stat -c '%W' "$d" 2>/dev/null)
        if [ "$created" = "0" ] || [ -z "$created" ]; then
            created=$(stat -c '%Y' "$d" 2>/dev/null)
        fi
        created=$(date -d "@$created" '+%Y-%m-%d' 2>/dev/null || echo "unknown")

        # Last-used and event count from journal
        local last_used="never" exec_count=0 last_rc=0
        if [ -f "$SANDBOX_JOURNAL" ]; then
            exec_count=$(grep -c "\"name\":\"$name\"" "$SANDBOX_JOURNAL" 2>/dev/null || echo 0)
            local last_line
            last_line=$(grep "\"name\":\"$name\"" "$SANDBOX_JOURNAL" | tail -1)
            if [ -n "$last_line" ]; then
                last_used=$(echo "$last_line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' | cut -dT -f1)
                last_rc=$(echo "$last_line" | sed -n 's/.*"rc":\([0-9]*\).*/\1/p')
            fi
        fi

        lines="${lines}  ${name}  ${type}  created:${created}  last:${last_used}  (${exec_count} events, last rc=${last_rc:-0})\n"
        (( sandbox_count++ ))
    done

    if [ "$sandbox_count" -eq 0 ]; then
        return 0
    fi

    printf -- "--- SANDBOX INVENTORY (%d) ---\n" "$sandbox_count"
    printf "%b" "$lines"
    printf "Reuse existing sandboxes when possible. /sandbox list for details.\n"
}

# Detailed status of a single sandbox.
# Usage: sandbox_status "name"
sandbox_status() {
    local name="$1"
    local sandbox_dir="$LODGE_SANDBOXES/$name"

    if [ ! -d "$sandbox_dir" ]; then
        ui_err "Sandbox '$name' not found"
        return 1
    fi

    local type="shell"
    [ -f "$sandbox_dir/Cargo.toml" ] && type="rust"
    [ -f "$sandbox_dir/pyproject.toml" ] && type="python"

    local size
    size=$(du -sh "$sandbox_dir" 2>/dev/null | cut -f1)

    local method
    method=$(sandbox_detect)

    local file_count
    file_count=$(find "$sandbox_dir" -type f ! -path '*/.git/*' 2>/dev/null | wc -l)

    local git_status=""
    if [ -d "$sandbox_dir/.git" ]; then
        git_status=$(cd "$sandbox_dir" && git log --oneline -1 2>/dev/null || echo "(no commits)")
    fi

    ui_section "Sandbox: $name"
    printf "  Type:       %b%s%b\n" "$C_CYAN" "$type" "$C_RESET"
    printf "  Isolation:  %s\n" "$method"
    printf "  Path:       %s\n" "$sandbox_dir"
    printf "  Size:       %s  (%d files)\n" "$size" "$file_count"
    [ -n "$git_status" ] && printf "  Last commit: %s\n" "$git_status"

    # Recent journal activity for this sandbox
    if [ -f "$SANDBOX_JOURNAL" ]; then
        local events
        events=$(grep "\"name\":\"$name\"" "$SANDBOX_JOURNAL" | tail -5)
        if [ -n "$events" ]; then
            printf "\n  %bRecent activity:%b\n" "$C_DIM" "$C_RESET"
            while IFS= read -r line; do
                local ev ts detail rc
                ev=$(echo "$line" | sed -n 's/.*"ev":"\([^"]*\)".*/\1/p')
                ts=$(echo "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' | sed 's/T/ /;s/Z//')
                detail=$(echo "$line" | sed -n 's/.*"detail":"\([^"]*\)".*/\1/p')
                rc=$(echo "$line" | sed -n 's/.*"rc":\([0-9]*\).*/\1/p')
                local rc_color="$C_GREEN"
                [ "$rc" != "0" ] && rc_color="$C_RED"
                printf "    %s  %b%-6s%b  %s  %brc=%s%b\n" "$ts" "$C_CYAN" "$ev" "$C_RESET" "${detail:0:40}" "$rc_color" "$rc" "$C_RESET"
            done <<< "$events"
        fi
    fi
}
