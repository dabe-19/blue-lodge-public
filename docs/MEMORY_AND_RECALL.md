# Memory, Recall & Journal

> How George remembers projects, searches knowledge, learns from experience, and lets old memories gracefully decay.

---

## Table of Contents

- [Design Philosophy](#design-philosophy)
- [Project Memory (GEORGE.md)](#project-memory)
- [System Prompt Construction](#system-prompt-construction)
- [The Recall System (FTS5)](#the-recall-system)
- [The Journal System](#the-journal-system)
- [User Preference Learning](#user-preference-learning)
- [Memory Compaction](#memory-compaction)
- [Putting It Back Together](#putting-it-back-together)
- [Troubleshooting](#troubleshooting)
- [Key Functions Reference](#key-functions-reference)

---

## Design Philosophy

George's memory system is built around three time horizons:

| Horizon | System | Persistence | Purpose |
|---------|--------|-------------|---------|
| **Immediate** | Micro/Macro memory | Per-task JSON files | Track current task progress |
| **Project** | GEORGE.md | Per-directory markdown | Remember project context and milestones |
| **Long-term** | Recall DB + Journal | SQLite + Markdown | Searchable knowledge + experiential memory |

The key constraint: **everything must survive subshells**. Bash `$()` command substitution creates subshells where variable assignments are invisible to the parent. This is why all memory uses files, not shell variables.

---

## Project Memory

### GEORGE.md — Per-Project State

Every project directory gets a `GEORGE.md` file:

```markdown
# GEORGE — myapi

## Project
name: myapi
type: rust

## Build
build: cargo build
test: cargo test

## Active Task
Build REST API with authentication endpoints

## Completed Milestones
- Created project scaffold with actix-web
- Added JWT authentication middleware
- Wrote user registration endpoint

## Context Files
- src/main.rs
- src/auth.rs
- Cargo.toml
```

### Initialization

```bash
memory_init() {
    local project_name="$1" project_type="$2"

    cat > "$dir/GEORGE.md" << MEMEOF
# GEORGE — $project_name

## Project
name: $project_name
type: ${project_type:-general}

## Build
build: (none)
test: (none)

## Active Task
(none)

## Completed Milestones
(none)

## Context Files
(none)
MEMEOF
}
```

**Bash Technique — Here-Documents**: The `<< MEMEOF` construct writes multiple lines to a file in a single operation. Variables like `$project_name` are expanded because the delimiter (`MEMEOF`) is **not** quoted. If it were `<< 'MEMEOF'`, variables would be literal.

### Section Manipulation

The memory system uses awk-based section editing — a pattern for safely modifying specific sections of a markdown file without disturbing others:

#### `memory_update_section()` — Replace Section Content

```bash
memory_update_section() {
    local file="$1" section="$2" content="$3"

    awk -v section="## $section" -v content="$content" '
    $0 == section {
        print           # Print the ## heading
        print content   # Print new content
        found = 1
        printed = 1
        next
    }
    found && /^## / {
        found = 0       # Next section starts — stop skipping
    }
    !found { print }    # Print lines outside the replaced section
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}
```

**How this works**:
1. Scan lines looking for the exact `## Section` heading
2. When found, print the heading + new content, then set `found=1`
3. While `found=1`, skip all lines (these are the old content being replaced)
4. When the next `## ` heading appears, reset `found=0` (resume printing)
5. Write to temp file, then atomic `mv` to avoid corruption on crash

#### `memory_append_section()` — Add to Section

```bash
memory_append_section() {
    local file="$1" section="$2" line="$3"

    # Filter out placeholder
    local current
    current=$(memory_get_section "$file" "$section")
    if [[ "$current" == "(none)" ]]; then
        memory_update_section "$file" "$section" "$line"
    else
        memory_update_section "$file" "$section" "${current}"$'\n'"${line}"
    fi
}
```

#### `memory_get_section()` — Extract Section Content

```bash
memory_get_section() {
    local file="$1" section="$2"

    awk -v section="## $section" '
    $0 == section { found = 1; next }
    found && /^## / { exit }
    found { print }
    ' "$file" | sed '/^$/d'  # Remove blank lines
}
```

---

## System Prompt Construction

### `memory_build_system_prompt()`

This is the most important function in the memory system — it assembles the system prompt that shapes ALL of George's behavior. The prompt varies by mode:

### Ask Mode (~400-500 tokens)

For quick Q&A (`/q` or `/ask`):

```
┌─ Identity (~90 tokens) ──────────────────────────────────────┐
│  From models_default_system(): "You ARE George, a coding     │
│  assistant built on Blue Lodge..."                            │
├─ Condensed Soul (~200 tokens) ───────────────────────────────┤
│  Personality + core rules (no ethics/philosophy)              │
├─ Context (~100 tokens) ──────────────────────────────────────┤
│  Active task + last 3 milestones + workspace files (8 max)   │
├─ Recall (~50 tokens) ────────────────────────────────────────┤
│  1 chunk from FTS5 if task_hint provided                     │
├─ Journal (~50 tokens) ───────────────────────────────────────┤
│  Recent entries (~150 chars)                                  │
├─ Output Constraints ─────────────────────────────────────────┤
│  "Answer in plain text, max 5 sentences"                     │
└──────────────────────────────────────────────────────────────┘
```

### Plan Mode (~2000-4500 tokens)

For task decomposition:

```
┌─ Identity ───────────────────────────────────────────────────┐
├─ Soul (full or condensed, toggle: LODGE_SOUL) ───────────────┤
├─ Environment Constraints ~100 tokens ────────────────────────┤
│  proot/Docker guards, toolchain warnings, authority level     │
├─ Project Memory (GEORGE.md) ~200 tokens ─────────────────────┤
├─ Command Catalog (JSON) ~900 tokens ─────────────────────────┤
├─ Workspace Files (15 max) ~100 tokens ───────────────────────┤
├─ Sandbox Inventory ~50 tokens ───────────────────────────────┤
├─ Output Constraints ─────────────────────────────────────────┤
│  "Output numbered list (1. 2. 3.)"                           │
└──────────────────────────────────────────────────────────────┘
```

### Task Mode (~6000+ tokens)

For full agent execution:

```
┌─ Background ─────────────────────────────────────────────────┐
│  Workspace files + sandbox inventory                          │
├─ Dynamic Context ────────────────────────────────────────────┤
│  GEORGE.md + recalled knowledge + journal entries             │
├─ Constraints ────────────────────────────────────────────────┤
│  Environment + command catalog + tool availability            │
├─ Identity (LAST for strongest attention) ────────────────────┤
│  Full soul.md                                                 │
└──────────────────────────────────────────────────────────────┘
```

**Recency Bias Optimization**: In task mode, identity and constraints are placed **last** in the prompt. Transformer models have a recency bias — they pay more attention to tokens near the end of the context. By placing the most important behavioral constraints last, the model follows them more reliably.

### Three Levels of Soul Injection

```bash
_memory_soul_identity()     # ~90 tokens:  "You ARE George" — minimal declaration
_memory_soul_condensed()    # ~200 tokens: personality + core rules
# Full soul.md             # ~4500 tokens: complete personality, ethics, philosophy
```

Controlled by `LODGE_SOUL`:
- `LODGE_SOUL=0` — Identity only (~90 tokens)
- `LODGE_SOUL=1` — Condensed (~200 tokens)
- `LODGE_SOUL=2` — Full soul.md (~4500 tokens)

---

## The Recall System

### Architecture

A SQLite FTS5 (Full-Text Search 5) database providing <1ms keyword search across George's knowledge:

```sql
CREATE TABLE chunks (
    id INTEGER PRIMARY KEY,
    source TEXT,       -- ref|journal|george|doc:<label>|user_pref
    section TEXT,      -- ## Section header
    content TEXT,      -- Section body text
    filepath TEXT,     -- Source file path
    indexed_at TEXT    -- ISO timestamp
);

CREATE VIRTUAL TABLE chunks_fts USING fts5(
    source, section, content,
    content='chunks',
    content_rowid='id',
    tokenize='porter unicode61'
);
```

**Why FTS5?** It provides:
- **Porter stemming**: `"wallets"` matches `"wallet"`, `"encrypted"` matches `"encrypt"`
- **BM25 ranking**: Results ordered by relevance
- **snippet()**: Highlighted excerpts showing matching context
- **<1ms queries**: No network, no API calls, works offline

### What Gets Indexed

| Source | File | Strategy |
|--------|------|----------|
| `ref` | docs/RECALL_INDEX.md | Distilled master reference (~75 chunks) |
| `journal` | journal.md | Living memory entries |
| `george` | ./GEORGE.md | Current project state |
| `user_pref` | (collected via /ask) | Q&A learning pairs |
| `doc:<label>` | User-ingested files | PDFs, markdown, code |

**Why only 3 core sources?** Raw documentation files are large and sparse. Instead, they're distilled into `RECALL_INDEX.md` — a single keyword-rich reference file optimized for FTS5 matching.

### Chunking Strategy

Markdown files are split on `##` headings:

```bash
_recall_chunk_markdown() {
    local filepath="$1"

    awk 'BEGIN { section = "(preamble)"; content = "" }
    /^## / {
        if (content != "") {
            # Emit previous chunk
            print section "\t" content
        }
        section = substr($0, 4)  # Strip "## " prefix
        content = ""
        next
    }
    {
        # Collapse whitespace, join lines
        gsub(/[[:space:]]+/, " ")
        content = content " " $0
    }
    END {
        if (content != "") print section "\t" content
    }' "$filepath"
}
```

**Bash Technique — Awk Multi-Line Accumulation**: The awk program maintains state (`section`, `content`) across lines. When a new `##` header is found, it emits the accumulated content of the previous section, then starts fresh. This is the idiomatic way to process section-based documents in awk.

### Query Sanitization

LLM-generated queries need cleaning before FTS5:

```bash
_recall_sanitize_query() {
    local query="$1"

    # Step 1: Keep only alphanumeric + spaces + underscores
    query=$(echo "$query" | tr -cd 'a-zA-Z0-9 _')

    # Step 2: Remove stop words
    local -a stop_words=(
        a an the this that in on at for to of is are was were
        check find search look get verify show list view
    )
    for word in "${stop_words[@]}"; do
        query=$(echo "$query" | sed "s/\b${word}\b//gi")
    done

    # Step 3: Collapse whitespace, trim
    query=$(echo "$query" | tr -s ' ' | sed 's/^ *//;s/ *$//')

    # Step 4: Wrap each word in FTS5 double-quotes
    query=$(echo "$query" | sed 's/[^ ][^ ]*/"\0"/g')

    echo "$query"
}
```

**Why quote each word?** FTS5 interprets unquoted special characters as operators. Quoting each word ensures literal matching: `"crypto" "wallets"` instead of `crypto AND wallets` (which would fail if either wasn't a column name).

### Search with Fallback

```bash
recall_search() {
    local query="$1" limit="${2:-5}"
    local clean
    clean=$(_recall_sanitize_query "$query")

    # Try AND first (all words must match)
    local results
    results=$(sqlite3 "$RECALL_DB" \
        "SELECT source, section, snippet(chunks_fts, 2, '>>>', '<<<', '...', 48)
         FROM chunks_fts
         WHERE chunks_fts MATCH '$clean'
         ORDER BY bm25(chunks_fts, 10.0, 5.0, 1.0)
         LIMIT $limit")

    # Fallback to OR if AND returns nothing
    if [[ -z "$results" ]]; then
        local or_query
        or_query=$(echo "$clean" | sed 's/" "/\" OR \"/g')
        results=$(sqlite3 "$RECALL_DB" \
            "SELECT source, section, snippet(chunks_fts, 2, '>>>', '<<<', '...', 48)
             FROM chunks_fts
             WHERE chunks_fts MATCH '$or_query'
             ORDER BY bm25(chunks_fts, 10.0, 5.0, 1.0)
             LIMIT $limit")
    fi

    echo "$results"
}
```

**BM25 Weighting**: `bm25(chunks_fts, 10.0, 5.0, 1.0)` assigns:
- Weight 10 to `source` column matches
- Weight 5 to `section` column matches
- Weight 1 to `content` column matches

This means a match in the section heading is 5x more relevant than a match in the body.

### Modification Tracking

The system only reindexes when source files have changed:

```bash
recall_needs_reindex() {
    local mtime_file="$RECALL_MTIME_FILE"
    [[ ! -f "$mtime_file" ]] && return 0  # No mtimes = needs reindex

    while IFS='=' read -r source mtime; do
        local current_mtime
        current_mtime=$(_recall_file_mtime "$source")
        [[ "$current_mtime" != "$mtime" ]] && return 0  # Changed = reindex
    done < "$mtime_file"

    return 1  # All mtimes match = no reindex needed
}
```

---

## The Journal System

### Temporal Decay Memory

The journal (`$LODGE_DIR/journal.md`) is George's experiential memory — reflections, learnings, struggles, and quips that **decay over time**:

```markdown
## 2026-03-08 14:30 — learning
Discovered that Qwen3 needs explicit /no_think suffix to suppress reasoning.

## 2026-03-07 09:15 — reflection
The web scraping task revealed that many sites now block automated access.

## 2026-02-20 16:45 — struggle
Failed repeatedly to connect to ProtonMail Bridge. Port 1025 wasn't listening.
```

### Decay Tiers

```
Day 0-3:   VIVID     → Full content displayed
Day 4-14:  FADING    → One-line summaries only
Day 15-60: SEDIMENT  → LLM-compressed into a single paragraph
Day 60+:   ARCHIVED  → Removed from active journal
```

### Reading with Decay

```bash
journal_read() {
    local now_epoch=$(date +%s)
    local vivid_cutoff=$(( now_epoch - DECAY_VIVID_DAYS * 86400 ))
    local fading_cutoff=$(( now_epoch - DECAY_FADING_DAYS * 86400 ))

    local output=""

    while IFS= read -r line; do
        # Parse entry date from header
        if [[ "$line" =~ ^##\ ([0-9]{4}-[0-9]{2}-[0-9]{2})\ [0-9]{2}:[0-9]{2}\ —\ (.+)$ ]]; then
            local entry_date="${BASH_REMATCH[1]}"
            local entry_type="${BASH_REMATCH[2]}"
            local entry_epoch
            entry_epoch=$(date -d "$entry_date" +%s 2>/dev/null)

            if (( entry_epoch >= vivid_cutoff )); then
                tier="vivid"
            elif (( entry_epoch >= fading_cutoff )); then
                tier="fading"
            else
                tier="sediment"
            fi
        fi

        case "$tier" in
            vivid)    output+="$line"$'\n' ;;          # Full content
            fading)   # First line only (summary)
                      [[ "$line" =~ ^## ]] && output+="$line"$'\n'
                      ;;
            sediment) ;;  # Skip (handled separately)
        esac
    done < "$JOURNAL_FILE"

    # Sediment at beginning (lowest attention — oldest memories)
    # Fading in the middle
    # Vivid at end (highest attention — recency bias)
    echo "$sediment_section"
    echo "$fading_section"
    echo "$vivid_section"
}
```

**Bash Technique — Epoch-Based Date Comparison**: Convert dates to Unix timestamps (seconds since 1970) for arithmetic comparison. `$(( now - 3 * 86400 ))` gives 3 days ago. This is the reliable cross-platform way to compare dates in bash.

### Decay Application

When entries age past the sediment cutoff:

```bash
journal_apply_decay() {
    # Collect old entries
    local old_entries
    old_entries=$(journal_get_old_entries "$sediment_cutoff")

    [[ -z "$old_entries" ]] && return 0

    # LLM generates poetic summary paragraph
    local compressed
    compressed=$(llm_generate \
        "Compress these journal entries into a single reflective paragraph (max 100 words):" \
        "$old_entries")

    # Update Sediment section
    journal_update_sediment "$compressed"

    # Remove old entries from journal
    journal_remove_old_entries "$sediment_cutoff"
}
```

### Journal Quips

After `/ask` exchanges, George writes a witty one-liner in the style of Benjamin Franklin:

```bash
journal_write_quip() {
    local question="$1" response="$2"

    # Background call (no TTY output, no blocking)
    (
        local quip
        quip=$(llm_generate \
            "Write a witty one-liner (max 120 chars) reflecting on this exchange. Franklin/Dogood wit." \
            "Q: $question A: $response")
        journal_write "quip" "$quip"
    ) &
}
```

**Bash Technique — Background Subshell**: The `( ... ) &` pattern runs the quip generation in a background subshell. The user doesn't wait for it. The `&` makes it asynchronous, and the `( )` keeps it isolated from the parent shell's state.

---

## User Preference Learning

### How It Works

When George asks questions via `/ask` and gets user responses, the Q&A pairs are saved:

```bash
recall_log_user_input() {
    local question="$1" answer="$2"

    local q_safe="${question//\'/\'\'}"   # SQL escape single quotes
    local a_safe="${answer//\'/\'\'}"

    sqlite3 "$RECALL_DB" \
        "INSERT INTO chunks (source, section, content, indexed_at)
         VALUES ('user_pref', '$q_safe', '$a_safe', datetime('now'))"

    # FIFO eviction: keep only newest N entries
    local count
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='user_pref'")
    if (( count > RECALL_USER_PREF_MAX )); then
        sqlite3 "$RECALL_DB" \
            "DELETE FROM chunks WHERE source='user_pref' AND id IN
             (SELECT id FROM chunks WHERE source='user_pref'
              ORDER BY indexed_at ASC
              LIMIT $((count - RECALL_USER_PREF_MAX)))"
    fi
}
```

### Preference Compaction

Over time, preferences may contradict (user changes preferred language from Python to Rust):

```bash
recall_compact_user_prefs() {
    local all_prefs
    all_prefs=$(sqlite3 "$RECALL_DB" \
        "SELECT section || ': ' || content FROM chunks WHERE source='user_pref'")

    # LLM consolidates, keeping most recent on contradiction
    local compacted
    compacted=$(llm_generate \
        "Consolidate these preferences into a user profile. If contradictions exist, keep the most recent." \
        "$all_prefs")

    # Replace all entries with one compacted summary
    sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE source='user_pref'"
    sqlite3 "$RECALL_DB" \
        "INSERT INTO chunks (source, section, content, indexed_at)
         VALUES ('user_pref', 'User Profile', '$(echo "$compacted" | sed "s/'/''/g")', datetime('now'))"
}
```

---

## Memory Compaction

### `memory_compact()`

Prevents GEORGE.md from growing without bound:

```bash
memory_compact() {
    local file="$1"

    # Trim completed milestones to last 5
    local milestones
    milestones=$(memory_get_section "$file" "Completed Milestones")
    local count
    count=$(echo "$milestones" | grep -c '^- ')
    if (( count > 5 )); then
        milestones=$(echo "$milestones" | tail -5)
        memory_update_section "$file" "Completed Milestones" "$milestones"
    fi

    # Deduplicate and cap context files at 20
    local context
    context=$(memory_get_section "$file" "Context Files" | sort -u | tail -20)
    memory_update_section "$file" "Context Files" "$context"

    # Hard cap: 6KB file size
    local size
    size=$(wc -c < "$file")
    if (( size > 6144 )); then
        # Aggressive trim: keep only last 3 milestones
        milestones=$(echo "$milestones" | tail -3)
        memory_update_section "$file" "Completed Milestones" "$milestones"
    fi
}
```

---

## Putting It Back Together

### If the Recall Database is Corrupted

```bash
# Delete and rebuild
rm -f .george/recall.db
# Trigger reindex on next recall command
lodge
/recall test   # This will trigger recall_ensure_indexed → full reindex
```

### If GEORGE.md is Corrupted

```bash
# Restore from snapshot
ls .lodge-snapshots/   # Find a good snapshot
cp .lodge-snapshots/GEORGE-20260308.md ./GEORGE.md
```

Or reinitialize:
```bash
# Inside lodge:
/memory init    # Creates fresh GEORGE.md
```

### If the Journal Won't Load

Common issue: malformed entry headers. Every entry must match:
```
## YYYY-MM-DD HH:MM — type
```

Check for missing dashes or incorrect date formats:
```bash
grep -n '^## ' journal.md | grep -v '^## [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\} — '
```

### If Memory Compaction Breaks Sections

The awk-based editor depends on exact `## Section` headings. If someone adds extra spaces or changes capitalization, sections become invisible:

```bash
# Check section headings
grep '^## ' GEORGE.md

# Should see exactly:
## Project
## Build
## Active Task
## Completed Milestones
## Context Files
```

---

## Troubleshooting

### Recall Returns No Results

1. **Check database exists**: `ls -la .george/recall.db`
2. **Check FTS5 support**: `sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(x);"` — if this errors, SQLite doesn't have FTS5
3. **Force reindex**: Delete `.george/.recall_mtimes` to trigger rebuild
4. **Check index content**: `sqlite3 .george/recall.db "SELECT COUNT(*) FROM chunks"`

### Journal Entries Not Decaying

1. **Check date format**: Entries must use `YYYY-MM-DD HH:MM` format
2. **Check decay settings**: `DECAY_VIVID_DAYS`, `DECAY_FADING_DAYS`, `DECAY_SEDIMENT_DAYS`
3. **Manual decay**: Run `journal_apply_decay` directly

### System Prompt Too Large

1. **Check soul mode**: `LODGE_SOUL=0` reduces identity to ~90 tokens
2. **Check recall injection**: Disable recall in ask mode by not providing task_hint
3. **Check workspace files**: Cap at 8 (ask) or 15 (plan) entries
4. **Compact memory**: Run `/compact` to trim GEORGE.md

---

## Key Functions Reference

### Memory (lib/memory.sh)

| Function | Purpose |
|----------|---------|
| `memory_init()` | Create fresh GEORGE.md |
| `memory_read_project()` | Read GEORGE.md from current directory |
| `memory_update_section()` | Replace section content (awk-based) |
| `memory_append_section()` | Add line to section |
| `memory_get_section()` | Extract section content |
| `memory_build_system_prompt()` | Mode-aware prompt assembly |
| `memory_compact()` | Trim milestones and context files |
| `memory_snapshot()` | Timestamped archive to .lodge-snapshots/ |

### Recall (lib/recall.sh)

| Function | Purpose |
|----------|---------|
| `recall_init()` | Create FTS5 tables and triggers |
| `recall_search()` | BM25-ranked search with AND→OR fallback |
| `recall_search_context()` | Plain text results for LLM injection |
| `recall_reindex()` | Full rebuild from source files |
| `recall_ingest()` | Add document to knowledge base |
| `_recall_chunk_markdown()` | Split markdown on ## headers |
| `_recall_sanitize_query()` | Clean query for FTS5 |
| `recall_log_user_input()` | Save Q&A learning pair |
| `recall_compact_user_prefs()` | LLM consolidation of preferences |

### Journal (lib/journal.sh)

| Function | Purpose |
|----------|---------|
| `journal_write()` | Append timestamped entry |
| `journal_read()` | Read with decay tiers applied |
| `journal_apply_decay()` | Compress old entries to sediment |
| `journal_write_failure()` | Structured failure record |
| `journal_write_quip()` | Background witty one-liner |
| `journal_reflect()` | Session reflection at task end |
| `journal_greeting()` | Session-aware greeting message |

---

*Previous: [Command Dispatch & Extensions](COMMAND_DISPATCH.md) | Next: [UI & Terminal Rendering](UI_AND_TERMINAL.md)*
