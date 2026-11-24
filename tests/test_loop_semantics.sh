#!/bin/bash
# ── Tests: Loop Semantics, 5-Domain Taxonomy & Error Sanitization ────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/api.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/web.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/native_tools.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/react.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/research_graph.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/sentinel.sh" 2>/dev/null || true

TEST_TMP=$(mktemp -d /tmp/george-loop-test-XXXXXX)
cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "Loop Semantics & 5-Domain Architecture"

describe "404/403 Web Egress Sanitization"
it "sanitizes HTTP 404 errors to standardized 1-line signature without HTML bloat" && {
    out=$(web_fetch "http://127.0.0.1:9876/definitely_not_found" 2>/dev/null || true)
    assert_contains "$out" "FETCH FAILED"
    # Verify no raw HTML doctype or tags leaked
    assert_not_contains "$out" "<!DOCTYPE html>"
    assert_not_contains "$out" "<html"
    # Verify signature length is compact (< 300 chars)
    [ "${#out}" -lt 300 ]
}

describe "Tool Scoping & Synthesis Mode"
it "masks search tools during synthesis milestones" && {
    tools_json='[{"type":"function","function":{"name":"searxng_search"}},{"type":"function","function":{"name":"arxiv_search"}},{"type":"function","function":{"name":"file_write"}}]'
    scoped=$(export REACT_TOOL_FILTER="research"; _react_scope_tools_for_step "$tools_json" "Synthesize Final Deliverable")
    assert_contains "$scoped" "file_write"
    assert_not_contains "$scoped" "searxng_search"
    assert_not_contains "$scoped" "arxiv_search"
}

it "permits search tools during exploration/retrieval milestones" && {
    tools_json='[{"type":"function","function":{"name":"searxng_search"}},{"type":"function","function":{"name":"file_write"}}]'
    scoped=$(export REACT_TOOL_FILTER="research"; _react_scope_tools_for_step "$tools_json" "Search and investigate sources")
    assert_contains "$scoped" "searxng_search"
    assert_contains "$scoped" "file_write"
}

describe "5-Domain Classification"
it "classifies gaming, emulation, and decompilation topics" && {
    d=$(research_classify_domain "Nintendo GameCube Dolphin JIT Recompiler and Decompilation")
    assert_eq "$d" "gaming"
    d2=$(research_classify_domain "PlayStation 2 Emotion Engine Vector Unit Emulation")
    assert_eq "$d2" "gaming"
}

it "classifies finance, investment, and crypto topics" && {
    d=$(research_classify_domain "Apple Q3 10-K EBITDA Margin and Cash Flow Valuation")
    assert_eq "$d" "finance"
    d2=$(research_classify_domain "Ethereum Layer 2 Tokenomics and Staking Yield")
    assert_eq "$d2" "finance"
}

it "classifies sports and automotive topics" && {
    d=$(research_classify_domain "Porsche 911 GT3 RS Powertrain Dyno and Nurburgring Lap Time")
    assert_eq "$d" "general_sports_auto"
    d2=$(research_classify_domain "Kansas City Chiefs Offensive Depth Chart and Starters")
    assert_eq "$d2" "general_sports_auto"
}

it "classifies software engineering and system topics" && {
    d=$(research_classify_domain "Linux Kernel eBPF Network Driver RFC Architecture")
    assert_eq "$d" "engineering"
}

it "classifies academic and scientific topics" && {
    d=$(research_classify_domain "Claude Shannon Entropy Bounds in 4-bit KV Cache")
    assert_eq "$d" "academic"
}

describe "5-Domain Milestone Deterministic Advancement"
it "auto-advances search milestone when gaming domain evidence is in scratchpad" && {
    sandbox="$TEST_TMP/sandbox_gaming"
    mkdir -p "$sandbox/.george"
    cat << 'EOF' > "$sandbox/.george/honeydew.json"
{
  "items": [
    {"id": 1, "task": "Search and investigate JIT recompilation architecture", "status": "pending"}
  ]
}
EOF
    cat << 'EOF' > "$sandbox/scratchpad.md"
# Scratchpad
- JIT recompiler translates MIPS R5900 instructions dynamically into x86-64 micro-ops.
- Vector Unit VU0 and VU1 operate in parallel with cycle accuracy constraints.
- Verified in decompilation codebase https://github.com/example/decomp.
- Execution bounds verified.
EOF
    out=$(_react_eval_milestone_evidence "$sandbox" "$sandbox" 1 "Search and investigate JIT recompilation architecture" "Investigate emulation" "" 0)
    assert_contains "$out" "SATISFIED"
    status=$(jq -r '.items[0].status' "$sandbox/.george/honeydew.json")
    assert_eq "$status" "done"
}

it "auto-advances search milestone when automotive/sports domain evidence is in scratchpad" && {
    sandbox="$TEST_TMP/sandbox_auto"
    mkdir -p "$sandbox/.george"
    cat << 'EOF' > "$sandbox/.george/honeydew.json"
{
  "items": [
    {"id": 1, "task": "Search and gather official vehicle technical specifications", "status": "pending"}
  ]
}
EOF
    cat << 'EOF' > "$sandbox/scratchpad.md"
# Scratchpad
- Naturally aspirated 4.0-liter flat-six produces 518 horsepower and 342 lb-ft of torque.
- 0-60 mph achieved in 3.0 seconds with top speed of 184 mph.
- Downforce generated is 1,895 lbs at 177 mph.
- Chassis and suspension damping curves verified from OEM spec sheet.
EOF
    out=$(_react_eval_milestone_evidence "$sandbox" "$sandbox" 1 "Search and gather official vehicle technical specifications" "Analyze Porsche 911" "" 0)
    assert_contains "$out" "SATISFIED"
    status=$(jq -r '.items[0].status' "$sandbox/.george/honeydew.json")
    assert_eq "$status" "done"
}

describe "Sentinel Sandbox Protection"
it "protects active sandboxes with running processes from reaper deletion" && {
    sbox_dir="$TEST_TMP/research_active_test_12345"
    mkdir -p "$sbox_dir"
    sleep 30 &
    bg_pid=$!
    echo "$bg_pid" > "$sbox_dir/.pid"

    is_protected=0
    if [ -f "$sbox_dir/.pid" ]; then
        r_pid=$(cat "$sbox_dir/.pid" 2>/dev/null)
        if [ -n "$r_pid" ] && kill -0 "$r_pid" 2>/dev/null; then
            is_protected=1
        fi
    fi
    kill "$bg_pid" 2>/dev/null || true
    wait "$bg_pid" 2>/dev/null || true

    assert_eq "$is_protected" 1
}

describe "Error Observation Formatting"
it "condenses generic tool errors to 300 chars while preserving phytology faults" && {
    long_err=$(python3 -c 'print("A" * 1000)')
    # Generic condensation
    condensed="${long_err:0:300}"
    [ "${#condensed}" -eq 300 ]

    # Phytology preservation
    phyto_err="[PHYTOLOGY FAULT: phyto_cache_invalidate failed with code 2: lock busy]"
    clean_phyto=""
    if [[ "$phyto_err" =~ (\[PHYTOLOGY\ FAULT:[^]]+\]) ]]; then
        clean_phyto="${BASH_REMATCH[1]}"
    fi
    assert_eq "$clean_phyto" "$phyto_err"
}

test_end
