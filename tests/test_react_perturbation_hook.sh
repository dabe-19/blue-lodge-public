#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Test: ReAct Circuit Breaker Prompt Perturbation & Phytology Manifest Alignment
# ═══════════════════════════════════════════════════════════════

set -euo pipefail
LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LODGE_DIR

source "$LODGE_DIR/tests/framework.sh"
source "$LODGE_DIR/lib/limits.sh"
source "$LODGE_DIR/lib/cache.sh"
source "$LODGE_DIR/lib/native_tools.sh"
source "$LODGE_DIR/lib/commands.sh"
source "$LODGE_DIR/lib/react.sh"

test_start "lib/react.sh — Circuit Breaker Perturbation & Tool Manifest Alignment"

# Setup sandbox workspace
SANDBOX_DIR=$(mktemp -d /tmp/george_perturbation_test_XXXXXX)
trap 'rm -rf "$SANDBOX_DIR"' EXIT
SESSION_ID="test_pert_$(date +%s)"
SESSION_DIR="$SANDBOX_DIR/session"
mkdir -p "$SESSION_DIR" "$SANDBOX_DIR/.george"
MESSAGES_FILE="$SESSION_DIR/messages.json"
echo '[]' > "$MESSAGES_FILE"
MACRO_FILE="$SANDBOX_DIR/.george/macro_memory.json"
echo '{"primary_objective":"Audit living tissue and verify phytology health"}' > "$MACRO_FILE"

# ── 1. Classification Tests ──────────────────────────────────────────
describe "Circuit State Classification"

it "classifies tool_search thrashing when streak >= 2" && {
    cls_search=$(_react_classify_circuit_state "tool_search" "phytology" "" 2 0 0)
    assert_eq "$cls_search" "TOOL_SEARCH_THRASHING"
}

it "classifies phytology subcommand error" && {
    cls_phyto=$(_react_classify_circuit_state "phytology_manage" "" "Unknown /phytology subcommand: '{\\'" 0 1 0)
    assert_eq "$cls_phyto" "PHYTOLOGY_ERROR"
}

it "classifies shell syntax error" && {
    cls_syntax=$(_react_classify_circuit_state "bash_exec" "find . -name )" "syntax error near unexpected token ')'" 0 1 0)
    assert_eq "$cls_syntax" "SHELL_SYNTAX_ERROR"
}

it "classifies consecutive tool failures" && {
    cls_fails=$(_react_classify_circuit_state "file_read" "path=foo" "File not found" 0 2 0)
    assert_eq "$cls_fails" "CONSECUTIVE_TOOL_FAILURES"
}

it "classifies action repetition strike 2" && {
    cls_rep=$(_react_classify_circuit_state "file_read" "path=foo" "" 0 0 2)
    assert_eq "$cls_rep" "ACTION_REPETITION"
}

# ── 2. Prompt Perturbation Injection Tests ───────────────────────────
describe "Prompt Perturbation Hook & Injection"

it "injects static perturbation for TOOL_SEARCH_THRASHING" && {
    (
        ACTIVE_ENDPOINT_URL=""
        TIER2_URL=""
        TIER3_URL=""
        pert=$(_react_circuit_breaker_perturbation "$SESSION_ID" "$SANDBOX_DIR" "TOOL_SEARCH_THRASHING" "tool_search" "repeated calls" "$MESSAGES_FILE" "$MACRO_FILE")
        assert_contains "$pert" "Cease searching"
        assert_contains "$pert" "phytology_manage"

        injected=$(jq -r '.[-1].content' "$MESSAGES_FILE")
        assert_contains "$injected" "Loop thrashing detected on tool_search"
    )
}

it "injects static perturbation for PHYTOLOGY_ERROR" && {
    (
        ACTIVE_ENDPOINT_URL=""
        TIER2_URL=""
        TIER3_URL=""
        pert_phyto=$(_react_circuit_breaker_perturbation "$SESSION_ID" "$SANDBOX_DIR" "PHYTOLOGY_ERROR" "phytology_manage" "Unknown subcommand" "$MESSAGES_FILE" "$MACRO_FILE")
        assert_contains "$pert_phyto" "Valid subcommands for phytology_manage"
    )
}

it "injects static perturbation for SHELL_SYNTAX_ERROR" && {
    (
        ACTIVE_ENDPOINT_URL=""
        TIER2_URL=""
        TIER3_URL=""
        pert_syntax=$(_react_circuit_breaker_perturbation "$SESSION_ID" "$SANDBOX_DIR" "SHELL_SYNTAX_ERROR" "bash_exec" "syntax error" "$MESSAGES_FILE" "$MACRO_FILE")
        assert_contains "$pert_syntax" "Shell syntax error"
    )
}

# ── 3. Tool Search Manifest Alignment ─────────────────────────────────
describe "Tool Search & Bedrock Primacy"

it "recognizes phytology_manage as bedrock and does not mount +models" && {
    native_tools_fts_init 1
    search_res=$(native_tools_search "phytology living tissue health status audit" "$SESSION_DIR" 36)
    assert_contains "$search_res" "core bedrock tool"
    assert_contains "$search_res" "ALREADY mounted"
    assert_not_contains "$search_res" "+models"
}

it "maps +phytology bundle to phytology_manage" && {
    bundle_res=$(native_tools_bundle_tools "+phytology")
    assert_eq "$bundle_res" "phytology_manage"
}

# ── 4. phytology_manage JSON Unpack & Execution ───────────────────────
describe "phytology_manage Robustness & Dispatch"

it "unwraps nested JSON action string in phytology_manage" && {
    nested_json='{"action":"{\"action\": \"status\"}"}'
    disp_res=$(native_tools_dispatch "call-test-1" "phytology_manage" "$nested_json" "$LODGE_DIR")
    assert_contains "$disp_res" "GEORGE LIVING TISSUE & PHYTOLOGY MANIFEST"
}

it "dispatches standard action=status" && {
    std_json='{"action":"status"}'
    disp_std=$(native_tools_dispatch "call-test-2" "phytology_manage" "$std_json" "$LODGE_DIR")
    assert_contains "$disp_std" "Cambium Root"
}

it "dispatches audit with flags=--cached" && {
    audit_json='{"action":"audit","flags":"--cached"}'
    disp_audit=$(native_tools_dispatch "call-test-3" "phytology_manage" "$audit_json" "$LODGE_DIR")
    assert_contains "$disp_audit" "SOFTWARE PHYTOLOGY LIVING TISSUE AUDIT"
}

test_end
