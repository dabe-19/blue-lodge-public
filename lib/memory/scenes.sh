#!/bin/bash
# ── lib/memory/scenes.sh — Layer 1 Persistent Scene Store ─────────────────
# Specious-present substrate for the memory-flow architecture.
#
# Governance invariants:
#   * Stored scenes are nouns; flow (linkages) is generated per turn and is
#     NEVER persisted in this layer.
#   * 1:1 mapping with chunks via UNIQUE(chunk_id). chunks and chunks_fts
#     are never rewritten, rebuilt, or backfilled by default.
#   * Materialization is lazy and idempotent: a scene row is created on
#     first access for a given chunk; bulk mapping is an explicit opt-in
#     (scene_backfill_all) and is safe to re-run.
#
# Usage: source this file, then call scene_store_init before any other fn.
# Requires: sqlite3 with FTS5.

# Resolve recall DB path (explicit override > GEORGE_DIR > repo .george).
scenes_db_path() {
    if [ -n "${RECALL_DB:-}" ]; then
        printf '%s' "$RECALL_DB"
        return 0
    fi
    local _george_dir="${GEORGE_DIR:-${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.george}}"
    printf '%s' "$_george_dir/recall.db"
}

# Locate the schema file (LODGE_DIR override, then repo root).
scenes_schema_path() {
    local _repo_dir
    _repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
    local _schema="${LODGE_DIR:-}/data/schemas/recall.sql"
    if [ -n "${LODGE_DIR:-}" ] && [ -f "$_schema" ]; then
        printf '%s' "$_schema"
        return 0
    fi
    printf '%s' "$_repo_dir/data/schemas/recall.sql"
}

# Apply (or verify) the full recall schema, including Layer 1 tables.
# Idempotent: all DDL is IF NOT EXISTS; meta uses INSERT OR IGNORE.
scene_store_init() {
    command -v sqlite3 >/dev/null 2>&1 || { echo "scenes: sqlite3 not found" >&2; return 1; }
    local _db _schema
    _db="$(scenes_db_path)"
    _schema="$(scenes_schema_path)"
    [ -f "$_schema" ] || { echo "scenes: schema file not found at $_schema" >&2; return 1; }
    mkdir -p "$(dirname "$_db")"
    sqlite3 ":memory:" "CREATE VIRTUAL TABLE _t USING fts5(c); DROP TABLE _t;" 2>/dev/null \
        || { echo "scenes: sqlite3 FTS5 extension unavailable" >&2; return 1; }
    sqlite3 "$_db" < "$_schema" || { echo "scenes: schema application failed" >&2; return 1; }
    return 0
}

# Lazy, idempotent 1:1 materialization: ensure a scene exists for the chunk.
# Prints the scene_id on success (empty on failure). Never touches chunks.
# All text values are read from chunk COLUMNS inside SQLite — no shell
# interpolation of content, so pipes/newlines/quotes in content are safe.
scene_ensure_for_chunk() {
    local _chunk_id="$1"
    case "$_chunk_id" in ''|*[!0-9]*) return 1 ;; esac
    local _db; _db="$(scenes_db_path)"

    local _existing
    _existing=$(sqlite3 "$_db" "SELECT scene_id FROM scenes WHERE chunk_id = $_chunk_id;" 2>/dev/null)
    if [ -n "$_existing" ]; then
        printf '%s' "$_existing"
        return 0
    fi

    local _now
    _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    sqlite3 "$_db" <<SQL 2>/dev/null || return 1
INSERT OR IGNORE INTO scenes (
    chunk_id, ts, provenance_channel, provenance_user, provenance_tool,
    provenance_cron, provenance_session, tier, salience, content, created_at
)
SELECT
    c.id,
    c.indexed_at,
    '',
    '',
    CASE c.source
        WHEN 'journal'     THEN 'journal'
        WHEN 'george'      THEN 'george'
        WHEN 'user_pref'   THEN 'user_pref'
        WHEN 'lan_ledger'  THEN 'lan_ledger'
        WHEN 'ref'         THEN 'ref'
        ELSE c.source
    END,
    '',
    '',
    'vivid',
    0.5,
    c.content,
    '$_now'
FROM chunks c
WHERE c.id = $_chunk_id;
SQL

    local _id
    _id=$(sqlite3 "$_db" "SELECT scene_id FROM scenes WHERE chunk_id = $_chunk_id;" 2>/dev/null)
    [ -n "$_id" ] || return 1
    if declare -f scene_autotag_scene >/dev/null 2>&1; then
        scene_autotag_scene "$_id" >/dev/null 2>&1 || true
    fi
    printf '%s' "$_id"
}

# Print one scene row, pipe-delimited: scene_id|tier|salience|ts|tool
scene_get_meta() {
    local _scene_id="$1"
    case "$_scene_id" in ''|*[!0-9]*) return 1 ;; esac
    local _db; _db="$(scenes_db_path)"
    sqlite3 -separator '|' "$_db" \
        "SELECT scene_id, tier, salience, ts, provenance_tool FROM scenes WHERE scene_id = $_scene_id;" 2>/dev/null
}

# Print scene content verbatim (safe for pipes/newlines; not pipe-delimited).
scene_get_content() {
    local _scene_id="$1"
    case "$_scene_id" in ''|*[!0-9]*) return 1 ;; esac
    local _db; _db="$(scenes_db_path)"
    sqlite3 "$_db" "SELECT content FROM scenes WHERE scene_id = $_scene_id;" 2>/dev/null
}

# Add a tag to a scene (idempotent). tag_class defaults to 'topic'.
scene_tag_add() {
    local _scene_id="$1" _tag="$2" _class="${3:-topic}"
    case "$_scene_id" in ''|*[!0-9]*) return 1 ;; esac
    case "$_class" in person|place|topic|decision_class|device|emotion) ;; *) return 1 ;; esac
    local _safe_tag="${_tag//\'/\'\'}" _db
    _db="$(scenes_db_path)"
    sqlite3 "$_db" "INSERT OR IGNORE INTO scene_tags (scene_id, tag, tag_class) VALUES ($_scene_id, '$_safe_tag', '$_class');" 2>/dev/null
}

# List tags for a scene: one per line 'tag<TAB>tag_class'
scene_tags_list() {
    local _scene_id="$1"
    case "$_scene_id" in ''|*[!0-9]*) return 1 ;; esac
    local _db; _db="$(scenes_db_path)"
    sqlite3 -separator $'\t' "$_db" \
        "SELECT tag, tag_class FROM scene_tags WHERE scene_id = $_scene_id ORDER BY tag;" 2>/dev/null
}

# Update tier (vivid|fading|sediment) for a scene.
scene_set_tier() {
    local _scene_id="$1" _tier="$2"
    case "$_tier" in vivid|fading|sediment) ;; *) return 1 ;; esac
    case "$_scene_id" in ''|*[!0-9]*) return 1 ;; esac
    local _db; _db="$(scenes_db_path)"
    sqlite3 "$_db" "UPDATE scenes SET tier = '$_tier' WHERE scene_id = $_scene_id;" 2>/dev/null
}

# Explicit opt-in: materialize ALL chunks without a scene. Idempotent.
# Prints the number of scenes created on this run.
scene_backfill_all() {
    local _db _created=0 _ids _cid
    _db="$(scenes_db_path)"
    _ids=$(sqlite3 "$_db" "SELECT c.id FROM chunks c LEFT JOIN scenes s ON s.chunk_id = c.id WHERE s.chunk_id IS NULL;" 2>/dev/null)
    [ -z "$_ids" ] && { printf '0'; return 0; }
    for _cid in $_ids; do
        if scene_ensure_for_chunk "$_cid" >/dev/null 2>&1; then
            _created=$((_created + 1))
        fi
    done
    printf '%s' "$_created"
}

# Read-only: count chunks that have no scene mapping yet (the pending/cold set).
# Pure count — writes nothing. Prints a single integer.
scene_pending_count() {
    local _db _n
    _db="$(scenes_db_path)"
    [ -f "$_db" ] || { printf '0'; return 0; }
    _n=$(sqlite3 "$_db" "SELECT COUNT(*) FROM chunks c LEFT JOIN scenes s ON s.chunk_id = c.id WHERE s.chunk_id IS NULL;" 2>/dev/null)
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    printf '%s' "$_n"
}

# Strategy C (lazy path): rescue the dormant lazy materialization for COLD
# chunks — those never surfaced by a query (no scene row yet). Unlike the blunt
# one-shot bulk sweep (scene_seed_bulk, strategy B) or the query-tied 5-chunk
# newest-first cold seed (scene_search_hooks, strategy A), this walks the
# coldest unmaterialized chunks ONE AT A TIME through the canonical lazy
# primitive scene_ensure_for_chunk — a bounded batch per call.
#
#   * "Cold" == a chunk with no scene row. Any chunk an active query surfaces
#     is materialized + link-stamped by the in-loop hook (strategy A), so the
#     absence of a scene row is exactly "never queried."
#   * Coldest-first: oldest indexed_at first (longest neglected), id ASC
#     tie-break — complementary to the hook's newest-first (id DESC) seed, so
#     both ends of the backlog warm over time.
#   * Bounded by budget (arg 1, else SCENE_COLD_RESCUE_BUDGET, default 25): a
#     small incremental drip, not a sweep. Idempotent + resumable — the
#     pending set shrinks each call; a re-run picks up where the last stopped.
#   * Never touches chunks/chunks_fts. Prints the count rescued on this run.
scene_rescue_cold() {
    local _budget="${1:-${SCENE_COLD_RESCUE_BUDGET:-25}}"
    case "$_budget" in ''|*[!0-9]*) _budget=25 ;; esac
    [ "$_budget" -ge 1 ] || { printf '0'; return 0; }
    local _db; _db="$(scenes_db_path)"
    [ -f "$_db" ] || { printf '0'; return 0; }

    local _ids
    _ids=$(sqlite3 "$_db" "SELECT c.id FROM chunks c LEFT JOIN scenes s ON s.chunk_id = c.id WHERE s.chunk_id IS NULL ORDER BY c.indexed_at ASC, c.id ASC LIMIT $_budget;" 2>/dev/null)
    [ -n "$_ids" ] || { printf '0'; return 0; }

    local _rescued=0 _cid
    for _cid in $_ids; do
        if scene_ensure_for_chunk "$_cid" >/dev/null 2>&1; then
            _rescued=$((_rescued + 1))
        fi
    done
    printf '%s' "$_rescued"
}

# Scene FTS5 search (scenes only): 'scene_id<TAB>snippet' lines, BM25 ranked.
scene_search() {
    local _query="$1" _limit="${2:-5}"
    case "$_limit" in ''|*[!0-9]*) _limit=5 ;; esac
    local _db; _db="$(scenes_db_path)"
    sqlite3 -separator $'\t' "$_db" "
SELECT s.scene_id,
       replace(replace(snippet(scenes_fts, 0, '>>>', '<<<', '...', 48), char(10), ' '), '|', '/')
FROM scenes_fts
JOIN scenes s ON s.scene_id = scenes_fts.rowid
WHERE scenes_fts MATCH '${_query//\'/\'\'}'
ORDER BY bm25(scenes_fts, 1.0, 0.1) LIMIT $_limit;" 2>/dev/null
}

# Stats line: total_chunks=<n> scenes_materialized=<m> tagged=<t> embedded=<e> fts_rows=<f>
scene_stats() {
    local _db; _db="$(scenes_db_path)"
    sqlite3 "$_db" "
SELECT 'total_chunks=' || (SELECT COUNT(*) FROM chunks) ||
       ' scenes_materialized=' || (SELECT COUNT(*) FROM scenes) ||
       ' tagged=' || (SELECT COUNT(*) FROM scene_tags) ||
       ' embedded=' || (SELECT COUNT(*) FROM scene_emb) ||
       ' fts_rows=' || (SELECT COUNT(*) FROM scenes_fts);
" 2>/dev/null
}

# Stamp a single scene as consumed/linked: link_count++, last_linked_ts=now,
# first_linked_ts=now (only if NULL). Idempotent. Prints nothing.
scene_stamp() {
    local _scene_id="$1"
    case "$_scene_id" in ''|*[!0-9]*) return 1 ;; esac
    local _db _now
    _db="$(scenes_db_path)"
    _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sqlite3 "$_db" "
UPDATE scenes
SET link_count = link_count + 1,
    last_linked_ts = '$_now',
    first_linked_ts = COALESCE(first_linked_ts, '$_now')
WHERE scene_id = $_scene_id;
" 2>/dev/null
    return 0
}

# Batch stamp: comma-separated scene IDs. Single sqlite3 call (one transaction).
# Prints the number of rows stamped.
scene_stamp_many() {
    local _ids_csv="$1"
    [ -z "$_ids_csv" ] && { printf '0'; return 1; }
    case "$_ids_csv" in *[!0-9,]*) { printf '0'; return 1; } ;; esac
    local _db _now _n
    _db="$(scenes_db_path)"
    _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _n=$(sqlite3 "$_db" "
UPDATE scenes
SET link_count = link_count + 1,
    last_linked_ts = '$_now',
    first_linked_ts = COALESCE(first_linked_ts, '$_now')
WHERE scene_id IN (${_ids_csv});
SELECT changes();
" 2>/dev/null)
    printf '%s' "${_n:-0}"
    return 0
}

# Age-based tier decay: vivid -> fading (SCENE_DECAY_FADING_DAYS, default 14) and
# fading -> sediment (SCENE_DECAY_SEDIMENT_DAYS, default 60). Idempotent and
# link-activity aware: a scene linked within the window is not demoted.
# Layer 1 nouns are NEVER deleted here — sediment is deep memory, not dustbin.
# Prints 'decayed_fading=<a> decayed_sediment=<b>'.
scene_tier_decay() {
    local _db _now
    _db="$(scenes_db_path)"
    _now="$(date +%s)"
    local _fd="${SCENE_DECAY_FADING_DAYS:-14}"
    local _sd="${SCENE_DECAY_SEDIMENT_DAYS:-60}"
    # Epoch arithmetic via strftime('%s', ts): julianday() returns NULL on a
    # bare epoch string, which would silently demote nothing. Naive timestamps
    # are treated as UTC (consistent with the chunker's ISO format).
    local _a _b _c14 _c60
    _c14=$(( _now - _fd * 86400 ))
    _c60=$(( _now - _sd * 86400 ))
    _a=$(sqlite3 "$_db" "
UPDATE scenes SET tier='sediment'
WHERE tier='fading'
  AND CAST(strftime('%s', ts) AS INTEGER) IS NOT NULL
  AND CAST(strftime('%s', ts) AS INTEGER) < $_c60;
SELECT changes();" 2>/dev/null)
    _b=$(sqlite3 "$_db" "
UPDATE scenes SET tier='fading'
WHERE tier='vivid'
  AND CAST(strftime('%s', ts) AS INTEGER) IS NOT NULL
  AND CAST(strftime('%s', ts) AS INTEGER) < $_c14
  AND CAST(strftime('%s', COALESCE(last_linked_ts, ts)) AS INTEGER) < $_c14;
SELECT changes();" 2>/dev/null)
    printf 'decayed_fading=%s decayed_sediment=%s' "${_b:-0}" "${_a:-0}"
}

# Bulk idempotent seeding: materialize scenes for ALL chunks that lack one,
# in a single transaction (one sqlite3 invocation — safe for 10k+ rows).
# Mirrors scene_ensure_for_chunk's source->provenance mapping, with one
# improvement: for journal chunks whose `section` encodes the entry heading
# ('YYYY-MM-DD HH:MM — type'), scene ts is set to the ENTRY's own date
# (event time), not the chunk's indexed_at (reindex time), so tier decay is
# meaningful. Prints total scene count after the run.
scene_seed_bulk() {
    local _db _now
    _db="$(scenes_db_path)"
    _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sqlite3 "$_db" <<SQL 2>/dev/null || return 1
BEGIN;
INSERT OR IGNORE INTO scenes (
    chunk_id, ts, provenance_channel, provenance_user, provenance_tool,
    provenance_cron, provenance_session, tier, salience, content, created_at
)
SELECT
    c.id,
    CASE
        WHEN c.source = 'journal'
             AND c.section GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]*'
        THEN substr(c.section, 1, 16) || ':00'
        ELSE c.indexed_at
    END,
    '',
    '',
    CASE c.source
        WHEN 'journal'     THEN 'journal'
        WHEN 'george'      THEN 'george'
        WHEN 'user_pref'   THEN 'user_pref'
        WHEN 'lan_ledger'  THEN 'lan_ledger'
        WHEN 'ref'         THEN 'ref'
        ELSE c.source
    END,
    '',
    '',
    'vivid',
    0.5,
    c.content,
    '$_now'
FROM chunks c
LEFT JOIN scenes s ON s.chunk_id = c.id
WHERE s.chunk_id IS NULL;
COMMIT;
SQL
    sqlite3 "$_db" "SELECT COUNT(*) FROM scenes;" 2>/dev/null
}

# Extract top-N frequent content words (len>=4) from a scene's content as
# 'topic' tags. Idempotent: a scene that already carries >=1 tag is skipped.
# Dependency-free tokenization (tr/awk/sort/uniq) — no python required.
# Never touches chunks; prints nothing.
scene_autotag_scene() {
    local _sid="$1" _max="${2:-6}"
    case "$_sid" in ''|*[!0-9]*) return 0 ;; esac
    case "$_max" in ''|*[!0-9]*) _max=6 ;; esac
    local _db; _db="$(scenes_db_path)"
    local _have
    _have=$(sqlite3 "$_db" "SELECT COUNT(*) FROM scene_tags WHERE scene_id=$_sid;" 2>/dev/null)
    [ "${_have:-0}" -gt 0 ] 2>/dev/null && return 0
    local _tags
    _tags=$(scene_get_content "$_sid" 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs 'a-z0-9' '\n' \
        | awk 'length($0) >= 4' \
        | grep -vxE 'that|this|with|from|have|were|been|when|what|which|will|would|could|should|does|there|their|about|into|over|under|after|before|while|being|just|also|more|most|such|then|than|they|them|these|those|each|some|only|many|much|make|made|using|used|uses|work|works|working|first|second|third|here|like|well|very|even|ever|never|always|often|really|because|between|through|during|without|against|further|however|although|within|across|where|whether|another|around|behind|beside|below|among|along|above|beneath|inside|outside' 2>/dev/null \
        | sort | uniq -c | sort -rn | head -n "$_max" \
        | awk '{print $2}' | grep -E '^[a-z0-9]{4,}$')
    [ -n "$_tags" ] || return 0
    {
        echo "BEGIN;"
        local _t
        for _t in $_tags; do
            [ -n "$_t" ] && printf "INSERT OR IGNORE INTO scene_tags (scene_id, tag, tag_class) VALUES (%s, '%s', 'topic');\n" "$_sid" "${_t//\'/\'\'}"
        done
        echo "COMMIT;"
    } | sqlite3 "$_db" 2>/dev/null || true
    return 0
}

# Canonical production writer (cold-start seam fix): materialize scenes for
# every pending chunk and auto-tag untagged scenes in a single batched pass
# (zero per-row process forks). Gated: no-op under GEORGE_TEST_MODE=1 or
# SCENE_HOOKS_ENABLED=0. Bounded per call (SCENE_MATERIALIZE_BATCH, default 250)
# and skips tiny punctuation-only scenes (<12 chars) so hot paths never stall.
scene_materialize_now() {
    [ "${GEORGE_TEST_MODE:-0}" = "1" ] && return 0
    case "${SCENE_HOOKS_ENABLED:-1}" in 0|off|false|no) return 0 ;; esac
    command -v sqlite3 >/dev/null 2>&1 || return 0
    local _db; _db="$(scenes_db_path)"
    [ -f "$_db" ] || return 0
    scene_seed_bulk >/dev/null 2>&1 || return 0
    local _batch="${SCENE_MATERIALIZE_BATCH:-250}"
    case "$_batch" in ''|*[!0-9]*) _batch=250 ;; esac
    local _sql_tags
    _sql_tags=$(sqlite3 -separator $'\x1f' "$_db" "
SELECT s.scene_id, replace(replace(replace(s.content, char(10), ' '), char(13), ' '), char(31), ' ')
FROM scenes s
LEFT JOIN scene_tags t ON t.scene_id = s.scene_id
WHERE t.scene_id IS NULL AND length(trim(s.content)) >= 12
ORDER BY s.scene_id DESC
LIMIT $_batch;" 2>/dev/null | LC_ALL=C awk -F $'\x1f' '
BEGIN {
    split("that this with from have were been when what which will would could should does there their about into over under after before while being just also more most such then than they them these those each some only many much make made using used uses work works working first second third here like well very even ever never always often really because between through during without against further however although within across where whether another around behind beside below among along above beneath inside outside", sw, " ")
    for (i in sw) stop[sw[i]] = 1
    print "BEGIN;"
    emitted = 0
}
NF >= 2 {
    sid = $1
    if (sid !~ /^[0-9]+$/) next
    txt = tolower($2)
    gsub(/[^a-z0-9]+/, " ", txt)
    n = split(txt, w, " ")
    delete cnt
    for (i = 1; i <= n; i++) {
        tok = w[i]
        if (length(tok) >= 4 && !(tok in stop)) cnt[tok]++
    }
    # Select top 6 tokens by frequency (descending), alphabetical tie-break
    for (k = 1; k <= 6; k++) {
        best = ""; best_c = 0
        for (tok in cnt) {
            c = cnt[tok]
            if (c > best_c || (c == best_c && (best == "" || tok < best))) {
                best = tok; best_c = c
            }
        }
        if (best == "") break
        printf "INSERT OR IGNORE INTO scene_tags (scene_id, tag, tag_class) VALUES (%s, \x27%s\x27, \x27topic\x27);\n", sid, best
        emitted++
        delete cnt[best]
    }
}
END {
    if (emitted > 0) print "COMMIT;"
}')
    if [ -n "$_sql_tags" ] && [[ "$_sql_tags" == *"INSERT OR IGNORE"* ]]; then
        printf '%s\n' "$_sql_tags" | sqlite3 "$_db" 2>/dev/null || true
    fi
    return 0
}


# ── In-loop scene hooks (Strategy A + C) ───────────────────────────────────
# scene_search_hooks: called fire-and-forget from recall_search after a
# successful active query (wired in lib/memory/recall.sh). Never alters the
# search output contract; all work is idempotent and quote-safe (text values
# only ever cross the sqlite3 boundary inside single statements).
#
#   1. Strategy A (real-time): materialize scenes for the chunks this query
#      just surfaced, then stamp them as linked (link flow generated per turn).
#   2. Strategy C (cold rescue): opportunistically seed up to
#      SCENE_HOOK_COLD_SEED (default 5) still-pending dormant chunks, so even
#      never-queried memory drifts toward materialization while the loop runs.
#      Twin paths: scene_rescue_cold is the standalone lazy-path rescuer
#      (coldest-first, budgeted, query-activity-independent); scene_seed_bulk
#      is the blunt bulk net the catch-up cron keeps as overflow.
#
# Test-mode aware: SCENE_HOOKS_ENABLED=0 (or GEORGE_TEST_MODE=1) disables the
# side effects entirely. Returns 0 on success/no-op, 1 if the hook cannot run
# (caller ignores; a failed hook must never poison a search result).
scene_search_hooks() {
    local _query="${1:-}" _limit="${2:-5}"
    [ -n "${_query:-}" ] || return 0
    case "${SCENE_HOOKS_ENABLED:-1}" in 0|off|false|no) return 0 ;; esac
    [ "${GEORGE_TEST_MODE:-0}" = "1" ] && return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0

    local _db; _db="$(scenes_db_path)"
    [ -f "$_db" ] || return 0
    local _now; _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local _cold="${SCENE_HOOK_COLD_SEED:-5}"
    case "$_cold" in ''|*[!0-9]*) _cold=5 ;; esac

    # The query string crosses the shell boundary — escape single quotes only.
    # (It is already FTS-sanitized upstream by recall_search.)
    local _q="${_query//\'/\'\'}"

    # 1a) Strategy A — READ phase (pure read, own transaction): capture the
    # hit chunk ids as a numeric list. FTS5 forbids MATCH reads inside a
    # write transaction (the scenes_ai trigger writes scenes_fts on insert),
    # so the MATCH must happen in a read-only call and the writes in the
    # next one. Numeric ids make later interpolation safe.
    local _hit_ids
    _hit_ids=$(sqlite3 "$_db" "SELECT c.id FROM chunks c JOIN chunks_fts f ON f.rowid = c.id WHERE f.chunks_fts MATCH '$_q' LIMIT 20;" 2>/dev/null)
    if [ -n "$_hit_ids" ]; then
        local _hit_csv; _hit_csv=$(printf '%s\n' "$_hit_ids" | tr '\n' ',' | sed 's/,$//')
        # 1b) WRITE phase (write-only, one transaction): seed scenes for the
        # hit chunks, then stamp them as linked (this turn consumed them).
        sqlite3 "$_db" <<SQL 2>/dev/null || true
BEGIN;
INSERT OR IGNORE INTO scenes (
    chunk_id, ts, provenance_channel, provenance_user, provenance_tool,
    provenance_cron, provenance_session, tier, salience, content, created_at
)
SELECT
    c.id,
    CASE
        WHEN c.source = 'journal'
             AND c.section GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]*'
        THEN substr(c.section, 1, 16) || ':00'
        ELSE c.indexed_at
    END,
    '', '',
    CASE c.source
        WHEN 'journal'     THEN 'journal'
        WHEN 'george'      THEN 'george'
        WHEN 'user_pref'   THEN 'user_pref'
        WHEN 'lan_ledger'  THEN 'lan_ledger'
        WHEN 'ref'         THEN 'ref'
        ELSE c.source
    END,
    '', '', 'vivid', 0.5, c.content, '$_now'
FROM chunks c
LEFT JOIN scenes s ON s.chunk_id = c.id
WHERE s.chunk_id IS NULL
  AND c.id IN (${_hit_csv});

UPDATE scenes
SET link_count = link_count + 1,
    last_linked_ts = '$_now',
    first_linked_ts = COALESCE(first_linked_ts, '$_now')
WHERE chunk_id IN (${_hit_csv});
COMMIT;
SQL
    fi

    # 2) Strategy C: rescue dormant cold chunks that have never been
    # queried, bounded per call so the react loop stays fast. No FTS needed.
    sqlite3 "$_db" <<SQL 2>/dev/null || return 0
INSERT OR IGNORE INTO scenes (
    chunk_id, ts, provenance_channel, provenance_user, provenance_tool,
    provenance_cron, provenance_session, tier, salience, content, created_at
)
SELECT
    c.id,
    CASE
        WHEN c.source = 'journal'
             AND c.section GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]*'
        THEN substr(c.section, 1, 16) || ':00'
        ELSE c.indexed_at
    END,
    '', '',
    CASE c.source
        WHEN 'journal'     THEN 'journal'
        WHEN 'george'      THEN 'george'
        WHEN 'user_pref'   THEN 'user_pref'
        WHEN 'lan_ledger'  THEN 'lan_ledger'
        WHEN 'ref'         THEN 'ref'
        ELSE c.source
    END,
    '', '', 'vivid', 0.5, c.content, '$_now'
FROM chunks c
LEFT JOIN scenes s ON s.chunk_id = c.id
WHERE s.chunk_id IS NULL
ORDER BY c.id DESC
LIMIT $_cold;
SQL
    return 0
}


# ── Strategy B: catch-up reconciliation (id-stable, hash-gated) ──────────
# scene_reconcile_source <source> <tsv_file> <filepath>
# Id-stable 3-way reconcile of one source's chunks against a chunk TSV
# (lines: 'section<TAB>content', the output shape of _recall_chunk_markdown).
#   * section identity = (source, section heading); unchanged rows are
#     untouched (ids and indexed_at preserved), changed rows UPDATE in place
#     (id preserved), new sections INSERT, vanished sections DELETE.
#   * No MATCH anywhere in the transaction, so the FTS5 read/write context
#     rule cannot fire; chunks_ai/ad/au triggers maintain chunks_fts.
#   * Duplicate section headings in the file: first occurrence wins
#     (predictable id stability beats the legacy path's row-duplication).
# Prints '+<i> ~<u> -<d>' on success, returns 1 on bad input.
scene_reconcile_source() {
    local _source="${1:-}" _tsv="${2:-}" _fpath="${3:-}"
    case "$_source" in ''|*[\ \;\']*) return 1 ;; esac
    [ -f "$_tsv" ] || return 1
    local _db; _db="$(scenes_db_path)"
    [ -f "$_db" ] || return 0

    local _src_esc="${_source//\'/\'\'}"
    local _fp_esc="${_fpath//\'/\'\'}"
    local _now; _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local _sql_tmp; _sql_tmp=$(mktemp "${TMPDIR:-/tmp}/scene-recon.XXXXXX")
    {
        echo "CREATE INDEX IF NOT EXISTS idx_chunks_source_section ON chunks(source, section);"
        echo "BEGIN;"
        echo "CREATE TEMP TABLE desired(section TEXT NOT NULL, content TEXT NOT NULL);"
        LC_ALL=C awk -F'\t' '
        NF >= 2 && length($1) > 0 && length($2) > 0 {
            k = tolower($1)
            if (seen[k]++) next
            s = $1; c = $2
            gsub(/\x27/, "\x27\x27", s)
            gsub(/\x27/, "\x27\x27", c)
            printf "INSERT INTO desired VALUES (\x27%s\x27, \x27%s\x27);\n", s, c
        }' "$_tsv"
        echo "CREATE INDEX temp.idx_desired_section ON desired(section);"
        echo "CREATE TEMP TABLE delta(i INTEGER, u INTEGER, d INTEGER);"
        cat <<EOSQL
-- Precompute exact diff counts: changes() under-reports (returns 1 regardless
-- of rows inserted) while the chunks_ai FTS trigger is active, so COUNT(*) it is.
INSERT INTO delta SELECT
  (SELECT COUNT(*) FROM desired d WHERE NOT EXISTS (SELECT 1 FROM chunks c WHERE c.source = '$_src_esc' AND c.section = d.section)),
  (SELECT COUNT(*) FROM chunks c WHERE c.source = '$_src_esc' AND EXISTS (SELECT 1 FROM desired d WHERE d.section = c.section AND d.content <> c.content)),
  (SELECT COUNT(*) FROM chunks c WHERE c.source = '$_src_esc' AND NOT EXISTS (SELECT 1 FROM desired d WHERE d.section = c.section));
UPDATE chunks
SET content = (SELECT d.content FROM desired d WHERE d.section = chunks.section),
    filepath = '$_fp_esc',
    indexed_at = '$_now'
WHERE source = '$_src_esc'
  AND EXISTS (SELECT 1 FROM desired d WHERE d.section = chunks.section AND d.content <> chunks.content);
INSERT INTO chunks (source, section, content, filepath, indexed_at)
SELECT '$_src_esc', d.section, d.content, '$_fp_esc', '$_now'
FROM desired d
WHERE NOT EXISTS (SELECT 1 FROM chunks c WHERE c.source = '$_src_esc' AND c.section = d.section);
DELETE FROM chunks
WHERE source = '$_src_esc'
  AND NOT EXISTS (SELECT 1 FROM desired d WHERE d.section = chunks.section);
COMMIT;
SELECT '+' || i || ' ~' || u || ' -' || d FROM delta;
EOSQL
    } > "$_sql_tmp"

    local _out
    _out=$(sqlite3 "$_db" < "$_sql_tmp" 2>/dev/null)
    local _rc=$?
    rm -f "$_sql_tmp"
    [ $_rc -eq 0 ] && [ -n "$_out" ] || return 1
    printf '%s' "$_out"
    return 0
}

# Tiny section-identity token for duplicate-section dedup in reconcile (shell-safe).
_hash_token() {
    printf '%s' "$1" | tr -d '\t\n' | tr '[:upper:]' '[:lower:]'
}

# scene_sync [source] [filepath]
# Hash-gated, id-stable reconciliation of a source file into its chunk set.
# The catch-up chain's first stage: even if the react loop never ran a
# reindex, the next catch-up cron run folds the file's current sections
# into chunks WITHOUT id churn (scenes survive; link history preserved).
#   * gate: sha256 of the sanitized+chunked stream, stored in scene_meta
#     under 'scene_sync_hash:<source>'; byte-identical file -> pure no-op.
#   * chunker: _recall_chunk_markdown when recall.sh is sourced, else an
#     embedded equivalent (scenes.sh stays standalone).
#   * GEORGE.md gets the same section-skip as recall_index_file
#     (Completed Milestones / Active Task are volatile working state).
# Prints '<source>: unchanged' or '<source>: +<i> ~<u> -<d>'. Returns 0 on
# success/no-op/skipped-file; 1 only on operational failure.
scene_sync() {
    local _source="${1:-journal}" _fpath="${2:-}"
    case "$_source" in ''|*[\ \;\']*) return 1 ;; esac

    # Default path resolution (mirrors recall.sh _recall_all_sources).
    if [ -z "$_fpath" ]; then
        local _repo; _repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
        local _gdir="${GEORGE_DIR:-${LODGE_DIR:-$_repo}/.george}"
        case "$_source" in
            journal)    _fpath="${LODGE_DIR:-$_repo}/journal.md" ;;
            george)     _fpath="${PWD}/GEORGE.md" ;;
            user_pref)  _fpath="$_gdir/operator_notes.md" ;;
            ref)        _fpath="${LODGE_DIR:-$_repo}/docs/RECALL_INDEX.md" ;;
            *)          _fpath="${LODGE_DIR:-$_repo}/$_source.md" ;;
        esac
    fi
    [ -f "$_fpath" ] && { :; } || { printf '%s: file missing, skipped' "$_source"; return 0; }

    local _db; _db="$(scenes_db_path)"
    [ -f "$_db" ] || return 1

    # Sanitize (same pipeline as recall_index_file: control chars, ANSI,
    # box-drawing / block elements) then chunk.
    local _san; _san=$(mktemp "${TMPDIR:-/tmp}/scene-sync-san.XXXXXX")
    local _tsv; _tsv=$(mktemp "${TMPDIR:-/tmp}/scene-sync-tsv.XXXXXX")
    tr -d '\000-\010\013\014\016-\032\034-\037\177' < "$_fpath" \
        | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' \
        | LC_ALL=C sed $'s/\xe2\x94[\x80-\xbf]//g; s/\xe2\x95[\x80-\xbf]//g; s/\xe2\x96[\x80-\xbf]//g; s/\xe2\x97[\x80-\xbf]//g' > "$_san"
    if [ "$(basename "$_fpath")" = "GEORGE.md" ]; then
        local _cln; _cln=$(mktemp "${TMPDIR:-/tmp}/scene-sync-cln.XXXXXX")
        LC_ALL=C awk 'BEGIN { skip=0 } /^## (Completed Milestones|Active Task)/ { skip=1; next } /^## / && skip { skip=0 } !skip { print }' "$_san" > "$_cln"
        rm -f "$_san"
        _san="$_cln"
    fi
    if declare -f _recall_chunk_markdown >/dev/null 2>&1; then
        _recall_chunk_markdown "$_san" > "$_tsv"
    else
        # Embedded fallback: identical semantics to _recall_chunk_markdown.
        LC_ALL=C awk '
        BEGIN { section = "(preamble)"; content = "" }
        /^## / {
            if (content != "") {
                gsub(/\t/, " ", content); gsub(/\n{3,}/, "\n\n", content)
                sub(/^\n+/, "", content); sub(/\n+$/, "", content)
                if (length(content) > 0) { gsub(/\n/, " ", content); printf "%s\t%s\n", section, content }
            }
            section = $0; sub(/^## */, "", section); content = ""; next
        }
        { content = content "\n" $0 }
        END {
            if (content != "") {
                gsub(/\t/, " ", content); gsub(/\n{3,}/, "\n\n", content)
                sub(/^\n+/, "", content); sub(/\n+$/, "", content)
                if (length(content) > 0) { gsub(/\n/, " ", content); printf "%s\t%s\n", section, content }
            }
        }' "$_san" > "$_tsv"
    fi
    rm -f "$_san"

    # Hash gate: byte-identical chunk stream -> no-op, zero writes.
    local _hash; _hash=$(sha256sum "$_tsv" 2>/dev/null | cut -c1-16)
    if [ -n "$_hash" ]; then
        local _prev; _prev=$(sqlite3 "$_db" "SELECT value FROM scene_meta WHERE key='scene_sync_hash:${_source//\'/\'\'}';" 2>/dev/null)
        if [ -n "$_prev" ] && [ "$_prev" = "$_hash" ]; then
            rm -f "$_tsv"
            printf '%s: unchanged' "$_source"
            return 0
        fi
    fi

    # Id-stable reconcile against the (still-on-disk) TSV, then clean up.
    local _res
    _res=$(scene_reconcile_source "$_source" "$_tsv" "$_fpath" 2>/dev/null)
    rm -f "$_tsv"
    [ -n "$_res" ] || return 1

    # Record the gate hash (upsert; scene_meta is key/value).
    if [ -n "$_hash" ]; then
        sqlite3 "$_db" "INSERT INTO scene_meta(key, value) VALUES ('scene_sync_hash:${_source//\'/\'\'}', '$_hash')
ON CONFLICT(key) DO UPDATE SET value=excluded.value;" 2>/dev/null
    fi
    printf '%s: %s' "$_source" "$_res"
    return 0
}

# scene_prune_orphans
# Remove scenes whose chunk no longer exists (chunk deleted by user_pref
# compaction/expiry, journal section removal, or a legacy destructive
# reindex). Cascade deletes scene_tags/scene_emb rows; the scenes_ad trigger
# maintains scenes_fts. Prints the number of pruned scenes.
scene_prune_orphans() {
    local _db _n
    _db="$(scenes_db_path)"
    [ -f "$_db" ] && {
        # PRAGMA foreign_keys=ON is REQUIRED per-connection (OFF by default in
        # sqlite3 CLI) or the ON DELETE CASCADE on scene_tags/scene_emb is inert
        # and orphaned tag rows dangle. scenes_ad trigger still maintains fts.
        _n=$(sqlite3 "$_db" "
PRAGMA foreign_keys=ON;
DELETE FROM scenes WHERE chunk_id NOT IN (SELECT id FROM chunks);
SELECT changes();" 2>/dev/null)
    }
    printf '%s' "${_n:-0}"
    return 0
}
