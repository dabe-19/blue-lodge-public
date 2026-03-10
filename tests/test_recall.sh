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

_create_sample_ref() {
    mkdir -p "$LODGE_DIR/docs"
    cat > "$LODGE_DIR/docs/RECALL_INDEX.md" << 'EOF'
# George — FTS5 Recall Index

## Quick Start Init Lodge

```bash
lodge                  # Interactive mode
lodge /init myapp rust # Scaffold a Rust project
lodge "add tests"      # Give it a task
```

## Architecture Model Ollama Qwen

George uses Ollama with Qwen3-4B. Everything runs locally on ARM.

## Slash Commands Help Init Fix

| Command | Description |
|---------|-------------|
| /help   | Show commands |
| /init   | New project |
| /fix    | Fix errors |

## Sandbox Build Test Run Proot

Lightweight project isolation using proot or directory fallback.
Commands: /sandbox create, /sandbox list, /sandbox enter

## Security HMAC AES Signing Encryption

HMAC-SHA256 signing, AES-256-CBC encryption, command allowlist.

## Container Proot Distro Ubuntu Alpine Kali

Full Linux environments via proot-distro. Ubuntu, Kali, Alpine.

## Discord Post Channel Message

/social post discord <channel> <message>
/social discord dm <user> <message>
Fallback: webhook if no channel match.

## Crypto Wallet Bitcoin BTC Balance Address

/wallet btc balance — check BTC balance
/wallet btc address — show receive address
Uses mempool.space API.

## Email Send SMTP Gmail

/email send <to> <subject> <body>
email ONLY — not for social media posting.

## Git Setup SSH Clone Push

/git setup — configure SSH keys + signing
/git clone <url> — clone repository

## Memory Loop Read Remember Respond

Read→Remember→Respond cycle.
journal write — persist to memory.

## Mastodon Instance Token Post

Multi-instance support.
instances configured via /api keys set.

## Phone SMS Call Notification

/phone sms, /phone call
Twilio-based integration.

## Agent Limits Configuration Parameters

Max steps, timeout, budget configuration.

## George Washington Identity Soul

George is named for Brother George Washington.
He has the wit of Benjamin Franklin.
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
    tables=$(sqlite3 "$RECALL_DB" ".tables" 2>/dev/null)
    assert_contains "$tables" "chunks"
    _teardown_recall
    fi
  }

  it "creates FTS virtual table" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
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
    count=$(_recall_chunk_markdown "$LODGE_DIR/README.md" | tr '\0' '\n' | grep -c $'\t')
    assert_gt "$count" 4
    _teardown_recall
  }

  it "extracts section titles" && {
    _setup_recall
    _create_sample_readme
    sections=$(_recall_chunk_markdown "$LODGE_DIR/README.md" | tr '\0' '\n' | cut -f1)
    assert_contains "$sections" "Quick Start"
    assert_contains "$sections" "Architecture"
    assert_contains "$sections" "Sandboxes"
    _teardown_recall
  }

  it "returns empty for nonexistent file" && {
    _setup_recall
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
    count1=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='readme';" 2>/dev/null)
    recall_index_file "readme" "$LODGE_DIR/README.md"
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
    _create_sample_ref
    _create_sample_journal
    recall_reindex
    sources=$(sqlite3 "$RECALL_DB" "SELECT DISTINCT source FROM chunks ORDER BY source;" 2>/dev/null)
    assert_contains "$sources" "ref"
    assert_contains "$sources" "journal"
    _teardown_recall
    fi
  }

  it "ref file contains crypto wallet content" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    results=$(recall_search "crypto wallet bitcoin" 3)
    assert_not_empty "$results"
    assert_contains "$results" "Crypto"
    _teardown_recall
    fi
  }

  it "creates mtime tracking file" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    assert_file_exists "$RECALL_MTIME_FILE"
    _teardown_recall
    fi
  }

# ── Needs Reindex Detection ──────────────────────────────────
describe "recall_needs_reindex"

  it "returns true when no DB exists" && {
    _setup_recall
    _create_sample_ref
    recall_needs_reindex
    assert_ok $?
    _teardown_recall
  }

  it "returns false after fresh index" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    recall_needs_reindex
    assert_fail $?
    _teardown_recall
    fi
  }

  it "returns true after file modification" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    sleep 1
    echo "## New Section" >> "$LODGE_DIR/docs/RECALL_INDEX.md"
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
    _create_sample_ref
    recall_reindex
    results=$(recall_search "sandboxes proot isolation" 5)
    assert_not_empty "$results"
    assert_contains "$results" "Sandbox"
    _teardown_recall
    fi
  }

  it "finds content across different sources" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    _create_sample_journal
    recall_reindex
    results=$(recall_search "George Washington" 5)
    assert_not_empty "$results"
    _teardown_recall
    fi
  }

  it "returns empty for unmatched query" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    results=$(recall_search "xyzzynonexistentterm" 5)
    assert_empty "$results"
    _teardown_recall
    fi
  }

  it "respects the limit parameter" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    results=$(recall_search "George" 2)
    count=$(echo "$results" | grep -c '|' || echo "0")
    [[ "$count" -le 2 ]]
    assert_ok $?
    _teardown_recall
    fi
  }

# ── Search for LLM Context ───────────────────────────────────
describe "recall_search_context"

  it "returns JSON array suitable for prompts" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    ctx=$(recall_search_context "architecture Ollama" 3)
    assert_not_empty "$ctx"
    assert_contains "$ctx" '"src":"ref"'
    _teardown_recall
    fi
  }

  it "returns empty for no matches" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
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
    _create_sample_ref
    recall_reindex
    review=$(recall_self_review)
    assert_not_empty "$review"
    assert_contains "$review" "CAPABILITIES"
    _teardown_recall
    fi
  }

  it "includes slash commands section" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
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
    _create_sample_ref
    recall_reindex
    stats=$(recall_stats)
    assert_contains "$stats" "Total chunks"
    assert_contains "$stats" "ref"
    _teardown_recall
    fi
  }

# ── Clear ─────────────────────────────────────────────────────
describe "recall_clear"

  it "removes the database" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
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
    _create_sample_ref
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
    _create_sample_ref
    recall_reindex
    # Should not produce a runtime error — may return empty but must not crash
    results=$(recall_search "recall.db" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles leading dots (.george)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    results=$(recall_search ".george" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles forward slashes (/recall)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    results=$(recall_search "/recall" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles at-signs (test@email.com)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    results=$(recall_search "test@email.com" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles hashes and dollar signs (#heading \$var)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    results=$(recall_search '#heading $variable' 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles commas, ampersands, and angle brackets" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    results=$(recall_search "a,b & c<d>e" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles FTS5 operators as literal words (AND OR NOT)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    results=$(recall_search "AND OR NOT" 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles all FTS5 operators (*+^~:(){}[])" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    results=$(recall_search 'test*+^~:(){}[]!' 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles pipe and backslash (a|b a\\b)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    results=$(recall_search 'a|b a\b' 5 2>&1)
    [[ "$results" != *"syntax error"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "handles pure punctuation query gracefully" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    # Pure punctuation should sanitize to empty and return 0, not crash
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
    result=$(_recall_sanitize_query "recall.db")
    assert_not_contains "$result" "."
    assert_contains "$result" "recall"
    assert_contains "$result" "db"
  }

  it "_recall_sanitize_query wraps words in quotes" && {
    result=$(_recall_sanitize_query "hello world")
    assert_contains "$result" '"hello"'
    assert_contains "$result" '"world"'
  }

  it "_recall_sanitize_query OR mode joins terms with OR" && {
    result=$(_recall_sanitize_query "hello world" "OR")
    assert_contains "$result" "OR"
  }

# ── ensure_indexed ────────────────────────────────────────────
describe "recall_ensure_indexed"

  it "indexes when DB missing" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_ensure_indexed
    assert_file_exists "$RECALL_DB"
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks;" 2>/dev/null)
    assert_gt "$count" 0
    _teardown_recall
    fi
  }

  it "skips when already indexed and unchanged" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    _create_sample_ref
    recall_reindex
    recall_ensure_indexed
    assert_ok $?
    _teardown_recall
    fi
  }

# ── RECALL_INDEX.md quality tests ──────────────────────────────
# Verify that the FTS5-optimized recall index produces clean, actionable
# recall output with concise, keyword-rich knowledge cards.

_setup_recall_with_ref() {
    _setup_recall
    mkdir -p "$LODGE_DIR/docs"
    # Copy the real RECALL_INDEX.md from the repo
    _real_ref="$(cd "$(dirname "$0")/.." && pwd)/docs/RECALL_INDEX.md"
    if [ -f "$_real_ref" ]; then
        cp "$_real_ref" "$LODGE_DIR/docs/RECALL_INDEX.md"
    else
        # Fallback: use the sample ref
        _create_sample_ref
    fi
    recall_reindex 2>/dev/null
}

describe "RECALL_INDEX.md recall quality"

  it "ref doc indexes with 'ref' source name" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    sources=$(sqlite3 "$RECALL_DB" "SELECT DISTINCT source FROM chunks ORDER BY source;" 2>/dev/null)
    assert_contains "$sources" "ref"
    _teardown_recall
    fi
  }

  it "ref produces 40+ short knowledge cards" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='ref';" 2>/dev/null)
    assert_gt "$count" 39
    _teardown_recall
    fi
  }

  it "ref cards are concise (avg under 500 chars)" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    avg_len=$(sqlite3 "$RECALL_DB" "SELECT CAST(AVG(length(content)) AS INTEGER) FROM chunks WHERE source='ref';" 2>/dev/null)
    [[ "$avg_len" -lt 500 ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "discord post query returns ref card first" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    ctx=$(recall_search_context "discord post channel" 4)
    assert_contains "$ctx" '"src":"ref"'
    _teardown_recall
    fi
  }

  it "discord post context includes exact syntax" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    ctx=$(recall_search_context "discord post channel" 2)
    assert_contains "$ctx" "/social post discord"
    _teardown_recall
    fi
  }

  it "context output has no snippet markers" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    ctx=$(recall_search_context "discord post channel" 4)
    [[ "$ctx" != *">>>"* ]] && [[ "$ctx" != *"<<<"* ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "sandbox query returns actionable ref card" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    ctx=$(recall_search_context "sandbox build test run" 3)
    assert_contains "$ctx" "/sandbox"
    _teardown_recall
    fi
  }

  it "crypto wallet query returns concise ref card" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    ctx=$(recall_search_context "crypto wallet bitcoin" 2)
    assert_contains "$ctx" "/wallet btc"
    _teardown_recall
    fi
  }

  it "discord dm query returns DM syntax" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    ctx=$(recall_search_context "discord dm user" 2)
    assert_contains "$ctx" "/social discord dm"
    _teardown_recall
    fi
  }

  it "mastodon instance query returns multi-instance syntax" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    ctx=$(recall_search_context "mastodon instance token" 2)
    assert_contains "$ctx" "instances"
    _teardown_recall
    fi
  }

  it "email query clearly says not for social" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    ctx=$(recall_search_context "email send" 2)
    assert_contains "$ctx" "email ONLY"
    _teardown_recall
    fi
  }

  it "git ssh query returns setup commands" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    ctx=$(recall_search_context "git setup ssh" 2)
    assert_contains "$ctx" "/git setup"
    _teardown_recall
    fi
  }

  it "no ref card exceeds 2000 chars" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    max_len=$(sqlite3 "$RECALL_DB" "SELECT MAX(length(content)) FROM chunks WHERE source='ref';" 2>/dev/null)
    [[ "${max_len:-9999}" -lt 2000 ]]
    assert_ok $?
    _teardown_recall
    fi
  }

  it "memory loop pattern is searchable" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall_with_ref
    ctx=$(recall_search_context "memory loop read remember respond" 2)
    assert_contains "$ctx" "journal write"
    _teardown_recall
    fi
  }

# ── User Preference Recall ────────────────────────────────────
describe "recall_log_user_input"

  it "is defined" && {
    declare -f recall_log_user_input &>/dev/null
    assert_ok $?
  }

  it "inserts a user_pref entry into the database" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    recall_log_user_input "Preferred language?" "Rust"
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref';")
    assert_eq "$count" "1"
    _teardown_recall
    fi
  }

  it "stores question as section and answer as content" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    recall_log_user_input "Favorite color?" "Blue"
    section=$(sqlite3 "$RECALL_DB" "SELECT section FROM chunks WHERE source='user_pref';")
    content=$(sqlite3 "$RECALL_DB" "SELECT content FROM chunks WHERE source='user_pref';")
    assert_eq "$section" "Favorite color?"
    assert_eq "$content" "Blue"
    _teardown_recall
    fi
  }

  it "FIFO evicts oldest when exceeding RECALL_USER_PREF_MAX" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    RECALL_USER_PREF_MAX=3
    recall_log_user_input "Q1?" "A1"
    recall_log_user_input "Q2?" "A2"
    recall_log_user_input "Q3?" "A3"
    recall_log_user_input "Q4?" "A4"
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref';")
    assert_eq "$count" "3"
    # Oldest (Q1) should be gone
    q1=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref' AND section='Q1?';")
    assert_eq "$q1" "0"
    RECALL_USER_PREF_MAX=20
    _teardown_recall
    fi
  }

  it "returns 1 on empty input" && {
    recall_log_user_input "" "answer" 2>/dev/null
    assert_eq $? 1
  }

  it "user_pref entries are searchable via recall_search" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    recall_log_user_input "Dietary restrictions?" "Vegetarian, no shellfish"
    result=$(recall_search "dietary vegetarian" 5)
    assert_contains "$result" "Vegetarian"
    _teardown_recall
    fi
  }

describe "recall_prune_user_prefs"

  it "is defined" && {
    declare -f recall_prune_user_prefs &>/dev/null
    assert_ok $?
  }

  it "removes entries before a given date" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    # Insert with old and new timestamps
    sqlite3 "$RECALL_DB" \
      "INSERT INTO chunks (source, section, content, filepath, indexed_at)
       VALUES ('user_pref', 'OldQ?', 'OldA', 'agent:/ask', '2025-01-15T10:00:00');"
    sqlite3 "$RECALL_DB" \
      "INSERT INTO chunks (source, section, content, filepath, indexed_at)
       VALUES ('user_pref', 'NewQ?', 'NewA', 'agent:/ask', '2026-03-08T10:00:00');"
    recall_prune_user_prefs "2026-01-01" >/dev/null 2>&1
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref';")
    assert_eq "$count" "1"
    remaining=$(sqlite3 "$RECALL_DB" "SELECT section FROM chunks WHERE source='user_pref';")
    assert_eq "$remaining" "NewQ?"
    _teardown_recall
    fi
  }

  it "validates date format" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    recall_prune_user_prefs "not-a-date" >/dev/null 2>&1
    assert_eq $? 1
    _teardown_recall
    fi
  }

describe "recall_compact_user_prefs"

  it "is defined" && {
    declare -f recall_compact_user_prefs &>/dev/null
    assert_ok $?
  }

  it "skips when 0 or 1 entries" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    recall_log_user_input "Solo?" "Yes"
    result=$(recall_compact_user_prefs 2>&1)
    assert_contains "$result" "nothing to compact"
    _teardown_recall
    fi
  }

describe "recall_clear_user_prefs"

  it "removes all user_pref entries" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    recall_log_user_input "Q1?" "A1"
    recall_log_user_input "Q2?" "A2"
    recall_clear_user_prefs >/dev/null 2>&1
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref';")
    assert_eq "$count" "0"
    _teardown_recall
    fi
  }

describe "recall_user_pref_count"

  it "returns 0 when no prefs exist" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    count=$(recall_user_pref_count)
    assert_eq "$count" "0"
    _teardown_recall
    fi
  }

  it "returns correct count after inserts" && {
    if [[ "$_HAS_SQLITE" != "1" ]]; then skip "sqlite3/FTS5 not available"; else
    _setup_recall
    recall_init
    recall_log_user_input "Q1?" "A1"
    recall_log_user_input "Q2?" "A2"
    count=$(recall_user_pref_count)
    assert_eq "$count" "2"
    _teardown_recall
    fi
  }

describe "recall_search_pretty user_pref label"

  it "shows User Pref label for user_pref source" && {
    body=$(declare -f recall_search_pretty)
    echo "$body" | grep -q 'user_pref'
    assert_ok $? "recall_search_pretty must handle user_pref source"
  }

test_end
