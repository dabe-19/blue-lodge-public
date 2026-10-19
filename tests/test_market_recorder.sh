#!/bin/bash
# ── Test Suite: P1 Market Data Foundation (pool recorder + market.db) ─────────
# Offline: decodes real captured Minswap V2 batch transactions, exercises the
# incremental recorder against a fake source, the API budget guard, retention,
# the 2 GB cap logic and the recorder-backed market dimensions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LODGE_DIR/tests/framework.sh"

PY_BIN="$LODGE_DIR/.venv/bin/python"
[ ! -x "$PY_BIN" ] && PY_BIN="python3"

TEST_TMP=$(mktemp -d /tmp/george-market-recorder-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FINANCE_DIR="$GEORGE_DIR/finance"
export MARKET_DB_PATH="$FINANCE_DIR/market.db"
export CARDANO_TEST_MODE=1
mkdir -p "$FINANCE_DIR"
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

test_start "P1 Market Data Foundation"

describe "Offline recorder / market.db checks"
CHECK_OUT=$("$PY_BIN" "$LODGE_DIR/tests/market_recorder_checks.py" 2>/dev/null || true)
for name in bech32_payment_credentials \
            pool_datum_exact_reserves_and_fee_tier \
            batch_decomposition_and_measured_batcher_fee \
            liquidity_only_spend_is_not_a_trade \
            recorder_incremental_poll_records_only_new_txs \
            budget_degrades_then_hands_over \
            janitor_downsamples_and_enforces_retention \
            size_cap_prunes_oldest_bars_first \
            spot_series_forward_fills_and_cex_gaps_when_stale \
            dimensions_use_exact_recorder_fee_tier \
            ohlcv_series_and_recent_swaps \
            chart_overlays_kalman_vrvp_and_order_book; do
    it "$name"
    line=$(printf '%s\n' "$CHECK_OUT" | grep -m1 "^$name " || true)
    assert_contains "$line" "$name PASS" "${line:-check did not run}"
done

describe "Cron wiring"
for job in pool_recorder market_janitor pool_backfill; do
    it "cron job $job exists with INTERVAL header"
    f="$LODGE_DIR/.george/cron_jobs/$job.sh"
    if [ -f "$f" ]; then
        assert_contains "$(head -5 "$f")" "# INTERVAL:"
    else
        skip "cron job not installed" || true
    fi
done

it "coinbase cron persists ticks to market.db"
if [ -f "$LODGE_DIR/.george/cron_jobs/api_coinbase_ada.sh" ]; then
    assert_contains "$(cat "$LODGE_DIR/.george/cron_jobs/api_coinbase_ada.sh")" "market_db.py\" cex-tick"
else
    skip "cron job not installed" || true
fi

it "market_db CLI records a CEX tick"
out=$("$PY_BIN" "$LODGE_DIR/lib/tools/quant/market_db.py" cex-tick --symbol=ADA-USD --price=0.25 2>/dev/null || true)
assert_contains "$out" '"status": "ok"'

it "market_db CLI rejects a non-positive price"
out=$("$PY_BIN" "$LODGE_DIR/lib/tools/quant/market_db.py" cex-tick --symbol=ADA-USD --price=0 2>/dev/null || true)
assert_contains "$out" '"status": "error"'

test_end
