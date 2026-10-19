#!/bin/bash
# DESC: Sovereign SearXNG Metasearch Engine Sidecar & Query Tool
# Usage:
#   /searxng status           — Check SearXNG container health & port status
#   /searxng start            — Start the SearXNG sidecar container (port 8081)
#   /searxng stop             — Stop the SearXNG sidecar container
#   /searxng restart          — Restart the SearXNG container
#   /searxng query <phrase>   — Run general metasearch query
#   /searxng code <phrase>    — Run IT/developer search (GitHub, StackOverflow, crates, pypi)
#   /searxng science <phrase> — Run academic/scientific research search (arXiv, PubMed)
#   /searxng news <phrase>    — Run news category search
#   /searxng images <phrase>  — Run image search and return image URLs
#   /searxng rss <phrase>     — Comb real-time RSS feeds
#   /searxng engines [cat]    — List active search engines and bang shortcuts
#   /searxng open             — Open Web UI in browser

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

SEARXNG_PORT="${SEARXNG_PORT:-8081}"
SEARXNG_URL="${SEARXNG_URL:-http://127.0.0.1:$SEARXNG_PORT}"

_py_exec() {
    if [ -x "$LODGE_DIR/.venv/bin/python" ]; then
        "$LODGE_DIR/.venv/bin/python" "$@"
    elif command -v uv &>/dev/null; then
        uv run --project "$LODGE_DIR" python "$@"
    else
        python3 "$@"
    fi
}

cmd_searxng() {
    local args="$1"
    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|status)
            _searxng_status
            ;;
        start)
            _searxng_start
            ;;
        stop)
            _searxng_stop
            ;;
        restart)
            _searxng_restart
            ;;
        query|search)
            if [ -z "$rest" ]; then
                ui_err "Usage: /searxng query <search phrase>"
                return 1
            fi
            _searxng_exec search --query "$rest" --category "general" --max-results 8
            ;;
        code|it)
            if [ -z "$rest" ]; then
                ui_err "Usage: /searxng code <developer query or error>"
                return 1
            fi
            _searxng_exec code --query "$rest" --max-results 8
            ;;
        science|paper|academic)
            if [ -z "$rest" ]; then
                ui_err "Usage: /searxng science <research topic or DOI>"
                return 1
            fi
            _searxng_exec science --query "$rest" --max-results 8
            ;;
        arxiv)
            if [ -z "$rest" ]; then
                ui_err "Usage: /searxng arxiv <research topic or preprint title>"
                return 1
            fi
            _searxng_exec arxiv --query "$rest" --max-results 8
            ;;
        hn|hackernews)
            if [ -z "$rest" ]; then
                ui_err "Usage: /searxng hn <discussion topic>"
                return 1
            fi
            _searxng_exec hn --query "$rest" --max-results 8
            ;;
        news)
            if [ -z "$rest" ]; then
                ui_err "Usage: /searxng news <search phrase>"
                return 1
            fi
            _searxng_exec news --query "$rest" --time-range "week" --max-results 8
            ;;
        images|img)
            if [ -z "$rest" ]; then
                ui_err "Usage: /searxng images <search phrase>"
                return 1
            fi
            _searxng_exec images --query "$rest" --max-results 10
            ;;
        rss)
            if [ -z "$rest" ]; then
                ui_err "Usage: /searxng rss <news topic>"
                return 1
            fi
            _searxng_exec rss --query "$rest" --max-results 8
            ;;
        engines)
            if [ -n "$rest" ]; then
                _searxng_exec engines --category "$rest" --format text
            else
                _searxng_exec engines --format text
            fi
            ;;
        open)
            ui_info "Opening SearXNG Web Interface at: $SEARXNG_URL"
            if command -v wslview &>/dev/null; then
                wslview "$SEARXNG_URL" &>/dev/null || true
            elif command -v xdg-open &>/dev/null; then
                xdg-open "$SEARXNG_URL" &>/dev/null || true
            fi
            ;;
        help|-h|--help)
            ui_section "Sovereign SearXNG Metasearch Engine"
            echo "Usage: /searxng <command> [arguments]"
            echo ""
            echo "Commands:"
            echo "  status            Check container health, latency, and uptime"
            echo "  start             Launch george-searxng sidecar container (port $SEARXNG_PORT)"
            echo "  stop              Stop george-searxng container"
            echo "  restart           Restart george-searxng container"
            echo "  query <phrase>    Execute keyless metasearch across Google, Bing, DDG, Brave"
            echo "  code <phrase>     Execute IT search across GitHub, StackOverflow, crates, pypi"
            echo "  science <phrase>  Execute academic search across arXiv, PubMed, Crossref"
            echo "  news <phrase>     Execute news search with recency filters"
            echo "  images <phrase>   Execute multi-engine image search"
            echo "  rss <phrase>      Comb real-time RSS feeds"
            echo "  engines [cat]     List active search engines and bang shortcuts"
            echo "  open              Open SearXNG interface in browser"
            ;;
        *)
            # Default to query if unknown subcmd
            _searxng_exec search --query "$args" --category "general" --max-results 8
            ;;
    esac
}

_searxng_status() {
    ui_section "SearXNG Metasearch Sidecar Status"
    local c_status
    c_status=$(docker inspect --format '{{.State.Status}}' george-searxng 2>/dev/null || echo "not_found")

    if [ "$c_status" = "running" ]; then
        ui_ok "Container: george-searxng (running)"
        echo "  Port:    $SEARXNG_PORT -> 8080 (container)"
        echo "  URL:     $SEARXNG_URL"
        local probe
        probe=$(curl -s -m 2 "$SEARXNG_URL/search?q=test&format=json" 2>/dev/null)
        if [ -n "$probe" ] && echo "$probe" | grep -q '"results"'; then
            local count
            count=$(echo "$probe" | jq -r '.results | length' 2>/dev/null || echo 0)
            ui_ok "API:     Operational ($count results on probe query)"
        else
            ui_warn "API:     Responding with errors or initializing"
        fi
    else
        ui_info "Container: george-searxng ($c_status)"
        echo "  Run '/searxng start' to launch the sovereign search sidecar."
    fi
}

_searxng_start() {
    ui_step "Starting george-searxng sidecar..."
    (cd "$LODGE_DIR" && docker compose up -d george-searxng)
    sleep 1
    _searxng_status
}

_searxng_stop() {
    ui_step "Stopping george-searxng sidecar..."
    (cd "$LODGE_DIR" && docker compose stop george-searxng)
    ui_ok "george-searxng container stopped."
}

_searxng_restart() {
    ui_step "Restarting george-searxng sidecar..."
    (cd "$LODGE_DIR" && docker compose restart george-searxng)
    sleep 1
    _searxng_status
}

_searxng_exec() {
    _py_exec "$LODGE_DIR/lib/tools/searxng_backend.py" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_searxng "$*"
fi
