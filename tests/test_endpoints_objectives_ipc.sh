#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tests/test_endpoints_objectives_ipc.sh — IPC FIFO Tier Slots & Objective Routing
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR

test_start "endpoints_objectives_ipc"

# Create isolated GEORGE_DIR inside test sandbox
export GEORGE_DIR="$GEORGE_TEST_SANDBOX/.george"
export ENDPOINTS_CONF="$GEORGE_DIR/endpoints.conf"
export IPC_ROOT_DIR="$GEORGE_DIR/ipc"
# Keep the FIFO IPC base aligned with the sandboxed GEORGE_DIR (the hermetic
# runner pre-exports FIFO_IPC_DIR from its own GEORGE_DIR before this override)
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"
mkdir -p "$GEORGE_DIR" "$IPC_ROOT_DIR" "$GEORGE_TEST_SANDBOX/mocks"

cat > "$GEORGE_TEST_SANDBOX/mocks/script.json" <<'EOF'
{"aux": "ok"}
EOF

python3 "$LODGE_DIR/tests/helpers/mock_llm.py" "$GEORGE_TEST_SANDBOX/mocks/port1" "$GEORGE_TEST_SANDBOX/mocks/script.json" &
MOCK_T1_PID=$!
python3 "$LODGE_DIR/tests/helpers/mock_llm.py" "$GEORGE_TEST_SANDBOX/mocks/port2" "$GEORGE_TEST_SANDBOX/mocks/script.json" &
MOCK_T2_PID=$!
trap 'kill "$MOCK_T1_PID" "$MOCK_T2_PID" 2>/dev/null || true' EXIT

for _i in $(seq 50); do
    [ -s "$GEORGE_TEST_SANDBOX/mocks/port1" ] && [ -s "$GEORGE_TEST_SANDBOX/mocks/port2" ] && break
    sleep 0.1
done

MOCK_T1_PORT=$(cat "$GEORGE_TEST_SANDBOX/mocks/port1")
MOCK_T2_PORT=$(cat "$GEORGE_TEST_SANDBOX/mocks/port2")

T1_URL="http://127.0.0.1:${MOCK_T1_PORT}"
T2_URL="http://127.0.0.1:${MOCK_T2_PORT}"

cat > "$ENDPOINTS_CONF" <<EOF
TIER3_NAME="frontier-cloud"
TIER3_URL="http://127.0.0.1:59999"
TIER3_MODEL="frontier-v1"
TIER3_CONTEXT=65536
TIER3_ENABLED=0

TIER1_NAME="primary-workhorse"
TIER1_URL="${T1_URL}"
TIER1_MODEL="qwen38-27b"
TIER1_CONTEXT=65536
TIER1_ENABLED=1

TIER2_NAME="custom-secondary-node"
TIER2_URL="${T2_URL}"
TIER2_MODEL="gemma-4-e4b"
TIER2_CONTEXT=32768
TIER2_ENABLED=1

TIER0_NAME="edge-mobile"
TIER0_URL="http://127.0.0.1:59998"
TIER0_MODEL="gemma-2b"
TIER0_CONTEXT=8192
TIER0_ENABLED=0

OBJECTIVE_INTERACTIVE="3,1,2,0"
OBJECTIVE_REMEDIATION="1,3"
OBJECTIVE_PR_REVIEW="1,3"
OBJECTIVE_EVALUATOR="2:idle,1"
OBJECTIVE_ADVISOR="1,3"
OBJECTIVE_SDR_SUMMARY="2"
OBJECTIVE_SUBAGENTS="2:idle,1"
OBJECTIVE_CLONE_WORKER="1,3"
OBJECTIVE_PHYTOLOGY="2:idle,1"
EOF

unset _LIB_FIFO_IPC_LOADED _LIB_ENDPOINTS_LOADED _CMD_ENDPOINTS_LOADED
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh"
source "$LODGE_DIR/lib/core/endpoints.sh"
source "$LODGE_DIR/commands/endpoints.sh"

# ───────────────────────────────────────────────────────────────────────
describe "IPC FIFO per-tier slot primitives"

ipc_tier_slot_init 1 1
ipc_tier_slot_init 2 1

ipc_tier_is_idle 1
assert_ok "$?" "tier 1 slot is initially idle"

ipc_tier_is_idle 2
assert_ok "$?" "tier 2 slot is initially idle"

ipc_tier_acquire 2 "sdr_stage2_test" 2
assert_ok "$?" "acquiring tier 2 slot succeeds"
assert_file_exists "$IPC_ROOT_DIR/inference_slots/tier_2/lease.json"

ipc_tier_is_idle 2
assert_fail "$?" "tier 2 slot reports busy while lease is held"

ipc_tier_release 2 "sdr_stage2_test"
assert_ok "$?" "releasing tier 2 slot succeeds"

ipc_tier_is_idle 2
assert_ok "$?" "tier 2 slot returns to idle after release"

# Pausing the FIFO channel also marks the tier non-idle
ipc_flow_pause "tier_2_slot"
ipc_tier_is_idle 2
assert_fail "$?" "paused tier_2_slot channel reports non-idle"

ipc_flow_resume "tier_2_slot"
ipc_tier_is_idle 2
assert_ok "$?" "resumed tier_2_slot channel reports idle"

# ───────────────────────────────────────────────────────────────────────
describe "Objective-to-Endpoint resolution (by tier number & custom node name)"

res_rem=$(endpoints_resolve_for_objective "remediation")
assert_eq "$res_rem" "1|primary-workhorse|${T1_URL}|qwen38-27b" "remediation resolves to Tier 1"

res_eval_idle=$(endpoints_resolve_for_objective "evaluator")
assert_eq "$res_eval_idle" "2|custom-secondary-node|${T2_URL}|gemma-4-e4b" "evaluator resolves to Tier 2 when idle"

# Now mark Tier 2 busy via IPC FIFO lease — evaluator (2:idle,1) must cascade to Tier 1!
ipc_tier_acquire 2 "sdr_summarizer" 2
res_eval_busy=$(endpoints_resolve_for_objective "evaluator")
assert_eq "$res_eval_busy" "1|primary-workhorse|${T1_URL}|qwen38-27b" "evaluator cascades to Tier 1 when Tier 2 FIFO slot is busy"
ipc_tier_release 2 "sdr_summarizer"

# Test resolution by custom node name in spec
endpoints_assign_objective "phytology" "custom-secondary-node:idle,primary-workhorse"
assert_ok "$?" "assign objective by custom node name"

res_phy=$(endpoints_resolve_for_objective "phytology")
assert_eq "$res_phy" "2|custom-secondary-node|${T2_URL}|gemma-4-e4b" "phytology resolves to custom-secondary-node when idle"

# Pause companion remote node channel node_custom-secondary-node -> should cascade to primary-workhorse
fifo_channel_open "node_custom-secondary-node" 1
ipc_flow_pause "node_custom-secondary-node"
res_phy_paused=$(endpoints_resolve_for_objective "phytology")
assert_eq "$res_phy_paused" "1|primary-workhorse|${T1_URL}|qwen38-27b" "phytology cascades when companion node_<name> channel is paused"
ipc_flow_resume "node_custom-secondary-node"

# ───────────────────────────────────────────────────────────────────────
describe "/endpoints CLI command & JSON output"

status_json=$(cmd_endpoints "json")
t2_name_in_json=$(echo "$status_json" | jq -r '.[] | select(.tier == 2) | .name')
assert_eq "$t2_name_in_json" "custom-secondary-node" "JSON status contains custom Tier 2 node name"

objs_json=$(endpoints_objectives_json)
rem_spec=$(echo "$objs_json" | jq -r '.remediation.spec')
assert_eq "$rem_spec" "1,3" "objectives JSON reflects remediation spec"
phy_spec=$(echo "$objs_json" | jq -r '.phytology.spec')
assert_eq "$phy_spec" "custom-secondary-node:idle,primary-workhorse" "objectives JSON reflects updated phytology spec"

test_end

