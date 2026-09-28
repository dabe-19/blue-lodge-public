#!/bin/bash
# INTERVAL: 14400
# DESC: Autonomous Research & Sovereign Blog Publisher
# PUBLISH_SOCIAL: 1
# PUBLISH_X: 0
# PUBLISH_MASTODON: 1
# PUBLISH_BLUESKY: 0

# ══════════════════════════════════════════════════════════════════════
# George Sovereign Research & Social Publishing Gate
# ══════════════════════════════════════════════════════════════════════
# Per-platform broadcast levers (1 = enabled, 0 = disabled):
# By default, AUTONOMIC_PUBLISH_X=0 prevents live tweet-thread flooding.
# Content will synthesize and safely stage in .george/social/queue/.
# ══════════════════════════════════════════════════════════════════════

_hdr_social=$(grep -m1 '^# PUBLISH_SOCIAL:' "$0" 2>/dev/null | awk '{print $3}')
_hdr_x=$(grep -m1 '^# PUBLISH_X:' "$0" 2>/dev/null | awk '{print $3}')
_hdr_masto=$(grep -m1 '^# PUBLISH_MASTODON:' "$0" 2>/dev/null | awk '{print $3}')
_hdr_bsky=$(grep -m1 '^# PUBLISH_BLUESKY:' "$0" 2>/dev/null | awk '{print $3}')

export AUTONOMIC_PUBLISH_SOCIAL="${AUTONOMIC_PUBLISH_SOCIAL:-${_hdr_social:-0}}"
export AUTONOMIC_PUBLISH_X="${AUTONOMIC_PUBLISH_X:-${_hdr_x:-0}}"
export AUTONOMIC_PUBLISH_MASTODON="${AUTONOMIC_PUBLISH_MASTODON:-${_hdr_mastodon:-1}}"
export AUTONOMIC_PUBLISH_BLUESKY="${AUTONOMIC_PUBLISH_BLUESKY:-${_hdr_bluesky:-0}}"

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/api.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/pgp.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/social.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/social_blog.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/research_graph.sh" 2>/dev/null || true

ui_step "Executing Autonomous Research & Sovereign Blog publisher..."

# If queue is empty, trigger the Autonomous Research Graph to synthesize a new dossier & thread
QUEUE_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/social/queue"
mkdir -p "$QUEUE_DIR"
queue_files=("$QUEUE_DIR"/*.txt)

if [ ! -e "${queue_files[0]}" ]; then
    ui_info "Research queue is empty — initiating Autonomous Research Graph..."
    research_graph_run
fi

# Run the sweep across all configured platforms (Mastodon, Bluesky, X)
# Each platform will only publish if explicitly enabled (=1)
x_blog_sweep
exit $?
