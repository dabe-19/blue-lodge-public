#!/bin/bash
# DESC: Sovereign Web Search/Fetch Engine & Web UI Sidecar Manager
# Usage:
#   /web search <query>       — Search the web
#   /web fetch <url>          — Fetch and extract readable text from a URL
#   /web scrape <url>         — Alias for fetch
#   /web images <query>       — Search for images
#   /web summary <url>        — AI-summarize a web page
#   /web links <url>          — Extract all links from a web page
#   /web title <url>          — Get page title
#   /web download <url>       — Download a file
#   /web ping <url>           — Check if URL is reachable
#   /web blacklist            — Manage blocked-site blacklist
#   /web cache clear          — Clear web cache
#   /web start|stop|restart   — Manage the George Web UI sidecar daemon (port 3000)
#   /web status               — Check Web UI sidecar health, PID, and port status
#   /web dev|build|open       — Run in dev mode, build release binary, or open in browser

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/web.sh" 2>/dev/null || true

WEB_DIR="$LODGE_DIR/web"
PID_FILE="$LODGE_DIR/.george/services/george-web.pid"
LOG_FILE="$LODGE_DIR/.george/services/logs/george-web.log"
PORT="${GEORGE_WEB_PORT:-3000}"

cmd_web() {
    local args="$1"
    local action
    action=$(echo "$args" | awk '{print $1}')
    local rest
    rest=$(echo "$args" | sed 's/^[^ ]* *//')
    [ "$rest" = "$action" ] && rest=""

    mkdir -p "$LODGE_DIR/.george/services/logs"
    export PATH="$HOME/.cargo/bin:$PATH"

    # Defensive: extract only the first URL for URL-taking actions
    case "$action" in
        fetch|read|scrape|scrape-images|scrapeimages|summary|links|title|ping)
            if [[ "$rest" == http* ]]; then
                rest=$(echo "$rest" | awk '{print $1}')
                rest="${rest%\\}"
            fi
            ;;
    esac

    case "$action" in
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
        search)
            web_search "$rest"
            ;;
        images)
            web_images "$rest"
            ;;
        fetch|read|scrape|scrape-images|scrapeimages)
            local _sj
            _sj=$(web_scrape "$rest")
            [ -z "$_sj" ] && return 1
            if [ ! -t 1 ]; then
                echo "$_sj"
            else
                echo "$_sj" | jq -r '
                  "Title: \(.title // "Untitled")",
                  "",
                  (.content // ""),
                  "",
                  if (.images | length) > 0 then
                    "Images (\(.images | length)):",
                    (.images | to_entries[] | "  \(.key+1). \(.value)")
                  else empty end,
                  "",
                  if (.links | length) > 0 then
                    "Links (\(.links | length)):",
                    (.links | to_entries[] | "  \(.key+1). \(.value)")
                  else empty end
                ' 2>/dev/null || echo "$_sj"
            fi
            ;;
        blacklist)
            local bl_sub bl_args
            bl_sub=$(echo "$rest" | awk '{print $1}')
            bl_args=$(echo "$rest" | sed 's/^[^ ]* *//')
            case "$bl_sub" in
                list|ls|"") web_blacklist_list ;;
                rm|remove|delete) web_blacklist_rm "$bl_args" ;;
                clear) web_blacklist_clear ;;
                enable|on) web_blacklist_enable ;;
                disable|off) web_blacklist_disable ;;
                *)
                    ui_info "Usage: /web blacklist <list|rm|clear|enable|disable>"
                    ;;
            esac
            ;;
        summary)
            web_summary "$rest"
            ;;
        links)
            web_links "$rest"
            ;;
        title)
            web_title "$rest"
            ;;
        download)
            local url fname
            url=$(echo "$rest" | awk '{print $1}')
            fname=$(echo "$rest" | awk '{print $2}')
            web_download "$url" "$fname"
            ;;
        ping)
            web_ping "$rest"
            ;;
        cache)
            local sub
            sub=$(echo "$rest" | awk '{print $1}')
            case "$sub" in
                clear) web_cache_clear ;;
                *)     ui_info "Usage: /web cache clear" ;;
            esac
            ;;
        help|-h|--help|*)
            ui_info "Usage: /web <fetch|scrape|search|images|summary|links|title|download|ping|blacklist|cache|status|start|stop|restart|dev|build|open>"
            ui_dim "  fetch <url>         — Read a web page as text"
            ui_dim "  scrape <url>        — Alias for fetch"
            ui_dim "  search <query>      — Search the web"
            ui_dim "  images <query>      — Search for images"
            ui_dim "  scrape-images <url> — Extract image URLs embedded in a page"
            ui_dim "  summary <url>       — AI-summarize a page"
            ui_dim "  links <url>         — Extract all links"
            ui_dim "  title <url>         — Get page title"
            ui_dim "  download <url>      — Download a file"
            ui_dim "  ping <url>          — Check if URL is reachable"
            ui_dim "  blacklist           — Manage blocked-site blacklist"
            ui_dim "  cache clear         — Clear web cache"
            ui_dim "  status|start|stop   — Manage George Sovereign Web UI sidecar (port $PORT)"
            ui_dim "  restart|dev|build   — Restart, run dev mode, or compile release Web UI"
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
    if command -v systemctl &>/dev/null && [ -f "$HOME/.config/systemd/user/george-web.service" ]; then
        systemctl --user daemon-reload 2>/dev/null || true
        if systemctl --user start george-web.service 2>/dev/null; then
            sleep 1
            local sys_pid
            sys_pid=$(systemctl --user show -p MainPID --value george-web.service 2>/dev/null || echo "")
            [ -n "$sys_pid" ] && [ "$sys_pid" != "0" ] && echo "$sys_pid" > "$PID_FILE"
            touch "$LODGE_DIR/.george/.web_observability" 2>/dev/null || true
            ui_ok "Web UI systemd service started (PID: ${sys_pid:-active}) at http://127.0.0.1:$PORT"
            return 0
        fi
    fi

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
        setsid -f env GEORGE_WEB_PORT="$PORT" "$bin" </dev/null >> "$LOG_FILE" 2>&1
        sleep 1
        local new_pid
        new_pid=$(pgrep -f "$bin" | head -n 1)
        if [ -n "$new_pid" ] && kill -0 "$new_pid" 2>/dev/null; then
            echo "$new_pid" > "$PID_FILE"
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
    if command -v systemctl &>/dev/null && [ -f "$HOME/.config/systemd/user/george-web.service" ]; then
        systemctl --user stop george-web.service 2>/dev/null || true
    fi
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
    ui_info "Web UI daemon stopped."
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
