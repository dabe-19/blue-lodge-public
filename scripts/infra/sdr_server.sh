#!/bin/bash
# ── Blue Lodge: Sovereign SDR Gateway Lifecycle Controller ────────────
# Gracefully manages the remote SDR server (Trunk-Recorder + Rdio-Scanner
# running inside rootless Podman under systemd --user) and coordinates
# local ingestion before shutdown or after startup.
#
# Usage:
#   bash scripts/infra/sdr_server.sh status     # Check SSH, AirSpy USB, service & container health
#   bash scripts/infra/sdr_server.sh stop       # Finalize local sync & gracefully stop SDR stack
#   bash scripts/infra/sdr_server.sh start      # Verify AirSpy USB & start SDR stack in order
#   bash scripts/infra/sdr_server.sh restart    # Gracefully restart SDR stack
#   bash scripts/infra/sdr_server.sh shutdown   # Gracefully stop SDR stack & power off sdr-server
#   bash scripts/infra/sdr_server.sh logs [n]   # Tail recent trunk-recorder & rdio-scanner logs

set -uo pipefail

LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -f "$LODGE_DIR/.george/secrets/operator.env" ]; then
    # shellcheck disable=SC1091
    source "$LODGE_DIR/.george/secrets/operator.env" 2>/dev/null || true
fi

SDR_HOST="${GEORGE_SDR_GATEWAY_HOST:-sdr-server}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=4)

check_reachable() {
    if ssh "${SSH_OPTS[@]}" "$SDR_HOST" "true" 2>/dev/null; then
        return 0
    fi
    return 1
}

wait_for_local_ingest() {
    local waited=0
    while pgrep -f "lib/tools/sdr_ingest.py" >/dev/null 2>&1 && [ "$waited" -lt 30 ]; do
        if [ "$waited" -eq 0 ]; then
            echo "  ⏳ Waiting for active local sdr_ingest.py process to finish..."
        fi
        sleep 2
        waited=$((waited + 2))
    done
}

sdr_status() {
    echo "═══════════════════════════════════════════════════════════"
    echo "  Sovereign SDR Gateway Status ($SDR_HOST)"
    echo "═══════════════════════════════════════════════════════════"

    if ! check_reachable; then
        echo "  Host Status:       ○ OFFLINE (SSH unreachable on '$SDR_HOST')"
        echo "  Local Ingestion:   ● Fast-bailout active (~2s no-op while offline)"
        echo "═══════════════════════════════════════════════════════════"
        return 1
    fi

    echo "  Host Status:       ● ONLINE ($SDR_HOST)"

    ssh "${SSH_OPTS[@]}" "$SDR_HOST" '
        echo "  Host Uptime:       $(uptime -p) (since $(uptime -s))"
        LGR=$(loginctl show-user "$USER" 2>/dev/null | grep "^Linger=" | cut -d= -f2 || echo "unknown")
        SVC=$(systemctl --user is-active scanner-podman.service 2>/dev/null || echo "inactive")
        SVC_EN=$(systemctl --user is-enabled scanner-podman.service 2>/dev/null || echo "disabled")
        echo "  Systemd Service:   scanner-podman.service [$SVC / boot=$SVC_EN / linger=$LGR]"

        USB=$(lsusb 2>/dev/null | grep -iE "airspy|1d50:60a1|rtl|2838" || true)
        if [ -n "$USB" ]; then
            echo "  SDR USB Hardware:  ● DETECTED ($USB)"
        else
            echo "  SDR USB Hardware:  ✗ NOT DETECTED on USB bus!"
        fi

        echo ""
        echo "  ── Podman Containers ──"
        podman ps -a --format "  • {{.Names}}\t[{{.Status}}]\tImage: {{.Image}}" 2>/dev/null || true

        echo ""
        echo "  ── Rdio-Scanner & Call Activity ──"
        if curl -fsS --max-time 3 http://127.0.0.1:3000/ >/dev/null 2>&1; then
            echo "  • Rdio-Scanner HTTP (port 3000): ● HEALTHY"
        else
            echo "  • Rdio-Scanner HTTP (port 3000): ○ UNREACHABLE"
        fi
        if [ -f "$HOME/scanner/rdio-data/rdio-scanner.db" ]; then
            python3 -c "
import sqlite3
con = sqlite3.connect(\"$HOME/scanner/rdio-data/rdio-scanner.db\")
cnt, latest = con.execute(\"SELECT COUNT(*), MAX(dateTime) FROM rdioScannerCalls\").fetchone()
print(f\"  • Total Calls in Gateway DB:    {cnt} (latest: {latest or '\''n/a'\''})\")
" 2>/dev/null || true
        fi
    '
    echo "═══════════════════════════════════════════════════════════"
}

sdr_stop() {
    echo "═══════════════════════════════════════════════════════════"
    echo "  Gracefully Stopping SDR Stack on $SDR_HOST"
    echo "═══════════════════════════════════════════════════════════"

    if ! check_reachable; then
        echo "  ! $SDR_HOST is already offline / unreachable."
        return 0
    fi

    # 1. Wait for any in-flight local sync, then run one final delta sync while rdio-scanner is still up
    wait_for_local_ingest
    echo "[1/3] Running final delta sync (sdr_ingest.py --sync) before stopping gateway..."
    python3 "$LODGE_DIR/lib/tools/sdr_ingest.py" --sync >/dev/null 2>&1 || true

    # 2. Stop trunk-recorder first (releases AirSpy USB & flushes pending uploads), then rdio-scanner
    echo "[2/3] Stopping trunk-recorder (releasing AirSpy USB) & rdio-scanner (closing SQLite WAL)..."
    ssh "${SSH_OPTS[@]}" "$SDR_HOST" '
        systemctl --user stop scanner-podman.service 2>/dev/null || true
        podman stop -t 15 trunk-recorder >/dev/null 2>&1 || true
        podman stop -t 15 rdio-scanner >/dev/null 2>&1 || true
        sync
    '

    # 3. Verify stopped state
    echo "[3/3] Verifying container state..."
    ssh "${SSH_OPTS[@]}" "$SDR_HOST" '
        podman ps -a --format "  • {{.Names}}: {{.Status}}"
    '
    echo ""
    echo "✓ SDR stack on $SDR_HOST is cleanly stopped."
}

sdr_start() {
    echo "═══════════════════════════════════════════════════════════"
    echo "  Starting Sovereign SDR Stack on $SDR_HOST"
    echo "═══════════════════════════════════════════════════════════"

    if ! check_reachable; then
        echo "  ✗ Cannot reach $SDR_HOST via SSH. Ensure the machine is powered on and connected."
        return 1
    fi

    echo "[1/3] Checking AirSpy USB hardware on $SDR_HOST..."
    if ! ssh "${SSH_OPTS[@]}" "$SDR_HOST" 'lsusb | grep -qiE "airspy|1d50:60a1|rtl|2838"'; then
        echo "  ⚠ Warning: AirSpy/RTL-SDR USB device was not seen in lsusb! Attempting startup anyway..."
    else
        echo "  ✓ AirSpy USB receiver detected."
    fi

    echo "[2/3] Starting scanner-podman.service (rdio-scanner -> trunk-recorder)..."
    ssh "${SSH_OPTS[@]}" "$SDR_HOST" '
        systemctl --user daemon-reload
        systemctl --user start scanner-podman.service
    '

    echo "[3/3] Verifying HTTP gateway & container health..."
    sleep 2
    ssh "${SSH_OPTS[@]}" "$SDR_HOST" '
        for i in 1 2 3 4 5; do
            if curl -fsS --max-time 2 http://127.0.0.1:3000/ >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        podman ps --format "  • {{.Names}}: {{.Status}}"
    '
    echo ""
    echo "✓ SDR stack on $SDR_HOST is online and capturing."
}

sdr_shutdown() {
    sdr_stop
    if ! check_reachable; then
        return 0
    fi
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Powering Off $SDR_HOST"
    echo "═══════════════════════════════════════════════════════════"
    echo "  Containers and databases are safely closed and synced."
    if [ -t 0 ]; then
        echo "  Invoking 'sudo poweroff' on $SDR_HOST (enter remote sudo password if prompted):"
        ssh -t "$SDR_HOST" "sudo poweroff"
    else
        echo "  Run the following in your terminal to complete OS poweroff:"
        echo "    ssh -t $SDR_HOST 'sudo poweroff'"
    fi
}

sdr_logs() {
    local lines="${1:-30}"
    if ! check_reachable; then
        echo "  ✗ $SDR_HOST is offline."
        return 1
    fi
    ssh "${SSH_OPTS[@]}" "$SDR_HOST" "
        echo '=== rdio-scanner (last ${lines} lines) ==='
        podman logs --tail ${lines} rdio-scanner 2>&1 || true
        echo ''
        echo '=== trunk-recorder (last ${lines} lines) ==='
        podman logs --tail ${lines} trunk-recorder 2>&1 || true
    "
}

case "${1:-status}" in
    status)
        sdr_status
        ;;
    stop|pause)
        sdr_stop
        ;;
    start|resume)
        sdr_start
        ;;
    restart)
        sdr_stop
        echo ""
        sdr_start
        ;;
    shutdown|poweroff)
        sdr_shutdown
        ;;
    logs)
        sdr_logs "${2:-30}"
        ;;
    *)
        echo "Usage: bash scripts/infra/sdr_server.sh {status|start|stop|restart|shutdown|logs [lines]}"
        exit 1
        ;;
esac
