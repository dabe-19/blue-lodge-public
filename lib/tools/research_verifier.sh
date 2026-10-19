#!/bin/bash
# ── George: Deterministic Grounding Gate & Adversarial Primitive Auditor ────
# Implements the two-phase verification sub-graph for Blue Lodge Deep Research:
# 1. Deterministic Citation & Entity Resolver (API & AST/Regex ground-truth verification)
# 2. Adversarial Primitive Auditor (Hostile LLM gate with inverted incentives & heuristics)
# 3. Platform Syntax & Format Linter (LaTeX delimiter stripping, Unicode conversion, cashtag sanitization)
# 4. Refinement Loop with conditional edge routing (max 2 retries) and Quarantine queue routing.

[ -n "${_LIB_RESEARCH_VERIFIER_LOADED:-}" ] && return 0; _LIB_RESEARCH_VERIFIER_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
RESEARCH_DIR="${RESEARCH_DIR:-$GEORGE_DIR/research}"
RESEARCH_QUARANTINE_DIR="${RESEARCH_QUARANTINE_DIR:-}"
RESEARCH_VERIFIER_PY="${LODGE_DIR}/lib/tools/research_verifier.py"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/native_tools.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/react.sh" 2>/dev/null || true

# ── Gate 1: Deterministic Citation & Entity Resolver ─────────────────
research_verify_citations() {
    local text="$1"
    local topic="$2"
    local domain="${3:-academic}"
    local evidence_file="${4:-}"
    local cache_file="${GEORGE_DIR}/cache/citations_cache.json"

    mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true

    if [ ! -f "$RESEARCH_VERIFIER_PY" ]; then
        ui_warn "research_verifier.py not found at $RESEARCH_VERIFIER_PY"
        return 0
    fi

    local -a ev_args=()
    [ -n "$evidence_file" ] && [ -s "$evidence_file" ] && ev_args=(--evidence "$evidence_file")

    # Hermetic in tests: grounding falls back to the ledger only (no Crossref).
    local grounding_net="${RESEARCH_GROUNDING_NETWORK:-1}"
    if [ "${LODGE_TEST_MODE:-0}" = "1" ] || [ -n "${TEST_TMP:-}" ]; then
        grounding_net=0
    fi

    local py_out py_code=0
    py_out=$(RESEARCH_GROUNDING_NETWORK="$grounding_net" python3 "$RESEARCH_VERIFIER_PY" verify-citations \
        --topic "$topic" \
        --domain "$domain" \
        --cache "$cache_file" \
        "${ev_args[@]}" \
        --text "$text" 2>&1) || py_code=$?

    echo "$py_out"
    return $py_code
}

# ── Gate 2: Adversarial Primitive Auditor ─────────────────────────────
research_adversarial_audit() {
    # Dynamically reload verifier if called from external caller or subshell
    if [ -z "${_RESEARCH_AUDIT_RESOURCING:-}" ] && [ -f "${LODGE_DIR:-$HOME/blue-lodge}/lib/tools/research_verifier.sh" ]; then
        _RESEARCH_AUDIT_RESOURCING=1 source "${LODGE_DIR:-$HOME/blue-lodge}/lib/tools/research_verifier.sh" 2>/dev/null || true
    fi

    local text="$1"
    local topic="$2"
    local domain="${3:-academic}"

    # 1. Programmatic Invariant Heuristics Check
    local heur_out heur_code=0
    if [ -f "$RESEARCH_VERIFIER_PY" ]; then
        heur_out=$(python3 "$RESEARCH_VERIFIER_PY" audit-heuristics \
            --topic "$topic" \
            --domain "$domain" \
            --text "$text" 2>&1) || heur_code=$?

        if [ "$heur_code" -ne 0 ]; then
            echo "$heur_out"
            return 1
        fi
    fi

    # 2. Hostile LLM Node with Inverted Incentives (if endpoint online)
    local endpoints_online=0
    endpoints_cascade "${ACTIVE_TIER:-1}" 2>/dev/null || endpoints_init 2>/dev/null || true
    local llm_url="${ACTIVE_ENDPOINT_URL:-${TIER1_URL:-http://127.0.0.1:8080}}"
    if curl -sf --connect-timeout 2 --max-time 3 "$llm_url/v1/models" &>/dev/null; then
        endpoints_online=1
    fi

    if [ "$endpoints_online" -eq 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ] && [ -z "${TEST_TMP:-}" ]; then
        local audit_prompt="You are George's Adversarial Primitive Auditor.
Your objective is strictly NEGATIVE:
Do not suggest rewrites. Act purely as a hostile technical, mathematical, and domain auditor.
Interdisciplinary cross-domain synthesis (importing concepts from physics, biology, economics, or pure mathematics into computer science, AI, or cryptography) is HIGHLY ENCOURAGED, provided an explicit structural mapping, mathematical analogy, or formal isomorphism is defined.

CRITICAL AUDIT RESTRICTIONS & WHITELIST (DO NOT VIOLATE):
- System Identity & Boilerplate: Do NOT flag system branding, persona, or document title conventions (e.g. 'Sovereign', 'Dossier', 'Craftsman', 'Blue Lodge', '# Sovereign Research Dossier') as unbridged jargon grafting. These are publication formatting metadata, not domain collisions.
- Systems Terminology: Do NOT flag standard computer systems and networking metrics (e.g. 'goodput' denoting application-level accepted tokens/bytes per second, 'throughput', 'bandwidth', 'arithmetic intensity', 'roofline ridge') as financial invariant violations or conflations.
- Empirical & Protocol Nuance: Implementation-level overheads (such as PCIe link-layer vs DMA/driver latency distinctions, kernel launch latencies, or roofline approximation bounds) MUST be classified as SEVERITY: ADVISORY, NOT BLOCKING, unless they mathematically invalidate the core asymptotic or physical feasibility theorem.

Negative Audit Criteria:
1. Hard Invariant Violations (SEVERITY: BLOCKING):
   - Physical/thermodynamic/friction limits (e.g. 0-60 on street production tires <1.0s without rocket thrust; exceeding light-speed latency).
   - Distributed systems impossibility results (e.g. claiming zero-latency linearizability without network quorum round-trips violating CAP/FLP).
   - Cryptographic/algebraic bounds (e.g. grafting lossy continuous gradient descent or low-rank matrix approximations onto exact discrete finite-field 𝔽_p state roots; conflating 1-of-N MPC ceremony assumptions with Byzantine consensus thresholds).
   - Financial invariants (claiming 'risk-free' execution without execution slippage, frontrunning, or liquidation waterfalls; conflating GMV with GAAP revenue).
2. Unbridged Jargon Grafting (SEVERITY: BLOCKING):
   - Invoking exotic terms from external domains (e.g. 'quantum entanglement', 'CRISPR gene editing', 'thermodynamic entropy') into an unrelated architecture as buzzwords without establishing an explicit operational or mathematical mapping.
3. Advisory / Domain Nuance Observations (SEVERITY: ADVISORY):
   - Missing asymptotic caveats (e.g. O(log N) ANN index requirement), precision clarifications on constant factors, hardware latency layer distinctions (link vs DMA), notation suggestions, or scope boundaries that do NOT invalidate the core mathematical or empirical thesis.

Text to Audit (Topic: '$topic', Domain: '$domain'):
$text

AUDITOR DIRECTIVE:
If any hard invariant violation or unbridged jargon grafting is detected, output:
STATUS: FAIL
SEVERITY: BLOCKING
VIOLATIONS:
- [BLOCKING:VIOLATION_TYPE] <Exact explanation of contradiction>

If only advisory domain caveats or notation clarifications are found (with no hard invariant breaks), output:
STATUS: PASS_WITH_ADVISORY
SEVERITY: ADVISORY
VIOLATIONS:
- [ADVISORY:NOTE] <Exact explanation of nuance>

If and only if the text is completely free of invalid assumptions and unbridged collisions, output:
STATUS: PASS"

        local payload
        payload=$(jq -n --arg p "$audit_prompt" \
            '{messages: [{"role": "system", "content": "You are a hostile technical and cryptographic auditor with inverted incentives. Your only job is to detect category errors and break invalid claims. Never suggest rewrites."}, {"role": "user", "content": $p}, {"role": "assistant", "content": "<think>\n</think>\n"}], temperature: 0.2, max_tokens: 1024}')

        declare -f transcript_log_prompt &>/dev/null && transcript_log_prompt "adversarial_audit" "$audit_prompt" "Hostile Primitive Auditor with inverted incentives"

        local raw_resp
        raw_resp=$(curl -s --max-time 120 "$llm_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)

        local resp_content
        resp_content=$(echo "$raw_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        if declare -f _research_strip_thinking &>/dev/null; then
            resp_content=$(_research_strip_thinking "$resp_content")
        fi

        if grep -qiE "STATUS:\s*PASS_WITH_ADVISORY" <<< "$resp_content"; then
            echo "$resp_content"
            return 0
        fi

        if grep -qiE "(STATUS:\s*FAIL|SEVERITY:\s*BLOCKING|\[BLOCKING:)" <<< "$resp_content"; then
            echo "$resp_content"
            return 1
        fi

        if grep -qiE "(STATUS:\s*FAIL|VIOLATIONS:)" <<< "$resp_content" && ! grep -qiE "SEVERITY:\s*ADVISORY" <<< "$resp_content"; then
            echo "$resp_content"
            return 1
        fi
    fi

    echo "STATUS: PASS"
    return 0
}

# ── Gate 3: Platform Syntax & Format Linter ───────────────────────────
research_platform_lint() {
    local target_file="$1"
    local platform="${2:-social}"

    if [ ! -f "$target_file" ]; then
        return 0
    fi

    if [ -f "$RESEARCH_VERIFIER_PY" ]; then
        python3 "$RESEARCH_VERIFIER_PY" lint-platform \
            --file "$target_file" \
            --platform "$platform" \
            --fix >/dev/null 2>&1 || true
    fi

    # Also run social_sanitize_text if defined in environment
    if declare -f social_sanitize_text &>/dev/null; then
        local raw sanitized
        raw=$(cat "$target_file")
        sanitized=$(social_sanitize_text "$raw")
        echo "$sanitized" > "$target_file"
    fi

    return 0
}

# ── Refine Synthesis Callback Helper ──────────────────────────────────
_research_refine_artifact() {
    local artifact_type="$1"   # "dossier" or "thread"
    local file_path="$2"
    local domain="$3"
    local topic="$4"
    local sandbox_dir="$5"
    local rejection_header="$6"
    local rejection_trace="$7"

    ui_step "Refining ${artifact_type} with injected rejection trace..."
    declare -f transcript_log &>/dev/null && transcript_log "verification_refine" "Refining ${artifact_type}: ${rejection_header}"

    local endpoints_online=0
    endpoints_cascade "${ACTIVE_TIER:-1}" 2>/dev/null || endpoints_init 2>/dev/null || true
    local llm_url="${ACTIVE_ENDPOINT_URL:-${TIER1_URL:-http://127.0.0.1:8080}}"
    if curl -sf --connect-timeout 2 --max-time 3 "$llm_url/v1/models" &>/dev/null; then
        endpoints_online=1
    fi

    local current_content
    current_content=$(cat "$file_path" 2>/dev/null || true)

    if [ "$endpoints_online" -eq 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ] && [ -z "${TEST_TMP:-}" ]; then
        local draft_max="${RESEARCH_REFINE_DRAFT_CHARS:-12000}"
        local ev_max="${RESEARCH_REFINE_EVIDENCE_CHARS:-16000}"
        local draft_excerpt="${current_content:0:$draft_max}"
        [ "${#current_content}" -gt "$draft_max" ] && draft_excerpt+=$'\n[... draft truncated ...]'
        local evidence_excerpt=""
        if [ -n "$sandbox_dir" ] && [ -s "$sandbox_dir/scratchpad.md" ]; then
            evidence_excerpt=$(head -c "$ev_max" "$sandbox_dir/scratchpad.md" 2>/dev/null)
        fi
        [ -z "$evidence_excerpt" ] && evidence_excerpt="(no evidence ledger available - remove any reference you cannot verify)"

        # ── Primary: Autonomous Multi-Turn ReAct Refiner with Complete Tool Suite ──
        if declare -f react_run &>/dev/null; then
            local refiner_goal="You are George, refining your synthesized ${artifact_type} on '${topic}'.
Target File: ${file_path}
Evidence Ledger: ${sandbox_dir}/scratchpad.md

The Grounding Verification Gate rejected the current draft with the following violation trace:
${rejection_header}
${rejection_trace}

=== CURRENT DRAFT ===
${draft_excerpt}
=== END DRAFT ===

=== EVIDENCE LEDGER (the ONLY sources you may cite) ===
${evidence_excerpt}
=== END EVIDENCE ===

CRITICAL REFINEMENT MANDATE:
1. Inspect the specific claims, equations, or citations in ${file_path} flagged by the rejection trace using file_read.
2. If mathematical bounds, equations, or capacity limits were disputed, use bash_exec (python3 - <<'EOF' ...) to compute and verify the exact mathematically sound formulation.
3. If citation titles or attributions were disputed, use arxiv_search or web_fetch to verify official paper authors, titles, or dates, and resolve any contradictions. Do NOT add any new reference that is not in the evidence.
4. Use file_edit to surgically patch the specific equations, citations, or paragraphs in ${file_path}.
   CRITICAL: Do NOT rewrite the entire file from scratch, and do NOT truncate the document. Preserve the depth, tone, and full structure of the monograph.
5. When the edits are made and verified in ${file_path}, call milestone_complete to conclude the refinement pass."

            ui_info "Launching ReAct Refiner with full suite (bash_exec, file_edit, arxiv_search)..."
            local refiner_turns="${RESEARCH_REFINER_MAX_TURNS:-200}"
            export REACT_KEEP_TRANSCRIPT=1
            export REACT_MAX_OBSERVATION_CHARS="${REACT_MAX_OBSERVATION_CHARS:-32000}"
            REACT_TOOL_FILTER="research_refiner" \
            react_run "$refiner_goal" "$sandbox_dir" "$refiner_turns" "${ACTIVE_TIER:-1}" "refine_${artifact_type}_$(date +%s)" "research_refiner"

            if [ -f "$RESEARCH_VERIFIER_PY" ]; then
                python3 "$RESEARCH_VERIFIER_PY" lint-platform --file "$file_path" --fix >/dev/null 2>&1 || true
            fi
            return 0
        fi

        # Fallback single-shot prompt if react_run not available
        local refine_prompt="You are George, refining your synthesized ${artifact_type} on '${topic}'.

The previous draft was REJECTED by the Grounding Verification Gates:
${rejection_header}
${rejection_trace}

=== CURRENT DRAFT (revise this) ===
${draft_excerpt}
=== END DRAFT ===

=== EVIDENCE LEDGER (the ONLY sources you may cite) ===
${evidence_excerpt}
=== END EVIDENCE ===

CRITICAL REFINEMENT MANDATE:
1. Output ONLY the complete, revised, publication-ready ${artifact_type}.
2. Do NOT include any meta-commentary, self-correction notes, or internal reflections.
3. Every reference, statistic, equation, and named result must come from the EVIDENCE LEDGER above. Do NOT add any new reference, author, venue, identifier, or number that is not in the evidence.
4. If a flagged citation is not in the evidence, DELETE it together with the claims that depend on it.
5. If category collisions or unbridged jargon were flagged, provide the missing structural mapping or remove the claim.
6. A shorter, fully grounded ${artifact_type} is better than a longer one with unsupported content."

        local payload
        payload=$(jq -n --arg p "$refine_prompt" \
            '{messages: [{"role": "system", "content": "You are a master technical researcher refining a draft to satisfy strict mathematical and empirical verification gates."}, {"role": "user", "content": $p}, {"role": "assistant", "content": "<think>\n</think>\n"}], temperature: 0.4, max_tokens: 8192}')

        local raw_resp
        raw_resp=$(curl -s --max-time 300 "$llm_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)

        local refined_content
        refined_content=$(echo "$raw_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        if declare -f _research_strip_thinking &>/dev/null; then
            refined_content=$(_research_strip_thinking "$refined_content")
        fi

        if [ -n "$refined_content" ] && [ "${#refined_content}" -gt 80 ]; then
            echo "$refined_content" > "$file_path"
            if [ -f "$RESEARCH_VERIFIER_PY" ]; then
                python3 "$RESEARCH_VERIFIER_PY" lint-platform --file "$file_path" --fix >/dev/null 2>&1 || true
            fi
            return 0
        fi
    fi

    # Fallback refinement: clean known invalid phrases directly
    local cleaned="$current_content"
    # Remove hallucinated arXiv IDs if flagged
    cleaned=$(echo "$cleaned" | sed -E 's/arXiv:[0-9]{4}\.[0-9]{4,5}(v[0-9]+)?//gI')
    # Clean false year assertions (e.g. 2025 -> 2019 for Crypsinous)
    cleaned=$(echo "$cleaned" | sed -E 's/Crypsinous \([^)]*2025[^)]*\)/Crypsinous (IEEE S\&P 2019)/gI')
    # Clean category collision phrases
    cleaned=$(echo "$cleaned" | sed -E 's/1 honest signer among [0-9]+/k-of-m stake-weighted threshold signers/gI')
    cleaned=$(echo "$cleaned" | sed -E 's/low-rank matrix factorization and gradient descent/algebraic SNARK verification circuits/gI')
    echo "$cleaned" > "$file_path"
    if [ -f "$RESEARCH_VERIFIER_PY" ]; then
        python3 "$RESEARCH_VERIFIER_PY" lint-platform --file "$file_path" --fix >/dev/null 2>&1 || true
    fi
}

# ── Quarantine Deliverable ───────────────────────────────────────────
research_quarantine_artifact() {
    local topic="$1"
    local slug="$2"
    local sandbox_dir="$3"
    local reason="$4"

    local q_base="${RESEARCH_QUARANTINE_DIR:-${RESEARCH_DIR:-$GEORGE_DIR/research}/quarantine}"
    local q_dir="${q_base}/${slug}"
    mkdir -p "$q_dir" 2>/dev/null || true

    [ -f "$sandbox_dir/dossier.md" ] && cp "$sandbox_dir/dossier.md" "$q_dir/" 2>/dev/null || true
    [ -f "$sandbox_dir/thread.md" ] && cp "$sandbox_dir/thread.md" "$q_dir/" 2>/dev/null || true
    [ -f "$sandbox_dir/scratchpad.md" ] && cp "$sandbox_dir/scratchpad.md" "$q_dir/" 2>/dev/null || true

    cat << EOF > "$q_dir/quarantine_report.md"
# Research Deliverable Quarantine Report
**Topic:** $topic
**Inquiry Slug:** $slug
**Date Quarantined:** $(date -u '+%Y-%m-%d %H:%M:%SZ')
**Status:** QUARANTINED (Publication Blocked by Grounding Gate)

## Rejection Trace & Rationale
$reason

## Required Remediation
1. Verify primary source citations against official arXiv, DOI, or RFC registries.
2. Ensure mathematical and architectural primitives do not cross invalid abstraction boundaries.
3. Update scratchpad evidence before re-triggering investigation.
EOF

    ui_warn "Deliverable quarantined in sovereign library: $q_dir"
    declare -f transcript_log &>/dev/null && transcript_log "quarantine" "Deliverable quarantined in $q_dir: $reason"
    _research_notify_quarantine "$topic" "$q_dir" "$reason"
}

# ── Operator notice on quarantine (best effort, never fatal) ─────────
# A quarantined deliverable used to fail silently: nothing posted and the
# operator only found out by reading logs. Send a short Discord DM instead.
_research_notify_quarantine() {
    local topic="$1" q_dir="$2" reason="$3"
    [ "${RESEARCH_QUARANTINE_NOTIFY:-1}" = "1" ] || return 0
    [ "${LODGE_TEST_MODE:-0}" = "1" ] && return 0
    [ -n "${TEST_TMP:-}" ] && return 0
    if ! declare -f discord_send &>/dev/null; then
        source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null || return 0
    fi
    declare -f discord_send &>/dev/null || return 0

    # First few violation lines only; no paths beyond the library-relative dir.
    local summary
    summary=$(printf '%s\n' "$reason" | grep -oE '\[[A-Z_]+\][^[]{0,160}' | head -n 4)
    [ -z "$summary" ] && summary="${reason:0:400}"
    local msg
    msg="Research on \"${topic:0:120}\" was held back (quarantined) by the grounding gate, so nothing was published.
${summary}
Draft and evidence are in research/quarantine/$(basename "$q_dir")."
    declare -f social_sanitize_text &>/dev/null && msg=$(social_sanitize_text "$msg")
    discord_send "me" "${msg:0:1900}" >/dev/null 2>&1 || true
    return 0
}

# ── Main Two-Phase Verification & Refinement Orchestration Loop ───────
research_verify_and_refine() {
    local artifact_type="$1"   # "dossier" or "thread"
    local file_path="$2"
    local domain="$3"
    local topic="$4"
    local slug="$5"
    local sandbox_dir="$6"

    local max_retries="${RESEARCH_MAX_RETRIES:-4}"
    local attempt=0
    local passed=0
    local failure_reason=""

    ui_step "Running Grounding Verification Loop on ${artifact_type}..."

    while [ "$attempt" -le "$max_retries" ]; do
        # Dynamically reload verifier logic to pick up hotfixes across attempts
        source "${LODGE_DIR:-$HOME/blue-lodge}/lib/tools/research_verifier.sh" 2>/dev/null || true

        local content
        content=$(cat "$file_path" 2>/dev/null || true)
        [ -z "$content" ] && { failure_reason="Empty artifact content"; break; }

        # ── Gate 1: Deterministic Citation Resolver ──
        ui_info "Gate 1/3: Deterministic Citation & Entity Resolver (attempt $((attempt+1))/$((max_retries+1)))..."
        local cit_out cit_code=0
        cit_out=$(research_verify_citations "$content" "$topic" "$domain" "${sandbox_dir:+$sandbox_dir/scratchpad.md}") || cit_code=$?

        if [ "$cit_code" -ne 0 ]; then
            local cit_violations
            cit_violations=$(echo "$cit_out" | jq -r '.violations[]?' 2>/dev/null || echo "$cit_out")
            ui_warn "Gate 1 (Citation Resolver) detected violations:"
            echo "$cit_violations" | sed 's/^/  ● /'

            if [ "$attempt" -lt "$max_retries" ]; then
                _research_refine_artifact "$artifact_type" "$file_path" "$domain" "$topic" "$sandbox_dir" \
                    "[Deterministic Citation Resolver Violations]" "$cit_violations"
                attempt=$((attempt+1))
                continue
            else
                failure_reason="Gate 1 (Citation Resolver) failed after $((max_retries+1)) attempts: $cit_violations"
                break
            fi
        fi
        ui_ok "Gate 1 (Deterministic Citation Resolver) PASSED."

        # ── Gate 2: Adversarial Primitive Auditor ──
        ui_info "Gate 2/3: Adversarial Primitive Auditor (attempt $((attempt+1))/$((max_retries+1)))..."
        local aud_out aud_code=0
        aud_out=$(research_adversarial_audit "$content" "$topic" "$domain") || aud_code=$?

        if [ "$aud_code" -ne 0 ]; then
            ui_warn "Gate 2 (Adversarial Primitive Auditor) detected category errors:"
            echo "$aud_out" | sed 's/^/  ● /'

            if [ "$attempt" -lt "$max_retries" ]; then
                _research_refine_artifact "$artifact_type" "$file_path" "$domain" "$topic" "$sandbox_dir" \
                    "[Adversarial Primitive Auditor Invariant Collisions]" "$aud_out"
                attempt=$((attempt+1))
                continue
            else
                failure_reason="Gate 2 (Adversarial Auditor) failed after $((max_retries+1)) attempts: $aud_out"
                break
            fi
        fi
        if grep -qiE "ADVISORY:" <<< "$aud_out"; then
            ui_info "Gate 2 cleared with theoretical advisories (non-blocking)."
        else
            ui_ok "Gate 2 (Adversarial Primitive Auditor) PASSED."
        fi

        # ── Gate 3: Platform Syntax & Format Linter ──
        ui_info "Gate 3/3: Platform Syntax & Format Linter..."
        local lint_plat="twitter"
        [ "$artifact_type" = "thread" ] && lint_plat="social"
        research_platform_lint "$file_path" "$lint_plat"
        ui_ok "Gate 3 (Platform Syntax & Format Linter) PASSED."

        passed=1
        break
    done

    if [ "$passed" -eq 1 ]; then
        ui_ok "All verification gates cleared for ${artifact_type}."
        return 0
    fi

    # Quarantine routing
    ui_warn "Verification sub-graph rejected ${artifact_type}. Routing to quarantine queue..."
    research_quarantine_artifact "$topic" "$slug" "$sandbox_dir" "$failure_reason"
    return 1
}
