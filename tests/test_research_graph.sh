#!/bin/bash
# ── Tests: Autonomous Research Graph & Mobile Endpoints ───────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/research_graph.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
source "$LODGE_DIR/commands/research.sh" 2>/dev/null || true
source "$LODGE_DIR/commands/gitea.sh" 2>/dev/null || true

# Test sandbox isolation
TEST_TMP=$(mktemp -d /tmp/george-research-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export RESEARCH_DIR="$GEORGE_DIR/research"
export RESEARCH_INDEX="$RESEARCH_DIR/research_index.jsonl"
export RESEARCH_QUEUE_DIR="$GEORGE_DIR/social/queue"
export RESEARCH_QUARANTINE_DIR="$RESEARCH_DIR/quarantine"
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
  it "discovers open-ended inquiry topics" && assert_not_empty "$(research_discover_topic)"

describe "research_classify_domain"
  it "correctly classifies domains without false substring matches" && {
    assert_eq "$(research_classify_domain "Zero-Knowledge State Proofs on Cardano")" "academic"
    assert_eq "$(research_classify_domain "Cardano DeFi Yield and Tokenomics")" "finance"
    assert_eq "$(research_classify_domain "Consensus Paradigms in Distributed Systems")" "engineering"
    assert_eq "$(research_classify_domain "Carbon Nanotube Memory Architectures")" "academic"
    assert_eq "$(research_classify_domain "Porsche 911 GT3 RS Telemetry")" "general_sports_auto"
    assert_eq "$(research_classify_domain "Nintendo Switch JIT Recompilation")" "gaming"
    assert_eq "$(research_classify_domain "Apple Q3 10-K Earnings Analysis")" "finance"
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

    # Verify transcript lifecycle and phase logging across phases 2-5
    t_file=$(ls -1 "$RESEARCH_DIR/$slug"/*.md 2>/dev/null | grep -v -E 'dossier|thread|scratchpad|_prompts' | head -1)
    assert_file_exists "$t_file"
    t_content=$(cat "$t_file")
    assert_contains "$t_content" "Phase 2/5: Evidence Audit"
    assert_contains "$t_content" "Phase 3/5: Long-Form Technical Monograph Synthesis"
    assert_contains "$t_content" "Phase 4/5: Editorial Critique"
    assert_contains "$t_content" "Phase 5/5: The Three Degrees Audit"
    assert_contains "$t_content" "Generated Social Media Thread"
    assert_contains "$t_content" "Duration:"
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

it "preserves transcript across social broadcast in /research start --publish" && {
    # Mock x_blog_sweep to simulate posting and outputting to UI
    x_blog_sweep() {
        ui_step "Broadcasting test thread to Mastodon and X"
        ui_ok "Broadcasted post 1/4 to Mastodon: https://mastodon.social/@george/123"
        ui_ok "Broadcasted post 1/4 to X: https://x.com/george/status/123"
    }
    cmd_research "start Quantization Limits --publish"
    q_slug="quantization-limits"
    assert_dir_exists "$RESEARCH_DIR/$q_slug"
    q_t_file=$(ls -1 "$RESEARCH_DIR/$q_slug"/*.md 2>/dev/null | grep -v -E 'dossier|thread|scratchpad|_prompts' | head -1)
    assert_file_exists "$q_t_file"
    q_t_content=$(cat "$q_t_file")
    assert_contains "$q_t_content" "Social Broadcast (Mastodon, Bluesky, X)"
    assert_contains "$q_t_content" "Broadcasting test thread to Mastodon and X"
    assert_contains "$q_t_content" "Duration:"
}

it "refines and self-corrects deliverable when citation errors are encountered" && {
    refine_test_dir="$TEST_TMP/refine_test"
    mkdir -p "$refine_test_dir"
    cat << 'EOF' > "$refine_test_dir/dossier.md"
# Sovereign Research Dossier: Hallucinated Monograph
## Executive Abstract
Mithril (arXiv:2007.09978) state roots are computed via gradient descent across continuous loss landscapes with 1 honest signer among 100.
EOF
    ref_code=0
    research_verify_and_refine "dossier" "$refine_test_dir/dossier.md" "academic" "Hallucinated Monograph" "refine-monograph" "$refine_test_dir" || ref_code=$?
    assert_eq "$ref_code" 0
    ref_content=$(cat "$refine_test_dir/dossier.md")
    assert_not_contains "$ref_content" "2007.09978"
}

it "halts and routes unverified deliverable to quarantine when verification retries are exhausted" && {
    q_test_dir="$TEST_TMP/quarantine_test"
    mkdir -p "$q_test_dir"
    cat << 'EOF' > "$q_test_dir/dossier.md"
# Sovereign Research Dossier: Stubborn Monograph
## Executive Abstract
Mithril (arXiv:2007.09978) state roots are computed via gradient descent across continuous loss landscapes with 1 honest signer among 100.
EOF
    # Stub refine to no-op to force retry exhaustion
    _research_refine_artifact() { return 0; }
    q_code=0
    research_verify_and_refine "dossier" "$q_test_dir/dossier.md" "academic" "Stubborn Monograph" "stubborn-monograph" "$q_test_dir" || q_code=$?
    assert_eq "$q_code" 1

    # Verify quarantine queue directory exists with report
    assert_dir_exists "$RESEARCH_DIR/quarantine/stubborn-monograph"
    assert_file_exists "$RESEARCH_DIR/quarantine/stubborn-monograph/quarantine_report.md"
    q_rep=$(cat "$RESEARCH_DIR/quarantine/stubborn-monograph/quarantine_report.md")
    assert_contains "$q_rep" "QUARANTINED"
    assert_contains "$q_rep" "CITATION_TITLE_MISMATCH"
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
