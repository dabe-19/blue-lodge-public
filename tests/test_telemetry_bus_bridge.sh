#!/usr/bin/env bash
# Telemetry -> event bus bridge (refinement P1/1.3)
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"

LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR
export EVENT_BUS_DIR="$GEORGE_TEST_SANDBOX/ipc"
export EVENT_BUS_REACTORS="$GEORGE_TEST_SANDBOX/reactors.json"
export EVENT_BUS_LOG="$EVENT_BUS_DIR/event_bus.log"
export EVENT_BUS_PID_FILE="$EVENT_BUS_DIR/event_bus.pid"
export EVENT_STORE_DB="$GEORGE_TEST_SANDBOX/events.db"
export TELEMETRY_DIR="$GEORGE_TEST_SANDBOX/telemetry"
export TELEMETRY_BUS_SYNC=1
export EVENT_CONTRACTS_STRICT=1   # bridged events must satisfy their contracts
unset _LIB_EVENT_BUS_LOADED _LIB_TELEMETRY_LOADED
source "$LODGE_DIR/lib/ipc/event_bus.sh"
source "$LODGE_DIR/lib/agents/telemetry.sh"
SPOOL="$EVENT_BUS_DIR/event_spool.ndjson"

spooled() { jq -c --arg t "$1" 'select(.type == $t)' "$SPOOL" 2>/dev/null; }

test_start "telemetry -> bus bridge"

assert_fn_defined telemetry_bus_bridge

describe "circuit breaker perturbation"
telemetry_record_anomaly "sess_A" "CIRCUIT_BREAKER_PERTURBATION" "TOOL_SEARCH_THRASHING" "inject scoped tools" >/dev/null
ev="$(spooled agent.circuit_breaker | tail -n 1)"
assert_not_empty "$ev" "agent.circuit_breaker must be emitted"
assert_eq "$(jq -r '.payload.session_id' <<<"$ev")" "sess_A"
assert_eq "$(jq -r '.payload.breaker_class' <<<"$ev")" "TOOL_SEARCH_THRASHING"
assert_eq "$(jq -r '.payload.kind' <<<"$ev")" "perturbation"
assert_eq "$(jq -r '.source' <<<"$ev")" "telemetry"

describe "hard trip"
telemetry_record_anomaly "sess_A" "CIRCUIT_BREAKER" "react.sh" "TARGET_FILE_THRASHING: bash_exec x" >/dev/null
ev="$(spooled agent.circuit_breaker | tail -n 1)"
assert_eq "$(jq -r '.payload.breaker_class' <<<"$ev")" "TARGET_FILE_THRASHING"
assert_eq "$(jq -r '.payload.kind' <<<"$ev")" "trip"

describe "empty-turn stall"
telemetry_record_anomaly "sess_A" "PROCESS_STALL" "react.sh" "Circuit breaker tripped: 3 consecutive empty turns" >/dev/null
ev="$(spooled agent.circuit_breaker | tail -n 1)"
assert_eq "$(jq -r '.payload.breaker_class' <<<"$ev")" "EMPTY_TURNS"

describe "tool failure"
telemetry_record_anomaly "sess_B" "SHELL_RUNTIME" "bash_exec" "token=SECRET123 boom" >/dev/null
ev="$(spooled agent.tool_failure | tail -n 1)"
assert_not_empty "$ev" "agent.tool_failure must be emitted"
assert_eq "$(jq -r '.payload.tool' <<<"$ev")" "bash_exec"
assert_eq "$(jq -r '.payload.error_class' <<<"$ev")" "SHELL_RUNTIME"
assert_not_contains "$ev" "SECRET123" "message must be redacted"
assert_match "$(jq -r '.payload.fingerprint' <<<"$ev")" '^[0-9a-f]{12}$'

describe "opt-out"
n0=$(wc -l < "$SPOOL")
TELEMETRY_BUS_BRIDGE=0 telemetry_record_anomaly "sess_C" "SHELL_RUNTIME" "x" "y" >/dev/null
assert_eq "$(wc -l < "$SPOOL")" "$n0" "bridge disabled => no emission"

describe "no contract warnings"
assert_not_contains "$(cat "$EVENT_BUS_LOG" 2>/dev/null)" "CONTRACT_" "bridged events satisfy contracts"

test_end
