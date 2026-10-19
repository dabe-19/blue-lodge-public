#!/bin/bash
# ── Tests: Cardano DEX Arbitrage Graph (5 Phases) ─────────────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/cardano_arbitrage_graph.sh" 2>/dev/null || true
source "$LODGE_DIR/commands/trading.sh" 2>/dev/null || true

# Test sandbox isolation
TEST_TMP=$(mktemp -d /tmp/george-cardano-graph-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FINANCE_DIR="$GEORGE_DIR/finance"
export DOSSIER_DIR="$TEST_TMP/dossiers/finance"
export GRAPH_TELEMETRY="${FINANCE_DIR}/cardano_graph_latest.json"
export GRAPH_TRADES_LOG="${DOSSIER_DIR}/trades.jsonl"
export GRAPH_DRY_RUN_LOG="${DOSSIER_DIR}/dry_run_simulations.jsonl"
export GRAPH_SCAN_DOSSIER="${DOSSIER_DIR}/cardano_arbitrage_scan.json"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "Sovereign Cardano DEX Arbitrage Graph Engine"

describe "cardano_graph_init"
it "creates finance and dossier directories" && {
    cardano_graph_init
    assert_dir_exists "$FINANCE_DIR"
    assert_dir_exists "$DOSSIER_DIR"
}

describe "Blockfrost URL normalization"
it "normalizes base URLs for Blockfrost compatibility" && {
    py_bin="$LODGE_DIR/.venv/bin/python"
    [ ! -x "$py_bin" ] && py_bin="python3"

    res=$("$py_bin" -c "
from lib.tools.cardano_trader import normalize_blockfrost_base_url
assert normalize_blockfrost_base_url(None) == 'https://cardano-mainnet.blockfrost.io/api'
assert normalize_blockfrost_base_url('https://custom.endpoint/api/v0') == 'https://custom.endpoint/api'
assert normalize_blockfrost_base_url('https://custom.endpoint/api') == 'https://custom.endpoint/api'
print('OK')
" 2>/dev/null)
    assert_eq "$res" "OK"
}

describe "Phase 1: Capital Gatekeeper"
it "verifies hot wallet balance and enforces 10 ADA reserve floor" && {
    out=$(cardano_graph_phase1_capital)
    assert_not_empty "$out"
    pass=$(echo "$out" | jq -r '.gate_pass')
    assert_eq "$pass" "true"
    total=$(echo "$out" | jq -r '.total_ada')
    total_int="${total%.*}"
    assert_gt "$total_int" 10
}

describe "Phase 2: AMM Protocol Hygiene"
it "whitelists active AMMs and excludes zombie protocols" && {
    out=$(cardano_graph_phase2_hygiene)
    assert_not_empty "$out"
    wl_count=$(echo "$out" | jq -r '.whitelisted_count')
    assert_gt "$wl_count" 3
    bl_count=$(echo "$out" | jq -r '.blacklisted_count')
    assert_gt "$bl_count" 4
}

describe "Deterministic 5-Phase Graph Run (Dry-Run Simulation)"
it "executes all 5 phases and records telemetry" && {
    out=$(cardano_graph_run --dry-run --force-sim --json)
    assert_not_empty "$out"
    status=$(echo "$out" | jq -r '.status // "error"')
    assert_eq "$status" "success"
    assert_file_exists "$GRAPH_DRY_RUN_LOG"
    dry_count=$(wc -l < "$GRAPH_DRY_RUN_LOG")
    assert_gt "$dry_count" 0
    # Ledger purity: verify trades.jsonl is not polluted with dry-runs
    if [ -f "$GRAPH_TRADES_LOG" ]; then
        trades_count=$(wc -l < "$GRAPH_TRADES_LOG")
        assert_eq "$trades_count" 0
    fi
}

describe "Slash Command: /trading graph"
it "invokes the graph cleanly through the command dispatcher" && {
    out=$(cmd_trading "graph dry-run")
    assert_not_empty "$out"
}

describe "Slash Command: /trading mode"
it "inspects and sets operating mode with guardrails" && {
    out=$(cmd_trading "mode")
    assert_not_empty "$out"
    out_manual=$(cmd_trading "mode MANUAL")
    assert_not_empty "$out_manual"
}

describe "Slash Command: /trading stale"
it "scans for resting orders past expiration or with drift" && {
    out=$(cmd_trading "stale scan")
    assert_not_empty "$out"
}

test_end
