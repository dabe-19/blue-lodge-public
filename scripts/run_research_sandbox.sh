#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# George Research Sandbox Runner (Compatibility Layer)
# ══════════════════════════════════════════════════════════════════════
# Invokes general research_sandbox.sh engine and optionally dispatches
# output artifact to recipient via transport helper.
# ══════════════════════════════════════════════════════════════════════

set -euo pipefail
LODGE_DIR="${LODGE_DIR:-/home/wsl-ops/blue-lodge}"

TOPIC="${1:-}"
OUTPUT_FILE="${2:-}"
RECIPIENT="${3:-}"

if [ -z "$TOPIC" ]; then
    echo "Usage: run_research_sandbox.sh \"<topic>\" [output_file] [recipient]" >&2
    exit 1
fi

"$LODGE_DIR/scripts/research_sandbox.sh" "$TOPIC" 3 "$OUTPUT_FILE"

if [ -n "$RECIPIENT" ] && [ -n "$OUTPUT_FILE" ] && [ -f "$OUTPUT_FILE" ]; then
    "$LODGE_DIR/scripts/discord_send_report.sh" "$RECIPIENT" "$OUTPUT_FILE" 2>/dev/null || \
    python3 "$LODGE_DIR/scripts/discord_send_report.py" "$RECIPIENT" "$OUTPUT_FILE" 2>/dev/null || true
fi
