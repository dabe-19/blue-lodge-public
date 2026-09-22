#!/bin/bash
# DESC: Sovereign Web UI Sidecar Service Manager
# Usage:
#   /web start    — Start the Web UI sidecar daemon in the background
#   /web stop     — Stop the Web UI sidecar daemon
#   /web status   — Check status, port, and health metrics
#   /web dev      — Run in foreground with live disk-serving
#   /web build    — Compile release binary with cargo
#   /web open     — Show access URL (http://127.0.0.1:3000)

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true

WEB_DIR="$LODGE_DIR/web"
PID_FILE="$LODGE_DIR/.george/services/george-web.pid"
LOG_FILE="$LODGE_DIR/.george/services/logs/george-web.log"
PORT="${GEORGE_WEB_PORT:-3000}"

cmd_web() {
    local subcmd="${1%% *}"
    local rest="${1#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    mkdir -p "$LODGE_DIR/.george/services/logs"

    # Ensure cargo is in PATH
    export PATH="$HOME/.cargo/bin:$PATH"

    case "$subcmd" in
        ""|status)
            _web_status
            ;;
        start)
            _web_start
            ;;
        stop)
            _web_stop
            ;;
        restart)
            _web_stop
            sleep 1
            _web_start
            ;;
        dev|run)
            _web_dev
            ;;
        build)
            _web_build
            ;;
        open)
            ui_info "Access George Sovereign Web UI at: http://127.0.0.1:$PORT"
            if command -v wslview &>/dev/null; then
                wslview "http://127.0.0.1:$PORT" &>/dev/null || true
            elif command -v xdg-open &>/dev/null; then
                xdg-open "http://127.0.0.1:$PORT" &>/dev/null || true
            fi
            ;;
        help|-h|--help)
            ui_section "George Sovereign Web UI Sidecar"
            echo "Usage: /web <command>"
            echo ""
            echo "Commands:"
            echo "  start    Launch the Web UI daemon in background (port $PORT)"
            echo "  stop     Stop the background Web UI daemon"
            echo "  restart  Restart the Web UI daemon"
            echo "  status   Check daemon health, PID, and port status"
            echo "  dev      Run in foreground with live static asset serving"
            echo "  build    Compile release binary via cargo"
            echo "  open     Open http://127.0.0.1:$PORT in browser"
            ;;
        *)
            ui_err "Unknown web command: $subcmd (try /web help)"
            return 1
            ;;
    esac
}

_web_status() {
    ui_section "Sovereign Web UI Status"
    local pid=""
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
    fi

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        ui_ok "Daemon running (PID: $pid) on port $PORT"
        echo "  URL: http://127.0.0.1:$PORT"
        echo "  Log: $LOG_FILE"
        if curl -sf --max-time 1 "http://127.0.0.1:$PORT/api/status" &>/dev/null; then
            echo -n "  Health: "
            curl -s "http://127.0.0.1:$PORT/api/status" 2>/dev/null | jq -c '.' 2>/dev/null || echo "OK"
        fi
    else
        # Check if something else is listening on the port
        local listening
        listening=$(ss -tlnp 2>/dev/null | grep ":$PORT " || true)
        if [ -n "$listening" ]; then
            ui_warn "Port $PORT is bound, but not by managed PID:"
            echo "  $listening"
        else
            ui_info "Daemon stopped (not listening on port $PORT)"
            echo "  Run '/web start' or '/web dev' to launch."
        fi
    fi
}

_web_start() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            ui_warn "Web UI already running on PID $pid (http://127.0.0.1:$PORT)"
            return 0
        fi
    fi

    local bin="$WEB_DIR/target/release/george-web"
    if [ ! -x "$bin" ]; then
        bin="$WEB_DIR/target/debug/george-web"
    fi

    if [ -x "$bin" ]; then
        ui_step "Starting compiled Web UI binary..."
        nohup env GEORGE_WEB_PORT="$PORT" "$bin" > "$LOG_FILE" 2>&1 &
        local new_pid=$!
        disown "$new_pid" 2>/dev/null || true
        echo "$new_pid" > "$PID_FILE"
        sleep 1
        if kill -0 "$new_pid" 2>/dev/null; then
            touch "$LODGE_DIR/.george/.web_observability" 2>/dev/null || true
            ui_ok "Web UI started (PID: $new_pid) at http://127.0.0.1:$PORT"
        else
            ui_err "Web UI failed to start. Check $LOG_FILE"
            return 1
        fi
    else
        ui_step "Binary not pre-compiled; launching via cargo run..."
        (
            cd "$WEB_DIR" && GEORGE_WEB_PORT="$PORT" cargo run > "$LOG_FILE" 2>&1
        ) &
        local new_pid=$!
        echo "$new_pid" > "$PID_FILE"
        sleep 2
        touch "$LODGE_DIR/.george/.web_observability" 2>/dev/null || true
        ui_ok "Web UI launched via Cargo (PID: $new_pid). Access at: http://127.0.0.1:$PORT"
    fi
}

_web_stop() {
    rm -f "$LODGE_DIR/.george/.web_observability" 2>/dev/null || true
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            ui_step "Stopping Web UI daemon (PID: $pid)..."
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
            rm -f "$PID_FILE"
            ui_ok "Web UI daemon stopped."
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    # Also check pkill by name
    pkill -f "george-web" 2>/dev/null || true
    ui_info "Web UI daemon is not running."
}

_web_dev() {
    ui_section "George Sovereign Web UI (Dev Mode)"
    echo "Serving live disk assets from: $WEB_DIR/static"
    echo "Access at: http://127.0.0.1:$PORT"
    echo "Press Ctrl+C to stop."
    echo ""
    cd "$WEB_DIR" && GEORGE_WEB_PORT="$PORT" cargo run
}

_web_build() {
    ui_step "Compiling George Sovereign Web UI release binary..."
    cd "$WEB_DIR" && cargo build --release
    if [ -x "$WEB_DIR/target/release/george-web" ]; then
        ui_ok "Release build complete: $WEB_DIR/target/release/george-web"
    else
        ui_err "Build failed."
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_web "$@"
fi
