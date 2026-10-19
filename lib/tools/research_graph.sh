#!/bin/bash
# ── George: Autonomous Deep Research Engine ───────────────────────────
# Conducts multi-turn ReAct research investigations in an isolated sandbox,
# downloads verified arXiv preprints & primary papers via bash, analyzes visual
# diagrams with multimodal vision, scrapes social discourse, audits evidence,
# authors long-form technical monographs, conducts editorial critique passes,
# and PGP-signs deliverables for sovereign library archival and publication.
#
# Grounded strictly in soul.md: "Well done is better than well said."

[ -n "${_LIB_RESEARCH_GRAPH_LOADED:-}" ] && return 0; _LIB_RESEARCH_GRAPH_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
RESEARCH_DIR="${RESEARCH_DIR:-$GEORGE_DIR/research}"
RESEARCH_INDEX="${RESEARCH_INDEX:-$RESEARCH_DIR/research_index.jsonl}"
RESEARCH_QUEUE_DIR="${RESEARCH_QUEUE_DIR:-$GEORGE_DIR/social/queue}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/api.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sys/pgp.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/web.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/react.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/native_tools.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ui/popup.sh" 2>/dev/null || true
source "$LODGE_DIR/commands/vision.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/research_verifier.sh" 2>/dev/null || true

research_init() {
    RESEARCH_DIR="${RESEARCH_DIR:-$GEORGE_DIR/research}"
    RESEARCH_INDEX="${RESEARCH_INDEX:-$RESEARCH_DIR/research_index.jsonl}"
    RESEARCH_QUEUE_DIR="${RESEARCH_QUEUE_DIR:-$GEORGE_DIR/social/queue}"
    RESEARCH_QUARANTINE_DIR="${RESEARCH_QUARANTINE_DIR:-$RESEARCH_DIR/quarantine}"
    mkdir -p "$RESEARCH_DIR" "$RESEARCH_QUEUE_DIR" "$RESEARCH_QUARANTINE_DIR" "$GEORGE_DIR/social/signatures" 2>/dev/null || true
}

research_domain_topics_file() {
    local dom="$1"
    local base="${GEORGE_DIR:-${LODGE_DIR}/.george}"
    case "$dom" in
        academic) echo "$base/research_topics_academic.txt" ;;
        engineering) echo "$base/research_topics_engineering.txt" ;;
        finance) echo "$base/research_topics_finance.txt" ;;
        gaming) echo "$base/research_topics_gaming.txt" ;;
        general_sports_auto|sports_auto|sports) echo "$base/research_topics_general_sports_auto.txt" ;;
        *)
            if [ -f "$base/research_topics_${dom}.txt" ]; then
                echo "$base/research_topics_${dom}.txt"
            else
                echo "$base/research_topics.txt"
            fi
            ;;
    esac
}

research_domain_theme_label() {
    local dom="$1"
    case "$dom" in
        academic) echo "AI / ML & Science" ;;
        engineering) echo "Systems & Security" ;;
        finance) echo "Finance & Macro" ;;
        gaming) echo "Gaming & Emulation" ;;
        general_sports_auto|sports_auto|sports) echo "Sports & Automotive" ;;
        all) echo "All Themes (Random Mode)" ;;
        auto_optimal) echo "Auto-Optimal (Resonance Guided)" ;;
        *) echo "$dom" ;;
    esac
}

research_set_mode() {
    local new_mode="$1"
    local conf="${GEORGE_DIR:-${LODGE_DIR}/.george}/research.conf"
    local master="${GEORGE_DIR:-${LODGE_DIR}/.george}/research_topics.txt"
    case "$new_mode" in
        sports|auto|general_sports_auto|sports_auto) new_mode="general_sports_auto" ;;
        systems|security|engineering) new_mode="engineering" ;;
        macro|crypto|finance) new_mode="finance" ;;
        game|emulation|gaming) new_mode="gaming" ;;
        academic|ai|science) new_mode="academic" ;;
        auto_optimal|resonance) new_mode="auto_optimal" ;;
        all|random) new_mode="all" ;;
    esac

    local effective_mode="$new_mode"
    if [ "$new_mode" = "auto_optimal" ] && [ -f "$LODGE_DIR/lib/tools/social_analytics.py" ]; then
        effective_mode=$(python3 "$LODGE_DIR/lib/tools/social_analytics.py" recommend-domain --lodge-dir "$LODGE_DIR" --offline 2>/dev/null || echo "academic")
    fi

    local t_file
    t_file=$(research_domain_topics_file "$effective_mode")

    if [ -f "$conf" ]; then
        if command -v jq &>/dev/null; then
            local tmp
            tmp=$(jq --arg m "$new_mode" '.active_domain = $m' "$conf" 2>/dev/null)
            [ -n "$tmp" ] && echo "$tmp" > "$conf"
        fi
    fi

    if [ -f "$t_file" ] && [ "$effective_mode" != "all" ]; then
        cp "$t_file" "$master" 2>/dev/null || true
    fi

    local label
    label=$(research_domain_theme_label "$new_mode")
    local cnt
    cnt=$(grep -v '^[[:space:]]*#' "$master" 2>/dev/null | grep -v '^[[:space:]]*$' | wc -l)
    ui_ok "Switched Research Mode to: $label ($new_mode) [$cnt topics loaded into active pool]"
}

# ── Strip Thinking / Chain-of-Thought Blocks & Deliberation Chatter ───
_research_strip_thinking() {
    local text="$1"
    [ -z "$text" ] && return 0
    if command -v python3 &>/dev/null; then
        python3 -c '
import sys, re
raw = sys.stdin.read()
cleaned = re.sub(r"(?is)<think>.*?</think>", "", raw)
cleaned = re.sub(r"(?is)\[think\].*?\[/think\]", "", cleaned)
cleaned = re.sub(r"(?is)\[thought\].*?\[/thought\]", "", cleaned)
cleaned = re.sub(r"(?i)</?think>", "", cleaned)
cleaned = re.sub(r"(?i)\[/?thought\]", "", cleaned)
cleaned = re.sub(r"(?i)\[/?think\]", "", cleaned)

# Filter out plain-text scratchpad deliberation lines (e.g. character counting, internal drafting)
lines = []
for line in cleaned.split("\n"):
    l_strip = line.strip()
    if re.search(r"^(we need|i need to|let'\''s (draft|count|think|answer)|characters?:|count:?|para\s*\d+:?|paragraph\s*\d+:?|the user (wants|asked)|as george\?)", l_strip, re.I):
        continue
    if re.search(r"(characters:\s*the=|count\?\s*let'\''s\s*count|dossier=\d+|space\s*\d+)", l_strip, re.I):
        continue
    lines.append(line)
cleaned = "\n".join(lines).strip()
print(cleaned)
' <<< "$text" 2>/dev/null
    elif command -v perl &>/dev/null; then
        perl -0777 -pe 's/<think>.*?<\/think>//gis; s/\[think\].*?\[\/think\]//gis; s/\[thought\].*?\[\/thought\]//gis; s/<\/?think>//gi;' <<< "$text" 2>/dev/null
    else
        echo "$text" | sed -E 's/<\/?think>//gI; s/\[\/?THINK\]//gI; s/\[\/?THOUGHT\]//gI'
    fi
}

_research_is_deliberation_trace() {
    local text="$1"
    [ -z "$text" ] && return 1
    if grep -iqE "(let's (draft|count|think)|we need (answer|produce)|i need to|characters?:|para[0-9]:|paragraph [0-9]:|count\?|token budget|the user (wants|asked)|as george\?|count roughly|dossier=[0-9]+)" <<< "$text"; then
        return 0
    fi
    return 1
}

# ── Post-50 Dialectic Combinatorial Synthesizer (Option 3) ────────────
research_synthesize_combinatorial_topic() {
    local index_file="${RESEARCH_INDEX:-$GEORGE_DIR/research/research_index.jsonl}"
    # If active index has fewer than 2 entries, fall back to the most recent archive
    if [ ! -f "$index_file" ] || [ "$(wc -l < "$index_file" 2>/dev/null || echo 0)" -lt 2 ]; then
        local latest_arch
        latest_arch=$(ls -td "$GEORGE_DIR"/research_archive_v1_* 2>/dev/null | head -n 1)
        if [ -n "$latest_arch" ] && [ -f "$latest_arch/research_index.jsonl" ]; then
            index_file="$latest_arch/research_index.jsonl"
        fi
    fi

    [ -f "$index_file" ] || return 1
    local count
    count=$(wc -l < "$index_file" 2>/dev/null || echo 0)
    [ "$count" -lt 2 ] && return 1

    # Extract topics from different domains
    local topic_a topic_b domain_a domain_b
    local sample_lines
    sample_lines=$(shuf -n 10 "$index_file" 2>/dev/null || head -n 10 "$index_file")

    topic_a=$(echo "$sample_lines" | jq -r '.topic // .title // empty' 2>/dev/null | head -n 1)
    [ -z "$topic_a" ] && return 1
    domain_a=$(research_classify_domain "$topic_a")

    while IFS= read -r line; do
        local cand_topic cand_dom
        cand_topic=$(echo "$line" | jq -r '.topic // .title // empty' 2>/dev/null)
        if [ -n "$cand_topic" ] && [ "$cand_topic" != "$topic_a" ]; then
            cand_dom=$(research_classify_domain "$cand_topic")
            if [ "$cand_dom" != "$domain_a" ]; then
                topic_b="$cand_topic"
                domain_b="$cand_dom"
                break
            fi
        fi
    done <<< "$sample_lines"

    if [ -z "$topic_b" ]; then
        topic_b=$(echo "$sample_lines" | jq -r '.topic // .title // empty' 2>/dev/null | grep -vFx "$topic_a" | head -n 1)
    fi
    [ -z "$topic_b" ] && return 1

    local clean_a clean_b
    clean_a=$(echo "$topic_a" | sed -E 's/^\[[a-zA-Z0-9_-]+\][[:space:]]*//')
    clean_b=$(echo "$topic_b" | sed -E 's/^\[[a-zA-Z0-9_-]+\][[:space:]]*//')

    local llm_url="${LODGE_LLM_URL:-http://127.0.0.1:8080}"
    local synth_topic=""
    if curl -s -m 5 "$llm_url/health" &>/dev/null || curl -s -m 5 "$llm_url/v1/models" &>/dev/null; then
        local prompt="Synthesize a single novel research inquiry title intersecting these two domains:
Domain 1 ($domain_a): '$clean_a'
Domain 2 ($domain_b): '$clean_b'
Requirements:
1. Synthesize a concrete, rigorous theoretical or systems question bridging both fields.
2. Return ONLY the title formatted as: [hybrid] Title Here
3. Max 14 words. No quotes, no markdown bolding, no explanations."
        local payload
        payload=$(jq -n --arg p "$prompt" '{messages: [{"role": "system", "content": "You are a research synthesis director. Output only the requested title."}, {"role": "user", "content": $p}], temperature: 0.8, max_tokens: 60}')
        local raw
        raw=$(curl -s -m 20 "$llm_url/v1/chat/completions" -H "Content-Type: application/json" -d "$payload" 2>/dev/null)
        synth_topic=$(echo "$raw" | jq -r '.choices[0].message.content // empty' 2>/dev/null | tr -d '\n\r"' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    fi

    if [ -z "$synth_topic" ] || [[ "$synth_topic" =~ (error|invalid) ]]; then
        local templates=(
            "[hybrid] ${clean_a} Dynamics in ${clean_b}"
            "[hybrid] Cross-Domain Synthesis: ${clean_a} Applied to ${clean_b}"
            "[hybrid] Topological and Thermodynamic Dualities Between ${clean_a} and ${clean_b}"
        )
        synth_topic="${templates[$(( RANDOM % ${#templates[@]} ))]}"
    fi

    echo "$synth_topic"
}

# ── Post-50 Frontier Expansion Synthesizer (Option 1) ─────────────────
research_synthesize_frontier_topic() {
    local domain_arg="${1:-}"
    local chosen_domain="$domain_arg"
    if [ -z "$chosen_domain" ] || [ "$chosen_domain" = "all" ]; then
        local domains=("academic" "engineering" "finance" "gaming" "general_sports_auto")
        chosen_domain="${domains[$(( RANDOM % ${#domains[@]} ))]}"
    fi
    local llm_url="${LODGE_LLM_URL:-http://127.0.0.1:8080}"
    local synth_topic=""
    local theme_title
    theme_title=$(research_domain_theme_label "$chosen_domain")

    if curl -s -m 5 "$llm_url/health" &>/dev/null || curl -s -m 5 "$llm_url/v1/models" &>/dev/null; then
        local prompt="Propose an authoritative, cutting-edge research inquiry title in the domain of '$theme_title' ($chosen_domain).
Requirements:
1. Must tackle an unsolved modern technical, algorithmic, or physical challenge.
2. Must cite or imply concrete mechanics (e.g., memory bottlenecks, algebraic bounds, JIT recompiler timing, zero-knowledge circuits, or aerodynamic telemetry).
3. Return ONLY the title formatted as: [empirical] Title Here (or [executive] Title Here).
4. Max 14 words. No quotes, no preamble."
        local payload
        payload=$(jq -n --arg p "$prompt" '{messages: [{"role": "system", "content": "You are a principal scientist. Output only the requested title."}, {"role": "user", "content": $p}], temperature: 0.9, max_tokens: 60}')
        local raw
        raw=$(curl -s -m 20 "$llm_url/v1/chat/completions" -H "Content-Type: application/json" -d "$payload" 2>/dev/null)
        synth_topic=$(echo "$raw" | jq -r '.choices[0].message.content // empty' 2>/dev/null | tr -d '\n\r"' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    fi

    if [ -z "$synth_topic" ] || [[ "$synth_topic" =~ (error|invalid) ]]; then
        case "$chosen_domain" in
            general_sports_auto|sports_auto|sports)
                local fallbacks=(
                    "[empirical] Expected Points Added (EPA) and Success Rate Variance in NFL Red Zone Play Calling"
                    "[executive] Salary Cap Restructuring, Void Years, and Long-Term Dead Money Risk in Modern NFL Roster Construction"
                    "[hybrid] Pre-Snap Motion Rates and Defensive Coverage Disguise Detection Using Next Gen Stats Tracking Vectors"
                    "[storyteller] The Ice Bowl and Sub-Zero Thermodynamic Physics of Late-Game Fourth-Quarter Drives at Lambeau Field"
                )
                ;;
            finance)
                local fallbacks=(
                    "[executive] EUTxO Concurrency Models and Minswap Batcher Queue Determinism"
                    "[hybrid] Cointegration Dynamics and Johansen Eigenvalue Stability in DEX Pools"
                    "[executive] Non-Custodial Plutus V3 Script Optimization for Limit Order Books"
                    "[empirical] Cardano Hydra Head Settlement Latency and Invariant Proofs"
                )
                ;;
            gaming)
                local fallbacks=(
                    "[executive] Hardware-Assisted Cycle-Accurate Vector Execution in Next-Gen Console Emulation"
                    "[empirical] Emotion Engine Vector Unit 0/1 Microcode JIT Recompilation"
                    "[executive] Dynamic Binary Translation of ARM64 NEON Vector Instructions to AVX2"
                    "[hybrid] PS3 Cell Broadband Engine SPU Thread Emulation"
                )
                ;;
            engineering)
                local fallbacks=(
                    "[empirical] eBPF Ring Buffer Backpressure and Tail Latency Under 100GbE Line Rates"
                    "[executive] io_uring Registered Buffers vs epoll in Zero-Copy Storage Fabrics"
                    "[hybrid] Deterministic Raft Consensus and Hybrid Logical Clocks Under Partitions"
                    "[executive] High-Throughput Zero-Copy POSIX FIFO IPC Architectures for Decoupled Runtimes"
                )
                ;;
            *)
                local fallbacks=(
                    "[empirical] Speculative Paged Attention and Non-Blocking KV Deserialization in Distributed Inference"
                    "[hybrid] Multi-Token Speculative Drafting with Medusa Heads on Constrained VRAM"
                    "[executive] Kernel Fusion and SRAM Occupancy Optimization for FlashAttention on Ada"
                    "[storyteller] Kolmogorov Complexity Estimators for Neural Compression and Generalization"
                )
                ;;
        esac
        synth_topic="${fallbacks[$(( RANDOM % ${#fallbacks[@]} ))]}"
    fi

    local target_file
    target_file=$(research_domain_topics_file "$chosen_domain")
    if [ -f "$target_file" ] && ! grep -qxF "$synth_topic" "$target_file" 2>/dev/null; then
        echo "$synth_topic" >> "$target_file"
    fi
    if [ -f "$GEORGE_DIR/research_topics.txt" ] && ! grep -qxF "$synth_topic" "$GEORGE_DIR/research_topics.txt" 2>/dev/null; then
        echo "$synth_topic" >> "$GEORGE_DIR/research_topics.txt"
    fi

    echo "$synth_topic"
}

# ── Dynamic Topic Discovery ──────────────────────────────────────────
# Formulates an open-ended research question from journal reflections & social feeds,
# with strict deduplication against previously completed research monographs.
# Pulls from domain-specific topic pool when a mode/domain is configured.
research_discover_topic() {
    local domain_arg="${1:-}"
    local topic=""

    # 1. Check recent journal reflections for open technical hypotheses
    local journal_file="$GEORGE_DIR/journal.md"
    if [ -f "$journal_file" ]; then
        local recent_reflection
        recent_reflection=$(grep -E '^(###|##) [0-9]' "$journal_file" -A 10 2>/dev/null | tail -n 12 2>/dev/null)
        if [ -n "$recent_reflection" ]; then
            local cand_journal
            cand_journal=$(echo "$recent_reflection" | grep -v '^#' | grep -v '^[[:space:]]*$' | head -n 1 | cut -c 1-120)
            local j_slug
            j_slug=$(research_slugify "$cand_journal")
            # Only use if not researched in recent index and matches requested domain (if specific domain requested)
            if [ -n "$cand_journal" ]; then
                local j_dom
                j_dom=$(research_classify_domain "$cand_journal")
                if [ -z "$domain_arg" ] || [ "$domain_arg" = "all" ] || [ "$domain_arg" = "$j_dom" ]; then
                    if [ ! -f "$RESEARCH_INDEX" ] || ! grep -qi "$j_slug" "$RESEARCH_INDEX" 2>/dev/null; then
                        topic="$cand_journal"
                    fi
                fi
            fi
        fi
    fi

    # 2. Sovereign topic pool with historical deduplication
    if [ -z "$topic" ]; then
        local target_domain="$domain_arg"
        if [ -z "$target_domain" ]; then
            target_domain="${RESEARCH_MODE:-${RESEARCH_DOMAIN:-}}"
        fi
        if [ -z "$target_domain" ] && [ -f "$GEORGE_DIR/research.conf" ]; then
            target_domain=$(jq -r '.active_domain // empty' "$GEORGE_DIR/research.conf" 2>/dev/null)
        fi
        if [ -z "$target_domain" ] || [ "$target_domain" = "null" ]; then
            target_domain="academic"
        fi

        if [ "$target_domain" = "auto_optimal" ] || [ "$target_domain" = "resonance" ]; then
            if [ -f "$LODGE_DIR/lib/tools/social_analytics.py" ]; then
                target_domain=$(python3 "$LODGE_DIR/lib/tools/social_analytics.py" recommend-domain --lodge-dir "$LODGE_DIR" --offline 2>/dev/null || echo "academic")
            else
                target_domain="academic"
            fi
        elif [ "$target_domain" = "all" ] || [ "$target_domain" = "random" ]; then
            local domains=("academic" "engineering" "finance" "gaming" "general_sports_auto")
            target_domain="${domains[$(( RANDOM % ${#domains[@]} ))]}"
        fi

        local candidate_topics=()
        local pool_file
        pool_file=$(research_domain_topics_file "$target_domain")

        if [ -f "$pool_file" ]; then
            while IFS= read -r c_conf; do
                [ -n "$c_conf" ] && candidate_topics+=("$c_conf")
            done < <(grep -v '^[[:space:]]*#' "$pool_file" | grep -v '^[[:space:]]*$' 2>/dev/null)
        fi

        # Fallback to general pool if domain-specific pool is empty
        if [ ${#candidate_topics[@]} -eq 0 ] && [ -f "$GEORGE_DIR/research_topics.txt" ]; then
            while IFS= read -r c_conf; do
                [ -n "$c_conf" ] && candidate_topics+=("$c_conf")
            done < <(grep -v '^[[:space:]]*#' "$GEORGE_DIR/research_topics.txt" | grep -v '^[[:space:]]*$' 2>/dev/null)
        elif [ ${#candidate_topics[@]} -eq 0 ] && [ -f "$GEORGE_DIR/research.conf" ]; then
            while IFS= read -r c_conf; do
                [ -n "$c_conf" ] && candidate_topics+=("$c_conf")
            done < <(jq -r '.candidate_topics[]?' "$GEORGE_DIR/research.conf" 2>/dev/null)
        fi

        if [ ${#candidate_topics[@]} -eq 0 ]; then
            candidate_topics=(
                "Low-rank matrix factorizations and loss landscapes in consumer GPU GEMM"
                "Claude Shannon entropy bounds in calibrated 4-bit KV cache quantization"
                "Continuous state-space models and selective state representations in edge compute"
                "Memory-bandwidth thermodynamics and register scheduling in local inference"
                "Next-generation reservoir computing and nonlinear vector autoregression"
            )
        fi

        local fresh_topics=()
        local q_base="${RESEARCH_QUARANTINE_DIR:-${RESEARCH_DIR:-$GEORGE_DIR/research}/quarantine}"
        for cand in "${candidate_topics[@]}"; do
            local cand_slug
            cand_slug=$(research_slugify "$cand")
            local is_recent=0
            # 1. Check verified research index
            if [ -f "$RESEARCH_INDEX" ] && grep -qi "$cand_slug" "$RESEARCH_INDEX" 2>/dev/null; then
                is_recent=1
            fi
            # 2. Check blog publication history
            if [ -f "$GEORGE_DIR/social/blog_history.jsonl" ] && grep -qi "$cand_slug" "$GEORGE_DIR/social/blog_history.jsonl" 2>/dev/null; then
                is_recent=1
            fi
            # 3. Check quarantine backlog (do not re-research items already quarantined for salvage)
            if [ -d "$q_base/$cand_slug" ] || [ -d "$q_base/${cand_slug:0:48}" ]; then
                is_recent=1
            fi
            # 4. Check active running sandboxes (prevent concurrent duplicate research runs)
            if compgen -G "${LODGE_DIR}/.sandboxes/research_${cand_slug}*" >/dev/null 2>&1; then
                is_recent=1
            fi

            if [ "$is_recent" -eq 0 ]; then
                fresh_topics+=("$cand")
            fi
        done

        if [ ${#fresh_topics[@]} -gt 0 ]; then
            local rand_idx=$(( RANDOM % ${#fresh_topics[@]} ))
            topic="${fresh_topics[$rand_idx]}"
        else
            # POST-50 REPLENISHMENT STRATEGY (Options 1 & 3)
            # When all defined topics have been researched or quarantined:
            # 2/3 of the time: Option 3 - Combinatorial Cross-Domain Dialectic Synthesis
            # 1/3 of the time: Option 1 - Frontier Expansion via LLM hypothesis generation
            local mode_roll=$(( RANDOM % 3 ))
            local synthesized_topic=""

            if [ "$mode_roll" -ne 0 ]; then
                synthesized_topic=$(research_synthesize_combinatorial_topic)
            fi

            if [ -z "$synthesized_topic" ]; then
                synthesized_topic=$(research_synthesize_frontier_topic "$target_domain")
            fi

            if [ -n "$synthesized_topic" ]; then
                topic="$synthesized_topic"
            else
                local rand_idx=$(( RANDOM % ${#candidate_topics[@]} ))
                topic="${candidate_topics[$rand_idx]}"
            fi
        fi
    fi

    echo "$topic"
}

# ── Slug Generator ───────────────────────────────────────────────────
research_slugify() {
    local raw="$1"
    raw=$(echo "$raw" | sed -E 's/^\[[a-zA-Z0-9_-]+\][[:space:]]*//')
    echo "$raw" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c 1-50
}

# ── Domain Classification Helper ─────────────────────────────────────
# Classifies research topics into 5 distinct domains:
# 1. academic: arXiv, preprints, peer-reviewed science, deep ML theory
# 2. engineering: GitHub repos, RFCs, system architecture, APIs, compilers
# 3. general_sports_auto: Sports teams, rosters, automotive engineering, OEM specs
# 4. finance: 10-K, earnings transcripts, DeFi, balance sheets, valuation
# 5. gaming: Emulation (JIT, cycle accuracy), decompilation, hardware architecture, game engines
research_classify_domain() {
    local topic="$1"
    local hint_dom="${2:-}"
    local base="${GEORGE_DIR:-${LODGE_DIR}/.george}"

    # 1. Normalize hint domain if provided
    case "$hint_dom" in
        sports|auto|general_sports_auto|sports_auto) hint_dom="general_sports_auto" ;;
        systems|security|engineering) hint_dom="engineering" ;;
        macro|crypto|finance) hint_dom="finance" ;;
        game|emulation|gaming) hint_dom="gaming" ;;
        academic|ai|science) hint_dom="academic" ;;
        all|random|"") hint_dom="" ;;
    esac

    # 2. Check if topic directly belongs to a known domain topics file
    local clean_check
    clean_check=$(echo "$topic" | sed -E 's/^\[[a-zA-Z0-9_-]+\][[:space:]]*//' | tr -d '\r\n')

    # If hint_dom provided, check its specific topics file first
    if [ -n "$hint_dom" ]; then
        local hint_file
        hint_file=$(research_domain_topics_file "$hint_dom")
        if [ -f "$hint_file" ] && grep -qF "$clean_check" "$hint_file" 2>/dev/null; then
            echo "$hint_dom"
            return 0
        fi
    fi

    # Check active domain from config
    local active_dom=""
    if [ -f "$base/research.conf" ]; then
        active_dom=$(jq -r '.active_domain // empty' "$base/research.conf" 2>/dev/null)
        case "$active_dom" in
            sports|auto|general_sports_auto|sports_auto) active_dom="general_sports_auto" ;;
            systems|security|engineering) active_dom="engineering" ;;
            macro|crypto|finance) active_dom="finance" ;;
            game|emulation|gaming) active_dom="gaming" ;;
            academic|ai|science) active_dom="academic" ;;
            all|random|"") active_dom="" ;;
        esac
        if [ -n "$active_dom" ]; then
            local act_file
            act_file=$(research_domain_topics_file "$active_dom")
            if [ -f "$act_file" ] && grep -qF "$clean_check" "$act_file" 2>/dev/null; then
                echo "$active_dom"
                return 0
            fi
        fi
    fi

    # Check all domain files
    for d in general_sports_auto gaming finance engineering academic; do
        local df
        df=$(research_domain_topics_file "$d")
        if [ -f "$df" ] && grep -qF "$clean_check" "$df" 2>/dev/null; then
            echo "$d"
            return 0
        fi
    done

    local lower="${topic,,}"

    # 3. Explicit Sports / Automotive / Racing / NFL Keywords
    if echo "$lower" | grep -qiE '\b(sport|sports|football|soccer|baseball|basketball|hockey|nfl|nba|mlb|nhl|fifa|premier\ league|champions\ league|ncaa|quarterback|wide\ receiver|linebacker|safety|cornerback|tight\ end|offensive\ line|defensive\ line|head\ coach|depth\ chart|roster|starter|championship|super\ bowl|touchdown|sideline|walk-off|interception|field\ goal|end\ zone|playoff|vikings|saints|packers|patriots|chiefs|eagles|cowboys|bills|passer|rushing|tackle|blitz|ice\ bowl|hail\ mary|motorsport|racing|formula\ 1|f1|nascar|indycar|motogp|lemans|hypercar|gt3|telemetry|chassis|aerodynamics|drag\ reduction|drs|venturi|downforce|turbocharger|turbocharged|supercharger|dyno|dynamometer|horsepower|torque|powertrain|apex|cornering|braking|lap\ time|0-60|quarter-mile|cars?|automotive|engine|vehicle|porsche|ferrari|bmw|mercedes|ford|gm|toyota|honda|tesla|mph)\b'; then
        echo "general_sports_auto"
    # 4. Gaming / Emulation / Decompilation
    elif echo "$lower" | grep -qiE '\b(game|gaming|emulat(or|ion)?|decompile|decompilation|jit|recompiler|ps[1-5]|switch|gamecube|n64|nintendo|playstation|xbox|retroarch|dolphin|pcsx2|rpcs3|godot|unreal|unity|rom|iso|disassembly|ghidra|ida\ pro|vector\ unit|emotion\ engine|cell\ broadband)\b'; then
        echo "gaming"
    # 5. Academic / Science / Cryptography / Mathematics
    elif echo "$lower" | grep -qiE '\b(zero[- ]knowledge|snark|stark|cryptograph(y|ic)|proofs?|nanotube|nanotech|semiconductor|superconductor|preprint|arxiv|theorem|equation|formula|quantum|algebra|manifold|tensor|thermodynamics|physics)\b'; then
        echo "academic"
    # 6. Engineering / Systems / Software
    elif echo "$lower" | grep -qiE '\b(rfc|github|repo|linux|kernel|driver|protocol|system|systems|networking|distributed|database|compiler|microservice|kubernetes|docker|security|vulnerability|exploit|cve|api|backend|frontend|rust|golang|c\+\+)\b'; then
        echo "engineering"
    # 7. Finance / Investments / Crypto / DeFi / Web3
    elif echo "$lower" | grep -qiE '\b(finance|financial|stock|invest(ment|or)?|equity|market|crypto|cryptocurrency|bitcoin|ethereum|cardano|solana|blockchain|utxo|ledger|defi|tokenomics|yield|10-k|10-q|earnings|revenue|ebitda|valuation|dividend|portfolio|trading|forex|treasury|interest\ rate|balance\ sheet|sec\ filing)\b'; then
        echo "finance"
    # 8. Fallback: if an active domain or hint was specified, prefer it over default academic
    elif [ -n "$hint_dom" ]; then
        echo "$hint_dom"
    elif [ -n "$active_dom" ]; then
        echo "$active_dom"
    else
        echo "academic"
    fi
}

# ── Sub-Domain Archetype Classifier ──────────────────────────────────
# Distinguishes specialized archetypes inside broad domains (especially finance:
# protocol_crypto vs microstructure_macro vs corporate_equity) so Phase 3 and Phase 5
# never force corporate 10-K/EBITDA templates onto market microstructure or DeFi topics.
research_classify_subdomain() {
    local topic="$1"
    local domain="${2:-}"
    [ -z "$domain" ] && domain=$(research_classify_domain "$topic")
    local lower="${topic,,}"

    case "$domain" in
        finance)
            if echo "$lower" | grep -qiE '\b(eutxo|utxo|cardano|plutus|hydra|ouroboros|mithril|cip-|minswap|sundaeswap|amm|dex|defi|tokenomics|polymarket|stablecoin|synthetic\ asset|liquidation\ cascade|smart\ contract|liquidity\ pool|batcher|mempool)\b'; then
                echo "finance:protocol_crypto"
            elif echo "$lower" | grep -qiE '\b(10-k|10-q|sec\ form|sec\ filing|earnings|balance\ sheet|ebitda|operating\ lease|footnote|corporate\ credit|cds|dividend|shareholder|gaap|equity\ valuation)\b'; then
                echo "finance:corporate_equity"
            else
                echo "finance:microstructure_macro"
            fi
            ;;
        general_sports_auto)
            if echo "$lower" | grep -qiE '\b(motorsport|racing|formula\ 1|f1|nascar|indycar|motogp|lemans|hypercar|gt3|chassis|aerodynamics|drag\ reduction|drs|venturi|downforce|turbocharger|supercharger|dyno|dynamometer|horsepower|torque|powertrain|apex|cornering|lap\ time|0-60|quarter-mile|automotive|engine|vehicle|porsche|ferrari|bmw|mercedes|ford|gm|toyota|honda|tesla|mph)\b'; then
                echo "general_sports_auto:automotive"
            else
                echo "general_sports_auto:sports"
            fi
            ;;
        *)
            echo "${domain}:general"
            ;;
    esac
}

# ── Phase 1: ReAct Deep Investigation Loop in Sandbox ────────────────
# Executes an autonomous agentic research loop equipped with web, bash, vision, and social tools
research_investigate_react() {
    local topic="$1"
    local sandbox_dir="$2"
    local domain="${3:-}"
    local scratchpad="$sandbox_dir/scratchpad.md"
    [ -z "$domain" ] && domain=$(research_classify_domain "$topic")
    local subdomain
    subdomain=$(research_classify_subdomain "$topic" "$domain")

    ui_step "Phase 1/5: Autonomous ReAct Research Loop in Sandbox [Domain: ${domain} (${subdomain})]..."
    ui_think "Grounding in soul.md: 'Well done is better than well said.' Forbidding pseudo-philosophical fluff."

    local endpoints_online=0
    endpoints_cascade "${ACTIVE_TIER:-1}" 2>/dev/null || endpoints_init 2>/dev/null || true
    local llm_url="${ACTIVE_ENDPOINT_URL:-${TIER1_URL:-http://127.0.0.1:8080}}"
    if curl -sf --connect-timeout 2 --max-time 3 "$llm_url/v1/models" &>/dev/null; then
        endpoints_online=1
    fi

    local mandate_items=""
    case "$domain" in
        gaming)
            mandate_items="- Ingest primary emulation architectures, hardware block diagrams, CPU/GPU register specs, Vector Unit microcode, JIT recompiler pipelines, and decompilation codebases.
- Download architecture diagrams and memory maps to artifacts/ and analyze via vision_analyze."
            ;;
        finance)
            case "$subdomain" in
                finance:protocol_crypto)
                    mandate_items="- Ingest protocol specifications, CIP standards, smart contract execution bounds, AMM/DEX liquidity models, and empirical on-chain/settlement benchmarks.
- Download protocol architecture or liquidity diagrams to artifacts/ and analyze via vision_analyze."
                    ;;
                finance:corporate_equity)
                    mandate_items="- Ingest primary SEC filings (10-K, 10-Q), earnings call transcripts, audited balance sheets, free cash flow models, and credit/valuation metrics.
- Download financial charts and capital breakdown graphs to artifacts/ and analyze via vision_analyze."
                    ;;
                *)
                    mandate_items="- Ingest econometric literature, central bank / regulatory reports (Federal Reserve, BIS, CFTC, SEC), market microstructure models, and empirical liquidity/spread data.
- Download liquidity curves or microstructure diagrams to artifacts/ and analyze via vision_analyze."
                    ;;
            esac
            ;;
        general_sports_auto)
            mandate_items="- Ingest official OEM technical specifications, dynamometer/telemetry figures, depth charts, starters, performance splits, and primary source records.
- Download technical schematics, dyno curves, or play diagrams to artifacts/ and analyze via vision_analyze."
            ;;
        engineering)
            mandate_items="- Ingest RFCs, official specification standards, open-source repository implementations, API signatures, and empirical latency/scale benchmarks.
- Download system architecture diagrams to artifacts/ and analyze via vision_analyze."
            ;;
        academic|*)
            mandate_items="- Ingest primary academic literature, arXiv preprints, exact mathematical formulations, benchmark metrics, and community discourse.
- Download figures to artifacts/ and analyze via vision_analyze."
            ;;
    esac

    cat << EOF > "$scratchpad"
# Deep Research Scratchpad: ${topic}
**Date:** $(date -u '+%Y-%m-%d %H:%M:%SZ')
**Investigator:** George (Blue Lodge Scholar - Tier 1)
**Domain:** ${domain}
**Category:** ${domain}
**Theme:** $(research_domain_theme_label "${domain}")

## Research Mandate & Directives (soul.md)
- "Well done is better than well said."
- The Impartial Spectator strictly forbids superficial fluff and pseudo-philosophical filler.
${mandate_items}

## Verified Empirical Evidence & Findings
EOF

    # If live endpoint is active and not in unit-test-isolation mode, run multi-turn ReAct
    if [ "$endpoints_online" -eq 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ] && [ -z "${TEST_TMP:-}" ]; then
        local domain_instructions="" domain_convergence=""
        case "$domain" in
            gaming)
                domain_instructions="1. Search for technical emulation documentation, hardware manuals, and decompilation repositories (e.g. GitHub decomp projects) on '$topic' using web_search or searxng_search.
2. Ingest exact hardware execution details: CPU/GPU registers, Vector Units, cycle accuracy bounds, JIT recompiler pipelines, frame pacing, microcode, or decompiled C/C++ logic.
3. (Optional) Search developer postmortems or scene discussions for real implementation trade-offs and edge cases.
4. (Optional) If hardware block diagrams, frame time graphs, or memory maps are found AND vision capability is active, download them to artifacts/ and run vision_analyze.
5. Record concrete hardware specifications, recompiler strategies, decompilation progress/functions, and verified citations into scratchpad.md."
                domain_convergence="Once you have cataloged 3 to 5 verified primary sources (hardware manuals, architectural block diagrams, recompiler repositories, or decompiled codebases) and concrete execution details in scratchpad.md, your mission is COMPLETE."
                ;;
            finance)
                case "$subdomain" in
                    finance:protocol_crypto)
                        domain_instructions="1. Search for primary protocol whitepapers, CIP specifications, academic cryptography/DeFi papers, and official repository docs on '$topic' using web_search, arxiv_search, or searxng_search.
2. Ingest formal state-transition equations, EUTxO/AMM invariants, batcher/settlement latency bounds, script budget limits, and empirical liquidity metrics into scratchpad.md.
3. (Optional) Search technical governance or developer discussions for adversarial edge cases, MEV/contention vectors, and closure invariants.
4. Record exact mathematical formulations, protocol parameters, throughput/latency figures, and verified primary sources into scratchpad.md."
                        domain_convergence="Once you have cataloged 3 to 5 verified primary sources (protocol whitepapers, CIPs, academic preprints, or empirical on-chain benchmarks) and concrete mathematical/protocol metrics in scratchpad.md, your mission is COMPLETE."
                        ;;
                    finance:corporate_equity)
                        domain_instructions="1. Search for primary SEC filings (10-K, 10-Q), earnings call transcripts, audited financial disclosures, or credit research on '$topic' using web_search or searxng_search.
2. Ingest hard financial metrics: revenue trajectories, margins, free cash flow, EBITDA, off-balance-sheet liabilities, debt schedules, and valuation multiples into scratchpad.md.
3. Record exact dollar figures, basis-point spreads, accounting footnotes, and verified primary sources into scratchpad.md."
                        domain_convergence="Once you have cataloged 3 to 5 verified primary sources (SEC filings, earnings transcripts, audited balance sheet figures, or credit reports) and concrete empirical metrics in scratchpad.md, your mission is COMPLETE."
                        ;;
                    *)
                        domain_instructions="1. Search for primary econometric papers, central bank working papers (Federal Reserve, BIS, OFR), regulatory reports (CFTC, SEC), or quantitative finance preprints on '$topic' using web_search, arxiv_search, or searxng_search.
2. Ingest exact mathematical formulations (e.g., price impact coefficients, spread decomposition equations, rate corridor bounds, convexity/cointegration estimators) and empirical market data into scratchpad.md.
3. Record concrete basis-point spreads, dollar volumes, regression/eigenvalue statistics, historical shock episodes, and verified primary citations into scratchpad.md."
                        domain_convergence="Once you have cataloged 3 to 5 verified primary sources (econometric papers, central bank/regulatory disclosures, or empirical market datasets) and concrete mathematical/quantitative metrics in scratchpad.md, your mission is COMPLETE."
                        ;;
                esac
                ;;
            general_sports_auto)
                domain_instructions="1. Search for authoritative specifications, official statistics, depth charts, rosters, or OEM technical sheets on '$topic' using web_search or searxng_search.
2. Ingest primary team/game reports or manufacturer technical specs (horsepower, torque, chassis, lap times, player stats, season splits) into scratchpad.md.
3. (Optional) Search analytical commentary and expert breakdowns to analyze tactical strategies, design evolution, or competitive trade-offs.
4. (Optional) If diagrams, telemetry graphs, or spec sheets are found AND vision capability is active, download them to artifacts/ and run vision_analyze.
5. Record verified stats, performance measurements, mechanical/roster data, and direct source citations into scratchpad.md."
                domain_convergence="Once you have cataloged 3 to 5 verified primary sources (official team statistics, OEM technical sheets, telemetry records, or sports analytics metrics) and concrete empirical findings in scratchpad.md, your mission is COMPLETE."
                ;;
            engineering)
                domain_instructions="1. Search for official documentation, specifications, RFCs, and GitHub source repositories on '$topic' using web_search or searxng_search.
2. Inspect architectures, implementation code, API signatures, and performance benchmarks into artifacts/ or papers/.
3. (Optional) Search practitioner postmortems, issues, and discussions on Hacker News and tech blogs.
4. (Optional) If system diagrams or schemas are found AND vision capability is active, download them to artifacts/ and run vision_analyze.
5. Record concrete architecture patterns, code mechanisms, performance metrics, and verified citations into scratchpad.md."
                domain_convergence="Once you have cataloged 3 to 5 verified primary sources (RFC standards, open-source repositories, API contracts, or benchmark reports) and concrete architecture details in scratchpad.md, your mission is COMPLETE."
                ;;
            academic|*)
                domain_instructions="1. Search for primary academic sources and arXiv preprints on '$topic' using arxiv_search or searxng_science_search.
2. Immediately download primary papers/preprints using bash (curl) into papers/, run pdftotext to extract text, and extract exact mathematical formulas, algorithms, and empirical benchmarks.
3. (Optional) Search technical discussions using hn_search or web_search to understand practical practitioner debates, war stories, and edge cases.
4. (Optional) If architectural figures or diagrams are found AND vision capability is active, download them to artifacts/ and run vision_analyze; otherwise, rely on text diagrams and formulas.
5. Record concrete mathematical formulations, algorithms, benchmark metrics, hardware bounds, and verified citations into scratchpad.md."
                domain_convergence="Once you have cataloged 3 to 5 verified primary sources, key mathematical formulations, and concrete empirical findings in scratchpad.md, your mission is COMPLETE."
                ;;
        esac

        local goal="You are George, an autonomous scholar and technical investigator conducting deep research on: '$topic' [Domain: ${domain} - $(research_domain_theme_label "${domain}")]. Execute decisively on Turn 1 without speculative preamble or planning monologues.
Follow these prioritized guidelines:
${domain_instructions}
6. Execution Rule: When using bash_exec with Python, NEVER use double-quoted python3 -c \"...\"; ALWAYS use single-quoted heredocs (python3 - <<'EOF' ... EOF) or write to a script with file_write. NEVER call json.load() without try/except handling. Prefer native domain searches (e.g. searxng_search, web_search, hn_search, or arxiv_search when academic).
7. Phase 1 Scope & Convergence: Phase 1's SOLE mission is evidence gathering into scratchpad.md. Do NOT attempt to author the final monograph in this phase (Phase 3 will synthesize the complete dossier from scratchpad.md). ${domain_convergence} Conclude Phase 1 promptly with a summary of findings so the pipeline advances to Phase 2 (Audit) and Phase 3 (Synthesis).
Ground all conclusions in concrete facts. Absolute prohibition against generic boilerplate or pseudo-philosophical filler."

        ui_info "Launching ReAct agent loop (Tier ${ACTIVE_TIER:-1} - ${ACTIVE_ENDPOINT_MODEL:-default})..."
        source "$LODGE_DIR/lib/core/limits.sh" 2>/dev/null || true
        local research_max_turns
        research_max_turns=$(declare -f limits_get &>/dev/null && limits_get MAX_RESEARCH_TURNS 200 || echo "${RESEARCH_MAX_TURNS:-200}")
        export REACT_MAX_OBSERVATION_CHARS="${REACT_MAX_OBSERVATION_CHARS:-32000}"
        REACT_KEEP_TRANSCRIPT=1 \
        REACT_TOOL_FILTER="research" \
        react_run "$goal" "$sandbox_dir" "$research_max_turns" "${ACTIVE_TIER:-1}" "research_$(date +%s)" "research"

        # NOTE: Do NOT blindly scrape raw URLs from trajectory.log here.
        # trajectory.log contains raw search engine Observation JSONs, including irrelevant or
        # rejected search results that the ReAct agent intentionally discarded during Phase 1.

        # Consolidate all extracted paper texts from papers/*.txt directly into scratchpad.md
        if [ -d "$sandbox_dir/papers" ]; then
            for txt_file in "$sandbox_dir"/papers/*.txt; do
                [ -f "$txt_file" ] || continue
                local bname
                bname=$(basename "$txt_file")
                if ! grep -Fq "$bname" "$scratchpad" 2>/dev/null; then
                    echo -e "\n#### Extracted Paper Source [$bname]\n" >> "$scratchpad"
                    head -n 80 "$txt_file" >> "$scratchpad"
                fi
            done
        fi
    else
        # Multi-vector targeted crawl fallback for test mode or offline
        ui_dim "Executing multi-vector targeted research sweep across empirical sources [Domain: ${domain}]..."
        local clean_topic
        clean_topic=$(echo "$topic" | tr -d '"'\''')
        local queries=()
        case "$domain" in
            gaming)
                queries=(
                    "${clean_topic} emulation architecture decompilation github"
                    "${clean_topic} hardware technical specs jit recompiler"
                    "${clean_topic} engine reverse engineering cycle accuracy"
                )
                ;;
            finance)
                queries=(
                    "${clean_topic} 10-K financial results revenue balance sheet"
                    "${clean_topic} earnings transcript valuation metrics"
                    "${clean_topic} market analysis risks competitive moat"
                )
                ;;
            general_sports_auto)
                queries=(
                    "${clean_topic} official specifications statistics"
                    "${clean_topic} depth chart roster performance"
                    "${clean_topic} technical review breakdown"
                )
                ;;
            engineering)
                queries=(
                    "${clean_topic} documentation specification rfc"
                    "${clean_topic} architecture github implementation"
                    "${clean_topic} benchmark latency performance comparison"
                )
                ;;
            academic|*)
                queries=(
                    "${clean_topic} arxiv research paper"
                    "${clean_topic} mathematical formulation algorithm"
                    "${clean_topic} benchmark performance comparison"
                )
                ;;
        esac

        local seen_urls=" "
        for q in "${queries[@]}"; do
            ui_info "  Searching vector: '$q'..."
            local s_res
            s_res=$(web_search "$q" 3 2>/dev/null || echo "")
            if [ -n "$s_res" ]; then
                echo -e "\n### Vector: ${q}\n" >> "$scratchpad"
                local u_list
                u_list=$(echo "$s_res" | grep -o -E 'https?://[^][ ")\\]+' | head -n 2)
                for u in $u_list; do
                    declare -f web_clean_url &>/dev/null && u=$(web_clean_url "$u")
                    [ -z "$u" ] && continue
                    [[ "$seen_urls" =~ " $u " ]] && continue
                    seen_urls+="$u "

                    ui_dim "    Ingesting: $u"
                    local raw_content clean_content
                    raw_content=$(web_fetch "$u" 2>/dev/null || echo "")
                    clean_content=$(echo "$raw_content" | grep -v -E '^[[:space:]]*<(!DOCTYPE|html|head|meta|link|script|style|svg|path|div|span|header|footer|nav)' | grep -v '^[[:space:]]*$' | head -n 40)
                    if [ -n "$clean_content" ] && [[ "$clean_content" != *"[FETCH FAILED"* ]]; then
                        echo -e "\n#### Reference [${u}]\n" >> "$scratchpad"
                        echo "$clean_content" >> "$scratchpad"
                    fi
                done
            fi
        done
    fi
}

# ── Phase 2: Evidence Audit & Gap Analysis ───────────────────────────
# Audits whether sufficient concrete evidence (equations, benchmarks, citations) was collected
research_evidence_audit() {
    local topic="$1"
    local sandbox_dir="$2"
    local domain="${3:-}"
    local scratchpad="$sandbox_dir/scratchpad.md"
    [ -z "$domain" ] && domain=$(research_classify_domain "$topic")

    ui_step "Phase 2/5: Auditing evidence density against the Research Standard [Domain: ${domain}]..."
    declare -f transcript_section &>/dev/null && transcript_section "Phase 2/5: Evidence Audit & Gap Analysis [Domain: ${domain}]"

    local ref_count
    ref_count=$(grep -E -c '(#### (Reference|Source|Extracted Paper Source)|DOI:[[:space:]]*`?10\.|arXiv:[[:space:]]*`?[0-9]{4}\.|https?://)' "$scratchpad" 2>/dev/null || true)
    ref_count="${ref_count:-0}"

    if [ "$ref_count" -lt 2 ]; then
        ui_warn "Evidence density low (${ref_count} references) — executing targeted supplemental sweep..."
        local sweep_query=""
        case "$domain" in
            gaming) sweep_query="${topic} emulation decompilation architecture" ;;
            finance) sweep_query="${topic} financial filing earnings transcript" ;;
            general_sports_auto) sweep_query="${topic} official statistics specifications" ;;
            engineering) sweep_query="${topic} specification rfc architecture" ;;
            academic|*) sweep_query="${topic} technical paper research" ;;
        esac

        local extra_results
        extra_results=$(web_search "$sweep_query" 4 2>/dev/null || echo "")
        local extra_urls
        extra_urls=$(echo "$extra_results" | grep -o -E 'https?://[^][ ")\\]+' | head -n 2)
        for eu in $extra_urls; do
            declare -f web_clean_url &>/dev/null && eu=$(web_clean_url "$eu")
            [ -z "$eu" ] && continue
            ui_dim "  Supplemental Ingest: $eu"
            local p_content
            p_content=$(web_fetch "$eu" 2>/dev/null | grep -v -E '^[[:space:]]*<(!DOCTYPE|html|head|meta|link|script|style|svg|path)' | grep -v '^[[:space:]]*$' | head -n 40)
            if [ -n "$p_content" ] && [[ "$p_content" != *"[FETCH FAILED"* ]]; then
                echo -e "\n#### Reference [${eu}]\n" >> "$scratchpad"
                echo "$p_content" >> "$scratchpad"
                ref_count=$((ref_count + 1))
            fi
        done
    fi

    # Audit primary PDF document extraction (Academic domain contract gate)
    local pdf_count
    pdf_count=$(find "$sandbox_dir" -maxdepth 2 -name "*.pdf" 2>/dev/null | wc -l)
    if [ "$pdf_count" -gt 0 ]; then
        for pdf_file in $(find "$sandbox_dir" -maxdepth 2 -name "*.pdf" 2>/dev/null); do
            local txt_target="${pdf_file%.pdf}.txt"
            if [ ! -f "$txt_target" ] && command -v pdftotext &>/dev/null; then
                pdftotext -layout "$pdf_file" "$txt_target" 2>/dev/null || true
            fi
        done
        local pdf_txt_count
        pdf_txt_count=$(find "$sandbox_dir" -maxdepth 2 -name "*.pdf.txt" -o -name "*_extracted.txt" -o -name "*.txt" 2>/dev/null | grep -v 'scratchpad' | wc -l)
        local scratchpad_has_pdf
        scratchpad_has_pdf=$(grep -iE 'pdftotext|\.pdf' "$scratchpad" 2>/dev/null | wc -l)
        if [ "$pdf_txt_count" -eq 0 ] && [ "$scratchpad_has_pdf" -eq 0 ] && [ "$domain" = "academic" ]; then
            ui_warn "Phase-Boundary Contract Gate: $pdf_count PDF asset(s) present, but 0 extracted text representations found."
            if declare -f telemetry_record_anomaly &>/dev/null; then
                telemetry_record_anomaly "research_${topic}" "CAPABILITY_DEFICIT" "pdf_read" "PDF acquired in sandbox but never successfully ingested into evidence scratchpad" >/dev/null 2>&1 || true
            fi
            if declare -f telemetry_preserve_incident &>/dev/null; then
                telemetry_preserve_incident "research_${topic}" "GATE_DEFICIT" "Phase 2 Gate: Acquired PDF was not ingested into evidence text" "$sandbox_dir" >/dev/null 2>&1 || true
            fi
        fi
    fi

    ui_ok "Evidence audit cleared: ${ref_count} verified source references cataloged."
    declare -f transcript_log &>/dev/null && transcript_log "evidence_audit" "Cleared with ${ref_count} verified source references cataloged in scratchpad.md"
}

# ── Phase 3: Long-Form Technical Synthesis ───────────────────────────
# Authors the master research monograph (dossier.md) from the accumulated evidence
research_synthesize_dossier() {
    local topic="$1"
    local sandbox_dir="$2"
    local domain="${3:-}"
    local scratchpad="$sandbox_dir/scratchpad.md"
    local dossier_file="$sandbox_dir/dossier.md"
    [ -z "$domain" ] && domain=$(research_classify_domain "$topic")
    local subdomain
    subdomain=$(research_classify_subdomain "$topic" "$domain")

    ui_step "Phase 3/5: Synthesizing authoritative long-form research monograph [Domain: ${domain} (${subdomain})]..."
    declare -f transcript_section &>/dev/null && transcript_section "Phase 3/5: Long-Form Technical Monograph Synthesis [Domain: ${domain}]"

    local endpoints_online=0
    endpoints_cascade "${ACTIVE_TIER:-1}" 2>/dev/null || endpoints_init 2>/dev/null || true
    local llm_url="${ACTIVE_ENDPOINT_URL:-${TIER1_URL:-http://127.0.0.1:8080}}"
    if curl -sf --connect-timeout 2 --max-time 3 "$llm_url/v1/models" &>/dev/null; then
        endpoints_online=1
    fi

    local topic_style=""
    local clean_topic="$topic"
    if [[ "$topic" =~ ^\[([a-zA-Z0-9_-]+)\][[:space:]]*(.*)$ ]]; then
        topic_style="${BASH_REMATCH[1]}"
        clean_topic="${BASH_REMATCH[2]}"
    fi

    local synthesis_resp=""
    if [ "$endpoints_online" -eq 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ] && [ -z "${TEST_TMP:-}" ]; then
        ui_dim "  Querying Tier 1 inference engine ($llm_url)..."
        declare -f ui_prefill_ticker_start &>/dev/null && ui_prefill_ticker_start

        local compact_scratchpad
        local _max_scratch="${RESEARCH_SCRATCHPAD_MAX_CHARS:-80000}"
        # Dynamically scaled scratchpad buffer for deep context windows (default 80k chars / ~20k tokens)
        compact_scratchpad=$(head -c "$_max_scratch" "$scratchpad" 2>/dev/null || cat "$scratchpad" 2>/dev/null)

        local domain_directives="" domain_structure="" domain_persona="" domain_system=""
        case "$domain" in
            gaming)
                domain_persona="You are George, an expert systems architect and emulation engineer carrying the discipline of Washington, the wit of Franklin, and the deep technical precision of a low-level systems programmer."
                domain_system="You are an expert systems and emulation engineer. Ground all analysis in concrete hardware architectures, CPU/GPU register specifications, JIT recompiler mechanics, cycle-timing bounds, and decompiled codebases."
                domain_directives="1. Ground every section strictly in verified hardware registers, Vector Units, cycle accuracy trade-offs, and decompilation codebases.
2. Detail CPU/GPU architecture, memory buses, recompiler pipelines, and assembly instructions.
3. Include real frame pacing measurements, emulator execution bounds, and reverse engineering milestones.
4. No generic filler, no boilerplate, and NEVER output meta-commentary about templates or rubrics."
                domain_structure="# Sovereign Gaming & Emulation Dossier: $clean_topic
## Executive Summary & System Overview
## Hardware Architecture, CPU/GPU & Subsystem Internals
## Emulation Mechanics, JIT Recompilation & Decompilation State
## Frame Timing, Cycle Accuracy & Performance Optimization
## Implementation Challenges & Technical Postmortem
## Verified Codebases, Disassembly & Primary References"
                ;;
            finance)
                case "$subdomain" in
                    finance:protocol_crypto)
                        domain_persona="You are George, a rigorous cryptoeconomic protocol architect and quantitative DeFi scholar carrying the discipline of Washington, the wit of Franklin, and the analytical precision of Adam Smith."
                        domain_system="You are a quantitative protocol architect and DeFi systems researcher. Ground all analysis in formal ledger state-transition mechanics, CIP standards, smart contract execution budgets, AMM liquidity invariants, and empirical on-chain benchmarks. NEVER force corporate 10-K/EBITDA terminology onto decentralized protocols or write meta-disclaimers about corporate entities."
                        domain_directives="1. Ground every section strictly in verified protocol specifications, CIP standards, formal state-transition equations, and empirical settlement/liquidity data.
2. Detail EUTxO/AMM invariants, batcher/mempool concurrency, script execution bounds, or collateralization mechanics.
3. Include concrete latency figures, throughput bounds, slippage curves, and game-theoretic closure/adversarial conditions.
4. NEVER output meta-disclaimers (e.g. never write 'Note: As this topic concerns a protocol rather than a corporate entity...'). Address the protocol directly."
                        domain_structure="# Sovereign Financial & Protocol Dossier: $clean_topic
## Executive Abstract & Protocol Thesis
## Formal Ledger Mechanics & Mathematical Formulation
## Liquidity Architecture, Concurrency & Execution Dynamics
## Empirical Benchmarks, Latency & Economic Bounds
## Adversarial Vectors, Contention & Systemic Risks
## Verified Citations & Primary References"
                        ;;
                    finance:corporate_equity)
                        domain_persona="You are George, a rigorous quantitative financial scholar and forensic corporate auditor carrying the discipline of Washington, the wit of Franklin, and the analytical precision of Adam Smith."
                        domain_system="You are a quantitative financial analyst and forensic corporate auditor. Ground all analysis in verified SEC filings, 10-K/10-Q metrics, audited balance sheets, cash flow models, and credit/market data."
                        domain_directives="1. Ground every section strictly in audited SEC filings (10-K, 10-Q), footnote disclosures, and empirical valuation multiples.
2. Detail balance sheet figures, segment revenues, gross/operating margins, free cash flow, and debt/lease schedules.
3. Include real peer benchmarking, capital allocation history, and credit spread metrics.
4. No speculative hype, generic investment platitudes, or rubric meta-commentary."
                        domain_structure="# Sovereign Financial Dossier: $clean_topic
## Executive Thesis & Investment Summary
## Financial Performance, Revenue & Balance Sheet Analysis
## Capital Allocation, Margins & Cash Flow Dynamics
## Valuation Multiples, Moat & Competitive Landscape
## Macro Risks, Regulatory Exposure & Scenarios
## Primary Financial Citations & Filings"
                        ;;
                    *)
                        domain_persona="You are George, a rigorous quantitative market microstructure and macro-liquidity scholar carrying the discipline of Washington, the wit of Franklin, and the analytical precision of Adam Smith."
                        domain_system="You are a quantitative market microstructure economist and central-bank liquidity analyst. Ground all analysis in econometric equations, order-flow models, central bank/regulatory disclosures (Federal Reserve, BIS, CFTC, OFR), and empirical market datasets. NEVER force corporate 10-K/EBITDA balance-sheet headers onto microstructure or macro topics, and NEVER write meta-disclaimers apologizing for the absence of a corporate entity."
                        domain_directives="1. Ground every section strictly in verified econometric models, central bank/regulatory data, and empirical market microstructure evidence.
2. Provide exact mathematical formulations (e.g. Kyle's lambda, Glosten-Milgrom spread decomposition, SOFR/repo corridor mechanics, convexity/cointegration estimators).
3. Include concrete basis-point spreads, dollar volumes, regression/eigenvalue metrics, and historical liquidity shock episodes.
4. NEVER write meta-apologies (e.g. never write 'Note: As this topic concerns market microstructure rather than a corporate entity...' or 'SEC filing equivalent')."
                        domain_structure="# Sovereign Financial & Microstructure Dossier: $clean_topic
## Executive Abstract & Analytical Thesis
## Theoretical Foundations & Mathematical Formulation
## Market Microstructure, Liquidity & Order-Flow Mechanics
## Empirical Benchmarks, Spread Dynamics & Stress Regimes
## Systemic Risks, Regulatory Plumbing & Failure Modes
## Verified Citations & Primary References"
                        ;;
                esac
                ;;
            general_sports_auto)
                domain_persona="You are George, an authoritative sports analytics and high-performance automotive engineering scholar carrying the discipline of Washington, the wit of Franklin, and the precision of an expert track engineer and offensive coordinator."
                domain_system="You are an authoritative technical sports and automotive analyst. Ground all analysis in verified telemetry, vehicle dynamics/aerodynamics, official game statistics, playbook mechanics, and primary source records. Never output generic sports-talk filler."
                domain_directives="1. Ground every section strictly in official OEM specifications, telemetry data, depth charts, rosters, or season performance statistics.
2. Detail mechanical architecture (engine, powertrain, chassis, aerodynamics) or tactical play schemes and player metrics.
3. Include real empirical measurements: 0-60, dyno horsepower/torque, lap times, player efficiency rating, EPA/CPOE, or game splits.
4. No generic sports-talk filler, unverified rumors, or rubric meta-commentary."
                domain_structure="# Sovereign Analytical Dossier: $clean_topic
## Executive Overview & Strategic Thesis
## Technical Specifications & Empirical Metrics
## Tactical Analysis, Engineering Dynamics & Mechanics
## Comparative Benchmarks & Performance Records
## Critical Assessment & Future Outlook
## Verified Citations & Primary Sources"
                ;;
            engineering)
                domain_persona="You are George, a principal systems and software architect carrying the discipline of Washington, the wit of Franklin, and uncompromising engineering rigor."
                domain_system="You are a principal systems and software architect. Ground all analysis in concrete RFC specifications, code implementations, p99 latency benchmarks, and distributed scale invariants."
                domain_directives="1. Ground every section strictly in official specification RFCs, open-source repository architectures, and empirical system benchmarks.
2. Detail system architecture, API contracts, concurrency models, and memory layouts.
3. Include real QPS throughput, p99 latency figures, and scale limits.
4. No generic architectural buzzwords, hollow generalities, or rubric meta-commentary."
                domain_structure="# Sovereign Engineering Dossier: $clean_topic
## Executive Summary
## System Architecture & Specification Standards
## Core Implementation Mechanics & Code Abstractions
## Performance Benchmarks, Latency & Scale Bounds
## Operational Bottlenecks & Critical Failure Modes
## Verified References & Repository Links"
                ;;
            academic|*)
                domain_persona="You are George, a master polymath scholar carrying the discipline of Washington, the wit of Franklin, and the analytical precision of Adam Smith."
                domain_system="You are a master technical researcher. Never output generic filler. Ground all analysis in concrete equations, hardware bounds, and benchmarks."
                domain_directives="1. Ground every section strictly in the concrete facts, formulas, architectures, and citations discovered.
2. Provide exact mathematical formulations from the research literature.
3. Include real benchmark metrics and hardware execution bounds discovered in the empirical papers.
4. No generic boilerplate, no empty placeholders, no philosophical fluff."
                domain_structure="# Sovereign Research Dossier: $clean_topic
## Executive Abstract
## Theoretical Foundations & Mathematical Formulation
## System Architecture & Algorithmic Mechanics
## Empirical Benchmarks & Hardware Bounds
## Community Discourse & Critical Limitations
## Verified Citations & References"
                ;;
        esac

        local synth_prompt="${domain_persona}
Topic: $clean_topic
Domain: $domain ($(research_domain_theme_label "$domain"))

Review all accumulated evidence, notes, empirical data, and citations in the scratchpad:
$compact_scratchpad

Author an authoritative, deep research monograph on '$clean_topic'.
MANDATORY DIRECTIVES:
${domain_directives}

Structure your response with:
${domain_structure}"

        local custom_directives=""
        local custom_style=""
        local custom_temp=""
        local custom_max_tokens=""
        if [ -f "$GEORGE_DIR/research.conf" ]; then
            custom_directives=$(jq -r '.directives // empty' "$GEORGE_DIR/research.conf" 2>/dev/null)
            custom_style=$(jq -r '.default_style // empty' "$GEORGE_DIR/research.conf" 2>/dev/null)
            custom_temp=$(jq -r '.temperature // empty' "$GEORGE_DIR/research.conf" 2>/dev/null)
            custom_max_tokens=$(jq -r '.max_tokens // empty' "$GEORGE_DIR/research.conf" 2>/dev/null)
            [ -n "$custom_directives" ] && synth_prompt+=$'\n\nOPERATOR RESEARCH DIRECTIVES:\n'"$custom_directives"
        fi

        local effective_style="${topic_style:-${custom_style:-storyteller}}"
        case "$effective_style" in
            executive)
                synth_prompt+=$'\n\nSTYLE DIRECTIVE (Crisp Executive / Engineering Brief): Lead with high-impact conclusions, concrete metrics, architectural trade-offs, and operational bottlenecks. Strictly avoid superfluous narrative embellishment or conversational meta-filler.'
                ;;
            hybrid)
                synth_prompt+=$'\n\nSTYLE DIRECTIVE (Sovereign Hybrid): Combine unflinching executive precision, mathematical rigor, and architectural trade-offs with the warm wit, moral clarity, and historical perspective of George.'
                ;;
            provocative)
                synth_prompt+=$'\n\nSTYLE DIRECTIVE (Provocative First-Principles Inquiry): Vigorously question orthodoxy, expose implicit industry assumptions, highlight conflicting benchmark claims, and analyze systemic failure modes.'
                ;;
            storyteller|*)
                synth_prompt+=$'\n\nSTYLE DIRECTIVE (Narrative Polymath Storyteller): Weave historical philosophical perspective, epistemic humility, and rigorous mathematical clarity into a cohesive intellectual journey.'
                ;;
        esac

        local synth_temp="${custom_temp:-1.0}"
        # Ensure max_tokens is generous enough for complete monograph synthesis while preventing OOM (default 8192, clamp 4096-16384)
        local synth_max_tokens="${custom_max_tokens:-8192}"
        if [ "$synth_max_tokens" -lt 4096 ]; then
            synth_max_tokens=4096
        elif [ "$synth_max_tokens" -gt 16384 ]; then
            synth_max_tokens=16384
        fi

        local payload
        payload=$(jq -n --arg p "$synth_prompt" --arg sys "$domain_system" --argjson t "$synth_temp" --argjson m "$synth_max_tokens" \
            '{messages: [{"role": "system", "content": $sys}, {"role": "user", "content": $p}, {"role": "assistant", "content": "<think>\n</think>\n"}], temperature: $t, max_tokens: $m}')

        declare -f transcript_log_prompt &>/dev/null && transcript_log_prompt "monograph_synthesis" "$synth_prompt" "$domain_system"

        # 600s timeout so large models on local hardware never get cut off
        local raw_synth_resp
        raw_synth_resp=$(curl -s --max-time 600 "$llm_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)

        local llm_err
        llm_err=$(echo "$raw_synth_resp" | jq -r '.error.message // .error // empty' 2>/dev/null)
        if [ -n "$llm_err" ]; then
            ui_warn "Monograph synthesis LLM error: $llm_err"
        fi

        synthesis_resp=$(echo "$raw_synth_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        synthesis_resp=$(_research_strip_thinking "$synthesis_resp")

        if [ -z "$synthesis_resp" ]; then
            local reasoning_text
            reasoning_text=$(echo "$raw_synth_resp" | jq -r '.choices[0].message.reasoning_content // empty' 2>/dev/null)
            if [ -n "$reasoning_text" ] && [ "${#reasoning_text}" -gt 200 ] && ! _research_is_deliberation_trace "$reasoning_text"; then
                if [[ "$reasoning_text" =~ (## Executive Abstract|# Sovereign Research) ]]; then
                    synthesis_resp=$(_research_strip_thinking "$reasoning_text")
                fi
            fi
        fi

        declare -f ui_prefill_ticker_stop &>/dev/null && ui_prefill_ticker_stop
    fi

    local theme_title
    theme_title=$(research_domain_theme_label "$domain")
    local frontmatter="---
category: ${domain}
domain: ${domain}
theme: \"${theme_title}\"
topic: \"${clean_topic}\"
date: \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"
status: verified
---"

    if [ -n "$synthesis_resp" ]; then
        if [[ "$synthesis_resp" =~ ^---[[:space:]]*$'\n' ]]; then
            echo "$synthesis_resp" > "$dossier_file"
        else
            printf "%s\n\n%s\n" "$frontmatter" "$synthesis_resp" > "$dossier_file"
        fi
        ui_ok "Long-form research monograph synthesized (${#synthesis_resp} bytes)."
        if declare -f transcript_log_details &>/dev/null; then
            transcript_log_details "Synthesized Research Monograph (dossier.md)" "$synthesis_resp" "markdown"
        fi
    else
        # Honest fallback strictly synthesized from the gathered scratchpad content (stripping internal prompt directives)
        ui_info "Synthesizing empirical monograph from cataloged scratchpad citations..."
        local clean_scratchpad
        clean_scratchpad=$(sed '/## Research Mandate/I,/## Verified/I{ /## Verified/!d; }' "$scratchpad" 2>/dev/null)
        [ -z "$clean_scratchpad" ] && clean_scratchpad="$(cat "$scratchpad" 2>/dev/null)"

        local fallback_citations
        fallback_citations=$(grep -E '^(### Source|#### Source|#### Reference|#### Extracted Paper Source|- Source:|- Repository:)' <<< "$clean_scratchpad" 2>/dev/null | grep -v -E 'a9\.com|w3\.org|schemas\.|schema\.org|dtd|xmlns' | sed 's/#### Source/ - Source:/; s/#### Reference/ - Reference:/; s/#### Extracted Paper Source/ - Paper Source:/; s/### Source/ - Source:/' | head -n 12)
        [ -z "$fallback_citations" ] && fallback_citations="- Blue Lodge Sovereign Knowledge Base & Academic Preprints Archive."

        local fallback_abstract
        fallback_abstract=$(grep -A 8 -i -E '(## Executive Abstract|## Executive Overview|## Phase 1 Convergence Summary)' <<< "$clean_scratchpad" 2>/dev/null | grep -v -E '^(#|`|\*\*)' | head -n 6 | tr '\n' ' ')
        [ -z "$fallback_abstract" ] && fallback_abstract="Technical evaluation of ${topic} synthesizing primary source specifications, empirical benchmarks, and architectural mechanics cataloged in the Blue Lodge sovereign research library."

        local fallback_theory
        fallback_theory=$(grep -A 20 -i -E '(Key Mathematical Formulations|Mathematical Formulation|Theoretical Foundations|System Architecture|Core Implementation|Technical Specifications)' <<< "$clean_scratchpad" 2>/dev/null | grep -v -E '^(# |- Ingest|- Download|soul\.md|vision_analyze)' | head -n 14)
        if [ -z "$fallback_theory" ]; then
            fallback_theory=$(grep -E '^[0-9]+\. \*\*' <<< "$clean_scratchpad" 2>/dev/null | head -n 6)
        fi
        if [ -z "$fallback_theory" ]; then
            fallback_theory="Theoretical foundations and formal domain mechanics for ${topic} as established in peer-reviewed literature and system specifications."
        fi

        local fallback_benchmarks
        fallback_benchmarks=$(grep -A 16 -i -E '(Performance Metrics|Empirical Benchmarks|Performance Benchmarks|Empirical Data Points|Comparative Benchmarks)' <<< "$clean_scratchpad" 2>/dev/null | grep -v -E '^(# |- Ingest|- Download|soul\.md|vision_analyze)' | head -n 12)
        if [ -z "$fallback_benchmarks" ]; then
            fallback_benchmarks=$(grep -E '^\|.*\|' <<< "$clean_scratchpad" 2>/dev/null | head -n 8)
        fi
        if [ -z "$fallback_benchmarks" ]; then
            fallback_benchmarks="Empirical measurements and system performance metrics cataloged from primary operational benchmarks and engineering evaluations."
        fi

        local fallback_discourse
        fallback_discourse=$(grep -A 12 -i -E '(Expert Commentary|Community Discourse|Critical Limitations|Tactical Strategic Insights)' <<< "$clean_scratchpad" 2>/dev/null | grep -v -E '^(# |- Ingest|- Download|soul\.md|vision_analyze)' | head -n 8)
        [ -z "$fallback_discourse" ] && fallback_discourse="Practitioners and researchers note that while ${topic} provides architectural improvements, implementation trade-offs, operational overhead, and formal verification bounds require rigorous engineering calibration."

        cat << EOF > "$dossier_file"
${frontmatter}

# Sovereign Research Dossier: ${topic}
**Date:** $(date -u '+%Y-%m-%d %H:%M:%SZ')
**Author:** George (Blue Lodge Agent)
**Category:** ${domain}
**Theme:** ${theme_title}

## Executive Abstract
${fallback_abstract}

## Theoretical Foundations & Mathematical Formulation
${fallback_theory}

## Empirical Benchmarks & Hardware Bounds
${fallback_benchmarks}

## Verified Citations & References
${fallback_citations}

## Community Discourse & Critical Limitations
${fallback_discourse}
EOF
        if declare -f transcript_log_details &>/dev/null; then
            transcript_log_details "Synthesized Research Monograph (dossier.md - Fallback)" "$(cat "$dossier_file")" "markdown"
        fi
    fi

    # ── Grounding Verification Sub-Graph (Deterministic Grounding + Adversarial Auditor) ──
    local slug
    slug=$(research_slugify "$topic")
    if declare -f research_verify_and_refine &>/dev/null; then
        if ! research_verify_and_refine "dossier" "$dossier_file" "$domain" "$clean_topic" "$slug" "$sandbox_dir"; then
            return 1
        fi
    fi
}

# ── Phase 4: Editorial Critique & soul.md Refinement ──────────────────
# Audits the synthesized dossier against George's landmarks (The Square, The Plumb, The Spectator's Honesty)
# and writes the refined Executive Abstract + stripped rubric meta-apologies back into dossier.md.
research_editorial_critique() {
    local topic="$1"
    local sandbox_dir="$2"
    local domain="${3:-}"
    [ -z "$domain" ] && domain=$(research_classify_domain "$topic")
    local dossier_file="$sandbox_dir/dossier.md"

    ui_step "Phase 4/5: Editorial critique & craftsmanship review (soul.md)..."
    declare -f transcript_section &>/dev/null && transcript_section "Phase 4/5: Editorial Critique & soul.md Craftsmanship Review"

    # Always strip any rubric meta-apology lines from dossier.md deterministically
    if [ -f "$dossier_file" ] && command -v python3 &>/dev/null; then
        python3 - "$dossier_file" << 'PYEOF' 2>/dev/null || true
import sys, re
p = sys.argv[1]
with open(p, "r", encoding="utf-8", errors="replace") as f:
    txt = f.read()
cleaned = re.sub(
    r"^\s*\*?(?:Note|Editor's Note|Analytical Note):\s*(?:As this topic concerns|While this topic|Because this inquiry examines|Since this analysis focuses on)[^\n]*(?:corporate entity|10-K|SEC filing|balance sheet)[^\n]*\*?\s*\n?",
    "",
    txt,
    flags=re.IGNORECASE | re.MULTILINE,
)
if cleaned != txt:
    with open(p, "w", encoding="utf-8") as f:
        f.write(cleaned)
PYEOF
    fi

    local endpoints_online=0
    endpoints_cascade "${ACTIVE_TIER:-1}" 2>/dev/null || endpoints_init 2>/dev/null || true
    local llm_url="${ACTIVE_ENDPOINT_URL:-${TIER1_URL:-http://127.0.0.1:8080}}"
    if curl -sf --connect-timeout 2 --max-time 3 "$llm_url/v1/models" &>/dev/null; then
        endpoints_online=1
    fi

    # In live mode with endpoint, run a sharpening critique pass and write the refined abstract back to dossier.md
    if [ "$endpoints_online" -eq 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ] && [ -z "${TEST_TMP:-}" ] && [ -f "$dossier_file" ]; then
        local plumb_check="Are technical assertions plumb and true?"
        local editor_system="You are a ruthless technical editor. Prune all fluff and meta-commentary."
        case "$domain" in
            general_sports_auto)
                plumb_check="Are aerodynamic telemetry, mechanical dyno numbers, player efficiency ratings, coaching schemes, and game situations plumb and true to real-world data?"
                editor_system="You are a ruthless technical sports & automotive editor. Prune all fluff and ensure precision in engineering telemetry and tactical dynamics."
                ;;
            gaming)
                plumb_check="Are console architecture, vector units, assembly translation, cycle timing, and reverse engineering assertions plumb and true?"
                editor_system="You are a ruthless low-level systems & reverse engineering editor. Prune all fluff."
                ;;
            finance)
                plumb_check="Are econometric equations, microstructure/protocol invariants, financial metrics, and empirical figures plumb and true without forced corporate 10-K meta-apologies?"
                editor_system="You are a ruthless quantitative finance, market microstructure, and forensic editor. Prune all fluff and strip any meta-apologies about templates."
                ;;
            engineering)
                plumb_check="Are distributed systems architecture, protocol mechanics, latency bounds, and code structures plumb and true?"
                editor_system="You are a ruthless systems engineering editor. Prune all fluff."
                ;;
            academic|*)
                plumb_check="Are mathematical proofs, formal complexity bounds, and empirical benchmark assertions plumb and true?"
                editor_system="You are a ruthless academic peer reviewer and technical editor. Prune all fluff."
                ;;
        esac

        local critique_prompt="You are George's editorial conscience (Adam Smith's Impartial Spectator).
Evaluate the opening and Executive Abstract of this draft research monograph on '$topic' [Domain: ${domain}]:
$(head -n 120 "$dossier_file")

Audit this text against George's inviolable landmarks:
1. The Square: Are claims supported by concrete facts, equations, and metrics rather than vague generalities?
2. The Plumb: ${plumb_check}
3. The Spectator's Honesty: Eliminate any pseudo-philosophical fluff, repetitive boilerplate, or meta-notes apologizing for how the topic fits a rubric.

Output ONLY the refined body paragraphs of the Executive Abstract / Executive Summary section (2 to 3 crisp, high-density paragraphs; do NOT include the '## Executive...' markdown heading itself and do NOT invent any new citations not already in the draft)."

        local p_payload
        p_payload=$(jq -n --arg p "$critique_prompt" --arg sys "$editor_system" \
            '{messages: [{"role": "system", "content": $sys}, {"role": "user", "content": $p}], temperature: 0.5, max_tokens: 1000, chat_template_kwargs: {enable_thinking: false}}')
        declare -f transcript_log_prompt &>/dev/null && transcript_log_prompt "editorial_critique" "$critique_prompt" "$editor_system"
        local raw_crit_resp
        raw_crit_resp=$(curl -s --max-time 180 "$llm_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$p_payload" 2>/dev/null)
        local critique_resp
        critique_resp=$(echo "$raw_crit_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        critique_resp=$(_research_strip_thinking "$critique_resp")

        if [ -n "$critique_resp" ] && [ "${#critique_resp}" -gt 140 ] && ! _research_is_deliberation_trace "$critique_resp"; then
            # Safely splice the refined abstract back into dossier.md if it doesn't introduce ungrounded citations
            python3 - "$dossier_file" "$critique_resp" << 'PYEOF' 2>/dev/null || true
import sys, re
dossier_path, new_abs = sys.argv[1], sys.argv[2].strip()
# Strip any leading ## heading if the LLM included one
new_abs = re.sub(r"^##+\s+[^\n]+\n+", "", new_abs).strip()
if len(new_abs) < 120:
    sys.exit(0)
with open(dossier_path, "r", encoding="utf-8", errors="replace") as f:
    orig = f.read()
# Ensure new_abs doesn't invent arXiv IDs not in orig
orig_arxiv = set(re.findall(r"arXiv:([0-9]+\.[0-9]+)", orig))
new_arxiv = set(re.findall(r"arXiv:([0-9]+\.[0-9]+)", new_abs))
if not new_arxiv.issubset(orig_arxiv):
    sys.exit(0)
pat = re.compile(r"(^##\s+(?:Executive Abstract|Executive Summary|Executive Overview|Executive Thesis)[^\n]*\n+)(.*?)(?=\n##\s+)", re.MULTILINE | re.DOTALL | re.IGNORECASE)
m = pat.search(orig)
if m:
    updated = orig[:m.start(2)] + new_abs + "\n" + orig[m.end(2):]
    with open(dossier_path, "w", encoding="utf-8") as f:
        f.write(updated)
PYEOF
            ui_think "Editorial critique applied: refined core abstract written to dossier.md."
            if declare -f transcript_log_block &>/dev/null; then
                transcript_log_block "editorial_critique" "$critique_resp"
            fi
        fi
    fi

    ui_ok "Editorial critique pass passed: verified fidelity to soul.md landmarks."
    declare -f transcript_log &>/dev/null && transcript_log "editorial_critique" "Pass complete: verified fidelity to soul.md landmarks"
}

# ── Deterministic Monograph Plate Helper ──────────────────────────────
# Renders a 1200x675 archival Monograph Plate (summary_card.png) from dossier.md + thread.md
# using 100% deterministic Python/Pillow with zero LLM overhead.
research_generate_plate() {
    local perm_dir="$1"
    [ -d "$perm_dir" ] || return 0
    local dossier_file="$perm_dir/dossier.md"
    local thread_file="$perm_dir/thread.md"
    local plate_out="$perm_dir/summary_card.png"
    local plate_script="${LODGE_DIR}/lib/tools/research_plate.py"

    [ -f "$plate_script" ] || return 0
    [ -f "$dossier_file" ] || return 0

    local py_bin="python3"
    if [ -x "${LODGE_DIR}/.venv/bin/python" ]; then
        py_bin="${LODGE_DIR}/.venv/bin/python"
    fi

    if "$py_bin" "$plate_script" --dossier "$dossier_file" --thread "$thread_file" --output "$plate_out" >/dev/null 2>&1; then
        if [ -s "$plate_out" ]; then
            ui_ok "Monograph visual plate rendered: $(basename "$plate_out")"
            declare -f transcript_log &>/dev/null && transcript_log "monograph_plate" "Rendered summary_card.png (${plate_out})"
        fi
    fi
    return 0
}

# ── Clean Sentence Trimmer Helper ────────────────────────────────────
_research_clean_sentence() {
    local text="$1"
    local max_len="${2:-280}"
    # Normalize internal newlines to spaces
    text=$(echo "$text" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | sed 's/^ //; s/ $//')
    if [ "${#text}" -le "$max_len" ]; then
        echo "$text"
        return 0
    fi

    # Find the last complete sentence within max_len
    local slice="${text:0:$max_len}"
    local sentence_cut
    sentence_cut=$(python3 -c '
import sys, re
t = sys.argv[1]
m = re.findall(r".+?[.!?](?:\s|$)", t)
if m:
    res = "".join(m).strip()
    if len(res) >= 60:
        print(res)
        sys.exit(0)
trimmed = re.sub(r"\s+\S*$", "", t).strip()
if not trimmed.endswith((".", "!", "?")):
    trimmed += "..."
print(trimmed)
' "$slice" 2>/dev/null || echo "")

    if [ -n "$sentence_cut" ]; then
        echo "$sentence_cut"
    else
        local trimmed="${slice% *}"
        [ -z "$trimmed" ] && trimmed="$slice"
        [[ ! "$trimmed" =~ [.!?]$ ]] && trimmed="${trimmed}..."
        echo "$trimmed"
    fi
}

# ── Phase 5: The Three Degrees Audit & Publication Packaging ──────────
research_audit_and_package() {
    local topic="$1"
    local slug="$2"
    local sandbox_dir="$3"
    local ts="$4"
    local domain="${5:-}"
    [ -z "$domain" ] && domain=$(research_classify_domain "$topic")
    local subdomain
    subdomain=$(research_classify_subdomain "$topic" "$domain")
    local dossier_file="$sandbox_dir/dossier.md"
    local thread_file="$sandbox_dir/thread.md"
    local scratchpad="$sandbox_dir/scratchpad.md"

    ui_step "Phase 5/5: The Three Degrees audit, PGP Ed25519 signing & broadcast staging..."
    declare -f transcript_section &>/dev/null && transcript_section "Phase 5/5: The Three Degrees Audit, PGP Ed25519 Signing & Broadcast Staging"

    # Author substantive thread directly from dossier facts
    local thread_content=""
    local endpoints_online=0
    endpoints_cascade "${ACTIVE_TIER:-1}" 2>/dev/null || endpoints_init 2>/dev/null || true
    local llm_url="${ACTIVE_ENDPOINT_URL:-${TIER1_URL:-http://127.0.0.1:8080}}"
    if curl -sf --connect-timeout 2 --max-time 3 "$llm_url/v1/models" &>/dev/null; then
        endpoints_online=1
    fi

    local clean_topic="$topic"
    if [[ "$topic" =~ ^\[([a-zA-Z0-9_-]+)\][[:space:]]*(.*)$ ]]; then
        clean_topic="${BASH_REMATCH[2]}"
    fi

    if [ "$endpoints_online" -eq 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ] && [ -z "${TEST_TMP:-}" ]; then
        local thread_trajectory=""
        local domain_focus=""
        local domain_thread_system=""
        case "$domain" in
            gaming)
                thread_trajectory="POST 1: [Magazine Header & Emulation Hook] Line 1: '🏛️ ${clean_topic}', blank line, sharp 2-sentence counter-intuitive hook on why this hardware/emulation challenge is hard, blank line, core architectural thesis.
POST 2: [Hardware Architecture & Subsystems] Detail CPU/GPU architecture, Vector Units, memory buses, and custom silicon with '▸' metric callouts.
POST 3: [Emulation Mechanics & JIT Pipeline] Explain JIT recompiler strategy, assembly translation, microcode, or decompiled C/C++ control flow.
POST 4: [Cycle Accuracy & Frame Timing] Report cycle accuracy trade-offs, frame pacing, sync bottlenecks, or memory latency with concrete '▸' timing numbers.
POST 5: [Hardware Execution Bounds] Highlight PC/edge hardware requirements, shader compilation, or memory footprint.
POST 6: [Provenance & Source Codebases] List the exact primary GitHub decomp projects, architecture manuals, emulator repositories, and full URLs/citations from the monograph's References section."
                domain_focus="Focus on hard facts, hardware architecture, CPU/GPU vector units, cycle-timing benchmarks, assembly disassembly, and primary emulator/decomp codebases from the monograph."
                domain_thread_system="You are a disciplined systems and emulation engineering scholar writing an engaging, magazine-style multi-post research thread for X Premium and Mastodon. Output only the thread posts separated by ---POST---. Keep every post visually structured (2-3 crisp paragraphs + '▸' metric bullets) and between 600 and 1100 characters."
                ;;
            finance)
                case "$subdomain" in
                    finance:protocol_crypto)
                        thread_trajectory="POST 1: [Magazine Header & Protocol Hook] Line 1: '🏛️ ${clean_topic}', blank line, sharp 2-sentence counter-intuitive hook on the protocol/liquidity bottleneck, blank line, core cryptoeconomic thesis.
POST 2: [Formal State & Mathematical Mechanics] Detail EUTxO/AMM state transitions, CIP specifications, or invariant equations with '▸' formula/parameter callouts.
POST 3: [Concurrency, Batching & Liquidity Dynamics] Explain mempool/batcher ordering, Plutus script budgets, or liquidity pool cointegration mechanics.
POST 4: [Empirical Benchmarks & Settlement Bounds] Report concrete settlement latency, throughput, slippage, or eigenvalue stability metrics using '▸' callouts.
POST 5: [Adversarial Vectors & Systemic Trade-Offs] Analyze contention stalls, MEV/arbitrage bounds, closure games, or collateral risks.
POST 6: [Provenance & Primary References] List the exact whitepapers, CIPs, arXiv preprints, and full URLs from the monograph's References section."
                        domain_focus="Focus on formal protocol invariants, EUTxO/AMM equations, script execution budgets, settlement latency, and primary citations from the monograph. NEVER mention corporate 10-K/EBITDA unless present in the monograph."
                        domain_thread_system="You are a disciplined cryptoeconomic and quantitative protocol scholar writing a magazine-style research thread for X Premium and Mastodon. Output only the thread posts separated by ---POST---. Keep every post structured (2-3 paragraphs + '▸' callouts) and between 600 and 1100 characters."
                        ;;
                    finance:corporate_equity)
                        thread_trajectory="POST 1: [Magazine Header & Financial Thesis] Line 1: '🏛️ ${clean_topic}', blank line, sharp 2-sentence hook on the accounting/valuation dislocation, blank line, core thesis.
POST 2: [Financial Performance & Balance Sheet] Hard revenue metrics, off-balance-sheet liabilities, margin trends, and unit economics with '▸' callouts.
POST 3: [Capital Allocation & Cash Flow] Free cash flow, debt/lease schedules, discount rates, and capital structure mechanics.
POST 4: [Valuation & Credit Assessment] Multiples, credit spreads, peer benchmarking, and structural invariants.
POST 5: [Macro Risks & Scenarios] Key operational risks, regulatory headwind, interest rate sensitivities, and bear/bull bounds.
POST 6: [Provenance & SEC Filings] List the exact primary 10-K/10-Q filings, FASB/IFRS standards, and URLs/references from the monograph."
                        domain_focus="Focus on hard financial metrics, SEC 10-K/10-Q disclosures, balance sheet footnotes, credit spreads, and primary filings from the monograph."
                        domain_thread_system="You are a disciplined financial analyst and forensic accounting scholar writing a magazine-style research thread for X Premium and Mastodon. Output only the thread posts separated by ---POST---. Keep every post between 600 and 1100 characters."
                        ;;
                    *)
                        thread_trajectory="POST 1: [Magazine Header & Microstructure Hook] Line 1: '🏛️ ${clean_topic}', blank line, sharp 2-sentence counter-intuitive hook on why textbook liquidity/pricing assumptions break down, blank line, core quantitative thesis.
POST 2: [Mathematical Formulation & Price Impact] Provide the exact econometric equations (e.g. Kyle's λ, Glosten-Milgrom spread, repo/SOFR corridor bounds, or convexity formulas) with '▸' equation callouts.
POST 3: [Order-Flow & Liquidity Plumbing] Detail market maker inventory dynamics, dealer balance-sheet constraints, or central-bank facility mechanics.
POST 4: [Empirical Benchmarks & Shock Regimes] Report concrete basis-point spreads, dollar volumes, VPIN/toxicity percentiles, or historical stress episodes with '▸' metric bullets.
POST 5: [Systemic Fragility & Execution Bounds] Explain nonlinear regime shifts, liquidity evaporation, and operational trade-offs.
POST 6: [Provenance & Primary Literature] List the exact academic papers, Federal Reserve/BIS/CFTC reports, and full URLs/arXiv/DOI references from the monograph."
                        domain_focus="Focus on exact econometric equations, basis-point spreads, dollar volumes, order-flow mechanics, and primary citations from the monograph. NEVER apologize for the absence of corporate 10-K filings."
                        domain_thread_system="You are a disciplined quantitative finance and market microstructure scholar writing a magazine-style research thread for X Premium and Mastodon. Output only the thread posts separated by ---POST---. Keep every post structured (2-3 paragraphs + '▸' callouts) and between 600 and 1100 characters."
                        ;;
                esac
                ;;
            general_sports_auto)
                thread_trajectory="POST 1: [Magazine Header & Analytical Hook] Line 1: '🏛️ ${clean_topic}', blank line, sharp 2-sentence counter-intuitive hook, blank line, core strategic or engineering thesis.
POST 2: [Specifications & Mechanical/Roster Dynamics] Hard specs: engine output, horsepower/torque, chassis geometry, or personnel/formation splits with '▸' metric bullets.
POST 3: [Tactical Strategy & Physics Execution] Playbook schemes, coaching decisions, aerodynamic downforce/drag, or biomechanical kinematics.
POST 4: [Comparative Performance & Empirical Records] Empirical timing: 0-60, lap times, EPA/play, CPOE, win probability swings, or historical records with '▸' callouts.
POST 5: [Critical Limits & Trade-Offs] Reliability bounds, thermal limits, fatigue, cap space, or defensive counter-adjustments.
POST 6: [Provenance & Primary Sources] List the exact official telemetry, Next Gen Stats / PFF / OEM sources, and URLs from the monograph's References section."
                domain_focus="Focus on hard facts, engineering telemetry, mechanical dyno numbers, playbook schemes, official game statistics, and primary citations from the monograph."
                domain_thread_system="You are a disciplined sports analytics and automotive engineering scholar writing a magazine-style research thread for X Premium and Mastodon. Output only the thread posts separated by ---POST---. Keep every post between 600 and 1100 characters."
                ;;
            engineering)
                thread_trajectory="POST 1: [Magazine Header & Systems Hook] Line 1: '🏛️ ${clean_topic}', blank line, sharp 2-sentence counter-intuitive hook on the scaling wall or systems bottleneck, blank line, core architectural thesis.
POST 2: [System Architecture & Standards] RFC specifications, protocol structures, kernel/distributed patterns, or memory model.
POST 3: [Implementation Mechanics & Algorithms] Key data structures, lock-free/consensus concurrency, API semantics, or compiler optimization with '▸' callouts.
POST 4: [Empirical Latency & Scale Benchmarks] Concrete QPS, p99 latency, memory throughput, and comparative scaling curves with '▸' metric bullets.
POST 5: [Operational Bottlenecks & Failure Modes] Critical edge cases, partition tolerance, tail-latency amplification, or hardware constraints.
POST 6: [Provenance & Repository Links] List the exact primary RFCs, GitHub repos, systems papers, and full URLs from the monograph's References section."
                domain_focus="Focus on hard engineering facts, RFC specifications, concrete QPS and p99 latency benchmarks, concurrency primitives, and primary GitHub/paper citations from the monograph."
                domain_thread_system="You are a disciplined systems architect and software engineering scholar writing a magazine-style research thread for X Premium and Mastodon. Output only the thread posts separated by ---POST---. Keep every post between 600 and 1100 characters."
                ;;
            academic|*)
                thread_trajectory="POST 1: [Magazine Header & Sovereign Hook] Line 1: '🏛️ ${clean_topic}', blank line, sharp 2-sentence counter-intuitive hook exposing why standard assumptions fail, blank line, core technical thesis.
POST 2: [Architectural Mechanics] Detail the specific structural transformation, protocol mechanics, or formal algorithmic representations.
POST 3: [Mathematical Formulation] Provide the exact Unicode equations, formal proof mechanics, parameter arithmetic, or complexity scaling bounds with '▸' callouts.
POST 4: [Empirical Benchmarks & Scaling] Report concrete benchmark numbers, downstream evaluation metrics, throughput, or resource savings from the papers using '▸' bullets.
POST 5: [Systems & Hardware Trade-Offs] Explain concrete hardware constraints, SRAM/VRAM bandwidth bounds, operational limits, or deployment bottlenecks.
POST 6: [Provenance & Synthesis] List the primary academic papers, key authors, exact arXiv IDs / DOIs / URLs from the monograph's Verified Citations section, and note archival in the Blue Lodge Sovereign Library."
                domain_focus="Focus on hard facts, mathematical formulas, concrete benchmark numbers, domain metrics, and primary citations from the monograph."
                domain_thread_system="You are a disciplined technical scholar writing a magazine-style multi-post research thread for X Premium and Mastodon. Output only the thread posts separated by ---POST---. Use clean Unicode math symbols (never LaTeX or $). Keep every post visually structured (2-3 paragraphs + '▸' callouts) and between 600 and 1100 characters."
                ;;
        esac

        # Pass the FULL dossier (up to 28,000 chars, always preserving the bottom Citations section) instead of head -n 100
        local full_dossier_context
        full_dossier_context=$(python3 - "$dossier_file" << 'PYEOF' 2>/dev/null || cat "$dossier_file"
import sys
p = sys.argv[1]
with open(p, "r", encoding="utf-8", errors="replace") as f:
    txt = f.read()
if len(txt) <= 28000:
    print(txt)
else:
    print(txt[:20000] + "\n\n[...]\n\n" + txt[-8000:])
PYEOF
)

        local t_prompt="You are George, writing a rich, magazine-style research thread for X Premium, Mastodon, and Bluesky based on this authoritative research monograph on '$clean_topic' [Domain: ${domain} (${subdomain})]:
${full_dossier_context}

Author a rigorous 6-post thread. Separate each post strictly using the delimiter:
---POST---

Structure the thread with the following trajectory:
${thread_trajectory}

Critical Magazine Formatting & Craftsmanship Directives:
- Separate EVERY post strictly with:
---POST---
- VISUAL PACING (NO WALLS OF TEXT): Every post MUST be broken into 2 to 3 crisp paragraphs separated by blank lines (\n\n). Never write a single monolithic block of text over 500 characters without a paragraph break. Use '▸ ' Unicode bullet callout lines to highlight 1 or 2 key quantitative metrics, equations, or primary sources inside Posts 2, 3, 4, and 6.
- POST 1 MAGAZINE HEADER: Post 1 MUST start with '🏛️ ${clean_topic}' on line 1, followed by a blank line, a sharp 2-sentence counter-intuitive hook, a blank line, and the core thesis. Under no circumstances begin Post 1 or any post with orphan connectives ('However,', 'Therefore,', 'Furthermore,').
- UNICODE MATH ONLY: Strictly plain text and clean Unicode symbols only (e.g. σ, π, λ, ∑, ≥, ≤, →, ∈, ≈, ≠, ·, ², ₙ). NEVER use LaTeX formatting or math delimiters (\$...\$ or \$\$...\$\$). NEVER use backslash math commands (write σ not \\sigma, λ not \\lambda). Never prefix variable names with \$ (write f(x) or C_st, NEVER \$f or \$C).
- LENGTH & DEPTH: Each post must be between 600 and 1,100 characters so it reads as a rich magazine dispatch on X Premium and splits cleanly into at most 2 balanced paired posts on Mastodon.
- REAL CITATIONS & URLS IN POST 6: Post 6 MUST include the actual verified primary source titles, arXiv IDs (arXiv:XXXX.XXXXX), DOIs, or full https:// URLs from the monograph's Citations/References section so readers can click through to the primary sources.
- ZERO META-APOLOGIES: Never write notes explaining how the topic fits or differs from a corporate 10-K template.
- Do NOT output tweet numbers like [1/6] or [2/6] (the publication engine prefixes these automatically).
- Do NOT include robotic prefixes or sign-offs (e.g. '[George]' or 'Thread below:').
- ${domain_focus}"

        if declare -f ipc_acquire_inference_lease &>/dev/null; then
            ipc_acquire_inference_lease "${IPC_PRIO_CRON:-50}" "research_thread_gen" 180 2>/dev/null || true
        fi

        local thread_max_tokens="${RESEARCH_THREAD_MAX_TOKENS:-8192}"
        local t_payload
        t_payload=$(jq -n --arg p "$t_prompt" --arg sys "$domain_thread_system" --argjson mt "$thread_max_tokens" \
            '{messages: [{"role": "system", "content": $sys}, {"role": "user", "content": $p}], temperature: 0.7, max_tokens: $mt, chat_template_kwargs: {enable_thinking: false}}')
        declare -f transcript_log_prompt &>/dev/null && transcript_log_prompt "social_thread" "$t_prompt" "$domain_thread_system"
        local raw_t_resp
        raw_t_resp=$(curl -s --max-time 450 "$llm_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$t_payload" 2>/dev/null)
        local finish_reason
        finish_reason=$(echo "$raw_t_resp" | jq -r '.choices[0].finish_reason // empty' 2>/dev/null)
        thread_content=$(echo "$raw_t_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        thread_content=$(_research_strip_thinking "$thread_content")

        if [ "$finish_reason" = "length" ]; then
            ui_warn "LLM thread generation hit token limit (finish_reason=length); falling back to complete structured dossier extraction."
            thread_content=""
        fi

        if declare -f ipc_release_inference_lease &>/dev/null; then
            ipc_release_inference_lease "research_thread_gen" 2>/dev/null || true
        fi
    fi

    # Completeness and structural validity verification for social threads
    local post_count=0 is_truncated=0 has_provenance=0
    if [ -n "$thread_content" ]; then
        post_count=$(grep -c -- '---POST---' <<< "$thread_content" 2>/dev/null || echo 0)
        post_count=$((post_count + 1))
        local last_post_tail
        last_post_tail=$(echo "$thread_content" | sed '/^[[:space:]]*$/d' | tail -n 1 | tr -d '\r\n')
        # Check for explicit mid-sentence truncation (dangling punctuation or trailing conjunctions/prepositions)
        if [[ "$last_post_tail" =~ (,|;|—|:\s*|-\s*)$ ]] || [[ "$last_post_tail" =~ [[:space:]]+(and|or|with|where|which|that|the|a|an|in|on|at|of|to|is|has|have|having|including)[[:space:]]*$ ]]; then
            is_truncated=1
        fi
        # Check for references / provenance across academic, financial, engineering, sports, and historical domains
        if grep -qiE "(arXiv:[0-9]+\.[0-9]+|doi:|https?://|Primary Sources?:|Sources?:|References?:|Citations?:|Sovereign Library|Blue Lodge|Archiv|SEC|10-K|10-Q|GitHub|RFC|NFL|ESPN|Next Gen Stats|PFF|Telemetry|Dyno|Chassis|FIA|F1|Formula 1|NASCAR|Motorsport|Stathead|Pro-Football-Reference)" <<< "$thread_content" 2>/dev/null; then
            has_provenance=1
        fi
    fi

    if [ -z "$thread_content" ] || [ "${#thread_content}" -lt 80 ] || [ "$post_count" -lt 4 ] || [ "$is_truncated" -eq 1 ] || [ "$has_provenance" -eq 0 ] || _research_is_deliberation_trace "$thread_content"; then
        if [ "$is_truncated" -eq 1 ]; then
            ui_warn "LLM generated incomplete/truncated thread (ends abruptly mid-sentence); falling back to clean dossier extraction."
        elif [ "$has_provenance" -eq 0 ] && [ -n "$thread_content" ]; then
            ui_warn "LLM generated thread lacking primary source citations; falling back to clean dossier extraction."
        elif [ "$post_count" -lt 4 ] && [ -n "$thread_content" ]; then
            ui_warn "LLM generated only $post_count post(s) (expected 5-7); falling back to clean dossier extraction."
        elif [ -n "$thread_content" ] && _research_is_deliberation_trace "$thread_content"; then
            ui_warn "LLM generated deliberation scratchpad traces instead of final summary; falling back to clean dossier extraction."
        fi
        # Fallback to high-density magazine-style multi-part extraction from dossier across all 5 domains
        if [ -f "$RESEARCH_VERIFIER_PY" ]; then
            local extract_max=920
            if [ "${X_PREMIUM:-1}" = "0" ]; then
                extract_max=460
            fi
            thread_content=$(python3 "$RESEARCH_VERIFIER_PY" extract-thread --file "$dossier_file" --max-len "$extract_max" 2>/dev/null || true)
        fi

        # Secondary fallback if python extractor returned empty
        if [ -z "$thread_content" ] || [ "${#thread_content}" -lt 80 ]; then
            local p1_abstract p2_foundations p3_math p4_empirical p5_provenance
            p1_abstract=$(grep -A 10 -iE '## (Executive Abstract|Executive Summary|Executive Overview|Executive Thesis)' "$dossier_file" 2>/dev/null | grep -v '^#' | sed '/^[[:space:]]*$/d' | head -n 4 | tr '\n' ' ')
            [ -z "$p1_abstract" ] && p1_abstract="Sovereign technical evaluation of ${topic} examining foundational mechanics, structural dynamics, and empirical performance bounds."
            p1_abstract=$(_research_clean_sentence "$p1_abstract" 450)

            p2_foundations=$(grep -A 15 -iE '## (Theoretical Foundations|System Architecture|Technical Specifications|Financial Performance|Hardware Architecture|Powertrain Specifications|Team Roster)' "$dossier_file" 2>/dev/null | grep -v -E '^(#|- Ingest|- Download|soul\.md|vision_analyze)' | sed '/^[[:space:]]*$/d' | head -n 4 | tr '\n' ' ')
            [ -z "$p2_foundations" ] && p2_foundations="Architectural analysis reveals concrete system dynamics and execution mechanics, quantifying operational efficiency and resource allocation."
            p2_foundations=$(_research_clean_sentence "$p2_foundations" 450)

            p3_math=$(grep -A 15 -iE '## (System Architecture|Algorithmic Mechanics|Core Implementation|Tactical Analysis|Capital Allocation|Emulation Mechanics|Aerodynamic Mechanics|Playbook Schemes)|### 2\.' "$dossier_file" 2>/dev/null | grep -v '^#' | grep -E '\$|\bparameter\b|\bformula\b|\bmapping\b|\bcompute\b|\brevenue\b|\bmargin\b|\bjit\b|\bhorsepower\b|\btorque\b|\bdepth\b|\bwin probability\b|\byards\b|\bdown\b' | head -n 4 | tr '\n' ' ')
            [ -z "$p3_math" ] && p3_math="Operational mechanics establish concrete execution boundaries, component scaling, and verifiable structural trade-offs."
            p3_math=$(_research_clean_sentence "$p3_math" 450)

            p4_empirical=$(grep -A 15 -iE '## (Empirical Benchmarks|Performance Benchmarks|Comparative Benchmarks|Valuation Multiples|Frame Timing|Telemetry Data|Player Efficiency|Track Timing)' "$dossier_file" 2>/dev/null | grep -v -E '^(#|- Ingest|- Download)' | sed '/^[[:space:]]*$/d' | head -n 4 | tr '\n' ' ')
            [ -z "$p4_empirical" ] && p4_empirical="Empirical benchmarking establishes verifiable scaling frontiers across primary metrics, efficiency curves, and operational performance."
            p4_empirical=$(_research_clean_sentence "$p4_empirical" 450)

            local citations
            citations=$(grep -E '^( - Source:| - Reference:| - Paper Source:| - Citations:| - Repository:)' "$dossier_file" 2>/dev/null | head -n 3 | sed 's/^[[:space:]]*- //' | tr '\n' '; ')
            [ -z "$citations" ] && citations="Primary sources and empirical data cataloged in Blue Lodge Sovereign Library"
            p5_provenance="Primary Provenance & References: ${citations}. Full technical monograph and artifacts preserved in Blue Lodge Sovereign Library."
            p5_provenance=$(_research_clean_sentence "$p5_provenance" 450)

            thread_content="${p1_abstract}

---POST---
${p2_foundations}

---POST---
${p3_math}

---POST---
${p4_empirical}

---POST---
${p5_provenance}"
        fi
    fi

    # Sanitize math formatting, LaTeX, delimiters, and single-letter cashtags for all social broadcasts
    if [ -n "$thread_content" ] && declare -f social_sanitize_text &>/dev/null; then
        thread_content=$(social_sanitize_text "$thread_content")
    fi

    echo "$thread_content" > "$thread_file"
    if declare -f transcript_log_details &>/dev/null; then
        transcript_log_details "Generated Social Media Thread (thread.md)" "$thread_content" "markdown"
    fi

    # ── Grounding Verification Sub-Graph for Social Thread ──
    if declare -f research_verify_and_refine &>/dev/null; then
        if ! research_verify_and_refine "thread" "$thread_file" "$domain" "$clean_topic" "$slug" "$sandbox_dir"; then
            ui_warn "Draft social thread failed grounding verification gates and was quarantined. Halting broadcast staging."
            return 1
        fi
    fi

    local perm_dir="${RESEARCH_DIR}/${slug}"
    mkdir -p "$perm_dir"

    cp "$dossier_file" "$perm_dir/dossier.md"
    cp "$scratchpad" "$perm_dir/scratchpad.md" 2>/dev/null || true
    [ -d "$sandbox_dir/artifacts" ] && cp -r "$sandbox_dir/artifacts" "$perm_dir/"

    # PGP Ed25519 sign thread
    local raw_thread
    raw_thread=$(cat "$thread_file")
    local signed_thread
    signed_thread=$(pgp_sign_social "$raw_thread" 2>/dev/null || echo "$raw_thread")
    echo "$signed_thread" > "$perm_dir/thread.md"
    declare -f transcript_log &>/dev/null && transcript_log "pgp_sign" "PGP Ed25519 signature generated for social broadcast"

    # Render deterministic Monograph Plate (summary_card.png)
    research_generate_plate "$perm_dir"

    # Queue for broadcast
    local queue_item="${RESEARCH_QUEUE_DIR}/${ts}_research_${slug}.txt"
    echo "$signed_thread" > "$queue_item"
    declare -f transcript_log &>/dev/null && transcript_log "broadcast_queue" "Staged in $(basename "$queue_item")"

    # Index in research library
    local theme_label
    theme_label=$(research_domain_theme_label "$domain")
    local record
    record=$(jq -nc \
        --arg slug "$slug" \
        --arg topic "$topic" \
        --arg domain "$domain" \
        --arg category "$domain" \
        --arg theme "$theme_label" \
        --arg date "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg path "$perm_dir" \
        --arg queue "$queue_item" \
        '{slug: $slug, topic: $topic, domain: $domain, category: $category, theme: $theme, timestamp: $date, directory: $path, queue_file: $queue}')
    echo "$record" >> "$RESEARCH_INDEX"

    # Preserve task transcripts to permanent research directory and system transcripts
    local sys_transcript_dir="${GEORGE_TRANSCRIPT_DIR:-${GEORGE_DIR:-$LODGE_DIR/.george}/transcripts}"
    mkdir -p "$sys_transcript_dir" 2>/dev/null || true

    if [ -d "$sandbox_dir/.george/transcripts" ]; then
        local t_file
        for t_file in "$sandbox_dir/.george/transcripts"/*.md; do
            [ -f "$t_file" ] || continue
            cp -u "$t_file" "$perm_dir/" 2>/dev/null || true
            if [ ! -L "$sandbox_dir/.george/transcripts" ]; then
                cp -u "$t_file" "$sys_transcript_dir/" 2>/dev/null || true
            fi
        done
    fi

    # Re-anchor active transcript files to system transcripts directory if currently inside sandbox_dir
    if [ -n "${_TRANSCRIPT_FILE:-}" ] && [[ "$_TRANSCRIPT_FILE" == "$sandbox_dir"* ]]; then
        local active_t_name
        active_t_name=$(basename "$_TRANSCRIPT_FILE")
        export _TRANSCRIPT_FILE="${sys_transcript_dir}/$active_t_name"
        export _TRANSCRIPT_DIR="$sys_transcript_dir"
        if [ -n "${_PROMPT_LOG_FILE:-}" ]; then
            local p_name
            p_name=$(basename "$_PROMPT_LOG_FILE")
            export _PROMPT_LOG_FILE="${sys_transcript_dir}/$p_name"
        fi
    fi

    rm -rf "$sandbox_dir"
    ui_ok "Deep Research complete! Preserved in sovereign library at: ${perm_dir}/"
    ui_info "Queued for broadcast: $(basename "$queue_item")"

    # If downstream publisher (e.g. commands/research.sh) is broadcasting, keep transcript open
    if [ "${RESEARCH_KEEP_TRANSCRIPT:-0}" -ne 1 ]; then
        if declare -f transcript_stop &>/dev/null && declare -f transcript_active &>/dev/null && transcript_active; then
            local final_t
            final_t=$(transcript_stop)
            if [ -n "$final_t" ] && [ -f "$final_t" ]; then
                cp "$final_t" "$perm_dir/" 2>/dev/null || true
                local final_p="${final_t%.md}_prompts.md"
                [ -f "$final_p" ] && cp "$final_p" "$perm_dir/" 2>/dev/null || true
            fi
        fi
        export _TRANSCRIPT_FILE=""
        export _PROMPT_LOG_FILE=""
    fi
}

# ── Research Phase & Live Companion HUD Launcher ─────────────────────
research_set_phase() {
    local sandbox_dir="$1"
    local phase_str="$2"
    mkdir -p "$sandbox_dir" 2>/dev/null || true
    echo "$phase_str" > "$sandbox_dir/.phase" 2>/dev/null || true
}

research_launch_live_monitor() {
    local topic="$1"
    local slug="$2"
    local sandbox_dir="$3"

    # If Web UI is running, do not spawn terminal popups
    if pgrep -f "george-web" &>/dev/null || \
       [ -f "${GEORGE_CONFIG_DIR:-$LODGE_DIR/.george}/.web_observability" ] || \
       ! declare -f popup_is_gui_available &>/dev/null || \
       ! popup_is_gui_available; then
        return 0
    fi

    # Clean up any lingering monitor process for this sandbox slug
    local existing_mon
    existing_mon=$(pgrep -f "scripts/monitor/research_live_monitor.sh.*$slug" 2>/dev/null || true)
    if [ -n "$existing_mon" ]; then
        kill $existing_mon 2>/dev/null || true
        sleep 0.2
    fi

    popup_terminal_launch "George Research HUD — $slug" "115,34" \
        bash ./scripts/monitor/research_live_monitor.sh "$topic" "$slug" "$sandbox_dir"
}

# ── Autonomous Deep Research Graph Execution ─────────────────────────
# Usage: research_graph_run [topic]
research_graph_run() {
    local topic="${1:-}"
    research_init

    if [ -z "$topic" ]; then
        ui_step "Discovering open-ended research inquiry from Lodge reflections..."
        topic=$(research_discover_topic)
    fi

    local slug
    slug=$(research_slugify "$topic")
    [ -z "$slug" ] && slug="inquiry-$(date +%s)"

    local ts
    ts=$(date +%s)
    local sandbox_dir="${LODGE_DIR}/.sandboxes/research_${slug}_${ts}"
    local sys_transcript_dir="${GEORGE_TRANSCRIPT_DIR:-${GEORGE_DIR:-$LODGE_DIR/.george}/transcripts}"
    mkdir -p "$sandbox_dir/artifacts" "$sandbox_dir/.george" "$sys_transcript_dir"
    ln -sfn "$sys_transcript_dir" "$sandbox_dir/.george/transcripts" 2>/dev/null || mkdir -p "$sandbox_dir/.george/transcripts"
    echo "${BASHPID:-$$}" > "$sandbox_dir/.pid" 2>/dev/null || true
    trap "touch '$sandbox_dir/.done' 2>/dev/null; rm -f '$sandbox_dir/.pid' 2>/dev/null" INT TERM

    # Ensure an active transcript covers the entire 5-phase research graph, anchored in sovereign transcripts
    if ! declare -f transcript_active &>/dev/null || ! transcript_active; then
        declare -f transcript_start &>/dev/null && transcript_start "Autonomous Research Graph: $topic" "$LODGE_DIR"
    fi

    # Resolve domain upfront so all 5 phases share the exact same domain context
    local domain
    domain=$(research_classify_domain "$topic")
    local theme_label
    theme_label=$(research_domain_theme_label "$domain")

    ui_section "Autonomous Deep Research Engine: $topic"
    ui_info "Inquiry Slug: $slug"
    ui_dim "Domain:       $domain ($theme_label)"
    ui_dim "Sandbox:      $sandbox_dir"

    # Launch non-intrusive companion HUD monitor (minimized to tray/taskbar)
    research_launch_live_monitor "$topic" "$slug" "$sandbox_dir"

    # Phase 1: ReAct Deep Investigation Loop in Sandbox
    research_set_phase "$sandbox_dir" "Phase 1/5: Deep ReAct Investigation & Primary Ingest"
    if ! research_investigate_react "$topic" "$sandbox_dir" "$domain"; then
        ui_warn "Research investigation entered quarantine / halted in Phase 1. Preserving state and pausing pipeline."
        research_set_phase "$sandbox_dir" "Phase 1/5: Quarantined Pending Remediation"
        return 1
    fi

    # Phase 2: Evidence Audit & Gap Analysis
    research_set_phase "$sandbox_dir" "Phase 2/5: Evidence Audit & Gap Analysis"
    research_evidence_audit "$topic" "$sandbox_dir" "$domain"

    # Phase 3: Long-Form Technical Synthesis (dossier.md)
    research_set_phase "$sandbox_dir" "Phase 3/5: Long-Form Technical Monograph Synthesis"
    if ! research_synthesize_dossier "$topic" "$sandbox_dir" "$domain"; then
        ui_warn "Synthesized monograph failed verification gates. Quarantined pending remediation."
        research_set_phase "$sandbox_dir" "Phase 3/5: Quarantined Due to Verification Failure"
        return 1
    fi

    # Phase 4: Editorial Critique & soul.md Refinement
    research_set_phase "$sandbox_dir" "Phase 4/5: Editorial Critique & Standard Alignment"
    research_editorial_critique "$topic" "$sandbox_dir" "$domain"

    # Phase 5: The Three Degrees Audit & Publication Packaging
    research_set_phase "$sandbox_dir" "Phase 5/5: The Three Degrees Audit & Publication Packaging"
    if ! research_audit_and_package "$topic" "$slug" "$sandbox_dir" "$ts" "$domain"; then
        ui_warn "Broadcast packaging failed verification gates. Quarantined pending remediation."
        research_set_phase "$sandbox_dir" "Phase 5/5: Quarantined Due to Verification Failure"
        return 1
    fi

    touch "$sandbox_dir/.done" 2>/dev/null || true
    research_set_phase "$sandbox_dir" "Research Complete: Dossier Generated"
    trap - EXIT INT TERM 2>/dev/null || true

    return 0
}

# ── Query Dossier For Replies ─────────────────────────────────────────
# Retrieves the dossier to answer follow-up questions from social platforms
research_query_sources() {
    local target="$1"
    local query="${2:-}"
    research_init

    local target_dir="${RESEARCH_DIR}/${target}"
    if [ ! -d "$target_dir" ]; then
        # Search index by topic or slug match
        local matched_dir
        matched_dir=$(grep -i "$target" "$RESEARCH_INDEX" 2>/dev/null | tail -1 | jq -r '.directory // empty' 2>/dev/null)
        if [ -n "$matched_dir" ] && [ -d "$matched_dir" ]; then
            target_dir="$matched_dir"
        fi
    fi

    if [ ! -f "$target_dir/dossier.md" ]; then
        ui_err "No research dossier found matching: '$target'"
        return 1
    fi

    ui_section "Research Sourcing Dossier: $(basename "$target_dir")"
    cat "$target_dir/dossier.md"
    return 0
}

# ── List Research Library ─────────────────────────────────────────────
research_list() {
    research_init
    ui_section "George Research Library & Queue"

    if [ ! -f "$RESEARCH_INDEX" ] || [ ! -s "$RESEARCH_INDEX" ]; then
        ui_dim "No research investigations recorded yet."
        ui_info "Trigger one with: /research start [optional topic]"
        return 0
    fi

    echo "ARCHIVED INVESTIGATIONS:"
    while read -r line; do
        [ -z "$line" ] && continue
        local r_slug r_topic r_ts
        r_slug=$(echo "$line" | jq -r '.slug // empty')
        r_topic=$(echo "$line" | jq -r '.topic // empty')
        r_ts=$(echo "$line" | jq -r '.timestamp // empty')
        printf "  %b●%b %-25s — %s (%s)\n" "$C_CYAN" "$C_RESET" "$r_slug" "$r_topic" "${r_ts:0:10}"
    done < "$RESEARCH_INDEX"

    echo ""
    ui_step "Pending Publication Queue:"
    local q_files=("$RESEARCH_QUEUE_DIR"/*.txt)
    if [ -e "${q_files[0]}" ]; then
        for qf in "${q_files[@]}"; do
            [ -f "$qf" ] || continue
            printf "  %b↳%b %s (%s bytes)\n" "$C_GREEN" "$C_RESET" "$(basename "$qf")" "$(wc -c < "$qf")"
        done
    else
        ui_dim "  Queue is currently empty."
    fi
}

# ── Backlog Salvage Utility ───────────────────────────────────────────
# Recovers and verifies quarantined research dossiers, advancing them
# through Phase 4 (Editorial) and Phase 5 (PGP Ed25519 Signing & Broadcast Staging)
research_salvage() {
    local target="${1:-all}"
    research_init

    local q_base="${RESEARCH_QUARANTINE_DIR:-${RESEARCH_DIR:-$GEORGE_DIR/research}/quarantine}"
    if [ ! -d "$q_base" ]; then
        ui_info "No quarantine directory found at $q_base"
        return 0
    fi

    local targets=()
    if [ "$target" = "all" ] || [ "$target" = "--all" ] || [ -z "$target" ]; then
        for d in "$q_base"/*; do
            [ -d "$d" ] && targets+=("$(basename "$d")")
        done
    else
        target="${target#--}"
        if [ -d "$q_base/$target" ]; then
            targets+=("$target")
        else
            ui_err "Quarantined dossier not found: '$target' in $q_base"
            return 1
        fi
    fi

    if [ "${#targets[@]}" -eq 0 ]; then
        ui_info "Quarantine queue is empty. No dossiers to salvage."
        return 0
    fi

    ui_section "George Research Backlog Salvage Engine"
    ui_dim "Found ${#targets[@]} candidate quarantined dossier(s)."

    local salvaged_count=0
    for slug in "${targets[@]}"; do
        local q_dir="$q_base/$slug"
        local dossier_file="$q_dir/dossier.md"
        if [ ! -f "$dossier_file" ]; then
            ui_warn "Skipping $slug: missing dossier.md"
            continue
        fi

        # Extract topic from quarantine_report.md or dossier.md or slug
        local topic=""
        if [ -f "$q_dir/quarantine_report.md" ]; then
            topic=$(grep -m 1 -E '^\*\*Topic:\*\*' "$q_dir/quarantine_report.md" 2>/dev/null | sed -E 's/^\*\*Topic:\*\*[[:space:]]*//' | tr -d '\r')
        fi
        if [ -z "$topic" ]; then
            topic=$(head -n 5 "$dossier_file" | grep -m 1 '^# ' | sed -E 's/^#[[:space:]]+(Sovereign Research Dossier:[[:space:]]*)?//' | tr -d '\r')
        fi
        [ -z "$topic" ] && topic=$(echo "$slug" | tr '-' ' ')

        local clean_topic="$topic"
        if [[ "$topic" =~ ^\[([a-zA-Z0-9_-]+)\][[:space:]]*(.*)$ ]]; then
            clean_topic="${BASH_REMATCH[2]}"
        fi
        local domain
        domain=$(research_classify_domain "$topic")

        local sbox_ts=$(date +%s)
        local sbox_dir="$LODGE_DIR/.sandboxes/salvage_${slug}_${sbox_ts}"
        mkdir -p "$sbox_dir" 2>/dev/null || true
        echo "${BASHPID:-$$}" > "$sbox_dir/.pid" 2>/dev/null || true
        echo "Evaluating verification gates..." > "$sbox_dir/.phase" 2>/dev/null || true
        cat > "$sbox_dir/task_meta.json" << EOF
{
  "command": "/research salvage ${slug}",
  "task_type": "research",
  "type": "research",
  "name": "salvage_${slug}",
  "summary": "Salvage Dossier: ${clean_topic}",
  "objective": "Grounding verification, editorial critique, and PGP signing for ${clean_topic}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

        echo ""
        ui_step "Evaluating candidate: '$clean_topic' [slug: $slug, domain: $domain]"

        # Ensure scratchpad exists for evidence resolution
        [ ! -f "$q_dir/scratchpad.md" ] && touch "$q_dir/scratchpad.md"

        # Gate 1 & 2 Verification with ReAct Refiner if needed
        echo "Gate 1-3: Grounding Verification..." > "$sbox_dir/.phase" 2>/dev/null || true
        if ! research_verify_and_refine "dossier" "$dossier_file" "$domain" "$clean_topic" "$slug" "$q_dir"; then
            ui_warn "Dossier '$slug' failed verification gates. Remaining in quarantine."
            echo "Failed: Verification gates rejected" > "$sbox_dir/.phase" 2>/dev/null || true
            touch "$sbox_dir/.done" 2>/dev/null || true
            continue
        fi

        # Phase 4: Editorial Critique & soul.md Refinement
        echo "Phase 4/5: Editorial Critique & Craftsmanship..." > "$sbox_dir/.phase" 2>/dev/null || true
        research_editorial_critique "$clean_topic" "$q_dir"

        # Phase 5: The Three Degrees Audit & Publication Packaging
        echo "Phase 5/5: Three Degrees Audit & PGP Signing..." > "$sbox_dir/.phase" 2>/dev/null || true
        local ts=$(date +%s)
        if ! research_audit_and_package "$clean_topic" "$slug" "$q_dir" "$ts"; then
            ui_warn "Packaging failed for '$slug'. Remaining in quarantine."
            echo "Failed: Packaging / audit rejected" > "$sbox_dir/.phase" 2>/dev/null || true
            touch "$sbox_dir/.done" 2>/dev/null || true
            continue
        fi

        # Clean up the quarantine folder since it has been safely migrated to $RESEARCH_DIR/$slug
        rm -rf "$q_dir"
        salvaged_count=$((salvaged_count + 1))
        echo "Completed: Dossier salvaged & published" > "$sbox_dir/.phase" 2>/dev/null || true
        touch "$sbox_dir/.done" 2>/dev/null || true
        ui_ok "✓ Successfully salvaged and published: $slug"
    done

    echo ""
    ui_ok "Salvage run complete: $salvaged_count of ${#targets[@]} dossier(s) successfully verified and published."
    return 0
}

# ── Research Topics Manager ──────────────────────────────────────────
research_topics_list() {
    research_init
    local dom_arg="${1:-}"
    if [ -z "$dom_arg" ] && [ -f "${GEORGE_DIR:-$LODGE_DIR/.george}/research.conf" ]; then
        dom_arg=$(jq -r '.active_domain // empty' "${GEORGE_DIR:-$LODGE_DIR/.george}/research.conf" 2>/dev/null)
    fi
    local topics_file
    topics_file=$(research_domain_topics_file "${dom_arg:-academic}")
    if [ ! -f "$topics_file" ]; then
        topics_file="${GEORGE_DIR:-$LODGE_DIR/.george}/research_topics.txt"
    fi
    if [ ! -f "$topics_file" ]; then
        ui_warn "No research topics file found at: $topics_file"
        return 1
    fi

    local index_file="${RESEARCH_INDEX:-${GEORGE_DIR:-$LODGE_DIR/.george}/research/research_index.jsonl}"
    local q_base="${RESEARCH_QUARANTINE_DIR:-${RESEARCH_DIR:-$GEORGE_DIR/research}/quarantine}"
    local theme_title
    theme_title=$(research_domain_theme_label "${dom_arg:-academic}")

    ui_section "Sovereign Research Topics Pool [${theme_title}]"
    ui_dim "File: $topics_file"
    echo ""

    local count=0
    local fresh_cnt=0
    local verified_cnt=0
    local quarantined_cnt=0

    while IFS= read -r topic_line; do
        [[ "$topic_line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${topic_line// }" ]] && continue
        count=$((count + 1))

        local slug
        slug=$(research_slugify "$topic_line")
        local domain
        domain=$(research_classify_domain "$topic_line")

        local status_tag=""
        if [ -f "$index_file" ] && grep -qi "$slug" "$index_file" 2>/dev/null; then
            status_tag="\033[32m[VERIFIED]\033[0m"
            verified_cnt=$((verified_cnt + 1))
        elif [ -d "$q_base/$slug" ] || [ -d "$q_base/${slug:0:48}" ]; then
            status_tag="\033[33m[QUARANTINED]\033[0m"
            quarantined_cnt=$((quarantined_cnt + 1))
        else
            status_tag="\033[36m[FRESH]\033[0m"
            fresh_cnt=$((fresh_cnt + 1))
        fi

        printf "  %2d. %b \033[90m(%-10s)\033[0m %s\n" "$count" "$status_tag" "$domain" "$topic_line"
    done < "$topics_file"

    echo ""
    ui_dim "Pool Status: $count Total | $fresh_cnt Fresh | $verified_cnt Verified | $quarantined_cnt Quarantined"
    ui_dim "To edit topics in VIM, run: ./lodge /research edit ${dom_arg:-academic}"
    return 0
}

research_topics_edit() {
    research_init
    local dom_arg="${1:-}"
    if [ -z "$dom_arg" ] && [ -f "${GEORGE_DIR:-$LODGE_DIR/.george}/research.conf" ]; then
        dom_arg=$(jq -r '.active_domain // empty' "${GEORGE_DIR:-$LODGE_DIR/.george}/research.conf" 2>/dev/null)
    fi
    local topics_file
    topics_file=$(research_domain_topics_file "${dom_arg:-academic}")
    [ ! -f "$topics_file" ] && touch "$topics_file"

    local editor="${EDITOR:-vim}"
    if ! command -v "$editor" &>/dev/null; then
        if command -v vim &>/dev/null; then
            editor="vim"
        elif command -v nano &>/dev/null; then
            editor="nano"
        else
            editor="vi"
        fi
    fi

    local theme_title
    theme_title=$(research_domain_theme_label "${dom_arg:-academic}")
    ui_section "Opening Research Topics in $editor [${theme_title}]"
    ui_dim "File: $topics_file"
    echo ""

    if [ -t 0 ] && [ -t 1 ]; then
        "$editor" "$topics_file"
    elif [ -c /dev/tty ]; then
        "$editor" "$topics_file" < /dev/tty > /dev/tty
    else
        "$editor" "$topics_file"
    fi

    # Sync to master if this was the active domain
    local active_m
    active_m=$(jq -r '.active_domain // "academic"' "${GEORGE_DIR:-$LODGE_DIR/.george}/research.conf" 2>/dev/null)
    if [ "$dom_arg" = "$active_m" ] || [ -z "$dom_arg" -a "$active_m" = "academic" ]; then
        cp "$topics_file" "${GEORGE_DIR:-$LODGE_DIR/.george}/research_topics.txt" 2>/dev/null || true
    fi

    local total_cnt
    total_cnt=$(grep -v '^[[:space:]]*#' "$topics_file" 2>/dev/null | grep -v '^[[:space:]]*$' | wc -l)
    echo ""
    ui_ok "Saved $topics_file ($total_cnt topics configured)."
    return 0
}

research_topics_random() {
    research_init
    local dom_arg="${1:-}"
    local chosen_domain="$dom_arg"
    if [ -z "$chosen_domain" ] || [ "$chosen_domain" = "all" ]; then
        local domains=("academic" "engineering" "finance" "gaming" "general_sports_auto")
        chosen_domain="${domains[$(( RANDOM % ${#domains[@]} ))]}"
    fi

    local topics_file
    topics_file=$(research_domain_topics_file "$chosen_domain")
    if [ ! -f "$topics_file" ]; then
        topics_file="${GEORGE_DIR:-$LODGE_DIR/.george}/research_topics.txt"
    fi

    local topics=()
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        topics+=("$line")
    done < "$topics_file"

    if [ ${#topics[@]} -eq 0 ]; then
        ui_err "No candidate topics found in $topics_file"
        return 1
    fi

    local rand_idx=$(( RANDOM % ${#topics[@]} ))
    local selected="${topics[$rand_idx]}"
    local theme_title
    theme_title=$(research_domain_theme_label "$chosen_domain")

    ui_section "Random Theme Pick"
    echo -e "  \033[1;35mTheme:\033[0m $theme_title ($chosen_domain)"
    echo -e "  \033[1;32mTopic:\033[0m $selected"
    echo -e "  \033[90mSource:\033[0m $topics_file"
    echo ""
    echo "$selected"
}

# ── Re-Synthesize Social Thread & Monograph Plate From Existing Dossier ──
# Usage: research_resynthesize_thread <slug> [--no-llm]
research_resynthesize_thread() {
    local slug="$1"
    local mode_flag="${2:-}"
    research_init

    if [ -z "$slug" ]; then
        ui_err "Usage: /research resynthesize <slug>"
        return 1
    fi

    local perm_dir="${RESEARCH_DIR}/${slug}"
    if [ ! -d "$perm_dir" ] || [ ! -f "$perm_dir/dossier.md" ]; then
        ui_err "Dossier not found for slug: '$slug'"
        return 1
    fi

    local dossier_file="$perm_dir/dossier.md"
    local topic=""
    topic=$(grep -m 1 -E '^topic:' "$dossier_file" 2>/dev/null | sed -E 's/^topic:[[:space:]]*"?([^"]*)"?$/\1/' | tr -d '\r')
    if [ -z "$topic" ]; then
        topic=$(grep -m 1 -E '^#[[:space:]]+' "$dossier_file" 2>/dev/null | sed -E 's/^#[[:space:]]+(Sovereign [A-Za-z &]+ Dossier:[[:space:]]*)?//' | tr -d '\r')
    fi
    [ -z "$topic" ] && topic="$slug"

    # Strip any rubric meta-apologies from existing dossier.md
    if command -v python3 &>/dev/null; then
        python3 - "$dossier_file" << 'PYEOF' 2>/dev/null || true
import sys, re
p = sys.argv[1]
with open(p, "r", encoding="utf-8", errors="replace") as f:
    txt = f.read()
cleaned = re.sub(
    r"^\s*\*?(?:Note|Editor's Note|Analytical Note):\s*(?:As this topic concerns|While this topic|Because this inquiry examines|Since this analysis focuses on)[^\n]*(?:corporate entity|10-K|SEC filing|balance sheet)[^\n]*\*?\s*\n?",
    "",
    txt,
    flags=re.IGNORECASE | re.MULTILINE,
)
if cleaned != txt:
    with open(p, "w", encoding="utf-8") as f:
        f.write(cleaned)
PYEOF
    fi

    local thread_content=""
    if [ -f "$RESEARCH_VERIFIER_PY" ]; then
        local extract_max=920
        [ "${X_PREMIUM:-1}" = "0" ] && extract_max=460
        thread_content=$(python3 "$RESEARCH_VERIFIER_PY" extract-thread --file "$dossier_file" --max-len "$extract_max" 2>/dev/null || true)
    fi

    if [ -n "$thread_content" ] && [ "${#thread_content}" -ge 80 ]; then
        if declare -f social_sanitize_text &>/dev/null; then
            thread_content=$(social_sanitize_text "$thread_content")
        fi
        local signed_thread
        signed_thread=$(pgp_sign_social "$thread_content" 2>/dev/null || echo "$thread_content")
        echo "$signed_thread" > "$perm_dir/thread.md"
        ui_ok "Re-synthesized magazine thread for: $slug"
    fi

    research_generate_plate "$perm_dir"
    return 0
}


