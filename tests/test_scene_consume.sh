#!/bin/bash
# ── Tests: scene_consume + scene_stamp_many — passive per-turn consumption ──
# Framework API: assert_eq actual expected [msg]; assert_ok/fail exit_code [msg];
# assert_contains haystack needle [msg]; assert_not_empty value [msg].
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/memory/scenes.sh"
source "$LODGE_DIR/lib/memory/flow.sh"

test_start "lib/memory — scene_consume & scene_stamp_many (passive consumption)"

# Pre-check: sqlite3 + FTS5 + jq
_HAS_SQLITE=0
if command -v sqlite3 &>/dev/null; then
    _tdb="/tmp/.scene_consume_fts5_check_$$.db"
    if sqlite3 "$_tdb" "CREATE VIRTUAL TABLE _t USING fts5(c); DROP TABLE _t;" 2>/dev/null; then
        _HAS_SQLITE=1
    fi
    rm -f "$_tdb"
fi
if [ "$_HAS_SQLITE" != "1" ]; then
    skip "sqlite3/FTS5 not available"
    test_end
    exit 0
fi

_HAS_JQ=0
command -v jq &>/dev/null && _HAS_JQ=1
if [ "$_HAS_JQ" != "1" ]; then
    skip "jq not available"
    test_end
    exit 0
fi

# The framework already sets up GEORGE_DIR in a sandbox. We also need RECALL_DB.
export RECALL_DB="$GEORGE_DIR/recall.db"
export FLOW_CACHE_DIR="$GEORGE_DIR/cache/flow"
export FLOW_EDGE_TTL=300
export FLOW_FRINGE_N=5
export FLOW_LINK_MAX=12

# ── Arrange ────────────────────────────────────────────────────────────────
scene_store_init
assert_ok $? "scene_store_init applies schema to fresh DB"

# Create test chunks with distinct content for FTS
sqlite3 "$RECALL_DB" <<'SQL'
INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES
 ('journal', '2026-11-14 10:00 — reflection', 'We implemented the FIFO async IPC protocol with sliding window credits and backpressure control for the agent loop', 'j.md', '2026-11-14T10:00:00Z'),
 ('journal', '2026-11-14 11:00 — reflection', 'The FIFO IPC protocol credit window was tuned to handle async dispatch with 12 pending tasks in the protocol queue', 'j.md', '2026-11-14T11:00:00Z'),
 ('george', 'Crypto desk', 'FIFO protocol backpressure on the async IPC channel caused credit exhaustion during the shock fade sizing session', 'G.md', '2026-11-13T22:00:00Z'),
 ('journal', '2026-11-13 09:00 — reflection', 'Git push to origin develop completed after fixing the FIFO protocol integration test in the async IPC module', 'j.md', '2026-11-13T09:00:00Z'),
 ('george', 'Scene system', 'The scene store uses lazy materialization with idempotent FIFO protocol chunk dispatch to the async IPC consumer', 'S.md', '2026-11-12T14:00:00Z');
SQL

_s1=$(scene_ensure_for_chunk 1)
_s2=$(scene_ensure_for_chunk 2)
_s3=$(scene_ensure_for_chunk 3)
_s4=$(scene_ensure_for_chunk 4)
_s5=$(scene_ensure_for_chunk 5)
assert_not_empty "$_s1" "scene 1 materialized"
assert_not_empty "$_s2" "scene 2 materialized"

# Add tags for tag-based retrieval
scene_tag_add "$_s1" "ipc" "topic"
scene_tag_add "$_s1" "fifo" "topic"
scene_tag_add "$_s1" "protocol" "topic"
scene_tag_add "$_s3" "crypto" "topic"
scene_tag_add "$_s3" "shock" "topic"
scene_tag_add "$_s5" "scene" "topic"
scene_tag_add "$_s5" "store" "topic"

# ══════════════════════════════════════════════════════════════════════════
# 1. scene_stamp (single)
# ══════════════════════════════════════════════════════════════════════════
describe "scene_stamp"

it "increments link_count for a valid scene" && {
    scene_stamp "$_s1"
    lc=$(sqlite3 "$RECALL_DB" "SELECT link_count FROM scenes WHERE scene_id = $_s1;")
    assert_eq "$lc" "1" "link_count is 1 after first stamp"
}

it "sets last_linked_ts" && {
    ts=$(sqlite3 "$RECALL_DB" "SELECT last_linked_ts FROM scenes WHERE scene_id = $_s1;")
    assert_not_empty "$ts" "last_linked_ts is set"
}

it "sets first_linked_ts only once" && {
    flts=$(sqlite3 "$RECALL_DB" "SELECT first_linked_ts FROM scenes WHERE scene_id = $_s1;")
    assert_not_empty "$flts" "first_linked_ts is set"
    scene_stamp "$_s1"
    flts2=$(sqlite3 "$RECALL_DB" "SELECT first_linked_ts FROM scenes WHERE scene_id = $_s1;")
    assert_eq "$flts" "$flts2" "first_linked_ts unchanged on second stamp"
    lc2=$(sqlite3 "$RECALL_DB" "SELECT link_count FROM scenes WHERE scene_id = $_s1;")
    assert_eq "$lc2" "2" "link_count is 2 after second stamp"
}

it "rejects non-numeric input" && {
    scene_stamp "abc" 2>/dev/null
    assert_fail $? "non-numeric scene_id rejected"
}

it "rejects empty input" && {
    scene_stamp "" 2>/dev/null
    assert_fail $? "empty scene_id rejected"
}

# ══════════════════════════════════════════════════════════════════════════
# 2. scene_stamp_many (batch)
# ══════════════════════════════════════════════════════════════════════════
describe "scene_stamp_many"

it "stamps multiple scenes in one call" && {
    n=$(scene_stamp_many "${_s2},${_s3},${_s4}")
    assert_eq "$n" "3" "3 scenes stamped"
}

it "all three have link_count=1" && {
    lc=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes WHERE scene_id IN (${_s2},${_s3},${_s4}) AND link_count = 1;")
    assert_eq "$lc" "3" "all 3 scenes have link_count=1"
}

it "rejects malformed input with injection characters" && {
    n=$(scene_stamp_many "1;DROP TABLE scenes;--")
    assert_eq "$n" "0" "injection attempt rejected"
}

it "rejects empty input" && {
    n=$(scene_stamp_many "")
    assert_eq "$n" "0" "empty input returns 0"
}

# ══════════════════════════════════════════════════════════════════════════
# 3. scene_consume (the full per-turn loop)
# ══════════════════════════════════════════════════════════════════════════
describe "scene_consume"

it "returns failure on empty focus" && {
    scene_consume "" 2>/dev/null
    assert_fail $? "empty focus returns 1"
}

it "produces a non-empty text block for a valid focus" && {
    out=$(FLOW_BYPASS_CACHE=1 scene_consume "fifo async ipc protocol" 3 2>/dev/null)
    assert_not_empty "$out" "scene_consume returns output"
}

it "output contains the header with focus" && {
    out=$(FLOW_BYPASS_CACHE=1 scene_consume "fifo async ipc protocol" 3 2>/dev/null)
    assert_contains "$out" "[Scene Flow" "output has Scene Flow header"
    assert_contains "$out" "fifo async ipc" "header includes focus text"
}

it "output contains numbered scene entries" && {
    out=$(FLOW_BYPASS_CACHE=1 scene_consume "fifo async ipc protocol" 3 2>/dev/null)
    assert_contains "$out" "1. [" "has first numbered entry"
    assert_contains "$out" "2. [" "has second numbered entry"
}

it "output contains the stamped footer" && {
    out=$(FLOW_BYPASS_CACHE=1 scene_consume "fifo async ipc protocol" 3 2>/dev/null)
    assert_contains "$out" "scene(s) stamped" "has stamped footer"
}

it "respects the N limit (max 3 with N=3)" && {
    out=$(FLOW_BYPASS_CACHE=1 scene_consume "fifo async ipc protocol" 3 2>/dev/null)
    count=$(echo "$out" | grep -c '^[0-9]\. \[')
    assert_eq "$count" "3" "exactly 3 scenes in output"
}

it "clamps N to max 8" && {
    out=$(FLOW_BYPASS_CACHE=1 scene_consume "fifo async ipc protocol" 99 2>/dev/null)
    count=$(echo "$out" | grep -c '^[0-9]\. \[')
    [ "$count" -le 8 ]
    assert_ok $? "N clamped to max 8 (got $count scenes)"
}

it "stamps scenes (increments link_count)" && {
    sqlite3 "$RECALL_DB" "UPDATE scenes SET link_count=0, last_linked_ts=NULL, first_linked_ts=NULL;"
    out=$(FLOW_BYPASS_CACHE=1 scene_consume "fifo async ipc protocol" 2 2>/dev/null)
    stamped=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes WHERE link_count > 0;")
    [ "$stamped" -ge 1 ]
    assert_ok $? "at least 1 scene stamped after consume (got $stamped)"
}

it "includes tier in output" && {
    out=$(FLOW_BYPASS_CACHE=1 scene_consume "fifo async ipc protocol" 2 2>/dev/null)
    assert_contains "$out" "vivid" "contains vivid tier label"
}

it "includes timestamp in output" && {
    out=$(FLOW_BYPASS_CACHE=1 scene_consume "fifo async ipc protocol" 2 2>/dev/null)
    has_date=$(echo "$out" | grep -cE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    [ "$has_date" -ge 1 ]
    assert_ok $? "output includes at least one date"
}

describe "scene_consume — focus differentiation"

it "different focus yields valid output for both" && {
    out_ipc=$(FLOW_BYPASS_CACHE=1 scene_consume "fifo async ipc protocol credits" 1 2>/dev/null)
    out_weather=$(FLOW_BYPASS_CACHE=1 scene_consume "weather appleton wisconsin overcast" 1 2>/dev/null)
    assert_not_empty "$out_ipc" "ipc focus returns output"
    assert_not_empty "$out_weather" "weather focus returns output"
}

describe "scene_consume — content snippet"

it "includes content from the scene" && {
    out=$(FLOW_BYPASS_CACHE=1 scene_consume "fifo async ipc protocol" 1 2>/dev/null)
    has_content=$(echo "$out" | grep -ci "FIFO\|async\|IPC\|protocol\|sliding\|credit")
    [ "$has_content" -ge 1 ]
    assert_ok $? "output includes relevant content text (matches: $has_content)"
}

# ══════════════════════════════════════════════════════════════════════════
# 4. Integration with tier decay (link-activity awareness)
# ══════════════════════════════════════════════════════════════════════════
describe "tier decay link-awareness"

it "recently-stamped scenes resist fading demotion" && {
    old_sid=$(sqlite3 "$RECALL_DB" "SELECT scene_id FROM scenes LIMIT 1;")
    [ -n "$old_sid" ] || { skip "no scenes in DB"; return 0 2>/dev/null; }
    sqlite3 "$RECALL_DB" "UPDATE scenes SET ts='2026-10-01T00:00:00Z' WHERE scene_id = $old_sid;"
    scene_stamp "$old_sid"
    result=$(SCENE_DECAY_FADING_DAYS=14 scene_tier_decay 2>/dev/null)
    tier=$(sqlite3 "$RECALL_DB" "SELECT tier FROM scenes WHERE scene_id = $old_sid;")
    assert_eq "$tier" "vivid" "recently-stamped old scene stays vivid (got: $tier)"
}

# ── Done ───────────────────────────────────────────────────────────────────
test_end
