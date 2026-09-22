#!/bin/bash
# ── Sovereign Infrastructure & Sidecar Manager ──────────────────
# Default execution policy: NEVER rebuild or pull unless explicitly flagged with 'rebuild'.

set -euo pipefail
LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LODGE_DIR"

CMD="${1:-status}"

case "$CMD" in
    start|up)
        echo "[+] Starting Docker Infrastructure (--no-build)..."
        docker compose up -d --no-build
        docker compose ps

        # Check / launch native Web sidecar if not running in container
        if ! curl -s http://localhost:3000/api/status >/dev/null 2>&1; then
            echo "[+] Starting Sovereign Web UI sidecar (george-web)..."
            if [ -f "$LODGE_DIR/web/target/release/george-web" ]; then
                nohup "$LODGE_DIR/web/target/release/george-web" >/dev/null 2>&1 &
                sleep 1
                echo "[✓] george-web running on http://localhost:3000"
            fi
        else
            echo "[✓] george-web is already operational on http://localhost:3000"
        fi

        # Optional: pre-warm MCP servers if --mcp or --all passed
        if [[ "${2:-}" == "--mcp" || "${2:-}" == "--all" ]]; then
            echo "[+] Pre-warming registered MCP servers..."
            source "$LODGE_DIR/lib/mcp.sh" 2>/dev/null || true
            if declare -f mcp_start >/dev/null; then
                for srv in $(mcp_server_names); do
                    echo "  - Starting MCP: $srv"
                    mcp_start "$srv" >/dev/null 2>&1 || true
                done
                echo "[✓] MCP servers pre-warmed."
            fi
        fi
        ;;
    stop|down)
        echo "[+] Stopping active autonomic cron sweeps..."
        curl -s -X POST http://localhost:3000/api/cron/daemon/stop >/dev/null 2>&1 || true

        echo "[+] Gracefully stopping Sovereign Infrastructure..."
        docker compose stop
        docker compose ps

        echo "[+] Stopping host-level george-web sidecars..."
        pkill -f "george-web" 2>/dev/null || true
        echo "[✓] All Sovereign services stopped."
        ;;
    rebuild)
        echo "[+] Rebuilding container layers and starting..."
        docker compose up -d --build
        docker compose ps
        ;;
    status|ps)
        echo "=== Docker Compose Services ==="
        docker compose ps
        echo ""
        echo "=== Sovereign Web Sidecar ==="
        if pgrep -f "george-web" >/dev/null 2>&1; then
            echo "[✓] george-web: RUNNING (PID $(pgrep -f "george-web" | head -1)) on http://localhost:3000"
        else
            echo "[ ] george-web: STOPPED"
        fi
        echo ""
        echo "=== Registered MCP Servers ==="
        if [ -f "$LODGE_DIR/lib/mcp.sh" ]; then
            source "$LODGE_DIR/lib/mcp.sh" 2>/dev/null || true
            if declare -f mcp_server_names >/dev/null; then
                for srv in $(mcp_server_names); do
                    if [ -f "$LODGE_DIR/.george/mcp/run/$srv/pid" ] && kill -0 "$(cat "$LODGE_DIR/.george/mcp/run/$srv/pid")" 2>/dev/null; then
                        echo "  [● ONLINE]  $srv"
                    else
                        echo "  [○ IDLE]    $srv (on-demand)"
                    fi
                done
            fi
        fi
        ;;
    logs)
        shift
        docker compose logs -f "${@:-}"
        ;;
    *)
        echo "Usage: ./scripts/compose.sh [start [--mcp|--all]|stop|rebuild|status|logs]"
        exit 1
        ;;
esac
