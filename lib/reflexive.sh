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

# Pre-fetch data for an anticipated command (background-safe)
# Stores result in _REFLEXIVE_SPECULATE_CACHE
reflexive_speculate_prefetch() {
    [ "${REFLEXIVE_SPECULATE:-0}" -eq 0 ] && return 0

    local predicted_cmd="$1"
    local workdir="${2:-.}"

    case "$predicted_cmd" in
        fetch)
            # Pre-warm: check if there's a URL in recent context
            # This is speculative — if no URL is found, it's a no-op
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] speculate: pre-fetch hint for web fetch\n' >/dev/tty 2>/dev/null
            _REFLEXIVE_SPECULATE_CACHE="prefetch_hint:web"
            ;;
        build)
            # Pre-check: look for build files
            if [ -f "$workdir/Makefile" ] || [ -f "$workdir/package.json" ] || [ -f "$workdir/Cargo.toml" ] || [ -f "$workdir/go.mod" ]; then
                _REFLEXIVE_SPECULATE_CACHE="prefetch_hint:build_ready"
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] speculate: build system detected in %s\n' "$workdir" >/dev/tty 2>/dev/null
            fi
            ;;
        test)
            # Pre-check: look for test infrastructure
            if [ -d "$workdir/tests" ] || [ -d "$workdir/test" ] || [ -f "$workdir/pytest.ini" ] || [ -f "$workdir/jest.config.js" ]; then
                _REFLEXIVE_SPECULATE_CACHE="prefetch_hint:test_ready"
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [reflexive] speculate: test infra detected in %s\n' "$workdir" >/dev/tty 2>/dev/null
            fi
            ;;
        *)
            _REFLEXIVE_SPECULATE_CACHE=""
            ;;
    esac
}

# Retrieve cached speculation result and clear it
reflexive_speculate_consume() {
    local cache="$_REFLEXIVE_SPECULATE_CACHE"
    _REFLEXIVE_SPECULATE_CACHE=""
    echo "$cache"
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

# Generate a metacognitive self-assessment (heuristic, no LLM)
# Examines recent prompt grades, token usage, and loop count
# to produce a status string
reflexive_metacog_assess() {
    [ "${REFLEXIVE_SELF_MODEL:-0}" -eq 0 ] && return 0

    local assessment=""
    local loop_count="$_REFLEXIVE_LOOP_COUNTER"

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
        # Compare as integer (rate is like "0.50" → extract before dot)
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
            return 1
        fi
    fi

    # Speculative pre-fetch for predicted next tool
    if [ "${REFLEXIVE_SPECULATE:-0}" -eq 1 ]; then
        local predicted
        predicted=$(reflexive_speculate_next "$selected_tool")
        if [ -n "$predicted" ]; then
            reflexive_speculate_prefetch "$predicted" "$workdir" &
        fi
    fi

    return 0
}

# Hook: called after command execution, before evaluator
# Runs: token observation, prompt grading
reflexive_post_execute() {
    local response="$1"
    local exit_code="${2:-0}"
    local prompt_hint="${3:-}"

    # Observe response size for token budgeting
    if [ "${REFLEXIVE_ADAPT_TOKENS:-0}" -eq 1 ]; then
        local char_count=${#response}
        reflexive_tokens_observe "$char_count"
    fi

    # Record prompt outcome for self-improving prompts
    if [ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 1 ]; then
        if [ "$exit_code" -eq 0 ]; then
            reflexive_prompt_record "success" "$prompt_hint"
        else
            reflexive_prompt_record "retry" "$prompt_hint"
        fi
    fi
}

# Hook: called when a milestone completes
# Runs: prompt success recording, metacog reset
reflexive_milestone_complete() {
    local milestone="${1:-}"

    # Record final success for prompt learning
    if [ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 1 ]; then
        reflexive_prompt_record "success" "milestone:${milestone:0:40}"
    fi

    # Reset metacog for fresh milestone
    reflexive_metacog_reset
}

# Hook: called when a milestone fails / retries exhausted
reflexive_milestone_fail() {
    local milestone="${1:-}"

    if [ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 1 ]; then
        reflexive_prompt_record "fail" "milestone:${milestone:0:40}"
    fi

    reflexive_metacog_reset
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
            printf 'Reflexive: ALL subsystems %s\n' "$target"
            return 0
            ;;
        *)
            printf 'Unknown reflexive subsystem: %s\n' "$subsystem"
            printf 'Available: soul, prompt, tokens, speculate, metacog, all\n'
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
    printf '  Soul Gate:      %b\n' "$([ "${REFLEXIVE_SOUL_GATE:-0}" -eq 1 ] && echo "$_on" || echo "$_off")"
    printf '  Prompt Learn:   %b\n' "$([ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 1 ] && echo "$_on" || echo "$_off")"
    printf '  Adapt Tokens:   %b\n' "$([ "${REFLEXIVE_ADAPT_TOKENS:-0}" -eq 1 ] && echo "$_on" || echo "$_off")"
    printf '  Speculative:    %b\n' "$([ "${REFLEXIVE_SPECULATE:-0}" -eq 1 ] && echo "$_on" || echo "$_off")"
    printf '  Self-Model:     %b\n' "$([ "${REFLEXIVE_SELF_MODEL:-0}" -eq 1 ] && echo "$_on" || echo "$_off")"

    if [ "${REFLEXIVE_PROMPT_LEARN:-0}" -eq 1 ] && [ "${#_REFLEXIVE_PROMPT_GRADES[@]}" -gt 0 ]; then
        printf '  Success Rate:   %s (%d samples)\n' "$(reflexive_prompt_success_rate)" "${#_REFLEXIVE_PROMPT_GRADES[@]}"
    fi
    if [ "${REFLEXIVE_ADAPT_TOKENS:-0}" -eq 1 ] && [ "${#_REFLEXIVE_TOKEN_HISTORY[@]}" -gt 0 ]; then
        printf '  Token Budget:   %s (recommended)\n' "$(reflexive_tokens_recommend)"
    fi
    printf '  Loop Counter:   %d\n' "$_REFLEXIVE_LOOP_COUNTER"
    printf '  Metacog State:  %s\n' "$(reflexive_metacog_state)"
}
