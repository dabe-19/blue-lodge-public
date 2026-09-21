#!/bin/bash
# ── Tests: Autonomous Research Graph & Mobile Endpoints ───────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/research_graph.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mcp_server_gitea.sh" 2>/dev/null || true
source "$LODGE_DIR/commands/research.sh" 2>/dev/null || true
source "$LODGE_DIR/commands/gitea.sh" 2>/dev/null || true

# Test sandbox isolation
TEST_TMP=$(mktemp -d /tmp/george-research-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export RESEARCH_DIR="$GEORGE_DIR/research"
export RESEARCH_INDEX="$RESEARCH_DIR/research_index.jsonl"
export RESEARCH_QUEUE_DIR="$GEORGE_DIR/social/queue"
export GITEA_CONF="$GEORGE_DIR/gitea.conf"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "Autonomous Research Graph Engine"

describe "research_init"
it "initializes research directories" && {
    research_init
    assert_dir_exists "$RESEARCH_DIR"
    assert_dir_exists "$RESEARCH_QUEUE_DIR"
}

describe "research_slugify"
it "generates clean url-safe slugs" && {
    s=$(research_slugify "Baruch Spinoza: Monism & Tensor Manifolds!")
    assert_eq "$s" "baruch-spinoza-monism-tensor-manifolds"
}

describe "research_discover_topic"
it "discovers open-ended inquiry topics" && {
    t=$(research_discover_topic)
    assert_not_empty "$t"
}

describe "research_graph_run"
it "executes autonomous research graph, builds dossier, and queues thread" && {
    research_graph_run "Entropy Bounds in 4-bit KV Cache"
    assert_file_exists "$RESEARCH_INDEX"

    slug="entropy-bounds-in-4-bit-kv-cache"
    assert_dir_exists "$RESEARCH_DIR/$slug"
    assert_file_exists "$RESEARCH_DIR/$slug/dossier.md"
    assert_file_exists "$RESEARCH_DIR/$slug/thread.md"

    # Verify queue has the research piece
    q_count=$(ls -1 "$RESEARCH_QUEUE_DIR"/*.txt 2>/dev/null | wc -l)
    assert_gt "$q_count" 0

    # Verify dossier content
    dossier_content=$(cat "$RESEARCH_DIR/$slug/dossier.md")
    assert_contains "$dossier_content" "Entropy Bounds in 4-bit KV Cache"
    assert_contains "$dossier_content" "Executive Abstract"
}

describe "research_query_sources"
it "retrieves dossier via research_query_sources" && {
    out=$(research_query_sources "entropy-bounds-in-4-bit-kv-cache" 2>&1)
    assert_contains "$out" "Executive Abstract"
}

describe "cmd_research"
it "dispatches /research slash commands" && {
    list_out=$(cmd_research "list" 2>&1)
    assert_contains "$list_out" "entropy-bounds-in-4-bit-kv-cache"
}

describe "Sovereign Gitea Dynamic Endpoint Configuration"

it "updates Gitea endpoint via gitea_set_endpoint" && {
    gitea_set_endpoint "http://llama.cpp-prism:3088"
    assert_eq "$GITEA_URL" "http://llama.cpp-prism:3088"
    assert_file_exists "$GITEA_CONF"
    conf_content=$(cat "$GITEA_CONF")
    assert_contains "$conf_content" "http://llama.cpp-prism:3088"
}

it "dispatches /gitea endpoint command to view and switch endpoint" && {
    out1=$(cmd_gitea "endpoint" 2>&1)
    assert_contains "$out1" "http://llama.cpp-prism:3088"

    out2=$(cmd_gitea "endpoint http://192.168.1.150:3088" 2>&1)
    assert_contains "$out2" "Updated Gitea endpoint to: http://192.168.1.150:3088"
    _gitea_load_conf
    assert_eq "$GITEA_URL" "http://192.168.1.150:3088"
}

test_end
