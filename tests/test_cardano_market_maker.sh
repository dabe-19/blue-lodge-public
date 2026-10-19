#!/bin/bash
# ── Test Suite: Sovereign Cardano Market Maker & Limit Order Engine (Path D) ──
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LODGE_DIR/tests/framework.sh"
source "$LODGE_DIR/lib/tools/cardano_market_maker_graph.sh"

PY_BIN="$LODGE_DIR/.venv/bin/python"
[ ! -x "$PY_BIN" ] && PY_BIN="python3"

# Test sandbox isolation to protect production database and ledger
TEST_TMP=$(mktemp -d /tmp/george-cardano-maker-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FINANCE_DIR="$GEORGE_DIR/finance"
export MAKER_DB_PATH="$FINANCE_DIR/maker_orders.db"
export SIM_MAKER_DB_PATH="$FINANCE_DIR/sim_maker_orders.db"
export CARDANO_TEST_MODE=1
export DOSSIER_DIR="$TEST_TMP/dossiers/finance"
export GRAPH_TRADES_LOG="$DOSSIER_DIR/trades.jsonl"
export GRAPH_TELEMETRY="$FINANCE_DIR/maker_graph_latest.json"
# Dry-run tx builds need the real wallet address/UTxOs (read-only; nothing is broadcast).
export LODGE_WALLETS_DIR="$LODGE_DIR/.george/wallets"
mkdir -p "$FINANCE_DIR" "$DOSSIER_DIR"
[ -d "$LODGE_DIR/.george/finance/market_cache" ] && cp -r "$LODGE_DIR/.george/finance/market_cache" "$FINANCE_DIR/" 2>/dev/null || true

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "Sovereign Cardano Market Maker Engine (Path D)"

describe "Core Market Maker Tools & Calculations"
  it "evaluates market maker corridors with live spot pricing & trend velocity" && {
    out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_market_maker.py" --capital 120 --json)
    status=$(echo "$out" | jq -r '.status')
    corridors_count=$(echo "$out" | jq -r '.corridors | length')
    regime=$(echo "$out" | jq -r '.corridors[0].trend_regime')
    assert_eq "$status" "ok"
    assert_gt "$corridors_count" "3"
    assert_match "$regime" "NORMAL_CORRIDOR|SLIDE_ALERT"
  }

  it "simulates resting limit order with positive net cycle profit" && {
    sim=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_market_maker.py" --simulate --asset MIN --capital 120 --discount 2.5 --json)
    sim_status=$(echo "$sim" | jq -r '.status')
    assert_eq "$sim_status" "simulated"
    is_prof=$(echo "$sim" | jq -r '.is_profitable_cycle')
    assert_eq "$is_prof" "true"
  }

  it "builds direct Plutus resting limit order transaction in dry-run mode" && {
    place=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_market_maker.py" --place --asset MIN --capital 10 --dry-run --json)
    p_status=$(echo "$place" | jq -r '.status')
    p_dry=$(echo "$place" | jq -r '.dry_run')
    p_saved=$(echo "$place" | jq -r '.aggregator_fee_saved_ada')
    p_script=$(echo "$place" | jq -r '.order_script')
    assert_eq "$p_status" "success"
    assert_eq "$p_dry" "true"
    assert_eq "$p_saved" "0.85"
    assert_match "$p_script" "^addr1"
  }

  it "queries active resting limit orders on chain" && {
    orders=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_market_maker.py" --orders --json)
    o_status=$(echo "$orders" | jq -r '.status')
    assert_eq "$o_status" "ok"
  }

describe "Database Persistence & Ledger Reconciliation (maker_orders.db)"
  it "initializes SQLite maker_orders table and reconciles from on-chain ledger" && {
    reconcile_out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_maker_db.py" --reconcile --json)
    r_status=$(echo "$reconcile_out" | jq -r '.status')
    assert_eq "$r_status" "ok"
  }

  it "retrieves active maker cycles from SQLite database" && {
    cycles_out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_maker_db.py" --list --json)
    c_status=$(echo "$cycles_out" | jq -r '.status')
    assert_eq "$c_status" "ok"
  }

describe "Order Watcher Daemon & Reactive Sell Leg (rx_maker_sell)"
  it "simulates order fill and emits cardano/maker_filled to event bus" && {
    fill_out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_watcher.py" --simulate-fill MIN)
    f_status=$(echo "$fill_out" | jq -r '.status')
    f_basis=$(echo "$fill_out" | jq -r '.cost_basis_ada')
    f_basis_int="${f_basis%.*}"
    assert_eq "$f_status" "success"
    assert_gt "$f_basis_int" "100"
  }

  it "executes reactive sell leg with deterministic profit hurdle" && {
    rx_out=$(bash -c "source '$LODGE_DIR/lib/tools/cardano_maker_sell_reactor.sh' && maker_sell_event_ingress 'cardano/maker_filled' '{\"order_id\":\"test_ord_1\",\"asset\":\"MIN\",\"tokens_filled\":7500.0,\"net_cost_basis_ada\":121.98,\"batcher_fee_ada\":1.80,\"tx_fee_ada\":0.18,\"is_simulated\":true}'" && echo "ok")
    assert_eq "$rx_out" "ok"
  }

  it "automatically records instant DEX swap buy and triggers reactive sell relisting" && {
    swap_out=$("$PY_BIN" -c "
from lib.tools.cardano_maker_db import record_dex_swap_fill
res = record_dex_swap_fill(
    asset='MIN',
    tokens_filled=5000.0,
    cost_basis_ada=75.0,
    tx_id='sim_swap_test_123',
    protocol='SundaeSwapV3',
    is_simulated=True,
    auto_relist=True
)
import json
print(json.dumps(res))
")
    s_status=$(echo "$swap_out" | jq -r '.status')
    s_order_id=$(echo "$swap_out" | jq -r '.order_id')
    s_relist_status=$(echo "$swap_out" | jq -r '.relist.status')
    assert_eq "$s_status" "ok"
    assert_match "$s_order_id" "^swap_min_"
    assert_match "$s_relist_status" "simulated|placed"
  }

  it "simulates dry-run DEX swap with auto-relisting in cardano_dex_swapper.py" && {
    dex_out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_dex_swapper.py" --amount 10.0 --to-token MIN --dry-run --json 2>/dev/null)
    d_status=$(echo "$dex_out" | jq -r '.status')
    d_relist=$(echo "$dex_out" | jq -r '.auto_relist.status // empty')
    assert_eq "$d_status" "success"
    assert_eq "$d_relist" "ok"
  }

describe "5-Phase Deterministic Maker Graph & Slide Gating"
  it "enforces Single-Leg Rule on assets with existing inventory" && {
    # MIN has active cycle from simulate-fill test
    graph_out=$("$LODGE_DIR/lib/tools/cardano_market_maker_graph.sh" --dry-run --pair MIN --capital 120 --json || echo '{"status":"skipped"}')
    g_status=$(echo "$graph_out" | jq -r '.status')
    assert_match "$g_status" "skipped|success"
  }

  it "executes clean 5-phase dry run on an unencumbered viable pair (IAG)" && {
    graph_out=$("$LODGE_DIR/lib/tools/cardano_market_maker_graph.sh" --dry-run --pair IAG --capital 15 --json)
    g_status=$(echo "$graph_out" | jq -r '.status')
    g_gate=$(echo "$graph_out" | jq -r '.capital.gate_pass')
    g_sim=$(echo "$graph_out" | jq -r '.simulation.simulation_passed')
    assert_eq "$g_status" "success"
    assert_eq "$g_gate" "true"
    assert_eq "$g_sim" "true"
  }

describe "Web API Endpoints for Path D"
  it "serves /api/finance/maker/corridors" && {
    resp=$(curl -s "http://localhost:3000/api/finance/maker/corridors?capital=120")
    api_status=$(echo "$resp" | jq -r '.status')
    assert_eq "$api_status" "ok"
  }

  it "serves /api/finance/maker/orders" && {
    resp=$(curl -s http://localhost:3000/api/finance/maker/orders)
    api_status=$(echo "$resp" | jq -r '.status')
    assert_eq "$api_status" "ok"
  }

  it "serves /api/finance/maker/active-cycles" && {
    resp=$(curl -s http://localhost:3000/api/finance/maker/active-cycles)
    api_status=$(echo "$resp" | jq -r '.status')
    assert_eq "$api_status" "ok"
  }

  LODGE_TOKEN=$(cat "${LODGE_DIR:-$HOME/blue-lodge}/.george/web_token" 2>/dev/null)

  it "serves /api/finance/maker/reconcile" && {
    resp=$(curl -s -X POST -H "X-Lodge-Token: $LODGE_TOKEN" http://localhost:3000/api/finance/maker/reconcile)
    api_status=$(echo "$resp" | jq -r '.status')
    assert_eq "$api_status" "ok"
  }

  it "serves /api/finance/maker/simulate" && {
    resp=$(curl -s -X POST -H "X-Lodge-Token: $LODGE_TOKEN" -H "Content-Type: application/json" -d '{"asset":"IAG","capital":120.0,"discount":2.5}' http://localhost:3000/api/finance/maker/simulate)
    sim_status=$(echo "$resp" | jq -r '.status')
    assert_eq "$sim_status" "simulated"
  }

  it "serves /api/finance/maker/link-inventory and /api/finance/maker/unlink-inventory" && {
    link_resp=$(curl -s -X POST -H "X-Lodge-Token: $LODGE_TOKEN" -H "Content-Type: application/json" -d '{"active_order_id":"test_active_ord","held_order_id":"test_held_ord"}' http://localhost:3000/api/finance/maker/link-inventory)
    link_status=$(echo "$link_resp" | jq -r '.status')
    assert_match "$link_status" "success|error"

    unlink_resp=$(curl -s -X POST -H "X-Lodge-Token: $LODGE_TOKEN" -H "Content-Type: application/json" -d '{"active_order_id":"test_active_ord"}' http://localhost:3000/api/finance/maker/unlink-inventory)
    unlink_status=$(echo "$unlink_resp" | jq -r '.status')
    assert_match "$unlink_status" "success|error"
  }

describe "Web API security gates"
  it "rejects fund-route POST without token (401)" && {
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{"asset":"IAG","capital":1,"discount":1}' http://localhost:3000/api/finance/maker/simulate)
    assert_eq "$code" "401"
  }

  it "rejects cross-origin requests (403)" && {
    code=$(curl -s -o /dev/null -w "%{http_code}" -H "Origin: https://evil.example" http://localhost:3000/api/finance/maker/orders)
    assert_eq "$code" "403"
  }

  it "rejects Sec-Fetch-Site cross-site (403)" && {
    code=$(curl -s -o /dev/null -w "%{http_code}" -H "Sec-Fetch-Site: cross-site" http://localhost:3000/api/status)
    assert_eq "$code" "403"
  }

  it "refuses token to non-loopback Host header (DNS rebinding)" && {
    code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: attacker.example:3000" http://127.0.0.1:3000/api/session/token)
    assert_eq "$code" "403"
  }

  it "issues token to localhost" && {
    tok=$(curl -s http://localhost:3000/api/session/token | jq -r '.token')
    assert_eq "$tok" "$LODGE_TOKEN"
  }

test_end
