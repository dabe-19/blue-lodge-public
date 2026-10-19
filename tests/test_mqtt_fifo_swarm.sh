#!/usr/bin/env bash
# ── Tests: FIFO-Backed MQTT Mesh, Dynamic Remote Node Discovery & Dual-Mode Swarm ──
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export LODGE_DIR

source "$SCRIPT_DIR/framework.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-mqtt-fifo-mesh.XXXXXX")
export GEORGE_DIR="$TEST_TMP/.george"
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"
export MQTT_BRIDGE_DIR="$GEORGE_DIR/swarm/bridges"
mkdir -p "$GEORGE_DIR"

trap 'rm -rf "$TEST_TMP" 2>/dev/null || true' EXIT

source "$LODGE_DIR/lib/core/endpoints.sh"
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh"
source "$LODGE_DIR/lib/comms/mqtt.sh"
source "$LODGE_DIR/lib/ipc/mqtt_fifo_bridge.sh"
source "$LODGE_DIR/lib/sys/remote.sh"
source "$LODGE_DIR/lib/agents/swarm.sh"

test_start "FIFO-Backed MQTT Mesh, Dynamic Remote Node Discovery & Dual-Mode Swarm"

describe "MQTT Client Argument Builder (lib/comms/mqtt.sh)"

it "splits host:port in MQTT_BROKER and omits empty -i client_id" && {
    MQTT_BROKER="127.0.0.1:1883"
    MQTT_PORT="1883"
    MQTT_CLIENT_ID=""
    _mqtt_build_args
    assert_eq "${_MQTT_ARGS[0]}" "-h"
    assert_eq "${_MQTT_ARGS[1]}" "127.0.0.1"
    assert_eq "${_MQTT_ARGS[2]}" "-p"
    assert_eq "${_MQTT_ARGS[3]}" "1883"
    has_empty_i=0
    for idx in "${!_MQTT_ARGS[@]}"; do
        if [ "${_MQTT_ARGS[$idx]}" = "-i" ] && [ -z "${_MQTT_ARGS[$((idx+1))]:-}" ]; then
            has_empty_i=1
        fi
    done
    assert_eq "$has_empty_i" "0"
}

describe "FIFO-MQTT Bridge Helpers & Credit Window (lib/ipc/mqtt_fifo_bridge.sh)"

it "sanitizes node_id into valid FIFO channel names" && {
    c1=$(_mqtt_bridge_chan_id "george-home" "node")
    c2=$(_mqtt_bridge_chan_id "george-home" "node_res")
    assert_eq "$c1" "node_george-home"
    assert_eq "$c2" "node_res_george-home"
}

it "opens 1-slot credit-controlled FIFO channels and enforces backpressure on LWT OFFLINE" && {
    ipc_init
    ipc_channel_open "node_test-worker" 1 300 "$IPC_PRIO_SYSTEM" "stream"
    assert_ok $?

    st=$(ipc_status "node_test-worker")
    cred=$(echo "$st" | jq -r '.credits')
    bp=$(echo "$st" | jq -r '.backpressure')
    assert_eq "$cred" "1"
    assert_eq "$bp" "false"

    # Simulate LWT OFFLINE -> pause channel
    ipc_flow_pause "node_test-worker"
    st=$(ipc_status "node_test-worker")
    bp=$(echo "$st" | jq -r '.backpressure')
    assert_eq "$bp" "true"

    # Simulate ONLINE -> resume & unstick channel
    ipc_flow_resume "node_test-worker"
    ipc_flow_unstick "node_test-worker"
    st=$(ipc_status "node_test-worker")
    bp=$(echo "$st" | jq -r '.backpressure')
    cred=$(echo "$st" | jq -r '.credits')
    assert_eq "$bp" "false"
    assert_eq "$cred" "1"

    ipc_channel_close "node_test-worker"
}

describe "Dynamic Tier Updates & Node Probe (lib/core/endpoints.sh & lib/sys/remote_node_probe.py)"

it "dynamically updates Tier 2 in endpoints.conf via endpoints_update_tier" && {
    endpoints_init
    endpoints_update_tier 2 \
        "NAME=george-home" \
        "URL=http://127.0.0.1:18080" \
        "MODEL=gemma4-v2-Q4_K_M" \
        "HARDWARE=AMD Radeon RX 5700 XT (8GB VULKAN)" \
        "CONTEXT=12288" \
        "ENABLED=1"
    assert_ok $?

    _endpoints_load_config
    assert_eq "$TIER2_NAME" "george-home"
    assert_eq "$TIER2_URL" "http://127.0.0.1:18080"
    assert_eq "$TIER2_MODEL" "gemma4-v2-Q4_K_M"
    assert_eq "$TIER2_HARDWARE" "AMD Radeon RX 5700 XT (8GB VULKAN)"
    assert_eq "$TIER2_CONTEXT" "12288"
    assert_eq "$TIER2_ENABLED" "1"
}

it "executes remote_node_probe.py and returns valid JSON hardware/model schema" && {
    probe_json=$(python3 "$LODGE_DIR/lib/sys/remote_node_probe.py")
    assert_ok $?
    st=$(echo "$probe_json" | jq -r '.status')
    assert_eq "$st" "ok"
}

test_end
