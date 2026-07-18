#!/bin/bash
# DESC: Register, deploy, and manage Rust microservices
# Usage:
#   /service list                   — List registered services and their status
#   /service register <name> [path] — Register a Cargo project as a service
#   /service build <name>           — Compile the service (release mode)
#   /service deploy <name>          — Build, install to /usr/local/bin, restart
#   /service start <name>           — Start the service in the background
#   /service stop <name>            — Stop a running service
#   /service restart <name>         — Stop + start
#   /service status <name>          — Show PID, uptime, port, log tail
#   /service logs <name> [n]        — Show last N lines of service log (default 30)
#   /service unregister <name>      — Remove service registration (does not delete source)

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Paths ──────────────────────────────────────────────────────
GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}"
SERVICE_DIR="${SERVICE_DIR:-$GEORGE_CONFIG_DIR/services}"
SERVICE_LOG_DIR="${SERVICE_LOG_DIR:-$GEORGE_CONFIG_DIR/services/logs}"
SERVICE_BIN_DIR="${SERVICE_BIN_DIR:-/usr/local/bin}"

# ═══════════════════════════════════════════════════════════════
# Initialization
# ═══════════════════════════════════════════════════════════════

_service_init() {
    mkdir -p "$SERVICE_DIR" "$SERVICE_LOG_DIR"
}

# ═══════════════════════════════════════════════════════════════
# Registry helpers — flat files: $SERVICE_DIR/<name>.conf
# Format: key=value, one per line
# ═══════════════════════════════════════════════════════════════

_service_conf() {
    echo "$SERVICE_DIR/${1}.conf"
}

_service_exists() {
    [ -f "$(_service_conf "$1")" ]
}

_service_get() {
    local name="$1" key="$2"
    local conf
    conf=$(_service_conf "$name")
    [ -f "$conf" ] || return 1
    grep "^${key}=" "$conf" 2>/dev/null | head -1 | cut -d= -f2-
}

_service_set() {
    local name="$1" key="$2" val="$3"
    local conf
    conf=$(_service_conf "$name")
    if grep -q "^${key}=" "$conf" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$conf"
    else
        echo "${key}=${val}" >> "$conf"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Rust toolchain check
# ═══════════════════════════════════════════════════════════════

_service_require_rust() {
    # Source cargo env if not already in PATH
    if ! command -v cargo &>/dev/null; then
        [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
    fi
    if ! command -v cargo &>/dev/null; then
        ui_err "Rust toolchain not found."
        ui_dim "Install with: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        ui_dim "Then: source \$HOME/.cargo/env"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# PID helpers
# ═══════════════════════════════════════════════════════════════

_service_pid_file() {
    echo "$SERVICE_DIR/${1}.pid"
}

_service_is_running() {
    local name="$1"
    local pidfile
    pidfile=$(_service_pid_file "$name")
    [ -f "$pidfile" ] || return 1
    local pid
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_service_get_pid() {
    local pidfile
    pidfile=$(_service_pid_file "$1")
    [ -f "$pidfile" ] && cat "$pidfile" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# Subcommands
# ═══════════════════════════════════════════════════════════════

# ── /service register <name> [path] ───────────────────────────
_service_register() {
    local name="$1"
    local project_path="${2:-.}"

    if [ -z "$name" ]; then
        ui_err "Usage: /service register <name> [path]"
        return 1
    fi

    # Resolve to absolute path
    project_path=$(cd "$project_path" 2>/dev/null && pwd) || {
        ui_err "Path does not exist: $2"
        return 1
    }

    # Validate it's a Cargo project
    if [ ! -f "$project_path/Cargo.toml" ]; then
        ui_err "No Cargo.toml found at: $project_path"
        ui_dim "Register from a Rust project directory or pass the path."
        return 1
    fi

    # Detect binary name from Cargo.toml (first [[bin]] name, or package name)
    local bin_name
    bin_name=$(grep -A1 '^\[\[bin\]\]' "$project_path/Cargo.toml" 2>/dev/null | grep '^name' | head -1 | sed 's/.*= *"//;s/".*//')
    if [ -z "$bin_name" ]; then
        bin_name=$(grep '^\[package\]' -A5 "$project_path/Cargo.toml" | grep '^name' | head -1 | sed 's/.*= *"//;s/".*//')
    fi
    bin_name="${bin_name:-$name}"

    _service_init
    local conf
    conf=$(_service_conf "$name")

    if [ -f "$conf" ]; then
        ui_warn "Service '$name' already registered — updating."
    fi

    cat > "$conf" << EOF
name=${name}
bin=${bin_name}
path=${project_path}
registered=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    ui_ok "Registered service: $name"
    ui_dim "  Binary: $bin_name"
    ui_dim "  Source: $project_path"
    ui_dim "  Next:   /service deploy $name"
}

# ── /service build <name> ─────────────────────────────────────
_service_build() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: /service build <name>"
        return 1
    fi
    _service_exists "$name" || { ui_err "Unknown service: $name (run /service register first)"; return 1; }
    _service_require_rust || return 1

    local project_path
    project_path=$(_service_get "$name" "path")
    [ -d "$project_path" ] || { ui_err "Source path missing: $project_path"; return 1; }

    ui_step "Building $name (release)..."
    (cd "$project_path" && cargo build --release 2>&1)
    local rc=$?

    if [ $rc -eq 0 ]; then
        local bin_name
        bin_name=$(_service_get "$name" "bin")
        local artifact="$project_path/target/release/$bin_name"
        if [ -f "$artifact" ]; then
            _service_set "$name" "last_build" "$(date '+%Y-%m-%d %H:%M:%S')"
            ui_ok "Build succeeded: $artifact"
        else
            ui_warn "Build succeeded but binary not found at: $artifact"
            ui_dim "Check [[bin]] name in Cargo.toml"
            return 1
        fi
    else
        ui_err "Build failed (exit $rc)"
    fi
    return $rc
}

# ── /service deploy <name> ────────────────────────────────────
# Full pipeline: build → install binary → restart
_service_deploy() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: /service deploy <name>"
        return 1
    fi
    _service_exists "$name" || { ui_err "Unknown service: $name"; return 1; }

    # 1. Build
    _service_build "$name" || return 1

    # 2. Install binary to /usr/local/bin
    local bin_name project_path artifact
    bin_name=$(_service_get "$name" "bin")
    project_path=$(_service_get "$name" "path")
    artifact="$project_path/target/release/$bin_name"

    ui_step "Installing $bin_name → $SERVICE_BIN_DIR/"
    cp "$artifact" "$SERVICE_BIN_DIR/$bin_name" || {
        ui_err "Failed to copy binary to $SERVICE_BIN_DIR/ (permissions?)"
        return 1
    }
    chmod +x "$SERVICE_BIN_DIR/$bin_name"
    _service_set "$name" "installed" "$SERVICE_BIN_DIR/$bin_name"
    _service_set "$name" "last_deploy" "$(date '+%Y-%m-%d %H:%M:%S')"
    ui_ok "Installed: $SERVICE_BIN_DIR/$bin_name"

    # 3. Restart if already running, otherwise start
    if _service_is_running "$name"; then
        ui_step "Restarting $name..."
        _service_stop "$name"
        sleep 1
    fi
    _service_start "$name"
}

# ── /service start <name> ─────────────────────────────────────
_service_start() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: /service start <name>"
        return 1
    fi
    _service_exists "$name" || { ui_err "Unknown service: $name"; return 1; }

    if _service_is_running "$name"; then
        local pid
        pid=$(_service_get_pid "$name")
        ui_warn "$name is already running (PID $pid)"
        return 0
    fi

    local bin_name
    bin_name=$(_service_get "$name" "bin")
    local installed
    installed=$(_service_get "$name" "installed")

    # Prefer installed path, fall back to PATH lookup
    local bin_path="${installed:-$(command -v "$bin_name" 2>/dev/null)}"
    if [ -z "$bin_path" ] || [ ! -x "$bin_path" ]; then
        ui_err "Binary not found for $name. Run /service deploy $name first."
        return 1
    fi

    local logfile="$SERVICE_LOG_DIR/${name}.log"
    local pidfile
    pidfile=$(_service_pid_file "$name")

    ui_step "Starting $name..."
    nohup "$bin_path" >> "$logfile" 2>&1 &
    local pid=$!
    echo "$pid" > "$pidfile"
    _service_set "$name" "last_start" "$(date '+%Y-%m-%d %H:%M:%S')"
    _service_set "$name" "pid" "$pid"

    # Brief delay to check it didn't crash immediately
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        ui_ok "$name started (PID $pid)"
        ui_dim "  Log: $logfile"
    else
        ui_err "$name exited immediately — check logs:"
        tail -10 "$logfile" 2>/dev/null | while IFS= read -r line; do
            ui_dim "  $line"
        done
        rm -f "$pidfile"
        return 1
    fi
}

# ── /service stop <name> ──────────────────────────────────────
_service_stop() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: /service stop <name>"
        return 1
    fi
    _service_exists "$name" || { ui_err "Unknown service: $name"; return 1; }

    if ! _service_is_running "$name"; then
        ui_dim "$name is not running."
        rm -f "$(_service_pid_file "$name")"
        return 0
    fi

    local pid
    pid=$(_service_get_pid "$name")
    ui_step "Stopping $name (PID $pid)..."
    kill "$pid" 2>/dev/null

    # Wait up to 5 seconds for graceful shutdown
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ $waited -lt 5 ]; do
        sleep 1
        ((waited++))
    done

    # Force kill if still alive
    if kill -0 "$pid" 2>/dev/null; then
        ui_warn "Sending SIGKILL to $pid"
        kill -9 "$pid" 2>/dev/null
        sleep 1
    fi

    rm -f "$(_service_pid_file "$name")"
    _service_set "$name" "pid" ""
    ui_ok "$name stopped."
}

# ── /service restart <name> ───────────────────────────────────
_service_restart() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: /service restart <name>"
        return 1
    fi
    _service_stop "$name"
    sleep 1
    _service_start "$name"
}

# ── /service status <name> ────────────────────────────────────
_service_status() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: /service status <name>"
        return 1
    fi
    _service_exists "$name" || { ui_err "Unknown service: $name"; return 1; }

    ui_section "Service: $name"

    local bin_name project_path registered last_build last_deploy installed
    bin_name=$(_service_get "$name" "bin")
    project_path=$(_service_get "$name" "path")
    registered=$(_service_get "$name" "registered")
    last_build=$(_service_get "$name" "last_build")
    last_deploy=$(_service_get "$name" "last_deploy")
    installed=$(_service_get "$name" "installed")

    printf "  %-14s %s\n" "Binary:" "$bin_name"
    printf "  %-14s %s\n" "Source:" "$project_path"
    printf "  %-14s %s\n" "Installed:" "${installed:-not installed}"
    printf "  %-14s %s\n" "Registered:" "${registered:-unknown}"
    printf "  %-14s %s\n" "Last build:" "${last_build:-never}"
    printf "  %-14s %s\n" "Last deploy:" "${last_deploy:-never}"

    if _service_is_running "$name"; then
        local pid
        pid=$(_service_get_pid "$name")
        local uptime_info
        uptime_info=$(ps -p "$pid" -o etime= 2>/dev/null | sed 's/^ *//')
        printf "  %-14s %b%s (PID %s, up %s)%b\n" "Status:" "$C_GREEN" "RUNNING" "$pid" "${uptime_info:-?}" "$C_RESET"

        # Try to detect listening port
        local port
        port=$(ss -tlnp 2>/dev/null | grep "pid=${pid}," | awk '{print $4}' | grep -oE '[0-9]+$' | head -1)
        [ -n "$port" ] && printf "  %-14s %s\n" "Port:" "$port"
    else
        printf "  %-14s %b%s%b\n" "Status:" "$C_RED" "STOPPED" "$C_RESET"
    fi

    # Log tail
    local logfile="$SERVICE_LOG_DIR/${name}.log"
    if [ -f "$logfile" ]; then
        local log_size
        log_size=$(wc -l < "$logfile")
        printf "  %-14s %s (%s lines)\n" "Log:" "$logfile" "$log_size"
        echo ""
        ui_dim "  Last 5 log lines:"
        tail -5 "$logfile" | while IFS= read -r line; do
            ui_dim "    $line"
        done
    fi
    echo ""
}

# ── /service logs <name> [n] ──────────────────────────────────
_service_logs() {
    local name="$1"
    local count="${2:-30}"
    if [ -z "$name" ]; then
        ui_err "Usage: /service logs <name> [n]"
        return 1
    fi
    _service_exists "$name" || { ui_err "Unknown service: $name"; return 1; }

    local logfile="$SERVICE_LOG_DIR/${name}.log"
    if [ ! -f "$logfile" ]; then
        ui_dim "No logs for $name yet."
        return 0
    fi

    ui_section "Logs: $name (last $count lines)"
    tail -"$count" "$logfile"
    echo ""
}

# ── /service list ──────────────────────────────────────────────
_service_list() {
    _service_init

    local found=0
    ui_section "Registered Services"
    printf "  %-16s %-14s %-20s %s\n" "NAME" "STATUS" "LAST DEPLOY" "BINARY"
    printf "  %-16s %-14s %-20s %s\n" "────" "──────" "───────────" "──────"

    for conf in "$SERVICE_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        found=1
        local sname bin_name last_deploy status_label
        sname=$(basename "$conf" .conf)
        bin_name=$(_service_get "$sname" "bin")
        last_deploy=$(_service_get "$sname" "last_deploy")

        if _service_is_running "$sname"; then
            local pid
            pid=$(_service_get_pid "$sname")
            status_label=$(printf "%b● RUNNING%b" "$C_GREEN" "$C_RESET")
        else
            status_label=$(printf "%b○ stopped%b" "$C_DIM" "$C_RESET")
        fi

        printf "  %-16s %-14b %-20s %s\n" "$sname" "$status_label" "${last_deploy:-never}" "$bin_name"
    done

    if [ "$found" -eq 0 ]; then
        ui_dim "  No services registered. Use /service register <name> [path]"
    fi
    echo ""
}

# ── /service unregister <name> ─────────────────────────────────
_service_unregister() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: /service unregister <name>"
        return 1
    fi
    _service_exists "$name" || { ui_err "Unknown service: $name"; return 1; }

    # Stop if running
    if _service_is_running "$name"; then
        _service_stop "$name"
    fi

    local bin_name
    bin_name=$(_service_get "$name" "bin")
    rm -f "$(_service_conf "$name")"
    rm -f "$(_service_pid_file "$name")"
    ui_ok "Unregistered: $name"
    ui_dim "  Binary at $SERVICE_BIN_DIR/$bin_name was NOT removed."
    ui_dim "  To remove: rm $SERVICE_BIN_DIR/$bin_name"
}

# ═══════════════════════════════════════════════════════════════
# Dispatcher
# ═══════════════════════════════════════════════════════════════

cmd_service() {
    local args="$1"
    local workdir="${2:-.}"

    # Parse subcommand
    local subcmd
    subcmd=$(echo "$args" | awk '{print $1}')
    local rest
    rest=$(echo "$args" | sed 's/^[^ ]* *//')
    [ "$rest" = "$subcmd" ] && rest=""

    # Further split rest into name and extra args
    local svc_name extra_args
    svc_name=$(echo "$rest" | awk '{print $1}')
    extra_args=$(echo "$rest" | sed 's/^[^ ]* *//')
    [ "$extra_args" = "$svc_name" ] && extra_args=""

    case "$subcmd" in
        register)   _service_register "$svc_name" "$extra_args" ;;
        build)      _service_build "$svc_name" ;;
        deploy)     _service_deploy "$svc_name" ;;
        start)      _service_start "$svc_name" ;;
        stop)       _service_stop "$svc_name" ;;
        restart)    _service_restart "$svc_name" ;;
        status)     _service_status "$svc_name" ;;
        logs)       _service_logs "$svc_name" "$extra_args" ;;
        list|ls)    _service_list ;;
        unregister) _service_unregister "$svc_name" ;;
        ""|help)
            ui_section "Microservice Manager"
            printf "  %b/service list%b                   — List services and status\n" "$C_CYAN" "$C_RESET"
            printf "  %b/service register%b <name> [path] — Register Cargo project as a service\n" "$C_CYAN" "$C_RESET"
            printf "  %b/service build%b <name>           — Compile (release mode)\n" "$C_CYAN" "$C_RESET"
            printf "  %b/service deploy%b <name>          — Build + install + restart\n" "$C_CYAN" "$C_RESET"
            printf "  %b/service start%b <name>           — Start in background (nohup)\n" "$C_CYAN" "$C_RESET"
            printf "  %b/service stop%b <name>            — Graceful shutdown\n" "$C_CYAN" "$C_RESET"
            printf "  %b/service restart%b <name>         — Stop + start\n" "$C_CYAN" "$C_RESET"
            printf "  %b/service status%b <name>          — PID, uptime, port, log tail\n" "$C_CYAN" "$C_RESET"
            printf "  %b/service logs%b <name> [n]        — Last N log lines (default 30)\n" "$C_CYAN" "$C_RESET"
            printf "  %b/service unregister%b <name>      — Remove registration\n" "$C_CYAN" "$C_RESET"
            echo ""
            ui_dim "  Workflow: /service register api . → /service deploy api"
            echo ""
            ;;
        *)
            ui_err "Unknown subcommand: $subcmd"
            ui_dim "Run /service help for usage"
            return 1
            ;;
    esac
}
