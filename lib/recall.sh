#!/bin/bash
# ── George: Recall System (FTS5 Knowledge Base) ────────────────
# Lightweight search over George's own documentation and memory.
# Uses SQLite FTS5 for BM25-ranked full-text search.
#
# Indexed sources:
#   ref          — RECALL_INDEX.md (FTS5-optimized master reference)
#   journal      — journal.md (living memory)
#   george       — GEORGE.md (current project memory)
#   doc:<label>  — user-ingested documents (/ingest)
#
# Raw human-readable docs (README, soul.md, docs/*.md) are NOT indexed.
# Their actionable content is distilled into docs/RECALL_INDEX.md for
# efficient retrieval with minimal noise.
#
# Overhead: ~50-100KB on disk, <1ms per query, 0 RAM.
# No network, no embedding model, no Python required.

[ -n "${_LIB_RECALL_LOADED:-}" ] && return 0; _LIB_RECALL_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR:-.}/.george}"
RECALL_DB="${RECALL_DB:-$GEORGE_DIR/recall.db}"
RECALL_MTIME_FILE="${RECALL_MTIME_FILE:-$GEORGE_DIR/.recall_mtimes}"

# ── Check if sqlite3 with FTS5 is available ────────────────────
recall_available() {
    if ! command -v sqlite3 &>/dev/null; then
        return 1
    fi
    # Quick FTS5 check (cached after first success)
    if [[ "${_RECALL_FTS5_OK:-}" == "1" ]]; then
        return 0
    fi
    local test_db="${TMPDIR:-/tmp}/.recall_fts5_test_$$.db"
    if sqlite3 "$test_db" "CREATE VIRTUAL TABLE _t USING fts5(c); DROP TABLE _t;" 2>/dev/null; then
        rm -f "$test_db"
        _RECALL_FTS5_OK=1
        # Check JSON1 support (json_group_array, json_object)
        if sqlite3 ':memory:' "SELECT json('{}');" &>/dev/null; then
            _RECALL_JSON1_OK=1
        else
            _RECALL_JSON1_OK=0
        fi
        return 0
    fi
    rm -f "$test_db"
    return 1
}

# ── Initialize the FTS5 database ──────────────────────────────
recall_init() {
    if ! recall_available; then
        ui_warn "sqlite3 with FTS5 not available — recall disabled"
        ui_dim "Install: apt install sqlite3  (or: pkg install sqlite)"
        return 1
    fi

    mkdir -p "$GEORGE_DIR"

    # Create tables if they don't exist
    sqlite3 "$RECALL_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source TEXT NOT NULL,       -- ref, journal, george, doc:<name>
    section TEXT NOT NULL,      -- section heading
    content TEXT NOT NULL,      -- section body
    filepath TEXT NOT NULL,     -- original file path
    indexed_at TEXT NOT NULL    -- ISO timestamp
);

CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    source,
    section,
    content,
    content='chunks',
    content_rowid='id',
    tokenize='porter unicode61'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
    INSERT INTO chunks_fts(rowid, source, section, content)
    VALUES (new.id, new.source, new.section, new.content);
END;

CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, source, section, content)
    VALUES ('delete', old.id, old.source, old.section, old.content);
END;

CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, source, section, content)
    VALUES ('delete', old.id, old.source, old.section, old.content);
    INSERT INTO chunks_fts(rowid, source, section, content)
    VALUES (new.id, new.source, new.section, new.content);
END;

-- Routing/evaluation trace (strict allowlist fields)
CREATE TABLE IF NOT EXISTS routing_eval_trace (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_boundary TEXT NOT NULL,
    recorded_at TEXT NOT NULL,
    infeasibility_class TEXT NOT NULL DEFAULT '',
    infeasibility_reason_code TEXT NOT NULL DEFAULT '',
    limitation_action TEXT NOT NULL DEFAULT '',
    tool_exposure_phase TEXT NOT NULL DEFAULT '',
    evaluator_mode TEXT NOT NULL DEFAULT 'normal',
    evaluator_failure_reason TEXT NOT NULL DEFAULT '',
    task_outcome_class TEXT NOT NULL DEFAULT '',
    redacted_diagnostic TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_routing_eval_trace_task
    ON routing_eval_trace(task_boundary, recorded_at);

-- Authoritative write-once terminal outcome per task boundary.
CREATE TABLE IF NOT EXISTS task_terminal_outcomes (
    task_boundary TEXT PRIMARY KEY,
    outcome_class TEXT NOT NULL,
    reason_code TEXT NOT NULL DEFAULT '',
    recorded_at TEXT NOT NULL
);

-- Evaluator diagnostic snapshots (redaction-safe, reproducible).
CREATE TABLE IF NOT EXISTS evaluator_diag_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_boundary TEXT NOT NULL,
    recorded_at TEXT NOT NULL,
    evaluator_mode TEXT NOT NULL DEFAULT 'normal',
    evaluator_failure_reason TEXT NOT NULL DEFAULT '',
    backend TEXT NOT NULL DEFAULT '',
    scenario TEXT NOT NULL DEFAULT '',
    token_budget INTEGER NOT NULL DEFAULT 0,
    output_length INTEGER NOT NULL DEFAULT 0,
    parse_mode TEXT NOT NULL DEFAULT '',
    grammar_mode TEXT NOT NULL DEFAULT '',
    selected_model TEXT NOT NULL DEFAULT '',
    grammar_schema_name TEXT NOT NULL DEFAULT '',
    prompt_char_count INTEGER NOT NULL DEFAULT 0,
    system_char_count INTEGER NOT NULL DEFAULT 0,
    estimated_token_pressure INTEGER NOT NULL DEFAULT 0,
    http_status INTEGER NOT NULL DEFAULT 0,
    received_sse_data INTEGER NOT NULL DEFAULT 0,
    received_non_sse_json_error INTEGER NOT NULL DEFAULT 0,
    curl_exit_code INTEGER NOT NULL DEFAULT 0,
    envelope_kind TEXT NOT NULL DEFAULT '',
    envelope_error_code TEXT NOT NULL DEFAULT '',
    envelope_error_message TEXT NOT NULL DEFAULT '',
    diagnostic_code TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_eval_diag_snapshots_task
    ON evaluator_diag_snapshots(task_boundary, recorded_at);

-- Grammar schema compatibility map used by runtime loop.
CREATE TABLE IF NOT EXISTS grammar_schema_compatibility (
    schema_name TEXT PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'unknown',
    stream_true_ok INTEGER NOT NULL DEFAULT 0,
    stream_false_ok INTEGER NOT NULL DEFAULT 0,
    repeated_runs INTEGER NOT NULL DEFAULT 0,
    diagnostic_code TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT '',
    checked_at TEXT NOT NULL
);
SQL

    return 0
}

# ── Chunk a markdown file by ## headers ────────────────────────
# Splits on level-2 headers. Each chunk = header + content until next header.
# Outputs NUL-separated records: section\tcontent\0
_recall_chunk_markdown() {
    local filepath="$1"
    [ -f "$filepath" ] || return 1

    awk '
    BEGIN { section = "(preamble)"; content = "" }
    /^## / {
        if (content != "") {
            # Clean up content: collapse whitespace, trim
            gsub(/\t/, " ", content)
            gsub(/\n{3,}/, "\n\n", content)
            sub(/^\n+/, "", content)
            sub(/\n+$/, "", content)
            if (length(content) > 0) {
                # Replace newlines with spaces for single-line output
                gsub(/\n/, " ", content)
                printf "%s\t%s\n", section, content
            }
        }
        section = $0
        sub(/^## */, "", section)
        content = ""
        next
    }
    { content = content "\n" $0 }
    END {
        if (content != "") {
            gsub(/\t/, " ", content)
            gsub(/\n{3,}/, "\n\n", content)
            sub(/^\n+/, "", content)
            sub(/\n+$/, "", content)
            if (length(content) > 0) {
                gsub(/\n/, " ", content)
                printf "%s\t%s\n", section, content
            }
        }
    }
    ' "$filepath"
}

# ── Index a single file ───────────────────────────────────────
# Usage: recall_index_file "readme" "/path/to/README.md"
recall_index_file() {
    local source="$1"
    local filepath="$2"

    [ -f "$filepath" ] || return 1

    local now
    now=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

    # Remove old entries for this source
    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source = '${source//\'/\'\'}';"

    # Chunk and index
    local count=0
    local _rc_tmp
    _rc_tmp=$(mktemp "${TMPDIR:-/tmp}/recall-chunk.XXXXXX")
    local _sanitized_file_tmp
    _sanitized_file_tmp=$(mktemp "${TMPDIR:-/tmp}/recall-sanitize.XXXXXX")
    sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' "$filepath" | python3 -c "
import sys
for line in sys.stdin:
    sys.stdout.write(''.join(c for c in line if ord(c) < 0x2500 or ord(c) > 0x25ff))
" 2>/dev/null > "$_sanitized_file_tmp" || cp "$filepath" "$_sanitized_file_tmp"

    if [[ "$(basename "$filepath")" == "GEORGE.md" ]]; then
        local _clean_file_tmp
        _clean_file_tmp=$(mktemp "${TMPDIR:-/tmp}/george-clean.XXXXXX")
        awk '
        BEGIN { skip=0 }
        /^## (Completed Milestones|Active Task)/ { skip=1; next }
        /^## / && skip { skip=0 }
        !skip { print }
        ' "$_sanitized_file_tmp" > "$_clean_file_tmp"
        _recall_chunk_markdown "$_clean_file_tmp" > "$_rc_tmp"
        rm -f "$_clean_file_tmp"
    else
        _recall_chunk_markdown "$_sanitized_file_tmp" > "$_rc_tmp"
    fi
    rm -f "$_sanitized_file_tmp"
    while IFS=$'\t' read -r section content; do
        [ -z "$content" ] && continue
        # Escape single quotes for SQL
        section="${section//\'/\'\'}"
        content="${content//\'/\'\'}"
        filepath_safe="${filepath//\'/\'\'}"

        sqlite3 "$RECALL_DB" \
            "INSERT INTO chunks (source, section, content, filepath, indexed_at)
             VALUES ('${source//\'/\'\'}', '$section', '$content', '$filepath_safe', '$now');"
        (( count++ ))
    done < "$_rc_tmp"
    rm -f "$_rc_tmp"

    return 0
}

# ── Check if reindex is needed ─────────────────────────────────
# Compares file mtimes against last indexed mtimes.
_recall_file_mtime() {
    local filepath="$1"
    [ -f "$filepath" ] || echo "0"
    stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null || echo "0"
}

# ── Build the source list for indexing ─────────────────────────
# Returns "source_name:filepath" lines, one per source.
#
# Only three sources are indexed:
#   ref     — RECALL_INDEX.md (FTS5-optimized master reference)
#   journal — journal.md (living memory with decay)
#   george  — GEORGE.md (current project memory)
#
# Raw human-readable docs (README, soul.md, docs/*.md) are NOT indexed.
# Their actionable content is distilled into RECALL_INDEX.md for
# efficient FTS5 retrieval with minimal noise.
_recall_all_sources() {
    # FTS5-optimized knowledge index (the only static source)
    echo "ref:$LODGE_DIR/docs/RECALL_INDEX.md"

    # Living memory (dynamic)
    [ -f "$LODGE_DIR/journal.md" ] && echo "journal:$LODGE_DIR/journal.md"

    # Current project memory (dynamic)
    if [ -f "./GEORGE.md" ]; then
        echo "george:$PWD/GEORGE.md"
    fi
}

recall_needs_reindex() {
    [ ! -f "$RECALL_DB" ] && return 0  # no DB yet → needs index

    # If the DB exists but is empty (schema only, 0 chunks), force reindex
    local chunk_count
    chunk_count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks;" 2>/dev/null || echo "0")
    [ "$chunk_count" -eq 0 ] 2>/dev/null && return 0

    local needs=1  # 1 = false (doesn't need)

    local _rs_tmp
    _rs_tmp=$(mktemp "${TMPDIR:-/tmp}/recall-src.XXXXXX")
    _recall_all_sources > "$_rs_tmp"
    while IFS=: read -r source filepath; do
        [ -f "$filepath" ] || continue

        local current_mtime
        current_mtime=$(_recall_file_mtime "$filepath")
        local stored_mtime=""
        if [ -f "$RECALL_MTIME_FILE" ]; then
            stored_mtime=$(grep "^${source}=" "$RECALL_MTIME_FILE" 2>/dev/null | cut -d= -f2)
        fi

        if [[ "$current_mtime" != "$stored_mtime" ]]; then
            needs=0  # true — at least one file changed
            break
        fi
    done < "$_rs_tmp"
    rm -f "$_rs_tmp"

    return $needs
}

# ── Save mtimes after indexing ─────────────────────────────────
_recall_save_mtimes() {
    > "$RECALL_MTIME_FILE"
    local _sm_tmp
    _sm_tmp=$(mktemp "${TMPDIR:-/tmp}/recall-src.XXXXXX")
    _recall_all_sources > "$_sm_tmp"
    while IFS=: read -r source filepath; do
        [ -f "$filepath" ] || continue
        local mtime
        mtime=$(_recall_file_mtime "$filepath")
        echo "${source}=${mtime}" >> "$RECALL_MTIME_FILE"
    done < "$_sm_tmp"
    rm -f "$_sm_tmp"
}

# ── Full reindex of all knowledge sources ─────────────────────
recall_reindex() {
    recall_init || return 1

    local total=0

    # Index all sources (RECALL_INDEX.md + journal + GEORGE.md)
    local _ri_tmp
    _ri_tmp=$(mktemp "${TMPDIR:-/tmp}/recall-src.XXXXXX")
    _recall_all_sources > "$_ri_tmp"
    while IFS=: read -r source filepath; do
        [ -f "$filepath" ] || continue
        recall_index_file "$source" "$filepath"
        (( total++ ))
    done < "$_ri_tmp"
    rm -f "$_ri_tmp"

    _recall_save_mtimes

    # Invalidate LRU cache — reindexed data means cached queries are stale
    if declare -f cache_invalidate_ns &>/dev/null; then
        cache_invalidate_ns "recall"
    fi

    ui_ok "Indexed $total sources" 2>/dev/null
    return 0
}

# ── Ensure index is fresh ─────────────────────────────────────
recall_ensure_indexed() {
    if recall_needs_reindex; then
        recall_reindex
    fi
}

# ── Sanitize query for FTS5 MATCH ────────────────────────────
# FTS5 has a rich query syntax where many punctuation characters are
# operators (*, +, ^, ~, :, AND, OR, NOT, etc.) and others (., @, #,
# /, <, >, |, &, etc.) cause parse errors when they appear inside
# unquoted tokens.
#
# Strategy:
#   1. Strip ALL non-alphanumeric, non-space, non-underscore chars.
#   2. Remove stop words (articles, verbs-of-intent, filler).
#      LLM-generated queries like "check existing isolation configs"
#      become "isolation configs" — the words that actually appear in
#      indexed content.
#   3. Collapse whitespace and trim.
#   4. Wrap each surviving word in FTS5 double-quotes.
#
# Args:
#   $1 — raw query string
#   $2 — join operator: "" (implicit AND, default) or "OR"
# Output: quoted FTS5 query string, or empty if nothing survives.
_recall_sanitize_query() {
    local raw="$1"
    local join="${2:-}"
    # Step 1: Keep only alphanumeric, spaces, and underscores
    local clean
    clean=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9_ \n' ' ')
    # Step 2: Remove stop words — articles, prepositions, and verbs-of-intent
    # that LLMs prepend to queries but never appear in indexed content.
    # Lowercase comparison; preserve original case in output.
    local _word _filtered=""
    for _word in $clean; do
        case "${_word,,}" in
            # Articles & pronouns
            a|an|the|this|that|these|those|it|its|my|our|your|their) ;;
            # Prepositions & conjunctions
            in|on|at|to|of|for|from|with|by|about|into|and|or|but|if|is|are|was|were|be|been|am|has|have|had|do|does|did|will|would|can|could|should|shall|may|might|not|no) ;;
            # Verbs-of-intent (LLM filler: "check existing", "find current", "look up")
            check|find|search|look|lookup|get|retrieve|fetch|show|list|display|identify|determine|examine|review|verify|confirm|locate|discover|explore|investigate|detect|analyze|ensure|obtain) ;;
            # Adjectives-of-state (LLM padding: "existing configs", "current setup")
            existing|current|available|possible|relevant|specific|particular|various|all|any|some|new|old|first|last|next|previous) ;;
            *) _filtered="$_filtered $_word" ;;
        esac
    done
    clean="${_filtered# }"
    # Fallback: if stop-word removal eliminated everything, use original
    # (e.g. "/recall find all" → all words are stop words)
    if [ -z "${clean// /}" ]; then
        clean=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9_ \n' ' ')
    fi
    # Step 3: Collapse multiple spaces and trim
    clean=$(printf '%s' "$clean" | sed 's/  */ /g; s/^ *//; s/ *$//')
    [ -z "$clean" ] && return 0
    # Step 4: Wrap each word in double-quotes for FTS5
    if [ "$join" = "OR" ]; then
        # "recall" OR "db" — explicit OR between quoted terms
        printf '%s' "$clean" | sed 's/[^ ][^ ]*/\"&\"/g; s/" "/\" OR \"/g'
    else
        # "recall" "db" — implicit AND (FTS5 default)
        printf '%s' "$clean" | sed 's/[^ ][^ ]*/\"&\"/g'
    fi
}

# ── Search the knowledge base ─────────────────────────────────
# Returns BM25-ranked results. Each result: source | section | snippet
# Usage: recall_search "sandboxes proot isolation" 5
recall_search() {
    local query="$1"
    local limit="${2:-5}"

    if ! recall_available; then
        return 1
    fi

    # Context mode must emit JSON only; suppress index refresh chatter.
    recall_ensure_indexed >/dev/null 2>&1

    local safe_query
    safe_query=$(_recall_sanitize_query "$query")
    # Bail on empty query after sanitization
    [ -z "$safe_query" ] && return 0

    # BM25 search with snippet extraction
    sqlite3 -separator '|' "$RECALL_DB" <<SQL
SELECT
    c.source,
    c.section,
    snippet(chunks_fts, 2, '>>>', '<<<', '...', 48) AS snippet
FROM chunks_fts
JOIN chunks c ON chunks_fts.rowid = c.id
WHERE chunks_fts MATCH '$safe_query'
ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0)
LIMIT $limit;
SQL
}

# ── Search and format for display ─────────────────────────────
recall_search_pretty() {
    local query="$1"
    local limit="${2:-5}"

    if ! recall_available; then
        ui_warn "Recall not available (sqlite3 with FTS5 required)"
        return 1
    fi

    local results
    results=$(recall_search "$query" "$limit")

    if [ -z "$results" ]; then
        # Try with OR between words for broader matching.
        # Uses _recall_sanitize_query directly to inject proper FTS5 OR
        # between quoted terms instead of passing raw "OR" through recall_search
        # (which would quote "OR" as a literal word).
        local or_query
        or_query=$(_recall_sanitize_query "$query" "OR")
        if [ -n "$or_query" ]; then
            results=$(recall_ensure_indexed; sqlite3 -separator '|' "$RECALL_DB" <<SQL
SELECT
    c.source,
    c.section,
    snippet(chunks_fts, 2, '>>>', '<<<', '...', 48) AS snippet
FROM chunks_fts
JOIN chunks c ON chunks_fts.rowid = c.id
WHERE chunks_fts MATCH '$or_query'
ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0)
LIMIT $limit;
SQL
            )
        fi
    fi

    if [ -n "$results" ]; then
        results=$(echo "$results" | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' | python3 -c "
import sys
for line in sys.stdin:
    sys.stdout.write(''.join(c for c in line if ord(c) < 0x2500 or ord(c) > 0x25ff))
" 2>/dev/null || echo "$results")
    fi

    local count=0
    while IFS='|' read -r source section snippet; do
        [ -z "$source" ] && continue
        (( count++ ))

        # Source label
        local label
        case "$source" in
            ref)        label="Reference" ;;
            journal)    label="Journal" ;;
            george)     label="Project" ;;
            user_pref)  label="User Pref" ;;
            doc:*)      label="${source#doc:}" ;;
            *)          label="$source" ;;
        esac

        printf "  %b[%s]%b %b%s%b\n" "$C_CYAN" "$label" "$C_RESET" "$C_WHITE" "$section" "$C_RESET"
        # Highlight match markers
        snippet="${snippet//>>>/$(printf '%b' "$C_YELLOW")}"
        snippet="${snippet//<<</$(printf '%b' "$C_RESET")}"
        printf "    %s\n\n" "$snippet"
    done <<< "$results"

    if [ "$count" -eq 0 ]; then
        ui_dim "  No results for: $query"
    fi
}

# ── Search and format for LLM context ─────────────────────────
# Returns plain text suitable for including in a system prompt.
# Uses full section content (capped at 300 chars) instead of
# snippet() to avoid noisy >>> <<< markers and truncation.
recall_search_context() {
    local query="$1"
    local limit="${2:-3}"
    local max_chars="${3:-300}"

    if ! recall_available; then
        return 1
    fi

    # ── LRU cache fast path (skips stat ops + sqlite3 fork) ──
    local _rsc_cache_key="recall:ctx:${query}:${limit}:${max_chars}"
    if declare -f cache_get &>/dev/null; then
        local _rsc_cached
        if _rsc_cached=$(cache_get "$_rsc_cache_key" "recall"); then
            printf '%s\n' "$_rsc_cached"
            return 0
        fi
    fi

    # Context mode must emit JSON only; suppress index refresh chatter.
    recall_ensure_indexed >/dev/null 2>&1

    local safe_query
    safe_query=$(_recall_sanitize_query "$query")
    [ -z "$safe_query" ] && return 0

    # Full content retrieval (capped) instead of snippet extraction.
    # Short sections (like ref doc cards) return complete; long ones truncate.
    local results
    results=$(sqlite3 -separator '|' "$RECALL_DB" <<SQL
SELECT
    c.source,
    c.section,
    CASE WHEN length(c.content) <= $max_chars
         THEN c.content
         ELSE substr(c.content, 1, $max_chars) || '...'
    END AS body
FROM chunks_fts
JOIN chunks c ON chunks_fts.rowid = c.id
WHERE chunks_fts MATCH '$safe_query'
ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0)
LIMIT $limit;
SQL
    )

    # OR fallback if AND produced no results
    if [ -z "$results" ]; then
        local or_query
        or_query=$(_recall_sanitize_query "$query" "OR")
        if [ -n "$or_query" ]; then
            results=$(sqlite3 -separator '|' "$RECALL_DB" <<SQL
SELECT
    c.source,
    c.section,
    CASE WHEN length(c.content) <= $max_chars
         THEN c.content
         ELSE substr(c.content, 1, $max_chars) || '...'
    END AS body
FROM chunks_fts
JOIN chunks c ON chunks_fts.rowid = c.id
WHERE chunks_fts MATCH '$or_query'
ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0)
LIMIT $limit;
SQL
            )
        fi
    fi

    [ -z "$results" ] && return 0

    # JSON array output — compact, matches micro_memory/syntax card patterns.
    # Small 2-4B models parse uniform JSON far more reliably than mixed
    # free-text-inside-JSON. Each result is {src, sec, body}.
    local _rsc_json='[]'

    if [[ "${_RECALL_JSON1_OK:-0}" == "1" ]]; then
        # ── Fast path: sqlite3 JSON functions ─────────────────
        # json_group_array + json_object produce a single valid JSON
        # string with proper escaping of newlines, quotes, and control
        # chars. Eliminates the pipe-delimited read loop that broke on
        # multi-line content (embedded newlines in body split records
        # across lines, corrupting field assignments).
        _rsc_json=$(sqlite3 "$RECALL_DB" <<SQL
SELECT json_group_array(
    json_object('src', source, 'sec', section, 'body', body))
FROM (
    SELECT
        c.source,
        c.section,
        CASE WHEN length(c.content) <= $max_chars
             THEN c.content
             ELSE substr(c.content, 1, $max_chars) || '...'
        END AS body
    FROM chunks_fts
    JOIN chunks c ON chunks_fts.rowid = c.id
    WHERE chunks_fts MATCH '$safe_query'
    ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0)
    LIMIT $limit
);
SQL
        )
        # json_group_array returns '[]' when subquery is empty — handled below
        if [ -z "$_rsc_json" ] || [ "$_rsc_json" = "[]" ] || [ "$_rsc_json" = "null" ]; then
            # OR fallback with JSON path
            local or_query_j
            or_query_j=$(_recall_sanitize_query "$query" "OR")
            if [ -n "$or_query_j" ]; then
                _rsc_json=$(sqlite3 "$RECALL_DB" <<SQL
SELECT json_group_array(
    json_object('src', source, 'sec', section, 'body', body))
FROM (
    SELECT
        c.source,
        c.section,
        CASE WHEN length(c.content) <= $max_chars
             THEN c.content
             ELSE substr(c.content, 1, $max_chars) || '...'
        END AS body
    FROM chunks_fts
    JOIN chunks c ON chunks_fts.rowid = c.id
    WHERE chunks_fts MATCH '$or_query_j'
    ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0)
    LIMIT $limit
);
SQL
                )
            fi
        fi
    else
        # ── Legacy fallback: pipe-delimited parsing ───────────
        # For sqlite3 without JSON1 (pre-3.9.0). Susceptible to
        # broken output when body content contains embedded newlines.
        local _rsc_arr='[]'
        while IFS='|' read -r source section body; do
            [ -z "$source" ] && continue
            _rsc_arr=$(jq -c \
                --arg src "$source" \
                --arg sec "$section" \
                --arg body "$body" \
                '. + [{"src":$src,"sec":$sec,"body":$body}]' <<< "$_rsc_arr")
        done <<< "$results"
        _rsc_json="$_rsc_arr"
    fi

    # Sanitize final JSON output (strip ANSI escapes and box-drawing/TUI characters)
    if [ -n "$_rsc_json" ] && [ "$_rsc_json" != "[]" ]; then
        _rsc_json=$(echo "$_rsc_json" | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' | python3 -c "
import sys
for line in sys.stdin:
    sys.stdout.write(''.join(c for c in line if ord(c) < 0x2500 or ord(c) > 0x25ff))
" 2>/dev/null || echo "$_rsc_json")
    fi

    # Store in LRU cache for subsequent turns
    if declare -f cache_put &>/dev/null && [ -n "$_rsc_json" ] && [ "$_rsc_json" != "[]" ]; then
        cache_put "$_rsc_cache_key" "recall" "$_rsc_json"
    fi

    printf '%s\n' "$_rsc_json"
}

# ── Get George's own capabilities summary ─────────────────────
# Returns key capability sections from the FTS5-optimized reference index.
recall_self_review() {
    if ! recall_available; then
        # Fallback: read the reference index directly
        if [ -f "$LODGE_DIR/docs/RECALL_INDEX.md" ]; then
            head -120 "$LODGE_DIR/docs/RECALL_INDEX.md"
        fi
        return
    fi

    recall_ensure_indexed

    # Pull key sections from the reference index
    local sections
    sections=$(sqlite3 -separator '|' "$RECALL_DB" <<'SQL'
SELECT section, content FROM chunks
WHERE source = 'ref'
AND (
    section LIKE '%Slash Command%'
    OR section LIKE '%Architecture%'
    OR section LIKE '%Security%'
    OR section LIKE '%Sandbox%'
    OR section LIKE '%Container%'
    OR section LIKE '%Phone%'
    OR section LIKE '%Memory%'
    OR section LIKE '%Agent%'
    OR section LIKE '%Init%'
)
ORDER BY id;
SQL
    )

    if [ -z "$sections" ]; then
        # Fallback
        head -120 "$LODGE_DIR/docs/RECALL_INDEX.md"
        return
    fi

    echo "=== GEORGE'S CAPABILITIES (from RECALL_INDEX) ==="
    echo ""
    while IFS='|' read -r section content; do
        [ -z "$section" ] && continue
        echo "## $section"
        echo "$content" | head -30
        echo ""
    done <<< "$sections"
}

# ── Get index statistics ──────────────────────────────────────
recall_stats() {
    if [ ! -f "$RECALL_DB" ]; then
        echo "not indexed"
        return
    fi

    local total sources
    total=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks;" 2>/dev/null || echo "0")
    sources=$(sqlite3 "$RECALL_DB" "SELECT source, COUNT(*) FROM chunks GROUP BY source;" 2>/dev/null || echo "")

    printf "  %bTotal chunks:%b %s\n" "$C_CYAN" "$C_RESET" "$total"
    while IFS='|' read -r src count; do
        [ -z "$src" ] && continue
        printf "    %-10s %s sections\n" "$src" "$count"
    done <<< "$sources"

    if [ -f "$RECALL_DB" ]; then
        local db_size
        db_size=$(du -h "$RECALL_DB" 2>/dev/null | cut -f1)
        printf "  %bDB size:%b     %s\n" "$C_CYAN" "$C_RESET" "$db_size"
    fi
}

# ── Clear the index ───────────────────────────────────────────
recall_clear() {
    if [ -f "$RECALL_DB" ]; then
        rm -f "$RECALL_DB"
        rm -f "$RECALL_MTIME_FILE"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Document Ingestion — Upload files to the knowledge base
# ═══════════════════════════════════════════════════════════════

# ── Supported file types ──────────────────────────────────────
# .md, .txt, .sh, .py, .rs, .js, .ts, .toml, .yaml, .yml, .json
# .pdf (requires pdftotext from poppler-utils)
# .html (stripped to plaintext)

# ── Extract text from any supported file ──────────────────────
_recall_extract_text() {
    local filepath="$1"
    local ext="${filepath##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    case "$ext" in
        md|txt|sh|bash|py|rs|js|ts|toml|yaml|yml|json|cfg|ini|conf|csv|log|c|h|cpp|hpp|java|go|rb|lua|sql|r|pl)
            # Plaintext — read directly
            cat "$filepath"
            ;;
        pdf)
            # PDF — requires pdftotext (poppler-utils)
            if command -v pdftotext &>/dev/null; then
                pdftotext -layout "$filepath" - 2>/dev/null
            else
                ui_err "pdftotext not found. Install: apt install poppler-utils"
                return 1
            fi
            ;;
        html|htm)
            # HTML — strip tags
            sed 's/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&nbsp;/ /g; s/&quot;/"/g' "$filepath"
            ;;
        doc|docx|odt)
            # Office docs — try basic extraction
            if command -v pandoc &>/dev/null; then
                pandoc -t plain "$filepath" 2>/dev/null
            elif command -v libreoffice &>/dev/null; then
                libreoffice --headless --convert-to txt --outdir "${TMPDIR:-/tmp}" "$filepath" 2>/dev/null
                local txt_file="${TMPDIR:-/tmp}/$(basename "${filepath%.*}").txt"
                [ -f "$txt_file" ] && cat "$txt_file" && rm -f "$txt_file"
            else
                ui_err "Cannot extract from .$ext — install pandoc or libreoffice"
                return 1
            fi
            ;;
        *)
            # Try as plaintext
            if file "$filepath" 2>/dev/null | grep -qi text; then
                cat "$filepath"
            else
                ui_err "Unsupported file type: .$ext"
                return 1
            fi
            ;;
    esac
}

# ── Chunk plain text by paragraphs/sections ───────────────────
# For non-markdown files, splits on blank lines into ~500 char chunks
_recall_chunk_text() {
    local filepath="$1"
    local source_name="$2"

    local text
    text=$(_recall_extract_text "$filepath") || return 1

    if [ -z "$text" ]; then
        return 1
    fi

    # For markdown files, use the header-based chunker
    local ext="${filepath##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    if [[ "$ext" == "md" ]]; then
        _recall_chunk_markdown "$filepath"
        return
    fi

    # For other files: split into ~500 char chunks on paragraph boundaries
    echo "$text" | awk -v name="$source_name" '
    BEGIN { chunk = ""; section = "(content)"; chunk_num = 0 }
    /^$/ {
        if (length(chunk) > 400) {
            chunk_num++
            section_label = sprintf("Part %d", chunk_num)
            gsub(/\t/, " ", chunk)
            gsub(/\n/, " ", chunk)
            sub(/^ +/, "", chunk)
            if (length(chunk) > 0) {
                printf "%s\t%s\n", section_label, chunk
            }
            chunk = ""
        } else {
            chunk = chunk "\n"
        }
        next
    }
    {
        # Check for section-like headers
        if ($0 ~ /^[A-Z].*:$/ || $0 ~ /^#+/) {
            if (length(chunk) > 50) {
                chunk_num++
                section_label = sprintf("Part %d", chunk_num)
                gsub(/\t/, " ", chunk)
                gsub(/\n/, " ", chunk)
                sub(/^ +/, "", chunk)
                if (length(chunk) > 0) {
                    printf "%s\t%s\n", section_label, chunk
                }
                chunk = ""
            }
            section = $0
            sub(/^#+ */, "", section)
            sub(/:$/, "", section)
        }
        chunk = chunk "\n" $0
    }
    END {
        if (length(chunk) > 0) {
            chunk_num++
            section_label = (chunk_num == 1) ? "(content)" : sprintf("Part %d", chunk_num)
            gsub(/\t/, " ", chunk)
            gsub(/\n/, " ", chunk)
            sub(/^ +/, "", chunk)
            if (length(chunk) > 0) {
                printf "%s\t%s\n", section_label, chunk
            }
        }
    }
    '
}

# ── Ingest a document into the knowledge base ─────────────────
# Usage: recall_ingest "document_label" "/path/to/file.pdf"
recall_ingest() {
    local label="$1"
    local filepath="$2"

    if [ -z "$label" ] || [ -z "$filepath" ]; then
        ui_err "Usage: recall_ingest <label> <filepath>"
        return 1
    fi

    if [ ! -f "$filepath" ]; then
        ui_err "File not found: $filepath"
        return 1
    fi

    recall_init || return 1

    # Use "doc:<label>" as the source to distinguish from built-in sources
    local source="doc:${label}"
    local now
    now=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

    # Remove old entries for this source
    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source = '${source//\'/\'\'}';"

    local count=0
    local ext="${filepath##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    if [[ "$ext" == "md" ]]; then
        # Use markdown chunker
        local _ic_tmp
        _ic_tmp=$(mktemp "${TMPDIR:-/tmp}/recall-chunk.XXXXXX")
        _recall_chunk_markdown "$filepath" > "$_ic_tmp"
        while IFS=$'\t' read -r section content; do
            [ -z "$content" ] && continue
            section="${section//\'/\'\'}"
            content="${content//\'/\'\'}"
            local fp_safe="${filepath//\'/\'\'}"
            sqlite3 "$RECALL_DB" \
                "INSERT INTO chunks (source, section, content, filepath, indexed_at)
                 VALUES ('${source//\'/\'\'}', '$section', '$content', '$fp_safe', '$now');"
            (( count++ ))
        done < "$_ic_tmp"
        rm -f "$_ic_tmp"
    else
        # Use generic text chunker
        local _ic_tmp
        _ic_tmp=$(mktemp "${TMPDIR:-/tmp}/recall-chunk.XXXXXX")
        _recall_chunk_text "$filepath" "$label" > "$_ic_tmp"
        while IFS=$'\t' read -r section content; do
            [ -z "$content" ] && continue
            section="${section//\'/\'\'}"
            content="${content//\'/\'\'}"
            local fp_safe="${filepath//\'/\'\'}"
            sqlite3 "$RECALL_DB" \
                "INSERT INTO chunks (source, section, content, filepath, indexed_at)
                 VALUES ('${source//\'/\'\'}', '$section', '$content', '$fp_safe', '$now');"
            (( count++ ))
        done < "$_ic_tmp"
        rm -f "$_ic_tmp"
    fi

    return 0
}

# ── List ingested documents ───────────────────────────────────
recall_list_documents() {
    if [ ! -f "$RECALL_DB" ]; then
        ui_dim "  No documents ingested yet."
        return
    fi

    local docs
    docs=$(sqlite3 -separator '|' "$RECALL_DB" \
        "SELECT source, COUNT(*), filepath FROM chunks WHERE source LIKE 'doc:%' GROUP BY source ORDER BY source;")

    if [ -z "$docs" ]; then
        ui_dim "  No documents ingested yet."
        return
    fi

    while IFS='|' read -r source count filepath; do
        [ -z "$source" ] && continue
        local label="${source#doc:}"
        printf "  %b●%b %-25s %b%d chunks%b  %b(%s)%b\n" \
            "$C_GREEN" "$C_RESET" "$label" \
            "$C_DIM" "$count" "$C_RESET" \
            "$C_DIM" "$filepath" "$C_RESET"
    done <<< "$docs"
}

# ── Remove an ingested document ───────────────────────────────
recall_remove_document() {
    local label="$1"
    if [ -z "$label" ]; then
        ui_err "Usage: recall_remove_document <label>"
        return 1
    fi

    local source="doc:${label}"
    local count
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='${source//\'/\'\'}';" 2>/dev/null)

    if [ "${count:-0}" -eq 0 ]; then
        ui_err "Document '$label' not found in index"
        return 1
    fi

    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source='${source//\'/\'\'}';"
    return 0
}

# ── Summarize a document (via LLM if available) ───────────────
# If llm_generate is available, summarizes and indexes the summary.
# Otherwise just indexes the raw content.
recall_ingest_with_summary() {
    local label="$1"
    local filepath="$2"

    if [ -z "$label" ] || [ -z "$filepath" ]; then
        ui_err "Usage: recall_ingest_with_summary <label> <filepath>"
        return 1
    fi

    [ -f "$filepath" ] || { ui_err "File not found: $filepath"; return 1; }

    # First, ingest the raw content
    recall_ingest "$label" "$filepath" || return 1

    # If LLM is available, generate and store a summary
    if declare -f llm_generate &>/dev/null; then
        local text
        text=$(_recall_extract_text "$filepath") || return 0

        # Truncate to ~2000 chars for summary prompt
        text=$(echo "$text" | head -c 2000)

        local summary
        ui_spinner_start "Summarizing"
        local LLM_SCENARIO=tool
        summary=$(llm_generate "Summarize this document in 3-5 bullet points. Be concise:

$text" "You are a concise summarizer. Output only bullet points." 256 "$LLM_BUDGET_TOOL" 2>/dev/null)
        ui_spinner_stop

        if [ -n "$summary" ] && [[ "$summary" != ERROR* ]]; then
            # Store the summary as an additional chunk
            local source="doc:${label}"
            local now
            now=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
            summary="${summary//\'/\'\'}"
            local fp_safe="${filepath//\'/\'\'}"
            sqlite3 "$RECALL_DB" \
                "INSERT INTO chunks (source, section, content, filepath, indexed_at)
                 VALUES ('${source//\'/\'\'}', 'Summary', '$summary', '$fp_safe', '$now');"
        fi
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════
# User Preference Recall — Agent-collected user answers via /ask
# ═══════════════════════════════════════════════════════════════
# Source tag: "user_pref"
# Section:   the question the agent asked
# Content:   the user's answer
# Filepath:  "agent:/ask" (virtual — no physical file)
#
# Capped at RECALL_USER_PREF_MAX entries (default 20, FIFO eviction).
# Supports: prune by date, compact via LLM summarization.

RECALL_USER_PREF_MAX="${RECALL_USER_PREF_MAX:-20}"

# ── Log a single Q&A pair from /ask ──────────────────────────
# Usage: recall_log_user_input "What is your preferred language?" "Rust"
recall_log_user_input() {
    local question="$1"
    local answer="$2"

    [ -z "$question" ] || [ -z "$answer" ] && return 1
    recall_init || return 1

    local now
    now=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

    # Escape single quotes for SQL
    local q_safe="${question//\'/\'\'}"
    local a_safe="${answer//\'/\'\'}"

    sqlite3 "$RECALL_DB" \
        "INSERT INTO chunks (source, section, content, filepath, indexed_at)
         VALUES ('user_pref', '$q_safe', '$a_safe', 'agent:/ask', '$now');"

    # FIFO eviction: keep only the newest N entries
    local count
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref';" 2>/dev/null || echo "0")
    if [ "$count" -gt "$RECALL_USER_PREF_MAX" ]; then
        local excess=$(( count - RECALL_USER_PREF_MAX ))
        sqlite3 "$RECALL_DB" \
            "DELETE FROM chunks WHERE id IN (
                SELECT id FROM chunks WHERE source='user_pref'
                ORDER BY indexed_at ASC LIMIT $excess
            );"
    fi

    return 0
}

# ── List all user preference entries ──────────────────────────
recall_list_user_prefs() {
    if [ ! -f "$RECALL_DB" ]; then
        ui_dim "  No user preferences stored yet."
        return
    fi

    local prefs
    prefs=$(sqlite3 -separator '|' "$RECALL_DB" \
        "SELECT section, content, indexed_at FROM chunks WHERE source='user_pref' ORDER BY indexed_at DESC;")

    if [ -z "$prefs" ]; then
        ui_dim "  No user preferences stored yet."
        return
    fi

    local count=0
    while IFS='|' read -r question answer ts; do
        [ -z "$question" ] && continue
        (( count++ ))
        printf "  %b%s%b\n" "$C_CYAN" "$ts" "$C_RESET"
        printf "    Q: %s\n" "$question"
        printf "    A: %s\n\n" "$answer"
    done <<< "$prefs"

    printf "  %b%d user preference(s) stored%b\n" "$C_DIM" "$count" "$C_RESET"
}

# ── Prune user preferences before a given date ───────────────
# Usage: recall_prune_user_prefs "2026-03-01"
#    or: recall_prune_user_prefs 30   (days)
recall_prune_user_prefs() {
    local cutoff="$1"

    if [ -z "$cutoff" ]; then
        ui_err "Usage: recall_prune_user_prefs <YYYY-MM-DD | days>"
        return 1
    fi

    [ ! -f "$RECALL_DB" ] && { ui_dim "No recall database."; return 0; }

    # If numeric, treat as days-ago
    if [[ "$cutoff" =~ ^[0-9]+$ ]]; then
        cutoff=$(date -d "-${cutoff} days" '+%Y-%m-%d' 2>/dev/null \
              || date -v-${cutoff}d '+%Y-%m-%d' 2>/dev/null)
        if [ -z "$cutoff" ]; then
            ui_err "Could not compute date offset"
            return 1
        fi
    fi

    # Validate date format (loose check)
    if ! [[ "$cutoff" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        ui_err "Invalid date format. Use YYYY-MM-DD or a number of days."
        return 1
    fi

    local before_count
    before_count=$(sqlite3 "$RECALL_DB" \
        "SELECT COUNT(*) FROM chunks WHERE source='user_pref' AND indexed_at < '${cutoff}T00:00:00';" 2>/dev/null || echo "0")

    if [ "$before_count" -eq 0 ]; then
        ui_dim "  No user preferences before $cutoff"
        return 0
    fi

    sqlite3 "$RECALL_DB" \
        "DELETE FROM chunks WHERE source='user_pref' AND indexed_at < '${cutoff}T00:00:00';"

    ui_ok "Pruned $before_count user preference(s) before $cutoff"
    return 0
}

# ── Compact user preferences via LLM summarization ───────────
# Reads all user_pref entries, asks the LLM to consolidate into a
# concise preference profile, deletes originals, inserts summary.
# If contradictions exist, keeps the most recent preference.
recall_compact_user_prefs() {
    [ ! -f "$RECALL_DB" ] && { ui_dim "No recall database."; return 0; }

    local count
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref';" 2>/dev/null || echo "0")

    if [ "$count" -le 1 ]; then
        ui_dim "  Only $count preference(s) — nothing to compact."
        return 0
    fi

    # Gather all Q&A pairs with timestamps
    local entries
    entries=$(sqlite3 -separator '|' "$RECALL_DB" \
        "SELECT indexed_at, section, content FROM chunks WHERE source='user_pref' ORDER BY indexed_at ASC;")

    # Build input for LLM
    local qa_text=""
    while IFS='|' read -r ts question answer; do
        [ -z "$question" ] && continue
        qa_text="${qa_text}[${ts}] Q: ${question}
A: ${answer}
"
    done <<< "$entries"

    if ! declare -f llm_generate &>/dev/null; then
        ui_warn "LLM not available — cannot compact. Use /recall prune <date> instead."
        return 1
    fi

    local summary
    ui_spinner_start "Compacting preferences"
    local LLM_SCENARIO=tool
    summary=$(llm_generate "Below are user preference Q&A entries collected over time (oldest first).
Consolidate them into a brief preference profile. Rules:
- If contradictory preferences exist, KEEP THE MOST RECENT one and note the change.
- Group related preferences (e.g., language, food, tools).
- Use \"Prefers X\" format, one per line.
- Keep it under 15 lines. No preamble.

$qa_text" \
        "You are a preference consolidator. Output only the consolidated profile." \
        512 "$LLM_BUDGET_TOOL" 2>/dev/null)
    ui_spinner_stop

    if [ -z "$summary" ] || [[ "$summary" == ERROR* ]]; then
        ui_err "LLM summarization failed — preferences unchanged."
        return 1
    fi

    # Replace all user_pref entries with the compacted summary
    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source='user_pref';"

    local now
    now=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    local s_safe="${summary//\'/\'\'}"

    sqlite3 "$RECALL_DB" \
        "INSERT INTO chunks (source, section, content, filepath, indexed_at)
         VALUES ('user_pref', 'User Preference Profile (compacted)', '$s_safe', 'agent:/ask', '$now');"

    ui_ok "Compacted $count preferences into 1 summary entry"
    printf "\n%s\n" "$summary"
    return 0
}

# ── Clear all user preferences ────────────────────────────────
recall_clear_user_prefs() {
    [ ! -f "$RECALL_DB" ] && return 0
    local count
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref';" 2>/dev/null || echo "0")
    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source='user_pref';"
    ui_ok "Cleared $count user preference(s)"
}

# ── Count user preference entries ─────────────────────────────
recall_user_pref_count() {
    [ ! -f "$RECALL_DB" ] && { echo "0"; return; }
    sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref';" 2>/dev/null || echo "0"
}

# ═══════════════════════════════════════════════════════════════
# Data & Memory Hooks — Trace, Outcomes, Diagnostics, Compatibility
# ═══════════════════════════════════════════════════════════════

_recall_now_iso() {
    date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S'
}

_recall_sql_escape() {
    local value="$1"
    printf '%s' "${value//\'/\'\'}"
}

_recall_sanitize_int() {
    local value="$1"
    [[ "$value" =~ ^-?[0-9]+$ ]] || { echo "0"; return; }
    echo "$value"
}

_recall_sanitize_bool_int() {
    local value="${1:-0}"
    case "${value,,}" in
        1|true|yes|y) echo "1" ;;
        *) echo "0" ;;
    esac
}

_recall_redact_text() {
    local value="$1"
    value=$(printf '%s' "$value" | sed -E \
        -e 's#https?://[^[:space:]]+#[REDACTED_ENDPOINT]#g' \
        -e 's#\b(Bearer|bearer)[[:space:]]+[A-Za-z0-9._-]+#\1 [REDACTED_TOKEN]#g' \
        -e 's#\b(sk|tok|token|api[_-]?key|apikey|authorization|auth)[=:][^[:space:]]+#\1=[REDACTED]#gi')
    if [ "${#value}" -gt 256 ]; then
        value="${value:0:256}...[truncated]"
    fi
    printf '%s' "$value"
}

_recall_redact_model_name() {
    local model="$1"
    if [[ "$model" == */* ]]; then
        model="${model##*/}"
    fi
    if [[ "$model" == *:* ]]; then
        model="${model##*:}"
    fi
    _recall_redact_text "$model"
}

_recall_redact_backend() {
    local backend="${1,,}"
    case "$backend" in
        *llama*|*ollama*|*local*|*inference*server*)
            echo "local_inference"
            ;;
        *openai*|*anthropic*|*google*|*cohere*|*groq*|*mistral*|*together*|*azure*|*vertex*)
            echo "external_provider"
            ;;
        "")
            echo ""
            ;;
        *)
            _recall_redact_text "$backend"
            ;;
    esac
}

_recall_allowed_infeasibility_class() {
    case "$1" in
        none|blocked_by_capability|blocked_by_policy) return 0 ;;
        *) return 1 ;;
    esac
}

_recall_allowed_limitation_action() {
    case "$1" in
        RESCOPE|ALT_PATH|TERMINATE|"") return 0 ;;
        *) return 1 ;;
    esac
}

_recall_allowed_tool_exposure_phase() {
    case "$1" in
        A|B|C|"") return 0 ;;
        *) return 1 ;;
    esac
}

_recall_allowed_evaluator_mode() {
    case "$1" in
        normal|degraded) return 0 ;;
        *) return 1 ;;
    esac
}

_recall_allowed_task_outcome_class() {
    case "$1" in
        successful|blocked_by_capability|blocked_by_policy|user_terminated|"") return 0 ;;
        *) return 1 ;;
    esac
}

# Persist a strict-allowlist trace row.
# Usage: recall_trace_record_allowlisted "task-id" '{"infeasibility_class":"none",...}'
recall_trace_record_allowlisted() {
    local task_boundary="$1"
    local payload_json="$2"

    [ -n "$task_boundary" ] || return 1
    [ -n "$payload_json" ] || payload_json='{}'
    recall_init || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local infeasibility_class infeasibility_reason_code limitation_action
    local tool_exposure_phase evaluator_mode evaluator_failure_reason task_outcome_class
    local redacted_diagnostic now

    infeasibility_class=$(jq -r '.infeasibility_class // ""' <<< "$payload_json" 2>/dev/null)
    infeasibility_reason_code=$(jq -r '.infeasibility_reason_code // ""' <<< "$payload_json" 2>/dev/null)
    limitation_action=$(jq -r '.limitation_action // ""' <<< "$payload_json" 2>/dev/null)
    tool_exposure_phase=$(jq -r '.tool_exposure_phase // ""' <<< "$payload_json" 2>/dev/null)
    evaluator_mode=$(jq -r '.evaluator_mode // "normal"' <<< "$payload_json" 2>/dev/null)
    evaluator_failure_reason=$(jq -r '.evaluator_failure_reason // ""' <<< "$payload_json" 2>/dev/null)
    task_outcome_class=$(jq -r '.task_outcome_class // ""' <<< "$payload_json" 2>/dev/null)
    redacted_diagnostic=$(jq -r '.redacted_diagnostic // ""' <<< "$payload_json" 2>/dev/null)

    _recall_allowed_infeasibility_class "$infeasibility_class" || infeasibility_class="none"
    _recall_allowed_limitation_action "$limitation_action" || limitation_action=""
    _recall_allowed_tool_exposure_phase "$tool_exposure_phase" || tool_exposure_phase=""
    _recall_allowed_evaluator_mode "$evaluator_mode" || evaluator_mode="normal"
    _recall_allowed_task_outcome_class "$task_outcome_class" || task_outcome_class=""

    infeasibility_reason_code=$(_recall_redact_text "$infeasibility_reason_code")
    evaluator_failure_reason=$(_recall_redact_text "$evaluator_failure_reason")
    redacted_diagnostic=$(_recall_redact_text "$redacted_diagnostic")
    now=$(_recall_now_iso)

    sqlite3 "$RECALL_DB" "INSERT INTO routing_eval_trace (
        task_boundary, recorded_at, infeasibility_class, infeasibility_reason_code,
        limitation_action, tool_exposure_phase, evaluator_mode, evaluator_failure_reason,
        task_outcome_class, redacted_diagnostic
    ) VALUES (
        '$(_recall_sql_escape "$task_boundary")',
        '$(_recall_sql_escape "$now")',
        '$(_recall_sql_escape "$infeasibility_class")',
        '$(_recall_sql_escape "$infeasibility_reason_code")',
        '$(_recall_sql_escape "$limitation_action")',
        '$(_recall_sql_escape "$tool_exposure_phase")',
        '$(_recall_sql_escape "$evaluator_mode")',
        '$(_recall_sql_escape "$evaluator_failure_reason")',
        '$(_recall_sql_escape "$task_outcome_class")',
        '$(_recall_sql_escape "$redacted_diagnostic")'
    );"

    jq -cn \
        --arg ts "$now" \
        --arg task_boundary "$task_boundary" \
        --arg infeasibility_class "$infeasibility_class" \
        --arg infeasibility_reason_code "$infeasibility_reason_code" \
        --arg limitation_action "$limitation_action" \
        --arg tool_exposure_phase "$tool_exposure_phase" \
        --arg evaluator_mode "$evaluator_mode" \
        --arg evaluator_failure_reason "$evaluator_failure_reason" \
        --arg task_outcome_class "$task_outcome_class" \
        --arg redacted_diagnostic "$redacted_diagnostic" \
        '{
            ts:$ts,
            task_boundary:$task_boundary,
            infeasibility_class:$infeasibility_class,
            infeasibility_reason_code:$infeasibility_reason_code,
            limitation_action:$limitation_action,
            tool_exposure_phase:$tool_exposure_phase,
            evaluator_mode:$evaluator_mode,
            evaluator_failure_reason:$evaluator_failure_reason,
            task_outcome_class:$task_outcome_class,
            redacted_diagnostic:$redacted_diagnostic
        }'
}

# Authoritative terminal outcome model.
# Write-once: non-terminal -> terminal only, terminal is immutable.
recall_record_terminal_outcome() {
    local task_boundary="$1"
    local outcome_class="$2"
    local reason_code="${3:-}"

    [ -n "$task_boundary" ] || return 1
    _recall_allowed_task_outcome_class "$outcome_class" || return 1
    [ -n "$outcome_class" ] || return 1
    recall_init || return 1

    local existing
    existing=$(sqlite3 "$RECALL_DB" "SELECT outcome_class FROM task_terminal_outcomes WHERE task_boundary='$(_recall_sql_escape "$task_boundary")' LIMIT 1;" 2>/dev/null)

    if [ -n "$existing" ]; then
        # Immutable terminal state: allow exact idempotent replay only.
        [ "$existing" = "$outcome_class" ] && return 0
        return 1
    fi

    reason_code=$(_recall_redact_text "$reason_code")
    local now
    now=$(_recall_now_iso)

    sqlite3 "$RECALL_DB" "INSERT INTO task_terminal_outcomes (task_boundary, outcome_class, reason_code, recorded_at)
        VALUES (
            '$(_recall_sql_escape "$task_boundary")',
            '$(_recall_sql_escape "$outcome_class")',
            '$(_recall_sql_escape "$reason_code")',
            '$(_recall_sql_escape "$now")'
        );"
}

recall_get_terminal_outcome() {
    local task_boundary="$1"
    [ -n "$task_boundary" ] || return 1
    [ -f "$RECALL_DB" ] || return 1

    command -v jq >/dev/null 2>&1 || return 1
    local row
    row=$(sqlite3 -separator '|' "$RECALL_DB" "SELECT task_boundary, outcome_class, reason_code, recorded_at
        FROM task_terminal_outcomes WHERE task_boundary='$(_recall_sql_escape "$task_boundary")' LIMIT 1;" 2>/dev/null)
    [ -n "$row" ] || return 1

    local b o r t
    IFS='|' read -r b o r t <<< "$row"
    jq -cn --arg task_boundary "$b" --arg outcome_class "$o" --arg reason_code "$r" --arg recorded_at "$t" \
        '{task_boundary:$task_boundary, outcome_class:$outcome_class, reason_code:$reason_code, recorded_at:$recorded_at}'
}

# Persist evaluator diagnostic snapshots (redaction-safe allowlist only).
# Usage: recall_record_evaluator_snapshot "task-id" '{...}'
recall_record_evaluator_snapshot() {
    local task_boundary="$1"
    local payload_json="$2"

    [ -n "$task_boundary" ] || return 1
    [ -n "$payload_json" ] || payload_json='{}'
    recall_init || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local evaluator_mode evaluator_failure_reason backend scenario token_budget
    local output_length parse_mode grammar_mode selected_model grammar_schema_name
    local prompt_char_count system_char_count estimated_token_pressure http_status
    local received_sse_data received_non_sse_json_error curl_exit_code envelope_kind
    local envelope_error_code envelope_error_message diagnostic_code now

    evaluator_mode=$(jq -r '.evaluator_mode // "normal"' <<< "$payload_json" 2>/dev/null)
    evaluator_failure_reason=$(jq -r '.failure_reason // .evaluator_failure_reason // ""' <<< "$payload_json" 2>/dev/null)
    backend=$(jq -r '.backend // ""' <<< "$payload_json" 2>/dev/null)
    scenario=$(jq -r '.scenario // ""' <<< "$payload_json" 2>/dev/null)
    token_budget=$(jq -r '.token_budget // 0' <<< "$payload_json" 2>/dev/null)
    output_length=$(jq -r '.output_length // 0' <<< "$payload_json" 2>/dev/null)
    parse_mode=$(jq -r '.parse_mode // ""' <<< "$payload_json" 2>/dev/null)
    grammar_mode=$(jq -r '.grammar_mode // ""' <<< "$payload_json" 2>/dev/null)
    selected_model=$(jq -r '.selected_model // ""' <<< "$payload_json" 2>/dev/null)
    grammar_schema_name=$(jq -r '.grammar_schema_name // ""' <<< "$payload_json" 2>/dev/null)
    prompt_char_count=$(jq -r '.prompt_char_count // 0' <<< "$payload_json" 2>/dev/null)
    system_char_count=$(jq -r '.system_char_count // 0' <<< "$payload_json" 2>/dev/null)
    estimated_token_pressure=$(jq -r '.estimated_token_pressure // 0' <<< "$payload_json" 2>/dev/null)
    http_status=$(jq -r '.http_status // 0' <<< "$payload_json" 2>/dev/null)
    received_sse_data=$(jq -r '.received_sse_data // .received_sse_frames // 0' <<< "$payload_json" 2>/dev/null)
    received_non_sse_json_error=$(jq -r '.received_non_sse_json_error // 0' <<< "$payload_json" 2>/dev/null)
    curl_exit_code=$(jq -r '.curl_exit_code // .curl_code // 0' <<< "$payload_json" 2>/dev/null)
    envelope_kind=$(jq -r '.envelope_kind // ""' <<< "$payload_json" 2>/dev/null)
    envelope_error_code=$(jq -r '.envelope_error_code // ""' <<< "$payload_json" 2>/dev/null)
    envelope_error_message=$(jq -r '.envelope_error_message // ""' <<< "$payload_json" 2>/dev/null)
    diagnostic_code=$(jq -r '.diagnostic_code // ""' <<< "$payload_json" 2>/dev/null)

    _recall_allowed_evaluator_mode "$evaluator_mode" || evaluator_mode="normal"
    backend=$(_recall_redact_backend "$backend")
    scenario=$(_recall_redact_text "$scenario")
    evaluator_failure_reason=$(_recall_redact_text "$evaluator_failure_reason")
    parse_mode=$(_recall_redact_text "$parse_mode")
    grammar_mode=$(_recall_redact_text "$grammar_mode")
    selected_model=$(_recall_redact_model_name "$selected_model")
    grammar_schema_name=$(_recall_redact_text "$grammar_schema_name")
    envelope_kind=$(_recall_redact_text "$envelope_kind")
    envelope_error_code=$(_recall_redact_text "$envelope_error_code")
    envelope_error_message=$(_recall_redact_text "$envelope_error_message")
    diagnostic_code=$(_recall_redact_text "$diagnostic_code")

    token_budget=$(_recall_sanitize_int "$token_budget")
    output_length=$(_recall_sanitize_int "$output_length")
    prompt_char_count=$(_recall_sanitize_int "$prompt_char_count")
    system_char_count=$(_recall_sanitize_int "$system_char_count")
    estimated_token_pressure=$(_recall_sanitize_int "$estimated_token_pressure")
    http_status=$(_recall_sanitize_int "$http_status")
    received_sse_data=$(_recall_sanitize_bool_int "$received_sse_data")
    received_non_sse_json_error=$(_recall_sanitize_bool_int "$received_non_sse_json_error")
    curl_exit_code=$(_recall_sanitize_int "$curl_exit_code")
    now=$(_recall_now_iso)

    sqlite3 "$RECALL_DB" "INSERT INTO evaluator_diag_snapshots (
        task_boundary, recorded_at, evaluator_mode, evaluator_failure_reason,
        backend, scenario, token_budget, output_length, parse_mode, grammar_mode,
        selected_model, grammar_schema_name, prompt_char_count, system_char_count,
        estimated_token_pressure, http_status, received_sse_data,
        received_non_sse_json_error, curl_exit_code, envelope_kind,
        envelope_error_code, envelope_error_message, diagnostic_code
    ) VALUES (
        '$(_recall_sql_escape "$task_boundary")',
        '$(_recall_sql_escape "$now")',
        '$(_recall_sql_escape "$evaluator_mode")',
        '$(_recall_sql_escape "$evaluator_failure_reason")',
        '$(_recall_sql_escape "$backend")',
        '$(_recall_sql_escape "$scenario")',
        $token_budget,
        $output_length,
        '$(_recall_sql_escape "$parse_mode")',
        '$(_recall_sql_escape "$grammar_mode")',
        '$(_recall_sql_escape "$selected_model")',
        '$(_recall_sql_escape "$grammar_schema_name")',
        $prompt_char_count,
        $system_char_count,
        $estimated_token_pressure,
        $http_status,
        $received_sse_data,
        $received_non_sse_json_error,
        $curl_exit_code,
        '$(_recall_sql_escape "$envelope_kind")',
        '$(_recall_sql_escape "$envelope_error_code")',
        '$(_recall_sql_escape "$envelope_error_message")',
        '$(_recall_sql_escape "$diagnostic_code")'
    );"

    jq -cn \
        --arg ts "$now" \
        --arg task_boundary "$task_boundary" \
        --arg evaluator_mode "$evaluator_mode" \
        --arg evaluator_failure_reason "$evaluator_failure_reason" \
        --arg backend "$backend" \
        --arg scenario "$scenario" \
        --arg parse_mode "$parse_mode" \
        --arg grammar_mode "$grammar_mode" \
        --arg selected_model "$selected_model" \
        --arg grammar_schema_name "$grammar_schema_name" \
        --arg envelope_kind "$envelope_kind" \
        --arg envelope_error_code "$envelope_error_code" \
        --arg envelope_error_message "$envelope_error_message" \
        --arg diagnostic_code "$diagnostic_code" \
        --argjson token_budget "$token_budget" \
        --argjson output_length "$output_length" \
        --argjson prompt_char_count "$prompt_char_count" \
        --argjson system_char_count "$system_char_count" \
        --argjson estimated_token_pressure "$estimated_token_pressure" \
        --argjson http_status "$http_status" \
        --argjson received_sse_data "$received_sse_data" \
        --argjson received_non_sse_json_error "$received_non_sse_json_error" \
        --argjson curl_exit_code "$curl_exit_code" \
        '{
            ts:$ts,
            task_boundary:$task_boundary,
            evaluator_mode:$evaluator_mode,
            evaluator_failure_reason:$evaluator_failure_reason,
            backend:$backend,
            scenario:$scenario,
            token_budget:$token_budget,
            output_length:$output_length,
            parse_mode:$parse_mode,
            grammar_mode:$grammar_mode,
            selected_model:$selected_model,
            grammar_schema_name:$grammar_schema_name,
            prompt_char_count:$prompt_char_count,
            system_char_count:$system_char_count,
            estimated_token_pressure:$estimated_token_pressure,
            http_status:$http_status,
            received_sse_data:$received_sse_data,
            received_non_sse_json_error:$received_non_sse_json_error,
            curl_exit_code:$curl_exit_code,
            envelope_kind:$envelope_kind,
            envelope_error_code:$envelope_error_code,
            envelope_error_message:$envelope_error_message,
            diagnostic_code:$diagnostic_code
        }'
}

# Upsert schema compatibility record used by grammar validation paths.
recall_schema_compat_set() {
    local schema_name="$1"
    local status="$2"
    local stream_true_ok="${3:-0}"
    local stream_false_ok="${4:-0}"
    local repeated_runs="${5:-0}"
    local diagnostic_code="${6:-}"
    local notes="${7:-}"

    [ -n "$schema_name" ] || return 1
    recall_init || return 1

    case "$status" in
        compatible|incompatible|unknown) ;;
        *) status="unknown" ;;
    esac

    stream_true_ok=$(_recall_sanitize_bool_int "$stream_true_ok")
    stream_false_ok=$(_recall_sanitize_bool_int "$stream_false_ok")
    repeated_runs=$(_recall_sanitize_int "$repeated_runs")
    [ "$repeated_runs" -lt 0 ] && repeated_runs=0

    diagnostic_code=$(_recall_redact_text "$diagnostic_code")
    notes=$(_recall_redact_text "$notes")
    local checked_at
    checked_at=$(_recall_now_iso)

    sqlite3 "$RECALL_DB" "INSERT INTO grammar_schema_compatibility (
        schema_name, status, stream_true_ok, stream_false_ok, repeated_runs,
        diagnostic_code, notes, checked_at
    ) VALUES (
        '$(_recall_sql_escape "$schema_name")',
        '$(_recall_sql_escape "$status")',
        $stream_true_ok,
        $stream_false_ok,
        $repeated_runs,
        '$(_recall_sql_escape "$diagnostic_code")',
        '$(_recall_sql_escape "$notes")',
        '$(_recall_sql_escape "$checked_at")'
    )
    ON CONFLICT(schema_name) DO UPDATE SET
        status=excluded.status,
        stream_true_ok=excluded.stream_true_ok,
        stream_false_ok=excluded.stream_false_ok,
        repeated_runs=excluded.repeated_runs,
        diagnostic_code=excluded.diagnostic_code,
        notes=excluded.notes,
        checked_at=excluded.checked_at;"
}

recall_schema_compat_get() {
    local schema_name="$1"
    [ -n "$schema_name" ] || return 1
    [ -f "$RECALL_DB" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local row
    row=$(sqlite3 -separator '|' "$RECALL_DB" "SELECT schema_name, status, stream_true_ok, stream_false_ok, repeated_runs,
        diagnostic_code, notes, checked_at
        FROM grammar_schema_compatibility
        WHERE schema_name='$(_recall_sql_escape "$schema_name")' LIMIT 1;" 2>/dev/null)
    [ -n "$row" ] || return 1

    local s status st sf rr dc notes checked
    IFS='|' read -r s status st sf rr dc notes checked <<< "$row"
    jq -cn \
        --arg schema_name "$s" \
        --arg status "$status" \
        --arg diagnostic_code "$dc" \
        --arg notes "$notes" \
        --arg checked_at "$checked" \
        --argjson stream_true_ok "$st" \
        --argjson stream_false_ok "$sf" \
        --argjson repeated_runs "$rr" \
        '{
            schema_name:$schema_name,
            status:$status,
            stream_true_ok:$stream_true_ok,
            stream_false_ok:$stream_false_ok,
            repeated_runs:$repeated_runs,
            diagnostic_code:$diagnostic_code,
            notes:$notes,
            checked_at:$checked_at
        }'
}

recall_schema_compat_map_json() {
    [ -f "$RECALL_DB" ] || { echo '{}'; return 0; }
    command -v jq >/dev/null 2>&1 || return 1

    local rows out
    rows=$(sqlite3 -separator '|' "$RECALL_DB" "SELECT schema_name, status, stream_true_ok, stream_false_ok, repeated_runs,
        diagnostic_code, notes, checked_at
        FROM grammar_schema_compatibility
        ORDER BY schema_name ASC;" 2>/dev/null)
    out='{}'

    while IFS='|' read -r s status st sf rr dc notes checked; do
        [ -n "$s" ] || continue
        out=$(jq -c \
            --arg schema "$s" \
            --arg status "$status" \
            --arg diagnostic_code "$dc" \
            --arg notes "$notes" \
            --arg checked_at "$checked" \
            --argjson stream_true_ok "$st" \
            --argjson stream_false_ok "$sf" \
            --argjson repeated_runs "$rr" \
            '. + {($schema): {
                status:$status,
                stream_true_ok:$stream_true_ok,
                stream_false_ok:$stream_false_ok,
                repeated_runs:$repeated_runs,
                diagnostic_code:$diagnostic_code,
                notes:$notes,
                checked_at:$checked_at
            }}' <<< "$out")
    done <<< "$rows"

    printf '%s\n' "$out"
}

# ── Archive a completed milestone into FTS5 ────────────────────
# Usage: recall_archive_milestone "title" "summary" [filepath]
recall_archive_milestone() {
    local title="$1"
    local content="$2"
    local fpath="${3:-}"

    # Gate: recall database must be initialized/available
    recall_available || return 0
    recall_init || return 0

    local now
    now=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

    local title_safe content_safe fpath_safe
    title_safe="${title//\'/\'\'}"
    content_safe="${content//\'/\'\'}"
    fpath_safe="${fpath//\'/\'\'}"

    # Avoid duplicate archiving for the exact same milestone title and content
    local dup
    dup=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='milestone_archive' AND section='$title_safe' AND content='$content_safe';" 2>/dev/null || echo "0")
    if [ "$dup" -gt 0 ] 2>/dev/null; then
        return 0
    fi

    sqlite3 "$RECALL_DB" \
        "INSERT INTO chunks (source, section, content, filepath, indexed_at)
         VALUES ('milestone_archive', '$title_safe', '$content_safe', '$fpath_safe', '$now');"
}

# ── Search archived milestones using FTS5 ──────────────────────
# Usage: recall_search_milestones "query" [limit] [max_chars]
recall_search_milestones() {
    local query="$1"
    local limit="${2:-3}"
    local max_chars="${3:-400}"

    recall_available || return 0
    [ -f "$RECALL_DB" ] || return 0

    local safe_query
    safe_query=$(_recall_sanitize_query "$query")
    [ -z "$safe_query" ] && return 0

    local results
    results=$(sqlite3 -separator '|' "$RECALL_DB" <<SQL
SELECT
    c.section,
    CASE WHEN length(c.content) <= $max_chars
         THEN c.content
         ELSE substr(c.content, 1, $max_chars) || '...'
    END AS body,
    c.indexed_at
FROM chunks_fts
JOIN chunks c ON chunks_fts.rowid = c.id
WHERE c.source = 'milestone_archive' AND chunks_fts MATCH '$safe_query'
ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0)
LIMIT $limit;
SQL
    )

    # OR fallback if AND produced no results
    if [ -z "$results" ]; then
        local or_query
        or_query=$(_recall_sanitize_query "$query" "OR")
        if [ -n "$or_query" ]; then
            results=$(sqlite3 -separator '|' "$RECALL_DB" <<SQL
SELECT
    c.section,
    CASE WHEN length(c.content) <= $max_chars
         THEN c.content
         ELSE substr(c.content, 1, $max_chars) || '...'
    END AS body,
    c.indexed_at
FROM chunks_fts
JOIN chunks c ON chunks_fts.rowid = c.id
WHERE c.source = 'milestone_archive' AND chunks_fts MATCH '$or_query'
ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0)
LIMIT $limit;
SQL
            )
        fi
    fi

    [ -z "$results" ] && return 0

    # Format as JSON array of objects
    local _rm_json='[]'
    if [[ "${_RECALL_JSON1_OK:-0}" == "1" ]]; then
        _rm_json=$(sqlite3 "$RECALL_DB" <<SQL
SELECT json_group_array(
    json_object('title', section, 'summary', body, 'ts', indexed_at))
FROM (
    SELECT
        c.section,
        CASE WHEN length(c.content) <= $max_chars
             THEN c.content
             ELSE substr(c.content, 1, $max_chars) || '...'
        END AS body,
        c.indexed_at
    FROM chunks_fts
    JOIN chunks c ON chunks_fts.rowid = c.id
    WHERE c.source = 'milestone_archive' AND chunks_fts MATCH '$safe_query'
    ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0)
    LIMIT $limit
);
SQL
        )
        if [ -z "$_rm_json" ] || [ "$_rm_json" = "[]" ] || [ "$_rm_json" = "null" ]; then
            local or_query_m
            or_query_m=$(_recall_sanitize_query "$query" "OR")
            if [ -n "$or_query_m" ]; then
                _rm_json=$(sqlite3 "$RECALL_DB" <<SQL
SELECT json_group_array(
    json_object('title', section, 'summary', body, 'ts', indexed_at))
FROM (
    SELECT
        c.section,
        CASE WHEN length(c.content) <= $max_chars
             THEN c.content
             ELSE substr(c.content, 1, $max_chars) || '...'
        END AS body,
        c.indexed_at
    FROM chunks_fts
    JOIN chunks c ON chunks_fts.rowid = c.id
    WHERE c.source = 'milestone_archive' AND chunks_fts MATCH '$or_query_m'
    ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0)
    LIMIT $limit
);
SQL
                )
            fi
        fi
    else
        # Fallback manual JSON assembly
        local first=1
        _rm_json='['
        while IFS='|' read -r sec body ts; do
            [ -z "$sec" ] && continue
            [ "$first" -eq 0 ] && _rm_json="${_rm_json},"
            first=0
            local escaped_sec escaped_body
            escaped_sec=$(echo "$sec" | jq -aR .)
            escaped_body=$(echo "$body" | jq -aR .)
            _rm_json="${_rm_json}{\"title\":${escaped_sec},\"summary\":${escaped_body},\"ts\":\"$ts\"}"
        done <<< "$results"
        _rm_json="${_rm_json}]"
    fi

    printf '%s\n' "$_rm_json"
}

