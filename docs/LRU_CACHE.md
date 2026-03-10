# LRU Cache — Design & Operator Guide

> How George's memory cache works, why it's built this way, and how to tune it.

---

## Table of Contents

- [Why a Cache?](#why-a-cache)
- [The Classical LRU vs. What We Actually Built](#the-classical-lru-vs-what-we-actually-built)
- [Architecture: Filesystem as Data Structure](#architecture-filesystem-as-data-structure)
- [How the LRU Ordering Works](#how-the-lru-ordering-works)
- [Namespace Generation Invalidation](#namespace-generation-invalidation)
- [TTL Expiration](#ttl-expiration)
- [The Hot Path: How Recall Uses the Cache](#the-hot-path-how-recall-uses-the-cache)
- [Disk Layout](#disk-layout)
- [Tuning Guide](#tuning-guide)
- [Operator Troubleshooting](#operator-troubleshooting)
- [Function Reference](#function-reference)
- [Design Tradeoffs & Limitations](#design-tradeoffs--limitations)

---

## Why a Cache?

Every time George takes a turn in the agent loop, the system calls `recall_search_context()` to inject relevant knowledge into the LLM's system prompt. Without caching, this means:

1. `recall_ensure_indexed()` — stat 3 files to check mtimes (~3ms)
2. Fork `sqlite3` — process spawn on Linux (~5-15ms)
3. FTS5 MATCH query — BM25-ranked search (~1-5ms)
4. Parse results, escape for JSON (~1ms)

**Total: ~10-30ms per turn.** On constrained hardware (iPhone 7+, Chromebook, Raspberry Pi), the sqlite3 fork alone can take 30ms+. During multi-step agent loops with 6-10 inner iterations, this adds up to 100-300ms of pure overhead *per milestone*.

With the LRU cache, a repeat query (common — the same `/build` or `/sandbox` command triggers the same recall lookup across retries) costs:

1. `_cache_hash` — printf + md5sum pipe (~0.5ms)
2. `stat` + `head -1` — check file exists, read header (~0.5ms)
3. `tail -n +2` — read value (~0.5ms)

**Total: ~1-2ms per turn.** That's a 10-30x speedup on the hot path.

---

## The Classical LRU vs. What We Actually Built

### Textbook LRU (C/Java/Python)

A classical LRU cache uses two data structures:

```
┌─────────────────────────────────────────────┐
│  Hash Map: O(1) key → node lookup           │
│  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐       │
│  │ k→n │  │ k→n │  │ k→n │  │ k→n │       │
│  └─────┘  └─────┘  └─────┘  └─────┘       │
│                                             │
│  Doubly Linked List: O(1) promote/evict     │
│  HEAD ⟷ [node A] ⟷ [node B] ⟷ [node C] ⟷ TAIL │
│  (MRU)                              (LRU)  │
└─────────────────────────────────────────────┘
```

- **Get**: Hash map lookup → pointer to node → move node to HEAD (O(1))
- **Put**: Create node at HEAD, if over capacity remove TAIL (O(1))
- **Evict**: Remove TAIL node, delete from hash map (O(1))

The doubly linked list lets you splice a node from anywhere to the front in O(1) — you just rewrite 4 pointers (prev.next, next.prev, head.prev, node.next).

### Why This Doesn't Work in Bash

Bash has no pointers, no structs, no heap-allocated objects. You can't build a doubly linked list. You could simulate one with associative arrays:

```bash
declare -A NEXT PREV VALUE
NEXT["a"]="b"; PREV["b"]="a"; VALUE["a"]="data"
```

But this lives in **shell memory**, which means:

1. **Lost in subshells.** Every `$()` command substitution creates a forked process. Variable changes inside are invisible to the parent. George's recall runs inside `$()` constantly:
   ```bash
   recall_ctx=$(recall_search_context "$task_hint" 3 2>/dev/null)
   ```
   Any in-memory cache populated inside that subshell vanishes when it returns.

2. **Lost across agent turns.** George's main loop re-enters functions on each iteration. There's no persistent process with warm memory.

3. **Bash arrays are O(n) for insertion/deletion.** Even if subshells weren't a problem, bash associative arrays use linear probing — they're slow for the pointer-chasing that makes doubly linked lists fast.

### What We Built Instead: Filesystem-as-Data-Structure

```
┌──────────────────────────────────────────────────┐
│  "Hash Map": md5sum(key) → filename              │
│  $CACHE_DIR/d41d8cd98f00b204e9800998ecf8427e     │
│  $CACHE_DIR/7d793037a0760186574b0282f2f435e7     │
│  $CACHE_DIR/e99a18c428cb38d5f260853678922e03     │
│                                                  │
│  "LRU Ordering": file mtime (managed by kernel)  │
│  oldest mtime ──────────────────── newest mtime  │
│  (evict first)                   (keep longest)  │
│                                                  │
│  "Promote": touch $file (updates mtime)          │
│  "Evict":   ls -1tr | head -N | rm              │
└──────────────────────────────────────────────────┘
```

The filesystem gives us everything we need:

| LRU Operation | Classical | Our Implementation |
|---------------|-----------|-------------------|
| **Lookup** | hash map → pointer | md5sum(key) → filename |
| **Read** | dereference node | `cat $file` |
| **Promote (move to front)** | splice 4 pointers | `touch $file` (kernel updates mtime) |
| **Evict LRU** | remove TAIL, relink | `ls -1tr \| head -1 \| rm` |
| **Count** | maintain counter | `ls -1 \| wc -l` |
| **Survives subshells?** | No | **Yes** (files persist) |

---

## How the LRU Ordering Works

The "doubly linked list" is replaced by the kernel's `mtime` (modification time) metadata on each cache file. Here's the flow:

### On `cache_put`:

```bash
# 1. Hash the key to a filename
hash=$(printf '%s' "$key" | md5sum | cut -d' ' -f1)
file="$CACHE_DIR/$hash"

# 2. Write atomically: header + value
{
    printf '%s %s\n' "$(date +%s)" "$generation"
    printf '%s' "$value"
} > "${file}.tmp" && mv "${file}.tmp" "$file"
#     ^^^^^^^^^^^^     ^^^^^^^^^^^^^^
#     Avoids partial reads    Atomic rename

# 3. The mv operation sets this file's mtime to NOW
# 4. If over capacity, evict oldest
```

### On `cache_get` (hit):

```bash
# 1. Lookup: hash key → check file exists
hash=$(_cache_hash "$key")
file="$CACHE_DIR/$hash"
[ ! -f "$file" ] && return 1  # MISS

# 2. Read header, check TTL + generation
header=$(head -1 "$file")

# 3. PROMOTE: touch updates mtime to NOW
touch "$file"
#     ^^^^^^^^^
#     This IS the LRU promotion. The file moves to
#     "most recently used" in the mtime ordering.

# 4. Return value (everything after line 1)
tail -n +2 "$file"
```

### On eviction:

```bash
# ls -1tr: list files sorted by mtime, oldest first
#   -1  one per line
#   -t  sort by mtime (newest first)
#   -r  reverse (oldest first = LRU)
ls -1tr "$CACHE_DIR" | grep -v '^\.' | head -"$to_remove" | while read name; do
    rm -f "$CACHE_DIR/$name"
done
```

### Visualizing the mtime ordering:

```
After put("A"), put("B"), put("C"):
  mtime order: A(12:00:01) — B(12:00:02) — C(12:00:03)
                 ↑ oldest (LRU)            ↑ newest (MRU)

After get("A") — touch promotes A:
  mtime order: B(12:00:02) — C(12:00:03) — A(12:00:04)
                 ↑ LRU now                  ↑ MRU now

Evict 1 entry → removes B (oldest mtime):
  mtime order: C(12:00:03) — A(12:00:04)
```

This is equivalent to the doubly linked list's "move to front" operation — we just let the kernel do the bookkeeping for us.

---

## Namespace Generation Invalidation

The most important design decision. When George reindexes the recall database (because GEORGE.md or journal.md changed), ALL cached recall queries are stale. We need to invalidate them.

### The Naive Approach (O(n))

Scan every cache file, check if it's a recall entry, delete it:
```bash
# DON'T do this — O(n) scan
for f in "$CACHE_DIR"/*; do
    header=$(head -1 "$f")
    # ... parse, check namespace, delete if recall
done
```

### Our Approach: Generation Counters (O(1))

Each namespace has a monotonically increasing generation number stored in a tiny file:

```
$CACHE_DIR/.gen.recall   →  contains "3"
$CACHE_DIR/.gen.memory   →  contains "1"
```

Every cache entry's header records what generation it was created under:

```
1710100000 3         ← epoch=1710100000, generation=3
[{"src":"ref",...}]  ← cached value
```

**On invalidation**, we just increment the counter:

```bash
cache_invalidate_ns "recall"
# .gen.recall: 3 → 4
# Cost: one write to a 1-byte file. That's it.
```

**On the next read**, every old entry fails the generation check:

```bash
# Entry header says gen=3, but .gen.recall now says 4
if [ "$entry_gen" != "$current_gen" ]; then
    rm -f "$file"     # lazy cleanup
    return 1          # MISS
fi
```

Old entries are cleaned up lazily — they're deleted when they're next accessed and found stale. No background scanner needed.

```
Before invalidation:
  .gen.recall = 3
  entry_A: gen=3 ✓ (valid)
  entry_B: gen=3 ✓ (valid)

After cache_invalidate_ns "recall":
  .gen.recall = 4
  entry_A: gen=3 ✗ → lazy delete on next access
  entry_B: gen=3 ✗ → lazy delete on next access

New entries after invalidation:
  entry_C: gen=4 ✓ (valid — matches current generation)
```

### Why Generation Counters?

They give us the critical property: **O(1) bulk invalidation without scanning**. When `recall_reindex()` runs (which touches the SQLite database), one integer increment atomically marks every cached recall query as stale. This is the same technique used by CPU cache coherency protocols (MESI) and database MVCC — just implemented with flat files.

---

## TTL Expiration

Every entry has a creation timestamp in its header:

```bash
created=1710100000  # epoch seconds at cache_put time
now=$(date +%s)     # current epoch

if (( now - created > CACHE_TTL )); then
    rm -f "$file"   # expired
    return 1        # MISS
fi
```

TTL is a safety net, not the primary invalidation mechanism. Generation counters handle intentional invalidation (reindex). TTL handles the edge case where the cache grows stale due to external changes that George doesn't know about (e.g., someone manually editing a file).

Default: `CACHE_TTL=300` (5 minutes). This is conservative — recall data rarely changes mid-session. On a phone where you want maximum responsiveness, you could safely raise it to 900 (15 minutes).

---

## The Hot Path: How Recall Uses the Cache

The integration lives in `recall_search_context()` in `lib/recall.sh`. Here's the flow:

```
recall_search_context("sandbox isolation", 3, 300)
│
├─ cache_get("recall:ctx:sandbox isolation:3:300", "recall")
│  ├─ HIT → return cached JSON immediately (1-2ms)
│  │         skip recall_ensure_indexed
│  │         skip sqlite3 fork
│  │         skip FTS5 query
│  │
│  └─ MISS → fall through ↓
│
├─ recall_ensure_indexed()     ← stat files, maybe reindex
├─ _recall_sanitize_query()    ← clean up FTS5 query
├─ sqlite3 ... FTS5 MATCH ...  ← actual BM25 search
├─ Build JSON array            ← format results
│
├─ cache_put("recall:ctx:sandbox isolation:3:300", "recall", $json)
│  └─ stored for next time
│
└─ return JSON
```

And in `recall_reindex()`:

```
recall_reindex()
│
├─ ... reindex all sources ...
├─ _recall_save_mtimes()
│
└─ cache_invalidate_ns("recall")   ← O(1), bumps .gen.recall
```

---

## Disk Layout

```
~/.george/cache/lru/
├── .stats                          # "hits misses evictions" (3 integers)
├── .gen.recall                     # generation counter for recall namespace
├── .gen.memory                     # generation counter for memory namespace
├── d41d8cd98f00b204e9800998ecf8427e  # cache entry (md5 of key)
│   ├── line 1: "1710100000 3"        #   epoch + generation
│   └── line 2+: [{"src":"ref",...}]  #   cached value (JSON)
├── 7d793037a0760186574b0282f2f435e7  # another cache entry
└── e99a18c428cb38d5f260853678922e03  # another cache entry
```

Hidden files (`.stats`, `.gen.*`) are excluded from entry counts and eviction. The `.tmp` suffix is used during atomic writes and also excluded.

---

## Tuning Guide

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CACHE_DIR` | `~/.george/cache/lru` | Where cache files live. Set to a tmpfs/ramfs mount for maximum speed. |
| `CACHE_CAPACITY` | `32` | Maximum cache entries before LRU eviction kicks in. |
| `CACHE_TTL` | `300` | Seconds before an entry expires regardless of access. |

### Tuning for Phone/Low-Memory Devices

```bash
# In your shell profile or before launching lodge:
export CACHE_CAPACITY=16     # fewer files to scan during eviction
export CACHE_TTL=600         # 10 min — recall data is stable within a session
```

Rationale: On a phone, George typically works on one project per session. The recall index changes infrequently (only when GEORGE.md or journal.md is updated). A smaller capacity means faster `ls -1tr` during eviction (16 files vs 32). Longer TTL means fewer expirations.

### Tuning for Desktop/Server (More RAM, More Projects)

```bash
export CACHE_CAPACITY=64     # more room for diverse queries
export CACHE_TTL=180         # 3 min — projects change faster on desktop
```

### Tuning for tmpfs (Maximum Speed)

If you're on Linux and want the cache to live entirely in RAM:

```bash
# Create a small tmpfs for George's cache
sudo mkdir -p /tmp/george-cache
sudo mount -t tmpfs -o size=2M tmpfs /tmp/george-cache

export CACHE_DIR=/tmp/george-cache
```

This eliminates disk I/O entirely. The cache is lost on reboot, which is fine — it rebuilds transparently on the next `cache_get` miss.

### Disabling the Cache

The cache is designed to degrade gracefully. If `cache_get` / `cache_put` are not available (i.e., `lib/cache.sh` isn't sourced), recall falls back to direct SQLite queries — exactly the behavior before the cache existed.

To disable explicitly:
```bash
# Option 1: Don't source cache.sh (remove the source line from lodge)
# Option 2: Set capacity to 0
export CACHE_CAPACITY=0
```

---

## Operator Troubleshooting

### Inspecting the Cache

```bash
# How many entries?
ls -1 ~/.george/cache/lru/ | grep -cv '^\.' 

# What's in the stats?
cat ~/.george/cache/lru/.stats
# Output: "142 38 7"  →  142 hits, 38 misses, 7 evictions

# What's the recall generation? 
cat ~/.george/cache/lru/.gen.recall
# Output: "5"

# Peek at a cache entry:
head -1 ~/.george/cache/lru/d41d8cd98f00b204e9800998ecf8427e
# Output: "1710100000 5"  →  created at epoch 1710100000, generation 5

# See what's cached (sorted by age, oldest first):
ls -1tr ~/.george/cache/lru/ | grep -v '^\.'

# See what's cached (sorted by age, newest first = most recently used):
ls -1t ~/.george/cache/lru/ | grep -v '^\.'
```

### The Cache Seems Stale

If George is returning outdated recall results:

```bash
# Option 1: Force recall reindex (automatically invalidates cache)
# Inside a George session:
/recall sandbox   # any query triggers ensure_indexed → reindex if needed

# Option 2: Manually invalidate the recall namespace
source ~/blue-lodge/lib/cache.sh
cache_invalidate_ns "recall"

# Option 3: Nuclear — clear everything
source ~/blue-lodge/lib/cache.sh
cache_clear
```

### Cache Is Using Too Much Disk

Each entry is typically 200-500 bytes (JSON recall results). At capacity 32, that's ~16KB. Even at capacity 128, it's ~64KB. This should never be a disk space concern.

If it is (very constrained device):
```bash
export CACHE_CAPACITY=8
```

### Hit Rate Is Low

Check stats:
```bash
source ~/blue-lodge/lib/cache.sh
cache_stats
# Output: hits=12 misses=45 evictions=3 rate=21%
```

Low hit rate typically means:
- **Diverse queries**: George is asking different questions each turn (normal for exploratory work). The cache helps most during repetitive loops (build→fail→retry→build).
- **TTL too short**: Entries expire before being reused. Try `CACHE_TTL=600`.
- **Capacity too small**: Entries get evicted before reuse. Try `CACHE_CAPACITY=64`.
- **Frequent reindexing**: If GEORGE.md changes every turn, generation invalidation fires constantly. This is expected — the cache gracefully degrades to direct SQLite.

---

## Function Reference

| Function | Arguments | Returns | Description |
|----------|-----------|---------|-------------|
| `cache_init` | — | — | Creates cache directory and stats file. Idempotent. |
| `cache_get` | `key` `namespace` | stdout=value, exit 0=hit, 1=miss | Look up a cached value. Promotes on hit (touch). |
| `cache_put` | `key` `namespace` `value` | — | Store a value. Triggers eviction if over capacity. |
| `cache_invalidate` | `key` | — | Remove a single cached entry. |
| `cache_invalidate_ns` | `namespace` | — | O(1) bulk invalidation via generation bump. |
| `cache_clear` | — | — | Remove all entries and reset stats. |
| `cache_stats` | — | stdout=`hits=N misses=N evictions=N rate=N%` | Hit/miss/eviction counters. |
| `cache_count` | — | stdout=integer | Number of current cache entries. |

Internal (prefixed with `_`):

| Function | Description |
|----------|-------------|
| `_cache_hash` | md5sum key → hex filename |
| `_cache_ns_gen` | Read current generation for a namespace |
| `_cache_stat_bump` | Increment hit/miss/eviction counter |
| `_cache_evict_if_needed` | LRU eviction scan (runs after every put) |

---

## Design Tradeoffs & Limitations

### What This Gets Right

1. **Subshell survival.** The #1 constraint. Bash `$()` substitution kills in-memory state. File-backed cache survives because the filesystem is shared between parent and child processes.

2. **Zero dependencies.** No Redis, no memcached, no Python. Just `md5sum`, `stat`, `ls`, `touch`, `cat` — available on every POSIX system, Android Termux, proot-distro, ChromeOS Linux.

3. **Transparent degradation.** If `cache.sh` isn't loaded, recall works exactly as before. The cache integration uses `declare -f cache_get &>/dev/null` guards everywhere.

4. **O(1) namespace invalidation.** The generation counter pattern avoids O(n) scans through cached entries.

### What This Trades Away

1. **Eviction is O(n).** Classic LRU evicts in O(1) by removing the tail of the linked list. Our `_cache_evict_if_needed` runs `ls -1tr` which is O(n) in the number of entries. At n=32 (default capacity), this takes <1ms. At n=1000 it would be noticeable. Keep capacity reasonable.

2. **Mtime resolution.** Most Linux filesystems have 1-second mtime granularity. Two operations within the same second get the same mtime, making their LRU ordering ambiguous. The `sleep 0.1` workaround in tests addresses this, but in production, two `cache_put` calls in the same second may not evict in perfectly deterministic order. This is acceptable — LRU is a heuristic, not a contract.

3. **No atomic read-promote.** `cache_get` does `head -1` (read header), then `touch` (promote), then `tail -n +2` (read value). A concurrent process could theoretically evict the file between `head` and `tail`. In practice, George is single-threaded — this never happens.

4. **Stats are not atomic.** The hit/miss/eviction counters use read-modify-write on `.stats`. Concurrent George sessions sharing the same `CACHE_DIR` could lose counter updates. Stats are informational, not correctness-critical.

### Why Not Use SQLite for the Cache Too?

Good question — we already have SQLite for the recall index. But:

- The cache's purpose is to *avoid forking sqlite3*. Caching via SQLite would just move the fork overhead to a different database.
- File I/O for small reads (stat + cat on a 300-byte file) is faster than any SQLite query because there's no SQL parser, no query planner, no page cache warmup.
- The cache should be disposable. `rm -rf $CACHE_DIR` and you're back to normal. SQLite databases are stickier — WAL files, journal files, locks.

### Why Not a Ring Buffer / FIFO Instead of LRU?

FIFO (First In, First Out) would be simpler — just evict the oldest entry by creation time, ignoring access patterns. But George's recall queries have strong temporal locality: during a build-test-fix loop, the same `/build`, `/sandbox`, `/test` queries fire repeatedly. LRU keeps these hot entries alive while evicting one-off queries from 10 minutes ago. FIFO would evict the frequently-used build query just because it was created before the one-off query.
