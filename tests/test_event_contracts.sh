#!/usr/bin/env bash
# Event contract registry: orphan CI gate + runtime enforcement (refinement P1/1.1)
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"

LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR
PY="$LODGE_DIR/.venv/bin/python"; [ -x "$PY" ] || PY=python3
REG="$LODGE_DIR/configs/event_contracts.json"

test_start "event contract registry"

describe "registry + static orphan scan"
assert_file_exists "$REG"
out="$("$PY" "$LODGE_DIR/lib/tools/event_contracts.py" static 2>&1)"; rc=$?
assert_eq "$rc" "0" "static audit must be clean (every emitted type contracted): $out"
assert_eq "$(jq -r '.registry_errors | length' <<<"$out" 2>/dev/null)" "0"
assert_eq "$(jq -r '.uncontracted | length' <<<"$out" 2>/dev/null)" "0"
n=$(jq -r '.emitted_types' <<<"$out" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0
assert_gt "$n" 20 "scanner should find the known emitters"

describe "validator"
"$PY" "$LODGE_DIR/lib/tools/event_contracts.py" validate no.such_type '{}' >/dev/null 2>&1
assert_eq "$?" "3"
"$PY" "$LODGE_DIR/lib/tools/event_contracts.py" validate system.job_failure '{"job":"x"}' >/dev/null 2>&1
assert_eq "$?" "4"
"$PY" "$LODGE_DIR/lib/tools/event_contracts.py" validate system.cron_failure '{}' >/dev/null 2>&1
assert_eq "$?" "3" "deprecated types are rejected"

describe "cron job_failure payload satisfies its contract"
ui_step() { :; }; ui_err() { :; }; ui_ok() { :; }; ui_warn() { :; }
source "$LODGE_DIR/lib/sys/cron.sh" 2>/dev/null
p="$(_cron_job_failure_payload demo 2 /nonexistent "" 2>/dev/null)"
"$PY" "$LODGE_DIR/lib/tools/event_contracts.py" validate system.job_failure "$p" >/dev/null 2>&1
assert_eq "$?" "0" "cron payload must validate: $p"

describe "runtime enforcement in event_bus_emit"
export EVENT_BUS_DIR="$GEORGE_TEST_SANDBOX/ipc"
export EVENT_BUS_REACTORS="$GEORGE_TEST_SANDBOX/reactors.json"
export EVENT_BUS_LOG="$EVENT_BUS_DIR/event_bus.log"
export EVENT_BUS_PID_FILE="$EVENT_BUS_DIR/event_bus.pid"
export EVENT_STORE_DB="$GEORGE_TEST_SANDBOX/events.db"
unset _LIB_EVENT_BUS_LOADED
source "$LODGE_DIR/lib/ipc/event_bus.sh"
spool="$EVENT_BUS_DIR/event_spool.ndjson"

EVENT_CONTRACTS_STRICT=1
event_bus_emit "totally.unknown" '{"a":1}' t >/dev/null 2>&1
assert_eq "$?" "3" "strict: uncontracted rejected"
event_bus_emit "system.job_failure" '{"job":"x"}' t >/dev/null 2>&1
assert_eq "$?" "4" "strict: missing required fields rejected"
event_bus_emit "system.job_failure" "$p" t >/dev/null 2>&1
assert_eq "$?" "0" "strict: valid payload accepted"
event_bus_emit "webhook_event" "x" t >/dev/null 2>&1
assert_eq "$?" "0" "strict: test_only allowed inside sandbox"
( unset GEORGE_TEST_SANDBOX; event_bus_emit "webhook_event" "x" t >/dev/null 2>&1 ); 
assert_eq "$?" "3" "strict: test_only rejected outside sandbox"

EVENT_CONTRACTS_STRICT=0
before=$(wc -l < "$spool" 2>/dev/null || echo 0)
event_bus_emit "totally.unknown" '{"a":1}' t >/dev/null 2>&1
assert_eq "$?" "0" "warn mode: still delivered"
after=$(wc -l < "$spool" 2>/dev/null || echo 0)
assert_gt "$after" "$before" "warn mode: envelope spooled"
assert_contains "$(cat "$EVENT_BUS_LOG" 2>/dev/null)" "CONTRACT_WARN"
assert_contains "$(cat "$EVENT_BUS_LOG" 2>/dev/null)" "CONTRACT_REJECT"

describe "sandbox isolation"
assert_not_contains "$EVENT_BUS_DIR" "/opt/blue-lodge/.george" "must not touch live bus"

test_end
