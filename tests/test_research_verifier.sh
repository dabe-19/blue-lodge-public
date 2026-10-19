#!/bin/bash
# ── Tests: Deterministic Grounding Gate & Adversarial Primitive Auditor ────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/research_verifier.sh" 2>/dev/null || true

# Sandbox isolation
TEST_TMP=$(mktemp -d /tmp/george-verifier-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export RESEARCH_DIR="$GEORGE_DIR/research"
export RESEARCH_QUARANTINE_DIR="$RESEARCH_DIR/quarantine"
mkdir -p "$GEORGE_DIR" "$RESEARCH_DIR" "$RESEARCH_QUARANTINE_DIR"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "Grounding Verification Sub-Graph"

describe "Deterministic Citation & Entity Resolver (Gate 1)"
it "passes on clean text without hallucinated citations" && {
    out=$(research_verify_citations "Cardano utilizes Extended UTxO ledger architecture." "Cardano Architecture" "academic")
    assert_contains "$out" "PASS"
}

it "rejects hallucinated arXiv ID 2007.09978 (river ecology paper claimed as Cardano Mithril)" && {
    out=$(research_verify_citations "Mithril (arXiv:2007.09978) verifies Cardano state proofs." "Zero-Knowledge State Proofs on Cardano" "academic")
    assert_contains "$out" "FAIL"
    assert_contains "$out" "CITATION_TITLE_MISMATCH"
}

it "rejects false venue publication year for Ouroboros Crypsinous" && {
    out=$(research_verify_citations "Ouroboros Crypsinous (IEEE S&P 2025) provides cloaked slot leader election." "Ouroboros Protocol" "academic")
    assert_contains "$out" "FAIL"
    assert_contains "$out" "CITATION_YEAR_MISMATCH"
}

it "accepts foundational test-time compute papers (Self-Consistency 2203.11171 & Tree of Thoughts 2305.10601)" && {
    text="Wang et al. (2022) proposed Self-Consistency (arXiv:2203.11171) to scale test-time compute by sampling multiple reasoning paths. Yao et al. introduced Tree of Thoughts (arXiv:2305.10601) for deliberate problem solving using tree search."
    out=$(research_verify_citations "$text" "Gradient-Free Evolutionary Prompt Optimization and Test-Time Compute Scaling" "academic")
    assert_contains "$out" "PASS"
}

it "permits bold cross-domain citations and bare identifiers without topic restrictions" && {
    text="We import statistical mechanics concepts into prompt optimization [arXiv:2203.11171]. Shannon, C.E. (1948). \"A Mathematical Theory of Communication.\" establishes the theoretical bounds on entropy."
    out=$(research_verify_citations "$text" "Gradient-Free Evolutionary Prompt Optimization" "academic")
    assert_contains "$out" "PASS"
}

it "rejects hallucinated arXiv ID 2309.08534 claimed as EvoPrompt while accepting genuine EvoPrompt 2309.08532" && {
    bad_text="Guo et al. introduced EvoPrompt (arXiv:2309.08534) for evolutionary prompt optimization."
    bad_out=$(research_verify_citations "$bad_text" "Gradient-Free Evolutionary Prompt Optimization and Test-Time Compute Scaling" "academic")
    assert_contains "$bad_out" "FAIL"
    assert_contains "$bad_out" "CITATION_TITLE_MISMATCH"

    good_text="Guo et al. introduced EvoPrompt (arXiv:2309.08532) for evolutionary prompt optimization."
    good_out=$(research_verify_citations "$good_text" "Gradient-Free Evolutionary Prompt Optimization and Test-Time Compute Scaling" "academic")
    assert_contains "$good_out" "PASS"
}

it "deduplicates versioned and unversioned arXiv forms to one canonical identifier (regression 520b12ff23c1)" && {
    # Deterministic, network-free unit test of extract_identifiers: the four raw
    # citation forms from incident 520b12ff23c1 must collapse to exactly two
    # canonical identifiers (one per distinct paper).
    py_out=$(python3 - <<PY
import importlib.util
spec = importlib.util.spec_from_file_location("rv", "${LODGE_DIR}/lib/tools/research_verifier.py")
rv = importlib.util.module_from_spec(spec); spec.loader.exec_module(rv)
cls = next(o for n, o in vars(rv).items() if isinstance(o, type) and hasattr(o, "extract_identifiers"))
r = cls.__new__(cls); r.cache = None
inc = r.extract_identifiers("x 2402.11140 y 2402.11140v2 z 2601.00828 w 2601.00828v1")
assert inc["arxiv"] == ["2402.11140v2", "2601.00828v1"], inc["arxiv"]
assert r.extract_identifiers("solo 2402.11140 end")["arxiv"] == ["2402.11140"]
assert r.extract_identifiers("2203.11171 and 2305.10601")["arxiv"] == ["2203.11171", "2305.10601"]
print("DEDUP_OK")
PY
    )
    assert_contains "$py_out" "DEDUP_OK"
}

describe "Adversarial Primitive Auditor (Gate 2)"
it "detects trust model conflation (MPC ceremony 1-of-N vs stake-weighted Byzantine threshold)" && {
    text="Mithril consensus security hinges on 1 honest signer among 100+ signers for signature aggregation."
    out=$(research_adversarial_audit "$text" "Zero-Knowledge State Proofs on Cardano" "academic")
    assert_contains "$out" "TRUST_MODEL_MISMATCH"
}

it "detects category collision (continuous lossy optimization on discrete finite field state roots)" && {
    text="Cardano eUTxO state root transition is calculated using low-rank matrix factorization and gradient descent."
    out=$(research_adversarial_audit "$text" "Zero-Knowledge State Proofs on Cardano" "academic")
    assert_contains "$out" "CATEGORY_COLLISION"
}

it "detects financial invariant violation (risk-free guaranteed arbitrage)" && {
    text="The cross-DEX trading strategy yields risk-free guaranteed profit across all mempools."
    out=$(research_adversarial_audit "$text" "Cross-DEX Arbitrage Strategy" "finance")
    assert_contains "$out" "FINANCIAL_INVARIANT_VIOLATION"
}

it "passes on sound technical claims" && {
    text="Cardano eUTxO state transitions map an unspent transaction output set to a validated successor set using Plutus Core scripts and cryptographic signature verification."
    out=$(research_adversarial_audit "$text" "Cardano State Model" "academic")
    assert_contains "$out" "PASS"
}

describe "Platform Syntax & Format Linter (Gate 3)"
it "sanitizes LaTeX delimiters, Greek math, and single-letter cashtags for social media" && {
    sample_file="$TEST_TMP/sample_thread.txt"
    cat << 'EOF' > "$sample_file"
State transition $f(\sigma, tx, \pi_{zk})$ maps UTxO set \sigma to \sigma'. Validity requires \sum_{in} value \geq \sum_{out} value + fee. zkSNARK circuit $C_{st}$ encodes this, where $f and $C are functions.
EOF
    research_platform_lint "$sample_file" "twitter"
    sanitized=$(cat "$sample_file")
    assert_not_contains "$sanitized" '\sigma'
    assert_not_contains "$sanitized" '\sum'
    assert_not_contains "$sanitized" '\geq'
    assert_not_contains "$sanitized" '$f'
    assert_not_contains "$sanitized" '$C'
    assert_contains "$sanitized" 'σ'
    assert_contains "$sanitized" '∑'
    assert_contains "$sanitized" '≥'
}

it "strips accidental LLM meta-commentary and self-correction notes" && {
    meta_file="$TEST_TMP/meta_leak.txt"
    cat << 'EOF' > "$meta_file"
# Monograph Title
Text before note.
*(Note: The rejection flagged arXiv:2203.11171. However, Self-Consistency IS test-time scaling.)*
*(Self-Correction: The rejection specifically flagged arXiv:2305.10601 as mismatch. I must NOT use this ID.)*
* *Decision:* I will describe Tree of Thoughts without ID.
Text after note.
EOF
    research_platform_lint "$meta_file" "twitter"
    cleaned=$(cat "$meta_file")
    assert_not_contains "$cleaned" "Self-Correction"
    assert_not_contains "$cleaned" "rejection flagged"
    assert_not_contains "$cleaned" "*Decision:*"
    assert_contains "$cleaned" "Text before note."
    assert_contains "$cleaned" "Text after note."
}

describe "Two-Phase Verification Orchestration & Quarantine Loop"
it "clears valid artifact through all three verification gates" && {
    valid_file="$TEST_TMP/valid_dossier.md"
    cat << 'EOF' > "$valid_file"
# Sovereign Research Dossier: Cardano Architecture
## Executive Abstract
Cardano utilizes an Extended UTxO ledger architecture where state transitions are governed by deterministic Plutus Core validators and stake-based Ouroboros Praos consensus.
EOF
    res=0
    research_verify_and_refine "dossier" "$valid_file" "academic" "Cardano Architecture" "cardano-architecture" "$TEST_TMP" || res=$?
    assert_eq "$res" 0
}

it "quarantines deliverable with diagnostic report when retries fail" && {
    bad_file="$TEST_TMP/bad_dossier.md"
    cat << 'EOF' > "$bad_file"
# Sovereign Research Dossier: Fake State Proofs
## Executive Abstract
Mithril (arXiv:2007.09978) state roots are optimized via gradient descent across continuous loss landscapes with 1 honest signer among 100.
EOF
    # Force a non-recoverable error by setting a stubborn file
    stubborn_dir="$TEST_TMP/stubborn_sandbox"
    mkdir -p "$stubborn_dir"
    cp "$bad_file" "$stubborn_dir/dossier.md"

    # Make refine a no-op to force retry exhaustion
    _research_refine_artifact() {
        return 0
    }

    res=0
    research_verify_and_refine "dossier" "$stubborn_dir/dossier.md" "academic" "Fake State Proofs" "fake-state-proofs" "$stubborn_dir" || res=$?
    assert_eq "$res" 1

    # Verify quarantine directory and report
    q_dir="$RESEARCH_QUARANTINE_DIR/fake-state-proofs"
    assert_dir_exists "$q_dir"
    assert_file_exists "$q_dir/quarantine_report.md"
    q_report=$(cat "$q_dir/quarantine_report.md")
    assert_contains "$q_report" "QUARANTINED"
    assert_contains "$q_report" "CITATION_TITLE_MISMATCH"
}

describe "Evidence-Grounded Citation Suppression (incident 41bf78240605)"
it "suppresses CITATION_NOT_FOUND for arXiv IDs grounded in the evidence ledger (registry lookup gap)" && {
    eg_cache="$TEST_TMP/eg_cache.json"
    eg_dossier="$TEST_TMP/eg_dossier.md"
    eg_ledger="$TEST_TMP/eg_ledger.md"
    printf '%s' '{"arxiv:2402.11140": {"found": false}, "arxiv:2601.00828": {"found": false}}' > "$eg_cache"
    cat << 'EOF' > "$eg_dossier"
# Test Dossier
We ground hop t with arXiv:2402.11140 and prune the beam via 2601.00828.
EOF
    cat << 'EOF' > "$eg_ledger"
## Gathered Evidence
- arXiv:2402.11140 grounded multi-hop paper (retrieved via arxiv_search)
- arXiv:2601.00828 grounded beam-pruning paper (retrieved via arxiv_search)
EOF
    eg_out=$(python3 "$LODGE_DIR/lib/tools/research_verifier.py" verify-citations \
        --topic "multi-hop reasoning" --domain academic \
        --file "$eg_dossier" --evidence "$eg_ledger" --cache "$eg_cache" 2>&1)
    assert_contains "$eg_out" "PASS"
    assert_not_contains "$eg_out" "CITATION_NOT_FOUND"
    assert_contains "$eg_out" "evidence_grounded"
}

it "still emits CITATION_NOT_FOUND when the IDs are absent from the evidence ledger (detection intact)" && {
    eg_cache2="$TEST_TMP/eg_cache2.json"
    eg_dossier2="$TEST_TMP/eg_dossier2.md"
    printf '%s' '{"arxiv:2402.11140": {"found": false}, "arxiv:2601.00828": {"found": false}}' > "$eg_cache2"
    cat << 'EOF' > "$eg_dossier2"
# Test Dossier 2
We ground hop t with arXiv:2402.11140 and prune the beam via 2601.00828.
EOF
    eg_out2=$(python3 "$LODGE_DIR/lib/tools/research_verifier.py" verify-citations \
        --topic "multi-hop reasoning" --domain academic \
        --file "$eg_dossier2" --cache "$eg_cache2" 2>&1)
    assert_contains "$eg_out2" "FAIL"
    assert_contains "$eg_out2" "CITATION_NOT_FOUND"
}

describe "Anti-Meta-Apology Sanitizer & Sub-Domain Classification"
it "strips LLM meta-apologies and leaked tool syntax via sanitize-thread" && {
    dirty_thread="$TEST_TMP/dirty_thread.md"
    cat << 'EOF' > "$dirty_thread"
🏛️ Order-Flow Toxicity in Concentrated Liquidity

While direct empirical studies on the 2026 fee switch are absent from the immediate retrieval results, structural invariant bounds demonstrate that LVR scales with σ².

▸ LVR = ½ · σ² · P · |Γ|

Let us run arxiv_search "concentrated liquidity LVR" to check more papers.

---POST---

Due to a lack of direct 2026 literature in the search results, we extrapolate from Uniswap v3 pool telemetry across 5bps and 30bps tiers.
EOF
    python3 "$LODGE_DIR/lib/tools/research_verifier.py" sanitize-thread --file "$dirty_thread" >/dev/null
    cleaned=$(cat "$dirty_thread")
    assert_not_contains "$cleaned" "absent from the immediate retrieval results"
    assert_not_contains "$cleaned" "arxiv_search"
    assert_not_contains "$cleaned" "Due to a lack of direct"
    assert_contains "$cleaned" "LVR scales with"
    assert_contains "$cleaned" "Uniswap v3 pool telemetry"
}

it "classifies finance sub-domains into protocol_crypto, microstructure_macro, and corporate_equity" && {
    sub_crypto=$(python3 -c "import sys; sys.path.insert(0, '$LODGE_DIR/lib/tools'); import research_verifier as rv; print(rv.classify_finance_sub_domain('Cardano eUTxO DEX Batching & MEV', ''))")
    sub_macro=$(python3 -c "import sys; sys.path.insert(0, '$LODGE_DIR/lib/tools'); import research_verifier as rv; print(rv.classify_finance_sub_domain('Zero-Lower-Bound Term Premium & Order Book Liquidity', ''))")
    sub_corp=$(python3 -c "import sys; sys.path.insert(0, '$LODGE_DIR/lib/tools'); import research_verifier as rv; print(rv.classify_finance_sub_domain('10-K Goodwill Impairment & ROIC Valuation', ''))")
    assert_eq "$sub_crypto" "protocol_crypto"
    assert_eq "$sub_macro" "microstructure_macro"
    assert_eq "$sub_corp" "corporate_equity"
}

describe "Deterministic Monograph Plate Generator (research_plate.py)"
it "renders a 1200x675 PNG summary card from a dossier directory" && {
    plate_dir="$TEST_TMP/plate_monograph"
    mkdir -p "$plate_dir"
    cat << 'EOF' > "$plate_dir/dossier.md"
# Sovereign Research Dossier: Sub-Quadratic Attention Kernels
**Domain**: `academic` | **Date**: 2026-10-14 12:00 UTC

## Executive Abstract & Thesis
Hardware-aware state-space and linear attention kernels reduce KV-cache memory bandwidth bottlenecks from O(N²) to O(N) while preserving exact causal masking under TileLang register tiling.

▸ Throughput: 312 TFLOPS on H100 SXM5 (1.84x over FlashAttention-2)
EOF
    cat << 'EOF' > "$plate_dir/thread.md"
🏛️ Sub-Quadratic Attention Kernels

Hardware-aware state-space kernels eliminate quadratic KV-cache bottlenecks.

▸ Throughput: 312 TFLOPS on H100 SXM5
EOF
    python3 "$LODGE_DIR/lib/tools/research_plate.py" --dir "$plate_dir" >/dev/null
    assert_file_exists "$plate_dir/summary_card.png"
    dims=$(python3 -c "from PIL import Image; im=Image.open('$plate_dir/summary_card.png'); print(f'{im.width}x{im.height}')")
    assert_eq "$dims" "1200x675"
}

