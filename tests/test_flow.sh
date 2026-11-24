#!/bin/bash
# ── Tests: lib/memory/flow.sh — Layer 2 Generated Layer (TTL-cached) ────
# Framework API: assert_eq actual expected [msg]; assert_ok/fail exit_code [msg];
# assert_contains haystack needle [msg]; assert_not_empty value [msg].
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/memory/scenes.sh"
source "$LODGE_DIR/lib/memory/flow.sh"

test_start "lib/memory/flow.sh — Layer 2 Generated Layer"

# Pre-check: sqlite3 + FTS5
_HAS_SQLITE=0
if command -v sqlite3 &>/dev/null; then
    _tdb="/tmp/.flow_fts5_check_$$.db"
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

_FLOW_TMP=$(mktemp -d /tmp/george-flow-test-XXXXXX)
cleanup() { rm -rf "$_FLOW_TMP" 2>/dev/null || true; }
trap cleanup EXIT

export GEORGE_DIR="$_FLOW_TMP/.george"
export RECALL_DB="$GEORGE_DIR/recall.db"
export LODGE_DIR
export FLOW_CACHE_DIR="$GEORGE_DIR/cache/flow"
export FLOW_EDGE_TTL=300
export FLOW_FRINGE_N=5
export FLOW_LINK_MAX=12
mkdir -p "$GEORGE_DIR"

# ── Arrange ────────────────────────────────────────────────────────────
scene_store_init
assert_ok $? "scene_store_init applies schema to fresh DB"

# Four scenes with distinct timestamps, tools, and tags.
sqlite3 "$RECALL_DB" <<SQL
INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES
 ('journal', 'FIFO design',  'We adopted the FIFO async IPC protocol with credit flow control', 'j.md', '2026-11-14T12:00:00Z'),
 ('journal', 'FIFO review',  'Review of the FIFO sliding-window credits and backpressure',      'j.md', '2026-11-14T13:00:00Z'),
 ('george',  'Weather',      'Local weather summary for Springfield',                              'G.md', '2026-11-10T08:00:00Z'),
 ('journal', 'Crypto desk',  'Shock fade sizing on NIGHT',                                      'j.md', '2026-11-13T22:00:00Z');
SQL
_s1=$(scene_ensure_for_chunk 1)
_s2=$(scene_ensure_for_chunk 2)
_s3=$(scene_ensure_for_chunk 3)
_s4=$(scene_ensure_for_chunk 4)
assert_not_empty "$_s1" "scene 1 materialized"
scene_tag_add "$_s1" "ipc" "topic"
scene_tag_add "$_s1" "fifo" "topic"
scene_tag_add "$_s2" "ipc" "topic"
scene_tag_add "$_s2" "credits" "topic"
scene_tag_add "$_s4" "crypto" "topic"

_FOCUS="FIFO async IPC protocol credits"

# ── 1. Edge id determinism ─────────────────────────────────────────────
_e1=$(flow_edge_id "$_s2" "$_s1" contiguity)
assert_not_empty "$_e1" "flow_edge_id returns an id"
assert_eq "$(printf '%s' "$_e1" | wc -c)" "40" "edge id is a 40-char sha1 hex string"
_e2=$(flow_edge_id "$_s1" "$_s2" contiguity)
assert_eq "$_e1" "$_e2" "edge id is order-insensitive (a,b) == (b,a)"
_e1b=$(flow_edge_id "$_s2" "$_s1" contiguity)
assert_eq "$_e1" "$_e1b" "edge id is deterministic across calls"
_e3=$(flow_edge_id "$_s1" "$_s2" similarity)
if [ "$_e1" = "$_e3" ]; then _same=0; else _same=1; fi
assert_eq "$_same" "1" "different assoc_type yields different edge id"

# 2. Edge id input validation
flow_edge_id abc "$_s1" contiguity 2>/dev/null
assert_fail $? "non-numeric scene id rejected"
flow_edge_id "$_s1" "$_s2" "" 2>/dev/null
assert_fail $? "empty assoc_type rejected"
flow_edge_id "$_s1" "$_s2" "DROP TABLE" 2>/dev/null
assert_fail $? "injection-style assoc_type rejected"

# ── 3. AssembledPresent shape ──────────────────────────────────────────
_p=$(flow_assemble_present "$_FOCUS")
assert_not_empty "$_p" "assemble returns a document"
if [ "$_HAS_JQ" = "1" ]; then
    printf '%s' "$_p" | jq -e . >/dev/null 2>&1
    assert_ok $? "AssembledPresent is valid JSON"
    assert_eq "$(printf '%s' "$_p" | jq -r '.focus')" "$_FOCUS" "focus round-trips"
    assert_eq "$(printf '%s' "$_p" | jq -e '.fringe | length > 0' >/dev/null 2>&1; echo $?)" "0" "fringe is non-empty"
    assert_eq "$(printf '%s' "$_p" | jq -e '.fringe | length <= 5' >/dev/null 2>&1; echo $?)" "0" "fringe respects default N=5"
    printf '%s' "$_p" | jq -e '.character_of_passage | length > 0' >/dev/null 2>&1
    assert_ok $? "character_of_passage is present and non-empty"
    printf '%s' "$_p" | jq -e '.generated_at and .ttl and (.scene_count >= 1)' >/dev/null 2>&1
    assert_ok $? "generated_at / ttl / scene_count fields present"
    # Top fringe member must be one of the FIFO scenes
    _top=$(printf '%s' "$_p" | jq -r '.fringe[0].scene_id')
    if [ "$_top" != "$_s1" ] && [ "$_top" != "$_s2" ]; then _ranked=0; else _ranked=1; fi
    assert_eq "$_ranked" "1" "FIFO scenes rank in fringe for FIFO focus"
    # Every fringe entry carries the assoc breakdown
    printf '%s' "$_p" | jq -e '[.fringe[] | has("scene_id") and has("score") and has("assoc")] | all' >/dev/null 2>&1
    assert_ok $? "fringe entries carry scene_id/score/assoc"
else
    assert_contains "$_p" '"focus"' "document has focus key (jq unavailable)"
    assert_contains "$_p" '"fringe":[' "document has fringe array"
    assert_contains "$_p" '"linkages":[' "document has linkages array"
    assert_contains "$_p" '"character_of_passage"' "document has character_of_passage"
fi

# ── 4. Determinism: bypass-cache re-derivation gives identical edges ───
_p2=$(FLOW_BYPASS_CACHE=1 flow_assemble_present "$_FOCUS")
if [ "$_HAS_JQ" = "1" ]; then
    _l1=$(printf '%s' "$_p" | jq -c '.linkages')
    _l2=$(printf '%s' "$_p2" | jq -c '.linkages')
    assert_eq "$_l1" "$_l2" "linkage edges are deterministic across assemblies"
    assert_contains "$_l1" "contiguity" "1h-gap FIFO pair linked by contiguity"
    _eids=$(printf '%s' "$_l1" | jq -r '.[].edge_id')  # _l1 is already the linkages array
    _ok_eid=$(flow_edge_id "$_s1" "$_s2" contiguity)
    assert_contains "$_eids" "$_ok_eid" "emitted edge id matches sha1(s1, s2, contiguity)"
fi

# ── 5. TTL cache lifecycle ─────────────────────────────────────────────
assert_eq "$(flow_cache_status "$_FOCUS")" "valid" "cache entry valid after assemble"
# Cache keying is canonical: case/spacing variants of the same focus must map
# to one cache path (proves read/write/status all funnel through the helper).
assert_eq "$(_flow_cache_path_for "  fifo   async  ipc protocol CREDITS ")" \
          "$(_flow_cache_path_for "$_FOCUS")" \
          "cache key is canonical (case/whitespace-insensitive)"

# A true cache hit cats the stored file. Prove it three ways: (a) the file
# exists at the helper path (so the mtime compare below is non-vacuous),
# (b) its mtime is unchanged (a hit reads, it does not re-derive), and
# (c) the re-derivable content is identical. Whole-document byte compare is a
# wall-clock race — generated_at AND character_of_passage embed assembly time
# by design — so we compare only the deterministic fringe + linkages, exactly
# the contract test_flow_budget.sh §12 checks.
_cfile="$(_flow_cache_path_for "$_FOCUS")"
[ -f "$_cfile" ]
assert_ok $? "cache file exists at _flow_cache_path_for (non-vacuous mtime check)"
_mt_before=$(stat -c %Y "$_cfile" 2>/dev/null || printf 0)
_p3=$(flow_assemble_present "$_FOCUS")
_mt_after=$(stat -c %Y "$_cfile" 2>/dev/null || printf 0)
assert_eq "$_mt_after" "$_mt_before" "cache hit serves the stored file (mtime unchanged)"
if [ "$_HAS_JQ" = "1" ]; then
    _c_now=$(printf '%s' "$_p3" | jq -c '{focus,fringe,linkages,scene_count}')
    _c_then=$(printf '%s' "$_p" | jq -c '{focus,fringe,linkages,scene_count}')
    assert_eq "$_c_now" "$_c_then" "cache hit returns identical derived content"
else
    assert_not_empty "$_p3" "cache hit returns non-empty document"
fi
export FLOW_EDGE_TTL=1
sleep 2
assert_eq "$(flow_cache_status "$_FOCUS")" "expired" "cache expires after TTL"
assert_eq "$(flow_cache_status "a never assembled focus")" "absent" "unknown focus has no cache entry"
flow_assemble_present "$_FOCUS" >/dev/null
assert_eq "$(flow_cache_status "$_FOCUS")" "valid" "re-assembly refreshes the cache"
export FLOW_EDGE_TTL=300

# ── 6. FLOW_FRINGE_N is tunable ────────────────────────────────────────
_FOCUS_WIDE="FIFO async IPC protocol credits weather crypto desk"
export FLOW_FRINGE_N=2
_p5=$(FLOW_BYPASS_CACHE=1 flow_assemble_present "$_FOCUS_WIDE")
if [ "$_HAS_JQ" = "1" ]; then
    assert_eq "$(printf '%s' "$_p5" | jq '.fringe | length')" "2" "fringe respects FLOW_FRINGE_N=2"
    export FLOW_FRINGE_N=5
    _p6=$(FLOW_BYPASS_CACHE=1 flow_assemble_present "$_FOCUS_WIDE")
    assert_eq "$(printf '%s' "$_p6" | jq '.fringe | length')" "4" "all 4 candidate scenes at FLOW_FRINGE_N=5"
else
    skip "fringe N assertions require jq"
fi
export FLOW_FRINGE_N=5

# ── 7. Zero-persistence invariant ──────────────────────────────────────
_extra_tables=$(sqlite3 "$RECALL_DB" \
    "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('linkages','flow','flow_edges','flow_links','scene_links');")
assert_eq "$_extra_tables" "" "no linkage/flow tables created in recall.db"
_scenes_after=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes;")
assert_eq "$_scenes_after" "4" "scene count unchanged after assemblies"
_chunks_after=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks;")
assert_eq "$_chunks_after" "4" "chunk count unchanged after assemblies"
_cached=$(ls "$FLOW_CACHE_DIR" 2>/dev/null | grep -c 'flow_')
[ "${_cached:-0}" -ge 1 ]
assert_ok $? "assembled presents cached as files, not rows"

# ── 8. flow_linkages row shape ─────────────────────────────────────────
_ll=$(flow_linkages "$_FOCUS")
assert_not_empty "$_ll" "flow_linkages emits edges"
_bad=$(printf '%s\n' "$_ll" | awk -F'\t' 'NF != 5 { c++ } END { print c + 0 }')
assert_eq "$_bad" "0" "all linkage rows have 5 tab-separated fields"

# ── 9. Cache GC honors sub-minute TTLs ─────────────────────────────────
export FLOW_EDGE_TTL=1
sleep 2
flow_cache_gc
assert_eq "$(flow_cache_status "$_FOCUS")" "absent" "gc purges the expired cache entry"
export FLOW_EDGE_TTL=300

# ── 10. Fallback assembly: unmatched focus still yields valid JSON ─────
_p7=$(FLOW_BYPASS_CACHE=1 flow_assemble_present "zzqqxx gibberish tokens unmatched")
if [ "$_HAS_JQ" = "1" ]; then
    printf '%s' "$_p7" | jq -e . >/dev/null 2>&1
    assert_ok $? "fallback assembly is valid JSON"
    assert_eq "$(printf '%s' "$_p7" | jq -e '.scene_count >= 1' >/dev/null 2>&1; echo $?)" "0" "fallback uses most-recent scenes"
else
    assert_not_empty "$_p7" "fallback assembly returns a document"
fi

test_end
