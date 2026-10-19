#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  lib/core/react_advisor.sh — Stuck-loop advisor (Refinement P2.6)
# ═══════════════════════════════════════════════════════════════════════
#  When the loop is stuck (circuit-breaker trip, evaluator BLOCKED, or two
#  INCOMPLETE verdicts on the same step) one grammar-constrained call
#  diagnoses the situation and proposes a concrete next action:
#
#    {diagnosis, next_tool, args_hint, abandon_step}
#
#  Budgets: ≤1 consult per step, ≤3 per run, hard 45 s cap per consult.
#  Replaces the temperature-0.7 / 3-second "perturbation" calls that
#  almost always timed out and fell through to a static catalog.
#
#  Public API
#    react_advise <session_dir> <step_id> <step_task> <goal> <trigger> <tools_csv>
#        → prints the advisor JSON object; non-zero when budget exhausted
#    react_advise_render <json>   → steering message for the model
# ═══════════════════════════════════════════════════════════════════════

[ -n "${_REACT_ADVISOR_LOADED:-}" ] && return 0
_REACT_ADVISOR_LOADED=1
source "${LODGE_DIR:-$HOME/blue-lodge}/lib/core/react_evaluator.sh" 2>/dev/null || true

REACT_ADVISOR_MAX_PER_RUN="${REACT_ADVISOR_MAX_PER_RUN:-3}"
REACT_ADVISOR_TIMEOUT="${REACT_ADVISOR_TIMEOUT:-45}"

_react_advisor_gbnf() {
    local tools_csv="${1:-}" tool_rule='tool ::= "\"" [a-z_0-9]{1,48} "\""'
    if [ -n "$tools_csv" ]; then
        local alts="" t
        IFS=',' read -ra _tl <<<"$tools_csv"
        for t in "${_tl[@]}"; do
            t="${t//[^a-z_0-9]/}"; [ -z "$t" ] && continue
            alts+="${alts:+ | }\"\\\"${t}\\\"\""
        done
        alts+="${alts:+ | }\"\\\"respond\\\"\""
        [ -n "$alts" ] && tool_rule="tool ::= ${alts}"
    fi
    printf '%s\n' 'root ::= "{" ws "\"diagnosis\":" ws str "," ws "\"next_tool\":" ws tool "," ws "\"args_hint\":" ws str "," ws "\"abandon_step\":" ws bool ws "}"' \
        'bool ::= "true" | "false"' "$tool_rule" "$REACT_GBNF_STR"
}

react_advisor_budget_ok() {
    local sdir="${1:-}" step="${2:-1}"
    [ -z "$sdir" ] && return 1
    local runs=0
    [ -f "$sdir/.advisor_count" ] && runs=$(cat "$sdir/.advisor_count" 2>/dev/null || echo 0)
    [[ "$runs" =~ ^[0-9]+$ ]] || runs=0
    [ "$runs" -ge "$REACT_ADVISOR_MAX_PER_RUN" ] && return 1
    [ -f "$sdir/.advisor_step_${step//[^0-9A-Za-z_]/_}" ] && return 1
    return 0
}

react_advise() {
    local sdir="${1:-}" step_id="${2:-1}" step_task="${3:-}" goal="${4:-}" trigger="${5:-STUCK}" tools_csv="${6:-}"
    declare -f react_llm_json &>/dev/null || return 1
    react_advisor_budget_ok "$sdir" "$step_id" || return 1

    local runs=0
    [ -f "$sdir/.advisor_count" ] && runs=$(cat "$sdir/.advisor_count" 2>/dev/null || echo 0)
    [[ "$runs" =~ ^[0-9]+$ ]] || runs=0
    printf '%s\n' "$(( runs + 1 ))" > "$sdir/.advisor_count" 2>/dev/null
    : > "$sdir/.advisor_step_${step_id//[^0-9A-Za-z_]/_}" 2>/dev/null

    local failed="" evals="" recent=""
    [ -f "$sdir/scratchpad.md" ] && failed=$(awk '/^## Failed Attempts/{f=1; next} /^## /{f=0} f' "$sdir/scratchpad.md" | tail -n 12)
    [ -f "$sdir/evaluator.jsonl" ] && evals=$(tail -n 4 "$sdir/evaluator.jsonl" | jq -r '"- step \(.step): \(.verdict) — \(.reason)"' 2>/dev/null)
    [ -f "$sdir/scratchpad.md" ] && recent=$(grep -E '^### \[' "$sdir/scratchpad.md" | tail -n 8)

    local sys="You are a senior operator advising an autonomous agent that is stuck.
Diagnose WHY it is stuck in one or two sentences, then pick exactly one next tool from the allowed list and a concrete argument hint (e.g. a better search query or a different source).
Never suggest repeating a failed call. Set abandon_step=true only if this milestone cannot be achieved with the available tools and the agent should move on (and say so honestly in its final answer).
Choose next_tool=\"respond\" if enough evidence exists to answer now."
    local conv_ctx=""
    if [ -n "${REACT_CONVERSATION_HISTORY:-}" ]; then
        conv_ctx="${REACT_CONVERSATION_HISTORY}"
        [ "${#conv_ctx}" -gt 1200 ] && conv_ctx="${conv_ctx: -1200}"
    fi
    local user="TASK: ${goal:0:1200}${conv_ctx:+
RECENT CONVERSATION CONTEXT:
$conv_ctx}
STUCK ON STEP ${step_id}: ${step_task}
TRIGGER: ${trigger}

FAILED ATTEMPTS:
${failed:-none recorded}

EVALUATOR VERDICTS:
${evals:-none}

RECENT ACTIONS:
${recent:-none}

ALLOWED TOOLS: ${tools_csv:-any}
Today is $(date '+%Y-%m-%d')."
    local obj
    obj=$(react_llm_json "$sys" "$user" "$(_react_advisor_gbnf "$tools_csv")" 350 "$REACT_ADVISOR_TIMEOUT") || return 1
    jq -nc --argjson o "$obj" --arg s "$step_id" --arg t "$trigger" --argjson ts "$(date +%s)" \
        '$o + {step: $s, trigger: $t, ts: $ts}' >> "$sdir/advisor.jsonl" 2>/dev/null || true
    printf '%s\n' "$obj"
}

react_advise_render() {
    local obj="${1:-}"
    local d n a ab
    d=$(jq -r '.diagnosis // ""' <<<"$obj"); n=$(jq -r '.next_tool // ""' <<<"$obj")
    a=$(jq -r '.args_hint // ""' <<<"$obj"); ab=$(jq -r '.abandon_step // false' <<<"$obj")
    local msg="[ADVISOR] Diagnosis: ${d}"
    if [ "$n" = "respond" ]; then
        msg+=$'\n'"Next: stop calling tools and deliver your answer now from the evidence you have (${a})."
    else
        msg+=$'\n'"Next: call ${n} — ${a}"
    fi
    [ "$ab" = "true" ] && msg+=$'\n'"This step is being abandoned as unachievable; continue with the next step and state the gap honestly in your final answer."
    printf '%s' "$msg"
}
