#!/bin/bash
# ── Tests: Evidence-ledger grounding for research deliverables ─────────
# Hermetic: no arXiv ids or DOIs reach the network resolver here, and the
# Crossref fallback is disabled (TEST_TMP set => RESEARCH_GROUNDING_NETWORK=0).

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
unset _LIB_RESEARCH_VERIFIER_LOADED
source "$LODGE_DIR/lib/tools/research_verifier.sh" 2>/dev/null || true

TEST_TMP=$(mktemp -d /tmp/george-grounding-test-XXXXXX)
export TEST_TMP
export GEORGE_DIR="$TEST_TMP/.george"
export RESEARCH_DIR="$GEORGE_DIR/research"
export RESEARCH_QUARANTINE_DIR="$RESEARCH_DIR/quarantine"
export RESEARCH_GROUNDING_NETWORK=0
mkdir -p "$GEORGE_DIR/cache" "$RESEARCH_QUARANTINE_DIR"
trap 'rm -rf "$TEST_TMP"' EXIT

PY="$LODGE_DIR/lib/tools/research_verifier.py"
LEDGER="$TEST_TMP/scratchpad.md"
cat > "$LEDGER" << 'EOF'
# Research Scratchpad
### Vector: liquid neural networks
#### Reference [https://example.org/papers/liquid-time-constant]
Liquid Time-constant Networks
Ramin Hasani, Mathias Lechner, Alexander Amini, Daniela Rus, Radu Grosu
Continuous-time recurrent networks whose time constants vary with input.
#### Reference [https://example.org/blog/closed-form-continuous]
Closed-form Continuous-time Neural Networks (CfC) remove the ODE solver from the forward pass.
EOF

verify() {  # verify <text> [ledger]
    local -a ev=()
    [ -n "${2:-}" ] && ev=(--evidence "$2")
    RESEARCH_GROUNDING_NETWORK=0 python3 "$PY" verify-citations --topic "Liquid Neural Networks" \
        --domain academic --cache "$GEORGE_DIR/cache/c.json" "${ev[@]}" --text "$1" 2>&1
}

test_start "Research Evidence Grounding"

describe "verify-citations --evidence"
it "passes when references trace back to ledger URLs" && {
    text=$'# Dossier\nLTCs adapt time constants to input.\n## References\n- Liquid Time-constant Networks. https://example.org/papers/liquid-time-constant\n- CfC overview: https://www.example.org/blog/closed-form-continuous/'
    out=$(verify "$text" "$LEDGER"); rc=$?
    assert_eq "$rc" 0
    assert_contains "$out" '"status": "PASS"'
    assert_contains "$out" '"ledger_grounded": 2'
}

it "grounds a reference by title overlap even with a wrong venue string" && {
    text=$'# Dossier\nBody.\n## References\n1. Hasani, R. et al. Liquid Time-constant Networks. AAAI 2021.'
    out=$(verify "$text" "$LEDGER"); rc=$?
    assert_eq "$rc" 0
    assert_contains "$out" '"grounded": 1'
}

it "flags an invented reference that is not in the evidence" && {
    text=$'# Dossier\nBody.\n## References\n1. Hasani, R. et al. Liquid Time-constant Networks. AAAI 2021.\n2. Shamszadi, A. Neuromorphic spike routing for edge accelerators. ICLR 2022.'
    out=$(verify "$text" "$LEDGER"); rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "CITATION_UNGROUNDED"
    assert_contains "$out" "Shamszadi"
    assert_not_contains "$out" "EVIDENCE_UNUSED"
}

it "fails with EVIDENCE_UNUSED when no reference comes from the ledger" && {
    text=$'# Dossier\nBody.\n### Sources\n- Smith, J. Neural ODE accelerators on photonic fabrics. IEEE TPAMI 2023.\n- Doe, K. Spiking reservoir chips for robotics. Nature Electronics 2022.'
    out=$(verify "$text" "$LEDGER"); rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "EVIDENCE_UNUSED"
}

it "does not treat 'Sources of error' as a references section" && {
    text=$'# Dossier\n## Sources of error\n- Sensor drift over long deployments can bias time constants.\n- Quantization noise.'
    out=$(verify "$text" "$LEDGER"); rc=$?
    assert_eq "$rc" 0
    assert_contains "$out" '"references": 0'
}

it "skips grounding when no ledger is supplied (backward compatible)" && {
    text=$'# Dossier\n## References\n- Smith, J. Something invented entirely. 2023.'
    out=$(verify "$text"); rc=$?
    assert_eq "$rc" 0
    assert_not_contains "$out" '"grounding"'
}

describe "EvidenceGrounding (inline identifiers, offline)"
it "flags inline arXiv ids absent from the ledger and accepts ones present" && {
    out=$(cd "$LODGE_DIR/lib/tools" && python3 - << 'PYEOF'
import research_verifier as rv
ledger = "#### Reference [https://arxiv.org/abs/2006.04439]\nLiquid Time-constant Networks\n"
g = rv.EvidenceGrounding(ledger, resolver=None, allow_network=False)
ok1, v1, _ = g.check("LTCs were introduced in arXiv:2006.04439.")
ok2, v2, _ = g.check("See arXiv:2106.99999 for the TPAMI extension.")
print("good", ok1, len(v1))
print("bad", ok2, any("CITATION_UNGROUNDED" in x for x in v2))
PYEOF
)
    assert_contains "$out" "good True 0"
    assert_contains "$out" "bad False True"
}

it "never counts a network failure as grounded" && {
    out=$(cd "$LODGE_DIR/lib/tools" && python3 - << 'PYEOF'
import research_verifier as rv
class Down:
    def resolve_unindexed_crossref(self, a, y, t):
        return {"found": None, "error": "timeout"}
g = rv.EvidenceGrounding("#### Reference [https://x.org/a]\nUnrelated ledger text here\n", resolver=Down(), allow_network=True)
ok, v, rep = g.check("## References\n- Brown, T. Invented monograph on continuous neural routing. 2021.")
print("ok", ok, rep["grounded"])
PYEOF
)
    assert_contains "$out" "ok False 0"
}

describe "Verification loop wiring"
it "quarantines a dossier whose references are not grounded in the sandbox ledger" && {
    sb="$TEST_TMP/sandbox_fab"
    mkdir -p "$sb"
    cp "$LEDGER" "$sb/scratchpad.md"
    cat > "$sb/dossier.md" << 'EOF'
# Sovereign Research Dossier: Liquid Neural Networks
## Executive Abstract
Liquid networks deliver large speedups on neuromorphic hardware.
## References
1. Shamszadi, A. Neuromorphic spike routing for edge accelerators. ICLR 2022.
2. Smith, J. Liquid neural accelerators on photonic fabrics. IEEE TPAMI 2023.
EOF
    _research_refine_artifact() { return 0; }
    res=0
    research_verify_and_refine "dossier" "$sb/dossier.md" "academic" "Liquid Neural Networks" "lnn-fab" "$sb" >/dev/null 2>&1 || res=$?
    assert_eq "$res" 1
    report=$(cat "$RESEARCH_QUARANTINE_DIR/lnn-fab/quarantine_report.md" 2>/dev/null)
    assert_contains "$report" "CITATION_UNGROUNDED"
}

it "refinement prompt carries the current draft and the evidence ledger" && {
    unset -f _research_refine_artifact
    unset _LIB_RESEARCH_VERIFIER_LOADED
    source "$LODGE_DIR/lib/tools/research_verifier.sh" 2>/dev/null || true
    assert_fn_contains _research_refine_artifact "CURRENT DRAFT"
    assert_fn_contains _research_refine_artifact "EVIDENCE LEDGER"
    assert_fn_contains _research_refine_artifact "Do NOT add any new reference"
}

it "quarantine notice is suppressed under tests (no Discord call)" && {
    _notify_calls="$TEST_TMP/notify_calls"
    discord_send() { echo "$*" >> "$_notify_calls"; }
    _research_notify_quarantine "t" "$TEST_TMP/q" "[X] reason"
    assert_file_not_exists "$_notify_calls"
    unset -f discord_send
}

it "quarantine notice DMs the operator when enabled" && {
    _notify_calls="$TEST_TMP/notify_calls2"
    discord_send() { printf '%s|%s\n' "$1" "$2" >> "$_notify_calls"; }
    ( unset TEST_TMP; LODGE_TEST_MODE=0 _research_notify_quarantine "Liquid NNs" "/x/quarantine/lnn" "Gate 1 failed: [CITATION_UNGROUNDED] Reference 'Smith' missing" )
    out=$(cat "$_notify_calls" 2>/dev/null)
    assert_contains "$out" "me|"
    assert_contains "$out" "CITATION_UNGROUNDED"
    assert_contains "$out" "research/quarantine/lnn"
    unset -f discord_send
}

test_end
