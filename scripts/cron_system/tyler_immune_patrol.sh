#!/usr/bin/env bash
# INTERVAL: 900
# SCOPE: system
# DESC: The Tyler 15-Minute Silent Immune System Patrol (Canary Honeypot + Custom tshark Watchlist + ARP Integrity + 30d Rolling Prune)
# CREATED: 2026-11-08

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
PY_BIN="$LODGE_DIR/.venv/bin/python"
[ -x "$PY_BIN" ] || PY_BIN="python3"

# 1. Ensure the Canary Honeypot Decoy listener daemon is armed
"$PY_BIN" "$LODGE_DIR/lib/tools/tyler_guardian.py" canary --action start >/dev/null 2>&1 || true

# 2. Enforce Layer-2 static ARP shield for critical LAN infrastructure
"$PY_BIN" "$LODGE_DIR/lib/tools/tyler_guardian.py" arp-shield --action enforce >/dev/null 2>&1 || true

# 3. Execute 10-second East-West tshark watchlist + ARP + Canary patrol & 30-day rolling DB/PCAP cull
#    (Zero LLM tokens burned when clean; emits authenticated webhook to /api/webhooks/tyler on anomaly)
"$PY_BIN" "$LODGE_DIR/lib/tools/tyler_guardian.py" immune-patrol --duration 10

