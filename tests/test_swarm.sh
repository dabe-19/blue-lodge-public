#!/bin/bash
# ── Tests: lib/swarm.sh ────────────────────────────────────────
# Unit and integration tests for Blue Lodge Multi-Node Swarm.
# Uses mock mosquitto_pub/mosquitto_sub for fast, reliable verification.

source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/mqtt.sh"
source "$LODGE_DIR/lib/swarm.sh"

test_start "lib/swarm.sh — Multi-Node Swarm & MQTT Coordination"

_SWARM_TEST_DIR=""
_SWARM_MOCK_BIN=""

_swarm_test_setup() {
    _SWARM_TEST_DIR=$(test_tmpdir)
    _SWARM_MOCK_BIN="$_SWARM_TEST_DIR/bin"
    mkdir -p "$_SWARM_MOCK_BIN"

    export GEORGE_DIR="$_SWARM_TEST_DIR/.george"
    export GEORGE_CONFIG_DIR="$GEORGE_DIR"
    export SWARM_DIR="$GEORGE_DIR/swarm"
    export SWARM_REGISTRY="$SWARM_DIR/nodes.json"
    export SWARM_CONFIG="$SWARM_DIR/swarm.conf"
    export SWARM_QUEUE_FILE="$SWARM_DIR/queue.json"
    mkdir -p "$SWARM_DIR"

    export MQTT_CONFIG="$GEORGE_DIR/mqtt.conf"
    export MQTT_DB="$GEORGE_DIR/mqtt.db"
    export MQTT_BROKER="test.broker:1883"

    # Create mock mosquitto_pub that logs calls
    cat > "$_SWARM_MOCK_BIN/mosquitto_pub" << 'MOCK'
#!/bin/bash
echo "PUB: $*" >> "${SWARM_MOCK_LOG:-/tmp/swarm_mock.log}"
exit 0
MOCK
    chmod +x "$_SWARM_MOCK_BIN/mosquitto_pub"

    # Create mock mosquitto_sub
    cat > "$_SWARM_MOCK_BIN/mosquitto_sub" << 'MOCK'
#!/bin/bash
echo "SUB: $*" >> "${SWARM_MOCK_LOG:-/tmp/swarm_mock.log}"
if [ -n "${SWARM_MOCK_SUB_OUTPUT:-}" ]; then
    echo "$SWARM_MOCK_SUB_OUTPUT"
fi
exit 0
MOCK
    chmod +x "$_SWARM_MOCK_BIN/mosquitto_sub"

    export SWARM_MOCK_LOG="$_SWARM_TEST_DIR/mock.log"
    export PATH="$_SWARM_MOCK_BIN:$PATH"
}

_swarm_test_teardown() {
    [ -n "$_SWARM_TEST_DIR" ] && rm -rf "$_SWARM_TEST_DIR"
}

# ── 1. JSON-RPC Framing Helpers ──────────────────────────────────────
describe "JSON-RPC 2.0 Framing"

_swarm_test_setup

it "creates valid json-rpc 2.0 request" && {
    req=$(swarm_rpc_req "req-1" "repl/exec" '{"command":"/status"}')
    v_rpc=$(echo "$req" | jq -r '.jsonrpc')
    v_id=$(echo "$req" | jq -r '.id')
    v_m=$(echo "$req" | jq -r '.method')
    v_cmd=$(echo "$req" | jq -r '.params.command')
    assert_eq "$v_rpc" "2.0"
    assert_eq "$v_id" "req-1"
    assert_eq "$v_m" "repl/exec"
    assert_eq "$v_cmd" "/status"
}

it "creates valid json-rpc 2.0 response" && {
    resp=$(swarm_rpc_resp "req-1" '{"exit_code":0, "status":"DONE"}')
    v_id=$(echo "$resp" | jq -r '.id')
    v_code=$(echo "$resp" | jq -r '.result.exit_code')
    assert_eq "$v_id" "req-1"
    assert_eq "$v_code" "0"
}

it "creates valid json-rpc 2.0 chunk notification" && {
    chunk=$(swarm_rpc_chunk "req-1" "streaming output line\n")
    v_m=$(echo "$chunk" | jq -r '.method')
    v_id=$(echo "$chunk" | jq -r '.params.id')
    v_txt=$(echo "$chunk" | jq -r '.params.text')
    assert_eq "$v_m" "repl/chunk"
    assert_eq "$v_id" "req-1"
    assert_contains "$v_txt" "streaming output line"
}

it "creates valid json-rpc 2.0 error" && {
    err=$(swarm_rpc_err "req-1" 403 "Permission denied")
    v_c=$(echo "$err" | jq -r '.error.code')
    v_msg=$(echo "$err" | jq -r '.error.message')
    assert_eq "$v_c" "403"
    assert_eq "$v_msg" "Permission denied"
}

_swarm_test_teardown

# ── 2. Master Node Initialization & Host Mode ─────────────────────────
describe "Master Node Hosting"

_swarm_test_setup

it "initializes master host role and registry" && {
    swarm_host "127.0.0.1:1883" >/dev/null 2>&1
    assert_eq "$SWARM_ROLE" "master"
    assert_file_exists "$SWARM_REGISTRY"
    m_count=$(jq '. | length' "$SWARM_REGISTRY")
    assert_eq "$m_count" "1"
    m_role=$(jq -r '.[0].role' "$SWARM_REGISTRY")
    assert_eq "$m_role" "master"
    m_status=$(jq -r '.[0].status' "$SWARM_REGISTRY")
    assert_eq "$m_status" "ONLINE"
}

_swarm_test_teardown

# ── 3. Swarm Handshake & Worker Join ─────────────────────────────────
describe "Worker Node Join & Handshake"

_swarm_test_setup

it "handles node/join handshake on master" && {
    swarm_host "127.0.0.1:1883" >/dev/null 2>&1

    join_json=$(swarm_rpc_req "join-123" "node/join" '{"node_id":"worker-alpha", "host":"remote-host", "tier":"2", "gpu":"RTX 4090"}')
    _swarm_master_handle_message "$join_json"

    # Verify worker added to registry
    w_exists=$(jq -r '.[] | select(.id == "worker-alpha") | .id' "$SWARM_REGISTRY")
    assert_eq "$w_exists" "worker-alpha"
    w_tier=$(jq -r '.[] | select(.id == "worker-alpha") | .tier' "$SWARM_REGISTRY")
    assert_eq "$w_tier" "2"
    w_gpu=$(jq -r '.[] | select(.id == "worker-alpha") | .gpu' "$SWARM_REGISTRY")
    assert_eq "$w_gpu" "RTX 4090"

    # Verify ack published via mock log
    assert_file_exists "$SWARM_MOCK_LOG"
    grep -q "george/node/worker-alpha/inbox" "$SWARM_MOCK_LOG"
    assert_ok $? "Ack should be published to worker inbox"
}

it "handles node/leave on master" && {
    swarm_host "127.0.0.1:1883" >/dev/null 2>&1

    join_json=$(swarm_rpc_req "join-123" "node/join" '{"node_id":"worker-beta", "host":"box-1", "tier":"2", "gpu":"none"}')
    _swarm_master_handle_message "$join_json"

    leave_json=$(swarm_rpc_req "leave-456" "node/leave" '{"node_id":"worker-beta"}')
    _swarm_master_handle_message "$leave_json"

    w_status=$(jq -r '.[] | select(.id == "worker-beta") | .status' "$SWARM_REGISTRY")
    assert_eq "$w_status" "OFFLINE"
}

_swarm_test_teardown

# ── 4. Policy Gating: Autonomous vs. Operator Approval ────────────────
describe "Swarm Execution Policy Gating"

_swarm_test_setup

it "queues requests when SWARM_REQUIRE_APPROVAL=1" && {
    swarm_host "127.0.0.1:1883" >/dev/null 2>&1
    swarm_policy "manual" >/dev/null 2>&1
    assert_eq "$SWARM_REQUIRE_APPROVAL" "1"

    exec_req=$(swarm_rpc_req "req-999" "repl/exec" '{"from":"worker-alpha", "command":"/endpoints"}')
    _swarm_master_handle_message "$exec_req"

    # Verify placed in queue
    q_entry=$(jq -r '.[] | select(.id == "req-999") | .status' "$SWARM_QUEUE_FILE")
    assert_eq "$q_entry" "PENDING_APPROVAL"
}

it "approves and updates queued request" && {
    swarm_host "127.0.0.1:1883" >/dev/null 2>&1
    swarm_policy "manual" >/dev/null 2>&1

    exec_req=$(swarm_rpc_req "req-888" "repl/exec" '{"from":"worker-alpha", "command":"echo test"}')
    _swarm_master_handle_message "$exec_req"

    swarm_approve "req-888" >/dev/null 2>&1
    q_entry=$(jq -r '.[] | select(.id == "req-888") | .status' "$SWARM_QUEUE_FILE")
    assert_eq "$q_entry" "APPROVED"
}

it "rejects queued request with error frame" && {
    swarm_host "127.0.0.1:1883" >/dev/null 2>&1
    swarm_policy "manual" >/dev/null 2>&1

    exec_req=$(swarm_rpc_req "req-777" "repl/exec" '{"from":"worker-alpha", "command":"rm -rf /"}')
    _swarm_master_handle_message "$exec_req"

    swarm_reject "req-777" >/dev/null 2>&1
    q_entry=$(jq -r '.[] | select(.id == "req-777") | .status' "$SWARM_QUEUE_FILE")
    assert_eq "$q_entry" "REJECTED"

    # Check error published to mock
    grep -q "Request rejected by Master operator" "$SWARM_MOCK_LOG"
    assert_ok $? "Rejection should be published"
}

it "toggles back to autonomous mode" && {
    swarm_policy "auto" >/dev/null 2>&1
    assert_eq "$SWARM_REQUIRE_APPROVAL" "0"
}

_swarm_test_teardown

# ── 5. Graceful Disconnect & Leave ───────────────────────────────────
describe "Swarm Disconnect & Cleanup"

_swarm_test_setup

it "cleans up on swarm_leave" && {
    swarm_host "127.0.0.1:1883" >/dev/null 2>&1
    swarm_leave >/dev/null 2>&1
    assert_eq "$SWARM_ROLE" "none"
}

_swarm_test_teardown

test_end
