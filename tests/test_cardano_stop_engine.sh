#!/bin/bash
# ── Test Suite: Sovereign Cardano Stop-Order & Reactive Bracket Engine ──────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LODGE_DIR/tests/framework.sh"

PY_BIN="$LODGE_DIR/.venv/bin/python"
[ ! -x "$PY_BIN" ] && PY_BIN="python3"

# Test sandbox isolation to protect production database and ledger
TEST_TMP=$(mktemp -d /tmp/george-cardano-stops-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FINANCE_DIR="$GEORGE_DIR/finance"
export MAKER_DB_PATH="$FINANCE_DIR/maker_orders.db"
export SIM_MAKER_DB_PATH="$MAKER_DB_PATH"
export CARDANO_TEST_MODE=1
export STOP_BUY_MIN_CAPITAL_ADA=20.0
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"
export EVENT_BUS_FIFO="$FIFO_IPC_DIR/event_bus.fifo"
mkdir -p "$FINANCE_DIR" "$FIFO_IPC_DIR"
[ -d "$LODGE_DIR/.george/finance/market_cache" ] && cp -r "$LODGE_DIR/.george/finance/market_cache" "$FINANCE_DIR/" 2>/dev/null || true

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "Sovereign Cardano Stop-Order & Reactive Bracket Engine"

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

describe "Quantitative Stop Calculation & Bounds"
  it "calculates coil bounds, fee drag floor, and sizing headroom for SNEK" && {
    out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" calc SNEK --json)
    status=$(echo "$out" | jq -r '.status')
    assert_eq "$status" "ok"

    spot=$(echo "$out" | jq -r '.spot_price_ada')
    coil_high=$(echo "$out" | jq -r '.coil_high_ada')
    coil_low=$(echo "$out" | jq -r '.coil_low_ada')
    stop_buy=$(echo "$out" | jq -r '.recommendations.stop_buy_trigger_ada')
    inv_disarm=$(echo "$out" | jq -r '.recommendations.invalidation_disarm_ada')
    tp=$(echo "$out" | jq -r '.recommendations.oco_take_profit_ada')
    sl=$(echo "$out" | jq -r '.recommendations.oco_stop_loss_ada')
    fee_drag=$(echo "$out" | jq -r '.fee_drag_floor_pct')

    # Mathematical consistency checks
    assert_float_gt "$spot" "0"
    assert_float_gt "$coil_high" "$coil_low"
    assert_float_gt "$stop_buy" "$coil_high"
    assert_float_gt "$stop_buy" "$inv_disarm"
    assert_float_gt "$tp" "$stop_buy"
    assert_float_gt "$stop_buy" "$sl"
    assert_eq "$fee_drag" "1.24"
  }

  it "enforces dynamic headroom above the 40.0 ADA reserve floor when active orders exist" && {
    # Initialize DB and simulate an active 160 ADA ladder on SNEK
    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_maker_db.py" --init >/dev/null
    sqlite3 "$MAKER_DB_PATH" "INSERT INTO maker_orders (order_id, asset, direction, status, capital_ada, target_price_ada, tokens_target, created_at, updated_at) VALUES ('test_order_1', 'SNEK', 'BUY', 'PENDING_BUY', 160.0, 0.0033, 48000, 1000, 1000);"

    out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" calc SNEK --json)
    active=$(echo "$out" | jq -r '.active_book_ada')
    spendable=$(echo "$out" | jq -r '.spendable_ada')
    floor=$(echo "$out" | jq -r '.reserve_floor_ada')
    headroom=$(echo "$out" | jq -r '.remaining_headroom_ada')

    assert_eq "$(python3 -c "print(round(float('$active'), 1))")" "160.0"
    assert_eq "$floor" "40.0"
    assert_float_gt "$spendable" "0"

    # Saturated book rejection when order exceeds remaining spendable headroom
    sqlite3 "$MAKER_DB_PATH" "UPDATE maker_orders SET capital_ada = 1000.0 WHERE order_id = 'test_order_1';"
    arm_res=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" arm SNEK --trigger 0.0035 --amount 25.0 --json || true)
    arm_status=$(echo "$arm_res" | jq -r '.status')
    assert_eq "$arm_status" "error"
    assert_contains "$(echo "$arm_res" | jq -r '.message')" "above the 40.0 ADA reserve floor"
  }

describe "Stop Arming, Listing, and Cancellation"
  it "arms a dry-run stop trigger with simulation receipt" && {
    # Reset active order
    sqlite3 "$MAKER_DB_PATH" "DELETE FROM maker_orders;"

    arm_out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" arm SNEK --trigger 0.00355 --amount 25.0 --invalidation 0.00320 --gate-ada-24h 0.0 --json)
    arm_status=$(echo "$arm_out" | jq -r '.status')
    tid=$(echo "$arm_out" | jq -r '.trigger_id')
    mode=$(echo "$arm_out" | jq -r '.simulation_receipt.mode')
    est_tokens=$(echo "$arm_out" | jq -r '.simulation_receipt.estimated_tokens_out')

    assert_eq "$arm_status" "ok"
    assert_match "$tid" "^stop_snek_[0-9]+_[0-9a-f]+$"
    assert_eq "$mode" "DRY_RUN"
    assert_float_gt "$est_tokens" "1000"

    # Verify present in SQLite with status ARMED
    db_status=$(sqlite3 "$MAKER_DB_PATH" "SELECT status FROM stop_triggers WHERE trigger_id = '$tid';")
    assert_eq "$db_status" "ARMED"
  }

  it "lists registered stop triggers and formats terminal table" && {
    list_out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" list)
    assert_contains "$list_out" "SOVEREIGN STOP TRIGGERS"
    assert_contains "$list_out" "SNEK"
    assert_contains "$list_out" "STOP_BUY"
    assert_contains "$list_out" "ARMED"
  }

  it "cancels an armed stop trigger cleanly" && {
    tid=$(sqlite3 "$MAKER_DB_PATH" "SELECT trigger_id FROM stop_triggers WHERE status = 'ARMED' LIMIT 1;")
    cancel_out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" cancel "$tid" --json)
    c_status=$(echo "$cancel_out" | jq -r '.status')
    c_ok=$(echo "$cancel_out" | jq -r '.cancelled')
    assert_eq "$c_status" "ok"
    assert_eq "$c_ok" "true"

    db_status=$(sqlite3 "$MAKER_DB_PATH" "SELECT status FROM stop_triggers WHERE trigger_id = '$tid';")
    assert_eq "$db_status" "CANCELLED"
  }

  it "prunes stale stop triggers and auto-cancels linked triggers when order is reclaimed" && {
    sqlite3 "$MAKER_DB_PATH" "DELETE FROM stop_triggers;"
    # Arm a trigger with a linked order
    tid=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" arm SNEK --trigger 0.00355 --amount 15.0 --json | jq -r '.trigger_id')
    sqlite3 "$MAKER_DB_PATH" "UPDATE stop_triggers SET linked_order_id = 'test_reclaim_ord_1' WHERE trigger_id = '$tid';"

    # Call cancel_linked_stop_triggers via python
    "$PY_BIN" -c "import sys; sys.path.insert(0, '$LODGE_DIR'); from lib.tools.cardano_maker_db import cancel_linked_stop_triggers; assert cancel_linked_stop_triggers('test_reclaim_ord_1') == 1"

    status=$(sqlite3 "$MAKER_DB_PATH" "SELECT status FROM stop_triggers WHERE trigger_id = '$tid';")
    assert_eq "$status" "CANCELLED"

    # Test prune CLI
    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" arm MIN --trigger 0.016 --amount 15.0 --json >/dev/null
    prune_res=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" prune --all --json)
    assert_eq "$(echo "$prune_res" | jq -r '.status')" "ok"
    assert_eq "$(echo "$prune_res" | jq -r '.pruned_count')" "1"
  }

describe "Multi-Headed Pair Ticker Scraper"
  it "stands down when no ARMED triggers exist" && {
    sqlite3 "$MAKER_DB_PATH" "DELETE FROM stop_triggers;"
    out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_pair_ticker.py" --poll --dry-run --json)
    ticks_cnt=$(echo "$out" | jq -r '.ticks | length')
    assert_eq "$ticks_cnt" "0"
  }

  it "scrapes spot and macro change for assets with active ARMED triggers" && {
    # Arm a trigger
    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" arm SNEK --trigger 0.00355 --amount 20.0 --json >/dev/null

    out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_pair_ticker.py" --poll --dry-run --json)
    ticks_cnt=$(echo "$out" | jq -r '.ticks | length')
    assert_gt "$ticks_cnt" "0"
    asset=$(echo "$out" | jq -r '.ticks[0].asset')
    spot=$(echo "$out" | jq -r '.ticks[0].spot_price_ada')
    assert_eq "$asset" "SNEK"
    assert_float_gt "$spot" "0"
  }

describe "Reactive Stop Engine & Chained OCO Brackets"
  it "holds trigger in persistent guard when price breaches but ADA 24h is negative" && {
    sqlite3 "$MAKER_DB_PATH" "DELETE FROM stop_triggers;"
    sqlite3 "$MAKER_DB_PATH" "DELETE FROM maker_orders;"

    # Arm a Stop-Buy at 0.00350 with gate min = 0.0%
    arm_out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" arm SNEK --trigger 0.00350 --amount 25.0 --invalidation 0.00320 --gate-ada-24h 0.0 --json)
    tid=$(echo "$arm_out" | jq -r '.trigger_id')

    # Emit tick where price breached (0.00355 >= 0.00350) but ADA 24h is -2.5% (negative)
    tick_payload='{"asset": "SNEK", "spot_price_ada": 0.00355, "ada_24h_change_pct": -2.5, "timestamp": 1000}'
    res=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_reactor.py" "$tick_payload")
    act=$(echo "$res" | jq -r '.actions[0].action')
    assert_eq "$act" "GATE_BLOCKED_HOLD"

    # Status remains ARMED with gate_blocked_at metadata
    st=$(sqlite3 "$MAKER_DB_PATH" "SELECT status FROM stop_triggers WHERE trigger_id = '$tid';")
    assert_eq "$st" "ARMED"
    meta=$(sqlite3 "$MAKER_DB_PATH" "SELECT metadata_json FROM stop_triggers WHERE trigger_id = '$tid';")
    assert_contains "$meta" "gate_blocked_at"
  }

  it "disarms trigger when price retreats back below invalidation after fakeout breach" && {
    tid=$(sqlite3 "$MAKER_DB_PATH" "SELECT trigger_id FROM stop_triggers WHERE status = 'ARMED' LIMIT 1;")
    # Price drops back into coil: 0.00315 <= 0.00320 invalidation
    retreat_payload='{"asset": "SNEK", "spot_price_ada": 0.00315, "ada_24h_change_pct": -2.5, "timestamp": 1010}'
    res=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_reactor.py" "$retreat_payload")
    act=$(echo "$res" | jq -r '.actions[0].action')
    assert_eq "$act" "DISARMED_FAKEOUT"

    st=$(sqlite3 "$MAKER_DB_PATH" "SELECT status FROM stop_triggers WHERE trigger_id = '$tid';")
    assert_eq "$st" "DISARMED"
  }

  it "confirms breakout buy, creates INVENTORY_HOLD order, and arms chained OCO bracket" && {
    sqlite3 "$MAKER_DB_PATH" "DELETE FROM stop_triggers;"
    sqlite3 "$MAKER_DB_PATH" "DELETE FROM maker_orders;"

    # Arm fresh Stop-Buy at 0.00350
    arm_out=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" arm SNEK --trigger 0.00350 --amount 25.0 --tp-pct 4.0 --sl-pct 2.5 --json)
    buy_tid=$(echo "$arm_out" | jq -r '.trigger_id')

    # Tick: Spot 0.00352 >= 0.00350 AND ADA 24h is -3.8% (confirmed under bypassed USD gate in ADA accumulation mode!)
    tick_payload='{"asset": "SNEK", "spot_price_ada": 0.00352, "ada_24h_change_pct": -3.8, "timestamp": 1020}'
    res=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_reactor.py" "$tick_payload")
    act=$(echo "$res" | jq -r '.actions[0].action')
    oid=$(echo "$res" | jq -r '.actions[0].order_id')
    oco_id=$(echo "$res" | jq -r '.actions[0].oco_bracket_id')

    assert_eq "$act" "BREAKOUT_BUY_EXECUTED"
    assert_match "$oid" "^maker_snek_[0-9]+_[0-9a-f]+$"
    assert_match "$oco_id" "^stop_snek_[0-9]+_[0-9a-f]+$"

    # 1. Stop buy is now TRIGGERED
    buy_st=$(sqlite3 "$MAKER_DB_PATH" "SELECT status FROM stop_triggers WHERE trigger_id = '$buy_tid';")
    assert_eq "$buy_st" "TRIGGERED"

    # 2. maker_orders has INVENTORY_HOLD with tokens filled
    order_st=$(sqlite3 "$MAKER_DB_PATH" "SELECT status FROM maker_orders WHERE order_id = '$oid';")
    tokens=$(sqlite3 "$MAKER_DB_PATH" "SELECT tokens_filled FROM maker_orders WHERE order_id = '$oid';")
    assert_eq "$order_st" "INVENTORY_HOLD"
    assert_float_gt "$tokens" "7000"

    # 3. OCO bracket is ARMED with +4% TP and -2.5% SL
    oco_st=$(sqlite3 "$MAKER_DB_PATH" "SELECT status FROM stop_triggers WHERE trigger_id = '$oco_id';")
    oco_type=$(sqlite3 "$MAKER_DB_PATH" "SELECT trigger_type FROM stop_triggers WHERE trigger_id = '$oco_id';")
    oco_tp=$(sqlite3 "$MAKER_DB_PATH" "SELECT trigger_price_ada FROM stop_triggers WHERE trigger_id = '$oco_id';")
    oco_sl=$(sqlite3 "$MAKER_DB_PATH" "SELECT invalidation_price_ada FROM stop_triggers WHERE trigger_id = '$oco_id';")

    assert_eq "$oco_st" "ARMED"
    assert_eq "$oco_type" "OCO_BRACKET"
    assert_float_gt "$oco_tp" "0.00360"
    assert_float_lt "$oco_sl" "0.00345"
  }

  it "executes OCO Take-Profit when target price is touched and realizes profit" && {
    oco_id=$(sqlite3 "$MAKER_DB_PATH" "SELECT trigger_id FROM stop_triggers WHERE trigger_type = 'OCO_BRACKET' AND status = 'ARMED' LIMIT 1;")
    tp_price=$(sqlite3 "$MAKER_DB_PATH" "SELECT trigger_price_ada FROM stop_triggers WHERE trigger_id = '$oco_id';")

    # Tick: Spot breaches Take-Profit target
    tp_payload=$(jq -nc --arg tp "$tp_price" '{"asset": "SNEK", "spot_price_ada": (($tp|tonumber) + 0.00005), "ada_24h_change_pct": 2.0, "timestamp": 1030}')
    res=$("$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_reactor.py" "$tp_payload")
    act=$(echo "$res" | jq -r '.actions[0].action')
    pnl=$(echo "$res" | jq -r '.actions[0].realized_pnl_ada')

    assert_eq "$act" "OCO_TAKE_PROFIT_EXECUTED"
    assert_float_gt "$pnl" "0.8"

    # Trigger is EXECUTED and maker_order is COMPLETED
    oco_st=$(sqlite3 "$MAKER_DB_PATH" "SELECT status FROM stop_triggers WHERE trigger_id = '$oco_id';")
    assert_eq "$oco_st" "EXECUTED"
    oid=$(sqlite3 "$MAKER_DB_PATH" "SELECT linked_order_id FROM stop_triggers WHERE trigger_id = '$oco_id';")
    order_st=$(sqlite3 "$MAKER_DB_PATH" "SELECT status FROM maker_orders WHERE order_id = '$oid';")
    assert_eq "$order_st" "COMPLETED"
  }

describe "DEX Chart & Visual Overlays"
  it "injects stop_buy and stop_loss horizontal lines into chart_data payload" && {
    # Arm a fresh trigger
    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" arm SNEK --trigger 0.00360 --amount 25.0 --invalidation 0.00325 --json >/dev/null

    chart_json=$("$PY_BIN" "$LODGE_DIR/lib/tools/chart_data.py" --asset=SNEK --json)
    has_stop_buy=$(echo "$chart_json" | jq '[.lines[] | select(.kind == "stop_buy")] | length')
    has_disarm=$(echo "$chart_json" | jq '[.lines[] | select(.kind == "invalidation_disarm")] | length')

    assert_gt "$has_stop_buy" "0"
    assert_gt "$has_disarm" "0"
  }
