#!/bin/bash
# ── Test Suite: P3 Operator escalation ───────────────────────────────────────
# Guards (dedup, rate limit, quiet hours, deferral), inbox fallback, ask/answer, the reactor's
# input validation, '# NOTIFY: escalate' cron parsing and the Discord confirm routing wiring.
# Offline: Discord delivery is injected or unconfigured and the event bus is disabled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$LODGE_DIR/tests/framework.sh"

PY_BIN="$LODGE_DIR/.venv/bin/python"
[ ! -x "$PY_BIN" ] && PY_BIN="python3"

TEST_TMP=$(mktemp -d /tmp/george-escalation-XXXXXX)
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT
export ESCALATIONS_DB_PATH="$TEST_TMP/escalations.db"
export TRADING_DB_PATH="$TEST_TMP/trading.db"
export GEORGE_CONFIG_DIR="$TEST_TMP/nokeys"
export ESCALATION_NO_BUS=1
unset DISCORD_BOT_TOKEN DISCORD_OPERATOR_ID DISCORD_OWNER_ID DISCORD_OWNER_IDS 2>/dev/null || true

test_start "P3 Operator escalation"

describe "Escalation engine (tests/escalation_checks.py)"
CHECK_OUT=$(timeout 120 "$PY_BIN" "$LODGE_DIR/tests/escalation_checks.py" 2>/dev/null || true)
for name in quiet_hours_window dedup_6h rate_limit_4_per_hour quiet_hours_defer_and_urgent_bypass \
            inbox_fallback_without_discord ask_answer_roundtrip delivered_escalation_opens_reply_window \
            expired_plan_not_offered_for_confirm expired_plan_expires_open_ask_and_escalation validation; do
    it "$name"
    line=$(printf '%s\n' "$CHECK_OUT" | grep -m1 "^$name " || true)
    assert_contains "$line" "$name PASS" "${line:-check did not run}"
done

describe "Escalation reactor input validation"
export ESCALATION_LOG="$TEST_TMP/reactor.log"
it "rejects a payload with an invalid escalation id"
bash "$LODGE_DIR/lib/comms/escalation_reactor.sh" operator/escalation '{"id":"E-12; rm -rf /"}'
assert_contains "$(cat "$ESCALATION_LOG" 2>/dev/null)" "rejected payload"

it "ignores an unknown (well-formed) id without starting a George run"
: > "$ESCALATION_LOG"
bash "$LODGE_DIR/lib/comms/escalation_reactor.sh" operator/escalation '{"id":"E-ABCDEF"}'
assert_not_contains "$(cat "$ESCALATION_LOG" 2>/dev/null)" "headless run"

it "reactor is registered on operator/escalation"
if [ -f "$LODGE_DIR/.george/reactors.json" ]; then
    n=$(jq '[.reactors[] | select(.id == "rx_operator_escalation")] | length' "$LODGE_DIR/.george/reactors.json")
    assert_eq "$n" "1"
else
    skip "reactors.json not installed" || true
fi

describe "'# NOTIFY: escalate' cron jobs"
eval "$(sed -n '/^_cron_escalate_from_output() {/,/^}/p' "$LODGE_DIR/lib/sys/cron.sh")"
OUTF="$TEST_TMP/run_output"
cat > "$OUTF" <<'EOF'
recorder ok
ESCALATE: NIGHT pool reserve dropped 30% in an hour
ESCALATE(urgent, wallet_low): wallet below 60 ADA
ESCALATE(normal, night_reserve): explicit subject
not an ESCALATE line
EOF
it "ESCALATE lines become escalations (kind cron/<job>)"
_cron_escalate_from_output "Price-Watch" "$OUTF"
inbox=$(cd "$LODGE_DIR" && "$PY_BIN" lib/comms/escalation.py inbox)
n=$(printf '%s' "$inbox" | jq '[.inbox[] | select(.kind == "cron/price-watch")] | length')
assert_eq "$n" "3"
it "urgent severity is parsed"
assert_eq "$(printf '%s' "$inbox" | jq -r '[.inbox[] | select(.severity == "urgent")] | length')" "1"
it "a repeat of the same subject is deduplicated"
_cron_escalate_from_output "Price-Watch" "$OUTF"
all=$(cd "$LODGE_DIR" && "$PY_BIN" -c "import sys,sqlite3; c=sqlite3.connect(sys.argv[1]); print(c.execute(\"select count(*) from escalations where status='suppressed'\").fetchone()[0])" "$ESCALATIONS_DB_PATH")
assert_eq "$all" "3"
it "header detection uses '# NOTIFY: escalate'"
assert_contains "$(cat "$LODGE_DIR/lib/sys/cron.sh")" "NOTIFY:[[:space:]]*escalate"

describe "Discord reply routing wiring"
BR="$(cat "$LODGE_DIR/lib/comms/discord_bridge.sh")"
it "operator 'confirm P-XXXXXX' calls the verified confirm path"
assert_contains "$BR" "agent_tools.py --origin discord confirm"
it "confirm requires the owner check and a message id"
assert_contains "$BR" 'discord_is_owner "$author_id" "$author"; then'
it "free-text replies to open asks are recorded"
assert_contains "$BR" "escalation.py answer --text"

test_end
