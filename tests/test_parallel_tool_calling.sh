#!/bin/bash
# ── Tests: Parallel Tool Calling Protocol & Adaptive Two-Phase Barrier ──

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh"
source "$LODGE_DIR/lib/core/react.sh"

TEST_TMP=$(mktemp -d /tmp/george-parallel-tool-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"

cleanup() {
    rm -rf "$TEST_TMP" 2>/dev/null || true
}
trap cleanup EXIT

test_start "Parallel Tool Calling Protocol & Adaptive Two-Phase Barrier"

# ── Suite 1: FIFO Promise Tool Call Manifest Registration ───────────
describe "Tool Call Manifest Registration in FIFO IPC"

it "stamps tool_call_id, tool_name, and tool_args into promise manifest" && {
    ipc_init
    prom_id=$(fifo_async "chan_test_manifest" "echo hello" "call_abc123" "crypto_orders" '{"status":"open","compact":true}')
    assert_ok $?

    prom_file="$FIFO_IPC_DIR/promises/${prom_id}.json"
    assert_file_exists "$prom_file"

    tc_id=$(jq -r '.tool_call_id // empty' "$prom_file")
    tc_name=$(jq -r '.tool_name // empty' "$prom_file")
    tc_args=$(jq -r '.tool_args // empty' "$prom_file")

    assert_eq "$tc_id" "call_abc123"
    assert_eq "$tc_name" "crypto_orders"
    assert_eq "$tc_args" '{"status":"open","compact":true}'

    out=$(fifo_await "$prom_id" 5 2>/dev/null)
    assert_ok $?
    assert_eq "$out" "hello"
}

# ── Suite 2: Multi-Promise Parallel Fan-Out & Barrier Wall-Clock Speedup ──
describe "Parallel Fan-Out & Wall-Clock Speedup"

it "executes 3 concurrent promises in parallel faster than serial sum" && {
    ipc_init
    t0=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))

    # Launch 3 tasks that each sleep 0.25s
    p1=$(fifo_async "c1" "sleep 0.25; echo out1" "c1" "read_1" "{}")
    p2=$(fifo_async "c2" "sleep 0.25; echo out2" "c2" "read_2" "{}")
    p3=$(fifo_async "c3" "sleep 0.25; echo out3" "c3" "read_3" "{}")

    # Await all settled
    fifo_await_all_settled "$p1" "$p2" "$p3" 5
    assert_ok $?

    t1=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
    elapsed_ms=$(( t1 - t0 ))

    # Serial execution of 3 x 250ms = 750ms+. In parallel, should be < 550ms.
    [ "$elapsed_ms" -lt 600 ]
    assert_ok $?

    # Verify outputs
    o1=$(fifo_await "$p1" 0 2>&1)
    o2=$(fifo_await "$p2" 0 2>&1)
    o3=$(fifo_await "$p3" 0 2>&1)

    assert_eq "$o1" "out1"
    assert_eq "$o2" "out2"
    assert_eq "$o3" "out3"
}

# ── Suite 3: Settled-All Fault Tolerance (Never Fail-Fast) ────────────
describe "Settled-All Fault Tolerance"

it "preserves completed sibling outputs when one promise fails or crashes" && {
    ipc_init
    # p1 succeeds (0.1s), p2 fails immediately with exit 42, p3 succeeds (0.2s)
    p1=$(fifo_async "c1" "sleep 0.1; echo success_p1" "c1" "read_1" "{}")
    p2=$(fifo_async "c2" "echo 'simulated error' >&2; exit 42" "c2" "read_fail" "{}")
    p3=$(fifo_async "c3" "sleep 0.2; echo success_p3" "c3" "read_3" "{}")

    # Settled-All barrier: waits for all 3 promises to settle
    fifo_await_all_settled "$p1" "$p2" "$p3" 5
    ret=$?

    # Since p2 failed with 42, return code reflects failure
    [ "$ret" -ne 0 ]
    assert_ok $?

    # Verify p1 resolved cleanly with full output
    _ipc_prom_read "$FIFO_IPC_DIR/promises/${p1}.json"
    assert_eq "$_p_st" "RESOLVED"
    assert_eq "${_p_ec:-0}" "0"
    o1=$(fifo_await "$p1" 0 2>&1)
    assert_eq "$o1" "success_p1"

    # Verify p2 rejected with exit code 42
    _ipc_prom_read "$FIFO_IPC_DIR/promises/${p2}.json"
    assert_eq "$_p_st" "REJECTED"
    assert_eq "${_p_ec:-1}" "42"

    # Verify p3 resolved cleanly despite sibling failure
    _ipc_prom_read "$FIFO_IPC_DIR/promises/${p3}.json"
    assert_eq "$_p_st" "RESOLVED"
    assert_eq "${_p_ec:-0}" "0"
    o3=$(fifo_await "$p3" 0 2>&1)
    assert_eq "$o3" "success_p3"
}

it "reaps timed-out promises with exit 124 without abandoning sibling promises" && {
    ipc_init
    p_fast=$(fifo_async "c_fast" "sleep 0.05; echo fast_done" "c_fast" "read_fast" "{}")
    p_slow=$(fifo_async "c_slow" "sleep 10; echo slow_done" "c_slow" "read_slow" "{}")

    # Timeout after 1 second
    fifo_await_all_settled "$p_fast" "$p_slow" 1
    ret=$?

    [ "$ret" -ne 0 ]
    assert_ok $?

    # Fast promise resolved
    _ipc_prom_read "$FIFO_IPC_DIR/promises/${p_fast}.json"
    assert_eq "$_p_st" "RESOLVED"
    o_fast=$(fifo_await "$p_fast" 0 2>&1)
    assert_eq "$o_fast" "fast_done"

    # Slow promise reaped with timeout exit code 124
    _ipc_prom_read "$FIFO_IPC_DIR/promises/${p_slow}.json"
    assert_eq "$_p_st" "REJECTED"
    assert_eq "${_p_ec:-0}" "124"
}

# ── Suite 4: Tool Mutation Classifier ────────────────────────────────
describe "Two-Phase Tool Mutation Classifier (_react_tool_is_mutating)"

it "correctly classifies read-only vs mutating domain tools" && {
    # Read-only tools (return 1 -> false)
    _react_tool_is_mutating "file_read" '{"path":"foo.txt"}'
    assert_fail $?
    _react_tool_is_mutating "file_grep" '{"query":"pattern"}'
    assert_fail $?
    _react_tool_is_mutating "dir_list" '{"path":"."}'
    assert_fail $?
    _react_tool_is_mutating "crypto_orders" '{"status":"open"}'
    assert_fail $?
    _react_tool_is_mutating "crypto_desk_summary" '{}'
    assert_fail $?
    _react_tool_is_mutating "web_search" '{"query":"test"}'
    assert_fail $?

    # Mutating tools (return 0 -> true)
    _react_tool_is_mutating "file_write" '{"path":"foo.txt","content":"hi"}'
    assert_ok $?
    _react_tool_is_mutating "file_edit" '{"path":"foo.txt"}'
    assert_ok $?
    _react_tool_is_mutating "crypto_place_limit" '{"asset":"SNEK"}'
    assert_ok $?
    _react_tool_is_mutating "crypto_reclaim_order" '{"order_id":"123"}'
    assert_ok $?
    _react_tool_is_mutating "crypto_send_ada" '{"target":"addr1"}'
    assert_ok $?
    _react_tool_is_mutating "git_commit" '{"message":"test"}'
    assert_ok $?
    _react_tool_is_mutating "bash_exec" '{"command":"git commit -m test"}'
    assert_ok $?
    _react_tool_is_mutating "bash_exec" '{"command":"ls -la"}'
    assert_fail $?
}

# ── Suite 5: Dynamic Turn-Budget Partitioning & Disk Archiving ────────
describe "Dynamic Turn-Budget Partitioning & Disk Archiving"

it "partitions context budget across multiple calls and archives full output to disk" && {
    session_dir="$TEST_TMP/session_budget_test"
    mkdir -p "$session_dir"
    session_id="test_sess_budget"
    workdir="$TEST_TMP"
    goal="test budget"
    turn=1
    max_turns=10
    current_hd_id=1
    current_hd_step=""
    thrashing_target_streak=0
    _rl_tool_calls=0
    _rl_tool_fails=0
    messages_file="$session_dir/messages.json"
    history_file="$session_dir/history.txt"
    macro_file="$session_dir/macro.json"
    echo "[]" > "$messages_file"
    echo '{"completed_milestones":[]}' > "$macro_file"

    # Generate 15,000 character output
    large_payload=$(python3 -c 'print("A" * 15000)')

    # Call with num_turn_calls=3, turn_max_chars=8000
    _react_postprocess_observation "call_test_budget" "file_read" '{"path":"big.txt"}' "$large_payload" 0 15 0 8000 3

    # 1. Full un-truncated output must be on disk
    obs_file="$session_dir/observations/call_test_budget.txt"
    assert_file_exists "$obs_file"
    obs_chars=$(wc -c < "$obs_file" | tr -d '[:space:]')
    assert_eq "$obs_chars" "15001"

    # 2. In-context message must be truncated with exact reference link
    last_msg_content=$(jq -r '.[-1].content' "$messages_file")
    [[ "$last_msg_content" =~ "Observation truncated at 8000 characters for turn-budget partitioning" ]]
    assert_ok $?
    [[ "$last_msg_content" =~ "$obs_file" ]]
    assert_ok $?
}

# ── Suite 6: Two-Phase Execution Ordering Simulation ─────────────────
describe "Two-Phase Barrier Execution Ordering"

it "completes all Phase 1 concurrent read tools before Phase 2 mutation tools run" && {
    _test_two_phase_simulation() {
        ipc_init
        session_dir="$TEST_TMP/session_two_phase_test"
        mkdir -p "$session_dir"
        messages_file="$session_dir/messages.json"
        history_file="$session_dir/history.txt"
        macro_file="$session_dir/macro.json"
        echo "[]" > "$messages_file"
        echo '{"completed_milestones":[]}' > "$macro_file"

        order_log="$session_dir/order_trace.log"

        # Mock tool dispatch that writes to order_log with timestamp and name
        native_tools_dispatch() {
            local id="$1" name="$2" args="$3" wd="$4"
            local ts=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
            echo "${ts} START ${name} (${id})" >> "$order_log"
            if [ "$name" = "read_slow" ]; then
                sleep 0.2
            elif [ "$name" = "read_fast" ]; then
                sleep 0.05
            elif [ "$name" = "write_tool" ]; then
                sleep 0.05
            fi
            echo "${ts} END ${name} (${id})" >> "$order_log"
            echo "OK from ${name}"
        }

        # Simulate 2 reads and 1 write
        local tool_calls=$(jq -nc '[
            {id: "call_r1", type: "function", function: {name: "read_slow", arguments: "{}"}},
            {id: "call_r2", type: "function", function: {name: "read_fast", arguments: "{}"}},
            {id: "call_w1", type: "function", function: {name: "write_tool", arguments: "{}"}}
        ]')

        session_id="test_sess_$$"
        workdir="$TEST_TMP"
        turn=1
        max_turns=10
        hd_file="$session_dir/hd.json"
        last_invoked_tool=""
        same_tool_streak=0
        tool_search_streak=0
        thrashing_target_streak=0
        last_inspected_path=""
        same_target_path_streak=0
        _rl_tool_calls=0
        _rl_tool_fails=0

        # Execute Adaptive Two-Phase Barrier logic
        local num_turn_calls
        num_turn_calls=$(jq 'length' <<<"$tool_calls" 2>/dev/null || echo 1)
        local turn_total_budget="${REACT_TURN_TOTAL_BUDGET:-24000}"
        local turn_max_chars=$(( turn_total_budget / num_turn_calls ))
        local as_timeout=10

        local -a p1_calls=() p2_calls=()
        while IFS= read -r _t_call; do
            [ -z "$_t_call" ] && continue
            local _cn _ca
            _cn=$(jq -r '.function.name // empty' <<<"$_t_call" 2>/dev/null)
            _ca=$(jq -r '.function.arguments // empty' <<<"$_t_call" 2>/dev/null)
            # Mock mutation rule for test
            if [ "$_cn" = "write_tool" ]; then
                p2_calls+=("$_t_call")
            else
                p1_calls+=("$_t_call")
            fi
        done < <(echo "$tool_calls" | jq -c '.[]' 2>/dev/null)

        assert_eq "${#p1_calls[@]}" "2"
        assert_eq "${#p2_calls[@]}" "1"

        # Phase 1 Parallel Fan-out
        local -a p1_prom_ids=() p1_t0_ms=()
        local _p1_idx=0
        for _call in "${p1_calls[@]}"; do
            local c_id c_name c_args
            c_id=$(jq -r '.id' <<<"$_call")
            c_name=$(jq -r '.function.name' <<<"$_call")
            c_args=$(jq -r '.function.arguments' <<<"$_call")
            local _t_start_ms=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
            p1_t0_ms[$_p1_idx]="$_t_start_ms"
            local call_cid="${session_id}_tc_${c_id//[^A-Za-z0-9_.-]/_}"
            local prom_id=$(fifo_async "$call_cid" "native_tools_dispatch '$c_id' '$c_name' '$c_args' '$workdir'" "$c_id" "$c_name" "$c_args")
            p1_prom_ids[$_p1_idx]="$prom_id"
            _p1_idx=$((_p1_idx + 1))
        done

        # Barrier join
        fifo_await_all_settled "$as_timeout" "${p1_prom_ids[@]}"
        assert_ok $?

        # Ingest Phase 1
        _p1_idx=0
        for _call in "${p1_calls[@]}"; do
            local c_id c_name c_args
            c_id=$(jq -r '.id' <<<"$_call")
            c_name=$(jq -r '.function.name' <<<"$_call")
            c_args=$(jq -r '.function.arguments' <<<"$_call")
            local prom_id="${p1_prom_ids[$_p1_idx]}"
            local tool_resp=$(fifo_await "$prom_id" 0 2>&1)
            _react_postprocess_observation "$c_id" "$c_name" "$c_args" "$tool_resp" 0 100 0 "$turn_max_chars" "$num_turn_calls"
            _p1_idx=$((_p1_idx + 1))
        done

        # Phase 2 Serial Queue
        for _call in "${p2_calls[@]}"; do
            local c_id c_name c_args
            c_id=$(jq -r '.id' <<<"$_call")
            c_name=$(jq -r '.function.name' <<<"$_call")
            c_args=$(jq -r '.function.arguments' <<<"$_call")
            local tool_resp=$(native_tools_dispatch "$c_id" "$c_name" "$c_args" "$workdir")
            _react_postprocess_observation "$c_id" "$c_name" "$c_args" "$tool_resp" 0 50 0 "$turn_max_chars" "$num_turn_calls"
        done

        # Verify messages_file has all 3 responses in role: "tool"
        local msg_count=$(jq '[.[] | select(.role == "tool")] | length' "$messages_file")
        assert_eq "$msg_count" "3"

        # Verify Phase 2 write started strictly AFTER Phase 1 reads ended
        local r_slow_end=$(grep "END read_slow" "$order_log" | awk '{print $1}')
        local w_start=$(grep "START write_tool" "$order_log" | awk '{print $1}')

        [ "$w_start" -ge "$r_slow_end" ]
        assert_ok $?
    }
    _test_two_phase_simulation
}

test_end
