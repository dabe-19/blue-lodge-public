#!/bin/bash
# ══════════════════════════════════════════════════════════════
# lib/reflexive.sh — Reflexive Intelligence Layer
# ══════════════════════════════════════════════════════════════
# Five self-monitoring subsystems that let George observe his own
# cognition and adapt in-flight.  Every feature is toggled OFF by
# default so 4B-parameter models are never burdened unless the
# operator explicitly opts in from the REPL.
#
# Subsystems:
#   1. Soul Consensus Gate    — REFLEXIVE_SOUL_GATE
#   2. Self-Improving Prompts — REFLEXIVE_PROMPT_LEARN
#   3. Adaptive Token Budgets — REFLEXIVE_ADAPT_TOKENS
#   4. Speculative Pre-fetch  — REFLEXIVE_SPECULATE
#   5. Self-Model (Metacog)   — REFLEXIVE_SELF_MODEL
#
# Integration: source'd by the lodge main script AFTER agent.sh
# so all _micro_*, _macro_*, and agent_* helpers are available.
# ══════════════════════════════════════════════════════════════

# ── Config toggles (all OFF by default for 4B safety) ─────────
export REFLEXIVE_SOUL_GATE="${REFLEXIVE_SOUL_GATE:-0}"
export REFLEXIVE_PROMPT_LEARN="${REFLEXIVE_PROMPT_LEARN:-0}"
export REFLEXIVE_ADAPT_TOKENS="${REFLEXIVE_ADAPT_TOKENS:-0}"
export REFLEXIVE_SPECULATE="${REFLEXIVE_SPECULATE:-0}"
export REFLEXIVE_SELF_MODEL="${REFLEXIVE_SELF_MODEL:-0}"
export REFLEXIVE_METACOG_LLM="${REFLEXIVE_METACOG_LLM:-0}"

# ── Tuning knobs ──────────────────────────────────────────────
export REFLEXIVE_SOUL_KEYWORDS="${REFLEXIVE_SOUL_KEYWORDS:-5}"
export REFLEXIVE_PROMPT_HISTORY="${REFLEXIVE_PROMPT_HISTORY:-8}"
export REFLEXIVE_TOKEN_FLOOR="${REFLEXIVE_TOKEN_FLOOR:-512}"
export REFLEXIVE_TOKEN_CEILING="${REFLEXIVE_TOKEN_CEILING:-8192}"
export REFLEXIVE_SPECULATE_BUDGET="${REFLEXIVE_SPECULATE_BUDGET:-3}"
export REFLEXIVE_METACOG_INTERVAL="${REFLEXIVE_METACOG_INTERVAL:-4}"

# ── Internal state ────────────────────────────────────────────
_REFLEXIVE_PROMPT_GRADES=()
_REFLEXIVE_TOKEN_HISTORY=()
_REFLEXIVE_LOOP_COUNTER=0
_REFLEXIVE_METACOG_STATE=""
_REFLEXIVE_SPECULATE_CACHE=""
_REFLEXIVE_SOUL_REJECTIONS=0
_REFLEXIVE_SPECULATE_HITS=0
_REFLEXIVE_SPECULATE_MISSES=0
_REFLEXIVE_TOTAL_COMMANDS=0
_REFLEXIVE_SESSION_START="${_REFLEXIVE_SESSION_START:-$(date +%s)}"
_REFLEXIVE_SAVE_COUNTER=0

# ── Persistence ───────────────────────────────────────────────
# Serialize internal state to $GEORGE_DIR/reflexive.json so
# learning data survives across sessions. Load on source,
# save on milestone events (debounced).

_reflexive_state_file() {
    echo "${GEORGE_DIR:-${GEORGE_CONFIG_DIR:-$HOME/.george}}/reflexive.json"
}

_reflexive_save_state() {
    local _sf
    _sf=$(_reflexive_state_file)
    local _dir
    _dir=$(dirname "$_sf")
    [ -d "$_dir" ] || return 0
    command -v jq &>/dev/null || return 0

    # Serialize arrays as JSON
    local _grades_json="[]"
    if [ "${#_REFLEXIVE_PROMPT_GRADES[@]}" -gt 0 ]; then
        _grades_json=$(printf '%s\n' "${_REFLEXIVE_PROMPT_GRADES[@]}" | jq -R . | jq -s .)
    fi
    local _tokens_json="[]"
    if [ "${#_REFLEXIVE_TOKEN_HISTORY[@]}" -gt 0 ]; then
        _tokens_json=$(printf '%s\n' "${_REFLEXIVE_TOKEN_HISTORY[@]}" | jq -R . | jq -s .)
    fi

    jq -n \
        --argjson grades "$_grades_json" \
        --argjson tokens "$_tokens_json" \
        --arg loop "$_REFLEXIVE_LOOP_COUNTER" \
        --arg metacog "$_REFLEXIVE_METACOG_STATE" \
        --arg rejections "$_REFLEXIVE_SOUL_REJECTIONS" \
        --arg spec_hits "$_REFLEXIVE_SPECULATE_HITS" \
        --arg spec_misses "$_REFLEXIVE_SPECULATE_MISSES" \
        --arg total_cmds "$_REFLEXIVE_TOTAL_COMMANDS" \
        --arg session_start "$_REFLEXIVE_SESSION_START" \
        --arg saved_at "$(date +%s)" \
        '{
            prompt_grades: $grades,
            token_history: $tokens,
            loop_counter: ($loop | tonumber),
            metacog_state: $metacog,
            soul_rejections: ($rejections | tonumber),
            speculate_hits: ($spec_hits | tonumber),
            speculate_misses: ($spec_misses | tonumber),
            total_commands: ($total_cmds | tonumber),
            session_start: ($session_start | tonumber),
            saved_at: ($saved_at | tonumber)
        }' > "$_sf" 2>/dev/null
}

_reflexive_load_state() {
    local _sf
    _sf=$(_reflexive_state_file)
    [ -f "$_sf" ] || return 0
    command -v jq &>/dev/null || return 0

    local _json
    _json=$(cat "$_sf" 2>/dev/null)
    [ -z "$_json" ] && return 0
    # Validate JSON
    echo "$_json" | jq -e . &>/dev/null || return 0

    # Restore arrays
    _REFLEXIVE_PROMPT_GRADES=()
    while IFS= read -r _entry; do
        [ -n "$_entry" ] && _REFLEXIVE_PROMPT_GRADES+=("$_entry")
    done < <(echo "$_json" | jq -r '.prompt_grades[]? // empty')

    _REFLEXIVE_TOKEN_HISTORY=()
    while IFS= read -r _entry; do
        [ -n "$_entry" ] && _REFLEXIVE_TOKEN_HISTORY+=("$_entry")
    done < <(echo "$_json" | jq -r '.token_history[]? // empty')

    _REFLEXIVE_LOOP_COUNTER=$(echo "$_json" | jq -r '.loop_counter // 0')
    _REFLEXIVE_METACOG_STATE=$(echo "$_json" | jq -r '.metacog_state // ""')
    _REFLEXIVE_SOUL_REJECTIONS=$(echo "$_json" | jq -r '.soul_rejections // 0')
    _REFLEXIVE_SPECULATE_HITS=$(echo "$_json" | jq -r '.speculate_hits // 0')
    _REFLEXIVE_SPECULATE_MISSES=$(echo "$_json" | jq -r '.speculate_misses // 0')
    _REFLEXIVE_TOTAL_COMMANDS=$(echo "$_json" | jq -r '.total_commands // 0')
    _REFLEXIVE_SESSION_START=$(echo "$_json" | jq -r '.session_start // 0')
    [ "$_REFLEXIVE_SESSION_START" -eq 0 ] && _REFLEXIVE_SESSION_START=$(date +%s)
}

# Debounced save — only writes every 5th call to avoid I/O churn
_reflexive_save_debounced() {
    _REFLEXIVE_SAVE_COUNTER=$((_REFLEXIVE_SAVE_COUNTER + 1))
    if [ $((_REFLEXIVE_SAVE_COUNTER % 5)) -eq 0 ]; then
        _reflexive_save_state
    fi
}

# Load persisted state on source
_reflexive_load_state


# ══════════════════════════════════════════════════════════════
# 1. SOUL CONSENSUS GATE
# ══════════════════════════════════════════════════════════════
# Before dispatching a specialist action, verify the plan aligns
# with the soul landmarks.  Extracts keyword signals from the
# proposed action and checks them against a condensed soul
# fingerprint.  Returns 0 if aligned, 1 if the plan should be
# softened or reconsidered.
#
# This is a LOCAL check — no LLM call.  Pure keyword/heuristic
# so it adds ~0 latency.
# ══════════════════════════════════════════════════════════════

# Build a soul fingerprint — set of alignment keywords from landmarks
_reflexive_soul_fingerprint() {
    # Static keywords derived from the 6 landmarks
    # Square (Mastery) + Gavel (Clarity) + 24-inch Gauge (Scope) +
    # Plumb (Validation) + Spectator's Honesty (Truth) + Trowel (Completion)
    echo "test build validate compile run explain clarify measure scope plan milestone memory recall journal finish complete"
}

# Check if a proposed action text aligns with soul values
# Returns 0 = aligned, 1 = misaligned
reflexive_soul_gate() {
    [ "${REFLEXIVE_SOUL_GATE:-0}" -eq 0 ] && return 0  # disabled → always pass

    local action_text="$1"
    [ -z "$action_text" ] && return 0

    local fingerprint
    fingerprint=$(_reflexive_soul_fingerprint)
    local action_lower
    action_lower=$(printf '%s' "$action_text" | tr '[:upper:]' '[:lower:]')

    # Anti-patterns: actions that violate soul principles
    # Spectator's Honesty: never fabricate
    # Plumb: never skip validation
    # Trowel: never abandon mid-task
    local violations=0
    local -a anti_patterns=(
        "skip test"
        "ignore error"
        "force push"
        "delete without"
        "overwrite blind"
        "rm -rf /"
        "fabricat"
        "hallucinate"
        "pretend"
    )

    local pattern
    for pattern in "${anti_patterns[@]}"; do
        if [[ "$action_lower" == *"$pattern"* ]]; then
            violations=$((violations + 1))
        fi
    done

    if [ "$violations" -gt 0 ]; then
        _REFLEXIVE_SOUL_REJECTIONS=$((_REFLEXIVE_SOUL_REJECTIONS + 1))
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] soul gate: %d violation(s) in proposed action\n' "$violations" >/dev/tty 2>/dev/null
        return 1
    fi

    # Positive alignment: does the action reference any soul keywords?
    local hits=0
    local keyword
    for keyword in $fingerprint; do
        if [[ "$action_lower" == *"$keyword"* ]]; then
            hits=$((hits + 1))
        fi
    done

    # If the action is generic (no soul keywords at all), that's fine —
    # we only block explicit violations.  Require at least 0 hits to pass.
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] soul gate: %d alignment hit(s), %d violation(s) → PASS\n' "$hits" "$violations" >/dev/tty 2>/dev/null
    return 0
}

# Format a soul-aligned recommendation when gate fails
reflexive_soul_recommend() {
    local action_text="$1"
    local action_lower
    action_lower=$(printf '%s' "$action_text" | tr '[:upper:]' '[:lower:]')

    if [[ "$action_lower" == *"skip test"* ]] || [[ "$action_lower" == *"ignore error"* ]]; then
        echo "The Plumb demands validation. Run the test or address the error before proceeding."
    elif [[ "$action_lower" == *"overwrite blind"* ]] || [[ "$action_lower" == *"delete without"* ]]; then
        echo "The Square demands mastery. Read before writing; confirm before destroying."
    elif [[ "$action_lower" == *"force push"* ]]; then
        echo "The Trowel demands completion. Ensure all work is tested before force-pushing."
    else
        echo "Review the proposed action against the soul landmarks before proceeding."
    fi
}


# ══════════════════════════════════════════════════════════════
# 2. SELF-IMPROVING PROMPTS
# ══════════════════════════════════════════════════════════════
# Tracks which prompt patterns lead to successful milestone
# completion vs. failure/retry loops.  Maintains a rolling
# grade history and surfaces "what worked" hints to the
# strategist prompt.
#
# No LLM call — pure bookkeeping + heuristic aggregation.
# ══════════════════════════════════════════════════════════════

# Record a prompt outcome: "success" or "retry" or "fail"
reflexive_prompt_record() {
    [ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 0 ] && return 0

    local outcome="$1"      # success | retry | fail
    local prompt_hint="$2"  # brief description of what was tried
    local ts
    ts=$(date +%s)

    _REFLEXIVE_PROMPT_GRADES+=("${ts}:${outcome}:${prompt_hint:0:80}")

    # Trim to rolling window
    local max="${REFLEXIVE_PROMPT_HISTORY:-8}"
    while [ "${#_REFLEXIVE_PROMPT_GRADES[@]}" -gt "$max" ]; do
        _REFLEXIVE_PROMPT_GRADES=("${_REFLEXIVE_PROMPT_GRADES[@]:1}")
    done
}

# Compute success rate from recent prompt history
reflexive_prompt_success_rate() {
    [ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 0 ] && echo "1.0" && return 0
    [ "${#_REFLEXIVE_PROMPT_GRADES[@]}" -eq 0 ] && echo "1.0" && return 0

    local successes=0 total=0
    local entry
    for entry in "${_REFLEXIVE_PROMPT_GRADES[@]}"; do
        local outcome
        outcome=$(printf '%s' "$entry" | cut -d: -f2)
        total=$((total + 1))
        [ "$outcome" = "success" ] && successes=$((successes + 1))
    done

    if [ "$total" -eq 0 ]; then
        echo "1.0"
    else
        # Bash integer math: express as X.Y where we scale by 100
        local pct=$((successes * 100 / total))
        printf '%d.%02d' "$((pct / 100))" "$((pct % 100))"
    fi
}

# Generate a hint string for the strategist based on recent outcomes
reflexive_prompt_hint() {
    [ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 0 ] && return 0
    [ "${#_REFLEXIVE_PROMPT_GRADES[@]}" -eq 0 ] && return 0

    local recent_fails=0 recent_successes=0
    local last_fail_hint=""
    local entry outcome hint
    for entry in "${_REFLEXIVE_PROMPT_GRADES[@]}"; do
        outcome=$(printf '%s' "$entry" | cut -d: -f2)
        hint=$(printf '%s' "$entry" | cut -d: -f3-)
        case "$outcome" in
            success) recent_successes=$((recent_successes + 1)) ;;
            fail|retry)
                recent_fails=$((recent_fails + 1))
                last_fail_hint="$hint"
                ;;
        esac
    done

    if [ "$recent_fails" -gt "$recent_successes" ] && [ -n "$last_fail_hint" ]; then
        echo "REFLEXIVE NOTE: Recent attempts have more failures than successes. Last failed approach: ${last_fail_hint}. Consider a different strategy."
    elif [ "$recent_fails" -gt 0 ] && [ -n "$last_fail_hint" ]; then
        echo "REFLEXIVE NOTE: Some recent retries detected. Approach that failed: ${last_fail_hint}."
    fi
}


# ══════════════════════════════════════════════════════════════
# 3. ADAPTIVE TOKEN BUDGETS
# ══════════════════════════════════════════════════════════════
# Observes actual token usage patterns and adjusts the budget
# for subsequent calls.  Simple tasks get smaller budgets
# (faster inference on edge devices); complex multi-step tasks
# get larger budgets.
#
# No LLM call — arithmetic on observed response lengths.
# ══════════════════════════════════════════════════════════════

# Record an observed response length (chars as proxy for tokens)
reflexive_tokens_observe() {
    [ "${REFLEXIVE_ADAPT_TOKENS:-0}" -eq 0 ] && return 0

    local response_chars="$1"
    _REFLEXIVE_TOKEN_HISTORY+=("$response_chars")

    # Keep rolling window of 10
    while [ "${#_REFLEXIVE_TOKEN_HISTORY[@]}" -gt 10 ]; do
        _REFLEXIVE_TOKEN_HISTORY=("${_REFLEXIVE_TOKEN_HISTORY[@]:1}")
    done
}

# Compute recommended token budget based on recent observations
# Returns an integer suitable for passing to llm_generate max_tokens
reflexive_tokens_recommend() {
    [ "${REFLEXIVE_ADAPT_TOKENS:-0}" -eq 0 ] && echo "${LLM_MAX_TOKENS:-4096}" && return 0
    [ "${#_REFLEXIVE_TOKEN_HISTORY[@]}" -eq 0 ] && echo "${LLM_MAX_TOKENS:-4096}" && return 0

    local sum=0 count=0 max_seen=0
    local val
    for val in "${_REFLEXIVE_TOKEN_HISTORY[@]}"; do
        sum=$((sum + val))
        count=$((count + 1))
        [ "$val" -gt "$max_seen" ] && max_seen="$val"
    done

    local avg=$((sum / count))

    # Rough chars→tokens: ~4 chars per token for English
    local avg_tokens=$((avg / 4))
    local max_tokens=$((max_seen / 4))

    # Budget = max of (avg * 1.5, max_seen * 1.2) with floor/ceiling
    local budget_a=$(( (avg_tokens * 3) / 2 ))    # avg * 1.5
    local budget_b=$(( (max_tokens * 6) / 5 ))    # max * 1.2
    local budget="$budget_a"
    [ "$budget_b" -gt "$budget" ] && budget="$budget_b"

    # Apply floor and ceiling
    local floor="${REFLEXIVE_TOKEN_FLOOR:-512}"
    local ceiling="${REFLEXIVE_TOKEN_CEILING:-8192}"
    [ "$budget" -lt "$floor" ] && budget="$floor"
    [ "$budget" -gt "$ceiling" ] && budget="$ceiling"

    # Thinking model multiplier
    if models_current_has_thinking 2>/dev/null; then
        budget=$((budget * 2))
        [ "$budget" -gt "$ceiling" ] && budget="$ceiling"
    fi

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] token budget: avg=%d max=%d → recommend=%d\n' "$avg_tokens" "$max_tokens" "$budget" >/dev/tty 2>/dev/null
    echo "$budget"
}


# ══════════════════════════════════════════════════════════════
# 4. SPECULATIVE PRE-FETCH
# ══════════════════════════════════════════════════════════════
# After the router selects a tool, predict what the NEXT likely
# tool will be and pre-fetch any slow data (web content, file
# reads, recall lookups) in the background so it's ready when
# the specialist needs it.
#
# Heuristic-only: no LLM call.  Uses a simple transition table
# learned from common command sequences.
# ══════════════════════════════════════════════════════════════

# Transition probability table: command → likely next command
# Format: "current_cmd:next_cmd"  (most common transitions)
_REFLEXIVE_TRANSITIONS=(
    "search:fetch"
    "fetch:write"
    "write:build"
    "build:test"
    "test:commit"
    "clone:build"
    "init:write"
    "vision:write"
    "download:build"
)

# Predict what comes after the current tool
reflexive_speculate_next() {
    [ "${REFLEXIVE_SPECULATE:-0}" -eq 0 ] && return 0

    local current_cmd="$1"
    local current_lower
    current_lower=$(printf '%s' "$current_cmd" | sed 's|^/||' | tr '[:upper:]' '[:lower:]')

    local entry
    for entry in "${_REFLEXIVE_TRANSITIONS[@]}"; do
        local from="${entry%%:*}"
        local to="${entry##*:}"
        if [ "$current_lower" = "$from" ]; then
            echo "$to"
            return 0
        fi
    done

    # No prediction available
    return 1
}

# Pre-fetch data for an anticipated command (background-safe).
# Writes to a temp file so results survive process boundaries
# (backgrounded & or $() subshells cannot propagate variables).
_reflexive_speculate_file() {
    echo "${GEORGE_DIR:-${GEORGE_CONFIG_DIR:-$HOME/.george}}/.speculate_cache"
}

reflexive_speculate_prefetch() {
    [ "${REFLEXIVE_SPECULATE:-0}" -eq 0 ] && return 0

    local predicted_cmd="$1"
    local workdir="${2:-.}"
    local _cache_file
    _cache_file=$(_reflexive_speculate_file)

    case "$predicted_cmd" in
        fetch)
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] speculate: pre-fetch hint for web fetch\n' >/dev/tty 2>/dev/null
            echo "prefetch_hint:web" > "$_cache_file" 2>/dev/null
            ;;
        build)
            if [ -f "$workdir/Makefile" ] || [ -f "$workdir/package.json" ] || [ -f "$workdir/Cargo.toml" ] || [ -f "$workdir/go.mod" ]; then
                echo "prefetch_hint:build_ready" > "$_cache_file" 2>/dev/null
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] speculate: build system detected in %s\n' "$workdir" >/dev/tty 2>/dev/null
            fi
            ;;
        test)
            if [ -d "$workdir/tests" ] || [ -d "$workdir/test" ] || [ -f "$workdir/pytest.ini" ] || [ -f "$workdir/jest.config.js" ]; then
                echo "prefetch_hint:test_ready" > "$_cache_file" 2>/dev/null
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] speculate: test infra detected in %s\n' "$workdir" >/dev/tty 2>/dev/null
            fi
            ;;
        *)
            rm -f "$_cache_file" 2>/dev/null
            ;;
    esac
}

# Retrieve cached speculation result and clear it
reflexive_speculate_consume() {
    local _cache_file
    _cache_file=$(_reflexive_speculate_file)
    if [ -f "$_cache_file" ]; then
        local cache
        cache=$(cat "$_cache_file" 2>/dev/null)
        rm -f "$_cache_file" 2>/dev/null
        if [ -n "$cache" ]; then
            _REFLEXIVE_SPECULATE_HITS=$((_REFLEXIVE_SPECULATE_HITS + 1))
        fi
        echo "$cache"
    else
        _REFLEXIVE_SPECULATE_MISSES=$((_REFLEXIVE_SPECULATE_MISSES + 1))
    fi
}


# ══════════════════════════════════════════════════════════════
# 5. SELF-MODEL (METACOGNITION)
# ══════════════════════════════════════════════════════════════
# Periodically (every N inner-loop iterations) George generates
# a brief self-assessment: am I stuck? am I making progress?
# am I repeating myself?  This is the only subsystem that MAY
# issue an LLM call (a tiny ~100-token self-check), but only
# when the operator opts in AND only at the configured interval.
#
# On 4B models: OFF by default.  Even when enabled, the self-
# check uses minimal tokens and a tightly constrained prompt.
# ══════════════════════════════════════════════════════════════

# Increment the loop counter and check if it's time for a metacog check
reflexive_metacog_tick() {
    [ "${REFLEXIVE_SELF_MODEL:-0}" -eq 0 ] && return 1

    _REFLEXIVE_LOOP_COUNTER=$((_REFLEXIVE_LOOP_COUNTER + 1))
    local interval="${REFLEXIVE_METACOG_INTERVAL:-4}"

    if [ $((_REFLEXIVE_LOOP_COUNTER % interval)) -eq 0 ]; then
        return 0  # time for a check
    fi
    return 1  # not yet
}

# Generate a metacognitive self-assessment.
# Phase 1 (always): heuristic check — zero-latency, pure arithmetic.
# Phase 2 (opt-in): LLM self-assessment — tiny ~150 token call,
#   gated by REFLEXIVE_METACOG_LLM=1 AND available llm_generate.
reflexive_metacog_assess() {
    [ "${REFLEXIVE_SELF_MODEL:-0}" -eq 0 ] && return 0

    local assessment=""
    local loop_count="$_REFLEXIVE_LOOP_COUNTER"

    # ── Phase 1: Heuristic assessment (always runs) ────────
    # Check for stuck loops (high retry count)
    if [ "$loop_count" -gt 12 ]; then
        assessment="WARNING: High iteration count ($loop_count). Possible stuck loop."
    elif [ "$loop_count" -gt 8 ]; then
        assessment="NOTICE: Elevated iteration count ($loop_count). Monitor for progress."
    fi

    # Check prompt success rate
    if [ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 1 ] && [ "${#_REFLEXIVE_PROMPT_GRADES[@]}" -gt 2 ]; then
        local rate
        rate=$(reflexive_prompt_success_rate)
        local rate_int="${rate%%.*}"
        if [ "${rate_int:-1}" -eq 0 ]; then
            local rate_frac="${rate##*.}"
            if [ "${rate_frac:-100}" -lt 40 ]; then
                assessment="${assessment:+$assessment | }LOW SUCCESS RATE: Most recent prompts are failing. Strategy change recommended."
            fi
        fi
    fi

    # Check for repetitive actions in prompt history
    if [ "${#_REFLEXIVE_PROMPT_GRADES[@]}" -ge 3 ]; then
        local last3=("${_REFLEXIVE_PROMPT_GRADES[@]: -3}")
        local last_hints=()
        local entry
        for entry in "${last3[@]}"; do
            last_hints+=("$(printf '%s' "$entry" | cut -d: -f3-)")
        done
        if [ "${last_hints[0]}" = "${last_hints[1]}" ] && [ "${last_hints[1]}" = "${last_hints[2]}" ]; then
            assessment="${assessment:+$assessment | }REPETITION: Last 3 attempts used identical approach. Break the cycle."
        fi
    fi

    if [ -z "$assessment" ]; then
        assessment="OK: Progress appears normal after $loop_count iterations."
    fi

    # ── Phase 2: LLM self-assessment (opt-in) ──────────────
    if [ "${REFLEXIVE_METACOG_LLM:-0}" -eq 1 ] && declare -f llm_generate &>/dev/null; then
        local _mc_grades=""
        if [ "${#_REFLEXIVE_PROMPT_GRADES[@]}" -gt 0 ]; then
            _mc_grades=$(printf '%s\n' "${_REFLEXIVE_PROMPT_GRADES[@]: -5}")
        fi
        local _mc_prompt="Iteration: ${loop_count}\nHeuristic assessment: ${assessment}\nRecent prompt grades:\n${_mc_grades:-none}"
        local _mc_sys="You are George's metacognition module. Given the iteration count, heuristic assessment, and recent prompt grades, respond with JSON: {\"stuck\":true/false, \"progress\":\"none\"|\"slow\"|\"normal\"|\"regressing\", \"assessment\":\"2-3 sentence analysis\"}. Be brutally honest."
        local _mc_result
        local LLM_SCENARIO=evaluator
        _mc_result=$(llm_generate "$_mc_prompt" "$_mc_sys" 256 256 "metacog" 2>/dev/null)
        if [ -n "$_mc_result" ]; then
            # Layer 2: try structured JSON extraction
            local _mc_json
            if declare -f _agent_extract_json &>/dev/null && _mc_json=$(_agent_extract_json "$_mc_result" "stuck" "progress" "assessment"); then
                local _mc_stuck _mc_progress _mc_assess_text
                _mc_stuck=$(echo "$_mc_json" | jq -r '.stuck // false')
                _mc_progress=$(echo "$_mc_json" | jq -r '.progress // "normal"')
                _mc_assess_text=$(echo "$_mc_json" | jq -r '.assessment // empty')
                assessment="${assessment} | LLM: stuck=${_mc_stuck} progress=${_mc_progress} ${_mc_assess_text}"
            else
                # Layer 3: fallback to raw text cleanup
                _mc_result=$(echo "$_mc_result" | head -4 | tr '\n' ' ')
                assessment="${assessment} | LLM: ${_mc_result}"
            fi
        fi
    fi

    _REFLEXIVE_METACOG_STATE="$assessment"
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] metacog: %s\n' "$assessment" >/dev/tty 2>/dev/null
    echo "$assessment"
}

# Get current metacog state without re-assessing
reflexive_metacog_state() {
    echo "${_REFLEXIVE_METACOG_STATE:-OK}"
}

# Reset metacog state (call at milestone boundaries)
reflexive_metacog_reset() {
    _REFLEXIVE_LOOP_COUNTER=0
    _REFLEXIVE_METACOG_STATE=""
    _REFLEXIVE_SPECULATE_CACHE=""
    # Clean up stale speculation cache file
    local _sf
    _sf=$(_reflexive_speculate_file 2>/dev/null)
    [ -n "$_sf" ] && rm -f "$_sf" 2>/dev/null
}


# ══════════════════════════════════════════════════════════════
# UNIFIED HOOKS
# ══════════════════════════════════════════════════════════════
# Single entry points for the agent loop to call at key moments.
# Each hook checks which subsystems are enabled and orchestrates
# the appropriate calls.
# ══════════════════════════════════════════════════════════════

# Hook: called before router dispatch (Phase 1)
# Runs: metacog tick, speculative consume
# Returns context string to inject into router prompt (may be empty)
reflexive_pre_route() {
    local objective="${1:-}"
    local context=""

    # Metacog tick
    if reflexive_metacog_tick; then
        local assessment
        assessment=$(reflexive_metacog_assess)
        [ -n "$assessment" ] && [ "$assessment" != "OK"* ] && context="[REFLEXIVE] $assessment"
    fi

    # Consume any speculative pre-fetch result from previous iteration
    if [ "${REFLEXIVE_SPECULATE:-0}" -eq 1 ]; then
        local cache
        cache=$(reflexive_speculate_consume)
        if [ -n "$cache" ]; then
            context="${context:+$context | }[SPECULATE] $cache"
        fi
    fi

    # Prompt learning hint
    if [ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 1 ]; then
        local hint
        hint=$(reflexive_prompt_hint)
        [ -n "$hint" ] && context="${context:+$context | }$hint"
    fi

    if [ -n "$context" ]; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] pre-route inject: %s\n' "${context:0:120}" >/dev/tty 2>/dev/null
        declare -f transcript_log &>/dev/null && transcript_log "reflexive:pre-route" "$context"
    fi

    echo "$context"
}

# Hook: called after router selects a tool (post-Phase 1)
# Runs: soul gate check, speculative pre-fetch for next tool
# Returns 0 if action is approved, 1 if soul gate rejects
reflexive_post_route() {
    local selected_tool="$1"
    local action_text="${2:-}"
    local workdir="${3:-.}"

    # Soul consensus gate
    if [ "${REFLEXIVE_SOUL_GATE:-0}" -eq 1 ]; then
        if ! reflexive_soul_gate "$action_text"; then
            local rec
            rec=$(reflexive_soul_recommend "$action_text")
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] soul gate REJECTED: %s\n' "$rec" >/dev/tty 2>/dev/null
            declare -f transcript_log &>/dev/null && transcript_log "reflexive:soul-gate" "REJECTED /$selected_tool — $rec"
            return 1
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] soul gate APPROVED: /%s\n' "$selected_tool" >/dev/tty 2>/dev/null
    fi

    # Speculative pre-fetch for predicted next tool
    if [ "${REFLEXIVE_SPECULATE:-0}" -eq 1 ]; then
        local predicted
        predicted=$(reflexive_speculate_next "$selected_tool")
        if [ -n "$predicted" ]; then
            reflexive_speculate_prefetch "$predicted" "$workdir" &
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] speculate: prefetch /%s (background)\n' "$predicted" >/dev/tty 2>/dev/null
            declare -f transcript_log &>/dev/null && transcript_log "reflexive:speculate" "prefetch /$predicted for /$selected_tool"
        fi
    fi

    return 0
}

# Hook: called after command execution, before evaluator
# Runs: token observation, prompt grading, save debounce
reflexive_post_execute() {
    local response="$1"
    local exit_code="${2:-0}"
    local prompt_hint="${3:-}"

    _REFLEXIVE_TOTAL_COMMANDS=$((_REFLEXIVE_TOTAL_COMMANDS + 1))

    # Observe response size for token budgeting
    if [ "${REFLEXIVE_ADAPT_TOKENS:-0}" -eq 1 ]; then
        local char_count=${#response}
        reflexive_tokens_observe "$char_count"
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] post-execute: observed %d chars\n' "$char_count" >/dev/tty 2>/dev/null
    fi

    # Record prompt outcome for self-improving prompts
    if [ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 1 ]; then
        if [ "$exit_code" -eq 0 ]; then
            reflexive_prompt_record "success" "$prompt_hint"
        else
            reflexive_prompt_record "retry" "$prompt_hint"
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] prompt-learn: exit=%d hint=%s\n' "$exit_code" "${prompt_hint:0:60}" >/dev/tty 2>/dev/null
    fi

    declare -f transcript_log &>/dev/null && transcript_log "reflexive:post-execute" "cmd=$_REFLEXIVE_TOTAL_COMMANDS exit=$exit_code chars=${#response}"

    # Debounced persistence
    _reflexive_save_debounced
}

# Hook: called when a milestone completes
# Runs: prompt success recording, metacog reset, persist
reflexive_milestone_complete() {
    local milestone="${1:-}"

    # Record final success for prompt learning
    if [ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 1 ]; then
        reflexive_prompt_record "success" "milestone:${milestone:0:40}"
    fi

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] milestone COMPLETE: %s (cmds=%d loops=%d rejections=%d)\n' "${milestone:0:60}" "$_REFLEXIVE_TOTAL_COMMANDS" "$_REFLEXIVE_LOOP_COUNTER" "$_REFLEXIVE_SOUL_REJECTIONS" >/dev/tty 2>/dev/null
    declare -f transcript_log &>/dev/null && transcript_log "reflexive:milestone" "COMPLETE: ${milestone:0:60} cmds=$_REFLEXIVE_TOTAL_COMMANDS loops=$_REFLEXIVE_LOOP_COUNTER"

    # Reset metacog for fresh milestone
    reflexive_metacog_reset
    # Force save on milestone boundary
    _reflexive_save_state
}

# Hook: called when a milestone fails / retries exhausted
reflexive_milestone_fail() {
    local milestone="${1:-}"

    if [ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 1 ]; then
        reflexive_prompt_record "fail" "milestone:${milestone:0:40}"
    fi

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] milestone FAILED: %s (cmds=%d loops=%d rejections=%d)\n' "${milestone:0:60}" "$_REFLEXIVE_TOTAL_COMMANDS" "$_REFLEXIVE_LOOP_COUNTER" "$_REFLEXIVE_SOUL_REJECTIONS" >/dev/tty 2>/dev/null
    declare -f transcript_log &>/dev/null && transcript_log "reflexive:milestone" "FAILED: ${milestone:0:60} cmds=$_REFLEXIVE_TOTAL_COMMANDS loops=$_REFLEXIVE_LOOP_COUNTER"

    reflexive_metacog_reset
    # Force save on milestone boundary
    _reflexive_save_state
}


# ══════════════════════════════════════════════════════════════
# REPL TOGGLE INTERFACE
# ══════════════════════════════════════════════════════════════
# Called from the REPL to enable/disable subsystems at runtime.
# Usage: reflexive_toggle <subsystem> [on|off]
# ══════════════════════════════════════════════════════════════

reflexive_toggle() {
    local subsystem="$1"
    local state="${2:-}"

    # Map subsystem name to variable
    local var_name=""
    case "$subsystem" in
        soul|soul_gate|soul-gate)       var_name="REFLEXIVE_SOUL_GATE" ;;
        prompt|prompt_learn|prompt-learn) var_name="REFLEXIVE_PROMPT_LEARN" ;;
        tokens|adapt_tokens|adapt-tokens) var_name="REFLEXIVE_ADAPT_TOKENS" ;;
        speculate|prefetch|pre-fetch)    var_name="REFLEXIVE_SPECULATE" ;;
        metacog|self_model|self-model)   var_name="REFLEXIVE_SELF_MODEL" ;;
        metacog-llm|metacog_llm|llm)     var_name="REFLEXIVE_METACOG_LLM" ;;
        all)
            # Toggle all at once
            local target="${state:-on}"
            local val=1
            [ "$target" = "off" ] && val=0
            export REFLEXIVE_SOUL_GATE="$val"
            export REFLEXIVE_PROMPT_LEARN="$val"
            export REFLEXIVE_ADAPT_TOKENS="$val"
            export REFLEXIVE_SPECULATE="$val"
            export REFLEXIVE_SELF_MODEL="$val"
            export REFLEXIVE_METACOG_LLM="$val"
            printf 'Reflexive: ALL subsystems %s\n' "$target"
            return 0
            ;;
        *)
            printf 'Unknown reflexive subsystem: %s\n' "$subsystem"
            printf 'Available: soul, prompt, tokens, speculate, metacog, metacog-llm, all\n'
            return 1
            ;;
    esac

    if [ -z "$state" ]; then
        # Toggle: flip current state
        local current
        eval "current=\${$var_name:-0}"
        if [ "$current" -eq 0 ]; then
            export "$var_name=1"
            printf 'Reflexive %s: ON\n' "$subsystem"
        else
            export "$var_name=0"
            printf 'Reflexive %s: OFF\n' "$subsystem"
        fi
    elif [ "$state" = "on" ] || [ "$state" = "1" ]; then
        export "$var_name=1"
        printf 'Reflexive %s: ON\n' "$subsystem"
    elif [ "$state" = "off" ] || [ "$state" = "0" ]; then
        export "$var_name=0"
        printf 'Reflexive %s: OFF\n' "$subsystem"
    else
        printf 'Usage: reflexive_toggle %s [on|off]\n' "$subsystem"
        return 1
    fi
}

# Print current status of all subsystems
reflexive_status() {
    local _on="${_T_GREEN:-}ON${_T_RESET:-}"
    local _off="${_T_DIM:-}OFF${_T_RESET:-}"

    printf 'Reflexive Intelligence Layer\n'
    printf '\n'
    printf '  ── Subsystems ──\n'
    printf '  Soul Gate:      %b\n' "$([ "${REFLEXIVE_SOUL_GATE:-0}" -eq 1 ] && echo "$_on" || echo "$_off")"
    printf '  Prompt Learn:   %b\n' "$([ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 1 ] && echo "$_on" || echo "$_off")"
    printf '  Adapt Tokens:   %b\n' "$([ "${REFLEXIVE_ADAPT_TOKENS:-0}" -eq 1 ] && echo "$_on" || echo "$_off")"
    printf '  Speculative:    %b\n' "$([ "${REFLEXIVE_SPECULATE:-0}" -eq 1 ] && echo "$_on" || echo "$_off")"
    printf '  Self-Model:     %b\n' "$([ "${REFLEXIVE_SELF_MODEL:-0}" -eq 1 ] && echo "$_on" || echo "$_off")"
    printf '  Metacog LLM:    %b\n' "$([ "${REFLEXIVE_METACOG_LLM:-0}" -eq 1 ] && echo "$_on" || echo "$_off")"

    printf '\n'
    printf '  ── Tuning Knobs ──\n'
    printf '  Soul Keywords:      %d  (1-20)\n' "${REFLEXIVE_SOUL_KEYWORDS:-5}"
    printf '  Prompt History:     %d  (1-50)\n' "${REFLEXIVE_PROMPT_HISTORY:-8}"
    printf '  Token Floor:        %d  (128-32768)\n' "${REFLEXIVE_TOKEN_FLOOR:-512}"
    printf '  Token Ceiling:      %d  (512-65536)\n' "${REFLEXIVE_TOKEN_CEILING:-8192}"
    printf '  Speculate Budget:   %d  (1-10)\n' "${REFLEXIVE_SPECULATE_BUDGET:-3}"
    printf '  Metacog Interval:   %d  (1-20)\n' "${REFLEXIVE_METACOG_INTERVAL:-4}"

    printf '\n'
    printf '  ── Session Metrics ──\n'
    # Session duration
    local _now
    _now=$(date +%s)
    local _elapsed=$((_now - _REFLEXIVE_SESSION_START))
    local _mins=$((_elapsed / 60))
    local _secs=$((_elapsed % 60))
    printf '  Session Duration:   %dm %ds\n' "$_mins" "$_secs"
    printf '  Total Commands:     %d\n' "$_REFLEXIVE_TOTAL_COMMANDS"
    printf '  Loop Counter:       %d\n' "$_REFLEXIVE_LOOP_COUNTER"

    if [ "${#_REFLEXIVE_PROMPT_GRADES[@]}" -gt 0 ]; then
        printf '  Success Rate:       %s (%d samples)\n' "$(reflexive_prompt_success_rate)" "${#_REFLEXIVE_PROMPT_GRADES[@]}"
        # Trend indicator
        if [ "${#_REFLEXIVE_PROMPT_GRADES[@]}" -ge 4 ]; then
            local _recent_ok=0 _recent_total=0 _older_ok=0 _older_total=0
            local _half=$(( ${#_REFLEXIVE_PROMPT_GRADES[@]} / 2 ))
            local _i=0 _entry _outcome
            for _entry in "${_REFLEXIVE_PROMPT_GRADES[@]}"; do
                _outcome=$(printf '%s' "$_entry" | cut -d: -f2)
                if [ "$_i" -lt "$_half" ]; then
                    _older_total=$((_older_total + 1))
                    [ "$_outcome" = "success" ] && _older_ok=$((_older_ok + 1))
                else
                    _recent_total=$((_recent_total + 1))
                    [ "$_outcome" = "success" ] && _recent_ok=$((_recent_ok + 1))
                fi
                _i=$((_i + 1))
            done
            local _trend="stable"
            if [ "$_older_total" -gt 0 ] && [ "$_recent_total" -gt 0 ]; then
                local _older_pct=$((_older_ok * 100 / _older_total))
                local _recent_pct=$((_recent_ok * 100 / _recent_total))
                if [ "$_recent_pct" -gt $((_older_pct + 15)) ]; then
                    _trend="improving"
                elif [ "$_recent_pct" -lt $((_older_pct - 15)) ]; then
                    _trend="declining"
                fi
            fi
            printf '  Prompt Trend:       %s\n' "$_trend"
        fi
    fi
    if [ "${#_REFLEXIVE_TOKEN_HISTORY[@]}" -gt 0 ]; then
        printf '  Token Budget:       %s (recommended)\n' "$(reflexive_tokens_recommend)"
    fi
    printf '  Soul Rejections:    %d\n' "$_REFLEXIVE_SOUL_REJECTIONS"
    if [ "$((_REFLEXIVE_SPECULATE_HITS + _REFLEXIVE_SPECULATE_MISSES))" -gt 0 ]; then
        printf '  Speculation:        %d hits / %d misses\n' "$_REFLEXIVE_SPECULATE_HITS" "$_REFLEXIVE_SPECULATE_MISSES"
    fi
    printf '  Metacog State:      %s\n' "$(reflexive_metacog_state)"
}

# Generate a deep analysis report with optional LLM summary
reflexive_report() {
    local report=""
    report+="══════════════════════════════════════════════════════════════\n"
    report+="REFLEXIVE INTELLIGENCE — SESSION REPORT\n"
    report+="══════════════════════════════════════════════════════════════\n\n"

    # Session info
    local _now
    _now=$(date +%s)
    local _elapsed=$((_now - _REFLEXIVE_SESSION_START))
    report+="Session Start:   $(date -d "@$_REFLEXIVE_SESSION_START" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$_REFLEXIVE_SESSION_START" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$_REFLEXIVE_SESSION_START")\n"
    report+="Duration:        $((_elapsed / 60))m $((_elapsed % 60))s\n"
    report+="Total Commands:  $_REFLEXIVE_TOTAL_COMMANDS\n"
    report+="Loop Iterations: $_REFLEXIVE_LOOP_COUNTER\n\n"

    # Subsystem states
    report+="── Subsystem States ──\n"
    report+="  Soul Gate:    $([ "${REFLEXIVE_SOUL_GATE:-0}" -eq 1 ] && echo ON || echo OFF)  (rejections: $_REFLEXIVE_SOUL_REJECTIONS)\n"
    report+="  Prompt Learn: $([ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 1 ] && echo ON || echo OFF)  (samples: ${#_REFLEXIVE_PROMPT_GRADES[@]})\n"
    report+="  Adapt Tokens: $([ "${REFLEXIVE_ADAPT_TOKENS:-0}" -eq 1 ] && echo ON || echo OFF)  (observations: ${#_REFLEXIVE_TOKEN_HISTORY[@]})\n"
    report+="  Speculative:  $([ "${REFLEXIVE_SPECULATE:-0}" -eq 1 ] && echo ON || echo OFF)  (hits: $_REFLEXIVE_SPECULATE_HITS, misses: $_REFLEXIVE_SPECULATE_MISSES)\n"
    report+="  Self-Model:   $([ "${REFLEXIVE_SELF_MODEL:-0}" -eq 1 ] && echo ON || echo OFF)  (interval: ${REFLEXIVE_METACOG_INTERVAL:-4})\n"
    report+="  Metacog LLM:  $([ "${REFLEXIVE_METACOG_LLM:-0}" -eq 1 ] && echo ON || echo OFF)\n\n"

    # Prompt learning details
    if [ "${#_REFLEXIVE_PROMPT_GRADES[@]}" -gt 0 ]; then
        report+="── Prompt Learning ──\n"
        report+="  Success Rate: $(reflexive_prompt_success_rate)\n"
        report+="  Recent Grades:\n"
        local _entry
        for _entry in "${_REFLEXIVE_PROMPT_GRADES[@]}"; do
            local _ts _outcome _hint
            _ts=$(printf '%s' "$_entry" | cut -d: -f1)
            _outcome=$(printf '%s' "$_entry" | cut -d: -f2)
            _hint=$(printf '%s' "$_entry" | cut -d: -f3-)
            local _time_str
            _time_str=$(date -d "@$_ts" '+%H:%M:%S' 2>/dev/null || date -r "$_ts" '+%H:%M:%S' 2>/dev/null || echo "$_ts")
            report+="    [$_time_str] $_outcome: $_hint\n"
        done
        report+="\n"
    fi

    # Token budget details
    if [ "${#_REFLEXIVE_TOKEN_HISTORY[@]}" -gt 0 ]; then
        report+="── Token Budget ──\n"
        report+="  Recommended: $(reflexive_tokens_recommend)\n"
        report+="  Floor: ${REFLEXIVE_TOKEN_FLOOR:-512}  Ceiling: ${REFLEXIVE_TOKEN_CEILING:-8192}\n"
        local _sum=0 _count=0 _max=0 _val
        for _val in "${_REFLEXIVE_TOKEN_HISTORY[@]}"; do
            _sum=$((_sum + _val))
            _count=$((_count + 1))
            [ "$_val" -gt "$_max" ] && _max="$_val"
        done
        report+="  Avg Response: $((_sum / _count)) chars  Max: $_max chars\n\n"
    fi

    # Metacog state
    report+="── Metacognition ──\n"
    report+="  Current State: $(reflexive_metacog_state)\n\n"

    # Tuning knobs
    report+="── Current Tuning ──\n"
    report+="  soul-keywords=${REFLEXIVE_SOUL_KEYWORDS:-5}  prompt-history=${REFLEXIVE_PROMPT_HISTORY:-8}\n"
    report+="  token-floor=${REFLEXIVE_TOKEN_FLOOR:-512}  token-ceiling=${REFLEXIVE_TOKEN_CEILING:-8192}\n"
    report+="  speculate-budget=${REFLEXIVE_SPECULATE_BUDGET:-3}  metacog-interval=${REFLEXIVE_METACOG_INTERVAL:-4}\n\n"

    # LLM analysis
    if declare -f llm_generate &>/dev/null; then
        declare -f ui_spinner_start &>/dev/null && ui_spinner_start "Analyzing" >/dev/tty 2>/dev/null
        local _analysis_prompt="Analyze this self-monitoring report from an AI agent named George:\n\n${report}\n\nSummarize patterns, flag concerns, and suggest optimizations for the tuning knobs. Be concise and focused."
        local _analysis_sys="You are analyzing the self-monitoring telemetry of an AI agent. Focus on actionable insights: Is the agent performing well? Are there efficiency problems? What tuning changes would help? Plain text, no markdown."
        local _analysis
        local LLM_SCENARIO=evaluator
        _analysis=$(llm_generate "$_analysis_prompt" "$_analysis_sys" 512 512 2>/dev/null)
        declare -f ui_spinner_stop &>/dev/null && ui_spinner_stop 2>/dev/null
        if [ -n "$_analysis" ]; then
            # Strip think blocks if present
            declare -f _strip_think_blocks &>/dev/null && _analysis=$(echo "$_analysis" | _strip_think_blocks)
            _analysis=$(echo "$_analysis" | sed 's/\*\+//g' | head -8)
            report+="── Analysis ──\n"
            report+="$_analysis\n"
        fi
    fi

    report+="\n══════════════════════════════════════════════════════════════\n"
    printf '%b' "$report"
}
