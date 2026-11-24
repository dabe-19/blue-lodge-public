#!/bin/bash
# ── Test Suite: P0 Trading Safety (fail-closed guards) ─────────────────────────
# Every guard on the money path must fail CLOSED. The Python checks are offline
# (all data sources monkeypatched); the deployment checks assert that retired
# strategies (single-leg cointegration, momentum stop-buys) stay switched off.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LODGE_DIR/tests/framework.sh"

PY_BIN="$LODGE_DIR/.venv/bin/python"
[ ! -x "$PY_BIN" ] && PY_BIN="python3"

# Sandbox: never touch the production ledger.
TEST_TMP=$(mktemp -d /tmp/george-trading-safety-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FINANCE_DIR="$GEORGE_DIR/finance"
export MAKER_DB_PATH="$FINANCE_DIR/maker_orders.db"
export SIM_MAKER_DB_PATH="$FINANCE_DIR/sim_maker_orders.db"
export CARDANO_TEST_MODE=1
mkdir -p "$FINANCE_DIR"
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

test_start "P0 Trading Safety (fail-closed guards)"

describe "Offline guard checks (lib/tools, monkeypatched data)"
CHECK_OUT=$("$PY_BIN" "$LODGE_DIR/tests/trading_safety_checks.py" 2>/dev/null || true)
for name in reactor_mode_fails_closed \
            single_leg_check_fails_closed_on_db_error \
            trend_velocity_pauses_without_data \
            corridors_never_viable_when_vol_unavailable \
            corridors_block_when_ou_verdict_missing \
            cpmm_no_fabricated_reserve \
            cpmm_includes_pool_fee_and_unknown_queue_not_blocking \
            congested_queue_is_no_go \
            token_registry_consistent; do
    it "$name"
    line=$(printf '%s\n' "$CHECK_OUT" | grep -m1 "^$name " || true)
    assert_contains "$line" "$name PASS" "${line:-check did not run}"
done

describe "Retired strategies stay disabled (deployment state)"
REAL_GEORGE="$LODGE_DIR/.george"

it "cointegration cron job header is ENABLED: 0"
if [ -f "$REAL_GEORGE/cron_jobs/cardano_cointegration_reactor.sh" ]; then
    hdr=$(grep -m1 '^# ENABLED:' "$REAL_GEORGE/cron_jobs/cardano_cointegration_reactor.sh" | awk '{print $3}')
    assert_eq "$hdr" "0"
else
    skip "cron job not installed" || true
fi

it "cointegration cron fallback mode is DRY_RUN"
if [ -f "$REAL_GEORGE/cron_jobs/cardano_cointegration_reactor.sh" ]; then
    assert_contains "$(cat "$REAL_GEORGE/cron_jobs/cardano_cointegration_reactor.sh")" 'CARDANO_COINT_CRON_MODE:-DRY_RUN'
else
    skip "cron job not installed" || true
fi

for rid in rx_cardano_cointegration rx_cardano_stop_reactor; do
    it "reactor $rid is disabled"
    if [ -f "$REAL_GEORGE/reactors.json" ] && command -v jq >/dev/null 2>&1; then
        state=$(jq -r --arg id "$rid" '[.reactors[] | select(.id == $id) | .enabled] | if length == 0 then "absent" else (.[0] | tostring) end' "$REAL_GEORGE/reactors.json")
        if [ "$state" = "absent" ]; then
            _test_pass
        else
            assert_eq "$state" "false"
        fi
    else
        skip "reactors.json or jq unavailable" || true
    fi
done

test_end
