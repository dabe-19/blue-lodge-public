#!/bin/bash
# ── Autonomic Cron Trigger: Sovereign Loan Fund surveillance loop ──
# INTERVAL: 300
# ENABLED: 1
# SCOPE: system
# DESC: Loan fund surveillance: loan book servicing (dry run), fund opportunities, DEX round-trip spreads, Polymarket complete sets
#
# Every input below is live (chain / market APIs). Nothing here broadcasts: loan servicing runs as a
# dry run so George (or the operator) can decide to execute via lending_service(execute=true), which
# is still capped by .george/wallets/policy.json.
# The Polymarket scan is throttled to every 30 minutes (it is a public API and edges are rare).

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

_PY_BIN="$LODGE_DIR/.venv/bin/python"
[ -f "$_PY_BIN" ] || _PY_BIN="python3"
export PYTHONPATH="$LODGE_DIR"

_LOG_FILE="${CRON_JOB_LOG:-$LODGE_DIR/.george/logs/cron/sovereign_trading_loop.log}"
_STATUS_FILE="$LODGE_DIR/.george/wallets/sovereign_trading_status.json"
_DOSSIER_FILE="$LODGE_DIR/dossiers/finance/cardano_live_opportunities.md"
_POLY_CACHE="$LODGE_DIR/.george/finance/polymarket_scan_last.json"
mkdir -p "$(dirname "$_LOG_FILE")" "$LODGE_DIR/.george/wallets" "$LODGE_DIR/.george/finance" "$LODGE_DIR/dossiers/finance" 2>/dev/null

_NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$_NOW] [START] Sovereign Loan Fund surveillance sweep" >> "$_LOG_FILE"

_json_or() { # $1 = candidate JSON, $2 = fallback
    if [ -n "$1" ] && printf '%s' "$1" | jq -e . >/dev/null 2>&1; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# ── 1. Loan book + servicing dry run ──────────────────────────────────
_BOOK=$(_json_or "$("$_PY_BIN" "$LODGE_DIR/lib/tools/sovereign_lending.py" book 2>/dev/null)" '{"loans":[],"by_status":{}}')
_SERVICE='{"results":[]}'
if [ "$(printf '%s' "$_BOOK" | jq '.count // 0')" -gt 0 ]; then
    _SERVICE=$(_json_or "$("$_PY_BIN" "$LODGE_DIR/lib/tools/sovereign_lending.py" service --actor=george 2>/dev/null)" '{"results":[]}')
fi
_OPEN_LOANS=$(printf '%s' "$_BOOK" | jq '[.loans[]? | select(.status=="AWAITING_COLLATERAL" or .status=="FUNDED" or .status=="MARGIN_CALL")] | length')
_LOAN_ACTIONS=$(printf '%s' "$_SERVICE" | jq '[.results[]? | select((.actions // []) | map(test("would|dry run")) | any)] | length')

# ── 2. Fund opportunities ─────────────────────────────────────────────
_OPPS=$(_json_or "$("$_PY_BIN" "$LODGE_DIR/lib/tools/sovereign_fund.py" opportunities --json 2>/dev/null)" '{"opportunities":[]}')
_STATE=$(_json_or "$("$_PY_BIN" "$LODGE_DIR/lib/tools/sovereign_fund.py" state --json 2>/dev/null)" '{}')

# ── 3. Legacy flash sniper retired (non-viable under eUTxO batcher model) ──
_SNIPES='[]'
_VIABLE_SNIPES=0

# ── 4. Polymarket complete sets (delegated to private mod-sovereign-alpha if installed) ──
_POLY='{}'
_POLY_SCRIPT="$LODGE_DIR/.george/modules/sovereign-alpha/strategies/scale_gated/polymarket_probability_arbitrageur.py"
if [ -f "$_POLY_SCRIPT" ] && { [ ! -f "$_POLY_CACHE" ] || [ $(( $(date +%s) - $(stat -c %Y "$_POLY_CACHE") )) -ge 1800 ]; }; then
    _P=$("$_PY_BIN" "$_POLY_SCRIPT" --json 2>/dev/null)
    if printf '%s' "$_P" | jq -e '.status=="ok"' >/dev/null 2>&1; then
        printf '%s' "$_P" | jq -c '{status, timestamp, scanned, viable, budget_usdc, opportunities: ([.opportunities[]? | {question, url, net_edge_pct, viable, blockers}] | sort_by(-.net_edge_pct) | .[:10])}' > "$_POLY_CACHE"
    fi
fi
[ -f "$_POLY_CACHE" ] && _POLY=$(_json_or "$(cat "$_POLY_CACHE")" '{}')
_VIABLE_POLY=$(printf '%s' "$_POLY" | jq '.viable // 0')

# ── 5. Sovereign DEX Desk: Triple-Engine Active Positions ─────────────
_DEX_DESK=$(_json_or "$("$_PY_BIN" "$LODGE_DIR/lib/tools/cardano_desk_summary.py" SNEK --json 2>/dev/null)" '{"resting_orders":[],"armed_stops":[],"treasury":{}}')
_RESTING_COUNT=$(printf '%s' "$_DEX_DESK" | jq '(.resting_orders // []) | length')
_ARMED_STOPS_COUNT=$(printf '%s' "$_DEX_DESK" | jq '(.armed_stops // []) | length')
_DEX_COMMITTED_ADA=$(printf '%s' "$_DEX_DESK" | jq '(.treasury.total_committed_capital_ada // 0)')

# ── Unified state (summary keys kept for /api/finance/loop + context engine) ──
_UNIFIED_PAYLOAD=$(jq -n \
  --arg now "$_NOW" \
  --argjson book "$_BOOK" --argjson service "$_SERVICE" --argjson opps "$_OPPS" --argjson state "$_STATE" \
  --argjson snipes "$_SNIPES" --argjson poly "$_POLY" --argjson desk "$_DEX_DESK" \
  --argjson open_loans "${_OPEN_LOANS:-0}" --argjson loan_actions "${_LOAN_ACTIONS:-0}" \
  --argjson viable_snipes "${_VIABLE_SNIPES:-0}" --argjson viable_poly "${_VIABLE_POLY:-0}" \
  --argjson resting_count "${_RESTING_COUNT:-0}" --argjson armed_stops_count "${_ARMED_STOPS_COUNT:-0}" \
  --argjson dex_committed_ada "${_DEX_COMMITTED_ADA:-0}" \
  '{
    timestamp: $now,
    status: "ok",
    schema: "sovereign_fund_loop/v2",
    summary: {
      approved_loans_count: $open_loans,
      loans_needing_action: $loan_actions,
      fund_opportunities: ($opps.opportunities | length),
      fund_nav: ($state.nav // {}),
      viable_flash_snipes_count: $viable_snipes,
      viable_polymarket_arb_count: $viable_poly,
      dex_resting_orders_count: $resting_count,
      dex_armed_stops_count: $armed_stops_count,
      dex_committed_capital_ada: $dex_committed_ada
    },
    loan_book: $book,
    loan_service_dry_run: $service,
    fund_opportunities: $opps.opportunities,
    dex_sniping: $snipes,
    polymarket: $poly,
    dex_desk: $desk
  }')

printf '%s\n' "$_UNIFIED_PAYLOAD" > "$_STATUS_FILE"

# ── Dossier (markdown, regenerated each sweep) ────────────────────────
{
    echo "# Sovereign Loan Fund — Live Surveillance"
    echo "**Last sweep:** $_NOW  "
    echo "**Open loans:** ${_OPEN_LOANS:-0} | **Loans needing action:** ${_LOAN_ACTIONS:-0} | **Viable DEX round-trips:** ${_VIABLE_SNIPES:-0} | **Viable Polymarket sets:** ${_VIABLE_POLY:-0}"
    echo "**DEX Positioning:** ${_RESTING_COUNT:-0} resting Plutus limit orders | ${_ARMED_STOPS_COUNT:-0} armed breakout stops (${_DEX_COMMITTED_ADA:-0} ADA committed)"
    echo
    echo "## 1. Fund opportunities (ranked)"
    printf '%s' "$_OPPS" | jq -r '.opportunities[]? | "- **P\(.priority) \(.title)**" + (if .detail then " — \(.detail)" else "" end) + (if .action and .action != "informational" then " → `\(.action)`" else "" end)'
    echo
    echo "## 2. Loan book"
    printf '%s' "$_BOOK" | jq -r 'if (.loans|length)==0 then "- (empty)" else .loans[] | "- **\(.id)** \(.status): \(.principal) \(.principal_asset) vs \(.collateral_units) \(.collateral_asset) @ \(.apr_pct)% / \(.term_days)d" end'
    printf '%s' "$_SERVICE" | jq -r '.results[]? | "  - service \(.loan_id): \((.actions // []) | join("; "))"'
    echo
    echo "## 3. DEX round-trip spreads (after all frictions)"
    printf '%s' "$_SNIPES" | jq -r '.[]? | "- **\(.asset)**: buy \(.buy_dex) → sell \(.sell_dex) | gross \(.gross_spread_pct)% | net \(.net_profit_ada) ADA | viable: \(.viable)"'
    echo
    echo "## 4. Polymarket complete sets"
    printf '%s' "$_POLY" | jq -r '"- scanned \(.scanned // 0), viable \(.viable // 0)", (.opportunities[]? | select(.net_edge_pct > -0.5) | "- \(.question): edge \(.net_edge_pct)%")'
    echo
    echo "## 5. Sovereign DEX Desk — Active Positioning & Coverage Triangle"
    "$_PY_BIN" "$LODGE_DIR/lib/tools/cardano_desk_summary.py" SNEK 2>/dev/null || echo "*(DEX Desk summary unavailable)*"
} > "$_DOSSIER_FILE"

echo "[$_NOW] [SUMMARY] open loans ${_OPEN_LOANS:-0} | loan actions ${_LOAN_ACTIONS:-0} | opps $(printf '%s' "$_OPPS" | jq '.opportunities|length') | snipes ${_VIABLE_SNIPES:-0} | poly ${_VIABLE_POLY:-0} | dex orders ${_RESTING_COUNT:-0} | stops ${_ARMED_STOPS_COUNT:-0}" >> "$_LOG_FILE"

# ── Alert only on actionable items ────────────────────────────────────
if [ "${_VIABLE_SNIPES:-0}" -gt 0 ] || [ "${_LOAN_ACTIONS:-0}" -gt 0 ] || [ "${_VIABLE_POLY:-0}" -gt 0 ]; then
    event_bus_emit "sovereign_trading_tick" "$(printf '%s' "$_UNIFIED_PAYLOAD" | jq -c '{timestamp, summary, loan_service_dry_run}')" "sovereign_trading_loop" 2>/dev/null || true
    echo "[$_NOW] [EMIT] Dispatched sovereign_trading_tick to event bus." >> "$_LOG_FILE"
fi

exit 0
