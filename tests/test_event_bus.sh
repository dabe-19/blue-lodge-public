#!/bin/bash
# ── Tests: Sovereign POSIX Reactive Event Bus & Autonomic Engine ──────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh"
source "$LODGE_DIR/lib/ipc/event_bus.sh"
source "$LODGE_DIR/commands/react.sh"

TEST_TMP=$(mktemp -d /tmp/george-event-bus-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"
export EVENT_BUS_DIR="$FIFO_IPC_DIR"
export EVENT_BUS_FIFO="$FIFO_IPC_DIR/event_bus.fifo"
export EVENT_BUS_REACTORS="$GEORGE_DIR/reactors.json"
export EVENT_BUS_LOG="$FIFO_IPC_DIR/event_bus.log"
export EVENT_BUS_PID_FILE="$FIFO_IPC_DIR/event_bus.pid"
export EVENT_BUS_LOCK="$FIFO_IPC_DIR/locks/event_bus.lock"
export EVENT_BUS_COOLDOWNS_DIR="$FIFO_IPC_DIR/cooldowns"

cleanup() {
    event_bus_stop >/dev/null 2>&1 || true
    rm -rf "$TEST_TMP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

test_start "Sovereign POSIX Reactive Event Bus & Autonomic Engine"

describe "event_bus_init"

it "creates FIFO, directories, and empty reactors ledger" && {
    event_bus_init
    assert_ok $?

    [ -p "$EVENT_BUS_FIFO" ]
    assert_ok $? "EVENT_BUS_FIFO should be a named pipe"

    assert_file_exists "$EVENT_BUS_REACTORS" "Reactors file should exist"
    
    rcount=$(jq '.reactors | length' "$EVENT_BUS_REACTORS" 2>/dev/null)
    assert_eq "$rcount" "0" "Initial reactors count should be 0"

    assert_dir_exists "$EVENT_BUS_COOLDOWNS_DIR"
}

describe "Reactor Registry Operations (Add, List, Toggle, Remove)"

it "registers new reactors with pattern matching and debounce" && {
    event_bus_reactor_add "alert_reactor" "system_alert" "CRITICAL" "logger critical alert" 5
    assert_ok $?

    count=$(jq '.reactors | length' "$EVENT_BUS_REACTORS")
    assert_eq "$count" "1"

    id=$(jq -r '.reactors[0].id' "$EVENT_BUS_REACTORS")
    type=$(jq -r '.reactors[0].event_type' "$EVENT_BUS_REACTORS")
    pat=$(jq -r '.reactors[0].pattern' "$EVENT_BUS_REACTORS")
    act=$(jq -r '.reactors[0].action' "$EVENT_BUS_REACTORS")
    deb=$(jq -r '.reactors[0].debounce_secs' "$EVENT_BUS_REACTORS")
    en=$(jq -r '.reactors[0].enabled' "$EVENT_BUS_REACTORS")

    assert_eq "$id" "alert_reactor"
    assert_eq "$type" "system_alert"
    assert_eq "$pat" "CRITICAL"
    assert_eq "$act" "logger critical alert"
    assert_eq "$deb" "5"
    assert_eq "$en" "true"
}

it "lists registered reactors in JSON view" && {
    json_list=$(reactor_list)
    assert_ok $?
    assert_contains "$json_list" "alert_reactor"
    assert_contains "$json_list" "system_alert"
}

it "toggles reactor state between enabled and disabled" && {
    event_bus_reactor_toggle "alert_reactor"
    assert_ok $?

    en=$(jq -r '.reactors[0].enabled' "$EVENT_BUS_REACTORS")
    assert_eq "$en" "false"

    event_bus_reactor_toggle "alert_reactor"
    assert_ok $?

    en=$(jq -r '.reactors[0].enabled' "$EVENT_BUS_REACTORS")
    assert_eq "$en" "true"
}

it "removes a registered reactor by ID" && {
    event_bus_reactor_remove "alert_reactor"
    assert_ok $?

    count=$(jq '.reactors | length' "$EVENT_BUS_REACTORS")
    assert_eq "$count" "0"
}

describe "Circuit Breaker & Debounce Suppression"

it "suppresses actions when cooldown debounce is active" && {
    event_bus_reactor_add "deb_test" "ping" ".*" "echo ping" 5
    
    now_val=$(_eb_now)
    echo "$now_val" > "$EVENT_BUS_COOLDOWNS_DIR/deb_test.ts"

    # With debounce 5 and cooldown timestamp written now, dispatch should debounce
    envelope=$(jq -n -c \
        --arg id "evt_deb_1" \
        --arg type "ping" \
        --arg src "test" \
        --argjson pl '{"msg":"test"}' \
        --argjson dp 0 \
        --argjson ts "$now_val" \
        '{event_id: $id, type: $type, source: $src, payload: $pl, depth: $dp, timestamp: $ts}')

    event_bus_dispatch_single "$envelope"
    assert_ok $?

    # Verify log recorded debounce suppression
    log_content=$(cat "$EVENT_BUS_LOG" 2>/dev/null || echo "")
    assert_contains "$log_content" "DEBOUNCE"

    event_bus_reactor_remove "deb_test"
}

it "circuit breaker blocks events exceeding max recursion depth" && {
    # Emitting with depth 4 when max_depth is 3 should halt cascade
    envelope=$(jq -n -c \
        --arg id "evt_recurse_1" \
        --arg type "cascade_event" \
        --arg src "loop_src" \
        --argjson pl '{"data":"overflow"}' \
        --argjson dp 4 \
        --argjson ts $(_eb_now) \
        '{event_id: $id, type: $type, source: $src, payload: $pl, depth: $dp, timestamp: $ts}')

    event_bus_dispatch_single "$envelope"
    assert_ok $?

    # Verify log recorded recursion circuit breaker warning
    assert_file_exists "$EVENT_BUS_LOG"
    log_content=$(cat "$EVENT_BUS_LOG")
    assert_contains "$log_content" "CIRCUIT_BREAKER"
}

describe "End-to-End Daemon Event Dispatch & Execution"

it "starts event bus daemon, dispatches event to matching reactor, and stops" && {
    out_file="$TEST_TMP/reaction_result.txt"
    rm -f "$out_file"

    # Register reactor that writes payload to out_file
    event_bus_reactor_add "file_writer_reactor" "webhook_event" "SUCCESS" "echo \$EVENT_PAYLOAD > '$out_file'" 0
    assert_ok $?

    # Start the Event Bus daemon
    event_bus_start
    assert_ok $?

    # Verify daemon is running
    event_bus_is_running
    assert_ok $? "Daemon should be running"

    # Emit an event that matches pattern SUCCESS
    event_bus_emit "webhook_event" "SUCCESS: order_99482_processed" "test_runner"
    assert_ok $?

    # Allow brief window for FIFO read and subshell execution
    waited=0
    while [ $waited -lt 30 ]; do
        if [ -f "$out_file" ] && [ -s "$out_file" ]; then
            break
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    assert_file_exists "$out_file" "Reaction output file should be created"
    result=$(cat "$out_file" 2>/dev/null || echo "")
    assert_contains "$result" "SUCCESS: order_99482_processed"

    # Stop the daemon
    event_bus_stop
    assert_ok $?

    event_bus_is_running
    assert_fail $? "Daemon should be stopped"
}

describe "CLI /react Integration"

it "executes /react commands cleanly without error" && {
    cmd_react "status"
    assert_ok $?

    cmd_react "list"
    assert_ok $?

    cmd_react "add cli_test_reactor telemetry HIGH_TEMP echo_ALERT --debounce 3"
    assert_ok $?

    count=$(jq '.reactors | length' "$EVENT_BUS_REACTORS")
    assert_eq "$count" "2"

    cmd_react "toggle cli_test_reactor"
    assert_ok $?

    cmd_react "remove cli_test_reactor"
    assert_ok $?

    count=$(jq '.reactors | length' "$EVENT_BUS_REACTORS")
    assert_eq "$count" "1"
}

test_end
