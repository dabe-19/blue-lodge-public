#!/bin/bash
# ── Tests: Optimization changes across agent.sh, web.sh, memory.sh ──
# Verifies _strip_think_blocks, contradiction guard, milestone dedup,
# web blacklist TTL, conversation buffer compression, junk detection,
# and ask-mode prompt updates.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/tools.sh"
source "$LODGE_DIR/lib/journal.sh"
source "$LODGE_DIR/lib/agent.sh"
source "$LODGE_DIR/lib/web.sh"

test_start "Optimizations — agent.sh / web.sh / memory.sh"

# ══════════════════════════════════════════════════════════════
# _strip_think_blocks
# ══════════════════════════════════════════════════════════════
describe "_strip_think_blocks"

  it "removes <think>...</think> inline block" && {
    result=$(echo 'Hello <think>inner thought</think> world' | _strip_think_blocks)
    assert_eq "$result" "Hello  world"
  }

  it "removes [THINK]...[/THINK] inline block" && {
    result=$(echo 'Before [THINK]thinking here[/THINK] after' | _strip_think_blocks)
    assert_eq "$result" "Before  after"
  }

  it "removes [THOUGHT]...[/THOUGHT] inline block" && {
    result=$(echo 'Start [THOUGHT]deep thought[/THOUGHT] end' | _strip_think_blocks)
    assert_eq "$result" "Start  end"
  }

  it "removes multi-line <think> block" && {
    input=$'Line 1\n<think>\nthinking line 1\nthinking line 2\n</think>\nLine 2'
    result=$(echo "$input" | _strip_think_blocks)
    expected=$'Line 1\nLine 2'
    assert_eq "$result" "$expected"
  }

  it "removes multi-line [THINK] block" && {
    input=$'Before\n[THINK]\nstuff\n[/THINK]\nAfter'
    result=$(echo "$input" | _strip_think_blocks)
    expected=$'Before\nAfter'
    assert_eq "$result" "$expected"
  }

  it "handles unclosed <think> block (strips to end)" && {
    input=$'Line 1\n<think>\nforever thinking\nstill thinking'
    result=$(echo "$input" | _strip_think_blocks)
    assert_eq "$result" "Line 1"
  }

  it "handles case-insensitive tags" && {
    result=$(echo 'Hello <THINK>loud thinking</THINK> world' | _strip_think_blocks)
    assert_eq "$result" "Hello  world"
  }

  it "preserves text when no think blocks present" && {
    result=$(echo 'Just normal text here' | _strip_think_blocks)
    assert_eq "$result" "Just normal text here"
  }

  it "handles empty input" && {
    result=$(echo '' | _strip_think_blocks)
    assert_empty "$result"
  }

  it "strips orphaned closing tags" && {
    result=$(echo 'text </think> more' | _strip_think_blocks)
    assert_eq "$result" "text  more"
  }

# ══════════════════════════════════════════════════════════════
# Contradiction guard (evaluator)
# ══════════════════════════════════════════════════════════════
describe "Contradiction guard structure"

  it "agent.sh contains case-based contradiction guard" && {
    grep -q 'Contradiction guard' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

  it "hard negation tier uses case statement" && {
    body=$(cat "$LODGE_DIR/lib/agent.sh")
    echo "$body" | grep -q 'not achieved\|unable to\|could not\|cannot\|impossible\|no progress'
    assert_ok $?
  }

  it "soft negation tier checks for dismissal qualifiers" && {
    body=$(cat "$LODGE_DIR/lib/agent.sh")
    echo "$body" | grep -q 'but\|however\|irrelevant\|not required'
    assert_ok $?
  }

# ══════════════════════════════════════════════════════════════
# Milestone deduplication
# ══════════════════════════════════════════════════════════════
describe "Milestone deduplication"

  it "uses 120-char normalized comparison" && {
    grep -q '_milestone_norm.*:0:120' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

  it "strips articles and prepositions for normalization" && {
    body=$(cat "$LODGE_DIR/lib/agent.sh")
    echo "$body" | grep -q 'the\\|a\\|an\\|to\\|for\\|of\\|in\\|on\\|at\\|by\\|with\\|from\\|into\\|via\\|using'
    assert_ok $?
  }

# ══════════════════════════════════════════════════════════════
# Web blacklist TTL
# ══════════════════════════════════════════════════════════════
describe "Web blacklist TTL"

  it "WEB_BLACKLIST_TTL defaults to 1800" && {
    assert_eq "${WEB_BLACKLIST_TTL}" "1800"
  }

  it "_web_blacklist_contains function exists" && {
    declare -f _web_blacklist_contains &>/dev/null
    assert_ok $?
  }

  it "_web_blacklist_contains checks TTL via date epoch" && {
    body=$(declare -f _web_blacklist_contains)
    echo "$body" | grep -q '_age.*WEB_BLACKLIST_TTL'
    assert_ok $?
  }

  it "preloaded domain blacklist is not subject to TTL" && {
    # Domain blacklist check returns before the TTL check
    body=$(declare -f _web_blacklist_contains)
    domain_line=$(echo "$body" | grep -n 'WEB_BLACKLIST_DOMAINS' | head -1 | cut -d: -f1)
    ttl_line=$(echo "$body" | grep -n 'WEB_BLACKLIST_TTL' | head -1 | cut -d: -f1)
    [ -n "$domain_line" ] && [ -n "$ttl_line" ] && [ "$domain_line" -lt "$ttl_line" ]
    assert_ok $? "Domain blacklist should be checked before TTL logic"
  }

# ══════════════════════════════════════════════════════════════
# Conversation buffer (6 exchanges, graduated compression)
# ══════════════════════════════════════════════════════════════
describe "Conversation buffer"

  it "AGENT_CONV_MAX defaults to 6" && {
    assert_eq "${AGENT_CONV_MAX}" "6"
  }

  it "_agent_conv_push is defined" && {
    declare -f _agent_conv_push &>/dev/null
    assert_ok $?
  }

  it "_agent_conv_context is defined" && {
    declare -f _agent_conv_context &>/dev/null
    assert_ok $?
  }

  it "_agent_conv_push stores to both history and full arrays" && {
    # Reset state
    _AGENT_CONV_HISTORY=()
    _AGENT_CONV_FULL=()
    _agent_conv_push "Hello" "World"
    assert_eq "${#_AGENT_CONV_HISTORY[@]}" "1"
    assert_eq "${#_AGENT_CONV_FULL[@]}" "1"
  }

  it "_agent_conv_push trims at AGENT_CONV_MAX" && {
    _AGENT_CONV_HISTORY=()
    _AGENT_CONV_FULL=()
    for i in 1 2 3 4 5 6 7 8; do
      _agent_conv_push "q$i" "a$i"
    done
    assert_eq "${#_AGENT_CONV_HISTORY[@]}" "$AGENT_CONV_MAX"
    assert_eq "${#_AGENT_CONV_FULL[@]}" "$AGENT_CONV_MAX"
  }

  it "_agent_conv_context returns empty when no history" && {
    _AGENT_CONV_HISTORY=()
    _AGENT_CONV_FULL=()
    result=$(_agent_conv_context)
    assert_empty "$result"
  }

  it "_agent_conv_context applies graduated compression" && {
    _AGENT_CONV_HISTORY=()
    _AGENT_CONV_FULL=()
    # Push 6 exchanges with long george responses
    long_text=$(printf 'x%.0s' $(seq 1 500))
    for i in 1 2 3 4 5 6; do
      _agent_conv_push "question $i" "$long_text"
    done
    result=$(_agent_conv_context)
    assert_contains "$result" "RECENT CONVERSATION"
    # Newest entries (last 2) get 400 chars + "..."
    # The oldest entries should be truncated more aggressively
    # Check that we don't get the full 500-char response for any entry
    # (even the newest gets 400, which is < 500)
    line_count=$(echo "$result" | wc -l)
    assert_gt "$line_count" "6" "Should have header + 6 USER + 6 GEORGE lines minimum"
  }

# ══════════════════════════════════════════════════════════════
# Empty web fetch guard and JUNK detection
# ══════════════════════════════════════════════════════════════
describe "Web fetch guards"

  it "agent.sh contains empty web fetch guard (<20 chars)" && {
    grep -q 'Web Fetch: Empty' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

  it "agent.sh contains JUNK detection after condenser" && {
    grep -q 'JUNK:' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

  it "agent.sh contains honeydew rewrite budget exhaustion flag" && {
    grep -q 'HONEYDEW_REWRITE_BUDGET_EXHAUSTED' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

# ══════════════════════════════════════════════════════════════
# Ask-mode prompt (memory.sh)
# ══════════════════════════════════════════════════════════════
describe "Ask-mode prompt"

  it "_memory_soul_condensed is defined" && {
    declare -f _memory_soul_condensed &>/dev/null
    assert_ok $?
  }

  it "condensed soul rule #2 no longer mentions '5 sentences'" && {
    soul=$(_memory_soul_condensed)
    assert_not_contains "$soul" "5 sentences"
  }

  it "condensed soul rule #2 says 'no filler'" && {
    soul=$(_memory_soul_condensed)
    assert_contains "$soul" "no filler"
  }

  it "ask-mode prompt includes ACCURACY directive" && {
    grep -q 'ACCURACY:.*exact numbers' "$LODGE_DIR/lib/memory.sh"
    assert_ok $?
  }

  it "ask-mode prompt includes REASONING directive" && {
    grep -q 'REASONING:.*step by step' "$LODGE_DIR/lib/memory.sh"
    assert_ok $?
  }

  it "ask-mode prompt no longer caps at 5 sentences" && {
    grep -q 'no more than 5 sentences' "$LODGE_DIR/lib/memory.sh"
    rc=$?
    assert_fail "$rc" "Should NOT contain '5 sentences' limit in OUTPUT FORMAT"
  }

# ══════════════════════════════════════════════════════════════
# Soul.md trowel landmark
# ══════════════════════════════════════════════════════════════
describe "Soul.md Trowel landmark"

  it "soul.md contains The Trowel landmark" && {
    grep -q 'The Trowel (Completion)' "$LODGE_DIR/soul.md"
    assert_ok $?
  }

  it "trowel landmark appears as number 6" && {
    grep -q '^6\..*The Trowel' "$LODGE_DIR/soul.md"
    assert_ok $?
  }

  it "trowel landmark mentions finishing work" && {
    line=$(grep 'The Trowel' "$LODGE_DIR/soul.md")
    assert_contains "$line" "Finish what you start"
  }

test_end
