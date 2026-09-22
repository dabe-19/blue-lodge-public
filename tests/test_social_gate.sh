#!/bin/bash
# ── Tests: Global and Platform-Specific Social Gate ─────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/social.sh"
source "$LODGE_DIR/lib/social_blog.sh"

test_start "Global and Platform-Specific Social Endpoints Gate"

TMP_DIR=$(test_tmpdir)
export GEORGE_CONFIG_DIR="$TMP_DIR/.george"
mkdir -p "$GEORGE_CONFIG_DIR/social"
export TEST_SOCIAL_GATE_ENFORCE=1

describe "social_is_platform_allowed validator"

  it "blocks all platforms when GLOBAL_SOCIAL_ENABLED=0" && {
    cat > "$GEORGE_CONFIG_DIR/social/social.conf" << 'EOF'
GLOBAL_SOCIAL_ENABLED=0
X_ENABLED=1
MASTODON_ENABLED=1
BLUESKY_ENABLED=1
EOF
    GLOBAL_SOCIAL_ENABLED=0 social_is_platform_allowed "all"
    assert_neq $? 0 "Must block when global is 0"

    GLOBAL_SOCIAL_ENABLED=0 social_is_platform_allowed "x"
    assert_neq $? 0 "Must block X when global is 0 even if X_ENABLED=1"
  }

  it "permits platform only when BOTH global and platform switches are 1" && {
    cat > "$GEORGE_CONFIG_DIR/social/social.conf" << 'EOF'
GLOBAL_SOCIAL_ENABLED=1
X_ENABLED=1
MASTODON_ENABLED=0
BLUESKY_ENABLED=0
EOF
    GLOBAL_SOCIAL_ENABLED=1 X_ENABLED=1 social_is_platform_allowed "x"
    assert_ok $? "Must allow X when both global and X are 1"

    GLOBAL_SOCIAL_ENABLED=1 MASTODON_ENABLED=0 social_is_platform_allowed "mastodon"
    assert_neq $? 0 "Must block Mastodon when MASTODON_ENABLED=0"
  }

describe "Social Posting Function Guards"

  it "x_post aborts and warns when social gate is locked" && {
    cat > "$GEORGE_CONFIG_DIR/social/social.conf" << 'EOF'
GLOBAL_SOCIAL_ENABLED=0
X_ENABLED=0
EOF
    out=$(GLOBAL_SOCIAL_ENABLED=0 X_ENABLED=0 x_post "Test post" 2>&1)
    status=$?
    assert_neq $status 0 "x_post must fail when gate is locked"
    assert_contains "$out" "X broadcast aborted: Social gate is locked"
  }

  it "mastodon_post aborts and warns when social gate is locked" && {
    cat > "$GEORGE_CONFIG_DIR/social/social.conf" << 'EOF'
GLOBAL_SOCIAL_ENABLED=0
MASTODON_ENABLED=0
EOF
    out=$(GLOBAL_SOCIAL_ENABLED=0 MASTODON_ENABLED=0 mastodon_post "Test post" 2>&1)
    status=$?
    assert_neq $status 0 "mastodon_post must fail when gate is locked"
    assert_contains "$out" "Mastodon broadcast aborted: Social gate is locked"
  }

  it "bluesky_post aborts and warns when social gate is locked" && {
    cat > "$GEORGE_CONFIG_DIR/social/social.conf" << 'EOF'
GLOBAL_SOCIAL_ENABLED=0
BLUESKY_ENABLED=0
EOF
    out=$(GLOBAL_SOCIAL_ENABLED=0 BLUESKY_ENABLED=0 bluesky_post "Test post" 2>&1)
    status=$?
    assert_neq $status 0 "bluesky_post must fail when gate is locked"
    assert_contains "$out" "Bluesky broadcast aborted: Social gate is locked"
  }

describe "x_blog_sweep Gate Integration"

  it "x_blog_sweep pauses and retains queue when global gate is locked" && {
    cat > "$GEORGE_CONFIG_DIR/social/social.conf" << 'EOF'
GLOBAL_SOCIAL_ENABLED=0
X_ENABLED=1
EOF
    out=$(GLOBAL_SOCIAL_ENABLED=0 x_blog_sweep 2>&1)
    assert_contains "$out" "Global Social gate is locked"
  }

test_end
