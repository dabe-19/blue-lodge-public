#!/bin/bash
# ── Tests: Research Backlog Salvage Utility & /research salvage Command ──

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/research_graph.sh" 2>/dev/null || true
source "$LODGE_DIR/commands/research.sh" 2>/dev/null || true

# Test sandbox isolation
TEST_TMP=$(mktemp -d /tmp/george-salvage-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export RESEARCH_DIR="$GEORGE_DIR/research"
export RESEARCH_INDEX="$RESEARCH_DIR/research_index.jsonl"
export RESEARCH_QUEUE_DIR="$GEORGE_DIR/social/queue"
export RESEARCH_QUARANTINE_DIR="$RESEARCH_DIR/quarantine"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "Research Backlog Salvage Utility"

describe "research_salvage CLI & Engine"

it "handles empty quarantine gracefully" && {
    mkdir -p "$RESEARCH_QUARANTINE_DIR"
    out=$(cmd_research "salvage" 2>&1)
    assert_contains "$out" "Quarantine queue is empty"
}

it "rejects non-existent quarantined slug" && {
    mkdir -p "$RESEARCH_QUARANTINE_DIR"
    res=0
    out=$(cmd_research "salvage phantom-slug" 2>&1) || res=$?
    assert_neq "$res" 0
    assert_contains "$out" "Quarantined dossier not found"
}

it "salvages verified quarantined dossier and publishes to Sovereign Library" && {
    slug="valid-salvage-candidate"
    q_dir="$RESEARCH_QUARANTINE_DIR/$slug"
    mkdir -p "$q_dir"
    cat << 'EOF' > "$q_dir/dossier.md"
# Sovereign Research Dossier: Cardano Architecture
## Executive Abstract
Cardano utilizes Extended UTxO ledger architecture where state transitions are governed by deterministic Plutus Core validators and stake-based Ouroboros Praos consensus.
EOF
    cat << 'EOF' > "$q_dir/quarantine_report.md"
# Quarantine Diagnostic Report
**Topic:** Cardano Architecture
**Status:** QUARANTINED
EOF

    # Mock editorial and packaging for fast hermetic unit testing
    research_editorial_critique() {
        return 0
    }
    research_audit_and_package() {
        local topic="$1"
        local slug="$2"
        local dir="$3"
        local ts="$4"
        mkdir -p "$RESEARCH_DIR/$slug"
        cp "$dir/dossier.md" "$RESEARCH_DIR/$slug/dossier.md"
        echo "Thread content" > "$RESEARCH_DIR/$slug/thread.md"
        touch "$RESEARCH_QUEUE_DIR/${ts}_research_${slug}.txt"
        return 0
    }

    out=$(cmd_research "salvage $slug" 2>&1)
    assert_contains "$out" "Successfully salvaged and published: $slug"
    assert_dir_exists "$RESEARCH_DIR/$slug"
    assert_file_exists "$RESEARCH_DIR/$slug/dossier.md"
    assert_file_not_exists "$q_dir"
}

it "keeps unverified dossier in quarantine when verification fails" && {
    slug="unverified-salvage-candidate"
    q_dir="$RESEARCH_QUARANTINE_DIR/$slug"
    mkdir -p "$q_dir"
    cat << 'EOF' > "$q_dir/dossier.md"
# Sovereign Research Dossier: Hallucinated Monograph
## Executive Abstract
Mithril (arXiv:2007.09978) state roots are computed via gradient descent across continuous loss landscapes with 1 honest signer among 100.
EOF
    cat << 'EOF' > "$q_dir/quarantine_report.md"
# Quarantine Diagnostic Report
**Topic:** Hallucinated Monograph
**Status:** QUARANTINED
EOF

    _research_refine_artifact() { return 0; }
    out=$(cmd_research "salvage $slug" 2>&1)
    assert_contains "$out" "Remaining in quarantine"
    assert_dir_exists "$q_dir"
    assert_file_not_exists "$RESEARCH_DIR/$slug"
}

it "salvages all qualifying dossiers using --all flag" && {
    slug1="batch-valid-candidate"
    slug2="batch-bad-candidate"
    mkdir -p "$RESEARCH_QUARANTINE_DIR/$slug1" "$RESEARCH_QUARANTINE_DIR/$slug2"
    cat << 'EOF' > "$RESEARCH_QUARANTINE_DIR/$slug1/dossier.md"
# Sovereign Research Dossier: Cardano Distributed Consensus
## Executive Abstract
Cardano utilizes Extended UTxO ledger architecture where state transitions are governed by deterministic Plutus Core validators.
EOF
    cat << 'EOF' > "$RESEARCH_QUARANTINE_DIR/$slug1/quarantine_report.md"
**Topic:** Cardano Distributed Consensus
EOF

    cat << 'EOF' > "$RESEARCH_QUARANTINE_DIR/$slug2/dossier.md"
# Sovereign Research Dossier: Flawed Monograph
## Executive Abstract
Mithril (arXiv:2007.09978) state roots are computed via continuous gradient descent.
EOF

    out=$(cmd_research "salvage --all" 2>&1)
    assert_contains "$out" "Successfully salvaged and published: $slug1"
    assert_contains "$out" "Remaining in quarantine"
    assert_dir_exists "$RESEARCH_DIR/$slug1"
    assert_dir_exists "$RESEARCH_QUARANTINE_DIR/$slug2"
}

test_end
