#!/bin/bash
# ── George: Recall System (FTS5 Knowledge Base) ────────────────
# Lightweight search over George's own documentation and memory.
# Uses SQLite FTS5 for BM25-ranked full-text search.
#
# Indexed sources:
#   readme       — README.md (George's capabilities & architecture)
#   soul         — soul.md (personality & ethics)
#   crypto       — docs/CRYPTO_WALLETS.md (cryptocurrency guide)
#   tuning       — docs/TUNING.md (token & performance tuning)
#   sandboxes    — docs/SANDBOXES.md (sandbox & isolation guide)
#   vault        — docs/SECRETS_VAULT.md (encrypted secrets vault)
#   recall_guide — docs/RECALL.md (recall system documentation)
#   social_bots  — docs/SOCIAL_BOTS.md (social media API setup)
#   pgp_signing  — docs/PGP_SIGNING.md (PGP message signing)
#   slash_cmds   — docs/SLASH_COMMANDS.md (slash command self-awareness)
#   journal      — journal.md (living memory)
#   claude       — CLAUDE.md (current project memory)
#
# Overhead: ~100-200KB on disk, <1ms per query, 0 RAM.
# No network, no embedding model, no Python required.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
GEORGE_DIR="${GEORGE_DIR:-$HOME/.george}"
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
    local test_db="/tmp/.recall_fts5_test_$$.db"
    if sqlite3 "$test_db" "CREATE VIRTUAL TABLE _t USING fts5(c); DROP TABLE _t;" 2>/dev/null; then
        rm -f "$test_db"
        _RECALL_FTS5_OK=1
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
    source TEXT NOT NULL,       -- readme, soul, journal, claude
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
                printf "%s\t%s\000", section, content
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
                printf "%s\t%s\000", section, content
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
    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source = '$source';"

    # Chunk and index
    local count=0
    while IFS=$'\t' read -r -d '' section content; do
        [ -z "$content" ] && continue
        # Escape single quotes for SQL
        section="${section//\'/\'\'}"
        content="${content//\'/\'\'}"
        filepath_safe="${filepath//\'/\'\'}"

        sqlite3 "$RECALL_DB" \
            "INSERT INTO chunks (source, section, content, filepath, indexed_at)
             VALUES ('$source', '$section', '$content', '$filepath_safe', '$now');"
        (( count++ ))
    done < <(_recall_chunk_markdown "$filepath")

    return 0
}

# ── Check if reindex is needed ─────────────────────────────────
# Compares file mtimes against last indexed mtimes.
_recall_file_mtime() {
    local filepath="$1"
    [ -f "$filepath" ] || echo "0"
    stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null || echo "0"
}

recall_needs_reindex() {
    [ ! -f "$RECALL_DB" ] && return 0  # no DB yet → needs index

    local needs=1  # 1 = false (doesn't need)

    local sources=("readme:$LODGE_DIR/README.md" "soul:$LODGE_DIR/soul.md")
    [ -f "$LODGE_DIR/docs/CRYPTO_WALLETS.md" ] && sources+=("crypto:$LODGE_DIR/docs/CRYPTO_WALLETS.md")
    [ -f "$LODGE_DIR/docs/TUNING.md" ] && sources+=("tuning:$LODGE_DIR/docs/TUNING.md")
    [ -f "$LODGE_DIR/docs/SANDBOXES.md" ] && sources+=("sandboxes:$LODGE_DIR/docs/SANDBOXES.md")
    [ -f "$LODGE_DIR/docs/SECRETS_VAULT.md" ] && sources+=("vault:$LODGE_DIR/docs/SECRETS_VAULT.md")
    [ -f "$LODGE_DIR/docs/RECALL.md" ] && sources+=("recall_guide:$LODGE_DIR/docs/RECALL.md")
    [ -f "$LODGE_DIR/docs/SOCIAL_BOTS.md" ] && sources+=("social_bots:$LODGE_DIR/docs/SOCIAL_BOTS.md")
    [ -f "$LODGE_DIR/docs/PGP_SIGNING.md" ] && sources+=("pgp_signing:$LODGE_DIR/docs/PGP_SIGNING.md")
    [ -f "$LODGE_DIR/docs/SLASH_COMMANDS.md" ] && sources+=("slash_cmds:$LODGE_DIR/docs/SLASH_COMMANDS.md")
    [ -f "$LODGE_DIR/journal.md" ] && sources+=("journal:$LODGE_DIR/journal.md")
    [ -f "./CLAUDE.md" ] && sources+=("claude:$PWD/CLAUDE.md")

    for entry in "${sources[@]}"; do
        local source="${entry%%:*}"
        local filepath="${entry#*:}"
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
    done

    return $needs
}

# ── Save mtimes after indexing ─────────────────────────────────
_recall_save_mtimes() {
    local sources=("readme:$LODGE_DIR/README.md" "soul:$LODGE_DIR/soul.md")
    [ -f "$LODGE_DIR/docs/CRYPTO_WALLETS.md" ] && sources+=("crypto:$LODGE_DIR/docs/CRYPTO_WALLETS.md")
    [ -f "$LODGE_DIR/docs/TUNING.md" ] && sources+=("tuning:$LODGE_DIR/docs/TUNING.md")
    [ -f "$LODGE_DIR/docs/SANDBOXES.md" ] && sources+=("sandboxes:$LODGE_DIR/docs/SANDBOXES.md")
    [ -f "$LODGE_DIR/docs/SECRETS_VAULT.md" ] && sources+=("vault:$LODGE_DIR/docs/SECRETS_VAULT.md")
    [ -f "$LODGE_DIR/docs/RECALL.md" ] && sources+=("recall_guide:$LODGE_DIR/docs/RECALL.md")
    [ -f "$LODGE_DIR/docs/SOCIAL_BOTS.md" ] && sources+=("social_bots:$LODGE_DIR/docs/SOCIAL_BOTS.md")
    [ -f "$LODGE_DIR/docs/PGP_SIGNING.md" ] && sources+=("pgp_signing:$LODGE_DIR/docs/PGP_SIGNING.md")
    [ -f "$LODGE_DIR/docs/SLASH_COMMANDS.md" ] && sources+=("slash_cmds:$LODGE_DIR/docs/SLASH_COMMANDS.md")
    [ -f "$LODGE_DIR/journal.md" ] && sources+=("journal:$LODGE_DIR/journal.md")
    [ -f "./CLAUDE.md" ] && sources+=("claude:$PWD/CLAUDE.md")

    > "$RECALL_MTIME_FILE"
    for entry in "${sources[@]}"; do
        local source="${entry%%:*}"
        local filepath="${entry#*:}"
        [ -f "$filepath" ] || continue
        local mtime
        mtime=$(_recall_file_mtime "$filepath")
        echo "${source}=${mtime}" >> "$RECALL_MTIME_FILE"
    done
}

# ── Full reindex of all knowledge sources ─────────────────────
recall_reindex() {
    recall_init || return 1

    local total=0

    # Core docs
    if [ -f "$LODGE_DIR/README.md" ]; then
        recall_index_file "readme" "$LODGE_DIR/README.md"
        (( total++ ))
    fi
    if [ -f "$LODGE_DIR/soul.md" ]; then
        recall_index_file "soul" "$LODGE_DIR/soul.md"
        (( total++ ))
    fi

    # Crypto wallet guide
    if [ -f "$LODGE_DIR/docs/CRYPTO_WALLETS.md" ]; then
        recall_index_file "crypto" "$LODGE_DIR/docs/CRYPTO_WALLETS.md"
        (( total++ ))
    fi

    # Token tuning guide
    if [ -f "$LODGE_DIR/docs/TUNING.md" ]; then
        recall_index_file "tuning" "$LODGE_DIR/docs/TUNING.md"
        (( total++ ))
    fi

    # Sandboxes guide
    if [ -f "$LODGE_DIR/docs/SANDBOXES.md" ]; then
        recall_index_file "sandboxes" "$LODGE_DIR/docs/SANDBOXES.md"
        (( total++ ))
    fi

    # Secrets vault guide
    if [ -f "$LODGE_DIR/docs/SECRETS_VAULT.md" ]; then
        recall_index_file "vault" "$LODGE_DIR/docs/SECRETS_VAULT.md"
        (( total++ ))
    fi

    # Recall guide
    if [ -f "$LODGE_DIR/docs/RECALL.md" ]; then
        recall_index_file "recall_guide" "$LODGE_DIR/docs/RECALL.md"
        (( total++ ))
    fi

    # Social bots guide
    if [ -f "$LODGE_DIR/docs/SOCIAL_BOTS.md" ]; then
        recall_index_file "social_bots" "$LODGE_DIR/docs/SOCIAL_BOTS.md"
        (( total++ ))
    fi

    # PGP signing guide
    if [ -f "$LODGE_DIR/docs/PGP_SIGNING.md" ]; then
        recall_index_file "pgp_signing" "$LODGE_DIR/docs/PGP_SIGNING.md"
        (( total++ ))
    fi

    # Slash command self-awareness guide
    if [ -f "$LODGE_DIR/docs/SLASH_COMMANDS.md" ]; then
        recall_index_file "slash_cmds" "$LODGE_DIR/docs/SLASH_COMMANDS.md"
        (( total++ ))
    fi

    # Living memory
    if [ -f "$LODGE_DIR/journal.md" ]; then
        recall_index_file "journal" "$LODGE_DIR/journal.md"
        (( total++ ))
    fi

    # Current project memory
    if [ -f "./CLAUDE.md" ]; then
        recall_index_file "claude" "$PWD/CLAUDE.md"
        (( total++ ))
    fi

    _recall_save_mtimes

    return 0
}

# ── Ensure index is fresh ─────────────────────────────────────
recall_ensure_indexed() {
    if recall_needs_reindex; then
        recall_reindex
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

    recall_ensure_indexed

    # Escape the query for FTS5
    local safe_query
    safe_query="${query//\"/\"\"}"
    # Strip ALL FTS5 special characters that cause syntax errors
    safe_query="${safe_query//\*/}"
    safe_query="${safe_query//\(/}"
    safe_query="${safe_query//\)/}"
    safe_query="${safe_query//:/}"
    safe_query="${safe_query//\?/}"
    safe_query="${safe_query//!/}"
    safe_query="${safe_query//+/}"
    safe_query="${safe_query//^/}"
    safe_query="${safe_query//~/}"
    safe_query="${safe_query//\{/}"
    safe_query="${safe_query//\}/}"
    safe_query="${safe_query//\[/}"
    safe_query="${safe_query//\]/}"
    safe_query="${safe_query//\;/}"
    # Collapse multiple spaces and trim
    safe_query=$(echo "$safe_query" | sed 's/  */ /g; s/^ *//; s/ *$//')
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
        # Try with OR between words for broader matching
        local or_query
        or_query=$(echo "$query" | sed 's/ / OR /g')
        results=$(recall_search "$or_query" "$limit")
    fi

    if [ -z "$results" ]; then
        ui_dim "  No results for: $query"
        return 0
    fi

    local count=0
    while IFS='|' read -r source section snippet; do
        [ -z "$source" ] && continue
        (( count++ ))

        # Source label
        local label
        case "$source" in
            readme)     label="README" ;;
            soul)       label="Soul" ;;
            journal)    label="Journal" ;;
            claude)     label="Project" ;;
            crypto)     label="Crypto" ;;
            tuning)     label="Tuning" ;;
            sandboxes)  label="Sandboxes" ;;
            vault)       label="Vault" ;;
            recall_guide) label="Recall" ;;
            social_bots)  label="Social Bots" ;;
            pgp_signing)  label="PGP" ;;
            slash_cmds)   label="Commands" ;;
            *)           label="$source" ;;
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
recall_search_context() {
    local query="$1"
    local limit="${2:-3}"

    if ! recall_available; then
        return 1
    fi

    local results
    results=$(recall_search "$query" "$limit")

    if [ -z "$results" ]; then
        local or_query
        or_query=$(echo "$query" | sed 's/ / OR /g')
        results=$(recall_search "$or_query" "$limit")
    fi

    [ -z "$results" ] && return 0

    local output=""
    while IFS='|' read -r source section snippet; do
        [ -z "$source" ] && continue
        output+="[$source: $section] $snippet
"
    done <<< "$results"

    echo "$output"
}

# ── Get George's own capabilities summary ─────────────────────
# Reads and returns specific README sections relevant to self-knowledge.
recall_self_review() {
    if ! recall_available; then
        # Fallback: just read the README directly
        if [ -f "$LODGE_DIR/README.md" ]; then
            head -120 "$LODGE_DIR/README.md"
        fi
        return
    fi

    recall_ensure_indexed

    # Pull key sections George would want to know about himself
    local sections
    sections=$(sqlite3 -separator '|' "$RECALL_DB" <<'SQL'
SELECT section, content FROM chunks
WHERE source = 'readme'
AND (
    section LIKE '%Slash Command%'
    OR section LIKE '%Architecture%'
    OR section LIKE '%Security%'
    OR section LIKE '%Sandbox%'
    OR section LIKE '%Container%'
    OR section LIKE '%Phone%'
    OR section LIKE '%Memory%'
    OR section LIKE '%Quick Start%'
    OR section LIKE '%Why%'
)
ORDER BY id;
SQL
    )

    if [ -z "$sections" ]; then
        # Fallback
        head -120 "$LODGE_DIR/README.md"
        return
    fi

    echo "=== GEORGE'S CAPABILITIES (from README.md) ==="
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
                libreoffice --headless --convert-to txt --outdir /tmp "$filepath" 2>/dev/null
                local txt_file="/tmp/$(basename "${filepath%.*}").txt"
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
                printf "%s\t%s\000", section_label, chunk
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
                    printf "%s\t%s\000", section_label, chunk
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
                printf "%s\t%s\000", section_label, chunk
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
        while IFS=$'\t' read -r -d '' section content; do
            [ -z "$content" ] && continue
            section="${section//\'/\'\'}"
            content="${content//\'/\'\'}"
            local fp_safe="${filepath//\'/\'\'}"
            sqlite3 "$RECALL_DB" \
                "INSERT INTO chunks (source, section, content, filepath, indexed_at)
                 VALUES ('$source', '$section', '$content', '$fp_safe', '$now');"
            (( count++ ))
        done < <(_recall_chunk_markdown "$filepath")
    else
        # Use generic text chunker
        while IFS=$'\t' read -r -d '' section content; do
            [ -z "$content" ] && continue
            section="${section//\'/\'\'}"
            content="${content//\'/\'\'}"
            local fp_safe="${filepath//\'/\'\'}"
            sqlite3 "$RECALL_DB" \
                "INSERT INTO chunks (source, section, content, filepath, indexed_at)
                 VALUES ('$source', '$section', '$content', '$fp_safe', '$now');"
            (( count++ ))
        done < <(_recall_chunk_text "$filepath" "$label")
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
        summary=$(llm_generate "Summarize this document in 3-5 bullet points. Be concise:

$text" "You are a concise summarizer. Output only bullet points." 256 2>/dev/null)
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
                 VALUES ('$source', 'Summary', '$summary', '$fp_safe', '$now');"
        fi
    fi

    return 0
}
