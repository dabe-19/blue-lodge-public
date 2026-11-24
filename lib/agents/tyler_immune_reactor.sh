#!/usr/bin/env bash
# ── George: The Tyler Active Immune System Event Reactor (rx_tyler_immune) ──
# Handles adverse network events from the FIFO Event Bus:
#   - network.canary_triggered
#   - network.tshark_watch_hit
#   - network.lateral_movement
#   - network.arp_spoof
#   - network.baseline_drift
#
# Workflow:
#   1. Captures a Tier A forensic_snap (.pcap + conntrack) for the offending LAN IP.
#   2. Evaluates .george/state/tyler_policy.json (confirm vs auto):
#      - confirm (default): Stages a Cardano-style Tier B Defense Plan (DEF-xxxx) in
#        lan_devices.db and dispatches a Discord DM alert to the operator (plus spawns
#        a non-colliding George ReAct triage turn when the inference slot is free).
#      - auto: Executes containment immediately (protected IPs remain strictly immune)
#        and notifies the operator on Discord.

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
PY_BIN="$LODGE_DIR/.venv/bin/python"
[ -x "$PY_BIN" ] || PY_BIN="python3"

REACTOR_LOG="$GEORGE_DIR/logs/tyler_immune_reactor.log"
LOCK_FILE="$GEORGE_DIR/state/tyler_immune_reactor.lock"
mkdir -p "$(dirname "$REACTOR_LOG")" "$GEORGE_DIR/state" 2>/dev/null || true

source "$LODGE_DIR/lib/comms/discord_bridge.sh" 2>/dev/null || true
[ -f "$GEORGE_DIR/keys.conf" ] && source "$GEORGE_DIR/keys.conf" 2>/dev/null || true

tyler_immune_event_ingress() {
    local evt_type="${1:-network.alert}"
    local evt_payload="${2:-{}}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    local src_ip rule_name dst_port resp_mode
    src_ip=$(printf '%s' "$evt_payload" | jq -r '.ip // .data.ip // empty' 2>/dev/null || true)
    rule_name=$(printf '%s' "$evt_payload" | jq -r '.rule_name // .data.rule_name // .service // empty' 2>/dev/null || true)
    dst_port=$(printf '%s' "$evt_payload" | jq -r '.port // .data.port // empty' 2>/dev/null || true)
    resp_mode=$(jq -r '.response_mode // "confirm"' "$GEORGE_DIR/state/tyler_policy.json" 2>/dev/null || echo "confirm")

    printf '[%s] [RX_TYLER_IMMUNE] event=%s ip=%s rule=%s port=%s mode=%s\n' \
        "$ts" "$evt_type" "${src_ip:-none}" "${rule_name:-none}" "${dst_port:-none}" "$resp_mode" >> "$REACTOR_LOG"

    if [ -z "$src_ip" ] || [ "$src_ip" = "127.0.0.1" ] || [ "$src_ip" = "0.0.0.0" ]; then
        return 0
    fi

    # 1. Tier A: Capture immediate forensic PCAP & conntrack snapshot
    "$PY_BIN" "$LODGE_DIR/lib/tools/tyler_guardian.py" intervene \
        --ip "$src_ip" --mode forensic_snap --duration 4 >> "$REACTOR_LOG" 2>&1 || true

    # 2. Stage Tier B Defense Plan (or auto-execute if response_mode == "auto")
    local rationale="quarantine: Triggered by ${evt_type}${rule_name:+ (rule: $rule_name)}${dst_port:+ (port: $dst_port)}"
    local plan_json plan_id plan_msg
    plan_json=$("$PY_BIN" "$LODGE_DIR/lib/tools/tyler_guardian.py" intervene \
        --ip "$src_ip" --mode propose_plan --rationale "$rationale" 2>/dev/null || echo '{}')
    plan_id=$(printf '%s' "$plan_json" | jq -r '.plan_id // "DEF-PENDING"' 2>/dev/null || echo "DEF-PENDING")
    plan_msg=$(printf '%s' "$plan_json" | jq -r '.message // ""' 2>/dev/null || true)

    # 3. Notify operator via Discord DM if configured
    if [ -n "${DISCORD_DM_USER_ID:-}" ] && [ "$DISCORD_DM_USER_ID" != "none" ] && declare -f discord_dm &>/dev/null; then
        local dm_text
        if [ "$resp_mode" = "auto" ]; then
            dm_text="🛡️ **The Tyler // Autonomous T-Cell Response** (\`$evt_type\`)\n- **Target IP**: \`$src_ip\`\n- **Plan ID**: \`$plan_id\`\n- **Status**: Auto-Response executed ($plan_msg)."
        else
            dm_text="⚠️ **The Tyler // Tier B Defense Plan Staged** (\`$evt_type\`)\n- **Target IP**: \`$src_ip\` ${rule_name:+(Rule: \`$rule_name\`)}${dst_port:+(Port: \`$dst_port\`)}\n- **Plan ID**: \`$plan_id\` (Proposed: \`quarantine\`)\n- **Action Required**: Review & click **Approve** or **Reject** in the Tyler Web UI, or ask George: \`approve defense plan $plan_id\`."
        fi
        discord_dm "$DISCORD_DM_USER_ID" "$dm_text" >> "$REACTOR_LOG" 2>&1 || true
    fi

    # 4. If in 'confirm' mode and no other George ReAct task is active, spawn a bounded forensic enrichment pass
    if [ "$resp_mode" = "confirm" ]; then
        (
            exec 9>"$LOCK_FILE"
            if flock -n 9; then
                "$PY_BIN" "$LODGE_DIR/lib/tools/tyler_guardian.py" fingerprint --ip "$src_ip" >> "$REACTOR_LOG" 2>&1 || true
            fi
        ) &
    fi

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    tyler_immune_event_ingress "${1:-network.canary_triggered}" "${2:-"{}"}"
fi

