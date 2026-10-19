#!/bin/bash
# ── Tests: Social Queue Concurrency, Locking & Idempotency ────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/api.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/social_blog.sh" 2>/dev/null || true

TEST_TMP=$(mktemp -d /tmp/george-social-concurrency-test-XXXXXX)
export GEORGE_CONFIG_DIR="$TEST_TMP/.george"
export GEORGE_BLOG_QUEUE_DIR="$GEORGE_CONFIG_DIR/social/queue"
export GEORGE_BLOG_HISTORY_FILE="$GEORGE_CONFIG_DIR/social/blog_history.jsonl"
export GLOBAL_SOCIAL_ENABLED=1
export AUTONOMIC_PUBLISH_SOCIAL=1
export AUTONOMIC_PUBLISH_MASTODON=1
export AUTONOMIC_PUBLISH_X=1
export AUTONOMIC_PUBLISH_BLUESKY=0
export LODGE_TEST_MODE=1
export TEST_SOCIAL_GATE_ENFORCE=0

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# Mock auth checks
_mastodon_instance_token() { echo "mock_token"; }
_x_cookie_auth_available() { return 0; }

# Mock broadcast calls to record invocations
mastodon_post() {
    echo "call" >> "$TEST_TMP/mastodon_calls.log"
    sleep 0.1
    return 0
}

x_thread() {
    echo "call" >> "$TEST_TMP/x_calls.log"
    sleep 0.1
    return 0
}

test_start "Social Queue Concurrency & Anti-Duplicate Guarantees"

describe "Parallel x_blog_sweep Mutual Exclusion"

it "prevents duplicate posts when two sweepers run simultaneously" && {
    mkdir -p "$GEORGE_BLOG_QUEUE_DIR"
    rm -f "$TEST_TMP/mastodon_calls.log" "$TEST_TMP/x_calls.log" "$GEORGE_BLOG_HISTORY_FILE"

    post_file="$GEORGE_BLOG_QUEUE_DIR/1760000000_research_gaming.txt"
    cat > "$post_file" << 'EOF'
TITLE: Emulation Architectures and Cycle-Accurate Timing
THEME: gaming_emulation
BODY:
Modern cycle-accurate emulation models hardware state transitions on exact clock boundaries.
EOF

    # Launch two simultaneous sweeps in parallel subshells
    (
        export GEORGE_CONFIG_DIR="$GEORGE_CONFIG_DIR"
        export GEORGE_BLOG_QUEUE_DIR="$GEORGE_BLOG_QUEUE_DIR"
        export GEORGE_BLOG_HISTORY_FILE="$GEORGE_BLOG_HISTORY_FILE"
        x_blog_sweep
    ) > "$TEST_TMP/sweep_worker_1.log" 2>&1 &
    pid1=$!

    (
        export GEORGE_CONFIG_DIR="$GEORGE_CONFIG_DIR"
        export GEORGE_BLOG_QUEUE_DIR="$GEORGE_BLOG_QUEUE_DIR"
        export GEORGE_BLOG_HISTORY_FILE="$GEORGE_BLOG_HISTORY_FILE"
        x_blog_sweep
    ) > "$TEST_TMP/sweep_worker_2.log" 2>&1 &
    pid2=$!

    wait "$pid1"
    wait "$pid2"

    # Exactly one worker should have transmitted to Mastodon and X
    m_count=0
    x_count=0
    [ -f "$TEST_TMP/mastodon_calls.log" ] && m_count=$(wc -l < "$TEST_TMP/mastodon_calls.log")
    [ -f "$TEST_TMP/x_calls.log" ] && x_count=$(wc -l < "$TEST_TMP/x_calls.log")

    assert_eq "$m_count" 1 "Mastodon must receive exactly one broadcast"
    assert_eq "$x_count" 1 "X must receive exactly one thread broadcast"

    # History file must contain exactly 1 completion record (JSON block with "filename")
    hist_entries=0
    [ -f "$GEORGE_BLOG_HISTORY_FILE" ] && hist_entries=$(grep -c '"filename":' "$GEORGE_BLOG_HISTORY_FILE" 2>/dev/null || echo 0)
    assert_eq "$hist_entries" 1 "History file must have exactly one entry"

    # Queue must be cleanly emptied
    remaining_files=$(ls -1 "$GEORGE_BLOG_QUEUE_DIR" 2>/dev/null | wc -l)
    assert_eq "$remaining_files" 0 "Queue directory must have 0 remaining files"

    # One worker should report publication, and the other should report lock contention
    combined_logs=$(cat "$TEST_TMP/sweep_worker_1.log" "$TEST_TMP/sweep_worker_2.log")
    assert_contains "$combined_logs" "Published and archived"
    assert_contains "$combined_logs" "Another social sweep is actively transmitting"
}

describe "Atomic Claim Mechanism"

it "safely skips file if already claimed by another worker (.processing.$$)" && {
    mkdir -p "$GEORGE_BLOG_QUEUE_DIR"
    rm -f "$TEST_TMP/mastodon_calls.log" "$TEST_TMP/x_calls.log" "$GEORGE_BLOG_HISTORY_FILE"

    post_file="$GEORGE_BLOG_QUEUE_DIR/1760000001_research_ps3.txt"
    echo "PS3 Cell Broadband Engine Research" > "$post_file"

    # Simulate another worker having atomically claimed the file
    mv "$post_file" "${post_file}.processing.88888"

    # Run x_blog_sweep - should find no unclaimed .txt files
    x_blog_sweep > "$TEST_TMP/claim_test.log" 2>&1

    m_count=0
    [ -f "$TEST_TMP/mastodon_calls.log" ] && m_count=$(wc -l < "$TEST_TMP/mastodon_calls.log")
    assert_eq "$m_count" 0 "Must not broadcast already claimed file"

    # Clean up mock file
    rm -f "${post_file}.processing.88888"
}

describe "Stale Processing File Recovery"

it "recovers orphaned .processing.* files older than 15 minutes" && {
    mkdir -p "$GEORGE_BLOG_QUEUE_DIR"
    rm -f "$TEST_TMP/mastodon_calls.log" "$TEST_TMP/x_calls.log" "$GEORGE_BLOG_HISTORY_FILE"

    stale_file="$GEORGE_BLOG_QUEUE_DIR/1760000002_research_ps4.txt.processing.77777"
    echo "PS4 Orbis OS GCN Architecture" > "$stale_file"

    # Set mtime to 20 minutes ago
    touch -d '20 minutes ago' "$stale_file"

    # Run sweep: should detect stale file, restore to .txt, and publish
    x_blog_sweep > "$TEST_TMP/stale_test.log" 2>&1

    m_count=0
    [ -f "$TEST_TMP/mastodon_calls.log" ] && m_count=$(wc -l < "$TEST_TMP/mastodon_calls.log")
    assert_eq "$m_count" 1 "Stale file must be recovered and published"

    remaining_files=$(ls -1 "$GEORGE_BLOG_QUEUE_DIR" 2>/dev/null | wc -l)
    assert_eq "$remaining_files" 0 "Queue directory must be empty after recovery"
}

describe "Platform Idempotency Guard"

it "skips platform if history shows it already succeeded for this file" && {
    mkdir -p "$GEORGE_BLOG_QUEUE_DIR"
    rm -f "$TEST_TMP/mastodon_calls.log" "$TEST_TMP/x_calls.log" "$GEORGE_BLOG_HISTORY_FILE"

    bname="1760000003_research_saturn.txt"
    post_file="$GEORGE_BLOG_QUEUE_DIR/$bname"
    echo "Sega Saturn Dual SH-2 Geometry" > "$post_file"

    # Pre-record that Mastodon succeeded previously
    cat > "$GEORGE_BLOG_HISTORY_FILE" << EOF
{
  "filename": "$bname",
  "published_at": "2026-10-13T04:00:00Z",
  "status": "partial",
  "succeeded": "Mastodon",
  "failed": "X",
  "author": "George"
}
EOF

    # Run sweep: Mastodon should be skipped, only X should be called
    x_blog_sweep > "$TEST_TMP/idempotent_test.log" 2>&1

    m_count=0
    x_count=0
    [ -f "$TEST_TMP/mastodon_calls.log" ] && m_count=$(wc -l < "$TEST_TMP/mastodon_calls.log")
    [ -f "$TEST_TMP/x_calls.log" ] && x_count=$(wc -l < "$TEST_TMP/x_calls.log")

    assert_eq "$m_count" 0 "Mastodon must be skipped since it already succeeded"
    assert_eq "$x_count" 1 "X must be called to complete partial publication"

    log_out=$(cat "$TEST_TMP/idempotent_test.log")
    assert_contains "$log_out" "Mastodon: already published for $bname — skipping duplicate"
}
