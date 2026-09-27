#!/bin/bash
# ── Tests for Guided Loop Architecture (lib/react.sh & lib/honeydew_strategist.py) ──

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/react.sh"

test_start "Guided Loop Architecture — Digest, Evaluator, Scratchpad & Self-Healing Breaker"

describe "_react_digest_tool_output"
  it "distills facts from tool output and appends to scratchpad.md and memory.md" && {
    tmp_sess=$(mktemp -d)
    tmp_work=$(mktemp -d)

    echo "# Working Memory" > "$tmp_sess/memory.md"
    obs_text='Elevance Health Reports Second Quarter 2026 Results: Operating revenue was $49.8 billion in the second quarter of 2026, up 0.8% from 2Q 2025. Diluted EPS was $6.71 and adjusted diluted EPS was $7.45. Source: https://www.elevancehealth.com/newsroom/q2-2026'

    digest=$(_react_digest_tool_output "call_123" "web_search" '{"query":"Elevance Q2 2026"}' "$obs_text" "Step 1: Gather financial intel" "$tmp_sess" "$tmp_work" "Research healthcare financial intel")

    assert_file_exists "$tmp_sess/scratchpad.md"
    assert_file_exists "$tmp_sess/observations/call_123.txt"
    scratch_content=$(cat "$tmp_sess/scratchpad.md")
    assert_contains "$scratch_content" "web_search"
    assert_contains "$scratch_content" "Milestone"
    # Verify raw observation was archived
    raw_saved=$(cat "$tmp_sess/observations/call_123.txt")
    assert_contains "$raw_saved" "Elevance Health"

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
    cat << 'EOF' > "$tmp_work/.george/honeydew.json"
{
  "primary_task": "Research healthcare financial intel",
  "items": [
    {"id": 1, "task": "Search and fetch deep context on Elevance Q2 2026", "status": "pending", "tier": 1},
    {"id": 2, "task": "Synthesize comprehensive final report", "status": "pending", "tier": 2}
  ]
}
EOF
    cat << 'EOF' > "$tmp_work/.george/macro_memory.json"
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

    eval_res=$(_react_eval_milestone_evidence "$tmp_work" "$tmp_sess" 1 "Search and fetch deep context on Elevance Q2 2026" "Research healthcare financial intel" 'Revenue: $49.8B')

    verdict="${eval_res%%|*}"
    assert_eq "$verdict" "SATISFIED"

    # Verify honeydew.json marked item 1 as done
    item1_status=$(jq -r '(.items[] | select(.id == 1)).status' "$tmp_work/.george/honeydew.json")
    assert_eq "$item1_status" "done"

    # Verify macro_memory.json has completed milestone
    m_count=$(jq '.completed_milestones | length' "$tmp_work/.george/macro_memory.json")
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

    python3 "$(dirname "$0")/../lib/honeydew_strategist.py" --expand "Research health insurers" "$hd_f" "$macro_f" "$scratch_f" >/dev/null 2>&1

    # Verify item 2 was marked done due to Anthem/Elevance identity
    item2_st=$(jq -r '(.items[] | select(.id == 2)).status' "$hd_f")
    assert_eq "$item2_st" "done"

    rm -rf "$tmp_dir"
  }

describe "Discord #1477077957691576393 End-to-End Simulation"
  it "simulates multi-turn research, scratchpad curation, milestone advancement, and self-healing synthesis" && {
    tmp_sess=$(mktemp -d)
    tmp_work=$(mktemp -d)

    mkdir -p "$tmp_work/.george"
    cat << 'EOF' > "$tmp_work/.george/honeydew.json"
{
  "primary_task": "Gather Q2 2026 earnings for Elevance Health / Anthem",
  "items": [
    {"id": 1, "task": "Search and verify Elevance Health Q2 2026 earnings metrics", "status": "pending", "tier": 1},
    {"id": 2, "task": "Search Anthem Q2 2026 results", "status": "pending", "tier": 2},
    {"id": 3, "task": "Synthesize comprehensive financial intelligence report", "status": "pending", "tier": 3}
  ]
}
EOF
    echo '{"completed_milestones": []}' > "$tmp_work/.george/macro_memory.json"
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

    # Verify raw observation was archived to disk, not polluting messages
    assert_file_exists "$tmp_sess/observations/call_disc_1.txt"
    raw_archived=$(cat "$tmp_sess/observations/call_disc_1.txt")
    assert_contains "$raw_archived" "Elevance Health Reports Second Quarter 2026 Results"

    # Step 1.2: Evaluate milestone against scratchpad
    eval_res=$(_react_eval_milestone_evidence "$tmp_work" "$tmp_sess" 1 "Search and verify Elevance Health Q2 2026 earnings metrics" "Gather Q2 2026 earnings for Elevance Health / Anthem" "$digest")
    verdict="${eval_res%%|*}"
    assert_eq "$verdict" "SATISFIED"

    # Verify Step 1 is marked done
    step1_st=$(jq -r '(.items[] | select(.id == 1)).status' "$tmp_work/.george/honeydew.json")
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
    _react_self_heal_circuit_breaker "disc_sess" "$tmp_work" "$tmp_sess" "web_search" '{"query":"Anthem second quarter 2026 results"}' "$tmp_sess/messages.json" "$tmp_work/.george/macro_memory.json" 3
    heal_ec=$?
    assert_eq "$heal_ec" "0"

    # Verify messages.json has synthesis guidance
    msgs_after=$(cat "$tmp_sess/messages.json")
    assert_contains "$msgs_after" "CIRCUIT HEALER"
    assert_contains "$msgs_after" "synthesize your final report"

    # Verify context engine injects the updated scratchpad into prompt
    source "$(dirname "$0")/../lib/context_engine.sh"
    ctx_prompt=$(context_engine_build "$tmp_work" "Gather Q2 2026 earnings for Elevance Health / Anthem" "full")
    assert_contains "$ctx_prompt" "scratchpad"

    rm -rf "$tmp_sess" "$tmp_work"
  }

test_end
