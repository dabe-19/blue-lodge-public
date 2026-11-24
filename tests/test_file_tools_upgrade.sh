#!/bin/bash
# ── Tests: File Tools Upgrade (Structured file_edit, 4-Tier Fuzzy Match, Raw I/O, State Machine) ──

set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/tools.sh"
source "$LODGE_DIR/lib/tools/native_tools.sh"
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh"
source "$LODGE_DIR/lib/core/react.sh"

TEST_TMP=$(mktemp -d /tmp/george-file-tools-upgrade-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"

cleanup() {
    rm -rf "$TEST_TMP" 2>/dev/null || true
}
trap cleanup EXIT

test_start "File Tools Upgrade — Structured Edits, 4-Tier Fuzzy Matching, Lock-Safe Raw I/O & ReAct Alignment"

# ── Suite 1: Structured file_edit (target + replacement & edits array) ──
describe "1. Structured file_edit (target + replacement & multi-hunk edits[])"

it "applies single structured target + replacement edit cleanly" && {
    f="$TEST_TMP/single_edit.py"
    cat > "$f" <<'EOF'
def calculate_tax(amount):
    rate = 0.05
    return amount * rate
EOF
    args=$(jq -nc --arg p "$f" '{
        path: $p,
        target: "    rate = 0.05",
        replacement: "    rate = 0.0825"
    }')
    res=$(native_tools_dispatch "call_fe_struct1" "file_edit" "$args" "$TEST_TMP")
    assert_ok $?
    assert_contains "$(echo "$res" | jq -r '.content')" "[exact]"
    content=$(cat "$f")
    assert_contains "$content" "    rate = 0.0825"
    assert_not_contains "$content" "0.05"
}

it "applies multi-hunk edits[] array atomically in a single call" && {
    f="$TEST_TMP/multi_hunk.py"
    cat > "$f" <<'EOF'
HOST = "127.0.0.1"
PORT = 8080
DEBUG = False

def start_server():
    print(f"Starting on {HOST}:{PORT}")
EOF
    args=$(jq -nc --arg p "$f" '{
        path: $p,
        edits: [
            {target: "PORT = 8080", replacement: "PORT = 9090"},
            {target: "DEBUG = False", replacement: "DEBUG = True"},
            {target: "    print(f\"Starting on {HOST}:{PORT}\")", replacement: "    print(f\"Listening on {HOST}:{PORT} (debug={DEBUG})\")"}
        ]
    }')
    res=$(native_tools_dispatch "call_fe_multi1" "file_edit" "$args" "$TEST_TMP")
    assert_ok $?
    out_msg=$(echo "$res" | jq -r '.content')
    assert_contains "$out_msg" "Applied 3 block edits"
    assert_contains "$out_msg" "[exact, exact, exact]"
    content=$(cat "$f")
    assert_contains "$content" "PORT = 9090"
    assert_contains "$content" "DEBUG = True"
    assert_contains "$content" "Listening on {HOST}:{PORT} (debug={DEBUG})"
}

it "leaves file completely untouched if any hunk in edits[] fails" && {
    f="$TEST_TMP/atomic_rollback.py"
    cat > "$f" <<'EOF'
A = 1
B = 2
EOF
    before_sha=$(sha256sum < "$f")
    args=$(jq -nc --arg p "$f" '{
        path: $p,
        edits: [
            {target: "A = 1", replacement: "A = 10"},
            {target: "NON_EXISTENT_LINE = 999", replacement: "B = 20"}
        ]
    }')
    res=$(native_tools_dispatch "call_fe_rollback" "file_edit" "$args" "$TEST_TMP")
    ec=$(echo "$res" | jq -r '.exit_code')
    assert_eq "$ec" "1"
    after_sha=$(sha256sum < "$f")
    assert_eq "$after_sha" "$before_sha"
}

it "supports replace_all=true and reports duplicate line numbers when replace_all=false" && {
    f="$TEST_TMP/dup_lines.txt"
    cat > "$f" <<'EOF'
alpha = 1
beta = 2
alpha = 1
EOF
    # Without replace_all: fails and reports exact line numbers (lines 1, 3)
    args_fail=$(jq -nc --arg p "$f" '{path: $p, target: "alpha = 1", replacement: "alpha = 9"}')
    res_fail=$(native_tools_dispatch "call_dup1" "file_edit" "$args_fail" "$TEST_TMP")
    msg_fail=$(echo "$res_fail" | jq -r '.content')
    assert_contains "$msg_fail" "multiple matches"
    assert_contains "$msg_fail" "1, 3"

    # With replace_all=true: succeeds and replaces both occurrences
    args_ok=$(jq -nc --arg p "$f" '{path: $p, target: "alpha = 1", replacement: "alpha = 9", replace_all: true}')
    res_ok=$(native_tools_dispatch "call_dup2" "file_edit" "$args_ok" "$TEST_TMP")
    assert_eq "$(echo "$res_ok" | jq -r '.exit_code')" "0"
    assert_eq "$(grep -c 'alpha = 9' "$f")" "2"
}

# ── Suite 2: 4-Tier Fuzzy Matcher & Closest-Match Diagnostics ──
describe "2. 4-Tier Fuzzy Matching & Closest-Match Diagnostics"

it "matches across Unicode curly quotes and em-dashes (Tier 4 Typography Normalization)" && {
    f="$TEST_TMP/typography.md"
    printf 'The paper states \xe2\x80\x9cquorum intersection is guaranteed\xe2\x80\x9d \xe2\x80\x94 see Theorem 2.\n' > "$f"

    # Search using standard ASCII quotes and double-hyphen
    args=$(jq -nc --arg p "$f" '{
        path: $p,
        target: "The paper states \"quorum intersection is guaranteed\" -- see Theorem 2.",
        replacement: "The paper proves \"quorum intersection is guaranteed\" (Theorem 2.1)."
    }')
    res=$(native_tools_dispatch "call_typo1" "file_edit" "$args" "$TEST_TMP")
    assert_eq "$(echo "$res" | jq -r '.exit_code')" "0"
    assert_contains "$(echo "$res" | jq -r '.content')" "[typography_norm]"
    assert_contains "$(cat "$f")" "Theorem 2.1"
}

it "matches across relative indentation shift and auto-adjusts replacement indentation (Tier 3)" && {
    f="$TEST_TMP/indent_shift.py"
    cat > "$f" <<'EOF'
class Worker:
    def run(self):
        if self.ready:
            value = self.compute_step()
            return value + 1
EOF
    # Model provides target with 4 spaces instead of 12 spaces
    args=$(jq -nc --arg p "$f" '{
        path: $p,
        target: "    value = self.compute_step()\n    return value + 1",
        replacement: "    value = self.compute_step()\n    return value + 2"
    }')
    res=$(native_tools_dispatch "call_indent1" "file_edit" "$args" "$TEST_TMP")
    assert_eq "$(echo "$res" | jq -r '.exit_code')" "0"
    assert_contains "$(echo "$res" | jq -r '.content')" "[indent_norm]"
    # Verify 12-space indentation was preserved in the replacement
    assert_contains "$(cat "$f")" "            return value + 2"
}

it "returns closest-match line preview with line numbers when search pattern is not found" && {
    f="$TEST_TMP/closest_match.py"
    cat > "$f" <<'EOF'
def alpha():
    return 1

def compute_quorum_threshold(n_nodes, fault_count):
    threshold = (n_nodes - fault_count) // 2 + 1
    return threshold

def omega():
    return 99
EOF
    args=$(jq -nc --arg p "$f" '{
        path: $p,
        target: "def compute_quorum_threshold(n_nodes, faults):\n    threshold = (n_nodes - faults) // 2 + 1\n    return threshold",
        replacement: "def compute_quorum_threshold(n_nodes, fault_count):\n    return (2 * n_nodes) // 3 + 1"
    }')
    res=$(native_tools_dispatch "call_closest1" "file_edit" "$args" "$TEST_TMP")
    msg=$(echo "$res" | jq -r '.content')
    assert_contains "$msg" "Closest match in file"
    assert_contains "$msg" "compute_quorum_threshold(n_nodes, fault_count)"
}

# ── Suite 3: Escape Sequence, Filename & XML Tag Preservation in Raw File I/O ──
describe "3. Raw File I/O Preservation (No Slash-Command Mangling)"

it "preserves literal \\n and \\t escape sequences in file_write and file_append" && {
    f="$TEST_TMP/escapes.py"
    code=$'def fmt(items):\n    return "\\n\\t".join(items)\n'
    args=$(jq -nc --arg p "$f" --arg c "$code" '{path: $p, content: $c}')
    res=$(native_tools_dispatch "call_fw_esc" "file_write" "$args" "$TEST_TMP")
    assert_eq "$(echo "$res" | jq -r '.exit_code')" "0"
    assert_contains "$(cat "$f")" '"\n\t".join(items)'

    app_code=$'def split_lines(s):\n    return s.split("\\n")\n'
    args_app=$(jq -nc --arg p "$f" --arg c "$app_code" '{path: $p, content: $c}')
    res_app=$(native_tools_dispatch "call_fa_esc" "file_append" "$args_app" "$TEST_TMP")
    assert_eq "$(echo "$res_app" | jq -r '.exit_code')" "0"
    assert_contains "$(cat "$f")" 's.split("\n")'
}

it "does NOT expand workspace filenames mentioned inside file_write or file_append content" && {
    echo "SECRET_CANARY_FILE_CONTENT_XYZ" > "$TEST_TMP/canary_ref.md"
    f="$TEST_TMP/notes.md"
    args=$(jq -nc --arg p "$f" '{path: $p, content: "Please see canary_ref.md for details.\nSecond line."}')
    native_tools_dispatch "call_fw_ref" "file_write" "$args" "$TEST_TMP" >/dev/null
    written=$(cat "$f")
    assert_contains "$written" "canary_ref.md"
    assert_not_contains "$written" "SECRET_CANARY_FILE_CONTENT_XYZ"
}

it "preserves code containing </parameter> or </function> regex strings in native_tools_sanitize_args" && {
    f="$TEST_TMP/parser_test.py"
    code=$'import re\nTAG_RE = re.compile(r"</?(?:parameter|function|tool_call)[^>]*>")\nprint("done")\n'
    args=$(jq -nc --arg p "$f" --arg c "$code" '{path: $p, content: $c}')
    res=$(native_tools_dispatch "call_fw_xml" "file_write" "$args" "$TEST_TMP")
    assert_eq "$(echo "$res" | jq -r '.exit_code')" "0"
    written=$(cat "$f")
    assert_contains "$written" 'print("done")'
    assert_contains "$written" 'TAG_RE = re.compile'
}

# ── Suite 4: file_read end_line Support ──
describe "4. file_read end_line parameter"

it "reads exact inclusive line range when start_line and end_line are provided" && {
    f="$TEST_TMP/numbered.txt"
    seq 1 50 > "$f"
    args=$(jq -nc --arg p "$f" '{path: $p, start_line: 10, end_line: 15}')
    res=$(native_tools_dispatch "call_fr_end" "file_read" "$args" "$TEST_TMP")
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "lines 10-15 of 50"
    assert_contains "$content" "10: 10"
    assert_contains "$content" "15: 15"
    assert_not_contains "$content" "16: 16"
}

# ── Suite 5: State Machine & Mutating Classifier Alignment ──
describe "5. State Machine & Mutating Classifier Alignment"

it "classifies file_append and code_symbol_patch as mutating tools and includes file_append in bedrock" && {
    _react_tool_is_mutating "file_append" '{"path":"foo.md","content":"bar"}'
    assert_ok $?
    _react_tool_is_mutating "code_symbol_patch" '{}'
    assert_ok $?
    _react_tool_is_mutating "memory_append_section" '{}'
    assert_ok $?

    assert_contains "$_BEDROCK_TOOLS" "file_append"
    def_prof=$(native_tools_resolve_profile "default")
    echo "$def_prof" | jq -e '.[] | select(.function.name == "file_append")' >/dev/null
    assert_ok $?
}

it "suppresses intra-turn streak escalation across multiple Phase 2 edits and resets path streak on edit success" && {
    session_id="test_sess_p2_$$"
    workdir="$TEST_TMP"
    session_dir="$TEST_TMP/session_p2"
    mkdir -p "$session_dir"
    messages_file="$session_dir/messages.json"
    macro_file="$session_dir/macro.json"
    history_file="$session_dir/trajectory.log"
    echo '[]' > "$messages_file"
    echo '{"completed_milestones":[]}' > "$macro_file"
    : > "$history_file"

    f="$TEST_TMP/streak_edit.txt"
    printf "line1\nline2\nline3\n" > "$f"

    turn=1
    max_turns=10
    same_tool_streak=0
    last_invoked_tool=""
    same_target_path_streak=4
    last_inspected_path="$f"
    tool_search_streak=0
    thrashing_target_streak=0

    # Simulate 3 sequential edits in the same turn (call 0, call 1, call 2)
    c0=$(jq -nc --arg p "$f" '{id: "e0", function: {name: "file_edit", arguments: ({path: $p, target: "line1", replacement: "LINE_ONE"} | tostring)}}')
    c1=$(jq -nc --arg p "$f" '{id: "e1", function: {name: "file_edit", arguments: ({path: $p, target: "line2", replacement: "LINE_TWO"} | tostring)}}')
    c2=$(jq -nc --arg p "$f" '{id: "e2", function: {name: "file_edit", arguments: ({path: $p, target: "line3", replacement: "LINE_THREE"} | tostring)}}')

    _REACT_SUPPRESS_INTRA_TURN_STREAK=0 _REACT_SKIP_BATCH_EVAL=1 _react_execute_single_tool_step "$c0" 4000 3
    _REACT_SUPPRESS_INTRA_TURN_STREAK=1 _REACT_SKIP_BATCH_EVAL=1 _react_execute_single_tool_step "$c1" 4000 3
    _REACT_SUPPRESS_INTRA_TURN_STREAK=1 _REACT_SKIP_BATCH_EVAL=0 _react_execute_single_tool_step "$c2" 4000 3

    assert_eq "$same_tool_streak" "1" "3 edits in one turn must only increment same_tool_streak once"
    assert_eq "$same_target_path_streak" "0" "Successful file edit must reset same_target_path_streak to 0"
    assert_contains "$(cat "$f")" "LINE_THREE"
}

it "executes parallel file_edit calls across distinct files via FIFO IPC (fifo_async + fifo_await_all_settled)" && {
    fa="$TEST_TMP/par_a.py"
    fb="$TEST_TMP/par_b.py"
    fc="$TEST_TMP/par_c.py"
    printf 'VAL = "old_a"\n' > "$fa"
    printf 'VAL = "old_b"\n' > "$fb"
    printf 'VAL = "old_c"\n' > "$fc"

    args_a=$(jq -nc --arg p "$fa" '{path: $p, target: "VAL = \"old_a\"", replacement: "VAL = \"new_a\""}')
    args_b=$(jq -nc --arg p "$fb" '{path: $p, target: "VAL = \"old_b\"", replacement: "VAL = \"new_b\""}')
    args_c=$(jq -nc --arg p "$fc" '{path: $p, target: "VAL = \"old_c\"", replacement: "VAL = \"new_c\""}')

    printf -v qa '%q' "$args_a"; printf -v qb '%q' "$args_b"; printf -v qc '%q' "$args_c"
    printf -v qwd '%q' "$TEST_TMP"
    pa=$(fifo_async "chan_par_1" "native_tools_dispatch par_1 file_edit $qa $qwd")
    pb=$(fifo_async "chan_par_2" "native_tools_dispatch par_2 file_edit $qb $qwd")
    pc=$(fifo_async "chan_par_3" "native_tools_dispatch par_3 file_edit $qc $qwd")

    fifo_await_all_settled 15 "$pa" "$pb" "$pc"
    assert_ok $?
    assert_contains "$(cat "$fa")" 'VAL = "new_a"'
    assert_contains "$(cat "$fb")" 'VAL = "new_b"'
    assert_contains "$(cat "$fc")" 'VAL = "new_c"'
}

it "restores only line-0 indentation when line 0 had its leading spaces stripped (Tier 3b first_line_only_strip)" && {
    f="$TEST_TMP/line0_strip.py"
    cat <<'EOF' > "$f"
def outer():
    if cond:
        val = 1
        return val
EOF
    # Line 0 has 0 spaces ("if cond:"), while lines 1-2 retain 8 spaces ("        val = 1")
    args=$(jq -nc --arg p "$f" '{
        path: $p,
        target: "if cond:\n        val = 1\n        return val",
        replacement: "if cond:\n        val = 42\n        return val"
    }')
    res=$(native_tools_dispatch "call_l0" "file_edit" "$args" "$TEST_TMP")
    assert_eq "$(echo "$res" | jq -r '.exit_code')" "0"
    assert_contains "$(echo "$res" | jq -r '.content')" "[indent_norm]"
    # Line 0 must be restored to 4 spaces, and line 1 must remain 8 spaces (not 12!)
    assert_contains "$(cat "$f")" "    if cond:"
    assert_contains "$(cat "$f")" "        val = 42"
    assert_not_contains "$(cat "$f")" "            val = 42"
}

describe "6. Phase 4 Line-Range Anchored file_edit (start_line / end_line)"

it "disambiguates duplicate lines using start_line and end_line without requiring extra context" && {
    f="$TEST_TMP/ranged_dup.py"
    cat <<'EOF' > "$f"
def first_fn():
    status = "pending"
    return status

def second_fn():
    status = "pending"
    return status
EOF
    args=$(jq -nc --arg p "$f" '{
        path: $p,
        start_line: 5,
        end_line: 7,
        target: "    status = \"pending\"",
        replacement: "    status = \"ready\""
    }')
    res=$(native_tools_dispatch "call_rng1" "file_edit" "$args" "$TEST_TMP")
    assert_eq "$(echo "$res" | jq -r '.exit_code')" "0"
    assert_contains "$(echo "$res" | jq -r '.content')" "[exact+line_range]"
    assert_eq "$(sed -n '2p' "$f")" '    status = "pending"'
    assert_eq "$(sed -n '6p' "$f")" '    status = "ready"'
}

it "supports boundary-anchored replacement (start_line + end_line + replacement without target)" && {
    f="$TEST_TMP/ranged_notarget.py"
    cat <<'EOF' > "$f"
line_1 = 1
line_2 = 2
line_3 = 3
line_4 = 4
line_5 = 5
EOF
    args=$(jq -nc --arg p "$f" '{
        path: $p,
        start_line: 2,
        end_line: 4,
        replacement: "replaced_a = 20\nreplaced_b = 30"
    }')
    res=$(native_tools_dispatch "call_rng2" "file_edit" "$args" "$TEST_TMP")
    assert_eq "$(echo "$res" | jq -r '.exit_code')" "0"
    assert_contains "$(echo "$res" | jq -r '.content')" "[line_range]"
    assert_eq "$(wc -l < "$f" | tr -d ' ')" "4"
    assert_eq "$(sed -n '1p' "$f")" "line_1 = 1"
    assert_eq "$(sed -n '2p' "$f")" "replaced_a = 20"
    assert_eq "$(sed -n '3p' "$f")" "replaced_b = 30"
    assert_eq "$(sed -n '4p' "$f")" "line_5 = 5"
}

it "applies multi-hunk ranged edits bottom-up so top-down line numbers never drift" && {
    f="$TEST_TMP/ranged_multi.py"
    cat <<'EOF' > "$f"
header = 1
block_one = "old1"
middle = 2
block_two = "old2"
footer = 3
EOF
    # Block 1 at line 2 expands from 1 line to 3 lines; Block 2 at line 4 still hits original line 4!
    args=$(jq -nc --arg p "$f" '{
        path: $p,
        edits: [
            {start_line: 2, end_line: 2, replacement: "block_one_a = 1\nblock_one_b = 2\nblock_one_c = 3"},
            {start_line: 4, end_line: 4, target: "block_two = \"old2\"", replacement: "block_two = \"new2\""}
        ]
    }')
    res=$(native_tools_dispatch "call_rng3" "file_edit" "$args" "$TEST_TMP")
    assert_eq "$(echo "$res" | jq -r '.exit_code')" "0"
    assert_contains "$(echo "$res" | jq -r '.content')" "[line_range, exact+line_range]"
    assert_contains "$(cat "$f")" "block_one_c = 3"
    assert_contains "$(cat "$f")" 'block_two = "new2"'
    assert_eq "$(tail -n 1 "$f")" "footer = 3"
}

it "rejects invalid start_line > end_line range without modifying the file" && {
    f="$TEST_TMP/ranged_invalid.py"
    printf "a = 1\nb = 2\nc = 3\n" > "$f"
    args=$(jq -nc --arg p "$f" '{
        path: $p,
        start_line: 3,
        end_line: 1,
        replacement: "bad = 0"
    }')
    res=$(native_tools_dispatch "call_rng4" "file_edit" "$args" "$TEST_TMP")
    assert_eq "$(echo "$res" | jq -r '.exit_code')" "1"
    assert_contains "$(echo "$res" | jq -r '.content')" "Invalid line range"
    assert_eq "$(sed -n '2p' "$f")" "b = 2"
}

test_end

