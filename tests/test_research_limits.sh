#!/bin/bash
# ── Tests: Research Limits, Social Sweeps, & Lifecycle ───────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/limits.sh"
source "$LODGE_DIR/lib/social_blog.sh"
source "$LODGE_DIR/lib/transcript.sh"

test_start "Autonomous Research Limits & Decoupled Social Distribution"

TMP_RES_DIR=$(test_tmpdir)
export GEORGE_DIR="$TMP_RES_DIR/.george"
export LIMITS_CONF="$GEORGE_DIR/limits.conf"
mkdir -p "$GEORGE_DIR"

describe "MAX_RESEARCH_TURNS Operational Lever"

  it "defaults to 200 turns" && {
    limits_init
    val=$(limits_get MAX_RESEARCH_TURNS)
    assert_eq "$val" "200"
  }

  it "allows updating MAX_RESEARCH_TURNS lever" && {
    limits_set MAX_RESEARCH_TURNS 175
    val=$(limits_get MAX_RESEARCH_TURNS)
    assert_eq "$val" "175"
  }

  it "resets MAX_RESEARCH_TURNS to 200 default" && {
    limits_reset
    val=$(limits_get MAX_RESEARCH_TURNS)
    assert_eq "$val" "200"
  }

describe "Decoupled Social Blog Distribution (x_blog_sweep)"

  it "skips all social platforms when AUTONOMIC_PUBLISH_SOCIAL=0" && {
    out=$(AUTONOMIC_PUBLISH_SOCIAL=0 x_blog_sweep "$TMP_RES_DIR" 2>&1)
    assert_contains "$out" "social publishing is paused"
  }

  it "skips X when AUTONOMIC_PUBLISH_X=0 but proceeds with sweep" && {
    blog_init
    dummy_post="$GEORGE_BLOG_QUEUE_DIR/test_post_$$.txt"
    echo "Title: Test Research Post" > "$dummy_post"
    echo "Body: Test research insights" >> "$dummy_post"

    out=$(AUTONOMIC_PUBLISH_SOCIAL=1 AUTONOMIC_PUBLISH_X=0 AUTONOMIC_PUBLISH_MASTODON=1 AUTONOMIC_PUBLISH_BLUESKY=0 x_blog_sweep "$TMP_RES_DIR" 2>&1)
    assert_contains "$out" "X publishing disabled"
    
    rm -f "$dummy_post"
  }

  it "provides clean diagnostic skip message when Mastodon key is missing" && {
    blog_init
    dummy_post="$GEORGE_BLOG_QUEUE_DIR/test_masto_$$.txt"
    echo "Title: Test Mastodon Post" > "$dummy_post"
    echo "Body: Test research insights" >> "$dummy_post"

    out=$(AUTONOMIC_PUBLISH_SOCIAL=1 AUTONOMIC_PUBLISH_X=0 AUTONOMIC_PUBLISH_MASTODON=1 AUTONOMIC_PUBLISH_BLUESKY=0 MASTODON_ACCESS_TOKEN="" x_blog_sweep "$TMP_RES_DIR" 2>&1)
    assert_contains "$out" "Mastodon: instance or access token not configured"

    rm -f "$dummy_post"
  }

describe "Transcript File Lifecycle Guard"

  it "cleans up transcript file handle safely before directory removal" && {
    mkdir -p "$TMP_RES_DIR/sandbox/.george/transcripts"
    transcript_start "test_tr" "$TMP_RES_DIR/sandbox"
    transcript_log "test" "Message 1"
    
    # Safe shutdown
    transcript_stop
    _TRANSCRIPT_FILE=""
    rm -rf "$TMP_RES_DIR/sandbox"
    
    # Subsequent ui logging shouldn't crash with No such file or directory
    err=$(ui_step "Step after sandbox deleted" 2>&1)
    assert_not_contains "$err" "No such file or directory"
  }

rm -rf "$TMP_RES_DIR"
test_end
