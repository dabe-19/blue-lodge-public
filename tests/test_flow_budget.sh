#!/bin/bash
# ── Tests: lib/memory/flow.sh — Step 5 token budget + N tunability ──────
# Verifies: FLOW_PRESENT_TOKEN_BUDGET fit loop (weakest-fringe-first trim),
# tunable FLOW_FRINGE_N / budget via environment, unconditional coercion of
# invalid values at every entry point, budget metadata field, and the
# never-empty invariant.
# Framework API: assert_eq actual expected [msg]; assert_ok/fail exit_code [msg];
# assert_contains haystack needle [msg]; assert_not_empty value [msg].
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/memory/scenes.sh"
source "$LODGE_DIR/lib/memory/flow.sh"

test_start "lib/memory/flow.sh — Step 5 budget + N tunability"

# Pre-checks
_HAS_SQLITE=0
if command -v sqlite3 &>/dev/null; then
    _tdb="/tmp/.flow_budget_fts5_$$.db"
    if sqlite3 "$_tdb" "CREATE VIRTUAL TABLE _t USING fts5(c); DROP TABLE _t;" 2>/dev/null; then
        _HAS_SQLITE=1
    fi
    rm -f "$_tdb"
fi
_HAS_PY=0
command -v python3 &>/dev/null && _HAS_PY=1
if [ "$_HAS_SQLITE" != "1" ] || [ "$_HAS_PY" != "1" ]; then
    skip "sqlite3/FTS5 + python3 not available"
    test_end
    exit 0
fi

_FLOW_TMP=$(mktemp -d /tmp/george-flow-budget-XXXXXX)
cleanup() { rm -rf "$_FLOW_TMP" 2>/dev/null || true; }
trap cleanup EXIT

export GEORGE_DIR="$_FLOW_TMP/.george"
export RECALL_DB="$GEORGE_DIR/recall.db"
export LODGE_DIR
export FLOW_CACHE_DIR="$GEORGE_DIR/cache/flow"
export FLOW_EDGE_TTL=300
mkdir -p "$GEORGE_DIR"

# JSON field extractor: flow_json <json> <python-expression on d>
flow_json() {
    printf '%s' "$1" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print($2)
" 2>/dev/null
}

# ── Arrange: 6 scenes, 5 tagged to a shared focus ───────────────────────
scene_store_init
assert_ok $? "scene_store_init applies schema to fresh DB"

sqlite3 "$RECALL_DB" <<SQL
INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES
 ('journal','FIFO design A','We adopted the FIFO async IPC protocol with credit flow control','j.md','2026-11-14T12:00:00Z'),
 ('journal','FIFO design B','Review of the FIFO sliding-window credits and backpressure','j.md','2026-11-14T12:30:00Z'),
 ('journal','FIFO design C','FIFO atomicity guarantees under credit exhaustion','j.md','2026-11-14T13:00:00Z'),
 ('journal','FIFO design D','FIFO priority tiers for auto-running memory tasks','j.md','2026-11-14T13:30:00Z'),
 ('journal','FIFO design E','FIFO backpressure behavior in the memory flow engine','j.md','2026-11-14T14:00:00Z'),
 ('journal','Weather',    'Local weather summary for Springfield','G.md','2026-11-10T08:00:00Z');
SQL
_scenes=()
for i in 1 2 3 4 5 6; do
    _sid=$(scene_ensure_for_chunk $i)
    assert_not_empty "$_sid" "scene $i materialized"
    _scenes+=("$_sid")
done
for _sid in "${_scenes[0]}" "${_scenes[1]}" "${_scenes[2]}" "${_scenes[3]}" "${_scenes[4]}"; do
    scene_tag_add "$_sid" "fifo" "topic"
done

_FOCUS="FIFO async IPC protocol credits budget"

# ── 1. flow_config: defaults ────────────────────────────────────────────
_cfg=$(flow_config)
assert_contains "$_cfg" '"token_budget":600' "default token budget is 600"
assert_contains "$_cfg" '"fringe_n":5' "default N is 5"
assert_contains "$_cfg" '"link_max":12' "default link max is 12"

# ── 2. flow_config: valid overrides honored ─────────────────────────────
_cfg=$(FLOW_PRESENT_TOKEN_BUDGET=300 FLOW_FRINGE_N=3 flow_config)
assert_contains "$_cfg" '"token_budget":300' "budget override 300 honored"
assert_contains "$_cfg" '"fringe_n":3' "N override 3 honored"
_cfg=$(FLOW_PRESENT_TOKEN_BUDGET=350 flow_config)
assert_contains "$_cfg" '"token_budget":350' "budget 350 (band floor) honored"

# ── 3. Invalid values coerced at entry point (not just source time) ─────
_cfg=$(FLOW_PRESENT_TOKEN_BUDGET=abc flow_config)
assert_contains "$_cfg" '"token_budget":600' "non-numeric budget coerced to 600"
_cfg=$(FLOW_PRESENT_TOKEN_BUDGET=0 flow_config)
assert_contains "$_cfg" '"token_budget":600' "zero budget coerced to 600"
_cfg=$(FLOW_FRINGE_N=-1 flow_config)
assert_contains "$_cfg" '"fringe_n":5' "negative N coerced to 5"
_cfg=$(FLOW_FRINGE_N= flow_config)
assert_contains "$_cfg" '"fringe_n":5' "empty N coerced to 5"

# ── 4. End-to-end: default budget (600) — all 5 focus scenes fit ────────
_p600=$(FLOW_BYPASS_CACHE=1 flow_assemble_present "$_FOCUS")
assert_not_empty "$_p600" "present assembled at default budget"
assert_eq "$(flow_json "$_p600" 'd["budget"]["token_budget"]')" "600" "budget field reports 600"
assert_eq "$(flow_json "$_p600" 'str(d["budget"]["within_budget"]).lower()')" "true" "present within budget"
assert_eq "$(flow_json "$_p600" 'd["budget"]["fringe_dropped"]')" "0" "nothing dropped at 600"
assert_eq "$(flow_json "$_p600" 'len(d["fringe"])')" "5" "all 5 focus scenes in fringe at 600"

# ── 5. End-to-end: budget 300 — weakest scenes dropped first ───────────
_p300=$(FLOW_PRESENT_TOKEN_BUDGET=300 FLOW_BYPASS_CACHE=1 flow_assemble_present "$_FOCUS")
assert_not_empty "$_p300" "present assembled at 300"
assert_eq "$(flow_json "$_p300" 'str(d["budget"]["within_budget"]).lower()')" "true" "within_budget true at 300"
_n300=$(flow_json "$_p300" 'len(d["fringe"])')
_d300=$(flow_json "$_p300" 'd["budget"]["fringe_dropped"]')
[ -n "$_n300" ] && [ "$_n300" -lt 5 ] && _lt300=1 || _lt300=0
assert_eq "$_lt300" "1" "fringe trimmed under 5 scenes at 300 got $_n300"
[ -n "$_d300" ] && [ "$_d300" -gt 0 ] && _d300ok=1 || _d300ok=0
assert_eq "$_d300ok" "1" "fringe_dropped nonzero at 300 got $_d300"
# Consistency: kept + dropped == full candidate set
_kept=$(( _n300 + _d300 ))
[ "$_kept" -eq 5 ] && _cons=1 || _cons=0
assert_eq "$_cons" "1" "kept plus dropped equals 5, got $_kept"

# ── 6. Drop order is rank order (strongest survivors) ───────────────────
_first300=$(flow_json "$_p300" 'd["fringe"][0]["scene_id"]')
_first600=$(flow_json "$_p600" 'd["fringe"][0]["scene_id"]')
assert_eq "$_first300" "$_first600" "top-ranked scene survives the trim (rank-order drop)"

# ── 7. Monotonicity: tighter budget never keeps more scenes ─────────────
_p150=$(FLOW_PRESENT_TOKEN_BUDGET=150 FLOW_BYPASS_CACHE=1 flow_assemble_present "$_FOCUS")
_n150=$(flow_json "$_p150" 'len(d["fringe"])')
[ -n "$_n150" ] && [ -n "$_n300" ] && [ "$_n150" -le "$_n300" ] && _mono=1 || _mono=0
assert_eq "$_mono" "1" "monotonic trim: 150 keeps <= 300 (got $_n150 vs $_n300)"
assert_not_empty "$(flow_json "$_p150" 'd["fringe"][0]["scene_id"]')" "present never empty while scenes exist (150)"

# ── 8. Budget field self-consistency ────────────────────────────────────
# When within_budget=true, estimate must be <= budget. When a pathological
# budget can't even hold one scene, within_budget=false must be HONESTLY
# flagged (never hidden) while the present stays non-empty.
for _p in "$_p600" "$_p300" "$_p150"; do
    _est=$(flow_json "$_p" 'd["budget"]["estimated_tokens"]')
    _bud=$(flow_json "$_p" 'd["budget"]["token_budget"]')
    _wi=$(flow_json "$_p" 'str(d["budget"]["within_budget"]).lower()')
    _ok=1
    if [ "$_wi" = "true" ]; then
        [ -n "$_est" ] && [ -n "$_bud" ] && [ "$_est" -le "$_bud" ] || _ok=0
    else
        [ -n "$_est" ] && [ -n "$_bud" ] && [ "$_est" -gt "$_bud" ] || _ok=0
    fi
    assert_eq "$_ok" "1" "budget field self-consistent: est=$_est bud=$_bud within=$_wi"
done

# ── 9. N tunability caps the fringe independently of budget ────────────
_pn3=$(FLOW_FRINGE_N=3 FLOW_BYPASS_CACHE=1 flow_assemble_present "$_FOCUS")
assert_eq "$(flow_json "$_pn3" 'len(d["fringe"])')" "3" "FLOW_FRINGE_N=3 caps fringe at 3"
_pn2=$(FLOW_FRINGE_N=2 FLOW_BYPASS_CACHE=1 flow_assemble_present "$_FOCUS")
assert_eq "$(flow_json "$_pn2" 'len(d["fringe"])')" "2" "FLOW_FRINGE_N=2 caps fringe at 2"

# ── 10. Combined: N=3 AND budget 300 both enforced ──────────────────────
_pc=$(FLOW_FRINGE_N=3 FLOW_PRESENT_TOKEN_BUDGET=300 FLOW_BYPASS_CACHE=1 flow_assemble_present "$_FOCUS")
_nc=$(flow_json "$_pc" 'len(d["fringe"])')
[ -n "$_nc" ] && [ "$_nc" -le 3 ] && _cok=1 || _cok=0
assert_eq "$_cok" "1" "N=3 cap holds at budget 300, got $_nc"
assert_eq "$(flow_json "$_pc" 'str(d["budget"]["within_budget"]).lower()')" "true" "combined config within budget"

# ── 11. Linkages respect FLOW_LINK_MAX and edge schema ──────────────────
_nl=$(flow_json "$_p600" 'len(d["linkages"])')
[ -n "$_nl" ] && [ "$_nl" -le 12 ] && _llimit=1 || _llimit=0
assert_eq "$_llimit" "1" "linkage count <= FLOW_LINK_MAX, got $_nl"
assert_eq "$(flow_json "$_p600" 'all(set(l) == {"edge_id","a","b","type","strength"} for l in d["linkages"])')" "True" "linkage objects carry the full 5-field schema"

# ── 12. Determinism: identical config yields identical derived content ──
# (generated_at / character_of_passage embed wall-clock time by design;
#  the derived fringe + linkages must be byte-identical)
_p600b=$(FLOW_BYPASS_CACHE=1 flow_assemble_present "$_FOCUS")
_d1=$(flow_json "$_p600" 'json.dumps({"fringe": d["fringe"], "linkages": d["linkages"]}, sort_keys=True)')
_d2=$(flow_json "$_p600b" 'json.dumps({"fringe": d["fringe"], "linkages": d["linkages"]}, sort_keys=True)')
assert_eq "$_d1" "$_d2" "fringe+linkages are deterministic for identical config"

# ── 13. Cached read path preserves the budget field ─────────────────────
_pcache=$(flow_assemble_present "$_FOCUS")
assert_contains "$_pcache" '"token_budget"' "cached present retains budget metadata"

# ── 14. Top-level present shape unchanged (backward compatible) ─────────
assert_eq "$(flow_json "$_p600" 'sorted(d.keys()) == sorted(["focus","fringe","linkages","character_of_passage","generated_at","ttl","scene_count","budget"])')" "True" "present JSON has the expected 8 top-level keys"

test_end
exit 0
