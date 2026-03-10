#!/bin/bash
# ── Tests: lib/cache.sh — LRU Cache ──────────────────────────
source "$(dirname "$0")/framework.sh"

# Use an isolated cache dir for every test
GEORGE_DIR=$(test_tmpdir)
CACHE_DIR="$GEORGE_DIR/cache/lru"
export GEORGE_DIR CACHE_DIR

source "$LODGE_DIR/lib/cache.sh"

test_start "lib/cache.sh — LRU Cache"

_reset_cache() {
    rm -rf "$CACHE_DIR"
    _LIB_CACHE_LOADED=""
    CACHE_CAPACITY=32
    CACHE_TTL=300
    source "$LODGE_DIR/lib/cache.sh"
}

# ── cache_init ─────────────────────────────────────────────────
describe "cache_init"

  it "creates the cache directory" && {
    _reset_cache
    cache_init
    assert_dir_exists "$CACHE_DIR"
  }

  it "creates the .stats file" && {
    _reset_cache
    cache_init
    assert_file_exists "$CACHE_DIR/.stats"
    stats=$(cat "$CACHE_DIR/.stats")
    assert_eq "$stats" "0 0 0"
  }

  it "is idempotent" && {
    _reset_cache
    cache_init
    echo "5 3 1" > "$CACHE_DIR/.stats"
    cache_init
    stats=$(cat "$CACHE_DIR/.stats")
    assert_eq "$stats" "5 3 1" "stats should not be reset on re-init"
  }

# ── _cache_hash ────────────────────────────────────────────────
describe "_cache_hash"

  it "returns a non-empty hash" && {
    h=$(_cache_hash "test-key")
    assert_not_empty "$h"
  }

  it "returns identical hash for same key" && {
    h1=$(_cache_hash "same-key")
    h2=$(_cache_hash "same-key")
    assert_eq "$h1" "$h2"
  }

  it "returns different hashes for different keys" && {
    h1=$(_cache_hash "key-alpha")
    h2=$(_cache_hash "key-beta")
    assert_neq "$h1" "$h2"
  }

# ── cache_put / cache_get ──────────────────────────────────────
describe "cache_put + cache_get"

  it "stores and retrieves a simple value" && {
    _reset_cache
    cache_put "greeting" "default" "hello world"
    val=$(cache_get "greeting" "default")
    assert_eq "$val" "hello world"
  }

  it "returns exit 0 on cache hit" && {
    _reset_cache
    cache_put "k1" "default" "v1"
    cache_get "k1" "default" >/dev/null
    assert_ok $?
  }

  it "returns exit 1 on cache miss" && {
    _reset_cache
    cache_get "no-such-key" "default" >/dev/null 2>&1
    assert_fail $?
  }

  it "stores and retrieves multi-line values" && {
    _reset_cache
    multi=$(printf 'line one\nline two\nline three')
    cache_put "multi" "default" "$multi"
    val=$(cache_get "multi" "default")
    assert_eq "$val" "$multi"
  }

  it "stores and retrieves JSON values" && {
    _reset_cache
    json='[{"src":"ref","sec":"Sandbox","body":"isolation"}]'
    cache_put "recall:sandbox" "recall" "$json"
    val=$(cache_get "recall:sandbox" "recall")
    assert_eq "$val" "$json"
  }

  it "handles empty string values" && {
    _reset_cache
    cache_put "empty" "default" ""
    val=$(cache_get "empty" "default")
    assert_eq "$val" ""
  }

  it "overwrites existing keys" && {
    _reset_cache
    cache_put "k" "default" "old"
    cache_put "k" "default" "new"
    val=$(cache_get "k" "default")
    assert_eq "$val" "new"
  }

# ── TTL expiration ─────────────────────────────────────────────
describe "TTL expiration"

  it "expires entries older than CACHE_TTL" && {
    _reset_cache
    cache_put "ttl-test" "default" "ephemeral"
    # Backdate the creation timestamp to 1 hour ago
    hash=$(_cache_hash "ttl-test")
    file="$CACHE_DIR/$hash"
    old_epoch=$(( $(date +%s) - 3600 ))
    # Rewrite with old timestamp
    val=$(tail -n +2 "$file")
    gen=$(head -1 "$file" | awk '{print $2}')
    { printf '%s %s\n' "$old_epoch" "$gen"; printf '%s' "$val"; } > "$file"
    # Should miss now
    cache_get "ttl-test" "default" >/dev/null 2>&1
    assert_fail $? "expired entry should be a cache miss"
  }

  it "serves entries within CACHE_TTL" && {
    _reset_cache
    CACHE_TTL=9999
    cache_put "fresh" "default" "still-good"
    val=$(cache_get "fresh" "default")
    assert_eq "$val" "still-good"
    CACHE_TTL=300
  }

# ── Namespace generation invalidation ─────────────────────────
describe "namespace invalidation"

  it "invalidates all entries in a namespace" && {
    _reset_cache
    cache_put "recall:q1" "recall" "result1"
    cache_put "recall:q2" "recall" "result2"
    # Both should hit
    cache_get "recall:q1" "recall" >/dev/null
    assert_ok $? "q1 should hit before invalidation"
    cache_get "recall:q2" "recall" >/dev/null
    assert_ok $? "q2 should hit before invalidation"
    # Invalidate recall namespace
    cache_invalidate_ns "recall"
    # Both should miss now
    cache_get "recall:q1" "recall" >/dev/null 2>&1
    assert_fail $? "q1 should miss after namespace invalidation"
    cache_get "recall:q2" "recall" >/dev/null 2>&1
    assert_fail $? "q2 should miss after namespace invalidation"
  }

  it "does not affect other namespaces" && {
    _reset_cache
    cache_put "recall:q" "recall" "recall-data"
    cache_put "memory:p" "memory" "memory-data"
    cache_invalidate_ns "recall"
    # recall should miss
    cache_get "recall:q" "recall" >/dev/null 2>&1
    assert_fail $? "recall entry should miss"
    # memory should still hit
    val=$(cache_get "memory:p" "memory")
    assert_eq "$val" "memory-data" "memory entry should survive"
  }

  it "allows new entries after invalidation" && {
    _reset_cache
    cache_put "k" "ns" "old"
    cache_invalidate_ns "ns"
    cache_put "k" "ns" "new"
    val=$(cache_get "k" "ns")
    assert_eq "$val" "new"
  }

# ── cache_invalidate (single key) ─────────────────────────────
describe "cache_invalidate"

  it "removes a specific key" && {
    _reset_cache
    cache_put "a" "default" "alpha"
    cache_put "b" "default" "beta"
    cache_invalidate "a"
    cache_get "a" "default" >/dev/null 2>&1
    assert_fail $? "invalidated key should miss"
    val=$(cache_get "b" "default")
    assert_eq "$val" "beta" "non-invalidated key should survive"
  }

# ── LRU eviction ──────────────────────────────────────────────
describe "LRU eviction"

  it "evicts oldest entry when over capacity" && {
    _reset_cache
    CACHE_CAPACITY=3
    # Fill cache
    cache_put "e1" "default" "val1"
    sleep 0.1  # ensure distinct mtimes
    cache_put "e2" "default" "val2"
    sleep 0.1
    cache_put "e3" "default" "val3"
    sleep 0.1
    # This should evict e1 (oldest mtime)
    cache_put "e4" "default" "val4"
    # e1 should be gone
    cache_get "e1" "default" >/dev/null 2>&1
    assert_fail $? "oldest entry should be evicted"
    # e4 should exist
    val=$(cache_get "e4" "default")
    assert_eq "$val" "val4"
    CACHE_CAPACITY=32
  }

  it "promotes accessed entries (true LRU)" && {
    _reset_cache
    CACHE_CAPACITY=3
    cache_put "lru1" "default" "v1"
    sleep 0.1
    cache_put "lru2" "default" "v2"
    sleep 0.1
    cache_put "lru3" "default" "v3"
    sleep 0.1
    # Access lru1 to promote it (updates mtime)
    cache_get "lru1" "default" >/dev/null
    sleep 0.1
    # Adding lru4 should evict lru2 (now the oldest mtime), not lru1
    cache_put "lru4" "default" "v4"
    # lru1 should survive (was promoted)
    cache_get "lru1" "default" >/dev/null
    assert_ok $? "promoted entry should survive eviction"
    # lru2 should be evicted (oldest mtime after lru1 was promoted)
    cache_get "lru2" "default" >/dev/null 2>&1
    assert_fail $? "unpromoted oldest entry should be evicted"
    CACHE_CAPACITY=32
  }

# ── cache_clear ────────────────────────────────────────────────
describe "cache_clear"

  it "removes all entries" && {
    _reset_cache
    cache_put "c1" "default" "v1"
    cache_put "c2" "default" "v2"
    cache_clear
    cache_get "c1" "default" >/dev/null 2>&1
    assert_fail $? "c1 should miss after clear"
    cache_get "c2" "default" >/dev/null 2>&1
    assert_fail $? "c2 should miss after clear"
  }

  it "resets stats" && {
    _reset_cache
    cache_put "s" "default" "v"
    cache_get "s" "default" >/dev/null
    cache_clear
    stats=$(cache_stats)
    assert_contains "$stats" "hits=0"
  }

# ── cache_stats ────────────────────────────────────────────────
describe "cache_stats"

  it "tracks hits and misses" && {
    _reset_cache
    cache_put "st" "default" "val"
    cache_get "st" "default" >/dev/null       # hit
    cache_get "st" "default" >/dev/null       # hit
    cache_get "miss1" "default" >/dev/null 2>&1  # miss
    stats=$(cache_stats)
    assert_contains "$stats" "hits=2"
    assert_contains "$stats" "misses=1"
  }

  it "calculates hit rate" && {
    _reset_cache
    cache_put "r1" "default" "v"
    cache_get "r1" "default" >/dev/null   # hit
    cache_get "r1" "default" >/dev/null   # hit
    cache_get "r1" "default" >/dev/null   # hit
    cache_get "nope" "default" >/dev/null 2>&1  # miss
    stats=$(cache_stats)
    assert_contains "$stats" "rate=75%"
  }

# ── cache_count ────────────────────────────────────────────────
describe "cache_count"

  it "returns number of cached entries" && {
    _reset_cache
    cache_put "cnt1" "default" "v"
    cache_put "cnt2" "default" "v"
    cache_put "cnt3" "default" "v"
    count=$(cache_count)
    assert_eq "$count" "3"
  }

  it "returns 0 for empty cache" && {
    _reset_cache
    cache_init
    count=$(cache_count)
    assert_eq "$count" "0"
  }

# ── Subshell survival ─────────────────────────────────────────
describe "subshell survival"

  it "cache_put in parent is visible in subshell" && {
    _reset_cache
    cache_put "parent-key" "default" "parent-val"
    val=$(cache_get "parent-key" "default")
    assert_eq "$val" "parent-val"
  }

  it "cache_put in subshell is visible in parent" && {
    _reset_cache
    # Put inside a subshell (like how recall runs)
    $(cache_put "sub-key" "default" "sub-val")
    val=$(cache_get "sub-key" "default")
    assert_eq "$val" "sub-val"
  }

# ── Integration: recall namespace pattern ──────────────────────
describe "recall integration pattern"

  it "caches a recall-style query and retrieves it" && {
    _reset_cache
    query="sandbox isolation"
    json='[{"src":"ref","sec":"Sandboxes","body":"Project isolation via proot"}]'
    key="recall:ctx:${query}:3:300"
    cache_put "$key" "recall" "$json"
    val=$(cache_get "$key" "recall")
    assert_eq "$val" "$json"
  }

  it "invalidate_ns recall clears all recall entries" && {
    _reset_cache
    cache_put "recall:ctx:q1:3:300" "recall" '{"q":"1"}'
    cache_put "recall:ctx:q2:3:300" "recall" '{"q":"2"}'
    cache_invalidate_ns "recall"
    cache_get "recall:ctx:q1:3:300" "recall" >/dev/null 2>&1
    assert_fail $? "recall q1 should miss after ns invalidation"
    cache_get "recall:ctx:q2:3:300" "recall" >/dev/null 2>&1
    assert_fail $? "recall q2 should miss after ns invalidation"
  }

# ── Edge cases ─────────────────────────────────────────────────
describe "edge cases"

  it "handles keys with special characters" && {
    _reset_cache
    cache_put "recall:ctx:what is /sandbox?:3:300" "recall" "safe"
    val=$(cache_get "recall:ctx:what is /sandbox?:3:300" "recall")
    assert_eq "$val" "safe"
  }

  it "handles values with single quotes" && {
    _reset_cache
    cache_put "sq" "default" "it's working"
    val=$(cache_get "sq" "default")
    assert_eq "$val" "it's working"
  }

  it "handles values with dollar signs" && {
    _reset_cache
    cache_put "ds" "default" 'price is $100'
    val=$(cache_get "ds" "default")
    assert_eq "$val" 'price is $100'
  }

  it "handles concurrent namespace invalidation" && {
    _reset_cache
    cache_put "k" "ns" "v1"
    cache_invalidate_ns "ns"
    cache_invalidate_ns "ns"  # double invalidation
    cache_put "k" "ns" "v2"  # new entry at gen=2
    val=$(cache_get "k" "ns")
    assert_eq "$val" "v2"
  }

test_end
