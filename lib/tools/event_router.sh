#!/bin/bash
# ── George: Event Router & Reactive Bus Entrypoint ────────────────────────────
# Entrypoint for running the Sovereign POSIX Reactive Event Bus router.
# Supports both foreground execution (for systemd / container managers)
# and detached daemon mode.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

# Load secrets and local environment if present
if [ -f "$GEORGE_DIR/secrets.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$GEORGE_DIR/secrets.env"
    set +a
elif [ -f "$LODGE_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$LODGE_DIR/.env"
    set +a
fi

# Source event bus engine
# shellcheck disable=SC1091
source "$LODGE_DIR/lib/ipc/event_bus.sh"

cmd="${1:-status}"

case "$cmd" in
    run|--foreground|-f)
        event_bus_init
        echo "[EVENT_ROUTER] Starting POSIX Event Bus in foreground (PID: $$)..."
        echo "$$" > "$EVENT_BUS_PID_FILE"
        exec event_bus_dispatch_loop
        ;;
    start)
        event_bus_start
        ;;
    stop)
        event_bus_stop
        ;;
    restart)
        event_bus_stop
        sleep 0.2
        event_bus_start
        ;;
    status)
        event_bus_status
        ;;
    *)
        echo "Usage: $0 {run|start|stop|restart|status}"
        exit 1
        ;;
esac
