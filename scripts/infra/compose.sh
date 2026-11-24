#!/bin/bash
# ── Sovereign Infrastructure & Sidecar Manager ──────────────────
# Default execution policy: NEVER rebuild or pull unless explicitly flagged with 'rebuild'.

set -euo pipefail
LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$LODGE_DIR"

CMD="${1:-status}"

case "$CMD" in
    start|up)
        echo "[+] Starting Docker Infrastructure (--no-build)..."
        docker compose up -d --no-build
        docker compose ps

        # Ensure Kali Linux Tyler container, Canary Honeypot daemon, and ARP Shield are active
        if [ -f "$LODGE_DIR/lib/sys/kali_tyler_ctl.sh" ]; then
            echo "[+] Ensuring Kali Linux Tyler container (george-kali-tyler) & Active Immune System..."
            source "$LODGE_DIR/lib/sys/kali_tyler_ctl.sh" && kali_tyler_ensure_running || true
            python3 "$LODGE_DIR/lib/tools/tyler_guardian.py" canary --action start >/dev/null 2>&1 || true
            python3 "$LODGE_DIR/lib/tools/tyler_guardian.py" arp-shield --action enforce >/dev/null 2>&1 || true
        fi

        # Verify Kokoro-82M & Piper ONNX voice models
        if [ -x "$LODGE_DIR/scripts/infra/ensure_tts_models.sh" ]; then
            "$LODGE_DIR/scripts/infra/ensure_tts_models.sh" || true
        fi

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
            export MCP_ENABLED=1
            source "$LODGE_DIR/lib/tools/mcp.sh" 2>/dev/null || true
            mcp_init 2>/dev/null || true
            _mcp_ensure_builtin_servers 2>/dev/null || true
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
        echo "[+] Stopping active autonomic cron sweeps & Tyler Canary daemon..."
        curl -s -X POST http://localhost:3000/api/cron/daemon/stop >/dev/null 2>&1 || true
        python3 "$LODGE_DIR/lib/tools/tyler_guardian.py" canary --action stop >/dev/null 2>&1 || true

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
        echo "=== The Tyler (Kali Linux & Active Immune System) ==="
        if docker inspect -f '{{.State.Running}}' george-kali-tyler 2>/dev/null | grep -q true; then
            echo "[✓] george-kali-tyler: RUNNING (host network Layer-2 eth0)"
        else
            echo "[ ] george-kali-tyler: STOPPED"
        fi
        if pgrep -f "tyler_guardian.py canary-daemon" >/dev/null 2>&1; then
            echo "[✓] Tyler Canary Honeypot: RUNNING (ports 2222, 2323, 4445, 6379)"
        else
            echo "[ ] Tyler Canary Honeypot: STOPPED"
        fi
        echo ""
        echo "=== Sovereign Neural TTS Models (.george/models/tts) ==="
        if [ -f "$LODGE_DIR/.george/models/tts/kokoro-v1.0.onnx" ] && [ -f "$LODGE_DIR/.george/models/tts/voices-v1.0.bin" ]; then
            echo "[✓] Kokoro-82M (FP32 + INT8) & Piper VITS ONNX voices: READY"
        else
            echo "[ ] Kokoro-82M / Piper ONNX voices: MISSING (run scripts/infra/ensure_tts_models.sh)"
        fi
        echo ""
        echo "=== Sovereign Web Sidecar ==="
        if pgrep -f "george-web" >/dev/null 2>&1; then
            echo "[✓] george-web: RUNNING (PID $(pgrep -f "george-web" | head -1)) on http://localhost:3000"
        else
            echo "[ ] george-web: STOPPED"
        fi
        echo ""
        echo "=== Registered MCP Servers ==="
        if [ -f "$LODGE_DIR/lib/tools/mcp.sh" ]; then
            source "$LODGE_DIR/lib/tools/mcp.sh" 2>/dev/null || true
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
        echo "Usage: ./scripts/infra/compose.sh [start [--mcp|--all]|stop|rebuild|status|logs]"
        exit 1
        ;;
esac
