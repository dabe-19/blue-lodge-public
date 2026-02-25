# Recall — FTS5 Knowledge Base

George has a built-in **full-text search** system called **Recall** that
lets him search across all of his documentation, personality, memory, and any
documents you ingest. It's powered by SQLite FTS5 — zero network, zero
Python, zero RAM overhead, sub-millisecond queries.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [How It Works](#how-it-works)
3. [Indexed Sources](#indexed-sources)
4. [Commands Reference](#commands-reference)
5. [Search Syntax](#search-syntax)
6. [How George Uses Recall](#how-george-uses-recall)
7. [Ingesting Your Own Documents](#ingesting-your-own-documents)
8. [Architecture](#architecture)
9. [Reindexing & Maintenance](#reindexing--maintenance)
10. [Troubleshooting](#troubleshooting)

---

## Quick Start

```bash
lodge

# Search for anything
george> /recall crypto wallets

# Search for specific topics
george> /recall how to use sandboxes
george> /recall adam smith moral sentiments
george> /recall AES encryption vault

# Check the index
george> /recall stats

# Force a reindex if something seems stale
george> /recall reindex

# Ingest a new document
george> /ingest myfile.pdf
```

---

## How It Works

```
┌─────────────────────────────────────────────────────┐
│  Your query: "crypto wallets"                       │
│                                                     │
│  1. Sanitize query (strip ?, !, special chars)      │
│  2. Check if reindex needed (mtime comparison)      │
│  3. FTS5 MATCH with BM25 ranking                    │
│  4. Return top results with highlighted snippets    │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│  SQLite FTS5 Database (~/.george/recall.db)          │
│                                                     │
│  Tables:                                            │
│    chunks     — source, section, content, filepath  │
│    chunks_fts — FTS5 virtual table (porter stemmer) │
│                                                     │
│  Tokenizer: porter unicode61                        │
│    "running" matches "run", "runs", "runner"        │
│    "wallets" matches "wallet"                       │
│    Unicode-aware for international text              │
└─────────────────────────────────────────────────────┘
```

George's documentation is **chunked by `##` headers** — each level-2
heading in a Markdown file becomes a separate searchable section. This means
searches return focused, relevant snippets rather than entire files.

**Key properties:**

| Property | Value |
|----------|-------|
| Engine | SQLite FTS5 |
| Ranking | BM25 (weighted: section 10x, source 5x, content 1x) |
| Tokenizer | Porter stemmer + unicode61 |
| Storage | `~/.george/recall.db` (~50-100KB) |
| Query speed | <1ms typically |
| Network | None — entirely local |
| Dependencies | `sqlite3` with FTS5 support |

---

## Indexed Sources

George automatically indexes these sources on startup:

| Source | File | Description |
|--------|------|-------------|
| `ref` | `docs/RECALL_INDEX.md` | FTS5-optimized master reference (~75 keyword-rich sections distilled from all docs) |
| `journal` | `journal.md` | George's living memory (with decay) |
| `george` | `./GEORGE.md` | Current project memory |
| `doc:<label>` | User-ingested files | Added via `/ingest` (e.g., `doc:research-paper`) |

> **Design note:** Raw human-readable docs (README.md, soul.md, docs/*.md) are **not** indexed directly. Their actionable content is distilled into `RECALL_INDEX.md` — a single file with ~75 dense, keyword-rich sections optimized for FTS5 retrieval. This keeps the index small (~20-40 chunks from built-in sources) while covering all of George's documentation.

### Automatic Reindexing

George checks file modification times (`mtime`) on every startup and before
every search. If any indexed file has changed since the last index, it
automatically reindexes. You generally don't need to manually reindex.

---

## Commands Reference

| Command | Description |
|---------|-------------|
| `/recall <query>` | Search all knowledge sources |
| `/recall stats` | Show chunk counts per source and DB size |
| `/recall reindex` | Force clear + reindex all sources |
| `/recall clear` | Delete the entire index |
| `/ingest <file> [label]` | Add a document to the knowledge base |
| `/ingest list` | Show all ingested documents |
| `/ingest rm <label>` | Remove an ingested document |

---

## Search Syntax

### Basic Search

Just type natural language. FTS5 finds all documents containing your words:

```
/recall crypto wallets
/recall how to use sandboxes
/recall adam smith
```

### How Matching Works

FTS5 uses **implicit AND** by default — all words must appear in the
document for it to match. If no results are found with AND, George
automatically retries with **OR** between words for broader matching.

```
/recall crypto wallets
→ First tries: documents containing BOTH "crypto" AND "wallets"
→ If empty: retries with "crypto OR wallets"
```

### Porter Stemming

The index uses the **Porter stemmer**, which means word variants match
automatically:

| You search for | Also matches |
|----------------|-------------|
| `running` | run, runs, runner |
| `wallets` | wallet |
| `encrypted` | encrypt, encryption, encrypts |
| `sandboxes` | sandbox |
| `testing` | test, tests, tested |

### Special Characters

Special characters (`?`, `!`, `*`, `(`, `)`, `:`, `+`, `^`, `~`, `{`, `}`,
`[`, `]`, `;`) are automatically stripped from queries. You can type natural
questions like:

```
/recall what can George do with crypto wallets?
/recall how does the vault encryption work?
```

### BM25 Ranking

Results are ranked by **BM25** (Best Matching 25), the same algorithm used
by search engines. Results are weighted:

- **Section heading match** — 10x weight (most important)
- **Source name match** — 5x weight
- **Content match** — 1x weight (body text)

This means a document with "crypto" in the section heading ranks higher than
one where "crypto" only appears in the body text.

---

## How George Uses Recall

Recall isn't just for manual `/recall` queries — George **automatically**
searches the knowledge base when working on tasks.

### During Task Execution (Full Mode)

When you give George a task, `memory_build_system_prompt` includes a
`--- RECALLED KNOWLEDGE ---` section with the top **4** FTS5 results relevant
to your task description:

```
You: Build a Bitcoin balance checker

George's system prompt includes:
  --- RECALLED KNOWLEDGE ---
  [crypto: Bitcoin (BTC)] /wallet btc balance — Check current BTC balance...
  [crypto: Quick Start] /wallet network testnet — Switch to testnet first...
```

This gives George contextual knowledge even when the information isn't in
his core personality (soul.md) or project memory (GEORGE.md).

### During /ask (Lean Mode)

Quick questions get **1** recall chunk (capped at **200 characters**) to keep the
prompt small (~150 tokens total):

```
You: /ask what's my vault encryption?
→ Recall injects: [vault: Encryption Details] AES-256-CBC, PBKDF2...
→ George can answer accurately even though vault details aren't in soul.md
```

### During Planning (Plan Mode)

Planning does **not** use recall — it only needs identity + project state +
file listing + lean command catalog. This keeps the plan prompt under ~700 tokens.

---

## Ingesting Your Own Documents

You can add any document to George's knowledge base:

### Supported Formats

| Format | Extension | Method |
|--------|-----------|--------|
| Markdown | `.md` | Chunked by `##` headers |
| Plain text | `.txt`, `.log`, `.csv` | Chunked by paragraphs (~500 chars) |
| Source code | `.sh`, `.py`, `.rs`, `.js`, `.ts`, `.go`, `.rb`, etc. | Chunked by paragraphs |
| Config | `.toml`, `.yaml`, `.json`, `.ini`, `.conf` | Chunked by paragraphs |
| PDF | `.pdf` | Via `pdftotext` (install: `apt install poppler-utils`) |
| HTML | `.html` | Tags stripped, then chunked |
| Office | `.doc`, `.docx`, `.odt` | Via `pandoc` or `libreoffice` |

### Ingest Examples

```bash
# Ingest a PDF research paper
george> /ingest ~/papers/attention-is-all-you-need.pdf transformer-paper

# Ingest project documentation
george> /ingest ./API_DOCS.md api-docs

# Ingest a requirements spec
george> /ingest ~/specs/requirements.txt project-requirements

# With LLM summary (if model is loaded, George generates a bullet-point
# summary and stores it as an additional searchable chunk)
george> /ingest ~/report.pdf quarterly-report
```

### Managing Ingested Documents

```bash
# List all ingested documents
george> /ingest list
  ● transformer-paper     8 chunks  (/home/user/papers/attention-is-all-you-need.pdf)
  ● api-docs              5 chunks  (./API_DOCS.md)

# Remove an ingested document
george> /ingest rm transformer-paper

# Search across everything (built-in + ingested)
george> /recall attention mechanism
```

### How Ingestion Works

1. George reads the file using the appropriate extractor (cat for text,
   pdftotext for PDF, pandoc for Office docs)
2. For Markdown files: splits on `##` headers into section-level chunks
3. For other files: splits on paragraph boundaries into ~500 character chunks
4. Each chunk is inserted into the FTS5 index with the source label `doc:<label>`
5. If the LLM is loaded, George generates a 3-5 bullet point summary and
   stores it as an additional "Summary" chunk for better search relevance
6. Modification times are tracked so George knows if the source file changes

---

## Architecture

### Database Schema

```sql
-- Main storage table
CREATE TABLE chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source TEXT NOT NULL,       -- ref, journal, george, doc:label
    section TEXT NOT NULL,      -- section heading from the document
    content TEXT NOT NULL,      -- section body text
    filepath TEXT NOT NULL,     -- original file path
    indexed_at TEXT NOT NULL    -- ISO timestamp
);

-- FTS5 virtual table (linked to chunks)
CREATE VIRTUAL TABLE chunks_fts USING fts5(
    source,
    section,
    content,
    content='chunks',
    content_rowid='id',
    tokenize='porter unicode61'
);

-- Automatic sync triggers (INSERT, UPDATE, DELETE)
```

### Chunking Strategy

**Markdown files** are split on `##` level-2 headers. Each chunk contains:
- `section` = the heading text (e.g., "Bitcoin (BTC)")
- `content` = everything between this heading and the next

**Non-Markdown files** are split on paragraph boundaries (~500 characters).
Each chunk gets a sequential label like "Part 1", "Part 2", etc.

### Modification Tracking

File modification times are stored in `~/.george/.recall_mtimes`:

```
ref=1740268421
journal=1740268400
george=1740268410
```

Before every search, George compares current mtimes against stored mtimes.
If any file has changed, it triggers a full reindex (~50ms for all sources).

### Query Pipeline

```
User query: "what can George do with crypto wallets?"
    │
    ├─ 1. Sanitize: strip "?" → "what can George do with crypto wallets"
    │
    ├─ 2. FTS5 MATCH (implicit AND)
    │     → Searches for docs containing ALL words
    │     → BM25 ranking with section/source weighting
    │
    ├─ 3. If no results: retry with OR
    │     → "what OR can OR George OR do OR with OR crypto OR wallets"
    │
    └─ 4. Return top N results with snippet highlighting
          → Snippets use >>> <<< markers around matching terms
          → Displayed with color highlighting in terminal
```

---

## Reindexing & Maintenance

### Force Reindex

If the index seems stale or you've made manual edits to docs:

```bash
george> /recall reindex
  ● Reindexing knowledge base...
  ✓ Reindexed
  Total chunks: 30
    ref        24 sections
    journal     4 sections
    george      2 sections
  DB size:     64K
```

### Clear and Rebuild

```bash
george> /recall clear
  ✓ Recall index cleared

george> /recall reindex
```

### Disk Usage

The recall database is lightweight:

- ~20-40 chunks from built-in sources (ref + journal + george) = ~50-100KB
- Each ingested document adds proportionally
- The FTS5 index is highly compressed

Check: `du -h ~/.george/recall.db`

### When Does Reindexing Happen?

| Event | Reindex? |
|-------|----------|
| George starts up | Yes, if any file mtime changed |
| Before `/recall` search | Yes, if any file mtime changed |
| After `/ingest` | Only the ingested document |
| After editing soul.md | On next startup or search |
| After journal reflection | On next startup or search |
| `/recall reindex` | Yes, always (full clear + rebuild) |

---

## Troubleshooting

### "sqlite3 with FTS5 not available"

FTS5 is a SQLite extension. Install it:

```bash
# Ubuntu / Debian / proot-distro
apt install sqlite3

# Termux (native)
pkg install sqlite

# Verify FTS5 support
sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(c);" && echo "FTS5 OK"
```

### "0 chunks" or Empty Index

If `/recall stats` shows 0 chunks:

1. Make sure `$LODGE_DIR` is set correctly: `echo $LODGE_DIR`
2. Check that the source files exist: `ls $LODGE_DIR/README.md $LODGE_DIR/soul.md`
3. Force a reindex: `/recall reindex`
4. Check for errors in the reindex output

### "No results" for Terms That Should Match

- Try simpler queries: `/recall crypto` instead of a long sentence
- Check that the source is indexed: `/recall stats`
- Force reindex: `/recall reindex`
- Remember: FTS5 uses AND by default — if all words don't appear in the
  same section, try fewer words

### FTS5 Syntax Errors

George automatically strips special characters (`?`, `!`, `*`, `(`, `)`,
`:`, `+`, etc.) from queries. If you still see syntax errors, your query
may contain unusual Unicode characters. Try simplifying the query.

### Recall Database Location

```
~/.george/recall.db           ← FTS5 database
~/.george/.recall_mtimes      ← Modification time cache
```

To reset everything:
```bash
rm -f ~/.george/recall.db ~/.george/.recall_mtimes
```

George will rebuild the index automatically on next startup.

---

*See also: [TUNING.md](TUNING.md) for prompt token budgets (recall's role
in the context window), [SANDBOXES.md](SANDBOXES.md) for project isolation,
[SECRETS_VAULT.md](SECRETS_VAULT.md) for encrypted credential storage.*
