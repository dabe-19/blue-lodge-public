#!/bin/bash
# ── George: Sovereign Trading Reactive Event Handler ──────────────────────────
# Handles 'sovereign_trading_tick' events emitted from the 3-pillar trading loop.
# Logs opportunities, maintains live intelligence, and dispatches alerts.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
TRADING_LOG="$GEORGE_DIR/trading/live_opportunities.log"
ALERTS_DIR="$GEORGE_DIR/notifications"
mkdir -p "$(dirname "$TRADING_LOG")" "$ALERTS_DIR" 2>/dev/null || true

trading_event_ingress() {
    local evt_type="${1:-}"
    local evt_payload="${2:-}"

    [ -z "$evt_payload" ] && return 0

    local n_snipes n_loans n_poly ts
    n_snipes=$(echo "$evt_payload" | jq -r '.summary.viable_flash_snipes_count // 0' 2>/dev/null || echo 0)
    n_loans=$(echo "$evt_payload" | jq -r '.summary.approved_loans_count // 0' 2>/dev/null || echo 0)
    n_poly=$(echo "$evt_payload" | jq -r '.summary.viable_polymarket_arb_count // 0' 2>/dev/null || echo 0)
    ts=$(echo "$evt_payload" | jq -r '.timestamp // empty' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')

    # If no actionable opportunities, exit silently
    if [ "$n_snipes" -le 0 ] && [ "$n_loans" -le 0 ] && [ "$n_poly" -le 0 ]; then
        return 0
    fi

    local log_line="[$ts] [OPPORTUNITY_ALERT] Viable Opportunities Detected: ${n_snipes} DEX Snipes, ${n_loans} P2P Loans, ${n_poly} Polymarket Arbs"
    echo "$log_line" >> "$TRADING_LOG"

    # Extract top snipe details
    local top_snipe_desc=""
    if [ "$n_snipes" -gt 0 ]; then
        top_snipe_desc=$(echo "$evt_payload" | jq -r '.dex_sniping[]? | select(.viable == true) | .asset + " (Buy " + .buy_dex + " -> Sell " + .sell_dex + ", Net Profit: +" + (.net_profit_ada|tostring) + " ADA)"' 2>/dev/null | head -n 2 | paste -sd ", " -)
        [ -n "$top_snipe_desc" ] && echo "  -> Top Snipes: $top_snipe_desc" >> "$TRADING_LOG"
    fi

    # Record notification file for Sentinel and UI
    local notif_file="$ALERTS_DIR/trading_alert_latest.json"
    cat << EOF > "$notif_file"
{
  "timestamp": "$ts",
  "type": "sovereign_trading_opportunity",
  "summary": {
    "viable_snipes": $n_snipes,
    "approved_loans": $n_loans,
    "viable_poly": $n_poly
  },
  "top_snipes": "$top_snipe_desc"
}
EOF

    # If discord_dm is available and configured, notify operator
    if [ -n "${DISCORD_DM_USER_ID:-}" ] && [ "$DISCORD_DM_USER_ID" != "none" ] && declare -f discord_dm &>/dev/null; then
        local alert_msg="🚨 **George Sovereign Capital Alert** ($ts): Found $n_snipes viable Cardano DEX snipes! Top: $top_snipe_desc"
        discord_dm "$DISCORD_DM_USER_ID" "$alert_msg" 2>/dev/null || true
    fi

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trading_event_ingress "${1:-sovereign_trading_tick}" "${2:-"{}"}"
fi
