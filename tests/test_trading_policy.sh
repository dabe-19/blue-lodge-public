#!/bin/bash
# ── Test Suite: P2/P4 Trading policy engine ───────────────────────────────────
# Tiers, fail-closed policy, capital rules, plan TTL / hash / freshness, single-use confirm
# tokens, standing orders, freeze, simulated strategies, Discord confirm verification, journal
# markouts and trips, the position watcher's Tier A-only pass, gates and re-lock (offline,
# everything injected), plus George's tool surface: hidden legacy tools and the bash guard.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$LODGE_DIR/tests/framework.sh"

PY_BIN="$LODGE_DIR/.venv/bin/python"
[ ! -x "$PY_BIN" ] && PY_BIN="python3"

test_start "P2/P4 Trading policy engine"

describe "Offline engine checks (tests/trading_policy_checks.py)"
CHECK_OUT=$(timeout 180 "$PY_BIN" "$LODGE_DIR/tests/trading_policy_checks.py" 2>/dev/null || true)
for name in tiers_classify policy_fails_closed capital_rules tier_b_needs_token \
            confirm_token_single_use_and_bound plan_ttl_and_tamper stale_plan_rejected \
            standing_order_cover simulated_and_disabled_strategies drawdown_freeze \
            tier_a_exit_executes discord_confirm_verification journal_markouts \
            watcher_journal_hook_trips watcher_auto_pass gates_gate1_gate2_relock \
            review_legacy_buy_is_tier_b batch_plans_ttl_refresh_and_multi_confirm; do
    it "$name"
    line=$(printf '%s\n' "$CHECK_OUT" | grep -m1 "^$name " || true)
    assert_contains "$line" "$name PASS" "${line:-check did not run}"
done

describe "George's tool surface (lib/tools/native_tools.sh)"
NT="$LODGE_DIR/lib/tools/native_tools.sh"
eval "$(sed -n '/^_trading_bash_guard() {/,/^}/p' "$NT")"
eval "$(grep -m1 '^_GEORGE_HIDDEN_TOOLS=' "$NT")"

for t in crypto_send cardano_dex_swap crypto_place_limit crypto_reclaim_order cardano_stop_manage; do
    it "legacy/unsafe tool $t is hidden from George"
    assert_contains ",$_GEORGE_HIDDEN_TOOLS," ",$t,"
done

for t in crypto_review crypto_scan crypto_plan crypto_execute crypto_standing_order crypto_journal operator_notify operator_ask; do
    it "schema for $t exists"
    n=$(jq --arg t "$t" '[.[] | select(.function.name == $t)] | length' "$LODGE_DIR/data/schemas/native_tools.json" 2>/dev/null || echo 0)
    assert_eq "$n" "1"
done

blocked=(
  "python3 lib/tools/trading/agent_tools.py confirm --plan P-ABC123 --via web"
  "cat .george/secrets/trading_confirm.key"
  "sqlite3 .george/finance/trading.db 'delete from plans'"
  "echo '{}' > .george/finance/trading_policy.json"
  "sed -i s/false/true/ .george/finance/trading_policy.json"
  "python3 lib/tools/minswap_v2.py --execute buy SNEK"
  "python3 lib/tools/cardano_orders.py reclaim abc#0"
  "/trading maker SNEK 50"
  "python3 lib/tools/trading/gates.py unfreeze --reason x"
  "python3 lib/tools/trading/gates.py set-state --strategy S2_shock_fade --state live --reason x"
)
for c in "${blocked[@]}"; do
    it "bash guard blocks: ${c:0:60}"
    if _trading_bash_guard "$c" >/dev/null; then _test_pass; else _test_fail "not blocked"; fi
done

allowed=(
  "python3 lib/tools/trading/agent_tools.py review"
  "cat .george/finance/trading_policy.json"
  "python3 lib/tools/trading/gates.py status"
  "ls -la dossiers"
)
for c in "${allowed[@]}"; do
    it "bash guard allows: $c"
    if _trading_bash_guard "$c" >/dev/null; then _test_fail "wrongly blocked"; else _test_pass; fi
done

it "file_write/file_edit refuse Tier C paths"
assert_contains "$(cat "$NT")" 'trading_policy\.json|trading\.db|escalations\.db|trading_confirm\.key'

it "crypto_execute refused inside headless escalation runs"
assert_contains "$(cat "$NT")" 'crypto_execute is not available while writing an escalation'

describe "Live-path wiring"
it "stop reactor live mode fails closed (policy momentum_stop_buy disabled)"
out=$(cd "$LODGE_DIR" && "$PY_BIN" -c "import sys; sys.path.insert(0,'.'); from lib.tools.cardano_stop_reactor import is_live_mode_armed as f; print(f())" 2>/dev/null | tail -1)
assert_eq "$out" "False"

it "position watcher dry run returns JSON"
TMPD=$(mktemp -d)
wout=$(cd "$LODGE_DIR" && TRADING_DB_PATH="$TMPD/t.db" ESCALATIONS_DB_PATH="$TMPD/e.db" MARKET_DB_PATH="$TMPD/m.db" \
       CARDANO_TEST_MODE=1 timeout 200 "$PY_BIN" lib/tools/trading/watcher.py --dry-run 2>/dev/null | tail -1 || true)
rm -rf "$TMPD"
if printf '%s' "$wout" | jq -e '.dry_run == true' >/dev/null 2>&1; then _test_pass; else _test_fail "${wout:0:200}"; fi

test_end
