#!/usr/bin/env bash
# ── Test Suite: Sovereign Multi-Chain Trading & Lending Platform ──────────────
# Verifies:
#   1. Quantitative OU Mean-Reversion & Residual Time-Series Analyzer
#   2. Defensible Volatility Corridors & Dynamic Friction Floors
#   3. Sovereign Multi-Chain Wallet Manager (Cardano, Polygon, Ethereum)
#   4. Cross-Chain Yield & Micro-Loan Underwriter
#   5. AMM Liquidity Imbalance & Stale Pool Squeeze Detector
#   6. Automated Trade Event-Bus Triggers & FIFO Reactors
#   7. CLI Command Router (Sovereign Desk vs. Isolated Simulated Sandbox)
# ─────────────────────────────────────────────────────────────────────────────

set -u

LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LODGE_DIR"

PASS=0
FAIL=0

test_match() {
    local desc="$1"
    local cmd="$2"
    local pattern="$3"
    echo -n "  ● Testing: $desc ... "
    local out
    out=$(eval "$cmd" 2>/dev/null || true)
    if echo "$out" | grep -E -q "$pattern"; then
        echo -e "\033[0;32mPASSED\033[0m"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAILED\033[0m"
        echo "    Pattern '$pattern' not found in command output."
        FAIL=$((FAIL + 1))
    fi
}

test_bool() {
    local desc="$1"
    local cmd="$2"
    echo -n "  ● Testing: $desc ... "
    if eval "$cmd" > /dev/null 2>&1; then
        echo -e "\033[0;32mPASSED\033[0m"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAILED\033[0m"
        FAIL=$((FAIL + 1))
    fi
}

echo "================================================================================"
echo "    RUNNING TEST HARNESS: SOVEREIGN MULTI-CHAIN CRYPTO SUITE"
echo "================================================================================"

PY_BIN="$LODGE_DIR/.venv/bin/python"

# 1. Quant Time-Series & Ornstein-Uhlenbeck Model
echo "--- [1] Quantitative Time-Series & Ornstein-Uhlenbeck Analyzer ---"
test_match "OU Estimator on mean-reverting series" \
    "$PY_BIN $LODGE_DIR/lib/tools/quant/timeseries_residual.py --prices '0.40,0.42,0.39,0.41,0.40,0.42,0.40,0.41' --ou" \
    "FAST_MEAN_REVERTING"

test_match "OU Estimator on explosive/trending series" \
    "$PY_BIN $LODGE_DIR/lib/tools/quant/timeseries_residual.py --prices '0.10,0.20,0.50,1.20,3.00,8.00,25.00' --ou" \
    "MOMENTUM_TRENDING_OR_EXPLOSIVE"

# 2. Volatility Engine & Defensible Corridors
echo "--- [2] Defensible Volatility Engine & Friction Floors ---"
test_match "Volatility engine outputs defensible corridors" \
    "$PY_BIN $LODGE_DIR/lib/tools/cardano_volatility_engine.py --asset SNEK --json" \
    "defensible_corridors"

test_match "Volatility engine calculates OU metrics" \
    "$PY_BIN $LODGE_DIR/lib/tools/cardano_volatility_engine.py --asset SNEK --json" \
    "half_life_hours"

# 3. Multi-Chain Wallet Manager (Cardano, Polygon, Ethereum)
echo "--- [3] Sovereign Multi-Chain Wallet Manager ---"
# Wallet + reactor checks read deployment state (wallet config, live reactors.json).
LIVE_STATE=0; [ -f "$LODGE_DIR/.george/reactors.json" ] && [ "${GEORGE_TEST_ALLOW_LIVE_STATE:-1}" = "1" ] && LIVE_STATE=1
if [ "$LIVE_STATE" = "1" ]; then
test_match "Multi-chain wallet returns status for Cardano, Polygon, and Ethereum" \
    "$PY_BIN $LODGE_DIR/lib/tools/sovereign_multichain_wallet.py --json" \
    "ethereum"

test_match "Ethereum USDC transfer simulation (dry-run)" \
    "$PY_BIN $LODGE_DIR/lib/tools/sovereign_multichain_wallet.py --eth-transfer-usdc 5.0 --to 0x000000000000000000000000000000000000dEaD" \
    "signed_tx_hash"

test_match "Unified wallet_status.py includes Ethereum" \
    "$PY_BIN $LODGE_DIR/lib/tools/wallet_status.py" \
    "ethereum"
else
    echo "  ● Skipping wallet status checks (no deployment state in this tree)"
fi

# 4. Sovereign Lending (shim over sovereign_lending.py / sovereign_fund.py; live data only)
echo "--- [4] Sovereign Lending Underwriter (calibrated) ---"
test_match "Lending scan returns live DeFiLlama yields + loan book" \
    "$PY_BIN $LODGE_DIR/lib/tools/crosschain_lending_underwriter.py --json" \
    '"yields"'

test_match "Microloan simulation returns a calibrated verdict" \
    "$PY_BIN $LODGE_DIR/lib/tools/crosschain_lending_underwriter.py --simulate --asset DJED --units 60 --req-usd 25 --apr 12 --json" \
    '"verdict": "(APPROVE|COUNTER|REJECT)"'

test_match "Microloan simulation rejects an unsafe LTV (100 SNEK for 90 USD)" \
    "$PY_BIN $LODGE_DIR/lib/tools/crosschain_lending_underwriter.py --simulate --asset SNEK --units 100 --req-usd 90 --apr 12 --json" \
    '"verdict": "REJECT"'

test_match "Native lending underwriter emits sovereign_underwriting/v1" \
    "$PY_BIN $LODGE_DIR/lib/tools/sovereign_lending.py underwrite --collateral=SNEK --units=20000 --principal=20 --term-days=30 --apr=25" \
    "sovereign_underwriting/v1"

test_match "Fund policy is readable" \
    "$PY_BIN $LODGE_DIR/lib/tools/sovereign_fund.py policy --json" \
    "targets_pct"

# 5. Pool health (live GeckoTerminal; schema pool_health/v2)
echo "--- [5] DEX Pool Health ---"
test_match "Pool health audits tracked pools" \
    "$PY_BIN $LODGE_DIR/lib/tools/dex_liquidity_squeeze_detector.py --json" \
    "total_pools_audited"

test_match "Unknown pair reports NO_DATA instead of fabricated metrics" \
    "$PY_BIN $LODGE_DIR/lib/tools/dex_liquidity_squeeze_detector.py --pair FOO/ADA --json" \
    "NO_DATA"

test_bool "Quick check exits non-zero when a pair cannot be verified" \
    "! $PY_BIN $LODGE_DIR/lib/tools/dex_liquidity_squeeze_detector.py --pair FOO/ADA --check-trap"

# 6. Event Bus Triggers & Reactors
echo "--- [6] Automated Trade Event Bus Triggers & Reactors ---"
if [ "$LIVE_STATE" = "1" ]; then
test_bool "Reactor registry includes rx_stale_order_canceller" \
    "grep -q 'rx_stale_order_canceller' $LODGE_DIR/.george/reactors.json"
else
    echo "  ● Skipping live reactor registry check (no deployment state in this tree)"
fi

test_match "Trade event trigger displays registered reactors" \
    "$LODGE_DIR/lib/tools/trade_event_trigger.sh status" \
    "rx_maker_sell"

test_match "Trade event trigger runs automated stale audit" \
    "$LODGE_DIR/lib/tools/trade_event_trigger.sh stale-scan" \
    "Auditing"

# 7. CLI Command Routing & Sandbox Isolation
echo "--- [7] CLI Interface & Sandbox Isolation ---"
test_match "Main /trading desk defaults to sovereign multi-chain desk" \
    "$LODGE_DIR/commands/trading.sh status" \
    "SOVEREIGN MULTI-CHAIN DESK"

test_match "Simulated paper trading sandbox relocated under /trading sim" \
    "$LODGE_DIR/commands/trading.sh sim status" \
    "Simulated Trading Sandbox"

test_match "George financial researcher performs hybrid crypto research" \
    "$PY_BIN $LODGE_DIR/lib/tools/finance_researcher.py --crypto SNEK" \
    "dossier_path"

# 8. Tool: Probabilistic Limit Order Fill Forecaster
echo "--- [8] Probabilistic Limit Order Fill Forecaster (Path D) ---"
test_match "Limit order fill forecaster produces multi-method fill probabilities (v2)" \
    "$PY_BIN $LODGE_DIR/lib/tools/limit_order_forecaster.py --asset IAG --target-price 0.095311 --amount 1625.32 --no-dossier --json" \
    "limit_order_forecast/v2"

test_match "CLI command /trading forecast produces dossier report" \
    "$LODGE_DIR/commands/trading.sh 'forecast IAG 0.095311 1625.32'" \
    "Probabilistic Limit Order Fill Forecast"


echo "================================================================================"
echo "    SUMMARY: $PASS PASSED, $FAIL FAILED"
echo "================================================================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
