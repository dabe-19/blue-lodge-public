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

_react_llm_json_call() {
    local ep="$1" payload="$2" timeout_s="$3"
    local resp content obj
    resp=$(curl -s --max-time "$timeout_s" "$ep/v1/chat/completions" \
        -H "Content-Type: application/json" -d "$payload" 2>/dev/null) || return 1
    content=$(jq -r '.choices[0].message.content // empty' <<<"$resp" 2>/dev/null)
    content=$(printf '%s' "$content" | sed -E 's/<think>.*<\/think>//g')
    # Grammar guarantees shape; still validate (endpoint may ignore grammar)
    obj=$(printf '%s' "$content" | jq -c 'select(type == "object")' 2>/dev/null | head -n 1)
    [ -z "$obj" ] && obj=$(printf '%s' "$content" | grep -oE '\{.*\}' | tail -n 1 | jq -c . 2>/dev/null)
    [ -n "$obj" ] && { printf '%s\n' "$obj"; return 0; }
    return 1
}

react_llm_json() {
    local sys="${1:-}" user="${2:-}" grammar="${3:-}" max_tokens="${4:-300}" timeout_s="${5:-45}"
    local default_ep="${ACTIVE_ENDPOINT_URL:-${TIER1_URL:-http://127.0.0.1:8080}}"
    local primary_ep="${REACT_EVAL_ENDPOINT:-$default_ep}"
    local fallback_ep=""

    if [ -z "${REACT_EVAL_ENDPOINT:-}" ] && [ -z "${GEORGE_TEST_SANDBOX:-}" ] && [ "${_LODGE_TESTING:-0}" != "1" ] && [ "${LODGE_TEST_MODE:-0}" != "1" ]; then
        local _lodge_dir="${LODGE_DIR:-$HOME/blue-lodge}"
        [ -f "$_lodge_dir/lib/core/endpoints.sh" ] && source "$_lodge_dir/lib/core/endpoints.sh" 2>/dev/null || true
        [ -f "$_lodge_dir/lib/ipc/fifo_ipc.sh" ] && source "$_lodge_dir/lib/ipc/fifo_ipc.sh" 2>/dev/null || true
        local _obj="${REACT_LLM_OBJECTIVE:-evaluator}"
        if declare -f endpoints_resolve_for_objective &>/dev/null; then
            local _resolved _r_tier _r_url
            _resolved=$(endpoints_resolve_for_objective "$_obj" 2>/dev/null || true)
            if [ -n "$_resolved" ]; then
                IFS='|' read -r _r_tier _ _r_url _ <<< "$_resolved"
                if [ -n "$_r_url" ]; then
                    primary_ep="$_r_url"
                    [ "$primary_ep" != "$default_ep" ] && fallback_ep="$default_ep"
                fi
            fi
        fi
    elif [ -n "${REACT_EVAL_ENDPOINT:-}" ] && [ -z "${GEORGE_TEST_SANDBOX:-}" ] && [ "${_LODGE_TESTING:-0}" != "1" ] && [ "${LODGE_TEST_MODE:-0}" != "1" ]; then
        [ "$REACT_EVAL_ENDPOINT" != "$default_ep" ] && fallback_ep="$default_ep"
    fi

    local payload
    payload=$(jq -nc --arg s "$sys" --arg u "$user" --arg g "$grammar" --argjson mt "$max_tokens" \
        '{messages: [{role: "system", content: $s}, {role: "user", content: $u}],
          temperature: 0.1, max_tokens: $mt, stream: false,
          chat_template_kwargs: {enable_thinking: false}}
         + (if $g == "" then {} else {grammar: $g} end)')

    local primary_timeout="$timeout_s"
    if [ -n "$fallback_ep" ] && [ "$primary_timeout" -gt 20 ]; then
        primary_timeout=20
    fi

    if _react_llm_json_call "$primary_ep" "$payload" "$primary_timeout"; then
        return 0
    fi
    if [ -n "$fallback_ep" ] && [ "$fallback_ep" != "$primary_ep" ]; then
        _react_llm_json_call "$fallback_ep" "$payload" "$timeout_s" && return 0
    fi
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

react_eval_check_gates() {
    local sdir="${1:-}" step_id="${2:-1}" step_task="${3:-}"
    [ -z "$sdir" ] || [ ! -d "$sdir" ] && return 0

    local hd_file="$sdir/honeydew.json"
    local req_tools=() req_files=() verify_cmd=""

    if [ -f "$hd_file" ]; then
        local item_json
        item_json=$(jq -c --argjson sid "$step_id" '.items[]? | select(.id == $sid)' "$hd_file" 2>/dev/null | head -n 1)
        if [ -n "$item_json" ]; then
            while IFS= read -r rt; do
                [ -n "$rt" ] && req_tools+=("$rt")
            done < <(jq -r '.required_tools[]? // empty' <<<"$item_json" 2>/dev/null)
            while IFS= read -r rf; do
                [ -n "$rf" ] && req_files+=("$rf")
            done < <(jq -r '.required_files[]? // empty' <<<"$item_json" 2>/dev/null)
            verify_cmd=$(jq -r '.verify_cmd // empty' <<<"$item_json" 2>/dev/null)
        fi
    fi

    # Implicit structural gate inference from milestone text for known mandatory protocols
    local st_lower="${step_task,,}"
    if [[ "$st_lower" =~ \bdiscord_send\b ]] && [[ ! " ${req_tools[*]} " =~ " discord_send " ]]; then
        req_tools+=("discord_send")
    fi
    if [[ "$st_lower" =~ digest_check\.sh[[:space:]]+validate ]] && [ -z "$verify_cmd" ]; then
        verify_cmd="grep -q 'digest_check.sh validate'"
    fi

    # 1. Check required_files
    local rf
    for rf in "${req_files[@]}"; do
        if [ ! -s "$rf" ] && [ ! -s "$sdir/$rf" ]; then
            echo "INCOMPLETE|Structural gate: required file '$rf' is missing or empty|Create and populate '$rf' before completing step ${step_id}"
            return 1
        fi
    done

    # 2. Check required_tools against messages.json and trajectory.log
    local rt
    for rt in "${req_tools[@]}"; do
        local found=0
        if [ -f "$sdir/messages.json" ] && jq -e --arg t "$rt" '.[] | select(.role == "tool" and .name == $t)' "$sdir/messages.json" >/dev/null 2>&1; then
            found=1
        elif [ -f "$sdir/trajectory.log" ] && grep -qF "$rt" "$sdir/trajectory.log" 2>/dev/null; then
            found=1
        fi
        if [ "$found" -eq 0 ]; then
            echo "INCOMPLETE|Structural gate: required tool '$rt' has not been invoked in this session|Call '$rt' to satisfy step ${step_id}"
            return 1
        fi
    done

    # 3. Check verify_cmd
    if [ -n "$verify_cmd" ]; then
        if [ "$verify_cmd" = "grep -q 'digest_check.sh validate'" ]; then
            local v_ok=0
            [ -f "$sdir/messages.json" ] && grep -q "digest_check.sh validate" "$sdir/messages.json" 2>/dev/null && v_ok=1
            [ -f "$sdir/trajectory.log" ] && grep -q "digest_check.sh validate" "$sdir/trajectory.log" 2>/dev/null && v_ok=1
            if [ "$v_ok" -eq 0 ]; then
                echo "INCOMPLETE|Structural gate: mandatory 'digest_check.sh validate' has not been executed|Run digest_check.sh validate via bash_exec"
                return 1
            fi
        else
            if ! (cd "$sdir" && bash -c "$verify_cmd") >/dev/null 2>&1; then
                echo "INCOMPLETE|Structural gate: verification command failed ($verify_cmd)|Fix output so '$verify_cmd' exits 0"
                return 1
            fi
        fi
    fi

    return 0
}

react_eval_milestone() {
    local sdir="${1:-}" step_id="${2:-1}" step_task="${3:-}" goal="${4:-}" evidence="${5:-}"
    # Deterministic Pre-Evaluator Structural Gate Check
    local gate_out=""
    if [ -n "$sdir" ] && [[ "$step_id" =~ ^[0-9]+$ ]]; then
        if ! gate_out=$(react_eval_check_gates "$sdir" "$step_id" "$step_task"); then
            _react_eval_bump_incomplete "$sdir" "$step_id"
            local g_reason="${gate_out#*|}"
            local g_next="${g_reason#*|}"
            g_reason="${g_reason%%|*}"
            jq -nc --arg s "$step_id" --arg v "INCOMPLETE" --arg r "$g_reason" --arg n "$g_next" --argjson ts "$(date +%s)" \
                '{ts: $ts, step: $s, verdict: $v, reason: $r, next_action: $n, gate: "structural"}' >> "$sdir/evaluator.jsonl" 2>/dev/null || true
            if declare -f recall_record_evaluator_snapshot &>/dev/null; then
                local _g_tb="${AGENT_ACTIVE_SESSION_ID:-$(basename "$sdir")}"
                local _g_snap
                _g_snap=$(jq -nc --arg efr "$g_reason" --arg sc "milestone_step_${step_id}_gate" \
                    '{evaluator_mode:"normal", evaluator_failure_reason:$efr, backend:"structural_gate", scenario:$sc, parse_mode:"deterministic_gate", diagnostic_code:"GATE_INCOMPLETE"}')
                recall_record_evaluator_snapshot "$_g_tb" "$_g_snap" >/dev/null 2>&1 || true
            fi
            echo "$gate_out"
            return 0
        fi
    fi
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
    local _eval_task_boundary="${AGENT_ACTIVE_SESSION_ID:-$(basename "${sdir:-eval_session}")}"
    if [ -z "$obj" ]; then
        if declare -f recall_record_evaluator_snapshot &>/dev/null; then
            local _deg_snap
            _deg_snap=$(jq -nc --arg sc "milestone_step_${step_id}" --arg be "${REACT_EVAL_ENDPOINT:-local_inference}" \
                --arg sm "${ACTIVE_ENDPOINT_MODEL:-default}" --argjson pcc "${#user}" --argjson scc "${#sys}" \
                '{evaluator_mode:"degraded", failure_reason:"evaluator unavailable", backend:$be, scenario:$sc, token_budget:300, output_length:0, parse_mode:"gbnf_json", grammar_mode:"gbnf", selected_model:$sm, grammar_schema_name:"react_eval_gbnf", prompt_char_count:$pcc, system_char_count:$scc, diagnostic_code:"UNAVAILABLE"}')
            recall_record_evaluator_snapshot "$_eval_task_boundary" "$_deg_snap" >/dev/null 2>&1 || true
        fi
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
    if declare -f recall_record_evaluator_snapshot &>/dev/null; then
        local _snap_efr=""
        [ "$verdict" != "COMPLETE" ] && _snap_efr="$reason"
        local _ok_snap
        _ok_snap=$(jq -nc --arg efr "$_snap_efr" --arg sc "milestone_step_${step_id}" --arg be "${REACT_EVAL_ENDPOINT:-local_inference}" \
            --arg sm "${ACTIVE_ENDPOINT_MODEL:-default}" --arg dc "$verdict" \
            --argjson ol "${#obj}" --argjson pcc "${#user}" --argjson scc "${#sys}" \
            '{evaluator_mode:"normal", evaluator_failure_reason:$efr, backend:$be, scenario:$sc, token_budget:300, output_length:$ol, parse_mode:"gbnf_json", grammar_mode:"gbnf", selected_model:$sm, grammar_schema_name:"react_eval_gbnf", prompt_char_count:$pcc, system_char_count:$scc, diagnostic_code:$dc}')
        recall_record_evaluator_snapshot "$_eval_task_boundary" "$_ok_snap" >/dev/null 2>&1 || true
    fi
    if declare -f recall_schema_compat_set &>/dev/null; then
        recall_schema_compat_set "react_eval_gbnf" "compatible" 0 1 1 "$verdict" "Milestone evaluator GBNF schema verified" >/dev/null 2>&1 || true
    fi
    echo "${verdict}|${reason}|${next}"
}
