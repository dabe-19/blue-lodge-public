#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  lib/core/react_evaluator.sh — Milestone evaluator (Refinement P2.5)
# ═══════════════════════════════════════════════════════════════════════
#  Replaces the keyword heuristic gate + free-text temperature-0.7 JSON
#  evaluator with one grammar-constrained call at temperature 0.1.
#
#    verdict ∈ COMPLETE | INCOMPLETE | BLOCKED
#
#  Public API
#    react_llm_json <system> <user> <grammar> [max_tokens] [timeout_s]
#        → prints the JSON object (or nothing on failure)
#    react_eval_milestone <session_dir> <step_id> <step_task> <goal> <evidence>
#        → prints "VERDICT|reason|next_action"
#    react_eval_incomplete_count <session_dir> <step_id>   → integer
# ═══════════════════════════════════════════════════════════════════════

[ -n "${_REACT_EVALUATOR_LOADED:-}" ] && return 0
_REACT_EVALUATOR_LOADED=1

# Shared GBNF fragments
REACT_GBNF_STR='str ::= "\"" chr{0,280} "\""
chr ::= [^"\\\n] | "\\" ["\\/nt]
ws ::= [ \t\n]{0,4}'

REACT_EVAL_GBNF='root ::= "{" ws "\"verdict\":" ws verdict "," ws "\"reason\":" ws str "," ws "\"next_action\":" ws str ws "}"
verdict ::= "\"COMPLETE\"" | "\"INCOMPLETE\"" | "\"BLOCKED\""
'"$REACT_GBNF_STR"

react_llm_json() {
    local sys="${1:-}" user="${2:-}" grammar="${3:-}" max_tokens="${4:-300}" timeout_s="${5:-45}"
    local ep="${REACT_EVAL_ENDPOINT:-${ACTIVE_ENDPOINT_URL:-http://127.0.0.1:8080}}"
    local payload resp content
    payload=$(jq -nc --arg s "$sys" --arg u "$user" --arg g "$grammar" --argjson mt "$max_tokens" \
        '{messages: [{role: "system", content: $s}, {role: "user", content: $u}],
          temperature: 0.1, max_tokens: $mt, stream: false,
          chat_template_kwargs: {enable_thinking: false}}
         + (if $g == "" then {} else {grammar: $g} end)')
    resp=$(curl -s --max-time "$timeout_s" "$ep/v1/chat/completions" \
        -H "Content-Type: application/json" -d "$payload" 2>/dev/null) || return 1
    content=$(jq -r '.choices[0].message.content // empty' <<<"$resp" 2>/dev/null)
    content=$(printf '%s' "$content" | sed -E 's/<think>.*<\/think>//g')
    # Grammar guarantees shape; still validate (endpoint may ignore grammar)
    local obj
    obj=$(printf '%s' "$content" | jq -c 'select(type == "object")' 2>/dev/null | head -n 1)
    [ -z "$obj" ] && obj=$(printf '%s' "$content" | grep -oE '\{.*\}' | tail -n 1 | jq -c . 2>/dev/null)
    [ -n "$obj" ] && { printf '%s\n' "$obj"; return 0; }
    return 1
}

react_eval_incomplete_count() {
    local sdir="${1:-}" step="${2:-1}"
    local f="$sdir/.eval_incomplete_${step//[^0-9A-Za-z_]/_}"
    [ -f "$f" ] && cat "$f" 2>/dev/null || echo 0
}

_react_eval_bump_incomplete() {
    local sdir="${1:-}" step="${2:-1}"
    [ -z "$sdir" ] && return 0
    local f="$sdir/.eval_incomplete_${step//[^0-9A-Za-z_]/_}" n
    n=$(react_eval_incomplete_count "$sdir" "$step"); n=$(( n + 1 ))
    printf '%s\n' "$n" > "$f" 2>/dev/null || true
}

react_eval_milestone() {
    local sdir="${1:-}" step_id="${2:-1}" step_task="${3:-}" goal="${4:-}" evidence="${5:-}"
    local scratch=""
    [ -f "$sdir/scratchpad.md" ] && scratch=$(tail -n 120 "$sdir/scratchpad.md" 2>/dev/null)
    [ "${#scratch}" -gt 4000 ] && scratch="${scratch: -4000}"
    # Analysis/design milestones are satisfied by the agent's stated conclusions,
    # which live in assistant content/reasoning, not in tool output. Without this
    # the judge kept asking for files the agent had already read (rem_1791146144_401).
    local concl=""
    if [ -f "$sdir/messages.json" ]; then
        concl=$(jq -r '[.[] | select(.role == "assistant")] | .[-3:] | map(((.reasoning_content // "") + "\n" + (.content // "")) | gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | join("\n---\n")' \
            "$sdir/messages.json" 2>/dev/null)
        [ "${#concl}" -gt 3000 ] && concl="${concl: -3000}"
    fi
    # Implementation milestones: file_edit digests only say "modified", so show the
    # real uncommitted + branch diff of the workspace (git worktrees only, capped).
    local wdiff="" ws="${REACT_EVAL_WORKSPACE:-${LODGE_DIR:-}}"
    if [[ "$ws" == */.sandboxes/* ]] && git -C "$ws" rev-parse --is-inside-work-tree &>/dev/null; then
        wdiff=$(git -C "$ws" diff --stat HEAD 2>/dev/null | tail -n 15; git -C "$ws" diff -U1 HEAD 2>/dev/null | head -c 2500)
    fi
    local incomp_cnt=0
    [ -n "$sdir" ] && incomp_cnt=$(react_eval_incomplete_count "$sdir" "$step_id")
    local ceiling_note=""
    if [ "$incomp_cnt" -ge 2 ]; then
        ceiling_note="STRIKE CEILING ($incomp_cnt previous INCOMPLETE evaluations on this step): Diminishing returns apply. If the agent has extracted the primary core facts, conclusions, or relevant data, judge COMPLETE even if granular or secondary sub-metrics are unavailable or missing from sources. Do NOT trap the agent in an endless loop demanding minor missing fields."
    fi

    local sys="You judge whether an agent's evidence completes ONE milestone of a larger task.
COMPLETE: the evidence concretely satisfies the milestone (facts/values/artifacts present).
INCOMPLETE: more work is needed; next_action names the single most useful next step.
BLOCKED: the milestone cannot be satisfied with available sources/tools (e.g. every source blocked); say why.
Judge only the milestone, not the whole task. Navigation menus, search-engine boilerplate and failed fetches are NOT evidence.
SUFFICIENT EVIDENCE & DIMINISHING RETURNS: If a milestone lists multiple granular sub-requirements (e.g. 10 specific statistical metrics, rankings, splits) and the agent has gathered the decisive primary data (e.g. records, scores, recent form, key metrics), mark COMPLETE. Do NOT demand exhaustive perfection on obscure sub-metrics that public sources or APIs do not provide.
For analysis, diagnosis or design milestones, a specific conclusion in AGENT CONCLUSIONS that cites files, functions or log lines seen in the evidence counts as COMPLETE; do not ask it to re-read what it already cites.${ceiling_note:+

$ceiling_note}"
    local conv_ctx=""
    if [ -n "${REACT_CONVERSATION_HISTORY:-}" ]; then
        conv_ctx="${REACT_CONVERSATION_HISTORY}"
        [ "${#conv_ctx}" -gt 1200 ] && conv_ctx="${conv_ctx: -1200}"
    fi
    local user="OVERALL TASK:
${goal:0:1500}${conv_ctx:+

RECENT CONVERSATION CONTEXT:
$conv_ctx}

MILESTONE (step ${step_id}):
${step_task}

LATEST TOOL EVIDENCE:
${evidence:0:4000}

AGENT CONCLUSIONS (recent turns):
${concl:-none}

WORKSPACE CHANGES (git diff vs HEAD):
${wdiff:-none}

SESSION SCRATCHPAD (recent):
${scratch}"
    local obj verdict reason next
    obj=$(react_llm_json "$sys" "$user" "$REACT_EVAL_GBNF" 300 "${REACT_EVAL_TIMEOUT:-45}")
    # The LLM server runs one slot: a timeout usually means we queued behind another consumer.
    [ -z "$obj" ] && obj=$(react_llm_json "$sys" "$user" "$REACT_EVAL_GBNF" 300 "${REACT_EVAL_RETRY_TIMEOUT:-150}")
    if [ -z "$obj" ]; then
        echo "INCOMPLETE|evaluator unavailable|continue"
        return 0
    fi
    verdict=$(jq -r '.verdict // "INCOMPLETE"' <<<"$obj")
    reason=$(jq -r '.reason // ""' <<<"$obj" | tr '|\n' '/ ')
    next=$(jq -r '.next_action // ""' <<<"$obj" | tr '|\n' '/ ')
    case "$verdict" in COMPLETE|INCOMPLETE|BLOCKED) ;; *) verdict="INCOMPLETE" ;; esac
    [ "$verdict" = "INCOMPLETE" ] && _react_eval_bump_incomplete "$sdir" "$step_id"
    if [ -n "$sdir" ]; then
        jq -nc --arg s "$step_id" --arg v "$verdict" --arg r "$reason" --arg n "$next" --argjson ts "$(date +%s)" \
            '{ts: $ts, step: $s, verdict: $v, reason: $r, next_action: $n}' >> "$sdir/evaluator.jsonl" 2>/dev/null || true
    fi
    echo "${verdict}|${reason}|${next}"
}
