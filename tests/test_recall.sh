#!/bin/bash
# ── Tests: lib/recall.sh — FTS5 Knowledge Base ─────────────
source "$(dirname "$0")/framework.sh"

# Need ui.sh for recall.sh to source
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null
source "$LODGE_DIR/lib/recall.sh"

test_start "lib/recall.sh — FTS5 Recall System"

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

# Create a sample README for testing
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
    _setup_recall
    recall_init
    assert_file_exists "$RECALL_DB"
    _teardown_recall
  }

  it "creates chunks table" && {
    _setup_recall
    recall_init
    local tables
    tables=$(sqlite3 "$RECALL_DB" ".tables" 2>/dev/null)
    assert_contains "$tables" "chunks"
    _teardown_recall
  }

  it "creates FTS virtual table" && {
    _setup_recall
    recall_init
    local tables
    tables=$(sqlite3 "$RECALL_DB" ".tables" 2>/dev/null)
    assert_contains "$tables" "chunks_fts"
    _teardown_recall
  }

  it "is idempotent" && {
    _setup_recall
    recall_init
    recall_init  # second call should not error
    assert_ok $?
    _teardown_recall
  }

# ── Markdown Chunking ─────────────────────────────────────────
describe "_recall_chunk_markdown"

  it "splits on ## headers" && {
    _setup_recall
    _create_sample_readme
    local count
    count=$(_recall_chunk_markdown "$LODGE_DIR/README.md" | tr '\0' '\n' | grep -c $'\t')
    # Should have: preamble + Quick Start + Architecture + Slash Commands + Sandboxes + Security + Containers
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
    _setup_recall
    _create_sample_readme
    recall_init
    recall_index_file "readme" "$LODGE_DIR/README.md"
    local count
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='readme';" 2>/dev/null)
    assert_gt "$count" 0
    _teardown_recall
  }

  it "replaces old entries on re-index" && {
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
  }

  it "stores the correct source label" && {
    _setup_recall
    _create_sample_soul
    recall_init
    recall_index_file "soul" "$LODGE_DIR/soul.md"
    local sources
    sources=$(sqlite3 "$RECALL_DB" "SELECT DISTINCT source FROM chunks;" 2>/dev/null)
    assert_contains "$sources" "soul"
    _teardown_recall
  }

# ── Full Reindex ──────────────────────────────────────────────
describe "recall_reindex"

  it "indexes all available sources" && {
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
  }

  it "indexes crypto wallet guide when present" && {
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
  }

  it "creates mtime tracking file" && {
    _setup_recall
    _create_sample_readme
    recall_reindex
    assert_file_exists "$RECALL_MTIME_FILE"
    _teardown_recall
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
    _setup_recall
    _create_sample_readme
    recall_reindex
    recall_needs_reindex
    assert_fail $?
    _teardown_recall
  }

  it "returns true after file modification" && {
    _setup_recall
    _create_sample_readme
    recall_reindex
    sleep 1
    echo "## New Section" >> "$LODGE_DIR/README.md"
    recall_needs_reindex
    assert_ok $?
    _teardown_recall
  }

# ── FTS5 Search ──────────────────────────────────────────────
describe "recall_search"

  it "finds matching sections by keyword" && {
    _setup_recall
    _create_sample_readme
    _create_sample_soul
    recall_reindex
    local results
    results=$(recall_search "sandboxes proot isolation" 5)
    assert_not_empty "$results"
    assert_contains "$results" "Sandboxes"
    _teardown_recall
  }

  it "finds content across different sources" && {
    _setup_recall
    _create_sample_readme
    _create_sample_soul
    _create_sample_journal
    recall_reindex
    local results
    results=$(recall_search "George Washington" 5)
    assert_not_empty "$results"
    _teardown_recall
  }

  it "returns empty for unmatched query" && {
    _setup_recall
    _create_sample_readme
    recall_reindex
    local results
    results=$(recall_search "xyzzynonexistentterm" 5)
    assert_empty "$results"
    _teardown_recall
  }

  it "respects the limit parameter" && {
    _setup_recall
    _create_sample_readme
    recall_reindex
    local results
    results=$(recall_search "George" 2)
    local count
    count=$(echo "$results" | grep -c '|' || echo "0")
    # Should be at most 2 results
    [[ "$count" -le 2 ]]
    assert_ok $?
    _teardown_recall
  }

# ── Search for LLM Context ───────────────────────────────────
describe "recall_search_context"

  it "returns plain text suitable for prompts" && {
    _setup_recall
    _create_sample_readme
    recall_reindex
    local ctx
    ctx=$(recall_search_context "architecture Ollama" 3)
    assert_not_empty "$ctx"
    # Should contain source labels in brackets
    assert_contains "$ctx" "[readme:"
    _teardown_recall
  }

  it "returns empty for no matches" && {
    _setup_recall
    _create_sample_readme
    recall_reindex
    local ctx
    ctx=$(recall_search_context "xyzzynonexistent" 3)
    assert_empty "$ctx"
    _teardown_recall
  }

# ── Self Review ───────────────────────────────────────────────
describe "recall_self_review"

  it "returns README capability sections" && {
    _setup_recall
    _create_sample_readme
    recall_reindex
    local review
    review=$(recall_self_review)
    assert_not_empty "$review"
    assert_contains "$review" "CAPABILITIES"
    _teardown_recall
  }

  it "includes slash commands section" && {
    _setup_recall
    _create_sample_readme
    recall_reindex
    local review
    review=$(recall_self_review)
    assert_contains "$review" "Slash Commands"
    _teardown_recall
  }

# ── Statistics ────────────────────────────────────────────────
describe "recall_stats"

  it "shows chunk counts" && {
    _setup_recall
    _create_sample_readme
    _create_sample_soul
    recall_reindex
    local stats
    stats=$(recall_stats)
    assert_contains "$stats" "Total chunks"
    assert_contains "$stats" "readme"
    _teardown_recall
  }

# ── Clear ─────────────────────────────────────────────────────
describe "recall_clear"

  it "removes the database" && {
    _setup_recall
    _create_sample_readme
    recall_reindex
    assert_file_exists "$RECALL_DB"
    recall_clear
    assert_file_not_exists "$RECALL_DB"
    _teardown_recall
  }

  it "removes the mtime file" && {
    _setup_recall
    _create_sample_readme
    recall_reindex
    recall_clear
    assert_file_not_exists "$RECALL_MTIME_FILE"
    _teardown_recall
  }

# ── ensure_indexed ────────────────────────────────────────────
describe "recall_ensure_indexed"

  it "indexes when DB missing" && {
    _setup_recall
    _create_sample_readme
    recall_ensure_indexed
    assert_file_exists "$RECALL_DB"
    local count
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks;" 2>/dev/null)
    assert_gt "$count" 0
    _teardown_recall
  }

  it "skips when already indexed and unchanged" && {
    _setup_recall
    _create_sample_readme
    recall_reindex
    # Second call should be fast (no-op)
    recall_ensure_indexed
    assert_ok $?
    _teardown_recall
  }

test_end
