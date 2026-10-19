#!/bin/bash
# ── Test Suite: Sovereign Cardano Unified Order Manager (UCOM) ──────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LODGE_DIR/tests/framework.sh"

PY_BIN="$LODGE_DIR/.venv/bin/python"
[ ! -x "$PY_BIN" ] && PY_BIN="python3"

# Test sandbox isolation
TEST_TMP=$(mktemp -d /tmp/george-cardano-ucom-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FINANCE_DIR="$GEORGE_DIR/finance"
export MAKER_DB_PATH="$FINANCE_DIR/maker_orders.db"
export SIM_MAKER_DB_PATH="$FINANCE_DIR/sim_maker_orders.db"
export CARDANO_TEST_MODE=1
export STOP_BUY_MIN_CAPITAL_ADA=20.0
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"
export EVENT_BUS_FIFO="$FIFO_IPC_DIR/event_bus.fifo"
export LODGE_WALLETS_DIR="$LODGE_DIR/.george/wallets"
mkdir -p "$FINANCE_DIR" "$FIFO_IPC_DIR"
[ -d "$LODGE_DIR/.george/finance/market_cache" ] && cp -r "$LODGE_DIR/.george/finance/market_cache" "$FINANCE_DIR/" 2>/dev/null || true

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "Sovereign Cardano Unified Order Manager (UCOM)"

assert_float_gt() {
    local actual="$1"
    local threshold="$2"
    local msg="${3:-Expected $actual > $threshold}"
    if python3 -c "import sys; sys.exit(0 if float('$actual') > float('$threshold') else 1)" 2>/dev/null; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_float_lt() {
    local actual="$1"
    local threshold="$2"
    local msg="${3:-Expected $actual < $threshold}"
    if python3 -c "import sys; sys.exit(0 if float('$actual') < float('$threshold') else 1)" 2>/dev/null; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

describe "1. Floor Enforcement & Ladder Sizing Compression Gate"
  it "automatically compresses 3 requested rungs on 160 ADA down to 2 rungs at 80 ADA floor" && {
    out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_tool.py" ladder SNEK --capital 160.0 --rungs 3 --plan-only --json)
    status=$(echo "$out" | jq -r '.status')
    effective_rungs=$(echo "$out" | jq -r '.effective_rungs')
    rung_count=$(echo "$out" | jq -r '.rungs | length')
    r1_cap=$(echo "$out" | jq -r '.rungs[0].capital_ada')
    r2_cap=$(echo "$out" | jq -r '.rungs[1].capital_ada')

    assert_eq "$status" "ok"
    assert_eq "$effective_rungs" "2"
    assert_eq "$rung_count" "2"
    assert_float_gt "$r1_cap" "79.9"
    assert_float_gt "$r2_cap" "79.9"
  }

  it "verifies fee drag on 80 ADA rungs is under 3% exit hurdle" && {
    out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_tool.py" ladder MIN --capital 160.0 --rungs 2 --plan-only --json)
    fee_drag=$(echo "$out" | jq -r '.rungs[0].fee_drag_pct')
    assert_float_lt "$fee_drag" "3.0"
  }

describe "2. Dry-Run Ladder Deployment & Option C Inventory Preloading"
  it "places multi-rung simulated ladder and preloads held inventory" && {
    # Seed an inventory hold record in the simulated database
    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_maker_db.py" --init >/dev/null
    sqlite3 "$SIM_MAKER_DB_PATH" "INSERT INTO maker_orders (order_id, asset, direction, status, capital_ada, target_price_ada, tokens_target, tokens_filled, cost_basis_ada, created_at, updated_at) VALUES ('seed_hold_1', 'NIGHT', 'BUY', 'INVENTORY_HOLD', 50.0, 0.19, 260.0, 260.0, 50.0, 1000, 1000);"

    # Deploy simulated ladder for NIGHT
    out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_tool.py" ladder NIGHT --capital 160.0 --rungs 2 --json)
    status=$(echo "$out" | jq -r '.status')
    mode=$(echo "$out" | jq -r '.mode')
    rungs_placed=$(echo "$out" | jq -r '.rungs_placed')
    assert_eq "$status" "success"
    assert_eq "$mode" "DRY_RUN"
    assert_eq "$rungs_placed" "2"

    # Verify inventory was linked
    inv_links=$(echo "$out" | jq -r '.inventory_preloaded | length')
    assert_gt "$inv_links" 0
  }

describe "3. Breakout Stop-Buy & Active Invalidation Disarm Trap"
  it "arms a breakout stop-buy trigger with invalidation disarm trap" && {
    out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_tool.py" stop SNEK --trigger-price 0.00360 --invalidation-price 0.00315 --capital 40.0 --tp 4.5 --sl 2.5 --json)
    status=$(echo "$out" | jq -r '.status')
    mode=$(echo "$out" | jq -r '.mode')
    tid=$(echo "$out" | jq -r '.trigger_id')
    assert_eq "$status" "armed"
    assert_eq "$mode" "DRY_RUN"
    assert_match "$tid" "^stop_snek_[0-9]+_[0-9a-f]+$"
  }

  it "disarms the trigger immediately when spot price retreats below invalidation trap" && {
    # Feed a simulated price tick below the 0.00315 invalidation price
    tick_json='{"asset": "SNEK", "spot_price_ada": 0.00310, "ada_24h_change_pct": 1.5, "ada_usd": 0.35, "timestamp": 1000}'
    ev_out=$("$PY_BIN" -c "from lib.tools.cardano_stop_reactor import process_price_tick; import json; print(json.dumps(process_price_tick($tick_json)))")
    ev_status=$(echo "$ev_out" | jq -r '.status')
    assert_eq "$ev_status" "ok"

    # Verify trigger status in DB is now DISARMED
    disarmed_count=$(sqlite3 "$SIM_MAKER_DB_PATH" "SELECT COUNT(*) FROM stop_triggers WHERE asset = 'SNEK' AND status = 'DISARMED';")
    assert_gt "$disarmed_count" 0
  }

describe "4. Autonomous Ladder Lower-Rung Pruning"
  it "prunes lower rungs when upper rung fill meets the 80 ADA hurdle" && {
    # Place a simulated ladder
    ladder_res=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_tool.py" ladder MIN --capital 160.0 --rungs 2 --json)
    ladder_id=$(echo "$ladder_res" | jq -r '.ladder_id')
    r1_id=$(echo "$ladder_res" | jq -r '.rungs[0].order_id')
    r2_id=$(echo "$ladder_res" | jq -r '.rungs[1].order_id')

    # Prune lower rungs assuming r1 filled with 80 ADA
    prune_res=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_tool.py" prune --ladder-id "$ladder_id" --filled-rung-id "$r1_id" --simulated --json)
    prune_status=$(echo "$prune_res" | jq -r '.status')
    reclaimed=$(echo "$prune_res" | jq -r '.reclaimed_rungs_count')

    assert_eq "$prune_status" "pruned"
    assert_eq "$reclaimed" "1"

    # Verify r2 was marked CANCELLED
    r2_status=$(sqlite3 "$SIM_MAKER_DB_PATH" "SELECT status FROM maker_orders WHERE order_id = '$r2_id';")
    assert_eq "$r2_status" "CANCELLED"
  }

describe "5. Polymorphic View & Unified Status"
  it "queries v_unified_orders across both maker orders and stop triggers" && {
    out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_tool.py" status --simulated --json)
    order_count=$(echo "$out" | jq -r 'length')
    assert_gt "$order_count" 0

    kinds=$(echo "$out" | jq -r '.[].order_kind' | sort -u | tr '\n' ' ')
    assert_contains "$kinds" "BUY"
    assert_contains "$kinds" "STOP_BUY"
  }

describe "6. Unified Engine Daemon (cardano_engine_daemon.py)"
  it "executes single engine cycle with order polling and ticker sweeps" && {
    daemon_out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_engine_daemon.py" --once --dry-run --json)
    d_mode=$(echo "$daemon_out" | jq -r '.mode')
    dur=$(echo "$daemon_out" | jq -r '.duration_ms')

    assert_eq "$d_mode" "DRY_RUN"
    assert_gt "$dur" 0
  }

test_end
