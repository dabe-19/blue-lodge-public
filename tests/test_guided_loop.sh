#!/bin/bash
# ── Tests for Guided Loop Architecture (lib/core/react.sh & lib/tools/honeydew_strategist.py) ──

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/core/react.sh"

# Hermetic stubs: the grammar-constrained evaluator/advisor call the live LLM.
# Evaluator stub returns COMPLETE only when evidence is non-empty; advisor is
# unavailable so the static perturbation catalog is exercised.
react_eval_milestone() {
    if [ -n "${5:-}" ]; then echo "COMPLETE|stub evidence present|synthesize"; else echo "INCOMPLETE|no evidence|search"; fi
}
react_advise() { return 1; }

test_start "Guided Loop Architecture — Digest, Evaluator, Scratchpad & Self-Healing Breaker"

describe "_react_digest_tool_output"
  it "distills facts from tool output and appends to scratchpad.md and memory.md" && {
    tmp_sess=$(mktemp -d)
    tmp_work=$(mktemp -d)

    echo "# Working Memory" > "$tmp_sess/memory.md"
    obs_text='Elevance Health Reports Second Quarter 2026 Results: Operating revenue was $49.8 billion in the second quarter of 2026, up 0.8% from 2Q 2025. Diluted EPS was $6.71 and adjusted diluted EPS was $7.45. Source: https://www.elevancehealth.com/newsroom/q2-2026'

    digest=$(_react_digest_tool_output "call_123" "web_search" '{"query":"Elevance Q2 2026"}' "$obs_text" "Step 1: Gather financial intel" "$tmp_sess" "$tmp_work" "Research healthcare financial intel")

    assert_file_exists "$tmp_sess/scratchpad.md"
    scratch_content=$(cat "$tmp_sess/scratchpad.md")
    assert_contains "$scratch_content" "web_search"
    assert_contains "$scratch_content" "Milestone"
    # Raw observation archiving happens at the tool-call site (react_run),
    # not in the digest — see test_react_e2e_mock.sh envelope case.
    assert_contains "$digest" "Elevance Health"

    # Verify memory.md updated
    mem_content=$(cat "$tmp_sess/memory.md")
    assert_contains "$mem_content" "Active Discoveries & Working Memory"

    rm -rf "$tmp_sess" "$tmp_work"
  }

describe "_react_eval_milestone_evidence"
  it "marks milestone SATISFIED when empirical findings are present in scratchpad" && {
    tmp_sess=$(mktemp -d)
    tmp_work=$(mktemp -d)

    mkdir -p "$tmp_work/.george"
    cat << 'EOF' > "$tmp_sess/honeydew.json"
{
  "primary_task": "Research healthcare financial intel",
  "items": [
    {"id": 1, "task": "Search and fetch deep context on Elevance Q2 2026", "status": "pending", "tier": 1},
    {"id": 2, "task": "Synthesize comprehensive final report", "status": "pending", "tier": 2}
  ]
}
EOF
    cat << 'EOF' > "$tmp_sess/macro_memory.json"
{
  "completed_milestones": []
}
EOF
    cat << 'EOF' > "$tmp_sess/scratchpad.md"
### [12:00:00] web_fetch (https://elevancehealth.com)
- **Milestone**: Step 1
- **Findings**:
* Operating revenue: $49.8 billion
* Diluted EPS: $6.71
* Adjusted diluted EPS: $7.45
* Source: https://www.elevancehealth.com/newsroom/q2-2026
* Status: OK verified
EOF

    eval_res=$(_react_eval_milestone_evidence "$tmp_work" "$tmp_sess" 1 "Search and fetch deep context on Elevance Q2 2026" "Research healthcare financial intel" 'Revenue: $49.8B' 1)

    verdict="${eval_res%%|*}"
    assert_eq "$verdict" "SATISFIED"

    # Verify honeydew.json marked item 1 as done
    item1_status=$(jq -r '(.items[] | select(.id == 1)).status' "$tmp_sess/honeydew.json")
    assert_eq "$item1_status" "done"

    # Verify macro_memory.json has completed milestone
    m_count=$(jq '.completed_milestones | length' "$tmp_sess/macro_memory.json")
    [ "$m_count" -ge 1 ]

    rm -rf "$tmp_sess" "$tmp_work"
  }

describe "_react_self_heal_circuit_breaker"
  it "heals and transitions to synthesis when scratchpad contains evidence instead of failing with 75" && {
    tmp_sess=$(mktemp -d)
    tmp_work=$(mktemp -d)

    echo '[]' > "$tmp_sess/messages.json"
    echo '{"status": "RUNNING"}' > "$tmp_sess/macro_memory.json"
    cat << 'EOF' > "$tmp_sess/scratchpad.md"
### [12:00:00] web_search
- Elevance Health Q2 2026 revenue was $49.8 billion, EPS $6.71.
- CVS Health Q2 2026 revenue was $91.2 billion.
- Centene Q2 2026 revenue was $39.8 billion.
EOF

    _react_self_heal_circuit_breaker "sess_123" "$tmp_work" "$tmp_sess" "web_search" '{"query":"Anthem Q2 2026"}' "$tmp_sess/messages.json" "$tmp_sess/macro_memory.json" 3
    ec=$?
    assert_eq "$ec" "0"

    # Verify advisory injected to steer model to synthesis
    msgs=$(cat "$tmp_sess/messages.json")
    assert_contains "$msgs" "CIRCUIT HEALER"
    assert_contains "$msgs" "synthesize your final report"

    rm -rf "$tmp_sess" "$tmp_work"
  }

  it "trips hard circuit breaker when repetition strikes reach 4 with empty scratchpad" && {
    tmp_sess=$(mktemp -d)
    tmp_work=$(mktemp -d)

    echo '[]' > "$tmp_sess/messages.json"
    echo '{"status": "RUNNING"}' > "$tmp_sess/macro_memory.json"
    # No scratchpad file created

    _react_self_heal_circuit_breaker "sess_123" "$tmp_work" "$tmp_sess" "web_search" '{"query":"Repeated Query"}' "$tmp_sess/messages.json" "$tmp_sess/macro_memory.json" 4
    ec=$?
    assert_eq "$ec" "75"

    rm -rf "$tmp_sess" "$tmp_work"
  }

describe "honeydew_strategist --expand"
  it "auto-satisfies redundant milestone when evidence is already present in scratchpad" && {
    tmp_dir=$(mktemp -d)

    hd_f="$tmp_dir/honeydew.json"
    macro_f="$tmp_dir/macro_memory.json"
    scratch_f="$tmp_dir/scratchpad.md"

    cat << 'EOF' > "$hd_f"
{
  "primary_task": "Research health insurers",
  "items": [
    {"id": 1, "task": "Search Elevance Q2 2026", "status": "done"},
    {"id": 2, "task": "Search Anthem Q2 2026 results", "status": "pending"},
    {"id": 3, "task": "Synthesize final deliverable", "status": "pending"}
  ]
}
EOF
    echo '{"completed_milestones": []}' > "$macro_f"
    cat << 'EOF' > "$scratch_f"
### [12:00:00] Elevance Health
- Elevance Health (formerly Anthem) reports Q2 2026 operating revenue of $49.8 billion.
- Diluted EPS was $6.71.
- URL: https://www.elevancehealth.com/q2-2026
EOF

    python3 "$(dirname "$0")/../lib/tools/honeydew_strategist.py" --expand "Research health insurers" "$hd_f" "$macro_f" "$scratch_f" >/dev/null 2>&1

    # Verify item 2 was marked done due to Anthem/Elevance identity
    item2_st=$(jq -r '(.items[] | select(.id == 2)).status' "$hd_f")
    assert_eq "$item2_st" "done"

    rm -rf "$tmp_dir"
  }

  it "preserves distinct pending research milestones without premature auto-satisfaction" && {
    tmp_dir=$(mktemp -d)

    hd_f="$tmp_dir/honeydew.json"
    macro_f="$tmp_dir/macro_memory.json"
    scratch_f="$tmp_dir/scratchpad.md"

    cat << 'EOF' > "$hd_f"
{
  "primary_task": "Deep research on cyclic learning rates",
  "items": [
    {"id": 1, "task": "Search arXiv for cyclic learning rate schedules and stochastic weight averaging", "status": "pending"},
    {"id": 2, "task": "Extract mathematical formulation and schedule equations from primary papers", "status": "pending"},
    {"id": 3, "task": "Investigate ablation benchmarks across ResNet and CIFAR-10", "status": "pending"},
    {"id": 4, "task": "Synthesize comprehensive research monograph", "status": "pending"}
  ]
}
EOF
    echo '{"completed_milestones": []}' > "$macro_f"
    cat << 'EOF' > "$scratch_f"
# Deep Research Scratchpad: Cyclic Learning Rates
**Date:** 2026-10-03T12:00:00Z
**Domain:** academic

## Research Mandate & Directives (soul.md)
- Ingest primary academic literature, arXiv preprints, exact mathematical formulations, benchmark metrics, and community discourse.
- Download figures to artifacts/ and analyze via vision_analyze.

## Verified Empirical Evidence & Findings
EOF

    python3 "$(dirname "$0")/../lib/tools/honeydew_strategist.py" --expand "Deep research on cyclic learning rates" "$hd_f" "$macro_f" "$scratch_f" >/dev/null 2>&1

    # Verify none of the items were prematurely marked done
    st1=$(jq -r '(.items[] | select(.id == 1)).status' "$hd_f")
    st2=$(jq -r '(.items[] | select(.id == 2)).status' "$hd_f")
    st3=$(jq -r '(.items[] | select(.id == 3)).status' "$hd_f")
    st4=$(jq -r '(.items[] | select(.id == 4)).status' "$hd_f")
    assert_eq "$st1" "pending"
    assert_eq "$st2" "pending"
    assert_eq "$st3" "pending"
    assert_eq "$st4" "pending"

    # Verify _react_eval_milestone_evidence does NOT satisfy Step 1 on empty template
    out=$(_react_eval_milestone_evidence "$tmp_dir" "$tmp_dir" 1 "Search arXiv for cyclic learning rate schedules" "Cyclic learning rates" "" 0)
    assert_contains "$out" "IN_PROGRESS"
    st1_after=$(jq -r '(.items[] | select(.id == 1)).status' "$hd_f")
    assert_eq "$st1_after" "pending"

    rm -rf "$tmp_dir"
  }

  it "does not advance refactor milestones or search milestones upon dir_list inspection" && {
    tmp_dir=$(mktemp -d)
    mkdir -p "$tmp_dir/.george"
    hd_f="$tmp_dir/.george/honeydew.json"
    cat << 'EOF' > "$hd_f"
{
  "primary_task": "Refactor cron job to use research sandbox",
  "items": [
    {"id": 1, "task": "Refactor the cron job script to delegate execution to the native research_sandbox", "status": "pending"},
    {"id": 2, "task": "Update the report delivery mechanism to post to Discord", "status": "pending"}
  ]
}
EOF
    _react_advance_honeydew_plan "$tmp_dir" "dir_list" '{"path": ".george/cron_jobs"}'
    st1=$(jq -r '(.items[] | select(.id == 1)).status' "$hd_f")
    assert_eq "$st1" "pending"

    rm -rf "$tmp_dir"
  }

  it "does not prematurely advance download or search milestones on file_read or hn_search getter calls" && {
    tmp_dir=$(mktemp -d)
    mkdir -p "$tmp_dir/.george"
    hd_f="$tmp_dir/.george/honeydew.json"
    cat << 'EOF' > "$hd_f"
{
  "primary_task": "Research prompt optimization",
  "items": [
    {"id": 1, "task": "Search for and identify 3 to 5 primary academic sources on prompt optimization", "status": "pending"},
    {"id": 2, "task": "Download the identified primary papers into papers/ and extract their full text", "status": "pending"}
  ]
}
EOF
    # Step 1: arxiv_search or hn_search must not advance Step 1
    _react_advance_honeydew_plan "$tmp_dir" "arxiv_search" '{"query": "prompt optimization"}'
    st1=$(jq -r '(.items[] | select(.id == 1)).status' "$hd_f")
    assert_eq "$st1" "pending"

    _react_advance_honeydew_plan "$tmp_dir" "hn_search" '{"query": "prompt optimization"}'
    st1=$(jq -r '(.items[] | select(.id == 1)).status' "$hd_f")
    assert_eq "$st1" "pending"

    # Step 1: Explicit milestone_complete DOES advance Step 1
    _react_advance_honeydew_plan "$tmp_dir" "milestone_complete" '{"status": "success", "summary": "Found 4 papers"}'
    st1=$(jq -r '(.items[] | select(.id == 1)).status' "$hd_f")
    assert_eq "$st1" "done"

    # Step 2: file_read on scratchpad must not advance Step 2
    _react_advance_honeydew_plan "$tmp_dir" "file_read" '{"path": "scratchpad.md"}'
    st2=$(jq -r '(.items[] | select(.id == 2)).status' "$hd_f")
    assert_eq "$st2" "pending"

    # Step 2: Once 2 extracted papers exist in papers/, physical check advances Step 2
    mkdir -p "$tmp_dir/papers"
    echo "paper 1 text" > "$tmp_dir/papers/arXiv_2309.08532.txt"
    echo "paper 2 text" > "$tmp_dir/papers/arXiv_2408.03314.txt"
    _react_advance_honeydew_plan "$tmp_dir" "file_read" '{"path": "scratchpad.md"}'
    st2=$(jq -r '(.items[] | select(.id == 2)).status' "$hd_f")
    assert_eq "$st2" "done"

    rm -rf "$tmp_dir"
  }

describe "Discord #300000000000000001 End-to-End Simulation"
  it "simulates multi-turn research, scratchpad curation, milestone advancement, and self-healing synthesis" && {
    tmp_sess=$(mktemp -d)
    tmp_work=$(mktemp -d)

    mkdir -p "$tmp_work/.george"
    cat << 'EOF' > "$tmp_sess/honeydew.json"
{
  "primary_task": "Gather Q2 2026 earnings for Elevance Health / Anthem",
  "items": [
    {"id": 1, "task": "Search and verify Elevance Health Q2 2026 earnings metrics", "status": "pending", "tier": 1},
    {"id": 2, "task": "Search Anthem Q2 2026 results", "status": "pending", "tier": 2},
    {"id": 3, "task": "Synthesize comprehensive financial intelligence report", "status": "pending", "tier": 3}
  ]
}
EOF
    echo '{"completed_milestones": []}' > "$tmp_sess/macro_memory.json"
    echo '[]' > "$tmp_sess/messages.json"
    echo "# Working Memory" > "$tmp_sess/memory.md"

    # Turn 1: 30KB raw search dump returned
    raw_web_dump="<!DOCTYPE html><html><body><h1>Elevance Health Reports Second Quarter 2026 Results</h1>
<p>INDIANAPOLIS — Elevance Health, Inc. (NYSE: ELV) today announced second quarter 2026 financial results.</p>
<p>Operating revenue was 49.8 billion USD in the second quarter of 2026, an increase of 0.8 percent compared to the prior year quarter.</p>
<p>Diluted EPS was 6.71 USD and adjusted diluted EPS was 7.45 USD. Operating cash flow was 2.1 billion USD.</p>
<p>Anthem Blue Cross Blue Shield continues serving commercial members across 14 states.</p>
<div>$(head -c 25000 < /dev/zero | tr '\0' 'A')</div>
</body></html>"

    # Step 1.1: Digest raw observation
    digest=$(_react_digest_tool_output "call_disc_1" "web_search" '{"query":"Elevance Q2 2026 earnings"}' "$raw_web_dump" "Step 1: Search and verify Elevance Health Q2 2026 earnings metrics" "$tmp_sess" "$tmp_work" "Gather Q2 2026 earnings for Elevance Health / Anthem")

    # Verify scratchpad was updated with dense facts
    assert_file_exists "$tmp_sess/scratchpad.md"
    scratch=$(cat "$tmp_sess/scratchpad.md")
    assert_contains "$scratch" "web_search"
    assert_contains "$scratch" "Milestone"

    # Digest carries the substantive headline (archive is done by react_run)
    assert_contains "$digest" "Elevance Health Reports Second Quarter 2026 Results"

    # Step 1.2: Evaluate milestone against scratchpad
    eval_res=$(_react_eval_milestone_evidence "$tmp_work" "$tmp_sess" 1 "Search and verify Elevance Health Q2 2026 earnings metrics" "Gather Q2 2026 earnings for Elevance Health / Anthem" "$digest" 1)
    verdict="${eval_res%%|*}"
    assert_eq "$verdict" "SATISFIED"

    # Verify Step 1 is marked done
    step1_st=$(jq -r '(.items[] | select(.id == 1)).status' "$tmp_sess/honeydew.json")
    assert_eq "$step1_st" "done"

    # Step 1.3: Dynamic DAG expansion checks if Step 2 is redundant
    _react_expand_honeydew_dag "Gather Q2 2026 earnings for Elevance Health / Anthem" "$tmp_work" "$tmp_sess"

    # Step 1.4: Curated observation digest appended to messages.json
    lean_digest='[OBSERVATION DIGEST: Elevance Health Q2 2026 revenue was 49.8B USD, diluted EPS 6.71 USD, adjusted EPS 7.45 USD. Operating cash flow 2.1B USD.]'
    jq --arg c "$lean_digest" '. += [{"role": "tool", "content": $c}]' "$tmp_sess/messages.json" > "$tmp_sess/messages.json.tmp" && mv "$tmp_sess/messages.json.tmp" "$tmp_sess/messages.json"

    # Verify messages.json is lean (< 1 KB) instead of 30+ KB
    msg_bytes=$(wc -c < "$tmp_sess/messages.json")
    [ "$msg_bytes" -lt 1500 ]

    # Turn 2: Model attempts to repeat search for Anthem (repetition Strike 3 simulation)
    # Self-healing circuit breaker triggers
    _react_self_heal_circuit_breaker "disc_sess" "$tmp_work" "$tmp_sess" "web_search" '{"query":"Anthem second quarter 2026 results"}' "$tmp_sess/messages.json" "$tmp_sess/macro_memory.json" 3
    heal_ec=$?
    assert_eq "$heal_ec" "0"

    # Verify messages.json has synthesis guidance
    msgs_after=$(cat "$tmp_sess/messages.json")
    assert_contains "$msgs_after" "CIRCUIT HEALER"
    assert_contains "$msgs_after" "synthesize your final report"

    # Verify context engine injects the updated scratchpad into prompt
    source "$(dirname "$0")/../lib/core/context_engine.sh"
    ctx_prompt=$(AGENT_ACTIVE_SESSION_DIR="$tmp_sess" context_engine_build "Gather Q2 2026 earnings for Elevance Health / Anthem" "$tmp_work" "full")
    assert_contains "$ctx_prompt" "scratchpad"

    rm -rf "$tmp_sess" "$tmp_work"
  }

test_end
