#!/bin/bash
# Test Suite: Autonomous Co-Pilot Multi-Model Engine & Surgical Patching
# Verifies AST reconciliation, safe commenting (zero-line deletion), tool forging,
# phytology integration, and POSIX native tool registration.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." 2>/dev/null && pwd)"
source "$TEST_DIR/framework.sh"

# Source dependencies
source "$LODGE_DIR/lib/core/config.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/native_tools.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/phytology.sh" 2>/dev/null || true

PYTHON_BIN="python3"
[ -x "$LODGE_DIR/.venv/bin/python" ] && PYTHON_BIN="$LODGE_DIR/.venv/bin/python"
ENGINE="$LODGE_DIR/lib/tools/copilot_engine.py"

TMP_DIR="/tmp/test_copilot_$$"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

test_start "Autonomous Co-Pilot Multi-Model Engine"

# ── 1. Python Engine CLI Status ──────────────────────────────────────────
describe "1. Python Engine CLI Status"
it "should report ready status, local endpoint, and tool inventory" && {
    status_out=$("$PYTHON_BIN" "$ENGINE" status)
    assert_contains "$status_out" "Autonomous Co-Pilot Engine Status" "Status title present"
    assert_contains "$status_out" "Tree-sitter AST" "Tree-sitter status reported"
    assert_contains "$status_out" "Llama.cpp local" "Llama.cpp endpoint reported"
}

# ── 2. Surgical Patch Reconciliation (Python AST) ────────────────────────
describe "2. Surgical Patch Reconciliation (Python AST)"
it "should preserve comments and untouched AST functions in Python" && {
    cat << 'EOF' > "$TMP_DIR/calc.py"
# Important configuration comment
# Do not delete this header
PI = 3.14159

def add(a: int, b: int) -> int:
    """Adds two integers together."""
    return a + b

def multiply(a: int, b: int) -> int:
    """Multiplies two integers."""
    return a * b
EOF

    cat << 'EOF' > "$TMP_DIR/calc_proposed.py"
def add(a: int, b: int) -> int:
    """Adds two integers with sanity check."""
    if a is None or b is None:
        raise ValueError("Values cannot be None")
    return a + b
EOF

    patch_out=$("$PYTHON_BIN" "$ENGINE" resolve-patch \
        --original-file "$TMP_DIR/calc.py" \
        --proposed-file "$TMP_DIR/calc_proposed.py" \
        --instruction "Add sanity check to add()" \
        --output-file "$TMP_DIR/calc_result.py")

    assert_contains "$patch_out" "PATCH_RESOLVED" "Patch marked resolved"
    assert_file_exists "$TMP_DIR/calc_result.py" "Output file generated"

    # Check syntax validity of resulting python file
    "$PYTHON_BIN" -m py_compile "$TMP_DIR/calc_result.py"
    assert_ok $? "Patched python file passes AST py_compile"

    # Verify header comment and untouched function remain
    res_content=$(cat "$TMP_DIR/calc_result.py")
    assert_contains "$res_content" "Important configuration comment" "Header comment preserved"
    assert_contains "$res_content" "def multiply" "Untouched multiply function preserved"
    assert_contains "$res_content" "raise ValueError" "Sanity check applied to add function"
}

# ── 3. Surgical Patch Reconciliation (Bash Shell) ────────────────────────
describe "3. Surgical Patch Reconciliation (Bash Shell)"
it "should update Bash function while preserving comments and other functions" && {
    cat << 'EOF' > "$TMP_DIR/worker.sh"
#!/bin/bash
# Worker daemon script v1
# Licensed under MIT

do_work() {
    echo "legacy work"
}

cleanup() {
    echo "cleaning up"
}
EOF

    cat << 'EOF' > "$TMP_DIR/worker_patch.sh"
do_work() {
    echo "modernized work with logging"
}
EOF

    "$PYTHON_BIN" "$ENGINE" resolve-patch \
        --original-file "$TMP_DIR/worker.sh" \
        --proposed-file "$TMP_DIR/worker_patch.sh" \
        --output-file "$TMP_DIR/worker_result.sh"

    assert_file_exists "$TMP_DIR/worker_result.sh" "Patched bash file generated"
    bash -n "$TMP_DIR/worker_result.sh"
    assert_ok $? "Patched bash script passes bash -n validation"

    bash_res=$(cat "$TMP_DIR/worker_result.sh")
    assert_contains "$bash_res" "Worker daemon script v1" "Bash header comment preserved"
    assert_contains "$bash_res" "cleanup()" "Bash cleanup function preserved"
    assert_contains "$bash_res" "modernized work with logging" "do_work function updated"
}

# ── 4. Reject Corrupt or Malformed Patches ────────────────────────────────
describe "4. Reject Corrupt or Malformed Patches"
it "should safely reject invalid syntax proposals" && {
    cat << 'EOF' > "$TMP_DIR/syntax_err.py"
def broken():
    this is completely invalid python syntax ::: :::
EOF

    if "$PYTHON_BIN" "$ENGINE" resolve-patch \
        --original-file "$TMP_DIR/calc.py" \
        --proposed-file "$TMP_DIR/syntax_err.py" \
        --output-file "$TMP_DIR/calc_broken.py" 2>/dev/null; then
        return 1
    else
        assert_ok 0 "Invalid proposal safely rejected"
    fi
}

# ── 5. Safe Commenting with Zero Line Deletions ───────────────────────────
describe "5. Safe Commenting with Zero Line Deletions"
it "should add AST explanations without deleting functional lines" && {
    cat << 'EOF' > "$TMP_DIR/math_ops.py"
def compute_fibonacci(n):
    if n <= 0:
        return 0
    elif n == 1:
        return 1
    return compute_fibonacci(n - 1) + compute_fibonacci(n - 2)
EOF

    orig_lines=$(wc -l < "$TMP_DIR/math_ops.py")

    comment_out=$("$PYTHON_BIN" "$ENGINE" safe-comment \
        --file "$TMP_DIR/math_ops.py" \
        --output-file "$TMP_DIR/math_ops_commented.py")

    assert_contains "$comment_out" "SAFE_COMMENT_APPLIED" "Safe comment succeeded"
    assert_contains "$comment_out" "deleted_lines\": 0" "Zero functional lines deleted confirmed"

    new_lines=$(wc -l < "$TMP_DIR/math_ops_commented.py")
    assert_gt "$new_lines" "$orig_lines" "Line count increased with AST annotations"

    # Verify original code statements still present verbatim
    comm_res=$(cat "$TMP_DIR/math_ops_commented.py")
    assert_contains "$comm_res" "def compute_fibonacci(n):" "Function definition intact"
    assert_contains "$comm_res" "return compute_fibonacci(n - 1) + compute_fibonacci(n - 2)" "Logic intact"
    assert_contains "$comm_res" "# Function: compute_fibonacci" "AST comment added"
}

# ── 6. Tool Forging and Sandboxed Testing ─────────────────────────────────
describe "6. Tool Forging and Sandboxed Testing"
it "should generate, sandbox, and verify new tool" && {
    forge_out=$("$PYTHON_BIN" "$ENGINE" forge-tool \
        --tool-name "metric_counter" \
        --description "Counts lines of code in a given file and formats output" \
        --workdir "$TMP_DIR")

    assert_contains "$forge_out" "TOOL_FORGED_AND_VERIFIED" "Tool forged and verified"
    assert_file_exists "$TMP_DIR/.george/tools/metric_counter.sh" "Forged tool script created"
    assert_file_exists "$TMP_DIR/.george/tools/metric_counter.json" "Tool manifest created"

    # Verify tool script executes successfully
    tool_run=$("$TMP_DIR/.george/tools/metric_counter.sh" 2>&1)
    assert_ok $? "Forged tool executes with exit status 0"
    assert_contains "$tool_run" "executed successfully" "Forged tool reports execution"
}

# ── 7. Native Tool Shell Wrappers ─────────────────────────────────────────
describe "7. Native Tool Shell Wrappers"
it "should execute copilot_patch and copilot_safe_comment shell wrappers" && {
    res=$(copilot_patch "$TMP_DIR/calc.py" "$TMP_DIR/calc_proposed.py" "Testing shell wrapper")
    assert_contains "$res" "PATCH_RESOLVED" "copilot_patch shell function returns resolved status"

    comment_res=$(copilot_safe_comment "$TMP_DIR/math_ops.py")
    assert_contains "$comment_res" "Successfully applied safe comments" "copilot_safe_comment shell function succeeds"
}

# ── 8. Native Tool Registration & Discovery (+copilot) ───────────────────
describe "8. Native Tool Registration & Discovery (+copilot)"
it "should discover +copilot bundle and dispatch tools" && {
    bundle_res=$(tool_search "+copilot")
    assert_contains "$bundle_res" "copilot_patch" "copilot_patch listed in bundle"
    assert_contains "$bundle_res" "copilot_safe_comment" "copilot_safe_comment listed in bundle"
    assert_contains "$bundle_res" "copilot_tool_forge" "copilot_tool_forge listed in bundle"

    # Test execution via execute_native_tool
    exec_res=$(execute_native_tool "copilot_safe_comment" "{\"file_path\":\"$TMP_DIR/math_ops.py\"}")
    assert_contains "$exec_res" "Successfully applied safe comments" "execute_native_tool dispatches copilot_safe_comment"
}

# ── 9. Phytology Integration (phytology_copilot_patch) ───────────────────
describe "9. Phytology Integration (phytology_copilot_patch)"
it "should perform atomic graft and preserve genetic memory snapshot" && {
    cat << 'EOF' > "$TMP_DIR/phytology_target.sh"
#!/bin/bash
# Tissue node v1
echo "version 1"
EOF

    cat << 'EOF' > "$TMP_DIR/phytology_proposal.sh"
#!/bin/bash
# Tissue node v2
echo "version 2"
EOF

    phy_res=$(phytology_copilot_patch "$TMP_DIR/phytology_target.sh" "$TMP_DIR/phytology_proposal.sh" "Upgrade node")
    assert_contains "$phy_res" "GRAFT_SUCCESS" "phytology_copilot_patch reports graft success"

    # Verify content was updated
    updated_content=$(cat "$TMP_DIR/phytology_target.sh")
    assert_contains "$updated_content" "version 2" "Target content updated via graft"
}

# ── 10. Slash Command /copilot ───────────────────────────────────────────
describe "10. Slash Command /copilot"
it "should execute /copilot status subcommand cleanly" && {
    cmd_out=$(bash "$LODGE_DIR/commands/copilot.sh" status)
    assert_contains "$cmd_out" "Co-Pilot Engine Status" "Slash command status header rendered"
}

test_end
