#!/bin/bash
# INTERVAL: 43200
# DESC: Twice-daily deep research report on top US health insurance providers (UnitedHealth, Elevance/CVS Aetna, Humana) financial performance.
#        Executes as a /lodge one-shot task inside the sandbox (research dossier + Discord delivery).

LODGE_DIR="${LODGE_DIR:-/home/wsl-ops/blue-lodge}"
TOPIC="US Health Insurance Providers Financial Performance & Quarterly Results: UnitedHealth Group (UNH), Elevance Health / CVS Caremark (Aetna), and Humana. Latest earnings, margins, claims trends, and analyst outlooks from the most recent fiscal quarter. Include specific revenue figures, EPS vs estimates, stock price reactions, and key risk factors for each provider."
OUTPUT_FILE="/tmp/health_insurance_intel_$(date +%Y%m%d_%H%M).md"
CHANNEL_TARGET="general"

# Resolve Discord channel ID for the delivery instruction (best-effort)
source "$LODGE_DIR/lib/discord_bridge.sh" 2>/dev/null || true
target_ch_id="${target_ch_id:-$(discord_channel_resolve "$CHANNEL_TARGET" 2>/dev/null || true)}"
if [ -z "$target_ch_id" ] && command -v sqlite3 >/dev/null 2>&1 && [ -f "$LODGE_DIR/.george/discord_channels.db" ]; then
    target_ch_id=$(sqlite3 "$LODGE_DIR/.george/discord_channels.db" "SELECT channel_id FROM channels WHERE name='$CHANNEL_TARGET' LIMIT 1;" 2>/dev/null || true)
fi

TASK="Run the research_sandbox tool with sample_size 3 and output_file '$OUTPUT_FILE' for the topic: \"$TOPIC\". Then read the generated dossier and send a summary of it to Discord channel '$CHANNEL_TARGET' (channel id: ${target_ch_id:-general})."

# Kick off a sandboxed task via the /lodge binary (one-shot agentic execution)
exec "$LODGE_DIR/lodge" "$TASK"
