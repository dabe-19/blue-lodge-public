#!/bin/bash
# ── George: Recall System (FTS5 Knowledge Base) ────────────────
# Lightweight search over George's own documentation and memory.
# Uses SQLite FTS5 for BM25-ranked full-text search.

[ -n "${_LIB_RECALL_LOADED:-}" ] && return 0; _LIB_RECALL_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"

GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR:-.}/.george}"
RECALL_DB="${RECALL_DB:-$GEORGE_DIR/recall.db}"
RECALL_MTIME_FILE="${RECALL_MTIME_FILE:-$GEORGE_DIR/.recall_mtimes}"

recall_available() {
    command -v sqlite3 &>/dev/null || return 1
    [[ "${_RECALL_FTS5_OK:-}" == "1" ]] && return 0
    local test_db="${TMPDIR:-/tmp}/.recall_fts5_test_$$.db"
    if sqlite3 "$test_db" "CREATE VIRTUAL TABLE _t USING fts5(c); DROP TABLE _t;" 2>/dev/null; then
        rm -f "$test_db"; _RECALL_FTS5_OK=1
        if sqlite3 ':memory:' "SELECT json('{}');" &>/dev/null; then
            _RECALL_JSON1_OK=1
        else
            _RECALL_JSON1_OK=0
        fi
        return 0
    fi
    rm -f "$test_db"; return 1
}

recall_init() {
    if ! recall_available; then
        ui_warn "sqlite3 with FTS5 not available — recall disabled"
        ui_dim "Install: apt install sqlite3  (or: pkg install sqlite)"
        return 1
    fi
    mkdir -p "$GEORGE_DIR"
    local _repo_dir; _repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
    local _schema_file="${LODGE_DIR:-}/data/schemas/recall.sql"
    [ ! -f "$_schema_file" ] && _schema_file="${_repo_dir}/data/schemas/recall.sql"
    [ -f "$_schema_file" ] && sqlite3 "$RECALL_DB" < "$_schema_file"
    return 0
}

_recall_chunk_markdown() {
    local filepath="$1"; [ -f "$filepath" ] || return 1
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
    }' "$filepath"
}

recall_index_file() {
    local source="$1" filepath="$2"
    [ -f "$filepath" ] || return 1
    local now; now=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source = '${source//\'/\'\'}';"

    local _rc_tmp; _rc_tmp=$(mktemp "${TMPDIR:-/tmp}/recall-chunk.XXXXXX")
    local _sanitized_file_tmp; _sanitized_file_tmp=$(mktemp "${TMPDIR:-/tmp}/recall-sanitize.XXXXXX")
    tr -d '\000-\010\013\014\016-\032\034-\037\177' < "$filepath" \
        | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' \
        | LC_ALL=C sed $'s/\xe2\x94[\x80-\xbf]//g; s/\xe2\x95[\x80-\xbf]//g; s/\xe2\x96[\x80-\xbf]//g; s/\xe2\x97[\x80-\xbf]//g' > "$_sanitized_file_tmp" \
        || tr -d '\000' < "$filepath" > "$_sanitized_file_tmp"

    if [[ "$(basename "$filepath")" == "GEORGE.md" ]]; then
        local _clean_file_tmp; _clean_file_tmp=$(mktemp "${TMPDIR:-/tmp}/george-clean.XXXXXX")
        LC_ALL=C awk 'BEGIN { skip=0 } /^## (Completed Milestones|Active Task)/ { skip=1; next } /^## / && skip { skip=0 } !skip { print }' "$_sanitized_file_tmp" > "$_clean_file_tmp"
        _recall_chunk_markdown "$_clean_file_tmp" > "$_rc_tmp"
        rm -f "$_clean_file_tmp"
    else
        _recall_chunk_markdown "$_sanitized_file_tmp" > "$_rc_tmp"
    fi
    rm -f "$_sanitized_file_tmp"

    if [ -s "$_rc_tmp" ]; then
        LC_ALL=C awk -F'\t' -v src="${source//\'/\'\'}" -v fp="${filepath//\'/\'\'}" -v now="$now" '
        BEGIN { print "BEGIN TRANSACTION;" }
        NF >= 2 && length($2) > 0 {
            s = $1; c = $2
            gsub(/\x27/, "\x27\x27", s)
            gsub(/\x27/, "\x27\x27", c)
            printf "INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES (\x27%s\x27, \x27%s\x27, \x27%s\x27, \x27%s\x27, \x27%s\x27);\n", src, s, c, fp, now
        }
        END { print "COMMIT;" }
        ' "$_rc_tmp" | sqlite3 "$RECALL_DB" 2>/dev/null
    fi
    rm -f "$_rc_tmp"
    return 0
}

_recall_file_mtime() {
    local filepath="$1"
    [ -f "$filepath" ] || { echo "0"; return; }
    stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null || echo "0"
}

_recall_all_sources() {
    echo "ref:$LODGE_DIR/docs/RECALL_INDEX.md"
    [ -f "$LODGE_DIR/journal.md" ] && echo "journal:$LODGE_DIR/journal.md"
    [ -f "./GEORGE.md" ] && echo "george:$PWD/GEORGE.md"
}

recall_needs_reindex() {
    [ ! -f "$RECALL_DB" ] && return 0
    local chunk_count; chunk_count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks;" 2>/dev/null || echo "0")
    [ "$chunk_count" -eq 0 ] 2>/dev/null && return 0

    local source filepath
    while IFS=: read -r source filepath; do
        [ -f "$filepath" ] || continue
        local current_mtime; current_mtime=$(_recall_file_mtime "$filepath")
        local stored_mtime=""
        [ -f "$RECALL_MTIME_FILE" ] && stored_mtime=$(grep "^${source}=" "$RECALL_MTIME_FILE" 2>/dev/null | cut -d= -f2)
        [[ "$current_mtime" != "$stored_mtime" ]] && return 0
    done < <(_recall_all_sources)
    return 1
}

_recall_save_mtimes() {
    > "$RECALL_MTIME_FILE"
    local source filepath
    while IFS=: read -r source filepath; do
        [ -f "$filepath" ] && echo "${source}=$(_recall_file_mtime "$filepath")" >> "$RECALL_MTIME_FILE"
    done < <(_recall_all_sources)
}

recall_reindex() {
    recall_init || return 1
    local total=0 source filepath
    while IFS=: read -r source filepath; do
        [ -f "$filepath" ] || continue
        recall_index_file "$source" "$filepath"
        (( total++ ))
    done < <(_recall_all_sources)
    _recall_save_mtimes
    declare -f cache_invalidate_ns &>/dev/null && cache_invalidate_ns "recall"
    ui_ok "Indexed $total sources" 2>/dev/null
    return 0
}

recall_ensure_indexed() {
    if recall_needs_reindex; then
        recall_reindex
    fi
}

_recall_sanitize_query() {
    local raw="$1" join="${2:-}"
    local clean; clean=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9_ \n' ' ')
    local _word _filtered=""
    for _word in $clean; do
        case "${_word,,}" in
            a|an|the|this|that|these|those|it|its|my|our|your|their) ;;
            in|on|at|to|of|for|from|with|by|about|into|and|or|but|if|is|are|was|were|be|been|am|has|have|had|do|does|did|will|would|can|could|should|shall|may|might|not|no) ;;
            check|find|search|look|lookup|get|retrieve|fetch|show|list|display|identify|determine|examine|review|verify|confirm|locate|discover|explore|investigate|detect|analyze|ensure|obtain) ;;
            existing|current|available|possible|relevant|specific|particular|various|all|any|some|new|old|first|last|next|previous) ;;
            *) _filtered="$_filtered $_word" ;;
        esac
    done
    clean="${_filtered# }"
    [ -z "${clean// /}" ] && clean=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9_ \n' ' ')
    clean=$(printf '%s' "$clean" | sed 's/  */ /g; s/^ *//; s/ *$//')
    [ -z "$clean" ] && return 0
    if [ "$join" = "OR" ]; then
        printf '%s' "$clean" | sed 's/[^ ][^ ]*/\"&\"/g; s/" "/\" OR \"/g'
    else
        printf '%s' "$clean" | sed 's/[^ ][^ ]*/\"&\"/g'
    fi
}

recall_search() {
    local query="$1" limit="${2:-5}"
    recall_available || return 1
    recall_ensure_indexed >/dev/null 2>&1
    local safe_query; safe_query=$(_recall_sanitize_query "$query")
    [ -z "$safe_query" ] && return 0
    sqlite3 -separator '|' "$RECALL_DB" <<SQL
SELECT c.source, c.section, snippet(chunks_fts, 2, '>>>', '<<<', '...', 48) AS snippet
FROM chunks_fts JOIN chunks c ON chunks_fts.rowid = c.id
WHERE chunks_fts MATCH '$safe_query'
ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0) LIMIT $limit;
SQL
}

recall_search_pretty() {
    local query="$1" limit="${2:-5}"
    if ! recall_available; then
        ui_warn "Recall not available (sqlite3 with FTS5 required)"
        return 1
    fi
    local results; results=$(recall_search "$query" "$limit")
    if [ -z "$results" ]; then
        local or_query; or_query=$(_recall_sanitize_query "$query" "OR")
        if [ -n "$or_query" ]; then
            results=$(recall_ensure_indexed; sqlite3 -separator '|' "$RECALL_DB" <<SQL
SELECT c.source, c.section, snippet(chunks_fts, 2, '>>>', '<<<', '...', 48) AS snippet
FROM chunks_fts JOIN chunks c ON chunks_fts.rowid = c.id
WHERE chunks_fts MATCH '$or_query'
ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0) LIMIT $limit;
SQL
            )
        fi
    fi
    [ -n "$results" ] && results=$(echo "$results" | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' | LC_ALL=C sed $'s/\xe2\x94[\x80-\xbf]//g; s/\xe2\x95[\x80-\xbf]//g; s/\xe2\x96[\x80-\xbf]//g; s/\xe2\x97[\x80-\xbf]//g')

    local count=0
    while IFS='|' read -r source section snippet; do
        [ -z "$source" ] && continue
        (( count++ ))
        local label
        case "$source" in
            ref) label="Reference" ;;
            journal) label="Journal" ;;
            george) label="Project" ;;
            user_pref) label="User Pref" ;;
            doc:*) label="${source#doc:}" ;;
            *) label="$source" ;;
        esac
        printf "  %b[%s]%b %b%s%b\n" "$C_CYAN" "$label" "$C_RESET" "$C_WHITE" "$section" "$C_RESET"
        snippet="${snippet//>>>/$(printf '%b' "$C_YELLOW")}"
        snippet="${snippet//<<</$(printf '%b' "$C_RESET")}"
        printf "    %s\n\n" "$snippet"
    done <<< "$results"
    [ "$count" -eq 0 ] && ui_dim "  No results for: $query"
}

recall_search_context() {
    local query="$1" limit="${2:-3}" max_chars="${3:-300}"
    recall_available || return 1

    local _rsc_cache_key="recall:ctx:${query}:${limit}:${max_chars}"
    if declare -f cache_get &>/dev/null; then
        local _rsc_cached
        if _rsc_cached=$(cache_get "$_rsc_cache_key" "recall"); then
            printf '%s\n' "$_rsc_cached"
            return 0
        fi
    fi

    recall_ensure_indexed >/dev/null 2>&1
    local safe_query; safe_query=$(_recall_sanitize_query "$query")
    [ -z "$safe_query" ] && return 0

    local _rsc_json=""
    if [[ "${_RECALL_JSON1_OK:-0}" == "1" ]]; then
        local json_query="SELECT json_group_array(json_object('src', source, 'sec', section, 'body', body)) FROM (SELECT c.source, c.section, CASE WHEN length(c.content) <= $max_chars THEN c.content ELSE substr(c.content, 1, $max_chars) || '...' END AS body FROM chunks_fts JOIN chunks c ON chunks_fts.rowid = c.id WHERE chunks_fts MATCH"
        _rsc_json=$(sqlite3 "$RECALL_DB" "$json_query '$safe_query' ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0) LIMIT $limit);")
        if [ -z "$_rsc_json" ] || [ "$_rsc_json" = "[]" ] || [ "$_rsc_json" = "null" ]; then
            local or_query_j; or_query_j=$(_recall_sanitize_query "$query" "OR")
            if [ -n "$or_query_j" ]; then
                _rsc_json=$(sqlite3 "$RECALL_DB" "$json_query '$or_query_j' ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0) LIMIT $limit);")
            fi
        fi
    else
        local sel_query="SELECT c.source, c.section, CASE WHEN length(c.content) <= $max_chars THEN c.content ELSE substr(c.content, 1, $max_chars) || '...' END AS body FROM chunks_fts JOIN chunks c ON chunks_fts.rowid = c.id WHERE chunks_fts MATCH"
        local results; results=$(sqlite3 -separator '|' "$RECALL_DB" "$sel_query '$safe_query' ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0) LIMIT $limit;")
        if [ -z "$results" ]; then
            local or_query; or_query=$(_recall_sanitize_query "$query" "OR")
            [ -n "$or_query" ] && results=$(sqlite3 -separator '|' "$RECALL_DB" "$sel_query '$or_query' ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0) LIMIT $limit;")
        fi
        if [ -n "$results" ]; then
            local _rsc_arr='[]'
            while IFS='|' read -r source section body; do
                [ -z "$source" ] && continue
                _rsc_arr=$(jq -c --arg src "$source" --arg sec "$section" --arg body "$body" '. + [{"src":$src,"sec":$sec,"body":$body}]' <<< "$_rsc_arr")
            done <<< "$results"
            _rsc_json="$_rsc_arr"
        fi
    fi

    [ -z "$_rsc_json" ] || [ "$_rsc_json" = "[]" ] || [ "$_rsc_json" = "null" ] || [ "$_rsc_json" = "[null]" ] && return 0

    _rsc_json=$(echo "$_rsc_json" | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' | LC_ALL=C sed $'s/\xe2\x94[\x80-\xbf]//g; s/\xe2\x95[\x80-\xbf]//g; s/\xe2\x96[\x80-\xbf]//g; s/\xe2\x97[\x80-\xbf]//g')
    [ -z "$_rsc_json" ] || [ "$_rsc_json" = "[]" ] && return 0

    if declare -f cache_put &>/dev/null; then
        cache_put "$_rsc_cache_key" "recall" "$_rsc_json"
    fi
    printf '%s\n' "$_rsc_json"
}

recall_self_review() {
    if ! recall_available; then
        [ -f "$LODGE_DIR/docs/RECALL_INDEX.md" ] && head -120 "$LODGE_DIR/docs/RECALL_INDEX.md"
        return
    fi
    recall_ensure_indexed
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
        [ -f "$LODGE_DIR/docs/RECALL_INDEX.md" ] && head -120 "$LODGE_DIR/docs/RECALL_INDEX.md"
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

recall_stats() {
    if ! recall_available || [ ! -f "$RECALL_DB" ]; then
        ui_warn "Recall not initialized. Run: /recall reindex"
        return 1
    fi
    local total_chunks db_size_kb sources
    total_chunks=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks;" 2>/dev/null || echo "0")
    db_size_kb=$(du -k "$RECALL_DB" 2>/dev/null | cut -f1 || echo "0")
    sources=$(sqlite3 -separator '|' "$RECALL_DB" "SELECT source, COUNT(*) FROM chunks GROUP BY source ORDER BY source;" 2>/dev/null)
    printf "  %bRecall Knowledge Base%b\n" "$C_BOLD" "$C_RESET"
    printf "  Database: %s (%d KB)\n" "$RECALL_DB" "$db_size_kb"
    printf "  Total chunks: %s\n\n" "$total_chunks"
    while IFS='|' read -r src cnt; do
        [ -z "$src" ] && continue
        printf "    %-12s %b%d chunks%b\n" "$src" "$C_CYAN" "$cnt" "$C_RESET"
    done <<< "$sources"
}

recall_clear() {
    rm -f "$RECALL_DB" "$RECALL_MTIME_FILE"
    ui_ok "Recall database cleared"
}

_recall_extract_text() {
    local filepath="$1" ext="${filepath##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        md|txt|sh|bash|py|rs|js|ts|toml|yaml|yml|json|cfg|ini|conf|csv|log|c|h|cpp|hpp|java|go|rb|lua|sql|r|pl)
            cat "$filepath" ;;
        pdf)
            if command -v pdftotext &>/dev/null; then
                pdftotext -layout "$filepath" - 2>/dev/null
            else
                ui_err "pdftotext not found. Install: apt install poppler-utils"
                return 1
            fi ;;
        html|htm)
            sed 's/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&nbsp;/ /g; s/&quot;/"/g' "$filepath" ;;
        doc|docx|odt)
            if command -v pandoc &>/dev/null; then
                pandoc -t plain "$filepath" 2>/dev/null
            elif command -v libreoffice &>/dev/null; then
                libreoffice --headless --convert-to txt --outdir "${TMPDIR:-/tmp}" "$filepath" 2>/dev/null
                local txt_file="${TMPDIR:-/tmp}/$(basename "${filepath%.*}").txt"
                [ -f "$txt_file" ] && cat "$txt_file" && rm -f "$txt_file"
            else
                ui_err "Cannot extract from .$ext — install pandoc or libreoffice"
                return 1
            fi ;;
        *)
            if file "$filepath" 2>/dev/null | grep -qi text; then
                cat "$filepath"
            else
                ui_err "Unsupported file type: .$ext"
                return 1
            fi ;;
    esac
}

_recall_chunk_text() {
    local filepath="$1" source_name="$2"
    local text; text=$(_recall_extract_text "$filepath") || return 1
    [ -z "$text" ] && return 1
    local ext="${filepath##*.}"; ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    if [[ "$ext" == "md" ]]; then
        _recall_chunk_markdown "$filepath"
        return
    fi
    echo "$text" | awk -v name="$source_name" '
    BEGIN { chunk = ""; section = "(content)"; chunk_num = 0 }
    /^$/ {
        if (length(chunk) > 400) {
            chunk_num++; section_label = sprintf("Part %d", chunk_num)
            gsub(/\t/, " ", chunk); gsub(/\n/, " ", chunk); sub(/^ +/, "", chunk)
            if (length(chunk) > 0) printf "%s\t%s\n", section_label, chunk
            chunk = ""
        } else chunk = chunk "\n"
        next
    }
    {
        if ($0 ~ /^[A-Z].*:$/ || $0 ~ /^#+/) {
            if (length(chunk) > 50) {
                chunk_num++; section_label = sprintf("Part %d", chunk_num)
                gsub(/\t/, " ", chunk); gsub(/\n/, " ", chunk); sub(/^ +/, "", chunk)
                if (length(chunk) > 0) printf "%s\t%s\n", section_label, chunk
                chunk = ""
            }
            section = $0; sub(/^#+ */, "", section); sub(/:$/, "", section)
        }
        chunk = chunk "\n" $0
    }
    END {
        if (length(chunk) > 0) {
            chunk_num++; section_label = (chunk_num == 1) ? "(content)" : sprintf("Part %d", chunk_num)
            gsub(/\t/, " ", chunk); gsub(/\n/, " ", chunk); sub(/^ +/, "", chunk)
            if (length(chunk) > 0) printf "%s\t%s\n", section_label, chunk
        }
    }'
}

recall_ingest() {
    local label="$1" filepath="$2"
    [ -z "$label" ] || [ -z "$filepath" ] && { ui_err "Usage: recall_ingest <label> <filepath>"; return 1; }
    [ -f "$filepath" ] || { ui_err "File not found: $filepath"; return 1; }
    recall_init || return 1

    local source="doc:${label}"
    local now; now=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source = '${source//\'/\'\'}';"

    local _ic_tmp; _ic_tmp=$(mktemp "${TMPDIR:-/tmp}/recall-chunk.XXXXXX")
    local ext="${filepath##*.}"; ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    if [[ "$ext" == "md" ]]; then
        _recall_chunk_markdown "$filepath" > "$_ic_tmp"
    else
        _recall_chunk_text "$filepath" "$label" > "$_ic_tmp"
    fi

    local sql_batch="BEGIN TRANSACTION;" count=0
    while IFS=$'\t' read -r section content; do
        [ -z "$content" ] && continue
        local s_esc="${section//\'/\'\'}" c_esc="${content//\'/\'\'}" fp_esc="${filepath//\'/\'\'}"
        sql_batch+="INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES ('${source//\'/\'\'}', '$s_esc', '$c_esc', '$fp_esc', '$now');"
        (( count++ ))
    done < "$_ic_tmp"
    rm -f "$_ic_tmp"
    sql_batch+="COMMIT;"
    [ "$count" -gt 0 ] && sqlite3 "$RECALL_DB" "$sql_batch" 2>/dev/null
    return 0
}

recall_list_documents() {
    [ -f "$RECALL_DB" ] || { ui_dim "  No documents ingested yet."; return; }
    local docs; docs=$(sqlite3 -separator '|' "$RECALL_DB" "SELECT source, COUNT(*), filepath FROM chunks WHERE source LIKE 'doc:%' GROUP BY source ORDER BY source;")
    [ -z "$docs" ] && { ui_dim "  No documents ingested yet."; return; }
    while IFS='|' read -r source count filepath; do
        [ -z "$source" ] && continue
        local label="${source#doc:}"
        printf "  %b●%b %-25s %b%d chunks%b  %b(%s)%b\n" "$C_GREEN" "$C_RESET" "$label" "$C_DIM" "$count" "$C_RESET" "$C_DIM" "$filepath" "$C_RESET"
    done <<< "$docs"
}

recall_remove_document() {
    local label="$1"; [ -z "$label" ] && { ui_err "Usage: recall_remove_document <label>"; return 1; }
    local source="doc:${label}"
    local count; count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='${source//\'/\'\'}';" 2>/dev/null)
    [ "${count:-0}" -eq 0 ] && { ui_err "Document '$label' not found in index"; return 1; }
    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source='${source//\'/\'\'}';"
    return 0
}

recall_ingest_with_summary() {
    local label="$1" filepath="$2"
    [ -z "$label" ] || [ -z "$filepath" ] && { ui_err "Usage: recall_ingest_with_summary <label> <filepath>"; return 1; }
    [ -f "$filepath" ] || { ui_err "File not found: $filepath"; return 1; }
    recall_ingest "$label" "$filepath" || return 1

    if declare -f llm_generate &>/dev/null; then
        local text; text=$(_recall_extract_text "$filepath") || return 0
        text=$(echo "$text" | head -c 2000)
        local summary; ui_spinner_start "Summarizing"
        local LLM_SCENARIO=tool
        summary=$(llm_generate "Summarize this document in 3-5 bullet points. Be concise:\n\n$text" "You are a concise summarizer. Output only bullet points." 256 "$LLM_BUDGET_TOOL" 2>/dev/null)
        ui_spinner_stop
        if [ -n "$summary" ] && [[ "$summary" != ERROR* ]]; then
            local source="doc:${label}" now; now=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
            local s_esc="${summary//\'/\'\'}" fp_esc="${filepath//\'/\'\'}"
            sqlite3 "$RECALL_DB" "INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES ('${source//\'/\'\'}', 'Summary', '$s_esc', '$fp_esc', '$now');"
        fi
    fi
    return 0
}

RECALL_USER_PREF_MAX="${RECALL_USER_PREF_MAX:-20}"

recall_log_user_input() {
    local question="$1" answer="$2"
    [ -z "$question" ] || [ -z "$answer" ] && return 1
    recall_init || return 1
    local now; now=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    local q_safe="${question//\'/\'\'}" a_safe="${answer//\'/\'\'}"
    sqlite3 "$RECALL_DB" "INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES ('user_pref', '$q_safe', '$a_safe', 'agent:/ask', '$now');"
    local count; count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref';" 2>/dev/null || echo "0")
    if [ "$count" -gt "$RECALL_USER_PREF_MAX" ]; then
        sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE id IN (SELECT id FROM chunks WHERE source='user_pref' ORDER BY id ASC LIMIT $(( count - RECALL_USER_PREF_MAX )));"
    fi
    return 0
}

recall_list_user_prefs() {
    [ -f "$RECALL_DB" ] || { ui_dim "  No user preferences stored yet."; return; }
    local prefs; prefs=$(sqlite3 -separator '|' "$RECALL_DB" "SELECT section, content, indexed_at FROM chunks WHERE source='user_pref' ORDER BY indexed_at DESC;")
    [ -z "$prefs" ] && { ui_dim "  No user preferences stored yet."; return; }
    local count=0
    while IFS='|' read -r question answer ts; do
        [ -z "$question" ] && continue
        (( count++ ))
        printf "  %b%s%b\n    Q: %s\n    A: %s\n\n" "$C_CYAN" "$ts" "$C_RESET" "$question" "$answer"
    done <<< "$prefs"
    printf "  %b%d user preference(s) stored%b\n" "$C_DIM" "$count" "$C_RESET"
}

recall_prune_user_prefs() {
    local cutoff="$1"
    [ -z "$cutoff" ] && { ui_err "Usage: recall_prune_user_prefs <YYYY-MM-DD | days>"; return 1; }
    [ ! -f "$RECALL_DB" ] && { ui_dim "No recall database."; return 0; }
    if [[ "$cutoff" =~ ^[0-9]+$ ]]; then
        cutoff=$(date -d "-${cutoff} days" '+%Y-%m-%d' 2>/dev/null || date -v-${cutoff}d '+%Y-%m-%d' 2>/dev/null)
        [ -z "$cutoff" ] && { ui_err "Could not compute date offset"; return 1; }
    fi
    [[ "$cutoff" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { ui_err "Invalid date format. Use YYYY-MM-DD or a number of days."; return 1; }
    local before_count; before_count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref' AND indexed_at < '${cutoff}T00:00:00';" 2>/dev/null || echo "0")
    [ "$before_count" -eq 0 ] && { ui_dim "  No user preferences before $cutoff"; return 0; }
    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source='user_pref' AND indexed_at < '${cutoff}T00:00:00';"
    ui_ok "Pruned $before_count user preference(s) before $cutoff"
    return 0
}

recall_compact_user_prefs() {
    [ ! -f "$RECALL_DB" ] && { ui_dim "No recall database."; return 0; }
    local count; count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref';" 2>/dev/null || echo "0")
    [ "$count" -le 1 ] && { ui_dim "  Only $count preference(s) — nothing to compact."; return 0; }
    local entries; entries=$(sqlite3 -separator '|' "$RECALL_DB" "SELECT indexed_at, section, content FROM chunks WHERE source='user_pref' ORDER BY indexed_at ASC;")
    local qa_text=""
    while IFS='|' read -r ts question answer; do
        [ -n "$question" ] && qa_text+="[${ts}] Q: ${question}\nA: ${answer}\n"
    done <<< "$entries"
    if ! declare -f llm_generate &>/dev/null; then
        ui_warn "LLM not available — cannot compact. Use /recall prune <date> instead."
        return 1
    fi
    ui_spinner_start "Compacting preferences"
    local LLM_SCENARIO=tool summary
    summary=$(llm_generate "Below are user preference Q&A entries collected over time (oldest first). Consolidate them into a brief preference profile. Rules: If contradictory preferences exist, KEEP THE MOST RECENT one and note the change. Group related preferences. Use \"Prefers X\" format, one per line. Keep it under 15 lines. No preamble.\n\n$qa_text" "You are a preference consolidator. Output only the consolidated profile." 512 "$LLM_BUDGET_TOOL" 2>/dev/null)
    ui_spinner_stop
    [ -z "$summary" ] || [[ "$summary" == ERROR* ]] && { ui_err "LLM summarization failed — preferences unchanged."; return 1; }
    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source='user_pref';"
    local now; now=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    local s_safe="${summary//\'/\'\'}"
    sqlite3 "$RECALL_DB" "INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES ('user_pref', 'User Preference Profile (compacted)', '$s_safe', 'agent:/ask', '$now');"
    ui_ok "Compacted $count preferences into 1 summary entry"
    printf "\n%s\n" "$summary"
    return 0
}

recall_clear_user_prefs() {
    [ ! -f "$RECALL_DB" ] && return 0
    local count; count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref';" 2>/dev/null || echo "0")
    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source='user_pref';"
    ui_ok "Cleared $count user preference(s)"
}

recall_user_pref_count() {
    [ ! -f "$RECALL_DB" ] && { echo "0"; return; }
    sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref';" 2>/dev/null || echo "0"
}

_recall_now_iso() {
    date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S'
}

_recall_sql_escape() {
    local value="$1"; printf '%s' "${value//\'/\'\'}"
}

_recall_sanitize_int() {
    local value="$1"; [[ "$value" =~ ^-?[0-9]+$ ]] && echo "$value" || echo "0"
}

_recall_sanitize_bool_int() {
    local value="${1:-0}"
    case "${value,,}" in 1|true|yes|y) echo "1" ;; *) echo "0" ;; esac
}

_recall_redact_text() {
    local value="$1"
    value=$(printf '%s' "$value" | sed -E -e 's#https?://[^[:space:]]+#[REDACTED_ENDPOINT]#g' -e 's#\b(Bearer|bearer)[[:space:]]+[A-Za-z0-9._-]+#\1 [REDACTED_TOKEN]#g' -e 's#\b(sk|tok|token|api[_-]?key|apikey|authorization|auth)[=:][^[:space:]]+#\1=[REDACTED]#gi')
    [ "${#value}" -gt 256 ] && value="${value:0:256}...[truncated]"
    printf '%s' "$value"
}

_recall_redact_model_name() {
    local model="$1"
    [[ "$model" == */* ]] && model="${model##*/}"
    [[ "$model" == *:* ]] && model="${model##*:}"
    _recall_redact_text "$model"
}

_recall_redact_backend() {
    local backend="${1,,}"
    case "$backend" in
        *llama*|*ollama*|*local*|*inference*server*) echo "local_inference" ;;
        *openai*|*anthropic*|*google*|*cohere*|*groq*|*mistral*|*together*|*azure*|*vertex*) echo "external_provider" ;;
        "") echo "" ;;
        *) _recall_redact_text "$backend" ;;
    esac
}

_recall_allowed_infeasibility_class() { case "$1" in none|blocked_by_capability|blocked_by_policy) return 0 ;; *) return 1 ;; esac; }
_recall_allowed_limitation_action() { case "$1" in RESCOPE|ALT_PATH|TERMINATE|"") return 0 ;; *) return 1 ;; esac; }
_recall_allowed_tool_exposure_phase() { case "$1" in A|B|C|"") return 0 ;; *) return 1 ;; esac; }
_recall_allowed_evaluator_mode() { case "$1" in normal|degraded) return 0 ;; *) return 1 ;; esac; }
_recall_allowed_task_outcome_class() { case "$1" in successful|blocked_by_capability|blocked_by_policy|user_terminated|"") return 0 ;; *) return 1 ;; esac; }

recall_trace_record_allowlisted() {
    local task_boundary="$1" payload_json="${2:-"{}"}"
    [ -n "$task_boundary" ] || return 1
    recall_init || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local parsed
    parsed=$(jq -r '[
        (.infeasibility_class // ""),
        (.infeasibility_reason_code // ""),
        (.limitation_action // ""),
        (.tool_exposure_phase // ""),
        (.evaluator_mode // "normal"),
        (.evaluator_failure_reason // ""),
        (.task_outcome_class // ""),
        (.redacted_diagnostic // "")
    ] | @tsv' <<< "$payload_json" 2>/dev/null) || return 1

    local ic irc la tep em efr toc rd
    IFS=$'\t' read -r ic irc la tep em efr toc rd <<< "$parsed"

    _recall_allowed_infeasibility_class "$ic" || ic="none"
    _recall_allowed_limitation_action "$la" || la=""
    _recall_allowed_tool_exposure_phase "$tep" || tep=""
    _recall_allowed_evaluator_mode "$em" || em="normal"
    _recall_allowed_task_outcome_class "$toc" || toc=""

    irc=$(_recall_redact_text "$irc")
    efr=$(_recall_redact_text "$efr")
    rd=$(_recall_redact_text "$rd")
    local now; now=$(_recall_now_iso)

    sqlite3 "$RECALL_DB" "INSERT INTO routing_eval_trace (
        task_boundary, recorded_at, infeasibility_class, infeasibility_reason_code,
        limitation_action, tool_exposure_phase, evaluator_mode, evaluator_failure_reason,
        task_outcome_class, redacted_diagnostic
    ) VALUES (
        '$(_recall_sql_escape "$task_boundary")', '$(_recall_sql_escape "$now")',
        '$(_recall_sql_escape "$ic")', '$(_recall_sql_escape "$irc")',
        '$(_recall_sql_escape "$la")', '$(_recall_sql_escape "$tep")',
        '$(_recall_sql_escape "$em")', '$(_recall_sql_escape "$efr")',
        '$(_recall_sql_escape "$toc")', '$(_recall_sql_escape "$rd")'
    );"

    jq -cn \
        --arg ts "$now" --arg task_boundary "$task_boundary" --arg infeasibility_class "$ic" \
        --arg infeasibility_reason_code "$irc" --arg limitation_action "$la" \
        --arg tool_exposure_phase "$tep" --arg evaluator_mode "$em" \
        --arg evaluator_failure_reason "$efr" --arg task_outcome_class "$toc" \
        --arg redacted_diagnostic "$rd" \
        '{ts:$ts, task_boundary:$task_boundary, infeasibility_class:$infeasibility_class, infeasibility_reason_code:$infeasibility_reason_code, limitation_action:$limitation_action, tool_exposure_phase:$tool_exposure_phase, evaluator_mode:$evaluator_mode, evaluator_failure_reason:$evaluator_failure_reason, task_outcome_class:$task_outcome_class, redacted_diagnostic:$redacted_diagnostic}'
}

recall_record_terminal_outcome() {
    local task_boundary="$1" outcome_class="$2" reason_code="${3:-}"
    [ -n "$task_boundary" ] || return 1
    _recall_allowed_task_outcome_class "$outcome_class" || return 1
    [ -n "$outcome_class" ] || return 1
    recall_init || return 1

    local existing
    existing=$(sqlite3 "$RECALL_DB" "SELECT outcome_class FROM task_terminal_outcomes WHERE task_boundary='$(_recall_sql_escape "$task_boundary")' LIMIT 1;" 2>/dev/null)
    if [ -n "$existing" ]; then
        [ "$existing" = "$outcome_class" ] && return 0
        return 1
    fi

    reason_code=$(_recall_redact_text "$reason_code")
    local now; now=$(_recall_now_iso)
    sqlite3 "$RECALL_DB" "INSERT INTO task_terminal_outcomes (task_boundary, outcome_class, reason_code, recorded_at) VALUES ('$(_recall_sql_escape "$task_boundary")', '$(_recall_sql_escape "$outcome_class")', '$(_recall_sql_escape "$reason_code")', '$(_recall_sql_escape "$now")');"
}

recall_get_terminal_outcome() {
    local task_boundary="$1"
    [ -n "$task_boundary" ] && [ -f "$RECALL_DB" ] && command -v jq >/dev/null 2>&1 || return 1
    local row
    row=$(sqlite3 -separator '|' "$RECALL_DB" "SELECT task_boundary, outcome_class, reason_code, recorded_at FROM task_terminal_outcomes WHERE task_boundary='$(_recall_sql_escape "$task_boundary")' LIMIT 1;" 2>/dev/null)
    [ -n "$row" ] || return 1
    local b o r t
    IFS='|' read -r b o r t <<< "$row"
    jq -cn --arg task_boundary "$b" --arg outcome_class "$o" --arg reason_code "$r" --arg recorded_at "$t" \
        '{task_boundary:$task_boundary, outcome_class:$outcome_class, reason_code:$reason_code, recorded_at:$recorded_at}'
}

recall_record_evaluator_snapshot() {
    local task_boundary="$1" payload_json="${2:-"{}"}"
    [ -n "$task_boundary" ] || return 1
    recall_init || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local parsed
    parsed=$(jq -r '[
        (.evaluator_mode // "normal"),
        (.failure_reason // .evaluator_failure_reason // ""),
        (.backend // ""),
        (.scenario // ""),
        ((.token_budget // 0) | tonumber? // 0),
        ((.output_length // 0) | tonumber? // 0),
        (.parse_mode // ""),
        (.grammar_mode // ""),
        (.selected_model // ""),
        (.grammar_schema_name // ""),
        ((.prompt_char_count // 0) | tonumber? // 0),
        ((.system_char_count // 0) | tonumber? // 0),
        ((.estimated_token_pressure // 0) | tonumber? // 0),
        ((.http_status // 0) | tonumber? // 0),
        (if ((.received_sse_data // .received_sse_frames // 0) | tostring | test("^(1|true|yes|y)$"; "i")) then 1 else 0 end),
        (if ((.received_non_sse_json_error // 0) | tostring | test("^(1|true|yes|y)$"; "i")) then 1 else 0 end),
        ((.curl_exit_code // .curl_code // 0) | tonumber? // 0),
        (.envelope_kind // ""),
        (.envelope_error_code // ""),
        (.envelope_error_message // ""),
        (.diagnostic_code // "")
    ] | @tsv' <<< "$payload_json" 2>/dev/null) || return 1

    local em efr be sc tb ol pm gm sm gsn pcc scc etp hs rsd rne cec ek eec eem dc
    IFS=$'\t' read -r em efr be sc tb ol pm gm sm gsn pcc scc etp hs rsd rne cec ek eec eem dc <<< "$parsed"

    _recall_allowed_evaluator_mode "$em" || em="normal"
    be=$(_recall_redact_backend "$be"); sc=$(_recall_redact_text "$sc"); efr=$(_recall_redact_text "$efr")
    pm=$(_recall_redact_text "$pm"); gm=$(_recall_redact_text "$gm"); sm=$(_recall_redact_model_name "$sm")
    gsn=$(_recall_redact_text "$gsn"); ek=$(_recall_redact_text "$ek"); eec=$(_recall_redact_text "$eec")
    eem=$(_recall_redact_text "$eem"); dc=$(_recall_redact_text "$dc")
    tb=$(_recall_sanitize_int "$tb"); ol=$(_recall_sanitize_int "$ol")
    pcc=$(_recall_sanitize_int "$pcc"); scc=$(_recall_sanitize_int "$scc")
    etp=$(_recall_sanitize_int "$etp"); hs=$(_recall_sanitize_int "$hs")
    rsd=$(_recall_sanitize_bool_int "$rsd"); rne=$(_recall_sanitize_bool_int "$rne")
    cec=$(_recall_sanitize_int "$cec")
    local now; now=$(_recall_now_iso)

    sqlite3 "$RECALL_DB" "INSERT INTO evaluator_diag_snapshots (
        task_boundary, recorded_at, evaluator_mode, evaluator_failure_reason,
        backend, scenario, token_budget, output_length, parse_mode, grammar_mode,
        selected_model, grammar_schema_name, prompt_char_count, system_char_count,
        estimated_token_pressure, http_status, received_sse_data,
        received_non_sse_json_error, curl_exit_code, envelope_kind,
        envelope_error_code, envelope_error_message, diagnostic_code
    ) VALUES (
        '$(_recall_sql_escape "$task_boundary")', '$(_recall_sql_escape "$now")', '$(_recall_sql_escape "$em")',
        '$(_recall_sql_escape "$efr")', '$(_recall_sql_escape "$be")', '$(_recall_sql_escape "$sc")',
        $tb, $ol, '$(_recall_sql_escape "$pm")', '$(_recall_sql_escape "$gm")', '$(_recall_sql_escape "$sm")',
        '$(_recall_sql_escape "$gsn")', $pcc, $scc, $etp, $hs, $rsd, $rne, $cec,
        '$(_recall_sql_escape "$ek")', '$(_recall_sql_escape "$eec")', '$(_recall_sql_escape "$eem")',
        '$(_recall_sql_escape "$dc")'
    );"

    jq -cn \
        --arg ts "$now" --arg task_boundary "$task_boundary" --arg evaluator_mode "$em" \
        --arg evaluator_failure_reason "$efr" --arg backend "$be" --arg scenario "$sc" \
        --arg parse_mode "$pm" --arg grammar_mode "$gm" --arg selected_model "$sm" \
        --arg grammar_schema_name "$gsn" --arg envelope_kind "$ek" --arg envelope_error_code "$eec" \
        --arg envelope_error_message "$eem" --arg diagnostic_code "$dc" \
        --argjson token_budget "$tb" --argjson output_length "$ol" --argjson prompt_char_count "$pcc" \
        --argjson system_char_count "$scc" --argjson estimated_token_pressure "$etp" --argjson http_status "$hs" \
        --argjson received_sse_data "$rsd" --argjson received_non_sse_json_error "$rne" --argjson curl_exit_code "$cec" \
        '{ts:$ts, task_boundary:$task_boundary, evaluator_mode:$evaluator_mode, evaluator_failure_reason:$evaluator_failure_reason, backend:$backend, scenario:$scenario, token_budget:$token_budget, output_length:$output_length, parse_mode:$parse_mode, grammar_mode:$grammar_mode, selected_model:$selected_model, grammar_schema_name:$grammar_schema_name, prompt_char_count:$prompt_char_count, system_char_count:$system_char_count, estimated_token_pressure:$estimated_token_pressure, http_status:$http_status, received_sse_data:$received_sse_data, received_non_sse_json_error:$received_non_sse_json_error, curl_exit_code:$curl_exit_code, envelope_kind:$envelope_kind, envelope_error_code:$envelope_error_code, envelope_error_message:$envelope_error_message, diagnostic_code:$diagnostic_code}'
}

recall_schema_compat_set() {
    local s="$1" st="${2:-unknown}" sok="${3:-0}" fok="${4:-0}" rr="${5:-0}" dc="${6:-}" n="${7:-}"
    [ -n "$s" ] || return 1
    recall_init || return 1
    case "$st" in compatible|incompatible|unknown) ;; *) st="unknown" ;; esac
    sok=$(_recall_sanitize_bool_int "$sok"); fok=$(_recall_sanitize_bool_int "$fok")
    rr=$(_recall_sanitize_int "$rr"); [ "$rr" -lt 0 ] && rr=0
    dc=$(_recall_redact_text "$dc"); n=$(_recall_redact_text "$n")
    local ca; ca=$(_recall_now_iso)
    sqlite3 "$RECALL_DB" "INSERT INTO grammar_schema_compatibility (schema_name, status, stream_true_ok, stream_false_ok, repeated_runs, diagnostic_code, notes, checked_at) VALUES ('$(_recall_sql_escape "$s")', '$st', $sok, $fok, $rr, '$(_recall_sql_escape "$dc")', '$(_recall_sql_escape "$n")', '$ca') ON CONFLICT(schema_name) DO UPDATE SET status=excluded.status, stream_true_ok=excluded.stream_true_ok, stream_false_ok=excluded.stream_false_ok, repeated_runs=excluded.repeated_runs, diagnostic_code=excluded.diagnostic_code, notes=excluded.notes, checked_at=excluded.checked_at;"
}

recall_schema_compat_get() {
    local schema_name="$1"
    [ -n "$schema_name" ] && [ -f "$RECALL_DB" ] && command -v jq >/dev/null 2>&1 || return 1
    local row
    row=$(sqlite3 -separator '|' "$RECALL_DB" "SELECT schema_name, status, stream_true_ok, stream_false_ok, repeated_runs, diagnostic_code, notes, checked_at FROM grammar_schema_compatibility WHERE schema_name='$(_recall_sql_escape "$schema_name")' LIMIT 1;" 2>/dev/null)
    [ -n "$row" ] || return 1
    local s status st sf rr dc notes checked
    IFS='|' read -r s status st sf rr dc notes checked <<< "$row"
    jq -cn --arg schema_name "$s" --arg status "$status" --arg diagnostic_code "$dc" --arg notes "$notes" --arg checked_at "$checked" --argjson stream_true_ok "$st" --argjson stream_false_ok "$sf" --argjson repeated_runs "$rr" \
        '{schema_name:$schema_name, status:$status, stream_true_ok:$stream_true_ok, stream_false_ok:$stream_false_ok, repeated_runs:$repeated_runs, diagnostic_code:$diagnostic_code, notes:$notes, checked_at:$checked_at}'
}

recall_schema_compat_map_json() {
    [ -f "$RECALL_DB" ] || { echo '{}'; return 0; }
    command -v jq >/dev/null 2>&1 || return 1
    sqlite3 -separator '|' "$RECALL_DB" "SELECT schema_name, status, stream_true_ok, stream_false_ok, repeated_runs, diagnostic_code, notes, checked_at FROM grammar_schema_compatibility ORDER BY schema_name ASC;" 2>/dev/null | jq -Rsc '
        split("\n") | map(select(length > 0) | split("|")) | map({
            key: .[0],
            value: {
                status: .[1], stream_true_ok: (.[2]|tonumber), stream_false_ok: (.[3]|tonumber),
                repeated_runs: (.[4]|tonumber), diagnostic_code: .[5], notes: .[6], checked_at: .[7]
            }
        }) | from_entries // {}
    ' 2>/dev/null || echo '{}'
}

recall_archive_milestone() {
    local title="$1" content="$2" fpath="${3:-}"
    recall_available || return 0
    recall_init || return 0
    local now; now=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    local t_esc="${title//\'/\'\'}" c_esc="${content//\'/\'\'}" fp_esc="${fpath//\'/\'\'}"
    local dup; dup=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='milestone_archive' AND section='$t_esc' AND content='$c_esc';" 2>/dev/null || echo "0")
    [ "$dup" -gt 0 ] 2>/dev/null && return 0
    sqlite3 "$RECALL_DB" "INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES ('milestone_archive', '$t_esc', '$c_esc', '$fp_esc', '$now');"
}

recall_search_milestones() {
    local query="$1" limit="${2:-3}" max_chars="${3:-400}"
    recall_available || return 0
    [ -f "$RECALL_DB" ] || return 0
    local safe_query; safe_query=$(_recall_sanitize_query "$query")
    [ -z "$safe_query" ] && return 0

    if [[ "${_RECALL_JSON1_OK:-0}" == "1" ]]; then
        local json_sql="SELECT json_group_array(json_object('title', section, 'summary', body, 'ts', indexed_at)) FROM (SELECT c.section, CASE WHEN length(c.content) <= $max_chars THEN c.content ELSE substr(c.content, 1, $max_chars) || '...' END AS body, c.indexed_at FROM chunks_fts JOIN chunks c ON chunks_fts.rowid = c.id WHERE c.source = 'milestone_archive' AND chunks_fts MATCH"
        local _rm_json
        _rm_json=$(sqlite3 "$RECALL_DB" "$json_sql '$safe_query' ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0) LIMIT $limit);")
        if [ -z "$_rm_json" ] || [ "$_rm_json" = "[]" ] || [ "$_rm_json" = "null" ]; then
            local or_query; or_query=$(_recall_sanitize_query "$query" "OR")
            [ -n "$or_query" ] && _rm_json=$(sqlite3 "$RECALL_DB" "$json_sql '$or_query' ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0) LIMIT $limit);")
        fi
        [ -n "$_rm_json" ] && [ "$_rm_json" != "null" ] && printf '%s\n' "$_rm_json" && return 0
    fi

    local query_sql="SELECT c.section, CASE WHEN length(c.content) <= $max_chars THEN c.content ELSE substr(c.content, 1, $max_chars) || '...' END AS body, c.indexed_at FROM chunks_fts JOIN chunks c ON chunks_fts.rowid = c.id WHERE c.source = 'milestone_archive' AND chunks_fts MATCH"
    local results
    results=$(sqlite3 -separator '|' "$RECALL_DB" "$query_sql '$safe_query' ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0) LIMIT $limit;")
    if [ -z "$results" ]; then
        local or_q; or_q=$(_recall_sanitize_query "$query" "OR")
        [ -n "$or_q" ] && results=$(sqlite3 -separator '|' "$RECALL_DB" "$query_sql '$or_q' ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0) LIMIT $limit;")
    fi
    [ -z "$results" ] && return 0

    local first=1 _rm_json='['
    while IFS='|' read -r sec body ts; do
        [ -z "$sec" ] && continue
        [ "$first" -eq 0 ] && _rm_json+=","
        first=0
        _rm_json+=$(jq -cn --arg t "$sec" --arg s "$body" --arg ts "$ts" '{title:$t, summary:$s, ts:$ts}')
    done <<< "$results"
    printf '%s]\n' "$_rm_json"
}

recall_symbol_sync() {
    local target_file="$1"
    [ ! -f "$target_file" ] && return 1
    recall_init || return 1
    local abs_path; abs_path=$(readlink -f "$target_file" 2>/dev/null || echo "$target_file")
    local cur_mtime; cur_mtime=$(stat -c %Y "$abs_path" 2>/dev/null || stat -f %m "$abs_path" 2>/dev/null || echo 0)
    local last_mtime; last_mtime=$(sqlite3 "$RECALL_DB" "SELECT mtime FROM code_symbols WHERE file_path = '$abs_path' LIMIT 1;" 2>/dev/null || true)
    [ -n "$last_mtime" ] && [ "$last_mtime" -eq "$cur_mtime" ] && return 0

    source "$LODGE_DIR/lib/tools/treesitter.sh" 2>/dev/null || true
    local symbols; symbols=$(treesitter_extract_symbols "$abs_path")
    [ -z "$symbols" ] && return 0

    sqlite3 "$RECALL_DB" "DELETE FROM code_symbols WHERE file_path = '$abs_path';" 2>/dev/null || true
    local sql_batch="BEGIN TRANSACTION;"
    while IFS=$'\t' read -r sym_name start_l end_l sym_lang; do
        [ -z "$sym_name" ] && continue
        local s_esc="${sym_name//\'/\'\'}"
        sql_batch+="INSERT INTO code_symbols (symbol_name, file_path, start_line, end_line, lang, mtime) VALUES ('$s_esc', '$abs_path', $start_l, $end_l, '$sym_lang', $cur_mtime);"
    done <<< "$symbols"
    sql_batch+="COMMIT;"
    sqlite3 "$RECALL_DB" "$sql_batch" 2>/dev/null || true
}

recall_symbol_get() {
    local symbol_name="$1" target_file="${2:-}"
    [ -z "$symbol_name" ] && { echo "Error: symbol_name required"; return 1; }
    recall_init || return 1
    [ -n "$target_file" ] && [ -f "$target_file" ] && recall_symbol_sync "$target_file"

    local query="SELECT file_path, start_line, end_line FROM code_symbols WHERE symbol_name = '$symbol_name'"
    if [ -n "$target_file" ]; then
        local abs_path; abs_path=$(readlink -f "$target_file" 2>/dev/null || echo "$target_file")
        query+=" AND file_path = '$abs_path'"
    fi
    query+=" LIMIT 1;"

    local res; res=$(sqlite3 -separator '|' "$RECALL_DB" "$query" 2>/dev/null)
    if [ -z "$res" ]; then
        if [ -n "$target_file" ] && [ -f "$target_file" ]; then
            source "$LODGE_DIR/lib/tools/treesitter.sh" 2>/dev/null || true
            treesitter_symbol "$target_file" "$symbol_name"
            return $?
        fi
        echo "Symbol '$symbol_name' not found in index."
        return 1
    fi

    local fpath start_l end_l
    IFS='|' read -r fpath start_l end_l <<< "$res"
    [ ! -f "$fpath" ] && { echo "File '$fpath' not found on disk."; return 1; }
    sed -n "${start_l},${end_l}p" "$fpath"
}
