#!/bin/bash
# ── George: LRU Cache ──────────────────────────────────────────
# Pure-bash file-backed LRU cache with namespace generation-based
# invalidation. All state lives on disk so it survives subshells
# ($() command substitution), which is the key constraint for George.
#
# Primary use: caching recall (SQLite FTS5) queries that would
# otherwise fork sqlite3 (~10-30ms) on every agent turn. On cache
# hit the cost drops to stat + cat on tmpfs (~1ms).
#
# Data layout:
#   $CACHE_DIR/<hash>         — line 1: epoch gen, line 2+: value
#   $CACHE_DIR/.gen.<ns>      — generation counter for namespace
#   $CACHE_DIR/.stats         — hits misses evictions
#
# LRU strategy: file mtime = last access time. On eviction, the
# file with the oldest mtime is removed first (true LRU).
#
# Namespace invalidation: O(1). Bumping the generation counter
# makes all entries created under the old generation stale on
# their next read — no scanning required.

[ -n "${_LIB_CACHE_LOADED:-}" ] && return 0; _LIB_CACHE_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR:-.}/.george}"

# ── Config ─────────────────────────────────────────────────────
CACHE_DIR="${CACHE_DIR:-$GEORGE_DIR/cache/lru}"
CACHE_CAPACITY="${CACHE_CAPACITY:-32}"      # max entries before eviction
CACHE_TTL="${CACHE_TTL:-300}"               # seconds before expiry (5 min)

# ── Initialize cache directory ─────────────────────────────────
cache_init() {
    [ -d "$CACHE_DIR" ] && return 0
    mkdir -p "$CACHE_DIR"
    echo "0 0 0" > "$CACHE_DIR/.stats"
}

# ── Hash key → filename-safe hex string ────────────────────────
# Uses md5sum (GNU/Android) with cksum fallback (POSIX).
_cache_hash() {
    printf '%s' "$1" | md5sum 2>/dev/null | cut -d' ' -f1 \
        || printf '%s' "$1" | cksum | cut -d' ' -f1
}

# ── Read current generation for a namespace ────────────────────
_cache_ns_gen() {
    local ns="$1"
    local gen_file="$CACHE_DIR/.gen.${ns}"
    if [ -f "$gen_file" ]; then
        cat "$gen_file"
    else
        echo "0"
    fi
}

# ── Bump a stats counter ──────────────────────────────────────
_cache_stat_bump() {
    local which="$1"  # hit | miss | evict
    local stats_file="$CACHE_DIR/.stats"
    [ -f "$stats_file" ] || echo "0 0 0" > "$stats_file"
    local hits misses evictions
    read -r hits misses evictions < "$stats_file" 2>/dev/null \
        || { hits=0; misses=0; evictions=0; }
    case "$which" in
        hit)   hits=$((hits + 1)) ;;
        miss)  misses=$((misses + 1)) ;;
        evict) evictions=$((evictions + 1)) ;;
    esac
    echo "$hits $misses $evictions" > "$stats_file"
}

# ── Get a cached value ─────────────────────────────────────────
# Usage: value=$(cache_get "recall:ctx:query:3" "recall")
# Returns 0 on hit (value on stdout), 1 on miss.
cache_get() {
    local key="$1"
    local ns="${2:-default}"

    local hash
    hash=$(_cache_hash "$key")
    local file="$CACHE_DIR/$hash"

    # Miss: no file
    if [ ! -f "$file" ]; then
        _cache_stat_bump miss
        return 1
    fi

    # Read header: epoch generation
    local header
    header=$(head -1 "$file")
    local created gen
    read -r created gen <<< "$header"

    # TTL check
    local now
    now=$(date +%s)
    if (( now - created > CACHE_TTL )); then
        rm -f "$file"
        _cache_stat_bump miss
        return 1
    fi

    # Generation check — stale if namespace generation advanced
    local current_gen
    current_gen=$(_cache_ns_gen "$ns")
    if [ "$gen" != "$current_gen" ]; then
        rm -f "$file"
        _cache_stat_bump miss
        return 1
    fi

    # Hit: promote (touch mtime for LRU ordering) and return value
    touch "$file" 2>/dev/null
    tail -n +2 "$file"
    _cache_stat_bump hit
    return 0
}

# ── Store a value in the cache ─────────────────────────────────
# Usage: cache_put "recall:ctx:query:3" "recall" "$json_value"
cache_put() {
    local key="$1"
    local ns="${2:-default}"
    local value="$3"

    cache_init

    local hash
    hash=$(_cache_hash "$key")
    local file="$CACHE_DIR/$hash"
    local now
    now=$(date +%s)
    local gen
    gen=$(_cache_ns_gen "$ns")

    # Atomic write: tmp → rename
    {
        printf '%s %s\n' "$now" "$gen"
        printf '%s' "$value"
    } > "${file}.tmp" && mv "${file}.tmp" "$file"

    # Evict if over capacity
    _cache_evict_if_needed
}

# ── Invalidate a single key ───────────────────────────────────
cache_invalidate() {
    local key="$1"
    local hash
    hash=$(_cache_hash "$key")
    rm -f "$CACHE_DIR/$hash"
}

# ── Invalidate entire namespace (O(1)) ────────────────────────
# Bumps the generation counter so all entries created under the
# old generation become stale on their next read.
cache_invalidate_ns() {
    local ns="$1"
    local gen_file="$CACHE_DIR/.gen.${ns}"
    cache_init
    local current
    current=$(_cache_ns_gen "$ns")
    echo "$((current + 1))" > "$gen_file"
}

# ── Clear entire cache ────────────────────────────────────────
cache_clear() {
    if [ -d "$CACHE_DIR" ]; then
        rm -rf "$CACHE_DIR"
        mkdir -p "$CACHE_DIR"
        echo "0 0 0" > "$CACHE_DIR/.stats"
    fi
}

# ── Evict LRU entries when over capacity ──────────────────────
# Counts cache entries. If over CACHE_CAPACITY, removes files
# with the oldest mtime (least recently used) first.
_cache_evict_if_needed() {
    [ -d "$CACHE_DIR" ] || return 0

    # Count cache entries (exclude hidden .stats/.gen.* and .tmp files)
    local count
    count=$(ls -1 "$CACHE_DIR" 2>/dev/null | grep -cv '^\.\|\.tmp$' || echo "0")

    if (( count > CACHE_CAPACITY )); then
        local to_remove=$(( count - CACHE_CAPACITY ))
        # ls -1tr: reverse time sort (oldest mtime first = LRU)
        ls -1tr "$CACHE_DIR" 2>/dev/null \
            | grep -v '^\.\|\.tmp$' \
            | head -"$to_remove" \
            | while read -r name; do
                rm -f "$CACHE_DIR/$name"
                _cache_stat_bump evict
            done
    fi
}

# ── Statistics ─────────────────────────────────────────────────
# Returns: hits=N misses=N evictions=N rate=N%
cache_stats() {
    local stats_file="$CACHE_DIR/.stats"
    if [ -f "$stats_file" ]; then
        local hits misses evictions
        read -r hits misses evictions < "$stats_file"
        local total=$((hits + misses))
        local rate=0
        (( total > 0 )) && rate=$(( (hits * 100) / total ))
        printf 'hits=%s misses=%s evictions=%s rate=%s%%' \
            "$hits" "$misses" "$evictions" "$rate"
    else
        echo "hits=0 misses=0 evictions=0 rate=0%"
    fi
}

# ── Entry count ───────────────────────────────────────────────
cache_count() {
    if [ -d "$CACHE_DIR" ]; then
        local _cc_count
        _cc_count=$(ls -1 "$CACHE_DIR" 2>/dev/null | grep -cv '^\.\|\.tmp$')
        echo "${_cc_count:-0}"
    else
        echo "0"
    fi
}
