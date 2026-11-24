#!/bin/bash
# ── lib/memory/flow.sh — Layer 2 Generated Layer (ephemeral, TTL-cached) ──
# The "flow = linkage" engine of the memory-flow architecture.
#
# Governance invariants:
#   * Flow is NEVER persisted. Linkage edges are derived per turn from Layer 1
#     scenes and cached only in TTL'd files under $FLOW_CACHE_DIR (default
#     $GEORGE_DIR/cache/flow). No new SQLite tables are ever created.
#   * Edge ids are deterministic: sha1(min(a,b) TAB max(a,b) TAB assoc_type).
#     The same pair+type always re-derives the same id — the reason there is
#     no need to store edges.
#   * The AssembledPresent (per-turn specious present) is a JSON document:
#       { focus, fringe[], linkages[], character_of_passage, generated_at,
#         ttl, scene_count }
#
# Association heuristics (James: similarity, contiguity, repetition, recency;
# plus an embedding proxy when scene_emb rows exist):
#   * fts       — 1.0 when the scene matches the focus in scenes_fts (BM25)
#   * tags      — |focus tokens ∩ scene tags| / |focus tokens|
#   * recency   — 1 / (1 + hours_since_ts)
#   * embedding — bag-of-tokens cosine proxy, 0.0 until embeddings exist
#   * scene score = 0.45*fts + 0.25*tags + 0.15*recency + 0.15*embedding
#   Pairwise edges along the ranked fringe chain (first match wins):
#   * contiguity — ts gap <= 24h, strength 1/(1+gap_h)
#   * similarity — >= 1 shared tag, strength 0.4
#   * repetition — same provenance_tool, strength 0.6
#
# Tunables (environment, validated to integers at source time):
#   FLOW_EDGE_TTL  seconds a cached present remains valid   (300)
#   FLOW_FRINGE_N  max fringe scenes in a present           (5)
#   FLOW_LINK_MAX  max linkage edges emitted                (12)
#   FLOW_PRESENT_TOKEN_BUDGET token budget for the serialized
#       present (600; the acceptable deployment band is 300-600, any
#       positive integer is honored)
#   FLOW_CACHE_DIR cache directory                          ($GEORGE_DIR/cache/flow)
#   FLOW_BYPASS_CACHE=1 forces fresh derivation (cache still refreshed)
#
# Budget invariant: the AssembledPresent is fitted to FLOW_PRESENT_TOKEN_BUDGET
# (deterministic estimate ceil(chars/4)) by dropping the weakest fringe scenes
# first (rank order), then trailing linkage edges. A present is never emitted
# empty while scenes exist; the JSON carries a "budget" object reporting the
# outcome (token_budget, estimated_tokens, within_budget, fringe_dropped).
#
# Requires: sqlite3+FTS5, sha1sum, GNU date. Sources cleanly after
# lib/memory/scenes.sh (reused for DB path resolution; standalone-safe).

# ── Tunables ────────────────────────────────────────────────────────────
FLOW_EDGE_TTL="${FLOW_EDGE_TTL:-300}"
FLOW_FRINGE_N="${FLOW_FRINGE_N:-5}"
FLOW_LINK_MAX="${FLOW_LINK_MAX:-12}"
FLOW_PRESENT_TOKEN_BUDGET="${FLOW_PRESENT_TOKEN_BUDGET:-600}"
case "$FLOW_EDGE_TTL" in ''|*[!0-9]*) FLOW_EDGE_TTL=300 ;; esac
case "$FLOW_FRINGE_N" in ''|*[!0-9]*) FLOW_FRINGE_N=5 ;; esac
case "$FLOW_LINK_MAX" in ''|*[!0-9]*) FLOW_LINK_MAX=12 ;; esac
case "$FLOW_PRESENT_TOKEN_BUDGET" in ''|*[!0-9]*) FLOW_PRESENT_TOKEN_BUDGET=600 ;; esac
[ "$FLOW_PRESENT_TOKEN_BUDGET" -gt 0 ] 2>/dev/null || FLOW_PRESENT_TOKEN_BUDGET=600

# Re-coerce all tunables to valid positive integers. Called at the start of
# every public entry point so late environment overrides (per-command or
# mid-session) can never smuggle a non-integer or non-positive value into the
# linkage engine — the budget and N constraints are honored unconditionally.
_flow_validate_limits() {
    case "$FLOW_EDGE_TTL" in ''|*[!0-9]*) FLOW_EDGE_TTL=300 ;; esac
    case "$FLOW_FRINGE_N" in ''|*[!0-9]*) FLOW_FRINGE_N=5 ;; esac
    [ "$FLOW_FRINGE_N" -gt 0 ] 2>/dev/null || FLOW_FRINGE_N=5
    case "$FLOW_LINK_MAX" in ''|*[!0-9]*) FLOW_LINK_MAX=12 ;; esac
    [ "$FLOW_LINK_MAX" -gt 0 ] 2>/dev/null || FLOW_LINK_MAX=12
    case "$FLOW_PRESENT_TOKEN_BUDGET" in ''|*[!0-9]*) FLOW_PRESENT_TOKEN_BUDGET=600 ;; esac
    [ "$FLOW_PRESENT_TOKEN_BUDGET" -gt 0 ] 2>/dev/null || FLOW_PRESENT_TOKEN_BUDGET=600
    return 0
}

# ── Path resolution ─────────────────────────────────────────────────────
_flow_repo_root() {
    printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
}

_flow_db() {
    if [ -n "${RECALL_DB:-}" ]; then
        printf '%s' "$RECALL_DB"
        return 0
    fi
    if declare -F scenes_db_path >/dev/null 2>&1; then
        scenes_db_path
        return 0
    fi
    printf '%s' "${GEORGE_DIR:-$(_flow_repo_root)/.george}/recall.db"
}

_flow_cache_root() {
    printf '%s' "${FLOW_CACHE_DIR:-${GEORGE_DIR:-$(_flow_repo_root)/.george}/cache/flow}"
}

# ── Primitives ──────────────────────────────────────────────────────────
# Deterministic, order-insensitive linkage edge id.
flow_edge_id() {
    local _a="$1" _b="$2" _t="$3"
    case "$_a" in ''|*[!0-9]*) return 1 ;; esac
    case "$_b" in ''|*[!0-9]*) return 1 ;; esac
    case "$_t" in ''|*[!a-z_]*) return 1 ;; esac
    if [ "$_a" -gt "$_b" ]; then
        local _sw="$_a"; _a="$_b"; _b="$_sw"
    fi
    printf '%s\t%s\t%s' "$_a" "$_b" "$_t" | sha1sum | cut -d' ' -f1
    return 0
}

# JSON-escape a bash string (backslash, double quote, newline, tab, CR).
_flow_json_escape() {
    local _v="$1"
    _v="${_v//\\/\\\\}"
    _v="${_v//\"/\\\"}"
    _v="${_v//$'\n'/\\n}"
    _v="${_v//$'\t'/\\t}"
    _v="${_v//$'\r'/\\r}"
    printf '%s' "$_v"
}

# Lowercase alphanumeric tokens >= 3 chars, unique, top 10, space-joined.
_flow_focus_tokens() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | \
        grep -E '^[a-z0-9]{3,}$' | awk '!seen[$0]++' | head -10 | tr '\n' ' '
}

# ISO ts -> epoch seconds (0 on unparseable — ages the scene, never crashes).
_flow_ts_epoch() {
    date -u -d "$1" +%s 2>/dev/null || printf '0'
}

# Canonicalize a focus string for cache keying: lowercase, collapse runs of
# whitespace to a single space, trim ends. Deterministic for a given phrase so
# case/spacing variants of the same focus share one cache entry, and so the
# read path, write path, and flow_cache_status all key on one canonical form.
_flow_focus_canonical() {
    local _v
    _v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')
    _v="${_v# }"
    _v="${_v% }"
    printf '%s' "$_v"
}

# Cache file for a focus string, keyed on sha1(canonical focus). Canonical
# (lowercase, whitespace-collapsed) so equivalent phrasings map to a single
# entry; every cache consumer funnels through this one helper.
_flow_cache_path_for() {
    local _key
    _key=$(printf '%s' "$(_flow_focus_canonical "$1")" | sha1sum | cut -d' ' -f1)
    printf '%s/flow_%s.json' "$(_flow_cache_root)" "$_key"
}

_flow_cache_valid() {
    local _path="$1" _now _mtime _age
    [ -f "$_path" ] || return 1
    _now=$(date +%s)
    _mtime=$(stat -c %Y "$_path" 2>/dev/null) || return 1
    _age=$((_now - _mtime))
    [ "$_age" -ge 0 ] && [ "$_age" -le "$FLOW_EDGE_TTL" ]
}

# Print cache state for a focus: absent | valid | expired
flow_cache_status() {
    local _path
    _path="$(_flow_cache_path_for "$1")"
    if [ ! -f "$_path" ]; then
        printf 'absent'
    elif _flow_cache_valid "$_path"; then
        printf 'valid'
    else
        printf 'expired'
    fi
    return 0
}

# Bag-of-tokens cosine proxy between focus tokens and scene CONTENT. It reads
# scenes.content directly and never touches the scene_emb table. Returns
# 0.0000 when _avail is not "1", python3 is missing, the scene has no content,
# or anything else fails.
_flow_emb_score() {
    local _sid="$1" _db="$2" _tokens="$3" _avail="$4"
    [ "$_avail" = "1" ] || { printf '0.0000'; return 0; }
    [ -n "$_tokens" ] || { printf '0.0000'; return 0; }
    command -v python3 >/dev/null 2>&1 || { printf '0.0000'; return 0; }
    local _out
    _out=$(FLOW_EMB_DB="$_db" FLOW_EMB_SID="$_sid" FLOW_EMB_TOKENS="$_tokens" python3 - <<'PYEOF'
import math, os, re, sqlite3

db = os.environ.get("FLOW_EMB_DB", "")
sid = os.environ.get("FLOW_EMB_SID", "")
focus = os.environ.get("FLOW_EMB_TOKENS", "").split()
if not db or not sid or not focus:
    print("0.0000")
    raise SystemExit(0)
try:
    conn = sqlite3.connect(db)
    row = conn.execute("SELECT content FROM scenes WHERE scene_id = ?", (sid,)).fetchone()
    if not row or not row[0]:
        print("0.0000")
        raise SystemExit(0)
    words = [w for w in re.findall(r"[a-z0-9]{3,}", row[0].lower())]
    fw = set(focus)
    sw = set(words)
    inter = len(fw & sw)
    denom = math.sqrt(len(fw) * len(sw)) if (fw and sw) else 0.0
    print("%.4f" % (inter / denom if denom else 0.0))
except Exception:
    print("0.0000")
PYEOF
    )
    case "$_out" in
        ''|*[!0-9.]*) printf '0.0000' ;;
        *) printf '%s' "$_out" ;;
    esac
    return 0
}

# ── Pure builders (no I/O; reused by the budget-fit loop) ───────────────
# Pairwise linkage edges along a ranked fringe chain (first match wins).
# Args: <fringe_rows> <db> where fringe rows are tab:
#   sid score fts tags rec emb ts tool tier sal tags_csv
# Prints tab rows: edge_id a b type strength (blank-filtered, capped at FLOW_LINK_MAX).
_flow_build_links() {
    local _fr="$1" _db="$2"
    local _links="" _prev_sid="" _prev_ts="" _prev_tool=""
    local _pa _pb _gap_s _gap_h _shared_n _type _strength _eid
    local _sid_a _score_a _fts_a _tagf_a _rec_a _emb_a _ts_a _tool_a _tier_a _sal_a _tags_a
    while IFS=$'\t' read -r _sid_a _score_a _fts_a _tagf_a _rec_a _emb_a _ts_a _tool_a _tier_a _sal_a _tags_a; do
        [ -n "$_sid_a" ] || continue
        if [ -n "$_prev_sid" ] && [ "$_prev_sid" != "$_sid_a" ]; then
            _pa=$(_flow_ts_epoch "$_prev_ts")
            _pb=$(_flow_ts_epoch "$_ts_a")
            _gap_s=$((_pa - _pb))
            [ "$_gap_s" -lt 0 ] && _gap_s=$((_gap_s * -1))
            _gap_h=$(awk -v g="$_gap_s" 'BEGIN { printf "%.4f", g / 3600.0 }')
            _type=""; _strength=""
            if awk -v g="$_gap_h" 'BEGIN { exit !(g <= 24.0) }'; then
                _type="contiguity"
                _strength=$(awk -v g="$_gap_h" 'BEGIN { printf "%.4f", 1.0 / (1.0 + g) }')
            else
                _shared_n=$(sqlite3 "$_db" "
SELECT COUNT(*) FROM (SELECT 1 FROM scene_tags ta
JOIN scene_tags tb ON ta.tag = tb.tag AND tb.scene_id = $_sid_a
WHERE ta.scene_id = $_prev_sid);" 2>/dev/null)
                if [ "${_shared_n:-0}" -gt 0 ] 2>/dev/null; then
                    _type="similarity"; _strength=0.4
                elif [ -n "$_prev_tool" ] && [ "$_prev_tool" = "$_tool_a" ]; then
                    _type="repetition"; _strength=0.6
                fi
            fi
            if [ -n "$_type" ]; then
                _eid=$(flow_edge_id "$_prev_sid" "$_sid_a" "$_type")
                _links="${_links}${_eid}"$'\t'"${_prev_sid}"$'\t'"${_sid_a}"$'\t'"${_type}"$'\t'"${_strength}"$'\n'
            fi
        fi
        _prev_sid="$_sid_a"; _prev_ts="$_ts_a"; _prev_tool="$_tool_a"
    done <<< "$_fr"
    printf '%s' "$_links" | grep -v '^[[:space:]]*$' | head -n "$FLOW_LINK_MAX"
    return 0
}

# Deterministic token estimate: ceil(chars / 4) — the standard
# ~4-chars-per-token heuristic. Pure shell, no I/O.
_flow_token_estimate() {
    local _len=${#1}
    printf '%d' $(( (_len + 3) / 4 ))
}

# Build the AssembledPresent JSON from raw fringe/link rows (no I/O).
# Args: <fringe_rows> <link_rows> <n> <top_type> <top_edge> <now_iso> <focus>
_flow_serialize_present() {
    local _fr="$1" _ln="$2" _n="$3" _top_type="${4:-}" _top_edge="${5:-}" _now_iso="$6" _focus="$7"
    local _fringe="" _entry _sid_a _score_a _fts_a _tagf_a _rec_a _emb_a
    local _ts_a _tool_a _tier_a _sal_a _tags_a _t _tag_json
    while IFS=$'\t' read -r _sid_a _score_a _fts_a _tagf_a _rec_a _emb_a _ts_a _tool_a _tier_a _sal_a _tags_a; do
        [ -n "$_sid_a" ] || continue
        [ -n "${_tier_a:-}" ] || _tier_a="vivid"
        _tag_json=""
        for _t in ${_tags_a//,/ }; do
            [ -n "$_t" ] || continue
            if [ -n "$_tag_json" ]; then _tag_json="${_tag_json},"; fi
            _tag_json="${_tag_json}\"$(_flow_json_escape "$_t")\""
        done
        _entry="{\"scene_id\":${_sid_a},\"tier\":\"$(_flow_json_escape "$_tier_a")\",\"ts\":\"$(_flow_json_escape "$_ts_a")\",\"tool\":\"$(_flow_json_escape "${_tool_a:-}")\",\"salience\":${_sal_a:-0.5},\"score\":${_score_a:-0},\"assoc\":{\"fts\":${_fts_a:-0},\"tags\":${_tagf_a:-0},\"recency\":${_rec_a:-0},\"embedding\":${_emb_a:-0}},\"tags\":[${_tag_json}]}"
        if [ -n "$_fringe" ]; then _fringe="${_fringe},"; fi
        _fringe="${_fringe}${_entry}"
    done <<< "$_fr"

    local _links="" _eid _a _b _type _strength
    while IFS=$'\t' read -r _eid _a _b _type _strength; do
        [ -n "$_eid" ] || continue
        if [ -n "$_links" ]; then _links="${_links},"; fi
        _links="${_links}{\"edge_id\":\"${_eid}\",\"a\":${_a},\"b\":${_b},\"type\":\"${_type}\",\"strength\":${_strength}}"
    done <<< "$_ln"

    local _cop
    _cop="Assembled ${_now_iso} for focus '$(_flow_json_escape "$_focus")'. ${_n:-0} scene(s) in fringe; dominant association ${_top_type:-none}; leading linkage ${_top_edge:-none}. Passage character: recency-weighted and focus-selective; contradictions recede to the fringe rather than being erased."

    printf '{"focus":"%s","fringe":[%s],"linkages":[%s],"character_of_passage":"%s","generated_at":"%s","ttl":%s,"scene_count":%s}' \
        "$(_flow_json_escape "$_focus")" "$_fringe" "$_links" "$_cop" "$_now_iso" "$FLOW_EDGE_TTL" "${_n:-0}"
    return 0
}

# ── Derivation core ─────────────────────────────────────────────────────
# Internal: rank candidates for a focus and derive the fringe chain plus
# pairwise linkage edges. Sets globals:
#   _FLOW_FRINGE  tab rows: sid score fts tags rec emb ts tool tier sal tags_csv
#   _FLOW_LINKS   tab rows: edge_id a b type strength
#   _FLOW_N       fringe scene count
#   _FLOW_TOP_TYPE / _FLOW_TOP_EDGE  first (strongest-ordered) linkage
_flow_derive() {
    local _focus="$1"
    _FLOW_FRINGE=""; _FLOW_LINKS=""; _FLOW_N=0
    _FLOW_TOP_TYPE="none"; _FLOW_TOP_EDGE="none"
    local _db; _db="$(_flow_db)"
    [ -f "$_db" ] || return 1
    local _now _tokens
    _now=$(date +%s)
    _tokens="$(_flow_focus_tokens "$_focus")"

    # Candidate set: FTS hits (BM25-ordered) union tag hits; fallback is the
    # 10 most recent scenes so an empty focus still assembles something.
    local _fts_list="" _tag_list="" _q _in_list
    if [ -n "$_tokens" ]; then
        _q=$(printf '%s' "$_tokens" | awk '{ for (i = 1; i <= NF; i++) printf "%s\"%s\"", (i > 1 ? " OR " : ""), $i }')
        if [ -n "$_q" ]; then
            _fts_list=$(sqlite3 "$_db" "
SELECT s.scene_id
FROM scenes_fts
JOIN scenes s ON s.scene_id = scenes_fts.rowid
WHERE scenes_fts MATCH '$_q'
ORDER BY bm25(scenes_fts, 1.0, 0.1)
LIMIT 20;" 2>/dev/null)
        fi
        _in_list=$(printf '%s' "$_tokens" | tr ' ' '\n' | grep -v '^$' | \
            awk 'BEGIN { q = sprintf("%c", 39) } { printf "%s%s%s%s", (NR > 1 ? "," : ""), q, $0, q }')
        if [ -n "$_in_list" ]; then
            _tag_list=$(sqlite3 "$_db" \
                "SELECT DISTINCT scene_id FROM scene_tags WHERE lower(tag) IN ($_in_list) LIMIT 20;" 2>/dev/null)
        fi
    fi
    local _cands
    _cands=$(printf '%s\n%s\n' "$_fts_list" "$_tag_list" | grep -E '^[0-9]+$' | awk '!seen[$0]++')
    if [ -z "$_cands" ]; then
        _cands=$(sqlite3 "$_db" "SELECT scene_id FROM scenes ORDER BY ts DESC LIMIT 10;" 2>/dev/null)
    fi
    [ -n "$_cands" ] || return 0

    # The content-overlap proxy (_flow_emb_score) reads scenes.content directly
    # and has no dependency on the (unused) scene_emb table, so it is always
    # available. Do NOT gate it on scene_emb row count — that left the 0.15
    # embedding weight as dead weight while scene_emb sat empty in production.
    local _emb_avail=1

    local _fts_set _ntok
    _fts_set=" $(printf '%s' "$_fts_list" | tr '\n' ' ') "
    _ntok=$(printf '%s' "$_tokens" | wc -w)

    # Score every candidate; one record row per scene (sid leads every row).
    local _records="" _sid _row _ts _tool _tier _sal
    local _ts_e _age_s _rec _fts _tagf _emb _score _tags _tok _hits _tags_csv
    while IFS= read -r _sid; do
        [ -n "$_sid" ] || continue
        _row=$(sqlite3 -separator '|' "$_db" \
            "SELECT ts, provenance_tool, tier, salience FROM scenes WHERE scene_id = $_sid;" 2>/dev/null | head -1)
        [ -n "$_row" ] || continue
        IFS='|' read -r _ts _tool _tier _sal <<< "$_row"
        [ -n "$_tier" ] || _tier="vivid"
        case "${_sal:-}" in ''|*[!0-9.]*) _sal=0.5 ;; esac

        _ts_e=$(_flow_ts_epoch "$_ts")
        _age_s=$((_now - _ts_e))
        [ "$_age_s" -lt 0 ] && _age_s=0
        _rec=$(awk -v a="$_age_s" 'BEGIN { printf "%.4f", 1.0 / (1.0 + a / 3600.0) }')

        _fts=0.0
        case "$_fts_set" in *" $_sid "*) _fts=1.0 ;; esac

        _tagf=0.0
        if [ "$_ntok" -gt 0 ]; then
            _tags=$(sqlite3 "$_db" "SELECT lower(tag) FROM scene_tags WHERE scene_id = $_sid LIMIT 50;" 2>/dev/null | tr '\n' ' ')
            _hits=0
            for _tok in $_tokens; do
                case " $_tags " in *" $_tok "*) _hits=$((_hits + 1)) ;; esac
            done
            _tagf=$(awk -v h="$_hits" -v n="$_ntok" 'BEGIN { printf "%.4f", h / n }')
        fi

        _emb=$(_flow_emb_score "$_sid" "$_db" "$_tokens" "$_emb_avail")
        _score=$(awk -v f="$_fts" -v t="$_tagf" -v r="$_rec" -v e="$_emb" \
            'BEGIN { printf "%.4f", 0.45*f + 0.25*t + 0.15*r + 0.15*e }')

        _tags_csv=$(sqlite3 "$_db" \
            "SELECT group_concat(tag, ',') FROM (SELECT tag FROM scene_tags WHERE scene_id = $_sid ORDER BY tag LIMIT 3);" 2>/dev/null)

        _records="${_records}${_sid}"$'\t'"${_score}"$'\t'"${_fts}"$'\t'"${_tagf}"$'\t'"${_rec}"$'\t'"${_emb}"$'\t'"${_ts}"$'\t'"${_tool}"$'\t'"${_tier}"$'\t'"${_sal}"$'\t'"${_tags_csv}"$'\n'
    done <<< "$_cands"

    [ -n "$_records" ] || return 0
    _FLOW_FRINGE=$(printf '%s' "$_records" | sort -t$'\t' -k2,2nr | head -n "$FLOW_FRINGE_N")

    # Pairwise linkage edges along the ranked fringe chain (first match wins).
    local _n=0 _r
    while IFS= read -r _r; do
        [ -n "$_r" ] && _n=$((_n + 1))
    done <<< "$_FLOW_FRINGE"
    _FLOW_N="$_n"
    _FLOW_LINKS=$(_flow_build_links "$_FLOW_FRINGE" "$_db")
    if [ -n "$_FLOW_LINKS" ]; then
        _FLOW_TOP_TYPE=$(printf '%s\n' "$_FLOW_LINKS" | head -1 | cut -f4)
        _FLOW_TOP_EDGE=$(printf '%s\n' "$_FLOW_LINKS" | head -1 | cut -f1 | cut -c1-8)
    fi
    return 0
}

# ── Public API ──────────────────────────────────────────────────────────
# Assemble the per-turn AssembledPresent JSON for a focus string (TTL-cached).
flow_assemble_present() {
    _flow_validate_limits
    local _focus="$1"
    if [ -z "$_focus" ]; then
        printf '{}\n'
        return 1
    fi
    local _cache
    _cache="$(_flow_cache_path_for "$_focus")"
    if [ -z "${FLOW_BYPASS_CACHE:-}" ] && _flow_cache_valid "$_cache"; then
        cat "$_cache"
        return 0
    fi

    _flow_derive "$_focus" || return 1
    local _db; _db="$(_flow_db)"
    local _now_iso
    _now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # ── Budget fit ─────────────────────────────────────────────────────
    # Fit the present to FLOW_PRESENT_TOKEN_BUDGET by dropping the weakest
    # fringe scenes first (rank order), then trailing linkage edges. 24
    # tokens are reserved for the budget field itself so the emitted
    # present is provably within budget. A present is never emitted empty
    # while scenes exist; within_budget flags overflow on pathological
    # budgets (a single scene's JSON larger than the whole budget).
    local _fr_rows="$_FLOW_FRINGE" _ln_rows="$_FLOW_LINKS" _n="${_FLOW_N:-0}"
    local _top_type="${_FLOW_TOP_TYPE:-}" _top_edge="${_FLOW_TOP_EDGE:-}"
    local _dropped=0 _within=false _json _est _fit
    _fit=$(( FLOW_PRESENT_TOKEN_BUDGET - 24 ))
    [ "$_fit" -lt 1 ] && _fit=1
    while :; do
        _json=$(_flow_serialize_present "$_fr_rows" "$_ln_rows" "$_n" "$_top_type" "$_top_edge" "$_now_iso" "$_focus")
        _est=$(_flow_token_estimate "$_json")
        if [ "$_est" -le "$_fit" ]; then _within=true; break; fi
        if [ "$_n" -gt 1 ] 2>/dev/null; then
            _fr_rows=$(printf '%s\n' "$_fr_rows" | head -n $((_n - 1)))
            _n=$((_n - 1)); _dropped=$((_dropped + 1))
            _ln_rows=$(_flow_build_links "$_fr_rows" "$_db")
            if [ -n "$_ln_rows" ]; then
                _top_type=$(printf '%s\n' "$_ln_rows" | head -1 | cut -f4)
                _top_edge=$(printf '%s\n' "$_ln_rows" | head -1 | cut -f1 | cut -c1-8)
            else
                _top_type=""; _top_edge=""
            fi
        elif [ -n "$_ln_rows" ]; then
            _ln_rows=$(printf '%s\n' "$_ln_rows" | sed '$d')
            [ -n "$_ln_rows" ] || { _top_type=""; _top_edge=""; }
        else
            break   # a single scene alone exceeds the budget
        fi
    done

    local _est_final _est2 _json_final
    _est_final=$(_flow_token_estimate "$_json")
    while :; do
        # _json is a complete object; strip its closing brace, splice the
        # budget field, and re-close so the budget lives inside the root.
        _json_final="${_json%\}},\"budget\":{\"token_budget\":${FLOW_PRESENT_TOKEN_BUDGET},\"estimated_tokens\":${_est_final},\"within_budget\":${_within},\"fringe_dropped\":${_dropped}}}"
        _est2=$(_flow_token_estimate "$_json_final")
        [ "$_est2" = "$_est_final" ] && break
        _est_final=$_est2
    done

    mkdir -p "$(dirname "$_cache")" 2>/dev/null
    printf '%s\n' "$_json_final" > "$_cache" 2>/dev/null
    printf '%s' "$_json_final"
    return 0
}

# Print the effective flow tunables as JSON (operator/verification view).
flow_config() {
    _flow_validate_limits
    printf '{"edge_ttl_s":%s,"fringe_n":%s,"link_max":%s,"token_budget":%s,"cache_dir":"%s","bypass_cache":%s}\n' \
        "$FLOW_EDGE_TTL" "$FLOW_FRINGE_N" "$FLOW_LINK_MAX" "$FLOW_PRESENT_TOKEN_BUDGET" \
        "$(_flow_json_escape "$(_flow_cache_root)")" "${FLOW_BYPASS_CACHE:-0}"
    return 0
}

# Print derived linkage edges for a focus: tab rows edge_id a b type strength.
flow_linkages() {
    _flow_validate_limits
    local _focus="$1" _limit="${2:-$FLOW_LINK_MAX}"
    case "$_limit" in ''|*[!0-9]*) _limit="$FLOW_LINK_MAX" ;; esac
    _flow_derive "$_focus" || return 0
    printf '%s' "$_FLOW_LINKS"
    return 0
}

# Purge expired cache entries (safe from cron). Exact second-based expiry
# so sub-minute TTLs are honored.
flow_cache_gc() {
    local _dir _f _now _mtime _age
    _dir="$(_flow_cache_root)"
    [ -d "$_dir" ] || return 0
    _now=$(date +%s)
    for _f in "$_dir"/flow_*.json; do
        [ -f "$_f" ] || continue
        _mtime=$(stat -c %Y "$_f" 2>/dev/null) || continue
        _age=$((_now - _mtime))
        if [ "$_age" -gt "$FLOW_EDGE_TTL" ]; then
            rm -f "$_f" 2>/dev/null
        fi
    done
    return 0
}

# Drop all flow cache entries.
flow_cache_clear() {
    local _dir
    _dir="$(_flow_cache_root)"
    [ -d "$_dir" ] || return 0
    find "$_dir" -maxdepth 1 -name 'flow_*.json' -delete 2>/dev/null
    return 0
}

# ── Passive per-turn scene consumption ────────────────────────────────────
# scene_consume <focus> [n]
#
# The per-turn consumption loop: derives the AssembledPresent for the given
# focus, stamps the injected scenes (link_count++, last_linked_ts=now), and
# prints a compact text block suitable for system prompt injection.
#
# This implements the "nouns persist, verbs regenerate" principle: the same
# persistent scenes are re-entered each turn, ranked by what the current
# focus attends to. The flow (rankings, linkages) is ephemeral — only the
# stamp (link_count, last_linked_ts) is persisted so tier decay is
# link-activity aware.
#
# Usage:
#   scene_consume "fifo async ipc credits"          # top 5 (default)
#   scene_consume "scene system architecture" 8    # top 8
#
# Output (stdout) — compact, ~40 tokens per scene:
#   [Scene Flow — focus: "fifo async ipc credits"]
#   1. [vivid] 0.82 [ipc,fifo] 2026-11-14: We adopted the FIFO async IPC...
#   2. [vivid] 0.71 [ipc,credits] 2026-11-14: Review of the FIFO slidi...
#   — 2 scene(s) stamped
#
# Side effect: stamps the injected scenes via scene_stamp_many.
# Return: 0 on success (even if 0 scenes found), 1 on empty focus or error.
scene_consume() {
    _flow_validate_limits
    local _focus="${1:-}"
    local _n="${2:-5}"
    case "$_n" in ''|*[!0-9]*) _n=5 ;; esac
    [ "$_n" -lt 1 ] && _n=5
    [ "$_n" -gt 8 ] && _n=8
    [ -z "$_focus" ] && return 1

    # Ensure scene stamping is available (scenes.sh may not be sourced yet)
    if ! declare -f scene_stamp_many >/dev/null 2>&1; then
        local _sc_dir
        _sc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        source "$_sc_dir/scenes.sh" 2>/dev/null || return 1
    fi

    # Require jq for JSON parsing (core project dependency)
    command -v jq >/dev/null 2>&1 || return 1

    # Derive the AssembledPresent (respects FLOW_EDGE_TTL cache;
    # set FLOW_BYPASS_CACHE=1 to force fresh derivation)
    local _json
    _json=$(flow_assemble_present "$_focus" 2>/dev/null)
    [ -n "$_json" ] || return 1

    # Validate: must have a non-empty fringe array
    local _sc
    _sc=$(printf '%s' "$_json" | jq -r '.fringe | length' 2>/dev/null)
    case "${_sc:-0}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_sc" -gt 0 ] || return 1

    # Extract ranked scene IDs (first N from the fringe)
    local _ids
    _ids=$(printf '%s' "$_json" | jq -r ".fringe[:${_n}] | map(.scene_id) | join(\",\")")
    [ -n "$_ids" ] || return 1

    # Stamp: mark these scenes as consumed this turn (link_count++, last_linked_ts)
    local _stamped
    _stamped=$(scene_stamp_many "$_ids" 2>/dev/null)

    # Build the compact text block
    local _db _trunc
    _db="$(_flow_db)"
    _trunc=$(printf '%s' "$_focus" | head -c 60)

    printf '[Scene Flow — focus: "%s"]\n' "$_trunc"

    # ONE jq call extracts all fields as pipe-delimited rows
    local _rows _sid _tier _score _ts _tags _snip _i
    _rows=$(printf '%s' "$_json" | jq -r \
        ".fringe[:${_n}] | .[] | [.scene_id, .tier, .score, .ts[:10], (.tags | join(\",\"))] | join(\"|\")")

    _i=1
    while IFS='|' read -r _sid _tier _score _ts _tags; do
        [ -n "$_sid" ] || continue
        # Fetch content snippet (one quick local sqlite3 read per scene)
        _snip=$(sqlite3 "$_db" "SELECT substr(content, 1, 100) FROM scenes WHERE scene_id = $_sid;" 2>/dev/null)
        _snip="${_snip//$'\n'/ }"   # collapse newlines to spaces

        local _tag_display=""
        [ -n "$_tags" ] && _tag_display=" [${_tags}]"

        printf '%s. [%s] %s%s %s: %s\n' "$_i" "$_tier" "$_score" "$_tag_display" "$_ts" "$_snip"
        _i=$((_i + 1))
    done <<< "$_rows"

    printf -- '— %s scene(s) stamped\n' "${_stamped:-0}"
    return 0
}
