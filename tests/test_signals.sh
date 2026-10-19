#!/bin/bash
# ── Test Suite: P4 S2/S3 signals, shadow simulator, impact study, walk-forward backtest ──
# Offline: temp databases and policy, GeckoTerminal injected. Wraps tests/signals_checks.py.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$LODGE_DIR/tests/framework.sh"

PY_BIN="$LODGE_DIR/.venv/bin/python"
[ ! -x "$PY_BIN" ] && PY_BIN="python3"

test_start "P4 Signals / shadow sim / backtest"

describe "Offline checks (tests/signals_checks.py)"
CHECK_OUT=$(cd "$LODGE_DIR" && timeout 240 "$PY_BIN" "$LODGE_DIR/tests/signals_checks.py" 2>/dev/null || true)
for name in sim_limit_fill_then_close sim_touch_without_haircut_is_not_a_fill sim_resting_until_deadline_known \
            sim_no_exit_on_fill_bar sim_timeout_marks_to_market sim_break_even_floor_on_exit \
            impact_recovers_impulse_response impact_insufficient_data_and_cache backtest_kalman_is_causal \
            backtest_s2_walk_forward_mean_reverting backtest_s2_random_walk_has_no_edge \
            backtest_s3_needs_cex_history backtest_s3_reverting_discount_trades \
            scan_warming_up_then_s2_signal_with_cooldown; do
    it "$name"
    line=$(printf '%s\n' "$CHECK_OUT" | grep -m1 "^$name " || true)
    assert_contains "$line" "$name PASS" "${line:-check did not run}"
done

describe "Wiring"
it "pool recorder cron runs the signal scan"
assert_contains "$(cat "$LODGE_DIR/.george/cron_jobs/pool_recorder.sh" 2>/dev/null || true)" "signals.py\" scan --emit"

it "daily quant research cron runs impact + backtest"
qr="$(cat "$LODGE_DIR/.george/cron_jobs/quant_research.sh" 2>/dev/null || true)"
assert_contains "$qr" "impact.py\" run"
assert_contains "$qr" "backtest.py\" run"

it "CLIs compile"
if (cd "$LODGE_DIR" && "$PY_BIN" -m py_compile lib/tools/quant/signals.py lib/tools/quant/impact.py lib/tools/quant/backtest.py); then
    _test_pass
else
    _test_fail "py_compile failed"
fi

test_end
