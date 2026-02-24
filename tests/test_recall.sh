#!/bin/bash
# ── Tests: lib/recall.sh — FTS5 Knowledge Base ─────────────
source "$(dirname "$0")/framework.sh"

# Need ui.sh for recall.sh to source
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null
source "$LODGE_DIR/lib/recall.sh"

test_start "lib/recall.sh — FTS5 Recall System"

# ── Pre-check: sqlite3 + FTS5 availability ────────────────────
_HAS_SQLITE=0
if command -v sqlite3 &>/dev/null; then
    _tdb="/tmp/.recall_fts5_check_$$.db"
    if sqlite3 "$_tdb" "CREATE VIRTUAL TABLE _t USING fts5(c); DROP TABLE _t;" 2>/dev/null; then
        _HAS_SQLITE=1
    fi
    rm -f "$_tdb"
fi

# ── Setup / Teardown ──────────────────────────────────────────
_setup_recall() {
    export TMPDIR_RECALL
    TMPDIR_RECALL=$(mktemp -d)
    export GEORGE_DIR="$TMPDIR_RECALL/.george"
    export RECALL_DB="$GEORGE_DIR/recall.db"
    export RECALL_MTIME_FILE="$GEORGE_DIR/.recall_mtimes"
    export LODGE_DIR="$TMPDIR_RECALL/lodge"
    mkdir -p "$LODGE_DIR"
}

_teardown_recall() {
    rm -rf "$TMPDIR_RECALL"
}

_create_sample_readme() {
    cat > "$LODGE_DIR/README.md" << 'EOF'
# George — Blue Lodge

A coding agent powered by local LLMs.

## Quick Start

```bash
lodge                  # Interactive mode
lodge /init myapp rust # Scaffold a Rust project
lodge "add tests"      # Give it a task
```

## Architecture

George uses Ollama with Qwen3-4B. Everything runs locally.

## Slash Commands

| Command | Description |
|---------|-------------|
| /help   | Show commands |
| /init   | New project |
| /fix    | Fix errors |

## Sandboxes

Lightweight project isolation using proot or directory fallback.

## Security

HMAC-SHA256 signing, AES-256-CBC encryption, command allowlist.

## Containers

Full Linux environments via proot-distro. Ubuntu, Kali, Alpine.
EOF
}

_create_sample_soul() {
    cat > "$LODGE_DIR/soul.md" << 'EOF'
# Soul of George

George is named for Brother George Washington.
He has the wit of Benjamin Franklin.
He follows the moral philosophy of Adam Smith.
EOF
}

_create_sample_journal() {
    cat > "$LODGE_DIR/journal.md" << 'EOF'
# Journal of George

## 2026-02-22 10:00 — reflection

Today I learned about sandboxes and proot isolation.

## 2026-02-22 11:00 — learning

Discovered that SQLite FTS5 uses BM25 ranking for full-text search.
EOF
}

# ── Availability ──────────────────────────────────────────────
describe "recall_available"

  it "returns true when sqlite3 is installed" && {
    if command -v sqlite3 &>/dev/null; then
        recall_available
        assert_ok $?
    else
        skip "sqlite3 not installed"
    fi
  }

# ── Initialization ────────────────────────────────────────────
describe "recall_init"

  it "creates the database file" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    assert_file_exists "$RECALL_DB"
    _teardown_recall
    fi
  }

  it "creates chunks table" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    local tables
    tables=$(sqlite3 "$RECALL_DB" ".tables" 2>/dev/null)
    assert_contains "$tables" "chunks"
    _teardown_recall
    fi
  }

  it "creates FTS virtual table" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    local tables
    tables=$(sqlite3 "$RECALL_DB" ".tables" 2>/dev/null)
    assert_contains "$tables" "chunks_fts"
    _teardown_recall
    fi
  }

  it "is idempotent" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    recall_init
    assert_ok $?
    _teardown_recall
    fi
  }

# ── Markdown Chunking ─────────────────────────────────────────
describe "_recall_chunk_markdown"

  it "splits on ## headers" && {
    _setup_recall
    _create_sample_readme
    local count
    count=$(_recall_chunk_markdown "$LODGE_DIR/README.md" | tr '\0' '\n' | grep -c $'\t')
    assert_gt "$count" 4
    _teardown_recall
  }

  it "extracts section titles" && {
    _setup_recall
    _create_sample_readme
    local sections
    sections=$(_recall_chunk_markdown "$LODGE_DIR/README.md" | tr '\0' '\n' | cut -f1)
    assert_contains "$sections" "Quick Start"
    assert_contains "$sections" "Architecture"
    assert_contains "$sections" "Sandboxes"
    _teardown_recall
  }

  it "returns empty for nonexistent file" && {
    _setup_recall
    local out
    out=$(_recall_chunk_markdown "/nonexistent/file.md" 2>/dev/null)
    assert_empty "$out"
    _teardown_recall
  }

# ── File Indexing ─────────────────────────────────────────────
describe "recall_index_file"

  it "indexes chunks into the database" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_init
    recall_index_file "readme" "$LODGE_DIR/README.md"
    local count
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='readme';" 2>/dev/null)
    assert_gt "$count" 0
    _teardown_recall
    fi
  }

  it "replaces old entries on re-index" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_init
    recall_index_file "readme" "$LODGE_DIR/README.md"
    local count1
    count1=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='readme';" 2>/dev/null)
    recall_index_file "readme" "$LODGE_DIR/README.md"
    local count2
    count2=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='readme';" 2>/dev/null)
    assert_eq "$count1" "$count2"
    _teardown_recall
    fi
  }

  it "stores the correct source label" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_soul
    recall_init
    recall_index_file "soul" "$LODGE_DIR/soul.md"
    local sources
    sources=$(sqlite3 "$RECALL_DB" "SELECT DISTINCT source FROM chunks;" 2>/dev/null)
    assert_contains "$sources" "soul"
    _teardown_recall
    fi
  }

# ── Full Reindex ──────────────────────────────────────────────
describe "recall_reindex"

  it "indexes all available sources" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    _create_sample_soul
    _create_sample_journal
    recall_reindex
    local sources
    sources=$(sqlite3 "$RECALL_DB" "SELECT DISTINCT source FROM chunks ORDER BY source;" 2>/dev/null)
    assert_contains "$sources" "readme"
    assert_contains "$sources" "soul"
    assert_contains "$sources" "journal"
    _teardown_recall
    fi
  }

  it "indexes crypto wallet guide when present" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    mkdir -p "$LODGE_DIR/docs"
    cat > "$LODGE_DIR/docs/CRYPTO_WALLETS.md" << 'CRYPTOEOF'
# George's Crypto Wallet Guide

## Bitcoin (BTC)
Bitcoin uses mempool.space for balance queries.

## Solana (SOL)
Solana uses JSON-RPC for balance queries.
CRYPTOEOF
    recall_reindex
    _sources=$(sqlite3 "$RECALL_DB" "SELECT DISTINCT source FROM chunks ORDER BY source;" 2>/dev/null)
    assert_contains "$_sources" "crypto"
    _teardown_recall
    fi
  }

  it "creates mtime tracking file" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    assert_file_exists "$RECALL_MTIME_FILE"
    _teardown_recall
    fi
  }

# ── Needs Reindex Detection ──────────────────────────────────
describe "recall_needs_reindex"

  it "returns true when no DB exists" && {
    _setup_recall
    _create_sample_readme
    recall_needs_reindex
    assert_ok $?
    _teardown_recall
  }

  it "returns false after fresh index" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    recall_needs_reindex
    assert_fail $?
    _teardown_recall
    fi
  }

  it "returns true after file modification" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    sleep 1
    echo "## New Section" >> "$LODGE_DIR/README.md"
    recall_needs_reindex
    assert_ok $?
    _teardown_recall
    fi
  }

# ── FTS5 Search ──────────────────────────────────────────────
describe "recall_search"

  it "finds matching sections by keyword" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    _create_sample_soul
    recall_reindex
    local results
    results=$(recall_search "sandboxes proot isolation" 5)
    assert_not_empty "$results"
    assert_contains "$results" "Sandboxes"
    _teardown_recall
    fi
  }

  it "finds content across different sources" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    _create_sample_soul
    _create_sample_journal
    recall_reindex
    local results
    results=$(recall_search "George Washington" 5)
    assert_not_empty "$results"
    _teardown_recall
    fi
  }

  it "returns empty for unmatched query" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local results
    results=$(recall_search "xyzzynonexistentterm" 5)
    assert_empty "$results"
    _teardown_recall
    fi
  }

  it "respects the limit parameter" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local results
    results=$(recall_search "George" 2)
    local count
    count=$(echo "$results" | grep -c '|' || echo "0")
    [[ "$count" -le 2 ]]
    assert_ok $?
    _teardown_recall
    fi
  }

# ── Search for LLM Context ───────────────────────────────────
describe "recall_search_context"

  it "returns plain text suitable for prompts" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local ctx
    ctx=$(recall_search_context "architecture Ollama" 3)
    assert_not_empty "$ctx"
    assert_contains "$ctx" "[readme:"
    _teardown_recall
    fi
  }

  it "returns empty for no matches" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local ctx
    ctx=$(recall_search_context "xyzzynonexistent" 3)
    assert_empty "$ctx"
    _teardown_recall
    fi
  }

# ── Self Review ───────────────────────────────────────────────
describe "recall_self_review"

  it "returns README capability sections" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local review
    review=$(recall_self_review)
    assert_not_empty "$review"
    assert_contains "$review" "CAPABILITIES"
    _teardown_recall
    fi
  }

  it "includes slash commands section" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local review
    review=$(recall_self_review)
    assert_contains "$review" "Slash Commands"
    _teardown_recall
    fi
  }

# ── Statistics ────────────────────────────────────────────────
describe "recall_stats"

  it "shows chunk counts" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    _create_sample_soul
    recall_reindex
    local stats
    stats=$(recall_stats)
    assert_contains "$stats" "Total chunks"
    assert_contains "$stats" "readme"
    _teardown_recall
    fi
  }

# ── Clear ─────────────────────────────────────────────────────
describe "recall_clear"

  it "removes the database" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    assert_file_exists "$RECALL_DB"
    recall_clear
    assert_file_not_exists "$RECALL_DB"
    _teardown_recall
    fi
  }

  it "removes the mtime file" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    recall_clear
    assert_file_not_exists "$RECALL_MTIME_FILE"
    _teardown_recall
    fi
  }

# ── FTS5 special character handling ───────────────────────────
describe "FTS5 special character escaping"

  it "handles dots in query (recall.db)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    # Should not produce a runtime error — may return empty but must not crash
    local results
    results=$(recall_search "recall.db" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles leading dots (.george)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local results
    results=$(recall_search ".george" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles forward slashes (/recall)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local results
    results=$(recall_search "/recall" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles at-signs (test@email.com)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local results
    results=$(recall_search "test@email.com" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles hashes and dollar signs (#heading \$var)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local results
    results=$(recall_search '#heading $variable' 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles commas, ampersands, and angle brackets" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local results
    results=$(recall_search "a,b & c<d>e" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles FTS5 operators as literal words (AND OR NOT)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local results
    results=$(recall_search "AND OR NOT" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles all FTS5 operators (*+^~:(){}[])" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local results
    results=$(recall_search 'test*+^~:(){}[]!' 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles pipe and backslash (a|b a\\b)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    local results
    results=$(recall_search 'a|b a\b' 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles pure punctuation query gracefully" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    # Pure punctuation should sanitize to empty and return 0, not crash
    local results
    results=$(recall_search "...///###" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "_recall_sanitize_query is defined" && {
    declare -f _recall_sanitize_query &>/dev/null
    assert_ok $?
  }

  it "_recall_sanitize_query strips dots and slashes" && {
    local result
    result=$(_recall_sanitize_query "recall.db")
    assert_not_contains "$result" "."
    assert_contains "$result" "recall"
    assert_contains "$result" "db"
  }

  it "_recall_sanitize_query wraps words in quotes" && {
    local result
    result=$(_recall_sanitize_query "hello world")
    assert_contains "$result" '"hello"'
    assert_contains "$result" '"world"'
  }

  it "_recall_sanitize_query OR mode joins terms with OR" && {
    local result
    result=$(_recall_sanitize_query "hello world" "OR")
    assert_contains "$result" "OR"
  }

# ── ensure_indexed ────────────────────────────────────────────
describe "recall_ensure_indexed"

  it "indexes when DB missing" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_ensure_indexed
    assert_file_exists "$RECALL_DB"
    local count
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks;" 2>/dev/null)
    assert_gt "$count" 0
    _teardown_recall
    fi
  }

  it "skips when already indexed and unchanged" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_readme
    recall_reindex
    recall_ensure_indexed
    assert_ok $?
    _teardown_recall
    fi
  }

test_end
