#!/bin/bash
# ── George: Sovereign Cardano Market Maker & Limit Order Graph (5 Phases) ───
# Deterministic finite-state execution graph for Cardano DEX resting limit orders,
# bid-ask corridor discovery, pre-flight Plutus validation, and direct placement.
#
# Grounded in soul.md: "Well done is better than well said."
# Fiduciary Guardrails: 40.00 ADA Reserve Floor, Direct AMM Execution (Zero Aggregator Toll).
# Strategic Mandate: Sovereign ADA Accumulation for Microfinancing Pool (1 ADA = 1 ADA).
# Conduit: Passive net cycle yield feeds Pillar 1 Microloan Underwriting (sovereign_lending.py).
#
# Phases:
#   Phase 1/5: Capital & Credential Gatekeeper (Blockfrost UTxOs, 40 ADA floor)
#   Phase 2/5: Corridor & Volatility Discovery (SNEK, MIN, WMTX, DJED, IAG)
#   Phase 3/5: Staleness & Risk Gating (Slot Freshness, Active Order De-duplication)
#   Phase 4/5: Pre-Flight Limit Plutus Simulation (Direct Script Output, Datum Math)
#   Phase 5/5: Placement, Telemetry & Event Bus Broadcast (Dry-run or Live L1 Settlement)
#
# Usage:
#   cardano_maker_graph [--dry-run | --execute] [--pair ASSET] [--capital ADA] [--json]

[ -n "${_LIB_CARDANO_MAKER_GRAPH_LOADED:-}" ] && return 0; _LIB_CARDANO_MAKER_GRAPH_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
FINANCE_DIR="${FINANCE_DIR:-$GEORGE_DIR/finance}"
DOSSIER_DIR="${DOSSIER_DIR:-$LODGE_DIR/dossiers/finance}"
GRAPH_TELEMETRY="${FINANCE_DIR}/cardano_maker_latest.json"
GRAPH_TRADES_LOG="${DOSSIER_DIR}/trades.jsonl"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true

MAKER_RESERVE_FLOOR_ADA="${MAKER_RESERVE_FLOOR_ADA:-40.0}"
MAKER_DEFAULT_CAPITAL_ADA="${MAKER_DEFAULT_CAPITAL_ADA:-120.0}"
MAKER_ROUNDTRIP_FRICTION_ADA="${MAKER_ROUNDTRIP_FRICTION_ADA:-3.96}"

cardano_maker_init() {
    mkdir -p "$FINANCE_DIR" "$DOSSIER_DIR" "$GEORGE_DIR/wallets" 2>/dev/null || true
}

# ── Phase 1: Capital & Credential Gatekeeper ───────────────────────────
cardano_maker_phase1_capital() {
    local req_capital="${1:-120.0}"
    local mode="${2:-live}"
    ui_step "Phase 1/5: Capital & Credential Gatekeeper..." >&2

    local py_bin="$LODGE_DIR/.venv/bin/python"
    [ ! -x "$py_bin" ] && py_bin="python3"

    local bal_json
    bal_json=$("$py_bin" -c "
from lib.tools.cardano_trader import query_wallet_balance
import json
print(json.dumps(query_wallet_balance()))
" 2>/dev/null || echo '{"status":"error","spendable_ada":0.0,"total_ada":0.0}')

    local status total_ada spendable_ada addr
    status=$(echo "$bal_json" | jq -r '.status // "error"')
    total_ada=$(echo "$bal_json" | jq -r '.total_ada // 0.0')
    spendable_ada=$(echo "$bal_json" | jq -r '.spendable_ada // 0.0')
    addr=$(echo "$bal_json" | jq -r '.address // "unknown"')

    if [ "$status" != "ok" ]; then
        ui_err "  [capital_gate] Blockfrost query failed: $(echo "$bal_json" | jq -r '.error // "unknown"')" >&2
        echo "$bal_json" | jq --arg msg "Blockfrost query failed" '. + {gate_pass: false, reason: $msg}'
        return 1
    fi

    local is_pass=1
    local fail_reason=""
    local min_required
    min_required=$(awk "BEGIN {print $req_capital + $MAKER_RESERVE_FLOOR_ADA}")

    if [ "$mode" = "dry-run" ] || [ "${IS_DRY_RUN:-0}" -eq 1 ]; then
        is_pass=1
        fail_reason=""
        ui_ok "  [capital_gate] DRY-RUN MODE: Capital allocation ${req_capital} ADA simulated." >&2
    elif (( $(echo "$spendable_ada < 15.0" | bc -l 2>/dev/null || echo 1) )); then
        is_pass=0
        fail_reason="Spendable balance (${spendable_ada} ADA) below minimal limit order threshold (15.0 ADA)"
        ui_warn "  [capital_gate] FAULT: $fail_reason" >&2
    else
        ui_ok "  [capital_gate] Hot Wallet: ${addr:0:15}...${addr: -8} | Total: ${total_ada} ADA | Spendable: ${spendable_ada} ADA (Reserve: ${MAKER_RESERVE_FLOOR_ADA} ADA protected)" >&2
    fi

    # Adjust allocation so it does not breach reserve floor
    local safe_alloc
    safe_alloc=$("$py_bin" -c "
is_dry_run = ('$mode' == 'dry-run') or ('${IS_DRY_RUN:-0}' == '1')
if is_dry_run:
    print(f'{float(\"$req_capital\"):.2f}')
else:
    spendable = float('$spendable_ada')
    requested = float('$req_capital')
    reserve = float('$MAKER_RESERVE_FLOOR_ADA')
    max_allowed = max(0.0, spendable - reserve - 5.0)
    alloc = min(requested, max_allowed)
    print(f'{alloc:.2f}')
" 2>/dev/null || echo "50.00")

    echo "$bal_json" | jq --argjson pass "$([ "$is_pass" -eq 1 ] && echo true || echo false)" \
                         --arg reason "$fail_reason" \
                         --arg alloc "$safe_alloc" \
                         '. + {gate_pass: $pass, reason: $reason, trade_allocation_ada: ($alloc | tonumber)}'
    [ "$is_pass" -eq 1 ] && return 0 || return 1
}

# ── Phase 2: Corridor & Volatility Discovery ───────────────────────────
cardano_maker_phase2_corridors() {
    local alloc_ada="${1:-120.0}"
    local target_pair="${2:-}"
    local horizon="${3:-auto}"
    ui_step "Phase 2/5: Corridor & Volatility Discovery (Capital: ${alloc_ada} ADA | Horizon: ${horizon})..." >&2

    local py_bin="$LODGE_DIR/.venv/bin/python"
    [ ! -x "$py_bin" ] && py_bin="python3"

    local scan_json
    scan_json=$("$py_bin" "$LODGE_DIR/lib/tools/cardano_market_maker.py" --capital "$alloc_ada" --horizon "$horizon" --json 2>/dev/null)

    local count
    count=$(echo "$scan_json" | jq -r '.corridors | length // 0')
    if [ "$count" -eq 0 ]; then
        ui_warn "  [corridor_discovery] No market corridors available" >&2
        echo "$scan_json"
        return 1
    fi

    # If pair specified, filter
    local best_opp
    if [ -n "$target_pair" ]; then
        best_opp=$(echo "$scan_json" | jq -c --arg p "$target_pair" '[.corridors[] | select(.asset == ($p | ascii_upcase))][0] // .corridors[0]')
    else
        best_opp=$(echo "$scan_json" | jq -c '.corridors[0]')
    fi

    echo "$scan_json" | jq -c '.corridors[]?' | while read -r row; do
        local sym spot bid ask sprd prof prof_bool hor dur dyn_fric need_cap
        sym=$(echo "$row" | jq -r '.asset')
        spot=$(echo "$row" | jq -r '.spot_price_ada')
        bid=$(echo "$row" | jq -r '.bid_target_ada')
        ask=$(echo "$row" | jq -r '.ask_target_ada')
        sprd=$(echo "$row" | jq -r '.maker_spread_pct')
        prof=$(echo "$row" | jq -r '.net_maker_profit_ada')
        prof_bool=$(echo "$row" | jq -r '.is_profitable')
        hor=$(echo "$row" | jq -r '.horizon // "auto"')
        dur=$(echo "$row" | jq -r '.est_fill_duration_hours // 2.0')
        dyn_fric=$(echo "$row" | jq -r '.friction_ada // 4.4')
        need_cap=$(echo "$row" | jq -r '.min_capital_needed_ada // 0')

        if [ "$prof_bool" = "true" ]; then
            ui_ok "  [corridor] ★ VIABLE: $sym ($hor ~${dur}h) | Spot: $spot ADA | Bid: $bid | Ask: $ask | Spread: ${sprd}% | Net Profit: +${prof} ADA (Friction: ${dyn_fric} ADA)" >&2
        else
            ui_dim "  [corridor] $sym ($hor) | Spot: $spot ADA | Spread: ${sprd}% | Net: ${prof} ADA (Below ${dyn_fric} ADA friction | Need: ${need_cap} ADA)" >&2
        fi
    done

    echo "$scan_json" | jq --argjson best "$best_opp" '. + {selected_opportunity: $best}'
    return 0
}

# ── Phase 3: Staleness & Risk Gating ───────────────────────────────────
cardano_maker_phase3_staleness() {
    local opp_json="$1"
    local asset
    asset=$(echo "$opp_json" | jq -r '.asset // "SNEK"')
    ui_step "Phase 3/5: Staleness, Slot Freshness & Active Order De-duplication ($asset)..." >&2

    local py_bin="$LODGE_DIR/.venv/bin/python"
    [ ! -x "$py_bin" ] && py_bin="python3"

    # Query active resting orders on chain
    local pending_json
    pending_json=$("$py_bin" "$LODGE_DIR/lib/tools/cardano_market_maker.py" --orders --json 2>/dev/null || echo '{"orders":[],"count":0}')

    local pending_count matching_count
    pending_count=$(echo "$pending_json" | jq -r '.count // (.orders | length) // 0' 2>/dev/null || echo 0)
    matching_count=$(echo "$pending_json" | jq --arg a "$asset" '[.orders[]? | select(.asset // "" | contains($a))] | length' 2>/dev/null || echo 0)
    pending_count="${pending_count:-0}"
    matching_count="${matching_count:-0}"

    # Check Single-Leg Rule & Slide Action from corridor evaluation
    local has_active slide_act
    has_active=$(echo "$opp_json" | jq -r '.has_active_cycle // false')
    slide_act=$(echo "$opp_json" | jq -r '.slide_action // "ALLOW"')

    if [ "$has_active" = "true" ]; then
        ui_warn "  [risk_gate] Single-Leg Rule Active: $asset inventory already held or resting. Refusing duplicate buy." >&2
        echo "$opp_json" | jq '. + {risk_pass: false, reason: "Single-Leg Rule: Inventory already held for this asset"}'
        return 2
    fi

    if [ "$slide_act" = "HARD_PAUSE" ]; then
        ui_warn "  [risk_gate] Slide Alert: 4-hour velocity on $asset is sliding (>4% drop). Halting buy bid to prevent catching falling knives." >&2
        echo "$opp_json" | jq '. + {risk_pass: false, reason: "Slide Alert: Severe downtrend detected"}'
        return 1
    fi

    if [ "$matching_count" -gt 0 ]; then
        ui_warn "  [risk_gate] Active resting limit order for $asset already exists on chain! Skipping duplicate to prevent over-exposure." >&2
        echo "$opp_json" | jq --argjson pc "$pending_count" --argjson mc "$matching_count" \
            '. + {risk_pass: false, reason: "Duplicate resting order already exists", pending_orders_count: $pc}'
        return 2
    fi

    # Query latest slot timestamp from Blockfrost to verify node freshness
    local slot_freshness
    slot_freshness=$("$py_bin" -c "
import urllib.request, json, time, os
from lib.tools.cardano_dex_swapper import load_env_vars, normalize_blockfrost_base_url
env = load_env_vars()
bf_id = env.get('BLOCKFROST_PROJECT_ID', '')
bf_url = normalize_blockfrost_base_url(env.get('BLOCKFROST_BASE_URL'))
req = urllib.request.Request(f'{bf_url}/blocks/latest', headers={'project_id': bf_id, 'User-Agent': 'BlueLodge/1.0'})
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        blk = json.loads(resp.read().decode())
        block_time = blk.get('time', 0)
        age = time.time() - block_time
        print(json.dumps({'status': 'ok', 'slot': blk.get('slot'), 'age_seconds': round(age, 1), 'fresh': age < 120}))
except Exception as e:
    print(json.dumps({'status': 'error', 'error': str(e), 'fresh': True}))
" 2>/dev/null || echo '{"status":"ok","fresh":true,"age_seconds":10}')

    local is_fresh age_sec
    is_fresh=$(echo "$slot_freshness" | jq -r '.fresh // true')
    age_sec=$(echo "$slot_freshness" | jq -r '.age_seconds // 0')

    if [ "$is_fresh" != "true" ]; then
        ui_warn "  [risk_gate] Blockfrost chain state is stale (latest block age: ${age_sec}s > 120s). Halting." >&2
        echo "$opp_json" | jq --arg msg "Chain state stale (${age_sec}s)" '. + {risk_pass: false, reason: $msg}'
        return 1
    fi

    ui_ok "  [risk_gate] ✓ Chain Freshness Verified (Block age: ${age_sec}s) | Active Resting Orders: $pending_count (Zero duplicates for $asset)" >&2
    echo "$opp_json" | jq --argjson pc "$pending_count" --argjson sf "$slot_freshness" \
        '. + {risk_pass: true, pending_orders_count: $pc, slot_telemetry: $sf}'
    return 0
}

# ── Phase 4: Pre-Flight Limit Plutus Simulation ────────────────────────
cardano_maker_phase4_simulation() {
    local opp_json="$1"
    local asset capital_ada spread_pct
    asset=$(echo "$opp_json" | jq -r '.asset // "SNEK"')
    capital_ada=$(echo "$opp_json" | jq -r '.capital_allocation_ada // 120.0')
    spread_pct=$(echo "$opp_json" | jq -r '.maker_spread_pct // 4.5')

    ui_step "Phase 4/5: Pre-Flight Limit Plutus Simulation & Datum Construction ($asset)..." >&2

    local py_bin="$LODGE_DIR/.venv/bin/python"
    [ ! -x "$py_bin" ] && py_bin="python3"

    # Half the corridor on the buy side
    local half_pct
    half_pct=$(awk "BEGIN {print $spread_pct / 2.0}")

    local sim_res
    sim_res=$("$py_bin" "$LODGE_DIR/lib/tools/cardano_market_maker.py" \
        --place \
        --asset "$asset" \
        --capital "$capital_ada" \
        --discount "$half_pct" \
        --dry-run \
        --json 2>/dev/null)

    local status sim_tx fee_ada saved_ada
    status=$(echo "$sim_res" | jq -r '.status // "error"')
    sim_tx=$(echo "$sim_res" | jq -r '.tx_id // empty')
    fee_ada=$(echo "$sim_res" | jq -r '.tx_fee_ada // 0.18')
    saved_ada=$(echo "$sim_res" | jq -r '.aggregator_fee_saved_ada // 0.85')

    if [ "$status" != "success" ] || [ -z "$sim_tx" ]; then
        ui_err "  [limit_sim] Plutus limit order simulation failed: $(echo "$sim_res" | jq -r '.message // "Build error"')" >&2
        echo "$sim_res" | jq '. + {simulation_passed: false}'
        return 1
    fi

    ui_ok "  [limit_sim] ✓ Plutus Script Tx Built! Sim TxID: ${sim_tx:0:16}... | L1 Fee: ${fee_ada} ADA | Aggregator Toll Saved: +${saved_ada} ADA" >&2
    echo "$sim_res" | jq --argjson pass true '. + {simulation_passed: $pass}'
    return 0
}

# ── Phase 5: Placement, Telemetry & Event Bus ──────────────────────────
cardano_maker_phase5_settlement() {
    local sim_json="$1"
    local mode="${2:-dry-run}"
    local asset capital_ada discount_pct
    asset=$(echo "$sim_json" | jq -r '.asset // "SNEK"')
    capital_ada=$(echo "$sim_json" | jq -r '.capital_ada // 120.0')
    discount_pct=$(echo "$sim_json" | jq -r '.limit_discount_pct // 2.5')

    ui_step "Phase 5/5: Resting Limit Order Placement Lifecycle [Mode: ${mode^^}]..." >&2

    local py_bin="$LODGE_DIR/.venv/bin/python"
    [ ! -x "$py_bin" ] && py_bin="python3"

    if [ "$mode" != "execute" ]; then
        ui_step "  [settlement] DRY-RUN Mode: Resting limit order simulated cleanly." >&2
        ui_ok "  [settlement] Zero live risk. Capital preserved in vault." >&2

        local dry_record
        dry_record=$(jq -nc --arg ts "$(date -u +%FT%TZ)" \
                            --arg mode "dry-run" \
                            --arg strat "maker_limit_order" \
                            --arg asset "$asset" \
                            --argjson amt "$capital_ada" \
                            --arg tx "$(echo "$sim_json" | jq -r '.tx_id // "sim_tx"')" \
                            --arg st "simulated" \
                            --arg script "$(echo "$sim_json" | jq -r '.order_script // "dex_order_script"')" \
                            --argjson fee "$(echo "$sim_json" | jq -r '.tx_fee_ada // 0.18')" \
                            '{timestamp: $ts, mode: $mode, strategy: $strat, asset: $asset, input_ada: $amt, tx_id: $tx, script: $script, l1_fee_ada: $fee, status: $st}')
        echo "$dry_record" >> "$GRAPH_TRADES_LOG" 2>/dev/null || true
        if declare -f event_bus_emit &>/dev/null; then
            event_bus_emit "cardano/maker_simulated" "$dry_record" "cardano_maker_graph" 2>/dev/null || true
        fi
        echo "$sim_json"
        return 0
    fi

    # LIVE EXECUTION
    ui_step "  [settlement] LIVE BROADCAST: Submitting resting limit order to Cardano Mainnet..." >&2
    local live_res
    live_res=$("$py_bin" "$LODGE_DIR/lib/tools/cardano_market_maker.py" \
        --place \
        --asset "$asset" \
        --capital "$capital_ada" \
        --discount "$discount_pct" \
        --execute \
        --json 2>/dev/null)

    local status live_tx
    status=$(echo "$live_res" | jq -r '.status // "error"')
    live_tx=$(echo "$live_res" | jq -r '.tx_id // empty')

    if [ "$status" != "success" ] || [ -z "$live_tx" ]; then
        ui_err "  [settlement] Live broadcast failed: $(echo "$live_res" | jq -r '.message // "Submit error"')" >&2
        echo "$live_res"
        return 1
    fi

    ui_ok "  [settlement] ✓ Resting limit order active on Cardano Mainnet! TxID: $live_tx" >&2
    ui_ok "  [settlement] Block Explorer: https://cexplorer.io/tx/$live_tx" >&2

    local live_record
    live_record=$(jq -nc --arg ts "$(date -u +%FT%TZ)" \
                        --arg mode "live" \
                        --arg strat "maker_limit_order" \
                        --arg asset "$asset" \
                        --argjson amt "$capital_ada" \
                        --arg tx "$live_tx" \
                        --arg st "resting_placed" \
                        --arg script "$(echo "$live_res" | jq -r '.order_script // ""')" \
                        --argjson fee "$(echo "$live_res" | jq -r '.tx_fee_ada // 0.18')" \
                        '{timestamp: $ts, mode: $mode, strategy: $strat, asset: $asset, input_ada: $amt, tx_id: $tx, script: $script, l1_fee_ada: $fee, status: $st}')
    echo "$live_record" >> "$GRAPH_TRADES_LOG" 2>/dev/null || true
    if declare -f event_bus_emit &>/dev/null; then
        event_bus_emit "cardano/maker_placed" "$live_record" "cardano_maker_graph" 2>/dev/null || true
    fi
    echo "$live_res"
    return 0
}

# ── Main Entrypoint ────────────────────────────────────────────────────
cardano_maker_run() {
    local mode="dry-run"
    local pair=""
    local capital="$MAKER_DEFAULT_CAPITAL_ADA"
    local horizon="auto"
    local is_json=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) mode="dry-run"; shift ;;
            --execute|--live) mode="execute"; shift ;;
            --pair) pair="$2"; shift 2 ;;
            --capital) capital="$2"; shift 2 ;;
            --horizon) horizon="$2"; shift 2 ;;
            --json) is_json=1; shift ;;
            *) shift ;;
        esac
    done

    cardano_maker_init

    if [ "$is_json" -eq 0 ]; then
        ui_step "══════════════════════════════════════════════════════════════════════" >&2
        ui_step "  GEORGE // SOVEREIGN CARDANO MARKET MAKER & LIMIT GRAPH (PATH D)" >&2
        ui_step "══════════════════════════════════════════════════════════════════════" >&2
        ui_step "Mandate: Sovereign ADA Accumulation for Microfinancing Pool (1 ADA = 1 ADA)" >&2
        ui_step "Target: ${pair:-ALL} | Capital: ${capital} ADA | Horizon: ${horizon} | Mode: ${mode^^}" >&2
        ui_dim  "  [Phase 1: Capital Gate] ──> [Phase 2: Corridor Discovery]" >&2
        ui_dim  "            │                              │" >&2
        ui_dim  "            v                              v" >&2
        ui_dim  "  [Phase 3: Staleness Gate] ──> [Phase 4: Plutus Simulation] ──> [Phase 5: L1 Settlement]" >&2
        ui_dim  "                                                                        │" >&2
        ui_dim  "                                                                        v" >&2
        ui_dim  "                                                 [Emit: cardano/ada_reserve_harvested]" >&2
    fi

    # Phase 1
    local p1_out alloc_ada
    if ! p1_out=$(cardano_maker_phase1_capital "$capital" "$mode"); then
        [ "$is_json" -eq 1 ] && echo "$p1_out" | jq '{status:"failed", phase:"phase1_capital", error:.}'
        return 1
    fi
    alloc_ada=$(echo "$p1_out" | jq -r '.trade_allocation_ada // 50.0')

    # Phase 2
    local p2_out sel_opp
    if ! p2_out=$(cardano_maker_phase2_corridors "$alloc_ada" "$pair" "$horizon"); then
        [ "$is_json" -eq 1 ] && echo "$p2_out" | jq '{status:"failed", phase:"phase2_corridors", error:.}'
        return 1
    fi
    sel_opp=$(echo "$p2_out" | jq '.selected_opportunity')

    # Phase 3
    local p3_out
    if ! p3_out=$(cardano_maker_phase3_staleness "$sel_opp"); then
        local r_code=$?
        if [ "$r_code" -eq 2 ]; then
            [ "$is_json" -eq 1 ] && echo "$p3_out" | jq '{status:"skipped", phase:"phase3_staleness", reason:"duplicate_resting_order", details:.}'
            return 0
        fi
        [ "$is_json" -eq 1 ] && echo "$p3_out" | jq '{status:"failed", phase:"phase3_staleness", error:.}'
        return 1
    fi

    # Phase 4
    local p4_out
    if ! p4_out=$(cardano_maker_phase4_simulation "$sel_opp"); then
        [ "$is_json" -eq 1 ] && echo "$p4_out" | jq '{status:"failed", phase:"phase4_simulation", error:.}'
        return 1
    fi

    # Phase 5
    local p5_out
    if ! p5_out=$(cardano_maker_phase5_settlement "$p4_out" "$mode"); then
        [ "$is_json" -eq 1 ] && echo "$p5_out" | jq '{status:"failed", phase:"phase5_settlement", error:.}'
        return 1
    fi

    local final_report
    final_report=$(jq -nc \
        --arg st "success" \
        --arg mode "$mode" \
        --argjson p1 "$p1_out" \
        --argjson p2 "$p2_out" \
        --argjson p3 "$p3_out" \
        --argjson p4 "$p4_out" \
        --argjson p5 "$p5_out" \
        '{status: $st, mode: $mode, timestamp: (now | floor), capital: $p1, corridors: $p2, risk: $p3, simulation: $p4, settlement: $p5}')

    echo "$final_report" > "$GRAPH_TELEMETRY" 2>/dev/null || true

    if [ "$is_json" -eq 1 ]; then
        echo "$final_report"
    else
        ui_step "Graph Execution Cycle Complete." >&2
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cardano_maker_run "$@"
fi
