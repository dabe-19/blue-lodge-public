#!/bin/bash
# ── Tests for Architectural Conformance Gate & Four-Layer Immune System ──

source "$(dirname "$0")/framework.sh"

test_start "Architectural Conformance Gate (lodge-lint & scaffold)"

describe "Lodge-Lint Mechanical Conformance Gate"
  it "runs clean on current repository and passes all 11 gates" && {
    out=$("$LODGE_DIR/bin/lodge-lint")
    assert_ok $?
    assert_contains "$out" "All architectural conformance gates passed"
  }

  it "outputs structured JSON in --json mode" && {
    json_out=$("$LODGE_DIR/bin/lodge-lint" --json)
    assert_ok $?
    status=$(echo "$json_out" | jq -r '.status // empty')
    assert_eq "$status" "passed"
    failed=$(echo "$json_out" | jq -r '.failed // 1')
    assert_eq "$failed" "0"
  }

  it "detects and rejects loose source files in lib/ root" && {
    bad_file="$LODGE_DIR/lib/_temp_loose_$$.sh"
    echo "#!/bin/bash" > "$bad_file"
    echo "echo bad" >> "$bad_file"

    st=0
    "$LODGE_DIR/bin/lodge-lint" --json >/dev/null 2>&1 || st=$?
    rm -f "$bad_file"

    assert_eq "$st" "1"
  }

  it "detects and rejects multi-line inline Python heredocs" && {
    bad_tool="$LODGE_DIR/.george/tools/_temp_bad_heredoc_$$.sh"
    mkdir -p "$LODGE_DIR/.george/tools"
    printf '#!/bin/bash\npython3 << '"'EOF'"'\nimport sys\nprint("violation")\nEOF\n' > "$bad_tool"

    st=0
    "$LODGE_DIR/bin/lodge-lint" --json >/dev/null 2>&1 || st=$?
    rm -f "$bad_tool"

    assert_eq "$st" "1"
  }

  it "detects and rejects symlinks in lib/ and scripts/" && {
    bad_link="$LODGE_DIR/lib/_temp_link_$$.sh"
    ln -s "core/env.sh" "$bad_link"

    st=0
    "$LODGE_DIR/bin/lodge-lint" --json >/dev/null 2>&1 || st=$?
    rm -f "$bad_link"

    assert_eq "$st" "1"
  }

describe "Scaffolding Archetypes (bin/scaffold)"
  it "shows CLI help documentation" && {
    help_out=$("$LODGE_DIR/bin/scaffold" --help)
    assert_contains "$help_out" "module"
    assert_contains "$help_out" "ipc"
    assert_contains "$help_out" "tool"
  }

  it "scaffolds a compliant domain library module" && {
    mod_name="test_mod_$$"
    "$LODGE_DIR/bin/scaffold" module ipc "$mod_name" --polyglot --desc "Test scaffold" >/dev/null 2>&1

    assert_file_exists "$LODGE_DIR/lib/ipc/${mod_name}.sh"
    assert_file_exists "$LODGE_DIR/lib/ipc/${mod_name}_backend.py"
    assert_file_not_exists "$LODGE_DIR/lib/${mod_name}.sh"
    assert_file_exists "$LODGE_DIR/tests/test_${mod_name}.sh"

    # Cleanup
    rm -f "$LODGE_DIR/lib/ipc/${mod_name}.sh"
    rm -f "$LODGE_DIR/lib/ipc/${mod_name}_backend.py"
    rm -f "$LODGE_DIR/tests/test_${mod_name}.sh"
  }

  it "scaffolds a FIFO-IPC worker adhering to flow control & UUID linking" && {
    w_name="test_worker_$$"
    "$LODGE_DIR/bin/scaffold" ipc "$w_name" "chan_$$" --desc "Test IPC worker" >/dev/null 2>&1

    assert_file_exists "$LODGE_DIR/scripts/workers/${w_name}.sh"
    assert_file_exists "$LODGE_DIR/tests/test_ipc_${w_name}.sh"

    # Verify FIFO-IPC & UUID invariants are in the generated code
    w_content=$(cat "$LODGE_DIR/scripts/workers/${w_name}.sh")
    assert_contains "$w_content" "fifo_ipc.sh"
    assert_contains "$w_content" "ipc_channel_open"
    assert_contains "$w_content" "uuid_generate"
    assert_contains "$w_content" "identity_link"

    # Cleanup
    rm -f "$LODGE_DIR/scripts/workers/${w_name}.sh"
    rm -f "$LODGE_DIR/tests/test_ipc_${w_name}.sh"
  }

  it "scaffolds a privileged operator tool with RBAC permission gate" && {
    t_name="test_tool_$$"
    "$LODGE_DIR/bin/scaffold" tool "$t_name" "workspace:write" --desc "Test RBAC tool" >/dev/null 2>&1

    assert_file_exists "$LODGE_DIR/.george/tools/${t_name}.sh"
    assert_file_exists "$LODGE_DIR/tests/test_tool_${t_name}.sh"

    # Verify RBAC & UUID invariants are in the generated code
    t_content=$(cat "$LODGE_DIR/.george/tools/${t_name}.sh")
    assert_contains "$t_content" "auth_check_permission"
    assert_contains "$t_content" "identity_link"
    assert_contains "$t_content" "uuid_generate"

    # Cleanup
    rm -f "$LODGE_DIR/.george/tools/${t_name}.sh"
    rm -f "$LODGE_DIR/tests/test_tool_${t_name}.sh"
  }

describe "Slash Command Dispatcher Integration (/scaffold)"
  it "executes /scaffold help from the slash command handler" && {
    source "$LODGE_DIR/commands/scaffold.sh"
    cmd_out=$(cmd_scaffold help)
    assert_contains "$cmd_out" "/scaffold module"
    assert_contains "$cmd_out" "/scaffold ipc"
    assert_contains "$cmd_out" "/scaffold tool"
  }

test_end
