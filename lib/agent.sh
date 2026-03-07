#!/bin/bash
# ── George: Agent Loop ─────────────────────────────────────
# The core plan→execute→memory cycle.
# Each step is a small LLM call with full memory context.

[ -n "${_LIB_AGENT_LOADED:-}" ] && return 0; _LIB_AGENT_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/tools.sh"
source "$LODGE_DIR/lib/journal.sh"

# ── Config ─────────────────────────────────────────────────────
AGENT_MAX_STEPS="${AGENT_MAX_STEPS:-20}"       # Macro loop milestone ceiling
AGENT_PLAN_STEPS="${AGENT_PLAN_STEPS:-6}"      # Max steps per plan/subtask
AGENT_INNER_LOOPS="${AGENT_INNER_LOOPS:-6}"    # Inner loop escalation ceiling
AGENT_STEP_DELAY="${AGENT_STEP_DELAY:-1}"
AGENT_MAX_CLARIFY="${AGENT_MAX_CLARIFY:-2}"
AGENT_INTERACTIVE_PLANNING="${AGENT_INTERACTIVE_PLANNING:-0}"
AGENT_MAX_DEPTH="${AGENT_MAX_DEPTH:-1}"        # Subtask recursion depth (1 = single expansion only)
AGENT_HONEYDEW_EXPAND="${AGENT_HONEYDEW_EXPAND:-0}"  # Subtask expansion: 0=disabled, 1=enabled
AGENT_HONEYDEW_MAX_ITEMS="${AGENT_HONEYDEW_MAX_ITEMS:-8}"  # Max honeydew items before expansion is suppressed
AGENT_WEB_SUFFICIENCY="${AGENT_WEB_SUFFICIENCY:-3}"  # Web actions before sufficiency signal
AGENT_MAX_MILESTONE_RETRIES="${AGENT_MAX_MILESTONE_RETRIES:-2}"  # Max times to retry same milestone
AGENT_MAX_CMD_FAMILY="${AGENT_MAX_CMD_FAMILY:-3}"                # Max milestones with same base command
AGENT_HONEYDEW_MATCH="${AGENT_HONEYDEW_MATCH:-2}"              # Min keyword score to auto-check honeydew item
AGENT_EVAL_MODE="${AGENT_EVAL_MODE:-auto}"              # Evaluator mode: auto | interactive | disabled
AGENT_WEB_SEARCH_CONSEC_MAX="${AGENT_WEB_SEARCH_CONSEC_MAX:-1}"  # Max consecutive /web search before fallback to fetch/scrape

LLM_EVALUATOR_TOKENS="${LLM_EVALUATOR_TOKENS:-2048}"     # Max output tokens for evaluator

# ── Context-aware memory injection for thinking models ─────────
# Thinking models consume input context faster (need room for
# <think> blocks). When a thinking model is active, reduce memory
# injection sizes to avoid overwhelming the context window.
# Returns the reduced value for thinking models, original otherwise.
_agent_thinking_context_limit() {
    local default_val="$1"
    if models_current_has_thinking 2>/dev/null; then
        # Halve context injection for thinking models
        echo $(( default_val / 2 ))
    else
        echo "$default_val"
    fi
}

# ── JSON Memory Helpers ─────────────────────────────────────────
# Micro and macro memory use structured JSON for inter-agent context.
# jq handles all read/modify/write operations to ensure valid JSON
# and safe string escaping (no injection from command output).
#
# micro_memory.json — Per-milestone working memory (wiped each milestone).
# macro_memory.json — Per-task persistent memory (persona + milestones).
# ---------------------------------------------------------------

# ── Micro Memory (per-milestone working memory) ───────────────

_micro_init() {
    local file="$1" objective="$2"
    jq -n --arg obj "$objective" --arg ts "$(date '+%Y-%m-%d %H:%M:%S %Z')" '{
        micro_objective: $obj,
        started: $ts,
        primary_objective: null,
        honeydew_progress: null,
        research_context: null,
        prior_milestones: [],
        action_log: [],
        milestone_result: null,
        sufficiency_reached: false,
        warnings: [],
        system_notes: []
    }' > "$file"
}

_micro_set() {
    local file="$1" key="$2" value="$3"
    local tmp="${file}.tmp"
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$file" > "$tmp" && mv "$tmp" "$file"
}

_micro_add_action() {
    local file="$1" action="$2" status="$3" exit_code="$4" output="$5" source="${6:-specialist}"
    local tmp="${file}.tmp"
    jq --arg a "$action" --arg s "$status" --argjson e "$exit_code" \
       --arg o "${output:0:2000}" --arg src "$source" \
       '.action_log += [{"action": $a, "status": $s, "exit_code": $e, "output": $o, "source": $src}]' \
       "$file" > "$tmp" && mv "$tmp" "$file"
}

_micro_add_warning() {
    local file="$1" warning="$2"
    local tmp="${file}.tmp"
    jq --arg w "$warning" '.warnings += [$w]' "$file" > "$tmp" && mv "$tmp" "$file"
}

_micro_add_note() {
    local file="$1" note="$2"
    local tmp="${file}.tmp"
    jq --arg n "$note" '.system_notes += [$n]' "$file" > "$tmp" && mv "$tmp" "$file"
}

_micro_set_result() {
    local file="$1" status="$2" summary="$3"
    local tmp="${file}.tmp"
    jq --arg s "$status" --arg sum "$summary" \
       '.milestone_result = {"status": $s, "summary": $sum}' \
       "$file" > "$tmp" && mv "$tmp" "$file"
}

_micro_set_sufficiency() {
    local file="$1"
    local tmp="${file}.tmp"
    jq '.sufficiency_reached = true' "$file" > "$tmp" && mv "$tmp" "$file"
}

_micro_set_prior_milestones() {
    local file="$1" milestones_json="$2"
    local tmp="${file}.tmp"
    jq --argjson m "$milestones_json" '.prior_milestones = $m' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Count actions matching an optional regex on the action field
_micro_action_count() {
    local file="$1" pattern="${2:-}"
    if [ -n "$pattern" ]; then
        jq --arg p "$pattern" '[.action_log[] | select(.action | test($p))] | length' "$file" 2>/dev/null || echo 0
    else
        jq '.action_log | length' "$file" 2>/dev/null || echo 0
    fi
}

# Count successful actions matching an optional regex
_micro_success_count() {
    local file="$1" pattern="${2:-}"
    if [ -n "$pattern" ]; then
        jq --arg p "$pattern" '[.action_log[] | select(.status == "SUCCESS") | select(.action | test($p))] | length' "$file" 2>/dev/null || echo 0
    else
        jq '[.action_log[] | select(.status == "SUCCESS")] | length' "$file" 2>/dev/null || echo 0
    fi
}

# Check if sufficiency gate has triggered
_micro_sufficiency_reached() {
    local file="$1"
    jq -e '.sufficiency_reached == true' "$file" >/dev/null 2>&1
}

# Serialize for LLM injection — last N actions with output capped
_micro_serialize() {
    local file="$1" max_actions="${2:-10}"
    jq --argjson n "$max_actions" '
        .action_log = (.action_log | .[-$n:] | map(.output = .output[:1024]))
    ' "$file" 2>/dev/null
}

# Lean serialize for the router — only objective + action summaries.
# The router doesn't need prior_milestones, research_context,
# system_notes, or warnings. Those fields dilute the routing
# decision on 4B models and waste tokens.
#
# Once a honeydew list exists (honeydew_progress is set), the
# primary_objective is redundant and is omitted to prevent the
# router from fixating on the raw query instead of the current
# milestone + honeydew context.
_micro_serialize_lean() {
    local file="$1" max_actions="${2:-6}"
    jq --argjson n "$max_actions" '{
        micro_objective: .micro_objective,
        honeydew_progress: .honeydew_progress,
        action_log: (.action_log | .[-$n:] | map({action, status, exit_code}))
    } + (if .honeydew_progress == null and .primary_objective != null then
        {primary_objective: .primary_objective}
    else {} end)' "$file" 2>/dev/null
}

# Serialize only the action log for the P1 milestone evaluator.
# P1 should judge THIS milestone's actions, not carryover context
# from prior milestones (research_context, prior_milestones, etc.).
_micro_serialize_eval() {
    local file="$1" max_actions="${2:-10}" max_output="${3:-1024}"
    jq --argjson n "$max_actions" --argjson m "$max_output" '{
        micro_objective: .micro_objective,
        action_log: (.action_log | .[-$n:] | map(.output = .output[:$m])),
        warnings: .warnings
    }' "$file" 2>/dev/null
}

# Extract successful web outputs for research buffer
_micro_web_outputs() {
    local file="$1" max_chars="${2:-1500}"
    local result
    result=$(jq -r '[.action_log[] | select(.action | test("^/web")) | select(.status == "SUCCESS") | .output] | join("\n---\n")' "$file" 2>/dev/null)
    echo "${result:0:$max_chars}"
}

# ── Macro Memory (per-task persistent memory) ─────────────────

_macro_init() {
    local file="$1" task="$2" persona="$3" project_ctx="${4:-}"
    jq -n --arg ts "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
          --arg task "$task" --arg persona "$persona" \
          --arg ctx "$project_ctx" '{
        task_started: $ts,
        persona: $persona,
        primary_objective: $task,
        project_context: (if $ctx == "" then null else $ctx end),
        completed_milestones: [],
        honeydew: null
    }' > "$file"
}

_macro_add_milestone() {
    local file="$1" objective="$2" summary="$3" command="${4:-}" action_class="${5:-UNKNOWN}" status="${6:-OK}"
    local tmp="${file}.tmp"
    jq --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
       --arg obj "$objective" --arg sum "$summary" \
       --arg cmd "$command" --arg ac "$action_class" --arg st "$status" \
       '.completed_milestones += [{"timestamp": $ts, "objective": $obj, "summary": $sum, "command": $cmd, "action_class": $ac, "status": $st}]' \
       "$file" > "$tmp" && mv "$tmp" "$file"
}

_macro_get() {
    local file="$1" key="$2"
    jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null
}

_macro_set_honeydew() {
    local file="$1" honeydew_text="$2"
    local tmp="${file}.tmp"
    jq --arg hd "$honeydew_text" '.honeydew = $hd' "$file" > "$tmp" && mv "$tmp" "$file"
}

_macro_milestone_count() {
    local file="$1"
    jq '.completed_milestones | length' "$file" 2>/dev/null || echo 0
}

# Get last N milestones as a JSON array
_macro_milestones_json() {
    local file="$1" last_n="${2:-3}"
    jq --argjson n "$last_n" '.completed_milestones | .[-$n:]' "$file" 2>/dev/null || echo '[]'
}

_macro_serialize() {
    local file="$1"
    cat "$file" 2>/dev/null
}

# Serialize macro_memory without persona bloat for evaluators/strategist.
# Persona text (~200 tokens) adds no value for milestone selection or
# completion judgment. Stripping it frees context window for actual
# task data on the 4B model.
#
# Once the honeydew list is built, primary_objective is redundant —
# the honeydew list encodes the original objective as structured
# subtasks. Stripping it prevents the strategist/evaluator from
# chasing the raw query instead of the remaining honeydew items.
_macro_serialize_lean() {
    local file="$1"
    # Strip: persona (always), primary_objective (when honeydew exists),
    # command field from milestones (prevents slash-command priming on
    # subsequent strategist calls), and cap milestones to last 5
    # (prevents unbounded token growth on long tasks).
    local _jq_lean='.completed_milestones |= (.[-5:] | [.[] | del(.command)])'
    if jq -e '.honeydew != null' "$file" >/dev/null 2>&1; then
        jq "del(.persona) | del(.primary_objective) | $_jq_lean" "$file" 2>/dev/null
    else
        jq "del(.persona) | $_jq_lean" "$file" 2>/dev/null
    fi
}

# ── Milestone Completion Helper ────────────────────────────────
# Shared logic for completing a milestone: summarize micro_memory,
# tag the action class, write to macro_memory, save research buffer.
# Called by the evaluator-based completion check and the sufficiency gate.
_agent_complete_milestone() {
    local micro_file="$1" macro_file="$2" micro_objective="$3"
    local summary="${4:-Objective fulfilled}"
    local last_success_cmd="${5:-}" george_dir="${6:-.george}"

    _micro_set_result "$micro_file" "COMPLETE" "$summary"

    # ── Summarize micro_memory into milestone_summary ──────
    local _micro_content _milestone_summary
    _micro_content=$(cat "$micro_file" 2>/dev/null)
    if [ -n "$_micro_content" ]; then
        local _ms_prompt="In no more than 6 sentences, summarize this milestone execution log. Include the command(s) run, their outcomes, and whether the objective was met. If web search or fetch results contain factual data (names, prices, specs, dates, descriptions, URLs, key findings), you MUST INCLUDE those specific facts verbatim — they will be needed by subsequent milestones. If a draft email, post, or message body was composed, include its key points. Generic summaries like 'Web research data gathered' are USELESS. Be specific.\n\n${_micro_content}"
        local _ms_sys="You are a concise summarizer. In no more than 6 factual sentences, write your output. PRESERVE specific facts (names, numbers, URLs). No personality. No markdown formatting (no ** or * markers). Plain text only."
        local LLM_SCENARIO=evaluator
        _milestone_summary=$(llm_generate "$_ms_prompt" "$_ms_sys" 512 "$LLM_BUDGET_AGENT" 2>/dev/null)
        _milestone_summary=$(echo "$_milestone_summary" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
        _milestone_summary=$(echo "$_milestone_summary" | sed ':a;N;$!ba;s/<think>.*$//g')
        # Strip markdown bold/italic from summary before storing in macro_memory
        _milestone_summary=$(echo "$_milestone_summary" | sed 's/\*\+//g')
        _milestone_summary=$(echo "$_milestone_summary" | sed '/^[[:space:]]*$/d' | head -6)
    fi
    [ -z "$_milestone_summary" ] && _milestone_summary="$summary"

    # ── TAG milestone with action class ────────────────────
    local _action_class="ACTION"
    if [ -n "$last_success_cmd" ]; then
        if [[ "$last_success_cmd" == /web* ]]; then
            _action_class="RESEARCH_ONLY"
        elif [[ "$last_success_cmd" == /recall* ]] || [[ "$last_success_cmd" == /ask* ]]; then
            _action_class="RESEARCH_ONLY"
        fi
    else
        _action_class="UNKNOWN"
    fi
    _macro_add_milestone "$macro_file" "$micro_objective" \
        "$_milestone_summary" "${last_success_cmd:-}" "$_action_class"

    if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
        printf '  [debug] macro_memory <- milestone: %s\n' "${_milestone_summary:0:120}" > /dev/tty 2>/dev/null
        printf '  [debug] micro_memory <- COMPLETE: %s\n' "${summary:0:80}" > /dev/tty 2>/dev/null
    fi

    # ── RESEARCH BUFFER: Carry forward web data ────────────
    local _web_outputs
    _web_outputs=$(_micro_web_outputs "$micro_file")
    if [ -n "$_web_outputs" ]; then
        echo "${_web_outputs:0:1500}" > "$george_dir/research_buffer.md"
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] research buffer saved (%d chars)\n' "${#_web_outputs}" > /dev/tty 2>/dev/null
    fi
}

# ── Honeydew List System ──────────────────────────────────────
# A persistent, precedence-ranked task decomposition that gives the
# evaluator and strategist structured visibility into multi-step
# tasks. The LLM decomposes the user's request into numbered
# subtasks at task start. Each subtask is tracked as:
#   1. [ ] Research HiBy M500 specifications
#   2. [ ] Write markdown report with findings
#   3. [ ] Email report to gwbluelodge@gmail.com
#
# The honeydew list persists in .george/honeydew.json and is injected
# into the pass 2 evaluator, strategist, and micro_memory so
# every component can see "2/3 tasks remain" rather than guessing.
#
# Name: "honeydew" is intentional — unique to George, not "todo".
#
# JSON format:
#   {"primary_task":"...", "items":[
#     {"id":1, "task":"...", "status":"pending"},
#     {"id":2, "task":"...", "status":"done"}]}
HONEYDEW_FILE="honeydew.json"

# Build the honeydew list from a user task via LLM decomposition.
# Writes .george/honeydew.json with structured items.
# Args: $1=task text, $2=workdir
_agent_honeydew_build() {
    local task="$1"
    local workdir="${2:-.}"
    local george_dir="$workdir/.george"
    local hd_file="$george_dir/$HONEYDEW_FILE"
    mkdir -p "$george_dir"

    local decompose_prompt="Break this task into a numbered checklist of GENERAL objectives in execution order.

TASK: $task

RULES:
- Output ONLY the numbered list, nothing else.
- Each item: a short imperative sentence describing WHAT to achieve, not HOW.
- Describe the GOAL, never the specific tool or command.
  GOOD: 'Find the weekly weather forecast for Appleton WI'
  BAD:  'Run curl -s https://weather.com/... | grep ...'
  BAD:  'Use /web search to find weather data'
- Do NOT mention specific commands, URLs, tools, or shell syntax.
- 2-5 items maximum. Simple tasks may have just 1-2.
- Order by dependency: research before writing, writing before sending.
- If the task is a single action (e.g., 'send a DM'), output 1-2 items.
- Do NOT include verification, confirmation, or cleanup steps.
- Do NOT prefix with checkboxes — just numbers."

    local decompose_sys="You are a task decomposition engine. Output ONLY a numbered list of general objectives. Each item describes WHAT to accomplish, not HOW or which tool to use. No commands, no URLs, no shell syntax. No explanation, no headers, no markdown formatting. Plain numbered list only."

    local raw_list
    local LLM_SCENARIO=strategist
    raw_list=$(llm_generate "$decompose_prompt" "$decompose_sys" "${LLM_STRATEGIST_TOKENS:-256}" "$LLM_BUDGET_AGENT")

    # Clean think blocks
    raw_list=$(echo "$raw_list" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
    raw_list=$(echo "$raw_list" | sed ':a;N;$!ba;s/<think>.*$//g')
    raw_list=$(echo "$raw_list" | sed 's/\[THINK\][^[]*\[\/THINK\]//gI')
    raw_list=$(echo "$raw_list" | sed ':a;N;$!ba;s/\[THINK\].*$//gI')
    raw_list=$(echo "$raw_list" | sed '/^[[:space:]]*$/d')

    # ── INLINE LIST SPLITTING ─────────────────────────────────
    # Some models (gemma, granite) output all items on one line:
    #   "1. Do thing one  2. Do thing two  3. Do thing three"
    # Split these into separate lines BEFORE the line-by-line parser.
    # Require exactly 1-2 whitespace chars AFTER the period/paren:
    #   - 0 spaces → prose number ("in 2026.The")  → no split
    #   - 1-2 spaces → real list item ("3. Do" / "3.  Do") → split
    #   - 3+ spaces → end-of-sentence padding, not a list item → no split
    # Also limit to 1-2 digit numbers to guard against years/prices.
    raw_list=$(echo "$raw_list" | sed 's/\([^0-9]\)\([0-9]\{1,2\}\.[[:space:]]\{1,2\}\)/\1\n\2/g')
    raw_list=$(echo "$raw_list" | sed 's/\([^0-9]\)\([0-9]\{1,2\})[[:space:]]\{1,2\}\)/\1\n\2/g')

    # Parse numbered lines into JSON array
    local _items_json='[]'
    local count=0
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//')
        if [[ "$line" =~ ^[0-9]{1,2}[\.\)][[:space:]]*(.*) ]]; then
            count=$((count + 1))
            local item="${BASH_REMATCH[1]}"
            item=$(echo "$item" | sed 's/^\[[ x✓]*\][[:space:]]*//')
            _items_json=$(echo "$_items_json" | jq --argjson id "$count" --arg t "$item" \
                '. += [{"id": $id, "task": $t, "status": "pending", "depth": 0}]')
        fi
    done <<< "$raw_list"

    # Fallback: if LLM gave no parseable items, create a single item
    if [ "$count" -eq 0 ]; then
        _items_json=$(jq -n --arg t "$task" '[{"id": 1, "task": $t, "status": "pending", "depth": 0}]')
        count=1
    fi

    # Write honeydew.json
    jq -n --arg task "$task" --argjson items "$_items_json" \
        '{"primary_task": $task, "items": $items}' > "$hd_file"

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] honeydew list built ($count items)"

    # Display the list to TTY — pretty checklist format
    _agent_honeydew_display "$hd_file"
}

# Display honeydew list to TTY in human-readable checklist format.
# Reads JSON, prints: 1. [ ] Task text  or  1. [x] Task text
# Args: $1=honeydew file path
_agent_honeydew_display() {
    local hd_file="$1"
    [ ! -f "$hd_file" ] && return 1

    ui_section "Honeydew List"
    jq -r '.items[] | "\(.id). [\(if .status == "done" then "x" else " " end)] \(.task)"' \
        "$hd_file" 2>/dev/null | while IFS= read -r line; do
        ui_info "$line"
    done
}

# Mark a honeydew item as complete by matching item number.
# Args: $1=item_number, $2=workdir
_agent_honeydew_mark() {
    local item_num="$1"
    local workdir="${2:-.}"
    local hd_file="$workdir/.george/$HONEYDEW_FILE"
    [ ! -f "$hd_file" ] && return 1

    local tmp="${hd_file}.tmp"
    jq --argjson id "$item_num" \
        '.items = [.items[] | if .id == $id then .status = "done" else . end]' \
        "$hd_file" > "$tmp" && mv "$tmp" "$hd_file"
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] honeydew item $item_num marked complete"
}

# Return a structured status summary of the honeydew list.
# Output: "2/5 complete | Next: 3. Research pricing data"
# Args: $1=workdir
_agent_honeydew_status() {
    local workdir="${1:-.}"
    local hd_file="$workdir/.george/$HONEYDEW_FILE"
    [ ! -f "$hd_file" ] && { echo "No honeydew list"; return 1; }

    local _hd_total _hd_done _next_task _next_id
    _hd_total=$(jq '.items | length' "$hd_file" 2>/dev/null || echo 0)
    _hd_done=$(jq '[.items[] | select(.status == "done")] | length' "$hd_file" 2>/dev/null || echo 0)
    _next_id=$(jq -r '[.items[] | select(.status == "pending")][0].id // empty' "$hd_file" 2>/dev/null)
    _next_task=$(jq -r '[.items[] | select(.status == "pending")][0].task // empty' "$hd_file" 2>/dev/null)

    if [ "$_hd_done" -eq "$_hd_total" ] && [ "$_hd_total" -gt 0 ]; then
        echo "${_hd_done}/${_hd_total} complete | All tasks done"
    elif [ -n "$_next_id" ]; then
        echo "${_hd_done}/${_hd_total} complete | Next: ${_next_id}. ${_next_task}"
    else
        echo "${_hd_done}/${_hd_total} complete"
    fi
}

# Return the full honeydew JSON (for injection into prompts).
# Args: $1=workdir
_agent_honeydew_read() {
    local workdir="${1:-.}"
    local hd_file="$workdir/.george/$HONEYDEW_FILE"
    [ ! -f "$hd_file" ] && return 1
    cat "$hd_file"
}

# ── Subtask Decomposition (Single-Level Expansion) ────────────
# When a honeydew item is complex (compound goal, comparisons,
# multi-entity operations), expands it into sub-items IN-PLACE.
#
# This is NOT full recursion — it's a one-shot splice into the
# flat honeydew list. The parent item is replaced with 2-4
# sub-items that inherit the parent's position. Sub-items are
# tagged with depth=1 (or depth=parent+1) and will NOT be
# expanded further once depth reaches AGENT_MAX_DEPTH.
#
# Integration point: called at the TOP of each macro loop
# iteration, BEFORE the strategist picks the next milestone.
# If the next pending item needs expansion, expand it in-place
# so the strategist sees granular sub-items instead of one
# monolithic compound goal.
#
# Design constraints:
#   - No nesting beyond AGENT_MAX_DEPTH (default 2)
#   - Sub-items are purely flat siblings in the items[] array
#   - IDs are renumbered after splice to stay sequential
#   - The primary_task field is never modified

# Heuristic: does a honeydew item look complex enough to
# warrant sub-decomposition? Returns 0 if yes, 1 if no.
# Pure string analysis — no LLM call.
# Args: $1=item text
_agent_honeydew_needs_expansion() {
    local text="$1"
    local lower
    lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

    # ── Complexity signals ─────────────────────────────────────
    # Each pattern targets a specific class of compound goals that
    # a single strategist milestone can't handle atomically.

    # 1. Multi-entity: "compare X and Y", "research A, B, and C"
    #    The model needs separate milestones per entity.
    if [[ "$lower" =~ (compare|contrast|evaluate).*(and|vs|versus) ]]; then
        return 0
    fi

    # 2. "each" / "every" / "all of" — iterative goals
    if [[ "$lower" =~ (for each|for every|each of|all of the|for all) ]]; then
        return 0
    fi

    # 3. Compound conjunction: "research X and write Y" or
    #    "find A then send B" — two distinct actions in one item
    if [[ "$lower" =~ (research|find|gather|search|look up).*(and|then).*(write|send|email|post|create|build|save) ]]; then
        return 0
    fi

    # 4. Explicit list separators: "A, B, and C" pattern
    #    (at least 2 commas + "and" = multi-item enumeration)
    local comma_count
    comma_count=$(echo "$lower" | tr -cd ',' | wc -c)
    if [ "$comma_count" -ge 2 ] && [[ "$lower" =~ " and " ]]; then
        return 0
    fi

    # 5. Long item text (>200 chars) — usually compound goals
    if [ ${#text} -gt 200 ]; then
        return 0
    fi

    return 1
}

# Expand a single honeydew item into sub-items via LLM decomposition.
# Replaces the parent item in-place, renumbers all IDs sequentially.
# Args: $1=item_id, $2=workdir
# Returns: 0 if expanded, 1 if no expansion needed/possible
_agent_honeydew_expand() {
    local item_id="$1"
    local workdir="${2:-.}"
    local hd_file="$workdir/.george/$HONEYDEW_FILE"
    [ ! -f "$hd_file" ] && return 1

    # Read the target item
    local item_text item_depth
    item_text=$(jq -r --argjson id "$item_id" \
        '.items[] | select(.id == $id) | .task' "$hd_file" 2>/dev/null)
    item_depth=$(jq -r --argjson id "$item_id" \
        '.items[] | select(.id == $id) | .depth // 0' "$hd_file" 2>/dev/null)

    [ -z "$item_text" ] && return 1

    # Depth guard: don't expand beyond AGENT_MAX_DEPTH
    local max_depth="${AGENT_MAX_DEPTH:-1}"
    if [ "$item_depth" -ge "$max_depth" ]; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] honeydew expand: item #$item_id at depth $item_depth >= max $max_depth — skipping"
        return 1
    fi

    # Check complexity heuristic
    if ! _agent_honeydew_needs_expansion "$item_text"; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] honeydew expand: item #$item_id not complex enough — skipping"
        return 1
    fi

    # ── LLM decomposition of the single item ──────────────────
    local sub_depth=$((item_depth + 1))

    local expand_prompt="Break this objective into 2-4 smaller sub-steps in execution order.

OBJECTIVE: $item_text

RULES:
- Output ONLY a numbered list (2-4 items).
- Each sub-step: a short imperative sentence describing WHAT, not HOW.
- Do NOT mention commands, URLs, tools, or shell syntax.
- Order by dependency (research before writing, writing before sending).
- Do NOT include verification or cleanup steps.
- Keep each sub-step atomic — achievable in a single action."

    local expand_sys="You are a task decomposition engine. Break ONE complex objective into 2-4 atomic sub-steps. Output ONLY a numbered list. No commands, no URLs, no explanation. Plain numbered list only."

    ui_think "Expanding honeydew item #${item_id} into sub-tasks..."
    local raw_list
    local LLM_SCENARIO=strategist
    raw_list=$(llm_generate "$expand_prompt" "$expand_sys" "${LLM_STRATEGIST_TOKENS:-256}" "$LLM_BUDGET_AGENT")

    # Clean think blocks (same pipeline as _agent_honeydew_build)
    raw_list=$(echo "$raw_list" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
    raw_list=$(echo "$raw_list" | sed ':a;N;$!ba;s/<think>.*$//g')
    raw_list=$(echo "$raw_list" | sed 's/\[THINK\][^[]*\[\/THINK\]//gI')
    raw_list=$(echo "$raw_list" | sed ':a;N;$!ba;s/\[THINK\].*$//gI')
    raw_list=$(echo "$raw_list" | sed '/^[[:space:]]*$/d')

    # Inline list splitting (same as _agent_honeydew_build)
    raw_list=$(echo "$raw_list" | sed 's/\([^0-9]\)\([0-9]\{1,2\}\.[[:space:]]\{1,2\}\)/\1\n\2/g')
    raw_list=$(echo "$raw_list" | sed 's/\([^0-9]\)\([0-9]\{1,2\})[[:space:]]\{1,2\}\)/\1\n\2/g')

    # Parse numbered lines
    local _sub_items='[]'
    local sub_count=0
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//')
        if [[ "$line" =~ ^[0-9]{1,2}[\.\)][[:space:]]*(.*) ]]; then
            sub_count=$((sub_count + 1))
            local sub_item="${BASH_REMATCH[1]}"
            sub_item=$(echo "$sub_item" | sed 's/^\[[ x✓]*\][[:space:]]*//')
            _sub_items=$(echo "$_sub_items" | jq --arg t "$sub_item" --argjson d "$sub_depth" \
                '. += [{"task": $t, "status": "pending", "depth": $d}]')
        fi
    done <<< "$raw_list"

    # Need at least 2 sub-items for expansion to be worthwhile
    if [ "$sub_count" -lt 2 ]; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] honeydew expand: LLM produced $sub_count items — not enough, keeping original"
        return 1
    fi

    # ── Splice sub-items into honeydew list ───────────────────
    # Strategy: collect items before the target, add sub-items,
    # collect items after the target, renumber all IDs sequentially.
    local tmp="${hd_file}.tmp"
    jq --argjson id "$item_id" --argjson subs "$_sub_items" '
        .items = (
            [.items[] | select(.id < $id)] +
            $subs +
            [.items[] | select(.id > $id)]
        ) |
        .items = [.items | to_entries[] | .value + {"id": (.key + 1)}]
    ' "$hd_file" > "$tmp" && mv "$tmp" "$hd_file"

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] honeydew expand: item #$item_id -> $sub_count sub-items (depth=$sub_depth)"

    # Display the updated list
    _agent_honeydew_display "$hd_file"
    return 0
}

# Check if the next pending honeydew item needs expansion and
# expand it if so. Called at top of each macro loop iteration.
# Args: $1=workdir
_agent_honeydew_maybe_expand() {
    local workdir="${1:-.}"
    local hd_file="$workdir/.george/$HONEYDEW_FILE"
    [ ! -f "$hd_file" ] && return 1

    # ── Master toggle: expansion disabled by default ───────────
    # On edge hardware (2-4B models) the LLM lacks the context
    # window to detect macro-redundancy, causing fractal task
    # explosion. Enable only when the model/hardware can handle it.
    if [ "${AGENT_HONEYDEW_EXPAND:-0}" -ne 1 ]; then
        return 1
    fi

    # ── Item count cap: stop expanding bloated lists ───────────
    # Even when enabled, don't expand if the list is already large.
    local _hd_item_count
    _hd_item_count=$(jq '.items | length' "$hd_file" 2>/dev/null || echo 0)
    local _max_items="${AGENT_HONEYDEW_MAX_ITEMS:-8}"
    if [ "$_hd_item_count" -ge "$_max_items" ]; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] honeydew expand: list already has $_hd_item_count items (max $_max_items) — suppressed"
        return 1
    fi

    # Find the next pending item
    local next_id next_depth next_task
    next_id=$(jq -r '[.items[] | select(.status == "pending")][0].id // empty' "$hd_file" 2>/dev/null)
    [ -z "$next_id" ] && return 1

    next_depth=$(jq -r --argjson id "$next_id" \
        '.items[] | select(.id == $id) | .depth // 0' "$hd_file" 2>/dev/null)
    next_task=$(jq -r --argjson id "$next_id" \
        '.items[] | select(.id == $id) | .task // empty' "$hd_file" 2>/dev/null)

    # Already at max depth — skip
    local max_depth="${AGENT_MAX_DEPTH:-1}"
    if [ "${next_depth:-0}" -ge "$max_depth" ]; then
        return 1
    fi

    # ── Redundancy guard: skip if siblings already cover this ──
    # Extract keywords from the target item and compare against
    # other pending items. If >=60% of the target's keywords
    # already appear in sibling items, expansion would just
    # produce duplicates (the fractal explosion pattern).
    if [ -n "$next_task" ]; then
        local _target_words _sibling_text _overlap=0 _total=0
        _target_words=$(echo "$next_task" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alpha:]' '\n' | sort -u | grep -E '.{4,}')
        _sibling_text=$(jq -r --argjson id "$next_id" \
            '[.items[] | select(.status == "pending" and .id != $id) | .task] | join(" ")' \
            "$hd_file" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        while IFS= read -r word; do
            [ -z "$word" ] && continue
            _total=$((_total + 1))
            if echo "$_sibling_text" | grep -qw "$word"; then
                _overlap=$((_overlap + 1))
            fi
        done <<< "$_target_words"
        if [ "$_total" -gt 0 ]; then
            local _pct=$(( (_overlap * 100) / _total ))
            if [ "$_pct" -ge 60 ]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] honeydew expand: item #$next_id has ${_pct}% keyword overlap with siblings — redundant, skipping"
                return 1
            fi
        fi
    fi

    # Try expansion (heuristic + LLM)
    _agent_honeydew_expand "$next_id" "$workdir"
}

# Match a completed milestone against honeydew items and mark
# the best-matching item as done. Uses simple keyword overlap.
# Args: $1=milestone_text, $2=workdir, $3=macro_file (optional)
_agent_honeydew_auto_check() {
    local milestone="$1"
    local workdir="${2:-.}"
    local macro_file="${3:-}"
    local hd_file="$workdir/.george/$HONEYDEW_FILE"
    [ ! -f "$hd_file" ] && return 1

    # Build combined match text from milestone + last milestone summary.
    # The strategist milestone is often a bare slash command ("/web search X")
    # with minimal vocabulary overlap against high-level honeydew items.
    # The milestone summary (written by _agent_complete_milestone) contains
    # rich factual keywords that match honeydew descriptions much better.
    local match_text="$milestone"
    if [ -n "$macro_file" ] && [ -f "$macro_file" ]; then
        local _last_summary
        _last_summary=$(jq -r '.completed_milestones[-1].summary // empty' "$macro_file" 2>/dev/null)
        [ -n "$_last_summary" ] && match_text="${match_text} ${_last_summary}"
    fi

    local milestone_lower
    milestone_lower=$(echo "$match_text" | tr '[:upper:]' '[:lower:]')

    # Iterate pending items and find best keyword match
    local best_num=0
    local best_score=0
    local _pending_items
    _pending_items=$(jq -r '.items[] | select(.status == "pending") | "\(.id)|\(.task)"' "$hd_file" 2>/dev/null)

    while IFS='|' read -r item_num item_text; do
        [ -z "$item_num" ] && continue
        local item_lower score=0
        item_lower=$(echo "$item_text" | tr '[:upper:]' '[:lower:]')

        # Score: count shared words (>3 chars) between milestone and item
        for word in $item_lower; do
            [ ${#word} -le 3 ] && continue
            if [[ "$milestone_lower" == *"$word"* ]]; then
                score=$((score + 1))
            fi
        done

        if [ "$score" -gt "$best_score" ]; then
            best_score=$score
            best_num=$item_num
        fi
    done <<< "$_pending_items"

    # Require minimum keyword overlap to auto-check
    if [ "$best_score" -ge "${AGENT_HONEYDEW_MATCH:-2}" ] && [ "$best_num" -gt 0 ]; then
        _agent_honeydew_mark "$best_num" "$workdir"
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] honeydew auto-check: item $best_num (score=$best_score)"
        return 0
    fi

    return 1
}

# ── Honeydew Item Evaluator ───────────────────────────────────
# LLM-based evaluation of whether a completed milestone satisfies
# the CURRENT honeydew item. Called AFTER the milestone P1 eval
# confirms the milestone succeeded and the rich summary is created.
#
# This is SEPARATE from the milestone evaluator (P1) and the
# overall evaluator (P2):
#   P1: Did the milestone's actions succeed? (inside inner loop)
#   Honeydew: Did the milestone satisfy the current honeydew item?
#   P2: Are ALL honeydew items done?
#
# Returns 0 if the honeydew item is satisfied, 1 if not.
# Sets _EVAL_HONEYDEW_REASON on failure.
# Sets _EVAL_HONEYDEW_ITEM_NUM to the item number evaluated.
_agent_evaluate_honeydew_item() {
    local macro_file="$1"
    local micro_file="$2"
    local milestone_text="$3"
    local workdir="${4:-.}"

    local hd_file="$workdir/.george/$HONEYDEW_FILE"
    [ ! -f "$hd_file" ] && return 0  # no honeydew = pass through

    # Find the first pending honeydew item
    local _next_id _next_task
    _next_id=$(jq -r '[.items[] | select(.status == "pending")][0].id // empty' "$hd_file" 2>/dev/null)
    _next_task=$(jq -r '[.items[] | select(.status == "pending")][0].task // empty' "$hd_file" 2>/dev/null)

    if [ -z "$_next_id" ] || [ -z "$_next_task" ]; then
        # All items already done
        _EVAL_HONEYDEW_ITEM_NUM=""
        return 0
    fi

    _EVAL_HONEYDEW_ITEM_NUM="$_next_id"

    # Build context: milestone summary from macro_memory (the rich
    # summary just written by _agent_complete_milestone) + action log
    local _milestone_summary=""
    if [ -f "$macro_file" ]; then
        _milestone_summary=$(jq -r '.completed_milestones[-1].summary // empty' "$macro_file" 2>/dev/null)
    fi

    local eval_context=""
    if [ -n "$micro_file" ] && [ -f "$micro_file" ]; then
        # Use higher output limit (2048) for honeydew eval — the default
        # 1024 truncates web search results and the evaluator can't see
        # URLs/snippets needed to judge whether research was sufficient.
        eval_context=$(_micro_serialize_eval "$micro_file" 10 2048)
    fi

    local _eval_now
    _eval_now=$(date '+%Y-%m-%d %H:%M:%S %Z')

    local eval_prompt="CURRENT DATE/TIME: ${_eval_now}\n\nMILESTONE COMPLETED:\n${milestone_text}\n\nMILESTONE SUMMARY:\n${_milestone_summary:-No summary available.}\n\nACTION LOG:\n${eval_context:-No actions available.}\n\n---\n\nHONEYDEW ITEM TO EVALUATE (item #${_next_id}):\n${_next_task}\n\nDoes the completed milestone SATISFY this honeydew item? The milestone does not need to match exactly — if the work accomplished meaningfully addresses the honeydew item's goal, it is SATISFIED.\n\nRespond: SATISFIED or UNSATISFIED: <reason>. <recommendation>\nIf UNSATISFIED, explain WHY (what is missing or wrong) and RECOMMEND the next action (e.g. 'Try /web fetch <url> to get the actual page content' or 'The search returned results but no fetch was done — use /web fetch on result URL')."

    local eval_sys="You are a honeydew item evaluator. Judge whether a completed milestone satisfies a specific task item. Be pragmatic: if the milestone's work meaningfully addresses the item's goal, it is SATISFIED. Do not require perfection. No markdown formatting. Respond SATISFIED or UNSATISFIED: <reason>. <recommendation>. If unsatisfied, explain what is missing and recommend the specific next action."

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: honeydew-eval <- item #${_next_id}: ${_next_task:0:80}"
    ui_think "Honeydew evaluator: checking item #${_next_id}..."
    local verdict
    local LLM_SCENARIO=evaluator
    verdict=$(llm_generate "$eval_prompt" "$eval_sys" "${LLM_EVALUATOR_TOKENS:-256}" "$LLM_BUDGET_AGENT")

    # ── DEBUG: Honeydew evaluator raw verdict ───────────────────
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] honeydew-eval raw verdict: %s\n' "$(echo "$verdict" | tr '\n' ' ' | head -c 200)" > /dev/tty 2>/dev/null

    # Clean up LLM output
    verdict=$(echo "$verdict" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
    verdict=$(echo "$verdict" | sed 's/\[THINK\][^[]*\[\/THINK\]//gI')
    verdict=$(echo "$verdict" | sed ':a;N;$!ba;s/<think>.*$//g')
    verdict=$(echo "$verdict" | sed ':a;N;$!ba;s/\[THINK\].*$//gI')
    verdict=$(echo "$verdict" | sed 's/\*\+//g')
    verdict=$(echo "$verdict" | sed '/^[[:space:]]*$/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    local first_line
    first_line=$(echo "$verdict" | head -1)
    local verdict_word
    # Extract just the verdict keyword — strip punctuation AND handle
    # "UNSATISFIED:reason" (no space after colon) by splitting on colon first.
    verdict_word=$(echo "$first_line" | awk -F'[: \t]' '{print $1}' | sed 's/^[*_]\+//;s/[*_.,]\+$//')

    _EVAL_HONEYDEW_REASON=""
    if [[ "$verdict_word" == "SATISFIED" ]]; then
        ui_ok "Honeydew evaluator: item #${_next_id} satisfied"
        return 0
    else
        if [[ "$first_line" == *":"* ]]; then
            _EVAL_HONEYDEW_REASON=$(echo "$first_line" | sed 's/^[^:]*:[[:space:]]*//')
        elif [ "$(echo "$first_line" | wc -w)" -gt 1 ]; then
            _EVAL_HONEYDEW_REASON=$(echo "$first_line" | sed 's/^[^ ]* *//')
        fi
        # Multi-line verdicts: append lines 2-4 for richer context
        local _extra_lines
        _extra_lines=$(echo "$verdict" | sed -n '2,4p' | sed '/^[[:space:]]*$/d')
        if [ -n "$_extra_lines" ]; then
            _EVAL_HONEYDEW_REASON="${_EVAL_HONEYDEW_REASON:+${_EVAL_HONEYDEW_REASON} }$(echo "$_extra_lines" | tr '\n' ' ')"
        fi
        local _reason_display="${_EVAL_HONEYDEW_REASON:+(${_EVAL_HONEYDEW_REASON:0:200})}"
        ui_info "Honeydew evaluator: item #${_next_id} not yet satisfied ${_reason_display}"
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] honeydew-eval full verdict:\n%s\n' "$verdict" > /dev/tty 2>/dev/null
        return 1
    fi
}

# ── Dual Evaluator System ─────────────────────────────────────
# Two-pass evaluation after each milestone:
#
# Pass 1 — _agent_evaluate_milestone():
#   Pragmatic check: did the action log show this specific milestone
#   was executed? Exit 0 = success, empty output = normal.
#   Sets _EVAL_MILESTONE_REASON on failure.
#
# Pass 2 — _agent_evaluate_completion():
#   Strategic check: given ALL milestones completed so far, is the
#   user's original request fully satisfied? Uses macro_memory (full
#   milestone history) supplemented by recent micro_memory.
#   Sets _EVAL_INCOMPLETE_REASON on failure.
#   Includes interactive/auto mode handling for task completion.
#
# Modes (AGENT_EVAL_MODE):
#   auto        — (default) Silently finish the task chain with a summary.
#   interactive — Prompt the operator to confirm satisfaction or continue.
#   disabled    — Skip evaluation entirely.

# ── Pass 1: Milestone Evaluator ───────────────────────────────
# Focused, pragmatic check on whether a SPECIFIC milestone was
# achieved by examining the micro_memory action log. Avoids the
# goalpost-moving that occurs when evaluating the entire objective
# during every single milestone.
_agent_evaluate_milestone() {
    local macro_file="$1"
    local micro_file="$2"
    local milestone_text="$3"

    # Read micro_memory action log ONLY for this milestone.
    # P1 should judge THIS milestone's actions in isolation — not
    # carryover context like prior_milestones or research_context
    # which can confuse the 4B model into thinking prior work counts.
    local eval_context=""
    if [ -n "$micro_file" ] && [ -f "$micro_file" ]; then
        eval_context=$(_micro_serialize_eval "$micro_file")
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: milestone-eval <- micro_memory action_log ($(echo "$eval_context" | wc -l) lines)"
    else
        ui_info "Milestone evaluator: no micro_memory available"
        return 1
    fi

    # Truncate to prevent attention dilution
    local _max_ctx_lines
    _max_ctx_lines=$(_agent_thinking_context_limit "${AGENT_EVAL_CONTEXT_LINES:-50}")
    local _ctx_total
    _ctx_total=$(echo "$eval_context" | wc -l)
    if [ "$_ctx_total" -gt "$_max_ctx_lines" ]; then
        eval_context=$(echo "$eval_context" | tail -n "$_max_ctx_lines")
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] milestone-eval context truncated: $_ctx_total -> $_max_ctx_lines lines"
    fi

    # ATTENTION REORDER: Action log FIRST, milestone LAST (recency bias)
    local _eval_now
    _eval_now=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local eval_prompt="CURRENT DATE/TIME: ${_eval_now}\n\nACTION LOG (from the current milestone execution):\n${eval_context}\n\n---\n\nMILESTONE TO EVALUATE:\n${milestone_text}\n\nDid the actions above accomplish this milestone? Apply the EVAL SCHEMA below.\n\n$(cat << 'EVAL_P1_JSON'
{"classify":"COMPLETE|INCOMPLETE",
 "default":{"exit_0":"COMPLETE","empty_output":"normal (email/social/file)"},
 "scope":"THIS milestone only",
 "no_extras":"no confirmation/follow-up unless milestone asked",
 "code":{
   "write":"meaningful non-trivial code required",
   "init":"key files created (Cargo.toml+src/main.rs, package.json+index.js)",
   "build":"/build exit_0 required — /write alone NOT enough",
   "web_only":"INCOMPLETE",
   "reject":["todo","unimplemented","placeholder","stub","panic!()","empty body"]},
 "respond":"COMPLETE or INCOMPLETE: <reason>"}
EVAL_P1_JSON
)"

    local eval_sys="You are a pragmatic milestone evaluator. Judge by the action log. exit_0 = success. Empty output = normal. No markdown formatting. Respond COMPLETE or INCOMPLETE: <reason>."

    ui_think "Evaluator (pass 1): assessing milestone completion..."
    local verdict
    local LLM_SCENARIO=evaluator
    verdict=$(llm_generate "$eval_prompt" "$eval_sys" "${LLM_EVALUATOR_TOKENS:-256}" "$LLM_BUDGET_AGENT")

    # ── DEBUG: Evaluator raw verdict ────────────────────────────
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] eval-p1 raw verdict: %s\n' "$(echo "$verdict" | tr '\n' ' ' | head -c 200)" > /dev/tty 2>/dev/null

    # Clean up LLM output — strip think blocks, markdown, whitespace
    verdict=$(echo "$verdict" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
    verdict=$(echo "$verdict" | sed 's/\[THINK\][^[]*\[\/THINK\]//gI')
    # Strip unclosed think blocks (token limit truncated before closing tag)
    verdict=$(echo "$verdict" | sed ':a;N;$!ba;s/<think>.*$//g')
    verdict=$(echo "$verdict" | sed ':a;N;$!ba;s/\[THINK\].*$//gI')
    # Strip markdown bold/italic — prevents contamination when verdict
    # is re-injected into strategist as _last_eval_feedback.
    verdict=$(echo "$verdict" | sed 's/\*\+//g')
    verdict=$(echo "$verdict" | sed '/^[[:space:]]*$/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    local first_line
    first_line=$(echo "$verdict" | head -1)
    local verdict_word
    verdict_word=$(echo "$first_line" | awk '{print $1}' | sed 's/^[*_]\+//;s/[*_:.,]\+$//')

    # Parse INCOMPLETE reason
    _EVAL_MILESTONE_REASON=""
    if [[ "$verdict_word" != "COMPLETE" ]]; then
        if [[ "$first_line" == *":"* ]]; then
            _EVAL_MILESTONE_REASON=$(echo "$first_line" | sed 's/^[^:]*:[[:space:]]*//')
        elif [ "$(echo "$first_line" | wc -w)" -gt 1 ]; then
            _EVAL_MILESTONE_REASON=$(echo "$first_line" | sed 's/^[^ ]* *//')
        fi
        if [ -z "$_EVAL_MILESTONE_REASON" ] && [ "$(echo "$verdict" | wc -l)" -gt 1 ]; then
            _EVAL_MILESTONE_REASON=$(echo "$verdict" | head -3)
        fi
        local _reason_display="${_EVAL_MILESTONE_REASON:+(${_EVAL_MILESTONE_REASON:0:80})}"
        ui_info "Milestone evaluator: not complete ${_reason_display}"
        return 1
    fi

    # ── Contradiction guard ─────────────────────────────────
    # Small models sometimes emit "COMPLETE: the milestone was not
    # achieved..." where the verdict word contradicts the explanation.
    # If the reason text after the colon negates the verdict, override.
    if [[ "$first_line" == *":"* ]]; then
        local _complete_reason
        _complete_reason=$(echo "$first_line" | sed 's/^[^:]*:[[:space:]]*//')
        if echo "$_complete_reason" | grep -qiE 'not (achieved|accomplished|completed|done|successful|satisfied)|fail(ed|ure)?|unable|could not|cannot|did not|wasn.t|weren.t|isn.t|does not exist|incomplete'; then
            _EVAL_MILESTONE_REASON="$_complete_reason"
            local _reason_display="${_EVAL_MILESTONE_REASON:+(${_EVAL_MILESTONE_REASON:0:80})}"
            ui_warn "Milestone evaluator: overrode contradictory COMPLETE ${_reason_display}"
            return 1
        fi
    fi

    ui_ok "Milestone evaluator: milestone achieved"
    return 0
}

# ── Pass 2: Overall Task Evaluator ─────────────────────────────
# Strategic check on whether the PRIMARY OBJECTIVE (the user's
# original request) has been satisfied by all milestones completed
# so far. Uses macro_memory (full milestone history) supplemented
# by recent micro_memory actions for detail.
#
# Returns 0 if the task is complete, 1 if work remains.
_agent_evaluate_completion() {
    local macro_file="$1"
    local micro_file="$2"

    # ── HARD HONEYDEW GATE ─────────────────────────────────────
    # When a honeydew list exists, completion is DETERMINISTIC:
    # all items done → COMPLETE, any pending → INCOMPLETE.
    # No LLM heuristics — each item was already individually
    # evaluated by the honeydew item evaluator + P1. The LLM-based
    # P2 path is reserved for tasks without a honeydew list.
    local _hd_eval_file_check
    _hd_eval_file_check="$(dirname "$macro_file")/$HONEYDEW_FILE"
    if [ -f "$_hd_eval_file_check" ]; then
        local _hd_gate_total _hd_gate_done _hd_gate_pending
        _hd_gate_total=$(jq '.items | length' "$_hd_eval_file_check" 2>/dev/null || echo 0)
        _hd_gate_done=$(jq '[.items[] | select(.status == "done")] | length' "$_hd_eval_file_check" 2>/dev/null || echo 0)
        _hd_gate_pending=$((_hd_gate_total - _hd_gate_done))

        if [ "$_hd_gate_total" -gt 0 ] && [ "$_hd_gate_pending" -gt 0 ]; then
            _EVAL_INCOMPLETE_REASON="${_hd_gate_done}/${_hd_gate_total} honeydew items addressed — ${_hd_gate_pending} still pending"
            local _reason_display="(${_EVAL_INCOMPLETE_REASON})"
            ui_info "Overall evaluator: ${_reason_display} — continuing"
            return 1
        fi

        if [ "$_hd_gate_total" -gt 0 ] && [ "$_hd_gate_pending" -eq 0 ]; then
            _EVAL_COMPLETE_REASON="All ${_hd_gate_total} honeydew items completed"
            ui_ok "Overall evaluator: $_EVAL_COMPLETE_REASON"

            if [[ "${AGENT_EVAL_MODE:-auto}" == "interactive" ]]; then
                echo ""
                ui_info "All honeydew items completed. The evaluator believes the task is done."
                printf " %b%s%b %b%s%b " "\033[1;37m" "Are you satisfied with the result?" "\033[0m" "\033[2m" "[Y/n]" "\033[0m"
                local answer
                read -r answer < /dev/tty 2>/dev/null || answer="y"
                answer="${answer:-y}"
                if [[ "${answer,,}" == "y"* ]]; then
                    echo ""
                    ui_ok "Task complete — $_EVAL_COMPLETE_REASON"
                    return 0
                else
                    ui_info "Continuing work — operator requested more progress"
                    return 1
                fi
            fi

            echo ""
            ui_ok "Task complete — $_EVAL_COMPLETE_REASON"
            return 0
        fi
        # _hd_gate_total is 0 — empty/malformed honeydew, fall through to LLM
    fi

    # ── No honeydew list — LLM-based P2 evaluation ────────────
    local primary_obj=""
    primary_obj=$(_macro_get "$macro_file" "primary_objective")
    [ -z "$primary_obj" ] && { ui_info "Overall evaluator: no primary objective found"; return 1; }

    # Use macro_memory without persona for evaluation context.
    # The persona (~200 tokens of identity text) adds no value for
    # task-completion judgment and wastes context on 4B models.
    local macro_context
    macro_context=$(_macro_serialize_lean "$macro_file")
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: overall-eval <- macro_memory lean ($(echo "$macro_context" | wc -l) lines)"

    # Supplement with recent micro_memory for action-level detail
    # CRITICAL: P2 needs SUFFICIENT context to distinguish "research done"
    # from "task fully complete". Previously capped at 30 lines — too low
    # for the evaluator to see what actions ACTUALLY ran. Match the context
    # depth of the final task summarizer so P2 has the same judgment quality.
    local micro_context=""
    local _micro_ctx_max
    _micro_ctx_max=$(_agent_thinking_context_limit 60)
    if [ -n "$micro_file" ] && [ -f "$micro_file" ]; then
        local _micro_lines
        _micro_lines=$(wc -l < "$micro_file")
        if [ "$_micro_lines" -gt "$_micro_ctx_max" ]; then
            micro_context=$(tail -n "$_micro_ctx_max" "$micro_file")
        else
            micro_context=$(cat "$micro_file")
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: overall-eval <- micro_memory supplement (${_micro_lines} lines)"
    fi

    # ATTENTION REORDER: context first, objective + criteria last
    local _eval_now
    _eval_now=$(date '+%Y-%m-%d %H:%M:%S %Z')

    # No honeydew list exists at this point (the hard gate above
    # handles all honeydew cases). Build the objective from primary_obj.
    local _obj_block="PRIMARY OBJECTIVE:\n${primary_obj}"

    local eval_prompt="CURRENT DATE/TIME: ${_eval_now}\n\nTASK MEMORY (all milestones completed so far):\n${macro_context}\n\nLATEST ACTION DETAILS:\n${micro_context:-No recent actions available.}\n\n---\n\n${_obj_block}\n\nAre all completion criteria fully satisfied? Apply the EVAL SCHEMA below.\n\n$(cat << 'EVAL_P2_JSON'
{"classify":"COMPLETE|INCOMPLETE",
 "default":{"actions_exit_0":"COMPLETE","no_extras":true},
 "action_class":{
   "RESEARCH_ONLY":"does NOT satisfy delivery",
   "ACTION":{"exit_0":"COMPLETE"}},
 "parts":{"single":"1 correct milestone = COMPLETE",
   "multi":"each part needs own milestone+action_class"},
 "code":{"require":["files_written","build_exit_0"],
   "reject":["todo","stub","panic","placeholder"],
   "web_only":"INCOMPLETE"},
 "content":{"require":["actual_content","delivery_command"],
   "reject":["placeholder","announcement_only","stub_body"],
   "email":"body must be substantive"},
 "delivery":{"need_both":"research + delivery (/respond,/write,/email,/save,/social)",
   "summary_!=_delivery":true,
   "check":"ACTUAL delivery commands in milestones"},
 "respond":"COMPLETE or INCOMPLETE: <what was accomplished or what remains>"}
EVAL_P2_JSON
)"

    local eval_sys="You are a task-completion evaluator. Be pragmatic: actions executed successfully = done. Check Action-Class tags: RESEARCH_ONLY does not satisfy delivery. For code: must compile. For content: must exist in output. No markdown formatting. Respond COMPLETE or INCOMPLETE: <reason>."

    ui_think "Evaluator (pass 2): assessing overall task completion..."
    local verdict
    local LLM_SCENARIO=evaluator
    verdict=$(llm_generate "$eval_prompt" "$eval_sys" "${LLM_EVALUATOR_TOKENS:-512}" "$LLM_BUDGET_AGENT")

    # ── DEBUG: Evaluator raw verdict ────────────────────────────
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] eval-p2 raw verdict: %s\n' "$(echo "$verdict" | tr '\n' ' ' | head -c 200)" > /dev/tty 2>/dev/null

    # Clean up LLM output — strip think blocks, markdown, whitespace
    verdict=$(echo "$verdict" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
    verdict=$(echo "$verdict" | sed 's/\[THINK\][^[]*\[\/THINK\]//gI')
    # Strip unclosed think blocks (token limit truncated before closing tag)
    verdict=$(echo "$verdict" | sed ':a;N;$!ba;s/<think>.*$//g')
    verdict=$(echo "$verdict" | sed ':a;N;$!ba;s/\[THINK\].*$//gI')
    # Strip markdown bold/italic — prevents contamination when verdict
    # is re-injected into strategist as _last_eval_feedback.
    verdict=$(echo "$verdict" | sed 's/\*\+//g')
    verdict=$(echo "$verdict" | sed '/^[[:space:]]*$/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    local first_line
    first_line=$(echo "$verdict" | head -1)
    local verdict_word
    verdict_word=$(echo "$first_line" | awk '{print $1}' | sed 's/^[*_]\+//;s/[*_:.,]\+$//')

    # Extract reason text from verdict (used for both COMPLETE and INCOMPLETE)
    local _eval_reason=""
    if [[ "$first_line" == *":"* ]]; then
        _eval_reason=$(echo "$first_line" | sed 's/^[^:]*:[[:space:]]*//')
    elif [ "$(echo "$first_line" | wc -w)" -gt 1 ]; then
        _eval_reason=$(echo "$first_line" | sed 's/^[^ ]* *//')
    fi
    if [ -z "$_eval_reason" ] && [ "$(echo "$verdict" | wc -l)" -gt 1 ]; then
        _eval_reason=$(echo "$verdict" | head -3)
    fi

    _EVAL_INCOMPLETE_REASON=""
    if [[ "$verdict_word" != "COMPLETE" ]]; then
        _EVAL_INCOMPLETE_REASON="$_eval_reason"
        local _reason_display="${_EVAL_INCOMPLETE_REASON:+(${_EVAL_INCOMPLETE_REASON:0:80})}"
        ui_info "Overall evaluator: objective not yet fulfilled ${_reason_display}— continuing"
        return 1
    fi

    # ── Task is complete — reuse evaluator reason as summary ───
    # The P2 evaluator already explains what was accomplished.
    # No separate summarizer LLM call needed — saves ~10-15s.
    _EVAL_COMPLETE_REASON="${_eval_reason:-primary objective fulfilled}"
    ui_ok "Overall evaluator: primary objective fulfilled"

    if [[ "${AGENT_EVAL_MODE:-auto}" == "interactive" ]]; then
        # Interactive mode: ask the operator
        echo ""
        ui_info "The evaluator believes the original request has been completed."
        printf " %b%s%b %b%s%b " "\033[1;37m" "Are you satisfied with the result?" "\033[0m" "\033[2m" "[Y/n]" "\033[0m"
        local answer
        read -r answer < /dev/tty 2>/dev/null || answer="y"
        answer="${answer:-y}"
        if [[ "${answer,,}" == "y"* ]]; then
            echo ""
            ui_ok "Summary: $_EVAL_COMPLETE_REASON"
            return 0
        else
            ui_info "Continuing work — operator requested more progress"
            return 1
        fi
    fi

    # Auto mode (default): display evaluator reason as summary
    echo ""
    ui_ok "Task complete — $_EVAL_COMPLETE_REASON"
    return 0
}

# ── Normalize inline plans ─────────────────────────────────────
# LLMs sometimes output all steps on one line:
#   "1. step one  2. step two  3. step three"
# This splits them into separate lines for the parser.
_agent_split_inline_steps() {
    local plan="$1"
    # Insert newline before step numbers preceded by 2+ spaces
    # Handles both "N." and "N)" formats
    echo "$plan" | sed 's/  \+\([0-9]\+[.)]\) /\n\1 /g'
}

# ── Check for critical errors needing user assistance ──────────
# Returns 0 (true) if the error message indicates a problem that
# requires user intervention: missing API keys, missing packages,
# missing authentication credentials, or slash command failures.
_agent_is_critical_error() {
    local error_msg="$1"
    [ -z "$error_msg" ] && return 1
    local lower
    lower=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')

    # Missing API key
    [[ "$lower" == *"api key"* ]] && return 0
    [[ "$lower" == *"api_key"* ]] && return 0
    [[ "$lower" == *"apikey"* ]] && return 0

    # Missing package / dependency
    [[ "$lower" == *"not installed"* ]] && return 0
    [[ "$lower" == *"command not found"* ]] && return 0
    [[ "$lower" == *"module not found"* ]] && return 0
    [[ "$lower" == *"package"*"missing"* ]] && return 0

    # Authentication / credentials
    [[ "$lower" == *"authentication"* ]] && return 0
    [[ "$lower" == *"credentials"* ]] && return 0
    [[ "$lower" == *"unauthorized"* ]] && return 0
    [[ "$lower" == *"permission denied"* ]] && return 0
    [[ "$lower" == *"access denied"* ]] && return 0

    return 1
}

# Track the last error from agent loops for critical error detection
_AGENT_LAST_ERROR=""

# ── Auto-fix: infer sandbox type from step context ─────────────
# Given a sandbox name and surrounding plan context, infers whether
# it should be rust, python, or shell.
_agent_infer_sandbox_type() {
    local name="$1"
    local context="$2"  # full plan text or step list
    local lower
    lower=$(echo "$context $name" | tr '[:upper:]' '[:lower:]')

    # Strong signals from the commands being run
    if [[ "$lower" == *"cargo "* ]] || [[ "$lower" == *"rustc"* ]] || [[ "$lower" == *".rs"* ]] || [[ "$lower" == *"Cargo.toml"* ]]; then
        echo "rust"; return
    fi
    if [[ "$lower" == *"pip "* ]] || [[ "$lower" == *"uv "* ]] || [[ "$lower" == *"python"* ]] || [[ "$lower" == *".py"* ]] || [[ "$lower" == *"pytest"* ]]; then
        echo "python"; return
    fi
    # Name-based heuristics
    if [[ "$name" == *rust* ]] || [[ "$name" == *cargo* ]] || [[ "$name" == *crate* ]]; then
        echo "rust"; return
    fi
    if [[ "$name" == *python* ]] || [[ "$name" == *py* ]] || [[ "$name" == *flask* ]] || [[ "$name" == *django* ]]; then
        echo "python"; return
    fi
    echo "shell"
}

# ── Auto-fix: create a missing sandbox ─────────────────────────
# If a /sandbox command fails because the sandbox doesn't exist,
# infer the type and create it automatically.
_agent_auto_create_sandbox() {
    local step="$1"
    local plan_context="$2"

    # Extract sandbox name from the step
    local sandbox_name=""
    if [[ "$step" =~ ^/sandbox\ +[a-z]+\ +([^ ]+) ]]; then
        sandbox_name="${BASH_REMATCH[1]}"
    fi
    [ -z "$sandbox_name" ] && return 1

    # Only act if the sandbox doesn't exist
    local sandbox_dir="${LODGE_SANDBOXES:-${LODGE_DIR:-.}/.sandboxes}/$sandbox_name"
    [ -d "$sandbox_dir" ] && return 1

    # Infer the type
    local inferred_type
    inferred_type=$(_agent_infer_sandbox_type "$sandbox_name" "$plan_context")

    ui_warn "Sandbox '$sandbox_name' not found — auto-creating as $inferred_type"
    if declare -f sandbox_create &>/dev/null; then
        sandbox_create "$sandbox_name" "$inferred_type"
        return $?
    fi
    return 1
}

# ── Auto-fix: install missing package ──────────────────────────
# Detects common "not found" / "not installed" errors and attempts
# to install the missing tool via apt.
_agent_auto_install_package() {
    local error_msg="$1"
    local lower
    lower=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')

    local pkg=""
    # "command not found: <cmd>"
    if [[ "$lower" =~ command\ not\ found.*:?\ *([a-z0-9_-]+) ]]; then
        pkg="${BASH_REMATCH[1]}"
    # "<cmd>: not found" or "<cmd> not found"
    elif [[ "$lower" =~ ([a-z0-9_-]+):\ not\ found ]]; then
        pkg="${BASH_REMATCH[1]}"
    # "No such file or directory" for common tools
    elif [[ "$lower" =~ /usr/bin/([a-z0-9_-]+).*no\ such ]]; then
        pkg="${BASH_REMATCH[1]}"
    fi

    [ -z "$pkg" ] && return 1
    # Skip if it's a sandbox name or something obviously not a package
    [[ "$pkg" =~ ^(sandbox|lodge|george)$ ]] && return 1

    if command -v "$pkg" &>/dev/null; then
        return 1  # already installed, error was something else
    fi

    ui_warn "'$pkg' not found — attempting: apt install -y $pkg"
    if command -v apt &>/dev/null; then
        apt install -y "$pkg" 2>&1 | tail -3
        if command -v "$pkg" &>/dev/null; then
            ui_ok "Installed $pkg"
            return 0
        fi
    fi
    ui_dim "  Could not auto-install '$pkg'"
    return 1
}

# ── Cascading failure detection ────────────────────────────────
# Given a failed step and the remaining steps, determines if the
# remaining steps depend on the same resource and should be skipped.
# Returns 0 if remaining steps share the resource (cascade likely).
_agent_detect_cascade() {
    local failed_step="$1"
    shift
    local -a remaining=("$@")

    # Extract the sandbox/resource name from the failed step
    # Matches: /sandbox build NAME, /sandbox run NAME ..., etc.
    local resource=""
    if [[ "$failed_step" =~ ^/sandbox\ +[a-z]+\ +([^ ]+) ]]; then
        resource="${BASH_REMATCH[1]}"
    fi

    [ -z "$resource" ] && return 1

    # Count how many remaining steps reference the same resource
    local dependent=0
    for step in "${remaining[@]}"; do
        if [[ "$step" == *"$resource"* ]]; then
            (( dependent++ ))
        fi
    done

    # If majority of remaining steps reference the same resource, cascade
    if [ "$dependent" -gt 0 ] && [ "${#remaining[@]}" -gt 0 ]; then
        local pct=$(( dependent * 100 / ${#remaining[@]} ))
        [ "$pct" -ge 50 ] && return 0
    fi

    return 1
}

# ── Plan validation ────────────────────────────────────────────
# Scans a list of steps for common hallucination patterns and
# warns about them before execution begins. Returns 0 always
# (advisory only), but sets _AGENT_PLAN_WARNINGS with messages.
_agent_validate_plan() {
    local -a steps=("$@")
    _AGENT_PLAN_WARNINGS=""
    local warn_count=0

    # Track which sandbox names get created in the plan
    local -A _sandbox_created=()

    for i in "${!steps[@]}"; do
        local step="${steps[$i]}"
        local num=$((i + 1))

        # ── Track sandbox creations ────────────────────────────
        if [[ "$step" =~ ^/sandbox\ +(new|create|init|make)\ +([^ ]+) ]]; then
            _sandbox_created["${BASH_REMATCH[2]}"]=1
        fi

        # ── Sandbox use before creation ────────────────────────
        if [[ "$step" =~ ^/sandbox\ +(run|build|test|exec|cd|status)\ +([^ ]+) ]]; then
            local _sb_name="${BASH_REMATCH[2]}"
            local _sb_dir="${LODGE_SANDBOXES:-${LODGE_DIR:-.}/.sandboxes}/$_sb_name"
            if [ -z "${_sandbox_created[$_sb_name]+x}" ] && [ ! -d "$_sb_dir" ]; then
                _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: /sandbox ${BASH_REMATCH[1]} '$_sb_name' — sandbox not created in plan (will auto-create)"
                warn_count=$(( warn_count + 1 ))
            fi
        fi

        # ── Hallucinated commands: /foo where foo isn't registered ──
        if [[ "$step" =~ ^/([a-zA-Z_][a-zA-Z0-9_-]*) ]]; then
            local _step_cmd="${BASH_REMATCH[1]}"
            local _cmd_found=0
            # Check registry (if populated)
            if declare -p CMD_REGISTRY &>/dev/null && [[ -n "${CMD_REGISTRY[$_step_cmd]+x}" ]]; then
                _cmd_found=1
            fi
            # Check commands dir scripts
            if [ -f "${LODGE_COMMANDS_DIR:-$LODGE_DIR/commands}/${_step_cmd}.sh" ]; then
                _cmd_found=1
            fi
            # Built-in commands
            if [[ "$_step_cmd" == "help" || "$_step_cmd" == "quit" || "$_step_cmd" == "exit" ]]; then
                _cmd_found=1
            fi
            if [ "$_cmd_found" -eq 0 ]; then
                _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: /$_step_cmd is not a registered command — will fail"
                warn_count=$(( warn_count + 1 ))
            fi
        fi

        # Hallucinated URLs: placeholder domains like your-repo, your-link, example.com
        if [[ "$step" =~ (your-repo|your-link|your-url|example\.com|placeholder|your-name|your-user) ]]; then
            _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: Contains placeholder URL/name — will fail"
            warn_count=$(( warn_count + 1 ))
        fi

        # /download from a URL that was clearly invented (not from a prior step)
        if [[ "$step" =~ ^/download ]] && [[ "$step" =~ github\.com/[^/]+/[^/]+ ]] && [[ "$step" =~ (your-|example|placeholder) ]]; then
            _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: Downloading from hallucinated URL"
            warn_count=$(( warn_count + 1 ))
        fi

        # /save with a shell command as content (literal $(find ...) etc)
        if [[ "$step" =~ ^/save ]] && [[ "$step" =~ \$\( ]]; then
            _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: /save with \$(command) — will save literal text, not output"
            warn_count=$(( warn_count + 1 ))
        fi

        # /social post with unquoted multi-word text (first word gets parsed as platform)
        if [[ "$step" =~ ^/social\ +post\ +\" ]]; then
            : # properly quoted — OK
        elif [[ "$step" =~ ^/social\ +post\ +[^\"] ]]; then
            _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: /social post needs quoted text (first word may be parsed as platform)"
            warn_count=$(( warn_count + 1 ))
        fi
    done

    if [ "$warn_count" -gt 0 ]; then
        echo ""
        ui_warn "Plan validation found $warn_count issue(s):$(printf '%b' "$_AGENT_PLAN_WARNINGS")"
        echo ""
    fi

    return 0
}

# ── Parse plan text into steps array ───────────────────────────
# Shared parser used by agent_run and _agent_run_subtask.
# Writes step strings to stdout, one per line.
_agent_parse_steps() {
    local plan="$1"
    plan=$(_agent_split_inline_steps "$plan")
    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9]+[\.\)\ ] ]]; then
            local step_text
            step_text=$(echo "$line" | sed 's/^[0-9]*[.)[:space:]]*//')
            [ -n "$step_text" ] && echo "$step_text"
        elif [[ "$line" =~ ^/ ]] && [ -n "$line" ]; then
            echo "$line"
        elif [[ "$line" =~ ^[-\*]\ + ]]; then
            local step_text
            step_text=$(echo "$line" | sed 's/^[-*][[:space:]]*//')
            [ -n "$step_text" ] && echo "$step_text"
        fi
    done <<< "$plan"
}

# ── Recursively plan and execute a subtask ─────────────────────
# Called when a step is prefixed with [SUBTASK]. Plans the subtask
# as a new mini-task and executes each sub-step, respecting depth.
# Parent context is injected into GEORGE.md so the subtask knows
# what the overall task is and what has been completed so far.
_agent_run_subtask() {
    local task="$1"
    local workdir="${2:-.}"
    local depth="${3:-1}"
    local parent_task="${4:-}"

    if [ "$depth" -gt "$AGENT_MAX_DEPTH" ]; then
        ui_warn "Max planning depth ($AGENT_MAX_DEPTH) reached. Executing as single step."
        agent_inner_loop "$task" "$workdir"
        return $?
    fi

    # Inject parent context so subtask plan is aware of the bigger picture
    if [ -n "$parent_task" ]; then
        memory_update_section "Active Task" "SUBTASK of: $parent_task\nSubtask: $task" "$workdir"
    fi

    ui_section "Subtask (depth $depth)"
    ui_info "$task"

    local plan
    plan=$(agent_plan "$task" "$workdir")
    if [ $? -ne 0 ]; then return 1; fi

    local -a steps=()
    while IFS= read -r s; do
        [ -n "$s" ] && steps+=("$s")
    done < <(_agent_parse_steps "$plan")

    local total=${#steps[@]}
    if [ "$total" -eq 0 ]; then
        steps=("$task")
        total=1
    fi

    ui_info "Sub-plan: $total steps (depth $depth)"
    echo ""

    local completed=0
    for i in "${!steps[@]}"; do
        local step_num=$((i + 1))
        local step_text="${steps[$i]}"

        # Nested subtask detection
        if [[ "$step_text" == \[SUBTASK\]* ]]; then
            local sub_desc="${step_text#\[SUBTASK\]}"
            sub_desc="${sub_desc# }"
            if _agent_run_subtask "$sub_desc" "$workdir" "$((depth + 1))" "$task"; then
                completed=$((completed + 1))
            fi
        else
            ui_progress "$step_num" "$total" "${step_text:0:30}"
            if agent_inner_loop "$step_text" "$workdir"; then
                completed=$((completed + 1))
            fi
        fi

        sleep "$AGENT_STEP_DELAY"

        if [ "$step_num" -ge 4 ] && [ $(( step_num % 2 )) -eq 0 ]; then
            memory_compact "$workdir"
        fi
    done

    ui_ok "Subtask complete: $completed/$total sub-steps succeeded"
    return 0
}

# ── Plan a task ────────────────────────────────────────────────
agent_plan() {
    local task="$1"
    local workdir="${2:-.}"
    
    # Use lean "plan" mode — ~1,500 tokens instead of ~3,100
    local system_prompt
    system_prompt=$(memory_build_system_prompt "$workdir" "" "plan")
    
    # Determine effective clarification limit based on interactive planning mode
    local effective_max_clarify=0
    if [ "${AGENT_INTERACTIVE_PLANNING:-0}" -eq 1 ]; then
        effective_max_clarify="$AGENT_MAX_CLARIFY"
    fi

    local base_rules="Plan this task. Rules:
- THINK FIRST: Is this a simple question George can answer from his own knowledge (no web search, no tools, no external actions)? If so, output ONLY: 1. /ask <the user's question>. Done. No sandbox, no coding.
- If the user explicitly names a tool or action (e.g., 'search the web', 'post to discord'), route to that tool — do NOT use /ask.
- Use the MINIMUM steps needed. Most tasks need 1-3 steps. Maximum: $AGENT_PLAN_STEPS steps.
- NEVER pad plans. No filler steps (no READMEs, no backup, no status checks, no recall searches, no reviews).
- Every step must directly advance the user's stated goal.
- Each step = ONE action (one file, one command, one operation).
- Use your slash commands (e.g. /sandbox, /write, /build) in steps.
- If using /sandbox: create it FIRST with /sandbox new <name> <type>.
- For complex multi-file or design-heavy work, prefix a step with [SUBTASK] — describe WHAT the code must do (architecture, modules, behavior). The subtask gets its own recursive sub-plan. Use [SUBTASK] for the heavy lifting; keep your top-level plan lean.
- Code steps must produce REAL implementation — no Hello World, no stubs.
- NEVER invent URLs or repo names. Use /web search or /github search first.
- Output ONLY a NUMBERED LIST (1. 2. 3. etc.) — no explanations, no code."

    if [ "$effective_max_clarify" -gt 0 ]; then
        base_rules="${base_rules}
- If the task is too vague or you need key details to make a good plan,
  start your response with CLARIFY: followed by ONE short question.
  You may ask for clarification at most ${effective_max_clarify} times."
    else
        base_rules="${base_rules}
- Do NOT ask questions. Produce a plan with the information available."
    fi

    base_rules="${base_rules}

Example plan format:
1. Do the first thing
2. Do the second thing
3. Do the third thing"

    local context=""
    local clarify_round=0
    local plan=""

    while [ "$clarify_round" -le "$effective_max_clarify" ]; do
        local prompt="TASK: $task"
        if [ -n "$context" ]; then
            prompt="${prompt}

ADDITIONAL CONTEXT FROM USER:
${context}"
        fi

        if [ "$clarify_round" -eq "$effective_max_clarify" ] && [ "$effective_max_clarify" -gt 0 ]; then
            prompt="${prompt}

${base_rules}

You have already asked ${clarify_round} question(s). No more questions — produce a plan NOW."
        else
            prompt="${prompt}

${base_rules}"
        fi

        # Stream the plan so user sees progress in real-time
        echo ""
        if [ "$clarify_round" -eq 0 ]; then
            ui_dim "  Plan:"
        else
            ui_dim "  Plan (round $((clarify_round + 1))):"
        fi

        local LLM_SCENARIO=agent
        plan=$(llm_stream "$prompt" "$system_prompt" 512 "$LLM_BUDGET_AGENT")
        echo ""

        # Transcript: log the plan
        declare -f transcript_log_block &>/dev/null && transcript_log_block "plan" "$plan"

        if [ -z "$plan" ] || [[ "$plan" == ERROR* ]]; then
            ui_err "Planning failed: ${plan:-empty response}"
            return 1
        fi

        # Check if the model is asking for clarification (only in interactive mode)
        if [ "$effective_max_clarify" -gt 0 ]; then
            local trimmed
            trimmed=$(echo "$plan" | sed 's/^[[:space:]]*//')
            if [[ "$trimmed" == CLARIFY:* ]] && [ "$clarify_round" -lt "$effective_max_clarify" ]; then
                clarify_round=$((clarify_round + 1))
                local question
                question=$(echo "$trimmed" | sed 's/^CLARIFY:[[:space:]]*//')
                echo ""
                ui_info "George needs more info ($clarify_round/$effective_max_clarify):"
                printf "  %b%s%b\n" "$C_CYAN" "$question" "$C_RESET"
                echo ""
                printf "  %b> %b" "$C_BOLD" "$C_RESET"
                local answer
                read -r answer < /dev/tty
                if [ -z "$answer" ]; then
                    ui_dim "  No answer — proceeding with available info."
                    # Force plan on next round
                    clarify_round=$effective_max_clarify
                else
                    context="${context:+$context\n}$question → $answer"
                fi
            else
                # Got a plan (not a clarification request)
                break
            fi
        else
            # Non-interactive mode — accept whatever plan was generated
            break
        fi
    done
    
    # Update memory
    memory_update_section "Active Task" "$task" "$workdir"
    
    echo "$plan"
}

# ── Dynamic Inner Loop Prompts ─────────────────────────────────
# Replaces the monolithic memory_build_system_prompt for inner loops.
# These prompts contain ZERO personality, vitals, or history.
# This drastically reduces prefill time — Ollama flushes the KV cache
# but does NOT reload the 4GB model from disk.

_build_router_prompt() {
    # Phase 1 Prompt: The Command Catalog Router (line-oriented)
    # Line-per-command format with clear TOOLS vs DELIVERY separation.
    # The router's ONLY job: classify task → command.
    # Completion detection is handled by the milestone evaluator.
    # Specialist handles exact syntax. ~250 tokens.
    #
    # FORMAT: Plain text, one command per line, two clear sections.
    # Small models (2-4B) parse line-oriented text far more reliably
    # than nested JSON with escaped quotes and brackets.
    #
    # ORDERING: Commands are ranked by utility/frequency. 2B models
    # exhibit strong primacy bias — items listed first are chosen
    # disproportionately. High-utility tools (web, recall) are at
    # the top. /slash is the escape valve for missing capabilities.
    cat << 'ROUTER_PROMPT'
Output ONLY the bare tool name. NO backticks. NO code fences. NO quotes. Example: /web

TOOLS — gather info, execute work (these do NOT deliver results to the user):
/web         Search web, fetch page, scrape page+images (/web search|fetch|scrape-images|images)
/recall      Search knowledge base FTS5 (DO THIS FIRST before web)
/read        Read a file
/ls          List files as tree
/journal     Read or write living memory
/build       Build project
/test        Run tests
/fix         Diagnose and fix errors
/init        Scaffold new project
/clone       Clone git repo
/download    Download a URL
/vision      Analyze/describe an image (accepts URLs from /web scrape-images)
/github      Search GitHub repos
/sandbox     Code sandboxes (NOT for running slash commands)
/container   Linux containers
/secret      Encrypted secrets vault
/vitals      System dashboard
/phone       Phone dashboard, SMS
/pgp         PGP sign/verify/export
/git         Git setup, SSH keys
/backup      Backup and restore
/slash       Create/run custom commands (USE when no built-in fits)
bash         Standard Linux shell (fallback)

DELIVERY — present results to user (one per milestone; a full task may chain several, e.g. /write then /email):
/respond     Present answer directly to operator (DEFAULT — use when no file/email/post needed)
/write       Write or overwrite a file
/save        Save content to file
/email       Send/check actual email (gmail/protonmail/zoho)
/social      Post to Discord/Telegram/X/Mastodon (NOT email)
/commit      AI commit message + commit
/push        Push to GitHub

DEFAULT RULE: If the task does NOT explicitly require /write, /save, /email, /social, /commit, or /push, use /respond to deliver the answer.

ROUTE EXAMPLES:
<weather or news question>         → /web
<deliver answer to user>           → /respond
<post to discord/telegram/x>       → /social
<send an email>                    → /email
<code sandbox project>             → /sandbox
<list or read files>               → /ls
<journal read/write>               → /journal
<create a custom tool>             → /slash
<analyze or describe an image>     → /vision
<write a report/file then email>   → /write (first), then /email (next milestone)
<draft a document/report>          → /write
<general knowledge, no tools>      → /respond

RULES:
- /web for ANYTHING time-sensitive (weather, dates, scores, events, prices, news)
- /slash to CREATE a custom tool when no built-in command fits
- /sandbox NEVER for slash commands
- /social for Discord/Telegram/X, /email for actual email
- NEVER output a command not in this list
- If unsure between TOOLS, use /web or /slash
- If no explicit output command requested, ALWAYS use /respond

FORMAT: bare tool name only. Output ONLY a slash command from the list above. No sentences, no explanations, no backticks, no code fences, no quotes.
ROUTER_PROMPT
}

# ── Specialist: per-command API key status ─────────────────────
# Returns a compact line listing which API keys/secrets are
# configured for a given command.  Injected into the specialist
# prompt so the model knows what services are available and can
# avoid generating commands that will fail due to missing keys.
#
# Only emits output for commands that actually need keys.
# Format:  KEYS: SERPER_API_KEY ✓, PERPLEXITY_API_KEY ✗
_specialist_key_status() {
    local cmd="$1"  # base command without /
    declare -f api_get_key &>/dev/null || return 0

    local -a keys=()
    case "$cmd" in
        web)      keys=(SERPER_API_KEY PERPLEXITY_API_KEY) ;;
        social)   keys=(DISCORD_BOT_TOKEN DISCORD_WEBHOOK_URL TELEGRAM_BOT_TOKEN X_BEARER_TOKEN MASTODON_ACCESS_TOKEN BLUESKY_APP_PASSWORD) ;;
        email)    keys=(EMAIL_PROVIDER) ;;
        github)   keys=(GITHUB_TOKEN) ;;
        wallet)   keys=(btc_address ada_address sol_address) ;;
        pgp)      ;; # uses gpg keyring, not API keys
        *)        return 0 ;;  # no keys needed
    esac

    [ ${#keys[@]} -eq 0 ] && return 0

    local parts=""
    local k
    for k in "${keys[@]}"; do
        if api_get_key "$k" &>/dev/null; then
            parts="${parts:+$parts, }$k ✓"
        else
            # wallet keys live in the secrets vault, not api keys
            if [[ "$cmd" == "wallet" ]] && declare -f secrets_get &>/dev/null; then
                if secrets_get "$k" &>/dev/null 2>&1; then
                    parts="${parts:+$parts, }$k ✓"
                    continue
                fi
            fi
            parts="${parts:+$parts, }$k ✗"
        fi
    done

    [ -n "$parts" ] && echo "KEYS: $parts"
}

_build_specialist_prompt() {
    local cmd_name="$1"
    local workdir="$2"
    local micro_objective="$3"  # Optional: used to rerank docs by objective keywords
    # Phase 2 Prompt: The Action Specialist
    # Injects deep-dive docs for ONE specific command.
    #
    # Slash commands: output on their own line starting with /
    #   (commands_dispatch handles execution)
    # Bash commands: output inside a ```bash block
    #   (eval handles execution)

    if [ "$cmd_name" != "bash" ]; then
        # Inject task context at the TOP of the system prompt so it
        # occupies the primacy position. On 4B models, early system
        # content outweighs everything else. Without this, syntax card
        # examples in the "ex" field dominate the model's attention.
        if [ -n "$micro_objective" ]; then
            echo "TASK: $micro_objective"
            echo "Generate the command WITH REAL ARGUMENTS derived from the TASK above."
            echo "Replace every <placeholder> in the syntax with actual values from the TASK. NEVER output bare commands without arguments."
            echo ""
        fi
        cat << 'SPEC_PREAMBLE'
OUTPUT FORMAT: exactly ONE slash command on its own line, starting with /
FORBIDDEN: code fences, quotes on args, multiple commands per line, /sandbox for slash commands

COMMAND TYPES:
  TOOLS (gather info, do work): /web /recall /read /ls /build /test /fix /init /clone /download /vision /github /sandbox /container /secret /vitals /phone /pgp /git /backup /slash /journal bash
  DELIVERY (present output to user): /respond /write /save /email /social /commit /push
  NOTE: A full task may chain multiple DELIVERY commands across milestones (e.g. /write a report, then /email it).
  DEFAULT: If the task does NOT explicitly need a file, email, or post, use /respond to deliver the answer.
SPEC_PREAMBLE
        echo "CRITICAL: Output the bare slash command. NO backticks. NO code fences. NO markdown formatting. Just the command."

        # Docs injection is SKIPPED for the specialist. The syntax card
        # below provides all needed syntax in ~10 lines per command.
        # Previously, GEORGE_REFERENCE.md (40 lines) + SLASH_COMMANDS.md
        # table rows + recall FTS5 results were all injected, ballooning
        # input to 1500-1800 tokens for only 3-17 output tokens. The 4B
        # model doesn't need encyclopedic docs — it needs a crisp syntax
        # card and the objective.
        local base_cmd="${cmd_name#/}"

        # ── Command-specific JSON syntax cards ────────────────
        # Compact JSON per command. Prevents the specialist from
        # hallucinating syntax. Examples keyed to their command.
        echo ""
        echo "SYNTAX CARD:"
        case "$base_cmd" in
            social)
                cat << 'SPEC'
{"cmd":"/social","syntax":["/social post discord <channel> <text>","/social post telegram <text>","/social post x <text>","/social post mastodon <text>","/social discord dm <user> <text>","/social discord read <channel>"],
"rules":["ALWAYS include channel name","@DisplayName auto-resolved to <@user_id>","Channel goes BEFORE text","No quotes on args"],
"format_only_ex":["/social post discord <channel> <text>","/social discord dm <user> <text>"],
"fill":{"<channel>":"Discord channel name without #","<text>":"Your message content","<user>":"Discord username"}}
SPEC
                ;;
            init)
                cat << 'SPEC'
{"cmd":"/init","syntax":"/init <name> <type>",
"notes":["name: no spaces (use underscores)","types: rust,python,rl,data,automation,notebook,shell","Creates project dir + GEORGE.md + starter code + git init","Auto-cd into project after init","Do NOT /init if project already exists"],
"format_only_ex":["/init <name> <type>"],
"fill":{"<name>":"project name with underscores not spaces","<type>":"one of: rust, python, rl, data, automation, notebook, shell"}}
SPEC
                ;;
            cd)
                cat << 'SPEC'
{"cmd":"/cd","syntax":"/cd <path>","notes":["Change working dir","Relative paths OK","/cd .. to go up"],
"format_only_ex":["/cd <directory>"],
"fill":{"<directory>":"target directory name or relative path"}}
SPEC
                ;;
            write)
                cat << 'SPEC'
{"cmd":"/write","syntax":["/write <filepath> <content>","/write --append <filepath> <content>","/write --edit <filepath> <sed_expr>"],
"modes":{"overwrite":"Write COMPLETE file contents. New files or full rewrites.","--append":"Add to END of file. Deps, new functions.","--edit":"ONLY short sed (rename, change value). Max 200 chars. NEVER multi-line."},
"rules":["RELATIVE PATHS ONLY (e.g. responses/file.json, src/main.rs) — NEVER start with /","Use \\n for newlines (NEVER literal line breaks)","COMPLETE source for code files","JSON: matching braces, quoted keys","If changing >1 line, use plain /write with COMPLETE file"],
"format_only_ex":["/write <relative-filepath> <complete file content with \\n for newlines>","/write --append <relative-filepath> <content to add>","/write --edit <relative-filepath> s/<old>/<new>/g"]}
SPEC
                ;;
            save)
                cat << 'SPEC'
{"cmd":"/save","syntax":"/save <filepath> <content>","notes":"First token=filepath, rest=content. RELATIVE PATHS ONLY.",
"format_only_ex":["/save <relative-filepath> <content>"],
"fill":{"<filepath>":"target filename or path","<content>":"text to save to the file"}}
SPEC
                ;;
            web)
                cat << 'SPEC'
{"cmd":"/web","syntax":{
  "search":"/web search <query> — returns URLs + text snippets from search engines",
  "fetch":"/web fetch <url> — downloads and extracts readable TEXT from a webpage (HTML/PDF/JSON). Returns plain text only, NO images.",
  "scrape-images":"/web scrape-images <url> — returns STRUCTURED JSON: {url, title, content, images:[]} with page text AND image URIs. Pass image URIs to /vision for analysis.",
  "images":"/web images <query> — searches for image URLs by keyword (Serper API). Returns image URLs only."},
"rules":["search=QUERY (keywords), fetch/scrape-images=URL — NEVER swap","/web fetch returns TEXT only — use /web scrape-images when you need images","scrape-images returns {url,title,content,images[]} — pass images[] URLs to /vision","AVOID redundant searches — 1 search + 1-2 fetches enough","For CODING: prefer /write,/build,/test over web research","ALWAYS derive search keywords from the TASK above — never from examples"],
"search_tips":["3-5 keywords MAX — Google FAILS with long queries","Drop filler: the/a/for/including/regarding/comprehensive","NEVER paste entire milestone as search query","Extract keywords from TASK context only"],
"FLOW CHAINS":["Text research: /web search -> /web fetch -> summarize","Image research: /web scrape-images <url> -> /vision <image_url_from_images[]>","Report: /web search -> /web fetch -> /write report"],
"notes":["Do NOT fetch every URL. 1 search + 1-2 fetches enough","If scrape-images returns empty content, use /web fetch for same URL instead"],
"format_only_ex":["/web search <keywords>","/web fetch <url>","/web scrape-images <url>","/web images <keywords>"],
"fill":{"<keywords>":"3-5 search terms derived from the TASK","<url>":"full https:// URL from search results or task"}}
SPEC
                ;;
            download)
                cat << 'SPEC'
{"cmd":"/download","syntax":"/download <url_or_path> [destination]",
"format_only_ex":["/download <url> [destination-path]"]}
SPEC
                ;;
            sandbox)
                cat << 'SPEC'
{"cmd":"/sandbox","syntax":{
  "new":"/sandbox new <name> [type] (rust/python/shell)",
  "build":"/sandbox build <name>","test":"/sandbox test <name>",
  "run":"/sandbox run <name> <cmd>","cd":"/sandbox cd <name>",
  "rm":"/sandbox rm <name>","clone":"/sandbox clone <url> [name]"},
"rules":["Do NOT use /sandbox to run slash commands"],
"format_only_ex":["/sandbox new <project-name> <type>","/sandbox build <project-name>"]}
SPEC
                ;;
            build)
                cat << 'SPEC'
{"cmd":"/build","syntax":"/build [release]","notes":"Auto-detects Cargo/pyproject/Makefile. Reads GEORGE.md Build section.",
"format_only_ex":["/build","/build release"]}
SPEC
                ;;
            test)
                cat << 'SPEC'
{"cmd":"/test","syntax":"/test [specific_test]","notes":"Auto-detects Cargo/pytest/npm/make.",
"ex":["/test"]}
SPEC
                ;;
            fix)
                cat << 'SPEC'
{"cmd":"/fix","syntax":"/fix [file_or_description]","notes":"Auto-diagnoses and fixes errors.",
"format_only_ex":["/fix <file-or-description>"],
"fill":{"<file-or-description>":"filename or error description from the TASK"}}
SPEC
                ;;
            commit)
                cat << 'SPEC'
{"cmd":"/commit","syntax":"/commit [files...]","notes":"AI-generates commit message. Optional: specific files to stage.",
"format_only_ex":["/commit","/commit <files>"],
"fill":{"<files>":"optional specific filenames to stage"}}
SPEC
                ;;
            push)
                cat << 'SPEC'
{"cmd":"/push","syntax":"/push [branch]","notes":"Push to remote. Defaults to current branch."}
SPEC
                ;;
            clone)
                cat << 'SPEC'
{"cmd":"/clone","syntax":"/clone <repo_url_or_owner/repo> [local_name]",
"format_only_ex":["/clone <owner/repo-or-url> [local-name]"]}
SPEC
                ;;
            git)
                cat << 'SPEC'
{"cmd":"/git","syntax":{
  "setup":"/git setup (configure user/email)","status":"/git status","ssh-keygen":"/git ssh-keygen"},
"format_only_ex":["/git <action>"],
"fill":{"<action>":"one of: setup, status, ssh-keygen"}}
SPEC
                ;;
            github)
                cat << 'SPEC'
{"cmd":"/github","syntax":"/github search <query>",
"format_only_ex":["/github search <keywords>"],
"fill":{"<keywords>":"search terms for GitHub repos"}}
SPEC
                ;;
            email)
                cat << 'SPEC'
{"cmd":"/email","syntax":{
  "send":"/email send <provider> <recipient> subject=<subj> body=<body>",
  "inbox":"/email inbox <provider> [count]","status":"/email status"},
"notes":["provider: gmail,protonmail,zoho","Recipient after provider (no to= needed)","Also accepts: to= s= b= as aliases","For actual email ONLY, NOT social platforms"],
"format_only_ex":["/email send <provider> <address> subject=<subject line> body=<email body>","/email inbox <provider>"]}
SPEC
                ;;
            journal)
                cat << 'SPEC'
{"cmd":"/journal","syntax":{
  "read":"/journal — Read ALL journal entries (no arguments needed)",
  "show":"/journal show [vivid|fading|sediment]",
  "write":"/journal write <entry_text>"},
"rules":["To READ: /journal (no args). To WRITE: /journal write <text>","NEVER write new content when the task asks you to check, read, review, or show the journal"],
"format_only_ex":["/journal","/journal show <tier>","/journal write <text>"],
"fill":{"<tier>":"one of: vivid, fading, sediment","<text>":"journal entry content"}}
SPEC
                ;;
            recall)
                cat << 'SPEC'
{"cmd":"/recall","syntax":"/recall <query>","notes":"BM25-ranked FTS5 search. Returns source, section, snippet.",
"format_only_ex":["/recall <search keywords>"]}
SPEC
                ;;
            pgp)
                cat << 'SPEC'
{"cmd":"/pgp","syntax":{
  "sign":"/pgp sign <message>","signpost":"/pgp signpost (sign+post to Discord)","export":"/pgp export"},
"format_only_ex":["/pgp sign <your message>"]}
SPEC
                ;;
            phone)
                cat << 'SPEC'
{"cmd":"/phone","syntax":"/phone","notes":"Dashboard: battery, signal, location, SMS. No args needed."}
SPEC
                ;;
            secret)
                cat << 'SPEC'
{"cmd":"/secret","syntax":["/secret set <name> <value>","/secret get <name>"],"notes":"AES-256-CBC vault.",
"format_only_ex":["/secret set <KEY_NAME> <value>","/secret get <KEY_NAME>"]}
SPEC
                ;;
            vitals)
                cat << 'SPEC'
{"cmd":"/vitals","syntax":"/vitals","notes":"Disk, RAM, battery, network dashboard. No args needed."}
SPEC
                ;;
            backup)
                cat << 'SPEC'
{"cmd":"/backup","syntax":{
  "local":"/backup local (timestamped)","restore":"/backup restore","github":"/backup github"},
"format_only_ex":["/backup <action>"],
"fill":{"<action>":"one of: local, restore, github"}}
SPEC
                ;;
            vision)
                cat << 'SPEC'
{"cmd":"/vision","syntax":"/vision <image_path_or_url> [prompt]",
"notes":["Supports jpg/png/gif/webp/bmp","Accepts image URLs directly (no /download needed)","Requires vision model: /models single minist-inst","Pair with /web scrape-images: scrape a page, then pass image URLs from images[] array to /vision","Returns detailed text description of image contents"],
"format_only_ex":["/vision <image> <prompt>"],
"fill":{"<image>":"URL or local path to image file (e.g. URL from /web scrape-images images[] output)","<prompt>":"what to analyze or describe about the image"}}
SPEC
                ;;
            container)
                cat << 'SPEC'
{"cmd":"/container","syntax":{
  "create":"/container create <distro> (ubuntu/alpine/debian/fedora/kali)",
  "enter":"/container enter <distro>","exec":"/container exec <distro> <cmd>","rm":"/container rm <distro>"},
"format_only_ex":["/container <action> <distro>"],
"fill":{"<action>":"one of: create, enter, exec, rm","<distro>":"one of: ubuntu, alpine, debian, fedora, kali"}}
SPEC
                ;;
            wallet)
                cat << 'SPEC'
{"cmd":"/wallet","syntax":{
  "status":"/wallet status","balances":"/wallet balances","check":"/wallet check"},
"format_only_ex":["/wallet <action>"],
"fill":{"<action>":"one of: status, balances, check"}}
SPEC
                ;;
            slash)
                cat << 'SPEC'
{"cmd":"/slash","syntax":["/slash create <name> <description>","/slash run <name> [args]","/slash list","/slash show <name>","/slash edit <name>"],
"notes":["George auto-generates bash code from the description","Created commands persist and can be reused across tasks","Commands get full lodge library access (curl, jq, etc.)","Use /slash to extend yourself when a built-in command doesn't exist"],
"format_only_ex":["/slash create <name> <description>","/slash run <name> <args>"],
"fill":{"<name>":"short hyphenated command name","<description>":"plain English description of what the command should do","<args>":"runtime arguments for the custom command"},
"workflow":["Step 1: /slash create <name> <what it should do>","Step 2: /slash run <name> [args]","If a built-in command doesn't do exactly what you need, create a /slash command."]}
SPEC
                ;;
            respond)
                cat << 'SPEC'
{"cmd":"/respond","syntax":"/respond <text>",
"notes":["Present output directly to operator — use when no file/email/post is needed","Use \\n for line breaks, supports markdown formatting","This IS a delivery command — satisfies task completion"],
"format_only_ex":["/respond <your complete answer text>"]}
SPEC
                ;;
            ask)
                cat << 'SPEC'
{"cmd":"/ask","syntax":"/ask <question>",
"notes":"Answer from model knowledge. WARNING: may be stale for dates, scores, events, prices. Prefer /web search for time-sensitive info.",
"format_only_ex":["/ask <question>"]}
SPEC
                ;;
            ls)
                cat << 'SPEC'
{"cmd":"/ls","syntax":"/ls [path] [depth]","notes":"Tree view, depth 1-8 (default 3).",
"format_only_ex":["/ls","/ls <path> <depth>"],
"fill":{"<path>":"directory path to list","<depth>":"tree depth 1-8"}}
SPEC
                ;;
            read)
                cat << 'SPEC'
{"cmd":"/read","syntax":"/read <file>","notes":"Read first 100 lines of file.",
"format_only_ex":["/read <filepath>"],
"fill":{"<filepath>":"path to file to read"}}
SPEC
                ;;
            *)
                echo "- /$base_cmd (no specific syntax card)"
                ;;
        esac

        # Inject per-command API key availability so the specialist
        # knows which services are configured and can avoid commands
        # that will fail due to missing keys.
        local _key_status
        _key_status=$(_specialist_key_status "$base_cmd" 2>/dev/null)
        if [ -n "$_key_status" ]; then
            echo ""
            echo "$_key_status"
        fi

        # ── Inject service availability into specialist ────────
        # The specialist needs to know which services (discord, email,
        # telegram, etc.) are actually configured so it can use the
        # correct provider/channel names and avoid commands that will
        # fail due to missing credentials.
        if declare -f commands_services_status &>/dev/null; then
            local _svc_status_spec
            _svc_status_spec=$(commands_services_status 2>/dev/null)
            if [ -n "$_svc_status_spec" ]; then
                echo ""
                echo "SERVICES STATUS:"
                echo "$_svc_status_spec"
                echo "ONLY use services listed as CONFIGURED. Do NOT attempt unconfigured services."
            fi
        fi

        # ── Inject registered channels/instances into specialist ─
        # When the command is social, inject the actual channel names
        # so the specialist uses correct names, not placeholders.
        if [[ "$base_cmd" == "social" ]] && declare -f social_context_compact &>/dev/null; then
            local _social_ctx_spec
            _social_ctx_spec=$(social_context_compact 2>/dev/null)
            if [ -n "$_social_ctx_spec" ]; then
                echo ""
                echo "REGISTERED SOCIAL CHANNELS (use these exact names):"
                echo "$_social_ctx_spec"
            fi
        fi

        # Previous search results are already visible in the micro_memory
        # action log via MICRO OBJECTIVE + ACTION LOG injection in the
        # specialist_prompt (user message). No need to inject them again
        # into the system prompt — that was doubling the token count.
    else
        echo "You are George. Output exactly ONE command inside a \`\`\`bash block."
        echo "Use standard bash. Do not use interactive commands (like nano or vim)."
        echo "Do not output slash commands — use only shell builtins and system utilities."
    fi
}

# ── Execute a single micro-objective (The Tactician) ──────────
# Replaces the legacy agent_execute_step with a two-phase
# route→execute inner loop governed by the Constrained Escalation Matrix.
#
# Phase 1 (Router):  Fast tool selection — zero personality, just a catalog.
# Phase 2 (Specialist): Deep-dive execution — one command's docs injected.
#
# Failure Escalation Matrix (5 levels + terminal):
#   L1: Naive retry (LLM bypassed — programmatic re-exec after sleep)
#   L2: Forced knowledge retrieval (/recall on base command)
#   L3-L4: Syntax permutation with identicality lockout
#   L5: Forced web fallback (search stderr + command name)
#   Terminal: Human operator intervention (read -r from /dev/tty)
agent_inner_loop() {
    local micro_objective="$1"
    local workdir="${2:-.}"
    local george_dir="$workdir/.george"
    local micro_file="$george_dir/micro_memory.json"
    local macro_file="$george_dir/macro_memory.json"
    local fail_file="$george_dir/failures_log.md"

    mkdir -p "$george_dir"

    # STRICT OVERWRITE: Wipe micro memory clean for the new objective.
    # This is not appended — it is destroyed and recreated on every
    # handoff from the Macro loop. JSON format for structured context.
    _micro_init "$micro_file" "$micro_objective"

    # ── HONEYDEW STATUS INJECTION ──────────────────────────────
    # Show the inner loop what tasks remain so the router/specialist
    # can see progress at a glance (e.g., "2/4 complete | Next: ...").
    local _hd_inner_file="$george_dir/$HONEYDEW_FILE"
    local _has_honeydew=0
    if [ -f "$_hd_inner_file" ]; then
        local _hd_inner_status
        _hd_inner_status=$(_agent_honeydew_status "$(dirname "$george_dir")" 2>/dev/null)
        if [ -n "$_hd_inner_status" ]; then
            _micro_set "$micro_file" "honeydew_progress" "$_hd_inner_status"
            _has_honeydew=1
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: honeydew status -> micro_memory"
        fi
    fi

    # ── PRIMARY OBJECTIVE INJECTION ────────────────────────────
    # Inject the overarching task goal so the inner loop's router and
    # specialist never lose sight of the bigger picture.
    # SKIP when the honeydew list exists — the honeydew encodes the
    # original objective as structured subtasks. Injecting the raw
    # query alongside the honeydew causes the router/specialist to
    # chase the original query instead of the current honeydew item.
    if [ "$_has_honeydew" -eq 0 ] && [ -f "$macro_file" ]; then
        local _primary_obj
        _primary_obj=$(_macro_get "$macro_file" "primary_objective")
        if [ -n "$_primary_obj" ] && [ "$_primary_obj" != "$micro_objective" ]; then
            _micro_set "$micro_file" "primary_objective" "$_primary_obj"
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: primary objective -> micro_memory"
        fi
    fi

    # ── RESEARCH BUFFER INJECTION ──────────────────────────
    # If the previous milestone saved a research buffer, inject it
    # so this milestone's specialist can use the gathered data.
    # Deleted after injection to prevent leaking into subsequent milestones.
    # Tagged with source context so the model can judge relevance.
    local _research_buf="$george_dir/research_buffer.md"
    if [ -f "$_research_buf" ]; then
        local _rb_content
        _rb_content=$(head -c 1500 "$_research_buf")
        # Tag with source: last milestone objective from macro_memory
        local _rb_source=""
        if [ -f "$macro_file" ]; then
            _rb_source=$(jq -r '.completed_milestones[-1].objective // empty' "$macro_file" 2>/dev/null)
        fi
        if [ -n "$_rb_source" ]; then
            _rb_content="[From prior milestone: ${_rb_source:0:100}]\n${_rb_content}"
        fi
        _micro_set "$micro_file" "research_context" "$_rb_content"
        rm -f "$_research_buf"
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: research buffer -> micro_memory (${#_rb_content} chars)"
    fi

    # ── MILESTONE HISTORY INJECTION ────────────────────────────
    # Inject last 3 completed milestones from macro_memory so the
    # specialist knows what previous milestones accomplished.
    if [ -f "$macro_file" ]; then
        local _prior_ms
        _prior_ms=$(_macro_milestones_json "$macro_file" 3)
        if [ "$_prior_ms" != "[]" ] && [ -n "$_prior_ms" ]; then
            _micro_set_prior_milestones "$micro_file" "$_prior_ms"
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: milestone history -> micro_memory"
        fi
    fi

    local inner_attempts=0
    local _fail_count=0              # Failure-specific counter for escalation gating
    local max_inner_loops="$AGENT_INNER_LOOPS"
    local last_failed_cmd=""
    local _last_success_cmd=""      # Track last successful command for macro_memory
    local _last_success_snippet=""  # First 200 chars of last successful output
    local _web_search_consec=0     # Consecutive /web search counter (reset on non-search)
    local _cancel_file="${TMPDIR:-/tmp}/.lodge-cancel-$$"

    while [ "$inner_attempts" -lt "$max_inner_loops" ]; do
        # ── CANCELLATION CHECK: Break immediately on Ctrl+C ─────
        # Without this, the loop continues making LLM calls after
        # the user presses Ctrl+C, creating a cancel→think→cancel loop.
        if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
            return 1
        fi

        # Cache serialized micro_memory — reused by both router and
        # specialist within this iteration. Re-serialized only after a
        # command executes and modifies micro_memory (saves 1 jq call
        # + disk read per inner loop iteration).
        local inner_context=$(_micro_serialize "$micro_file")

        # ── PRE-ROUTE: Extract explicit slash command from milestone ──
        # When the strategist milestone already names a specific command
        # (e.g. "Use /respond to present findings"), skip the LLM router
        # entirely — saves one LLM call and prevents the 2B router from
        # misrouting explicit instructions.
        # Regex anchors to space or start-of-string to avoid matching
        # URL path segments (e.g. https://example.com/api → "api").
        local _pre_route=""
        if [[ "$micro_objective" =~ (^|[[:space:]])/([a-z]+) ]]; then
            local _pre_cmd="${BASH_REMATCH[2]}"
            # Synonym remap: models love "/draft" — treat as /write
            [ "$_pre_cmd" = "draft" ] && _pre_cmd="write"
            # Validate it's a real command before trusting the extraction
            local _pre_valid=0
            if [ "$_pre_cmd" = "bash" ]; then
                _pre_valid=1
            elif declare -p CMD_REGISTRY &>/dev/null && [[ -n "${CMD_REGISTRY[$_pre_cmd]+x}" ]]; then
                _pre_valid=1
            elif [ -f "${LODGE_COMMANDS_DIR:-$LODGE_DIR/commands}/${_pre_cmd}.sh" ]; then
                _pre_valid=1
            fi
            if [ "$_pre_valid" -eq 1 ]; then
                _pre_route="$_pre_cmd"
                # ── SAFETY: Rewrite bare-command milestones ────────
                # If the milestone IS a raw slash command (starts with
                # /cmd), rewrite micro_objective into natural language
                # so the specialist generates a real command instead
                # of parroting the milestone verbatim.
                # "/write a summary" → "Use /write to a summary"
                if [[ "$micro_objective" =~ ^/[a-z]+[[:space:]] ]]; then
                    micro_objective="Use /${_pre_cmd} to ${micro_objective#/"$_pre_cmd" }"
                fi
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Pre-routed from milestone: /$_pre_route (skipping LLM router)"
                declare -f transcript_log &>/dev/null && transcript_log "router" "/$_pre_route (pre-routed)"
            fi
        fi

        # ── PHASE 1: Fast Tool Routing ────────────────────────
        local selected_tool
        if [ -n "$_pre_route" ]; then
            selected_tool="$_pre_route"
        else
        local router_sys=$(_build_router_prompt)
        local _route_now
        _route_now=$(date '+%Y-%m-%d %H:%M:%S %Z')
        local _router_context
        _router_context=$(_micro_serialize_lean "$micro_file")
        local route_prompt="Current date/time: ${_route_now}\nRoute the next action.\n"
        route_prompt="${route_prompt}\n$_router_context"

        local LLM_SCENARIO=router
        selected_tool=$(llm_generate "$route_prompt" "$router_sys" "${LLM_ROUTER_TOKENS:-50}" "$LLM_BUDGET_ROUTER")

        # Transcript: log router decision
        declare -f transcript_log &>/dev/null && transcript_log "router" "$selected_tool"

        # Cancel check after router LLM call — curl may have been killed
        if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
            return 1
        fi

        # ── ROUTER: Ignore stale SUCCESS from hallucinating models ──
        # The router should ONLY output tool names. If it outputs
        # SUCCESS (from cached prompt patterns), strip it and fall
        # through to the evaluator-based completion check below.
        if [[ "$selected_tool" == *"SUCCESS"* ]]; then
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Router output 'SUCCESS' — ignoring (completion is evaluator's job)"
            # If there are successful actions, the evaluator will
            # detect completion. If not, we need more actions.
            local _sr_count
            _sr_count=$(_micro_action_count "$micro_file")
            if [ "$_sr_count" -gt 0 ]; then
                # Let evaluator decide — skip to end of loop
                inner_attempts=$((inner_attempts + 1))
                continue
            fi
            # No actions yet — fall through to specialist
            selected_tool="/ask"
        fi

        fi  # end pre-route / LLM router branch

        # ── WEB SUFFICIENCY ENFORCEMENT ───────────────────────
        # The sufficiency gate (in the action success block below)
        # sets sufficiency_reached after N successful web actions.
        # Instead of forcing completion blindly, run the milestone
        # evaluator one final time. This prevents N *irrelevant*
        # web searches (e.g. model parroting an example query) from
        # being stamped as complete when the objective is unmet.
        # Runs for both pre-routed and LLM-routed paths.
        if _micro_sufficiency_reached "$micro_file"; then
            if _agent_evaluate_milestone "$macro_file" "$micro_file" "$micro_objective"; then
                local _suff_summary="Web research data gathered"
                local _last_web
                _last_web=$(jq -r '[.action_log[] | select(.action | test("^/web")) | select(.status == "SUCCESS") | .output] | last // empty' "$micro_file" 2>/dev/null)
                [ -n "$_last_web" ] && _suff_summary="${_last_web:0:120}"
                _agent_complete_milestone "$micro_file" "$macro_file" "$micro_objective" \
                    "$_suff_summary" "" "$george_dir"
                return 0
            else
                # Inject eval reason into micro_memory so the router/specialist
                # can see WHY the previous attempt was judged INCOMPLETE and adapt.
                if [ -n "${_EVAL_MILESTONE_REASON:-}" ]; then
                    _micro_add_note "$micro_file" "EVAL_FEEDBACK: Milestone NOT complete — ${_EVAL_MILESTONE_REASON}. Try a different approach or tool."
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Sufficiency reached but evaluator says INCOMPLETE — injecting feedback into micro_memory"
                else
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Sufficiency reached but evaluator says INCOMPLETE — continuing"
                fi
            fi
        fi

        # ── PHASE 2: Specialist Execution ─────────────────────
        # Strip code fences — small models wrap router output in ```
        # when the prompt context is JSON-heavy.  sed removes bare
        # fence lines AND inline backticks so /web survives.
        selected_tool=$(echo "$selected_tool" | sed '/^```[a-z]*[[:space:]]*$/d; s/```//g')
        # Trim leading/trailing whitespace.
        selected_tool=$(echo "$selected_tool" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # ── SMART COMMAND EXTRACTION ──────────────────────────
        # Thinking models (Phi4, Qwen3) often wrap the tool name in
        # prose: "The next action is to use `/web` to..."
        # Strategy: scan the full output for a /(known_command) match
        # FIRST. Only fall back to first-word extraction if no valid
        # slash command is found anywhere in the output.
        local _extracted_cmd=""
        local _router_raw="$selected_tool"
        # Scan for /command patterns and validate against registry
        local _candidate
        while [[ "$_router_raw" =~ /([a-z]+) ]]; do
            _candidate="${BASH_REMATCH[1]}"
            if [ "$_candidate" = "bash" ]; then
                _extracted_cmd="$_candidate"; break
            elif declare -p CMD_REGISTRY &>/dev/null && [[ -n "${CMD_REGISTRY[$_candidate]+x}" ]]; then
                _extracted_cmd="$_candidate"; break
            elif [ -f "${LODGE_COMMANDS_DIR:-$LODGE_DIR/commands}/${_candidate}.sh" ]; then
                _extracted_cmd="$_candidate"; break
            fi
            # Remove this match and continue scanning
            _router_raw="${_router_raw#*"/${_candidate}"}"
        done

        # Save full cleaned router text for direct /respond fallback
        local _router_full_text="$selected_tool"
        local _direct_respond=0

        if [ -n "$_extracted_cmd" ]; then
            selected_tool="$_extracted_cmd"
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Router: extracted /$_extracted_cmd from prose output"
        else
            # Fallback: first word of first line (original behavior)
            selected_tool=$(echo "$selected_tool" | head -1 | awk '{print $1}' | sed 's|^/||; s|^/||')
        fi

        # ── SEARCH/RESEARCH REMAP ─────────────────────────────
        # Small models hallucinate /research or /search — these don't
        # exist. Remap to /web so the specialist generates a proper
        # /web search <query> command.
        if [[ "$selected_tool" == "research" || "$selected_tool" == "search" ]]; then
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Router: remapped /$selected_tool -> /web"
            selected_tool="web"
        fi

        # ── TOOL VALIDATION: Reject hallucinated commands ─────
        # If the router outputs a tool name that doesn't exist in the
        # command registry or commands directory, fall back to re-routing
        # with the full command catalog injected.
        # This prevents the inner loop from wasting escalation rounds
        # on imaginary commands like "/execute".
        local _tool_valid=0
        local _hallucination_fallback=0
        if [ "$selected_tool" = "bash" ]; then
            _tool_valid=1
        elif declare -p CMD_REGISTRY &>/dev/null && [[ -n "${CMD_REGISTRY[$selected_tool]+x}" ]]; then
            _tool_valid=1
        elif [ -f "${LODGE_COMMANDS_DIR:-$LODGE_DIR/commands}/${selected_tool}.sh" ]; then
            _tool_valid=1
        fi
        if [ "$_tool_valid" -eq 0 ]; then
            # ── NO-SLASH DIRECT RESPOND ─────────────────────────
            # If the router produced prose with no slash command at all,
            # the text IS the answer. Route directly to /respond with
            # the full text — no specialist needed.
            if [ -z "$_extracted_cmd" ] && ! [[ "$_router_full_text" =~ /[a-z] ]]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Router: no slash command found — direct /respond"
                _direct_respond=1
            else
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Router hallucinated '/$selected_tool' — injecting full catalog for re-route"
                _hallucination_fallback=1
                selected_tool="respond"
            fi
        fi

        # ── SANDBOX INTERLOCK: Programmatic gate ──────────────
        # The 4B model obsessively routes through /sandbox even for
        # non-code tasks (social posts, web searches, etc.).
        # Programmatically reject /sandbox unless the micro objective
        # explicitly involves code, building, or project creation.
        if [ "$selected_tool" = "sandbox" ]; then
            local _obj_lower
            _obj_lower=$(echo "$micro_objective" | tr '[:upper:]' '[:lower:]')
            if ! [[ "$_obj_lower" =~ (build|compile|code|project|scaffold|init|clone|test|debug|deploy|create.*app|create.*project|write.*program|develop) ]]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Sandbox rejected for non-code objective — extracting real command"
                # Try to extract the real slash command from the micro objective
                local _real_cmd
                _real_cmd=$(echo "$micro_objective" | grep -oP '/[a-z]+' | head -1 | sed 's|^/||')
                if [ -n "$_real_cmd" ] && { declare -p CMD_REGISTRY &>/dev/null && [[ -n "${CMD_REGISTRY[$_real_cmd]+x}" ]]; }; then
                    selected_tool="$_real_cmd"
                else
                    # Fallback: scan objective for common command keywords
                    # Delivery commands checked FIRST to prevent research
                    # loop (e.g. "write a report" matching *web* before *write*).
                    case "$_obj_lower" in
                        *respond*|*present*|*deliver*answer*)             selected_tool="respond" ;;
                        *write*|*save*|*file*|*create*|*draft*|*compose*) selected_tool="write" ;;
                        *email*|*send*mail*)                             selected_tool="email" ;;
                        *social*|*discord*|*telegram*|*post*|*tweet*)    selected_tool="social" ;;
                        *journal*|*log*|*note*)                          selected_tool="journal" ;;
                        *recall*|*remember*|*knowledge*)                 selected_tool="recall" ;;
                        *search*|*web*|*fetch*|*url*|*look*up*)          selected_tool="web" ;;
                        *)                                               selected_tool="respond" ;;
                    esac
                fi
            fi
        fi

        # Declare cmd/cmd_is_slash early so both branches can set them
        local cmd=""
        local cmd_is_slash=0

        # ── DIRECT RESPOND BYPASS ─────────────────────────
        # When the router output was pure prose (no slash command),
        # skip the specialist entirely and deliver the text via /respond.
        if [ "$_direct_respond" -eq 1 ]; then
            cmd="/respond $_router_full_text"
            cmd_is_slash=1
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Direct respond bypass — skipping specialist"
        else

        # Re-prefix for specialist lookup
        [ "$selected_tool" != "bash" ] && selected_tool="/$selected_tool"

        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Phase 2 specialist: loading docs for $selected_tool"

        local specialist_sys=$(_build_specialist_prompt "$selected_tool" "$workdir" "$micro_objective")
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: specialist prompt <- syntax card for $selected_tool"

        # ── HALLUCINATION RECOVERY: Inject full command catalog ──
        # When the router hallucinated a command, the specialist needs
        # visibility into ALL available commands to pick a real one.
        # Inject the full command catalog so the model can route itself
        # to an appropriate tool instead of re-hallucinating the same
        # non-existent command. The /respond card acts as a minimal
        # fallback while the catalog provides the full toolbox view.
        if [ "$_hallucination_fallback" -eq 1 ] && declare -f commands_catalog &>/dev/null; then
            local _recovery_catalog
            _recovery_catalog=$(commands_catalog 2>/dev/null)
            specialist_sys="${specialist_sys}

IMPORTANT: The previously attempted command does not exist. Choose from ONLY the commands listed below.
AVAILABLE COMMANDS:
${_recovery_catalog}

Pick the BEST command from this list for the task. Output exactly ONE command with arguments."
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: specialist <- full command catalog (hallucination recovery)"
        fi

        # Inject cached micro_memory (action log) so the specialist sees
        # prior outputs, created files, and error history. Without this,
        # multi-step objectives fail because the specialist can't adapt.
        # Uses inner_context cached above (same iteration, no mutations yet).
        local _spec_tail="Write the COMPLETE command with all required arguments filled in from the MICRO OBJECTIVE. NEVER output a bare command name without arguments."
        # /web search gets a focused constraint — the model ignores
        # search_tips buried in the JSON card, so put it at the end
        # where recency bias makes it impossible to miss.
        if [[ "${selected_tool#/}" == "web" ]]; then
            _spec_tail="Output ONLY the /web command WITH ARGUMENTS. For /web search: extract 3-5 keywords FROM THE MICRO OBJECTIVE above. Drop filler words (the, a, for, in, to, and, or, about, including, regarding, comprehensive, professional, community, organizations, associations). DO NOT copy examples — derive keywords from the objective. NEVER output just '/web search' without keywords."
        fi
        local specialist_prompt="MICRO OBJECTIVE: $micro_objective\n\nACTION LOG:\n$inner_context\n\n${_spec_tail}"
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: specialist <- micro_memory action log ($(echo "$inner_context" | wc -l) lines)"

        # ── Per-command specialist token limit ─────────────────
        # Content-bearing commands (/write, /save, /email) need high
        # token limits (full file contents). Short commands (/web,
        # /social, /recall, etc.) only need 1-2 lines — cap them
        # tight to prevent verbose rambling.
        local _spec_tokens="${LLM_AGENT_TOKENS:-512}"
        local _base_cmd="${selected_tool#/}"
        case "$_base_cmd" in
            web|social|recall|journal|ask|vitals|phone|pgp|backup|cd|build|test|fix|commit|push|clone|git|github|container|wallet|slash|secret|download|vision|sandbox)
                _spec_tokens="${LLM_SPECIALIST_SHORT_TOKENS:-128}"
                ;;
        esac

        # Use llm_generate (non-streaming) for the specialist. The output
        # is a single command line that will be displayed by "Running: ..."
        # below. Streaming it first wastes time showing the same text twice
        # and confuses the user with redundant output.
        local action_plan
        local LLM_SCENARIO=agent
        action_plan=$(llm_generate "$specialist_prompt" "$specialist_sys" "$_spec_tokens" "$LLM_BUDGET_AGENT")

        # Transcript: log specialist response
        declare -f transcript_log_block &>/dev/null && transcript_log_block "specialist" "$action_plan"

        # ── DEBUG: Specialist raw response ─────────────────────
        if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
            local _spec_lines
            _spec_lines=$(echo "$action_plan" | wc -l)
            printf '  [debug] specialist response (%d lines): %s\n' "$_spec_lines" "$(echo "$action_plan" | head -3 | tr '\n' ' ' | head -c 120)" > /dev/tty 2>/dev/null
        fi

        # Cancel check after specialist LLM call
        if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
            return 1
        fi

        # Extract command based on routing: slash commands vs bash.
        # Slash commands: extracted as lines starting with /
        # Bash commands: extracted from ```bash blocks
        #
        # CRITICAL: Content-bearing commands (/write, /save, /email, /social)
        # may span multiple lines. The specialist outputs:
        #   /write filename.txt
        #   Line 1 of content
        #   Line 2 of content
        # We must capture the /command line AND all following non-slash,
        # non-code-fence continuation lines as the full command body.

        # ── STRIP CODE FENCE WRAPPING ─────────────────────────
        # The 4B specialist model frequently wraps its output in
        # markdown code fences (```...```) despite being told not to.
        # The awk parser below skips lines inside fences, which means
        # the actual /command gets ignored. Strip all fence lines
        # before parsing so the bare /command is visible.
        local _clean_plan
        _clean_plan=$(echo "$action_plan" | sed '/^```[a-z]*[[:space:]]*$/d')

        if [ "$selected_tool" != "bash" ]; then
            # Extract slash command + continuation lines (content body).
            # Captures the first /command line outside code blocks, then
            # all subsequent lines until EOF, another /command, or a code fence.
            # Continuation lines are joined with \n literal so /write and
            # /save receive them as multi-line content.
            cmd=$(echo "$_clean_plan" | awk '
                /^```/ { in_block = !in_block; next }
                in_block { next }
                !found && /^\/[a-z]/ { found=1; cmd=$0; next }
                found && /^\/[a-z]/ { exit }
                found && /^```/ { exit }
                found && /^\*\(/ { exit }
                found { cmd = cmd "\\n" $0 }
                END { if(found) print cmd }
            ')
            if [ -n "$cmd" ]; then
                cmd_is_slash=1
            else
                # Fallback: LLM may have wrapped it in a bash block anyway.
                # Use original action_plan — _clean_plan strips the fence
                # markers that the awk parser needs to find the block.
                cmd=$(echo "$action_plan" | awk '/```bash/{flag=1; next} /```/{flag=0} flag')
            fi
        else
            # IMPORTANT: Use the ORIGINAL action_plan (not _clean_plan) for
            # bash extraction. _clean_plan strips code fence lines, but the
            # bash awk parser NEEDS the ```bash markers to locate the code
            # block. Using _clean_plan here causes "No command extracted"
            # when the specialist correctly outputs a ```bash block.
            cmd=$(echo "$action_plan" | awk '/```bash/{flag=1; next} /```/{flag=0} flag')
        fi

        fi  # end direct_respond / specialist branch

        # ── SPECIALIST OUTPUT CLEANUP ─────────────────────────
        # These post-processing steps fix LLM artifacts in specialist
        # output (quote wrapping, multi-command concat, verbose queries).
        # Skip entirely for direct respond — the text is prose content,
        # not LLM-generated command syntax.
        if [ "$_direct_respond" -ne 1 ]; then

        # ── MULTI-COMMAND SPLITTER ────────────────────────────
        # The LLM sometimes concatenates multiple slash commands on one line:
        #   /sandbox new x  /write file.md "text"  /social post discord "msg"
        # Extract only the FIRST slash command and discard the rest.
        # SKIP for multi-line commands (content body uses literal \n) — those
        # are content-bearing commands like /write, /save, /email where the
        # "second /command" pattern would incorrectly split content text.
        if [ "$cmd_is_slash" -eq 1 ] && [[ "$cmd" != *'\n'* ]] && [[ "$cmd" =~ ^(/[a-z]+[[:space:]]) ]]; then
            # Check for a second embedded slash command (space-/cmd pattern)
            local _first_cmd
            _first_cmd=$(echo "$cmd" | sed 's|  */|\n/|g' | head -1)
            if [ "$_first_cmd" != "$cmd" ]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Split multi-command: extracted '${_first_cmd:0:60}...'"
                cmd="$_first_cmd"
            fi
        fi

        # ── QUOTE NORMALIZATION ────────────────────────────────
        # The LLM wraps slash command arguments in shell-style quotes:
        #   /init python "pid loop tuning assistant"
        #   /social post discord "#lunkers" "hello world"
        # Slash commands don't use shell parsing — quotes are literal.
        # Strip matching outer quotes from the args portion.
        if [ "$cmd_is_slash" -eq 1 ] && [[ "$cmd" == *'"'* ]]; then
            cmd=$(echo "$cmd" | sed 's/"//g')
        fi
        if [ "$cmd_is_slash" -eq 1 ] && [[ "$cmd" == *"'"* ]]; then
            cmd=$(echo "$cmd" | sed "s/'//g")
        fi

        # ── WEB SEARCH QUERY TRIMMER ──────────────────────────
        # Programmatic backstop: even with prompt guidance, the 4B
        # model produces verbose search queries. Strip common filler
        # words and cap at 8 tokens so search engines get clean input.
        if [ "$cmd_is_slash" -eq 1 ] && [[ "$cmd" == /web\ search\ * ]]; then
            local _raw_query="${cmd#/web search }"
            # Strip markdown bold/italic markers leaked from milestone text
            _raw_query=$(echo "$_raw_query" | sed 's/\*\+//g')
            # Strip filler/stopwords (case-insensitive)
            local _trimmed_query
            _trimmed_query=$(echo "$_raw_query" | sed '
                s/\bOR\b//g; s/\bAND\b//g;
                s/\b[Tt]he\b//g; s/\b[Aa]n\?\b//g; s/\b[Ff]or\b//g;
                s/\b[Ii]n\b//g; s/\b[Tt]o\b//g; s/\b[Aa]nd\b//g;
                s/\b[Oo]r\b//g; s/\b[Oo]f\b//g; s/\b[Oo]n\b//g;
                s/\b[Aa]bout\b//g; s/\b[Ii]ncluding\b//g;
                s/\b[Rr]egarding\b//g; s/\b[Cc]omprehensive\b//g;
                s/\b[Pp]rofessional\b//g; s/\b[Cc]ommunity\b//g;
                s/\b[Oo]rganizations\?\b//g; s/\b[Aa]ssociations\?\b//g;
                s/\b[Ff]ocusing\b//g; s/\b[Ii]dentify\b//g;
                s/\b[Rr]elevant\b//g; s/\b[Ss]pecific\b//g;
                s/\b[Vv]arious\b//g; s/\b[Rr]elated\b//g;
                s/\b[Ww]ith\b//g; s/\b[Tt]hat\b//g; s/\b[Ff]rom\b//g;
                s/  */ /g; s/^ *//; s/ *$//' )
            # Cap at 8 words
            _trimmed_query=$(echo "$_trimmed_query" | awk '{for(i=1;i<=NF&&i<=8;i++) printf "%s ", $i; print ""}'  | sed 's/ *$//')
            if [ -n "$_trimmed_query" ] && [ "$_trimmed_query" != "$_raw_query" ]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] web-search trimmed: '$_raw_query' -> '$_trimmed_query'"
                cmd="/web search $_trimmed_query"
            fi
        fi

        # ── SINGLE-URL ENFORCEMENT ────────────────────────────
        # The 4B model generates "OR" chains with multiple URLs:
        #   /web fetch URL1 OR URL2 OR URL3
        # These fail because web_fetch/scrape/download/vision expect
        # exactly one URL. Extract only the first http(s) URL.
        if [ "$cmd_is_slash" -eq 1 ]; then
            local _needs_single_url=0
            local _url_cmd_prefix=""
            case "$cmd" in
                "/web fetch "*)          _needs_single_url=1; _url_cmd_prefix="/web fetch" ;;
                "/web scrape-images "*)   _needs_single_url=1; _url_cmd_prefix="/web scrape-images" ;;
                "/web scrapeimages "*)    _needs_single_url=1; _url_cmd_prefix="/web scrapeimages" ;;
                "/download "*)            _needs_single_url=1; _url_cmd_prefix="/download" ;;
                "/vision "*)              _needs_single_url=1; _url_cmd_prefix="/vision" ;;
            esac
            if [ "$_needs_single_url" -eq 1 ]; then
                local _url_args="${cmd#$_url_cmd_prefix }"
                # Count URLs — only intervene if multiple detected
                local _url_count
                _url_count=$(echo "$_url_args" | grep -oP 'https?://[^\s"'"'"']+' | wc -l)
                if [ "$_url_count" -gt 1 ]; then
                    local _first_url
                    _first_url=$(echo "$_url_args" | grep -oP 'https?://[^\s"'"'"']+' | head -1)
                    if [ -n "$_first_url" ]; then
                        # /vision may have a prompt after the URL — preserve it
                        if [[ "$cmd" == "/vision "* ]]; then
                            # Extract prompt: everything after the first URL
                            local _after_url="${_url_args#*"$_first_url"}"
                            # Strip any trailing URLs/OR chains from the prompt
                            _after_url=$(echo "$_after_url" | sed 's/[[:space:]]*\(OR\|AND\)[[:space:]].*//I; s/[[:space:]]*https\?:\/\/.*//; s/^[[:space:]]*//')
                            cmd="/vision ${_first_url}${_after_url:+ $_after_url}"
                        else
                            cmd="${_url_cmd_prefix} ${_first_url}"
                        fi
                        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] single-url: kept first of $_url_count URLs"
                    fi
                fi
            fi
        fi

        fi  # end specialist output cleanup (skipped for direct respond)

        # ── CONSECUTIVE WEB SEARCH INTERLOCK ──────────────────
        # When the agent has already done N consecutive /web search
        # commands (default: 1), redirect to /web fetch or /web
        # scrape-images instead. Inject the previous search results
        # as research context + dedicated fetch/scrape-images catalog
        # cards so the model picks a URL to fetch instead of searching
        # again. This prevents the search-loop where the agent keeps
        # searching without ever fetching page content.
        if [ "$cmd_is_slash" -eq 1 ] && [[ "$cmd" == /web\ search\ * ]] && [ "$_web_search_consec" -ge "${AGENT_WEB_SEARCH_CONSEC_MAX:-1}" ]; then
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] web-search interlock: $_web_search_consec consecutive searches (max ${AGENT_WEB_SEARCH_CONSEC_MAX:-1}) — redirecting to fetch/scrape"
            ui_warn "Web search interlock: $_web_search_consec consecutive searches. Redirecting to fetch/scrape."

            # Inject previous search output as research buffer
            local _prev_search_output=""
            _prev_search_output=$(jq -r '[.action_log[] | select(.action | test("^/web search")) | select(.status == "SUCCESS") | .output] | last // empty' "$micro_file" 2>/dev/null)

            # Build a focused specialist prompt with ONLY fetch/scrape cards
            local _ws_interlock_sys="TASK: $micro_objective
You have already searched the web. Now you must FETCH or SCRAPE a specific URL from the search results below.

OUTPUT FORMAT: exactly ONE /web command on its own line, starting with /
FORBIDDEN: /web search (already done — use the URLs below instead)

AVAILABLE COMMANDS (use ONLY these):
/web fetch <url>           — Download and extract readable TEXT from a webpage (HTML/PDF/JSON). Returns plain text, no images.
/web scrape-images <url>   — Returns STRUCTURED JSON: {url, title, content, images:[]} with page text AND image URIs. Use when you need images.

RULES:
- Pick the MOST RELEVANT URL from the search results below
- Use /web fetch for text content (articles, docs, specs, prices)
- Use /web scrape-images when you need images or visual content
- Output exactly ONE command with a full https:// URL
- NEVER output /web search — you must use a URL from the results"

            local _ws_interlock_prompt="MICRO OBJECTIVE: $micro_objective\n\nPREVIOUS SEARCH RESULTS:\n${_prev_search_output:-No search results available.}\n\nPick the best URL from the search results and output a /web fetch or /web scrape-images command."

            local _ws_interlock_cmd
            local LLM_SCENARIO=agent
            _ws_interlock_cmd=$(llm_generate "$_ws_interlock_prompt" "$_ws_interlock_sys" "${LLM_SPECIALIST_SHORT_TOKENS:-128}" "$LLM_BUDGET_AGENT")

            # Clean and extract the command
            _ws_interlock_cmd=$(echo "$_ws_interlock_cmd" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
            _ws_interlock_cmd=$(echo "$_ws_interlock_cmd" | sed ':a;N;$!ba;s/<think>.*$//g')
            _ws_interlock_cmd=$(echo "$_ws_interlock_cmd" | sed 's/\[THINK\][^[]*\[\/THINK\]//gI')
            _ws_interlock_cmd=$(echo "$_ws_interlock_cmd" | sed ':a;N;$!ba;s/\[THINK\].*$//gI')
            _ws_interlock_cmd=$(echo "$_ws_interlock_cmd" | sed '/^```[a-z]*[[:space:]]*$/d; s/```//g')
            _ws_interlock_cmd=$(echo "$_ws_interlock_cmd" | grep -m1 '^/web ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/"//g')

            if [[ "$_ws_interlock_cmd" == /web\ fetch\ * ]] || [[ "$_ws_interlock_cmd" == /web\ scrape-images\ * ]] || [[ "$_ws_interlock_cmd" == /web\ scrapeimages\ * ]]; then
                cmd="$_ws_interlock_cmd"
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] web-search interlock: redirected to '$cmd'"
                _micro_add_note "$micro_file" "INTERLOCK: Consecutive web search limit reached. Redirected to: $cmd"
            else
                # Fallback: if specialist couldn't extract a URL, try to grab
                # the first URL from the previous search results programmatically
                local _fallback_url=""
                _fallback_url=$(echo "$_prev_search_output" | grep -oP 'https?://[^\s"'"'"']+' | head -1)
                if [ -n "$_fallback_url" ]; then
                    cmd="/web fetch $_fallback_url"
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] web-search interlock: programmatic fallback to '$cmd'"
                    _micro_add_note "$micro_file" "INTERLOCK: Consecutive web search limit. Programmatic fallback to: $cmd"
                else
                    # No URLs available — let the original search through but warn
                    _micro_add_note "$micro_file" "WARNING: $_web_search_consec consecutive web searches. No URLs found to fetch. Consider using /recall or /respond."
                fi
            fi
        fi

        # ── PROGRAMMATIC INTERLOCK: Identicality Lockout ──────
        # Levels 3-4: Prevents the LLM from re-running the exact same
        # broken command. If identical, reject and force regeneration.
        if [ "$_fail_count" -ge 3 ] && [ -n "$cmd" ] && [ "$cmd" == "$last_failed_cmd" ]; then
            ui_warn "Interlock Triggered: Identical failed command. Forcing regeneration."
            _micro_add_note "$micro_file" "System interlock: Command '$cmd' rejected (identical to previous failure)"
            inner_attempts=$((inner_attempts + 1))
            continue
        fi

        # ── SPECIALIST OUTPUT VALIDATION ───────────────────────
        # The specialist may hallucinate commands that don't exist
        # (e.g. "/weather" when the router fell back to /respond but
        # the specialist ignored the catalog injection). Validate the
        # extracted slash command BEFORE dispatching to prevent
        # burning escalation levels on commands that will always
        # return exit 127. On rejection, log the hallucination and
        # inject the full command catalog into micro_memory so the
        # next iteration's specialist has visibility into real tools.
        if [ "$cmd_is_slash" -eq 1 ] && [ -n "$cmd" ]; then
            local _spec_cmd_name
            _spec_cmd_name=$(echo "$cmd" | awk '{print $1}' | sed 's|^/||')
            local _spec_cmd_valid=0
            if declare -p CMD_REGISTRY &>/dev/null && [[ -n "${CMD_REGISTRY[$_spec_cmd_name]+x}" ]]; then
                _spec_cmd_valid=1
            elif [ -f "${LODGE_COMMANDS_DIR:-$LODGE_DIR/commands}/${_spec_cmd_name}.sh" ]; then
                _spec_cmd_valid=1
            fi
            if [ "$_spec_cmd_valid" -eq 0 ]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Specialist hallucinated '/$_spec_cmd_name' — rejecting before dispatch"
                _micro_add_action "$micro_file" "$cmd" "FAILED" 127 \
                    "Command /$_spec_cmd_name does not exist. Available commands: $(echo "${!CMD_REGISTRY[@]}" | tr ' ' ', ')" "system_validation"
                # Inject catalog reminder so next iteration picks a real command
                if declare -f commands_catalog &>/dev/null; then
                    local _valid_cmds
                    _valid_cmds=$(echo "${!CMD_REGISTRY[@]}" | tr ' ' '\n' | sort | sed 's/^/\//' | tr '\n' ', ')
                    _micro_add_note "$micro_file" "SYSTEM: /$_spec_cmd_name is not a valid command. Valid commands: ${_valid_cmds%. }"
                fi
                inner_attempts=$((inner_attempts + 1))
                continue
            fi
        fi

        # ── EMPTY COMMAND HANDLER ──────────────────────────────
        # If command extraction failed (specialist output was garbage,
        # unparseable, or entirely wrapped in noise), log the failure
        # to micro_memory and increment the loop. Without this, the
        # loop silently burns all iterations with no diagnostic trail.
        if [ -z "$cmd" ]; then
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] No command extracted from specialist output"
            _micro_add_action "$micro_file" "(parse_failure)" "FAILED" 1 \
                "Specialist output could not be parsed into a command: ${action_plan:0:200}" "system"
            inner_attempts=$((inner_attempts + 1))
            continue
        fi

        if [ -n "$cmd" ]; then
            # Display a truncated version for multi-line commands
            local _cmd_display
            if [[ "$cmd" == *'\n'* ]]; then
                # Show first line + indicator that content follows
                _cmd_display=$(echo "$cmd" | head -1)
                local _cmd_lines
                _cmd_lines=$(echo "$cmd" | awk -F'\\\\n' '{print NF}')
                _cmd_display="${_cmd_display:0:120} (+${_cmd_lines} lines)"
            else
                _cmd_display="$cmd"
            fi
            ui_step "Running: $_cmd_display"

            # ── DIRECTORY CHANGE INTERCEPTION ─────────────────
            # /cd and /init change directories but commands_dispatch
            # runs in a subshell ($(...)) so cd never propagates.
            # Handle these in the parent shell directly.
            if [[ "$cmd" == /cd\ * ]]; then
                local _cd_target
                _cd_target=$(echo "$cmd" | sed 's|^/cd *||')
                if [ -d "$workdir/$_cd_target" ]; then
                    workdir=$(cd "$workdir/$_cd_target" && pwd)
                    output="Changed to: $workdir"
                    exit_code=0
                    ui_ok "$output"
                elif [ -d "$_cd_target" ]; then
                    workdir=$(cd "$_cd_target" && pwd)
                    output="Changed to: $workdir"
                    exit_code=0
                    ui_ok "$output"
                else
                    output="Directory not found: $_cd_target"
                    exit_code=1
                    ui_err "$output"
                fi
                _micro_add_action "$micro_file" "$cmd" "$([ $exit_code -eq 0 ] && echo 'SUCCESS' || echo 'FAILED')" "$exit_code" "$output" "cd_intercept"
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] workdir now: %s\n' "$workdir" > /dev/tty 2>/dev/null
                inner_attempts=$((inner_attempts + 1))
                continue
            fi

            # Execute based on command type:
            #   Slash commands → commands_dispatch (proper command registry)
            #   Bash commands  → eval (direct shell execution)
            # head -c 2000 : Reads only the first 2000 bytes to prevent
            # context window overflow from massive stack traces.
            local output
            local exit_code
            if [ "$cmd_is_slash" -eq 1 ] && declare -f commands_dispatch &>/dev/null; then
                output=$(commands_dispatch "$cmd" "$workdir" 2>&1 | head -c 2000)
                exit_code=${PIPESTATUS[0]}
            else
                output=$(eval "$cmd" 2>&1 | head -c 2000)
                exit_code=${PIPESTATUS[0]}
            fi

            if [ $exit_code -eq 0 ]; then
                # ── POST-INIT WORKDIR UPDATE ───────────────────
                # /init creates a project dir and cd's into it,
                # but that cd happens in the subshell. Update
                # workdir so subsequent commands target the project.
                if [[ "$cmd" == /init\ * ]]; then
                    local _init_name
                    _init_name=$(echo "$cmd" | awk '{print $2}')
                    if [ -n "$_init_name" ] && [ -d "$workdir/$_init_name" ]; then
                        workdir="$workdir/$_init_name"
                        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] post-init workdir: %s\n' "$workdir" > /dev/tty 2>/dev/null
                    fi
                fi
                _last_success_cmd="$cmd"
                _last_success_snippet="${output:0:200}"

                # ── CONSECUTIVE WEB SEARCH COUNTER ─────────────
                # Track how many /web search commands run in a row.
                # Reset on any non-web-search command so the interlock
                # only triggers on genuine consecutive search loops.
                if [[ "$cmd" == /web\ search\ * ]]; then
                    _web_search_consec=$((_web_search_consec + 1))
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] web-search-consec: $_web_search_consec (max ${AGENT_WEB_SEARCH_CONSEC_MAX:-1})"
                else
                    _web_search_consec=0
                fi

                # ── WEB OUTPUT CONDENSER ───────────────────────
                # Raw web scrape/fetch output can be 100+ lines of noisy
                # HTML-extracted text that gets carried through EVERY
                # subsequent router + specialist call. Instead, pay
                # for one cheap LLM call to condense it into a focused
                # summary the evaluator can actually use.
                #
                # SKIP for /web search — search results are already
                # structured (numbered URLs + snippets) and MUST be
                # preserved verbatim so the agent can pick URLs for
                # follow-up /web fetch commands. Condensing search
                # results destroys the URLs.
                #
                # SKIP for /web images — same reason (image URLs needed).
                if [[ "$cmd" == /web\ fetch* ]] || [[ "$cmd" == /web\ scrape* ]] || [[ "$cmd" == /web\ summary* ]]; then
                  if [ "${#output}" -gt 300 ]; then
                    local _condense_prompt _condensed
                    # Build context-aware condense prompt
                    _condense_prompt="TASK: $micro_objective"
                    # Inject goal context: prefer current honeydew item over raw primary_objective
                    if [ "$_has_honeydew" -eq 1 ] && [ -f "$_hd_inner_file" ]; then
                        local _hd_current
                        _hd_current=$(jq -r '[.[] | select(.done != true)] | first | .task // empty' "$_hd_inner_file" 2>/dev/null)
                        [ -n "$_hd_current" ] && _condense_prompt="CURRENT OBJECTIVE: $_hd_current\nCURRENT STEP: $micro_objective"
                    elif [ -f "$macro_file" ]; then
                        local _primary_for_condense
                        _primary_for_condense=$(_macro_get "$macro_file" "primary_objective")
                        [ -n "$_primary_for_condense" ] && _condense_prompt="OVERALL GOAL: $_primary_for_condense\nCURRENT STEP: $micro_objective"
                    fi
                    _condense_prompt="${_condense_prompt}\n\nWEB CONTENT (from: $cmd):\n${output}\n\nIn 3-5 sentences, summarize useful information. Preserve specific facts, names, numbers, URLs, and data points relevant to the task. If the content is mostly junk (cookie notices, paywalls, login walls, ad text, empty/broken page, or irrelevant boilerplate), say: JUNK: <brief reason>. If partially useful, extract what matters and note what was missing."
                    local _condense_sys="You are a concise factual summarizer. No personality. Preserve URLs, names, numbers. 3-5 sentences max."
                    local LLM_SCENARIO=evaluator
                    _condensed=$(llm_generate "$_condense_prompt" "$_condense_sys" "${LLM_WEB_CONDENSE_TOKENS:-200}" "$LLM_BUDGET_AGENT" 2>/dev/null)
                    # Strip think blocks from summary
                    _condensed=$(echo "$_condensed" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
                    _condensed=$(echo "$_condensed" | sed ':a;N;$!ba;s/<think>.*$//g')
                    _condensed=$(echo "$_condensed" | sed '/^[[:space:]]*$/d')
                    if [ -n "$_condensed" ]; then
                        output="[Web Summary] $_condensed"
                        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] web condenser: %d chars -> %d chars\n' "${#output}" "${#_condensed}" > /dev/tty 2>/dev/null
                    fi
                  fi
                fi

                _micro_add_action "$micro_file" "$cmd" "SUCCESS" 0 "$output" "specialist"

                # Transcript: log command execution result
                declare -f transcript_log_block &>/dev/null && transcript_log_block "output (exit 0)" "$cmd\n${output:0:3000}"

                # ── DEBUG: Command output to TTY ──────────────
                # Print command result to TTY so operator can see
                # what the agent is receiving as feedback. Shows
                # a truncated preview (no risk of model contamination
                # since this goes to /dev/tty, not stdout).
                if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
                    local _out_lines _out_preview
                    _out_lines=$(echo "$output" | wc -l)
                    if [ "$_out_lines" -le 10 ]; then
                        _out_preview="$output"
                    else
                        _out_preview=$(echo "$output" | head -8)
                        _out_preview="${_out_preview}
  ... (${_out_lines} lines total)"
                    fi
                    [ -n "$output" ] && printf '  [debug] cmd output (exit %d, %d lines):\n%s\n' "$exit_code" "$_out_lines" "$_out_preview" > /dev/tty 2>/dev/null
                    [ -z "$output" ] && printf '  [debug] cmd output: (empty, exit 0)\n' > /dev/tty 2>/dev/null
                fi

                # ── WEB SUFFICIENCY GATE ───────────────────────
                # After N successful web actions, mark sufficiency
                # so the programmatic enforcement gate at loop top
                # forces completion on the next iteration.
                if [[ "$cmd" == /web* ]]; then
                    local _web_ok_count
                    _web_ok_count=$(_micro_action_count "$micro_file" "^/web")
                    if [ "$_web_ok_count" -ge "${AGENT_WEB_SUFFICIENCY:-3}" ]; then
                        _micro_set_sufficiency "$micro_file"
                        _micro_add_note "$micro_file" "SUFFICIENCY: $_web_ok_count web actions completed. Enough data gathered."
                        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Web sufficiency gate: $_web_ok_count actions reached threshold"
                    fi
                fi

                # ── PLACEHOLDER DETECTION FOR /write ───────────
                # If a /write command succeeded but the written content
                # contains bracket placeholders like [your name here],
                # inject a WARNING so the evaluator and router see that
                # the content is incomplete/generic — not real.
                if [[ "$cmd" == /write* ]]; then
                    local _write_body
                    _write_body=$(echo "$cmd" | tail -n +2)
                    if [ -n "$_write_body" ] && echo "$_write_body" | grep -qP '\[(?:your |briefly |mention |e\.g\.|TBD|TODO|placeholder)' 2>/dev/null; then
                        _micro_add_warning "$micro_file" "File contains placeholder text ([your ...], [TBD], etc.). Template, not finished content. Rewrite with actual data."
                        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] /write placeholder detected — warning injected"
                    fi
                fi

                # ── USAGE/HELP OUTPUT DETECTION ────────────────
                # Some commands return usage/help text on exit 0 when
                # called with missing or wrong arguments. The P1 evaluator
                # can't distinguish "usage printed" from "work done".
                # Detect common usage patterns and inject a warning.
                if [ -n "$output" ] && [ "${#output}" -lt 2000 ]; then
                    local _out_lower
                    _out_lower=$(echo "$output" | tr '[:upper:]' '[:lower:]')
                    if [[ "$_out_lower" =~ (^usage:|^usage |subcommands:|commands:|options:|synopsis:) ]] || \
                       [[ "$_out_lower" =~ (^[[:space:]]*\/[a-z]+[[:space:]]+(search|fetch|post|send|read|write|new|build|test|run)[[:space:]]) && "$_out_lower" =~ (description|help|available) ]]; then
                        _micro_add_warning "$micro_file" "Command returned USAGE/HELP text, not actual work output. The command was likely called with wrong or missing arguments. Retry with correct arguments."
                        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] usage/help output detected — warning injected"
                    fi
                fi

                # ── EVALUATOR-BASED COMPLETION CHECK ───────────
                # After each successful action, run the P1 milestone
                # evaluator to determine if the micro-objective is met.
                # This replaces the old router SUCCESS detection — the
                # evaluator has richer context and can't be fooled by
                # the model hallucinating early completion.
                local _action_count
                _action_count=$(_micro_action_count "$micro_file")
                if [ "$_action_count" -ge 1 ]; then
                    if _agent_evaluate_milestone "$macro_file" "$micro_file" "$micro_objective"; then
                        _agent_complete_milestone "$micro_file" "$macro_file" "$micro_objective" \
                            "Objective fulfilled" "$_last_success_cmd" "$george_dir"
                        return 0
                    fi
                fi

                inner_attempts=$((inner_attempts + 1))
                continue
            fi

            # ═══════════════════════════════════════════════════
            # FAILURE ESCALATION MATRIX
            # ═══════════════════════════════════════════════════
            last_failed_cmd="$cmd"

            # ── Enhanced failure logging ───────────────────────
            # Include timestamp, HTTP status (for web commands), and
            # the URL that failed so the log is actionable without
            # cross-referencing micro_memory.
            {
                echo ""
                echo "FAILED COMMAND: \`$cmd\`"
                echo "EXIT CODE: $exit_code"
                echo "TIMESTAMP: $(date '+%Y-%m-%d %H:%M:%S %Z')"
                # For /web commands, include the HTTP status / error code
                if [[ "$cmd" == /web* ]] && [ -f "$_WEB_STATUS_FILE" ]; then
                    local _web_fail_status
                    _web_fail_status=$(cat "$_WEB_STATUS_FILE" 2>/dev/null)
                    [ -n "$_web_fail_status" ] && echo "HTTP STATUS: $_web_fail_status"
                fi 2>/dev/null
                echo "OUTPUT:"
                echo " ${output:0:500}"
                echo "---"
            } >> "$fail_file"

            # ── WEB SOFT-FAILURE TOLERANCE ─────────────────────
            # Web fetches/scrapes fail frequently (HTML parsing errors,
            # anti-bot blocks, fragment URLs, etc.).  If this milestone
            # already has successful /web actions in micro_memory, treat
            # the failure as a soft failure: log it, inject a nudge to
            # use existing data, but do NOT burn escalation levels or
            # require operator intervention.  The evaluator will decide
            # if the successful scrapes provided enough context.
            if [[ "$cmd" == /web* ]]; then
                local _prior_web_ok
                _prior_web_ok=$(_micro_success_count "$micro_file" "^/web")
                if [ "$_prior_web_ok" -gt 0 ]; then
                    _micro_add_action "$micro_file" "$cmd" "FAILED" "$exit_code" "${output:0:300}" "specialist_soft_fail"
                    _micro_add_note "$micro_file" "Web fetch failed, but $_prior_web_ok prior web action(s) succeeded. Use existing data or try a different URL."
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] Web soft-failure: %d prior successes, skipping escalation\n' "$_prior_web_ok" > /dev/tty 2>/dev/null
                    inner_attempts=$((inner_attempts + 1))
                    continue
                fi
            fi

            _fail_count=$((_fail_count + 1))

            # ── Level 1: Naive Retry (Programmatic Bypass) ────
            # LLM is completely bypassed. Re-run the exact command
            # after a brief sleep. Catches transient network errors,
            # file locks, or race conditions without wasting tokens.
            #
            # SPECIAL CASE: /web scrape-images often fails on JS-rendered
            # SPAs (returns empty content or SIGPIPE). Instead of retrying
            # the same scrape-images, fall back to /web fetch which uses
            # simpler HTML extraction and handles more sites reliably.
            # /web fetch CAN naive-retry to itself since it's idempotent.
            if [ "$_fail_count" -le 1 ]; then
                local _l1_cmd="$cmd"
                local _l1_label="Retry"
                # Detect scrape-images and fall back to /web fetch
                if [[ "$cmd" == "/web scrape-images "* ]] || [[ "$cmd" == "/web scrapeimages "* ]]; then
                    local _scrape_url="${cmd##* }"
                    _l1_cmd="/web fetch $_scrape_url"
                    _l1_label="Fallback: scrape-images→fetch"
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] L1: scrape-images fallback -> /web fetch %s\n' "$_scrape_url" > /dev/tty 2>/dev/null
                fi
                ui_warn "Escalation L1: ${_l1_label}..."
                sleep 1
                if [[ "$_l1_cmd" == /* ]] && declare -f commands_dispatch &>/dev/null; then
                    output=$(commands_dispatch "$_l1_cmd" "$workdir" 2>&1 | head -c 2000)
                elif [ "$cmd_is_slash" -eq 1 ] && declare -f commands_dispatch &>/dev/null; then
                    output=$(commands_dispatch "$_l1_cmd" "$workdir" 2>&1 | head -c 2000)
                else
                    output=$(eval "$_l1_cmd" 2>&1 | head -c 2000)
                fi
                if [ ${PIPESTATUS[0]} -eq 0 ]; then
                    _micro_add_action "$micro_file" "$_l1_cmd" "SUCCESS" 0 "$output" "L1_retry"
                    inner_attempts=$((inner_attempts + 1))
                    continue
                fi
                ui_warn "L1 failed. Escalating..."
            fi

            # ── Level 2: Forced Knowledge Retrieval ───────────
            # Parse the base command from the failed string and
            # programmatically execute /recall <base_command>.
            # Inject the recall stdout into micro_memory so the
            # LLM reads its own documentation BEFORE retrying.
            # Also inject the full command catalog so the model
            # can see ALL available commands and pick a real one
            # instead of re-hallucinating a non-existent command.
            if [ "$_fail_count" -le 2 ]; then
                if declare -f recall_search_context &>/dev/null; then
                    local base_cmd
                    base_cmd=$(echo "$cmd" | awk '{print $1}')
                    ui_warn "Escalation L2: Forced recall for '$base_cmd'..."
                    local recall_result
                    recall_result=$(recall_search_context "$base_cmd" 3 2>/dev/null)
                    if [ -n "$recall_result" ]; then
                        _micro_add_note "$micro_file" "L2_recall ($base_cmd): $recall_result"
                        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: L2 recall for '$base_cmd' -> micro_memory"
                    fi
                fi
                # Inject compact command list so the model knows what
                # tools actually exist. Prevents repeated hallucinations
                # of non-existent commands (e.g. /weather, /research).
                if declare -p CMD_REGISTRY &>/dev/null; then
                    local _l2_valid_cmds
                    _l2_valid_cmds=$(echo "${!CMD_REGISTRY[@]}" | tr ' ' '\n' | sort | sed 's/^/\//' | tr '\n' ', ')
                    _micro_add_note "$micro_file" "L2_AVAILABLE_COMMANDS: ${_l2_valid_cmds%,}. Use ONLY these commands. If no built-in command fits, use /slash create <name> <description> to create a custom command, or /web search <query> to find information, or bash for shell commands."
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: L2 command list -> micro_memory"
                fi
            fi

            # ── Levels 3-4: Syntax Permutation + History Recall ─
            # Identicality lockout (top of loop) prevents identical reruns.
            # Additionally, read the failure log for past RECOVERY entries.
            # If the operator has previously solved a similar failure,
            # inject those instructions so the LLM can self-correct.
            if [ "$_fail_count" -ge 3 ] && [ -f "$fail_file" ]; then
                local past_recoveries
                past_recoveries=$(grep -B1 -A2 "^RECOVERY:\|^OPERATOR GUIDANCE:" "$fail_file" 2>/dev/null | tail -20)
                if [ -n "$past_recoveries" ]; then
                    ui_warn "Escalation L3: Injecting past recovery instructions..."
                    _micro_add_note "$micro_file" "L3_recovery: $past_recoveries"
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: L3 past recoveries -> micro_memory"
                fi
            fi

            # ── Level 5: Forced Web Fallback ──────────────────
            # LLM is bypassed again. Extract the last 5 lines of stderr
            # and automatically search the web for the error.
            if [ "$_fail_count" -ge 5 ] && declare -f web_search &>/dev/null; then
                local stderr_tail
                stderr_tail=$(echo "$output" | tail -n 5)
                local base_cmd
                base_cmd=$(echo "$cmd" | awk '{print $1}')
                ui_warn "Escalation L5: Web search for error..."
                local web_result
                web_result=$(web_search "error: $stderr_tail $base_cmd" 3 2>/dev/null)
                if [ -n "$web_result" ]; then
                    _micro_add_note "$micro_file" "L5_web_error_search: ${web_result:0:1500}"
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: L5 web error search -> micro_memory"
                fi
            fi

            # Append failure to micro memory so the LLM sees it on the next loop
            _micro_add_action "$micro_file" "$cmd" "FAILED" "$exit_code" "$output" "specialist"

            # Transcript: log failed command
            declare -f transcript_log_block &>/dev/null && transcript_log_block "output (exit $exit_code)" "$cmd\n${output:0:3000}"
        fi

        inner_attempts=$((inner_attempts + 1))
    done

    # ── Terminal Escalation: Human Operator Intervention ───────
    # All 5 levels exhausted. Drop to a safe holding state.
    # Present failures_log.md to the operator for guidance.
    # Skip entirely if cancelled — user wants to return to REPL, not be
    # prompted for guidance on an operation they already abandoned.
    if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
        _macro_add_milestone "$macro_file" "$micro_objective" "Cancelled" "" "UNKNOWN" "CANCELLED"
        return 1
    fi
    ui_err "Inner loop exhausted all escalation levels."
    if [ -f "$fail_file" ]; then
        echo ""
        ui_warn "Failures log:"
        tail -30 "$fail_file"
        echo ""
    fi
    printf "  %bGeorge needs help. Provide a command, explanation, or 'abort': %b" "$C_BOLD" "$C_RESET"
    local guidance
    read -r guidance < /dev/tty

    # ── ABORT PROPAGATION ─────────────────────────────────────
    # When the operator types 'abort', propagate cancellation to the
    # macro loop so the entire task stops — not just this milestone.
    # Previously, abort only terminated the inner loop and the macro
    # loop would immediately generate the same failed milestone again.
    if [ "$guidance" = "abort" ]; then
        _LODGE_CANCELLED=1
        touch "$_cancel_file" 2>/dev/null
        _macro_add_milestone "$macro_file" "$micro_objective" "Aborted by operator" "" "UNKNOWN" "ABORTED"
        return 1
    fi

    if [ -n "$guidance" ] && [ "$guidance" != "abort" ]; then
        _micro_add_note "$micro_file" "Operator guidance: $guidance"

        # ── Catalog-Aware Guided Retry ────────────────────────
        # Combine operator input with the full command catalog so
        # the LLM maps natural language ("use /web search") to a
        # real command instead of hallucinating.
        # Inject micro_memory (action log) so the specialist sees
        # prior inputs, created files, and error history. Without this,
        # guided retries fail because the LLM can't see past attempts.
        local catalog=""
        if declare -f commands_catalog &>/dev/null; then
            catalog=$(commands_catalog)
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: guided retry <- command catalog"
        fi

        local guided_prompt="MICRO OBJECTIVE: $micro_objective

OPERATOR GUIDANCE: $guidance

AVAILABLE COMMANDS:
$catalog

The operator provided guidance after previous failures. Using the operator's instructions and the command catalog above, write the exact command to execute.
The command MUST be one listed in AVAILABLE COMMANDS or a valid bash command.
Output a slash command line starting with / OR a bash code block."

        local guided_sys=$(_build_specialist_prompt "" "$workdir" "$micro_objective")
        local final_plan
        local LLM_SCENARIO=agent
        final_plan=$(llm_stream "$guided_prompt" "$guided_sys" "${LLM_AGENT_TOKENS:-512}" "$LLM_BUDGET_AGENT")

        # Extract slash command or bash command (same logic as main loop)
        local final_cmd=""
        local final_is_slash=0
        final_cmd=$(echo "$final_plan" | awk '
            /^```/ { in_block = !in_block; next }
            in_block { next }
            /^\/[a-z]/ { print; exit }
        ')
        if [ -n "$final_cmd" ]; then
            final_is_slash=1
        else
            final_cmd=$(echo "$final_plan" | awk '/```bash/{flag=1; next} /```/{flag=0} flag')
        fi

        if [ -n "$final_cmd" ]; then
            ui_step "Running (guided): $final_cmd"
            local final_output
            local final_exit
            if [ "$final_is_slash" -eq 1 ] && declare -f commands_dispatch &>/dev/null; then
                final_output=$(commands_dispatch "$final_cmd" "$workdir" 2>&1 | head -c 2000)
                final_exit=${PIPESTATUS[0]}
            else
                final_output=$(eval "$final_cmd" 2>&1 | head -c 2000)
                final_exit=${PIPESTATUS[0]}
            fi

            if [ "$final_exit" -eq 0 ]; then
                # ── Recovery Logging ───────────────────────────
                # Write a RECOVERY entry to the failure log so that
                # future L3 escalations can find what the operator
                # told us to do for similar failures.
                {
                    echo ""
                    echo "RECOVERY: \`$final_cmd\`"
                    echo "OPERATOR GUIDANCE: $guidance"
                    echo "ORIGINAL FAILURE: \`$last_failed_cmd\`"
                    echo "---"
                } >> "$fail_file"
                local summary="Completed with operator guidance"
                _micro_add_action "$micro_file" "$final_cmd" "SUCCESS" 0 "$final_output" "operator_guided"
                _micro_set_result "$micro_file" "COMPLETE" "$summary"
                _macro_add_milestone "$macro_file" "$micro_objective" "$summary" "$final_cmd" "ACTION"
                return 0
            else
                # Log guided failure for the record
                echo -e "\nFAILED COMMAND (guided): \`$final_cmd\`\nEXIT CODE: $final_exit\nOPERATOR GUIDANCE: $guidance\nOUTPUT:\n$final_output\n---" >> "$fail_file"
            fi
        fi
    fi

    _macro_add_milestone "$macro_file" "$micro_objective" "All escalation levels exhausted" "${last_failed_cmd:-}" "UNKNOWN" "FAILED"
    return 1
}

# ── Run full task: Macro Loop (The Strategist) ────────────────
# Governs the overall trajectory of the task using a dynamic
# dual-loop ReAct architecture:
#   Macro Loop: Determines the next high-level milestone.
#   Micro Loop: Executes via agent_inner_loop.
#
# Memory Architecture:
#   macro_memory.json — Persona seed + objective + completed milestones (JSON).
#   micro_memory.json — Overwritten per micro-objective (JSON, managed by inner loop).
#   failures_log.md — Isolated stderr graveyard (managed by inner loop).
agent_run() {
    local task="$1"
    local workdir="${2:-.}"

    if [ -z "$task" ]; then
        ui_err "No task provided"
        return 1
    fi

    # Signal that we're in a task (for cancellation handling)
    _LODGE_IN_TASK=1
    _LODGE_CANCELLED=0
    local _cancel_file="${TMPDIR:-/tmp}/.lodge-cancel-$$"

    # Reset debug counters at task start
    declare -f llm_debug_reset &>/dev/null && llm_debug_reset

    # ── Start transcript logging ──────────────────────────────
    declare -f transcript_start &>/dev/null && transcript_start "$task" "$workdir"

    ui_section "Task"
    ui_info "$task"

    # Check for cancellation (file-based — visible in subshells unlike variables)
    if [ -f "$_cancel_file" ]; then _LODGE_IN_TASK=0; return 1; fi

    # Pre-flight vitals check — abort if critically low on resources
    if declare -f vitals_preflight &>/dev/null; then
        if ! vitals_preflight "strict" 2>/dev/null; then
            ui_err "Task aborted — resolve resource issues above first"
            _LODGE_IN_TASK=0
            return 1
        fi
    fi

    # ── Initialize Memory Architecture ────────────────────────
    local george_dir="$workdir/.george"
    local macro_file="$george_dir/macro_memory.json"
    local micro_file="$george_dir/micro_memory.json"
    local fail_file="$george_dir/failures_log.md"
    mkdir -p "$george_dir"

    # ── Auto-create GEORGE.md if it doesn't exist ─────────────
    # Non-sandbox tasks (social posts, web searches, emails, etc.)
    # still need a GEORGE.md for task summaries and milestone tracking.
    # Without this, memory_update_section silently fails and task
    # history is lost for any task not preceded by /init.
    local _george_md="$workdir/GEORGE.md"
    if [ ! -f "$_george_md" ]; then
        local _proj_name
        _proj_name=$(basename "$workdir")
        if declare -f memory_init &>/dev/null; then
            memory_init "$workdir" "$_proj_name" "General"
        else
            cat > "$_george_md" << MEMEOF
# GEORGE — $_proj_name

## Project
name: $_proj_name
type: General

## Build
build: N/A
test: N/A

## Active Task
(none)

## Completed Milestones
(none)

## Context Files
(none)
MEMEOF
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] auto-created GEORGE.md in $workdir"
    fi

    # ── Flush stale memory from previous task ──────────────────
    # Previous task's memory files are preserved for review after
    # the task completes (they've already been summarized to journal).
    # Now wipe them fresh so old task requirements don't leak into
    # the new task's context via journal_reflect or evaluators.
    rm -f "$micro_file" "$fail_file" 2>/dev/null

    # Seed macro_memory.json with persona, objective, and project context.
    # Uses _memory_soul_identity() for a clean cut at the TMS boundary
    # instead of an arbitrary head -20 that could split mid-paragraph.
    local _persona_text
    _persona_text=$(_memory_soul_identity)
    local _george_ctx=""
    if declare -f memory_read_project &>/dev/null; then
        _george_ctx=$(memory_read_project "$workdir" 2>/dev/null)
        if [ -n "$_george_ctx" ]; then
            # Include project info + context files — skip active task/milestones
            _george_ctx=$(echo "$_george_ctx" | awk '
                /^## (Project|Build|Context Files)/ { show=1 }
                /^## (Active Task|Completed Milestones)/ { show=0 }
                show { print }
            ')
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: macro_memory <- GEORGE.md project context"
        fi
    fi
    _macro_init "$macro_file" "$task" "$_persona_text" "$_george_ctx"

    # Create failures log alongside macro memory
    echo "# Failures Log" > "$fail_file"
    echo "---" >> "$fail_file"

    # ── Build Honeydew List ───────────────────────────────────
    # Decompose the user's task into a precedence-ranked checklist
    # BEFORE the first strategist call. This gives the evaluator
    # and strategist structured visibility into remaining work
    # (e.g., "2/4 tasks remain") instead of guessing.
    _agent_honeydew_build "$task" "$workdir"

    # Inject honeydew list into macro_memory so strategist + evaluator
    # see it as part of the task context.
    local _hd_content
    _hd_content=$(_agent_honeydew_read "$workdir" 2>/dev/null)
    if [ -n "$_hd_content" ]; then
        _macro_set_honeydew "$macro_file" "$_hd_content"
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: honeydew list -> macro_memory"
    fi

    # ── Macro Loop: Milestone-by-milestone execution ──────────
    local macro_iterations=0
    local max_macro_loops="${AGENT_MAX_STEPS:-20}"
    local completed_milestones=0
    local failed_milestones=""
    local _exec_log=""
    # Milestone deduplication: track attempted milestones so the
    # strategist doesn't regenerate the same failed milestone in a
    # loop. Each entry is "status|milestone_text".
    local -a _attempted_milestones=()
    # Track consecutive research-only milestones (web/recall) so
    # the strategist is forced toward delivery after saturation.
    local _research_milestone_count=0
    # Last evaluator feedback — prominently surfaced to strategist.
    # Updated after each evaluator pass so the strategist sees exactly
    # what the evaluator said was missing on the PREVIOUS iteration.
    local _last_eval_feedback=""

    while [ "$macro_iterations" -lt "$max_macro_loops" ]; do
        # Check for cancellation between milestones
        if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
            ui_warn "Task cancelled at milestone $((macro_iterations + 1))"
            break
        fi

        # Inter-milestone vitals check
        if declare -f vitals_guard_disk &>/dev/null; then
            if ! vitals_guard_disk 2>/dev/null; then
                ui_warn "Stopping task — disk critically low"
                break
            fi
            vitals_guard_ram 2>/dev/null || true
        fi

        # ── Subtask expansion: decompose complex honeydew items ──
        # Before the strategist picks the next milestone, check if
        # the next pending honeydew item is compound/complex. If so,
        # expand it into 2-4 atomic sub-items in-place. This gives
        # the strategist granular targets instead of monolithic goals
        # that require multiple milestones to satisfy.
        if _agent_honeydew_maybe_expand "$workdir"; then
            # Refresh honeydew in macro_memory after expansion
            local _hd_expanded
            _hd_expanded=$(_agent_honeydew_read "$workdir" 2>/dev/null)
            if [ -n "$_hd_expanded" ] && [ -f "$macro_file" ]; then
                _macro_set_honeydew "$macro_file" "$_hd_expanded"
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] macro_memory refreshed after honeydew expansion"
            fi
        fi

        # Read macro_memory without persona for strategist context.
        # Persona identity text wastes ~200 tokens that the strategist
        # doesn't need for milestone selection.
        local macro_context
        macro_context=$(_macro_serialize_lean "$macro_file")
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: strategist <- macro_memory lean ($(echo "$macro_context" | wc -l) lines)"

        # Service status: let strategist know what's configured vs not.
        # Computed BEFORE tool_summary so COMMS can be conditionally included.
        local _svc_status=""
        if declare -f commands_services_status &>/dev/null; then
            _svc_status=$(commands_services_status 2>/dev/null)
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && [ -n "$_svc_status" ] && ui_dim "  [debug] inject: strategist <- services status"
        fi

        # Lean command list for the strategist (~150 tokens vs ~200 prior).
        # The strategist only needs to ROUTE — the specialist handles syntax.
        # Removed: CONFIG (interactive setup), EXTENSION (edge case),
        # DELIVERY as separate group (deduplicated into CORE/FILES).
        # COMMS is conditional — only included when social/email is configured.
        local _tool_summary='YOUR WORKING COMMANDS:
{"CORE":["/ask","/respond","/recall","/journal","/journal write"],
"FILES":["/write","/save","/read","/ls","/download","/build","/test","/fix","/commit","/push","/init","/clone","/cd"],
"WEB":["/web search","/web fetch","/web images","/github search","/vision"],
"SANDBOX":["/sandbox","/container"]'
        # Include COMMS only when social or email services are configured
        if echo "$_svc_status" | grep -qE 'CONFIGURED:.*(discord|telegram|mastodon|x/twitter|bluesky|email)'; then
            _tool_summary="${_tool_summary}"',"COMMS":["/social post","/social dm","/social read","/email send","/email inbox","/phone"]'
        fi
        _tool_summary="${_tool_summary}}"

        # Social context: registered Discord channels and Mastodon
        # instances so the strategist can generate correct channel
        # names. Injected into the USER prompt (not system prompt)
        # as reference data — keeps system prompt static for KV
        # cache reuse and avoids priming the model toward social
        # research loops on small (3-4B) models.
        local _social_ctx=""
        if declare -f social_context_compact &>/dev/null; then
            _social_ctx=$(social_context_compact 2>/dev/null)
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && [ -n "$_social_ctx" ] && ui_dim "  [debug] inject: strategist <- social context"
        fi

        # ── Inject milestone history into strategist prompt ─────
        # Prevents the strategist from regenerating failed milestones.
        local _milestone_history=""
        if [ ${#_attempted_milestones[@]} -gt 0 ]; then
            _milestone_history="\n\nPREVIOUSLY ATTEMPTED MILESTONES (do NOT repeat failed ones):"
            for _am in "${_attempted_milestones[@]}"; do
                _milestone_history="${_milestone_history}\n- ${_am}"
            done
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: strategist <- milestone history (${#_attempted_milestones[@]} entries)"
        fi

        local _strat_now
        _strat_now=$(date '+%Y-%m-%d %H:%M:%S %Z')

        # ── Inject honeydew list prominently into strategist ───
        # The honeydew list IS the driving objective once it exists.
        # Surface it as a separate block so the strategist picks the
        # next pending item instead of re-deriving goals from memory.
        local _strat_honeydew=""
        local _strat_hd_file="$george_dir/$HONEYDEW_FILE"
        if [ -f "$_strat_hd_file" ]; then
            local _strat_hd_content
            _strat_hd_content=$(jq -r '.items[] | "\(.id). [\(if .status == "done" then "x" else " " end)] \(.task)"' "$_strat_hd_file" 2>/dev/null)
            if [ -n "$_strat_hd_content" ]; then
                local _strat_hd_total _strat_hd_done
                _strat_hd_total=$(jq '.items | length' "$_strat_hd_file" 2>/dev/null || echo 0)
                _strat_hd_done=$(jq '[.items[] | select(.status == "done")] | length' "$_strat_hd_file" 2>/dev/null || echo 0)
                _strat_honeydew="\n\n>>> HONEYDEW LIST (${_strat_hd_done}/${_strat_hd_total} complete) — YOUR DRIVING OBJECTIVES <<<\n${_strat_hd_content}\n>>> Pick the FIRST [ ] item by number. Do NOT skip items. Do NOT re-derive objectives from memory. <<<"
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: strategist <- honeydew list (${_strat_hd_done}/${_strat_hd_total})"
            fi
        fi

        # NOTE: Date is in the USER prompt, not system prompt.
        # Keeping system prompt static enables llama-server KV cache
        # reuse across consecutive strategist calls (~30-60% prefill savings).
        local macro_prompt="Current date/time: ${_strat_now}\n\nTask memory:\n$macro_context${_strat_honeydew}${_social_ctx:+\n\nREFERENCE — registered social channel names (do NOT research these):\n${_social_ctx}}\n\nWhat is the SINGLE next logical milestone to advance the remaining objectives?"

        # ── Research→Delivery Gate ────────────────────────────
        # After 2+ consecutive research milestones, inject a hard
        # constraint forcing the strategist to use a delivery command.
        # This breaks the /web loop where the model endlessly searches
        # instead of producing output.
        local _research_gate=""
        if [ "$_research_milestone_count" -ge 2 ]; then
            _research_gate="

>>> RESEARCH PHASE FINISHED — you have done ${_research_milestone_count} consecutive research milestones. <<<
>>> Next milestone MUST use a DELIVERY command: /respond, /write, /email, /save, /social, /build. <<<
>>> Do NOT use /web or /recall. Deliver results using the data already gathered. <<<"
        fi

        local macro_sys="Strategic planning engine. Output the SINGLE next milestone. No markdown formatting (no ** or * markers). Plain text only.

${_tool_summary}

SERVICES STATUS: ${_svc_status:-unknown}

$(cat << 'STRAT_RULES_JSON'
{"rules":{
 "routing":{"named_tool":"use it — NEVER override with /ask",
   "/ask":"own knowledge only (may be stale — prefer /web for dates/events/scores)",
   "/social":"Discord/Telegram/X/Mastodon (NOT /email)",
   "/email":"actual email only","/sandbox":"NEVER for slash commands"},
 "milestones":{"source":"YOUR WORKING COMMANDS only",
   "format":"single imperative sentence starting with a verb (e.g. 'Use /write to create a summary')",
   "NEVER_raw_command":"Do NOT output a bare slash command as the milestone (WRONG: '/write a summary' — RIGHT: 'Use /write to create a summary')",
   "one_action":"1 milestone = 1 honeydew item, NEVER combine two items",
   "no_prefix":true,"no_intro":true,
   "only_configured":true},
 "research":{"when":"missing info (keys,URLs,packages,specs)",
   "tools":["/web search","/recall","/web fetch","/web scrape-images","/social discord read","/secret get"],
   "max_consecutive":2,"then":"MUST use delivery command (/respond,/write,/email,/save,/social,/build)"},
 "failure":{"no_repeat":true,"advance_next_part":true},
 "honeydew":{"pick":"FIRST [ ] item by number — do NOT skip items"},
 "multi_delivery":"Different honeydew items may each need their own DELIVERY command (e.g. item 2=/write report, item 3=/email report). This is normal — chain them across milestones.",
 "conversation":"question → use /ask"}}
STRAT_RULES_JSON
)${_research_gate}${_milestone_history}${_last_eval_feedback:+

>>> EVALUATOR FEEDBACK (from the last milestone — address this NOW) <<<
${_last_eval_feedback}
>>> You MUST address the above feedback in your next milestone. <<<}"

        ui_think "Strategist: determining next milestone..."
        local milestone
        # Use llm_generate (non-streaming) for the strategist. The output
        # is a brief milestone description displayed once by ui_info below.
        # Previously llm_stream showed it live, then ui_info showed it again,
        # then the specialist streamed it a third time — tripling the output.
        local LLM_SCENARIO=strategist
        milestone=$(llm_generate "$macro_prompt" "$macro_sys" "${LLM_STRATEGIST_TOKENS:-512}" "$LLM_BUDGET_AGENT")

        # ── MILESTONE CLEANUP ─────────────────────────────────
        # The strategist should output one imperative sentence, but
        # small models sometimes emit <think> blocks, code fences,
        # explanatory preamble, or repetitive content. Strip all of
        # that so the milestone is a clean, single-line action.
        # 1. Remove <think>...</think> and [THINK]...[/THINK] blocks (including multi-line)
        milestone=$(echo "$milestone" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
        milestone=$(echo "$milestone" | sed 's/\[THINK\][^[]*\[\/THINK\]//gI')
        milestone=$(echo "$milestone" | sed 's/\[THOUGHT\][^[]*\[\/THOUGHT\]//gI')
        # 1b. Remove UNCLOSED think blocks — when token limit truncates
        # before the closing tag, the entire think content leaks through.
        # Strip from opening tag to end of string.
        milestone=$(echo "$milestone" | sed ':a;N;$!ba;s/<think>.*$//g')
        milestone=$(echo "$milestone" | sed ':a;N;$!ba;s/\[THINK\].*$//gI')
        milestone=$(echo "$milestone" | sed ':a;N;$!ba;s/\[THOUGHT\].*$//gI')
        # 2. Remove stray opening/closing think tags (both formats, all case variants)
        milestone=$(echo "$milestone" | sed 's/<\/?think>//gI')
        milestone=$(echo "$milestone" | sed 's/\[\/?THINK\]//gI')
        milestone=$(echo "$milestone" | sed 's/\[\/?THOUGHT\]//gI')
        # 3. Remove code fences and their content
        milestone=$(echo "$milestone" | sed '/^```/,/^```/d')
        # 4. Strip leading/trailing whitespace and blank lines
        milestone=$(echo "$milestone" | sed '/^[[:space:]]*$/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        # 5. Take ONLY the first non-empty line (milestone = one sentence)
        milestone=$(echo "$milestone" | head -1)
        # 6. Strip markdown bold/italic markers (**, *, _) — prevents
        # formatting contamination when milestone text is re-injected
        # into specialist and evaluator prompts as micro_objective.
        milestone=$(echo "$milestone" | sed 's/\*\+//g')
        # 7. Strip leading slash-command prefix from milestone text.
        # Small models (Gemma, etc.) sometimes emit milestones that
        # look like raw slash commands: "/write a summary of the war".
        # The pre-route optimization then matches the "/write", skips
        # the router, and the specialist echoes it verbatim — causing
        # /write to parse "a" as filename and "summary..." as content.
        # Fix: convert "/write a summary" → "Use /write to a summary"
        # so the pre-route still works but the specialist sees a task
        # description, not a literal command to parrot.
        if [[ "$milestone" =~ ^/([a-z]+)[[:space:]]+(.*) ]]; then
            milestone="Use /${BASH_REMATCH[1]} to ${BASH_REMATCH[2]}"
        fi
        # 8. Synonym remap: /draft → /write (models love "draft")
        milestone="${milestone//\/draft /\/write }"
        milestone="${milestone//\/draft$/\/write}"
        # 9. Truncate to 200 chars max (prevents context bloat)
        milestone="${milestone:0:200}"

        # Transcript: log strategist milestone
        declare -f transcript_log &>/dev/null && transcript_log "strategist" "$milestone"

        # ── Check for completion ──────────────────────────────
        if [ -z "$milestone" ] || [[ "$milestone" == ERROR* ]]; then
            ui_err "Macro loop failed: ${milestone:-empty response}"
            break
        fi

        if [[ "$milestone" == DONE* ]]; then
            # ── HONEYDEW DONE GUARD ─────────────────────────────
            # Thinking models (Phi4) sometimes hallucinate DONE when
            # the honeydew list has pending items. If ANY items remain
            # pending, reject DONE and substitute the next pending item
            # as the milestone text. This prevents premature exit.
            local _done_guard_file="$george_dir/$HONEYDEW_FILE"
            if [ -f "$_done_guard_file" ]; then
                local _dg_pending _dg_next_task
                _dg_pending=$(jq '[.items[] | select(.status == "pending")] | length' "$_done_guard_file" 2>/dev/null || echo 0)
                if [ "$_dg_pending" -gt 0 ]; then
                    _dg_next_task=$(jq -r '[.items[] | select(.status == "pending")][0].task // empty' "$_done_guard_file" 2>/dev/null)
                    if [ -n "$_dg_next_task" ]; then
                        ui_warn "Strategist hallucinated DONE with $_dg_pending honeydew items pending — overriding"
                        milestone="$_dg_next_task"
                        _last_eval_feedback="Strategist tried to exit early. ${_dg_pending} honeydew items remain. Address them."
                    else
                        ui_ok "Strategist: Objective complete."
                        break
                    fi
                else
                    ui_ok "Strategist: Objective complete."
                    break
                fi
            else
                ui_ok "Strategist: Objective complete."
                break
            fi
        fi

        # ── MILESTONE DEDUPLICATION CHECK ─────────────────────
        # If the strategist generated a milestone substantially similar
        # to one that already failed, detect it and either force the
        # strategist to try a different approach or skip ahead.
        #
        # Similarity detection uses THREE strategies:
        #   1) First 40 chars match (catches rephrased duplicates)
        #   2) Same primary slash command + first argument extracted
        #      (catches "/social discord dm dabe" vs "Send a DM to dabe via /social discord dm")
        #   3) Command-family cap — if 3+ milestones used the same base
        #      command (e.g. /web), force a different approach even if
        #      the arguments differ ("/web search X" vs "/web search Y").
        local _milestone_lower
        _milestone_lower=$(echo "$milestone" | tr '[:upper:]' '[:lower:]')
        # Extract slash command signature: e.g. "/social discord dm dabe" → "social discord dm dabe"
        local _milestone_slash=""
        if [[ "$_milestone_lower" =~ /([a-z]+[[:space:]]+[a-z].*) ]]; then
            _milestone_slash=$(echo "${BASH_REMATCH[1]}" | sed 's/[[:space:]]\+/ /g' | cut -d' ' -f1-4)
        fi
        local _dup_count=0
        local _last_milestone_text=""
        for _prev in "${_attempted_milestones[@]}"; do
            local _prev_text _prev_lower _prev_slash
            _prev_text="${_prev#*|}"  # strip "FAILED|" or "OK|" prefix
            _prev_lower=$(echo "$_prev_text" | tr '[:upper:]' '[:lower:]')
            # Strategy 1: first 40 chars match
            if [ "${_milestone_lower:0:40}" = "${_prev_lower:0:40}" ]; then
                _dup_count=$((_dup_count + 1))
            # Strategy 2: same slash command signature
            elif [ -n "$_milestone_slash" ]; then
                _prev_slash=""
                if [[ "$_prev_lower" =~ /([a-z]+[[:space:]]+[a-z].*) ]]; then
                    _prev_slash=$(echo "${BASH_REMATCH[1]}" | sed 's/[[:space:]]\+/ /g' | cut -d' ' -f1-4)
                fi
                if [ -n "$_prev_slash" ] && [ "$_milestone_slash" = "$_prev_slash" ]; then
                    _dup_count=$((_dup_count + 1))
                fi
            fi
            _last_milestone_text="$_prev_text"
        done

        # Strategy 3: Command-family cap — count all milestones
        # sharing the same base command regardless of arguments.
        if [ -n "$_milestone_slash" ] && [ "$_dup_count" -eq 0 ]; then
            local _ms_base_cmd _family_count=0
            _ms_base_cmd=$(echo "$_milestone_slash" | cut -d' ' -f1)
            for _prev in "${_attempted_milestones[@]}"; do
                local _prev_text_fam _prev_lower_fam _prev_base=""
                _prev_text_fam="${_prev#*|}"
                _prev_lower_fam=$(echo "$_prev_text_fam" | tr '[:upper:]' '[:lower:]')
                if [[ "$_prev_lower_fam" =~ /([a-z]+) ]]; then
                    _prev_base="${BASH_REMATCH[1]}"
                fi
                [ "$_prev_base" = "$_ms_base_cmd" ] && _family_count=$((_family_count + 1))
            done
            if [ "$_family_count" -ge "${AGENT_MAX_CMD_FAMILY:-3}" ]; then
                _dup_count=$((${AGENT_MAX_MILESTONE_RETRIES:-2}))
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] command-family cap: $_family_count milestones used /$_ms_base_cmd — forcing progression"
            fi
        fi

        # Exact-repeat guard: if the strategist output is identical to the
        # very last milestone (even on first attempt), it's stuck in a loop.
        # Immediately set feedback and force a different approach.
        if [ -n "$_last_milestone_text" ]; then
            local _last_lower
            _last_lower=$(echo "$_last_milestone_text" | tr '[:upper:]' '[:lower:]')
            if [ "$_milestone_lower" = "$_last_lower" ]; then
                _dup_count=$((${AGENT_MAX_MILESTONE_RETRIES:-2}))
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] exact repeat of last milestone — forcing progression"
            fi
        fi
        if [ "$_dup_count" -ge "${AGENT_MAX_MILESTONE_RETRIES:-2}" ]; then
            ui_warn "Milestone '$milestone' already attempted $_dup_count times — forcing progression"
            _macro_add_milestone "$macro_file" "$milestone" "Skipped (duplicate of failed milestone)" "" "UNKNOWN" "SKIPPED"
            _attempted_milestones+=("SKIPPED|$milestone")
            macro_iterations=$((macro_iterations + 1))
            _exec_log="${_exec_log}Milestone $macro_iterations: ${milestone:0:60} — SKIPPED (dup)\n"
            _last_eval_feedback="Milestone '${milestone:0:80}' was skipped (repeated). Try a completely different approach to advance the task."

            # Run overall evaluator before skipping — earlier milestones
            # may have already fulfilled the objective. Without this check,
            # the `continue` below would jump past the dual evaluator block
            # and the loop would keep generating (and skipping) milestones
            # for a task that's already done.
            if [ "${AGENT_EVAL_MODE:-auto}" != "disabled" ] && [ "$completed_milestones" -gt 0 ]; then
                if _agent_evaluate_completion "$macro_file" "$george_dir/micro_memory.json"; then
                    _last_eval_feedback=""
                    break
                else
                    if [ -n "${_EVAL_INCOMPLETE_REASON:-}" ]; then
                        _last_eval_feedback="Milestone skipped (repeated). Still needed: ${_EVAL_INCOMPLETE_REASON}"
                    fi
                fi
            fi

            sleep "${AGENT_STEP_DELAY:-1}"
            continue
        fi

        # ── Execute milestone via Micro Loop ──────────────────
        macro_iterations=$((macro_iterations + 1))
        echo ""
        ui_section "Milestone $macro_iterations"
        ui_info "$milestone"

        if agent_inner_loop "$milestone" "$workdir"; then
            completed_milestones=$((completed_milestones + 1))
            _exec_log="${_exec_log}Milestone $macro_iterations: ${milestone:0:60} — OK\n"
            _attempted_milestones+=("OK|$milestone")

            # ── Track research vs delivery milestones ─────────
            local _ms_lower_track
            _ms_lower_track=$(echo "$milestone" | tr '[:upper:]' '[:lower:]')
            if [[ "$_ms_lower_track" =~ (/web |/recall |search|fetch|lookup|research) ]]; then
                _research_milestone_count=$((_research_milestone_count + 1))
            else
                _research_milestone_count=0  # reset on delivery milestone
            fi

            # JSON uses empty array for milestones — no placeholder to remove
            if false; then
                : # removed: sed placeholder cleanup (JSON has no "(none yet)")
            fi

            # ── Update GEORGE.md with milestone progress ──────
            # Keeps project memory in sync so /build, /test, and future
            # tasks can see what steps have been completed.
            if declare -f memory_update_section &>/dev/null; then
                memory_update_section "Active Task" "$task (milestone $completed_milestones complete)" "$workdir" 2>/dev/null
                # Append to Completed Milestones (avoid overwriting previous milestones)
                local _george_file="$workdir/GEORGE.md"
                if [ -f "$_george_file" ]; then
                    local _step_line="- [$(date '+%H:%M')] $milestone"
                    local _current_steps
                    _current_steps=$(awk '/^## Completed Milestones/{getline; p=1} /^## /{if(p)exit} p' "$_george_file" 2>/dev/null)
                    if [ "$_current_steps" = "(none)" ] || [ -z "$_current_steps" ]; then
                        memory_update_section "Completed Milestones" "$_step_line" "$workdir" 2>/dev/null
                    else
                        memory_update_section "Completed Milestones" "${_current_steps}\n${_step_line}" "$workdir" 2>/dev/null
                    fi
                fi
            fi

            # ── Honeydew + Overall Evaluation Chain ─────────────
            # The milestone P1 eval already ran INSIDE agent_inner_loop.
            # If we're here with success, the milestone is confirmed.
            # Now evaluate honeydew item completion (if honeydew exists),
            # then overall task completion.
            #
            # Chain:
            #   1. Honeydew eval: Does this milestone satisfy the
            #      current honeydew item?
            #      - NO  → feedback to strategist, continue loop
            #      - YES → mark item done, proceed to step 2
            #   2. Overall eval (P2): Are ALL honeydew items done?
            #      - NO  → feedback with remaining honeydew, continue
            #      - YES → task complete, break
            #
            # When no honeydew list exists, skip straight to P2.
            if [ "${AGENT_EVAL_MODE:-auto}" != "disabled" ] && [ "$completed_milestones" -gt 0 ]; then
                local _hd_eval_file="$george_dir/$HONEYDEW_FILE"
                if [ -f "$_hd_eval_file" ]; then
                    # ── Honeydew item evaluation ──────────────
                    if _agent_evaluate_honeydew_item "$macro_file" "$george_dir/micro_memory.json" "$milestone" "$workdir"; then
                        # Honeydew item satisfied — mark it done
                        if [ -n "${_EVAL_HONEYDEW_ITEM_NUM:-}" ]; then
                            _agent_honeydew_mark "$_EVAL_HONEYDEW_ITEM_NUM" "$workdir"
                            local _hd_status
                            _hd_status=$(_agent_honeydew_status "$workdir" 2>/dev/null)
                            [ -n "$_hd_status" ] && ui_dim "  Honeydew: $_hd_status"
                            # Refresh honeydew in macro_memory
                            local _hd_updated
                            _hd_updated=$(_agent_honeydew_read "$workdir" 2>/dev/null)
                            if [ -n "$_hd_updated" ] && [ -f "$macro_file" ]; then
                                _macro_set_honeydew "$macro_file" "$_hd_updated"
                            fi
                        fi

                        # ── Overall evaluation (P2) ───────────
                        if _agent_evaluate_completion "$macro_file" "$george_dir/micro_memory.json"; then
                            _last_eval_feedback=""
                            break
                        else
                            if [ -n "${_EVAL_INCOMPLETE_REASON:-}" ]; then
                                _attempted_milestones+=("EVAL|honeydew remaining: $_EVAL_INCOMPLETE_REASON")
                                _last_eval_feedback="Honeydew item addressed. Remaining work: ${_EVAL_INCOMPLETE_REASON}"
                                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] eval feedback -> strategist: ${_last_eval_feedback:0:100}"
                            else
                                _last_eval_feedback="Honeydew item addressed. More items remain on the honeydew list."
                            fi
                        fi
                    else
                        # Honeydew item NOT satisfied — milestone
                        # succeeded but didn't address the current
                        # honeydew item. Feed back to strategist.
                        if [ -n "${_EVAL_HONEYDEW_REASON:-}" ]; then
                            _attempted_milestones+=("EVAL|honeydew item unsatisfied: $_EVAL_HONEYDEW_REASON")
                            _last_eval_feedback="Milestone '${milestone:0:80}' ran, but honeydew item #${_EVAL_HONEYDEW_ITEM_NUM:-?} is NOT addressed: ${_EVAL_HONEYDEW_REASON}. Next milestone must address it."
                            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] eval feedback -> strategist: ${_last_eval_feedback:0:100}"
                        else
                            _last_eval_feedback="Milestone '${milestone:0:80}' ran, but the current honeydew item is NOT addressed. Try a different approach."
                        fi
                    fi
                else
                    # ── No honeydew list — P2 only ────────────
                    if _agent_evaluate_completion "$macro_file" "$george_dir/micro_memory.json"; then
                        _last_eval_feedback=""
                        break
                    else
                        if [ -n "${_EVAL_INCOMPLETE_REASON:-}" ]; then
                            _attempted_milestones+=("EVAL|still missing: $_EVAL_INCOMPLETE_REASON")
                            _last_eval_feedback="Milestone '${milestone:0:80}' ran, but more work needed. Still missing: ${_EVAL_INCOMPLETE_REASON}"
                            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] eval feedback -> strategist: ${_last_eval_feedback:0:100}"
                        else
                            _last_eval_feedback="Milestone '${milestone:0:80}' ran, but more work is needed."
                        fi
                    fi
                fi
            fi

        else
            failed_milestones="${failed_milestones:+${failed_milestones}, }milestone $macro_iterations: $milestone"
            _exec_log="${_exec_log}Milestone $macro_iterations: ${milestone:0:60} — FAILED\n"
            _attempted_milestones+=("FAILED|$milestone")

            # Check if failure was due to cancellation or operator abort
            if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
                ui_warn "Milestone $macro_iterations cancelled"
                break
            fi

            # Milestone failed — feed back to strategist
            _last_eval_feedback="Milestone '${milestone:0:80}' did not work. Try a different approach."
        fi

        sleep "${AGENT_STEP_DELAY:-1}"
    done

    # ── Task complete ─────────────────────────────────────────
    # Capture cancellation state BEFORE resetting — needed to skip
    # post-task journal reflection (which triggers a model switch to
    # the secondary model and can crash Termux if Ollama is still
    # recovering from the killed curl requests).
    local _was_cancelled=0
    if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
        _was_cancelled=1
    fi
    _LODGE_IN_TASK=0
    _LODGE_CANCELLED=0

    echo ""
    ui_divider
    if [ "$_was_cancelled" -eq 1 ]; then
        ui_warn "Task cancelled ($completed_milestones/$macro_iterations milestones completed before cancellation)"
    elif [ "$macro_iterations" -eq 0 ]; then
        ui_ok "Task complete: objective resolved without milestones"
    else
        ui_ok "Task complete: $completed_milestones/$macro_iterations milestones succeeded"
    fi

    # Print debug summary (timers + token totals) if enabled
    declare -f llm_debug_summary &>/dev/null && llm_debug_summary

    # ── Stop transcript logging ───────────────────────────────
    if declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null; then
        local _transcript_path
        _transcript_path=$(transcript_stop)
        [ -n "$_transcript_path" ] && ui_dim "  Transcript: $_transcript_path"
    fi

    # Reflect in journal (background — don't block user)
    # SKIP if task was cancelled — journal_reflect triggers a model switch
    # to the secondary model (LLM_SCENARIO=journal → LODGE_MODEL_SECONDARY).
    # After Ctrl+C, Ollama may still be cleaning up killed requests; issuing
    # a model unload+load at that moment races with the cleanup and can crash
    # Termux. The cancelled task will be visible in macro_memory.json anyway.
    if [ "$_was_cancelled" -eq 0 ]; then
        # ── Update GEORGE.md with task completion ─────────────
        # Mark the task as done (or cancelled) so the next task or
        # interactive session sees what was accomplished.
        if declare -f memory_update_section &>/dev/null; then
            memory_update_section "Active Task" "(none — last task: ${task:0:80})" "$workdir" 2>/dev/null
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] GEORGE.md updated: task complete"
        fi

        # ── Single journal entry (reflect only) ───────────────
        # Previously wrote TWO entries: a factual summary + a personality
        # reflection. Now merged into one journal_reflect call (which
        # already summarizes the exec_log). Saves one LLM call (~10s).
        local reflect_summary="$task ($completed_milestones/$macro_iterations milestones in $(basename "$workdir"))"
        if [ -n "$failed_milestones" ]; then
            reflect_summary="${reflect_summary}. Failed: ${failed_milestones}"
        fi
        journal_reflect "$reflect_summary" "$workdir" "$_exec_log" &
        disown 2>/dev/null

        # Notify on phone if available
        tools_phone_toast "Lodge: Task complete ($completed_milestones/$macro_iterations milestones)"
    fi

    # Model stays loaded during active session for fast response times.
    # It will be unloaded on session exit (lodge main) or by keep_alive timeout.

    return 0
}

# ── Conversation history (ring buffer for /ask continuity) ─────
# Stores last N exchanges so George remembers recent conversation.
# Each entry: "USER: ...\nGEORGE: ..."
_AGENT_CONV_HISTORY=()
AGENT_CONV_MAX="${AGENT_CONV_MAX:-3}"  # Keep last 3 exchanges (~300-600 tokens)

_agent_conv_push() {
    local user_msg="$1"
    local george_msg="$2"
    # Truncate long responses to ~150 chars to stay token-lean
    local trunc_response="${george_msg:0:150}"
    [ ${#george_msg} -gt 150 ] && trunc_response="${trunc_response}..."
    _AGENT_CONV_HISTORY+=("USER: $user_msg
GEORGE: $trunc_response")
    # Trim to max size
    while [ ${#_AGENT_CONV_HISTORY[@]} -gt "$AGENT_CONV_MAX" ]; do
        _AGENT_CONV_HISTORY=("${_AGENT_CONV_HISTORY[@]:1}")
    done
}

_agent_conv_context() {
    if [ ${#_AGENT_CONV_HISTORY[@]} -eq 0 ]; then
        echo ""
        return
    fi
    local ctx="--- RECENT CONVERSATION ---"
    for entry in "${_AGENT_CONV_HISTORY[@]}"; do
        ctx="$ctx
$entry"
    done
    echo "$ctx"
}

# ── Single-shot ask (no planning, just answer) ────────────────
agent_ask() {
    local question="$1"
    local workdir="${2:-.}"
    
    _LODGE_IN_TASK=1
    _LODGE_CANCELLED=0
    
    # Use lean prompt — keeps system context under ~800 tokens
    local system_prompt
    system_prompt=$(memory_build_system_prompt "$workdir" "$question" "ask")
    
    # Inject conversation history for continuity
    local conv_ctx
    conv_ctx=$(_agent_conv_context)
    
    local full_question="$question"
    if [ -n "$conv_ctx" ]; then
        full_question="$conv_ctx

$question"
    fi
    
    # Stream the response so user sees tokens arrive in real-time
    echo ""
    local response
    local LLM_SCENARIO=ask
    response=$(llm_stream "$full_question" "$system_prompt" "$LLM_ASK_TOKENS" "$LLM_BUDGET_ASK")
    echo ""
    
    # Transcript: log the ask response
    declare -f transcript_log_block &>/dev/null && transcript_log_block "llm-response (ask)" "$response"

    # Track this exchange for future context
    [ -n "$response" ] && [[ "$response" != ERROR* ]] && _agent_conv_push "$question" "$response"
    
    _LODGE_IN_TASK=0
    
    if [ "${_LODGE_CANCELLED:-0}" -eq 1 ]; then
        _LODGE_CANCELLED=0
        return 1
    fi
    
    if [[ "$response" == ERROR* ]]; then
        ui_err "$response"
        return 1
    fi
    
    # Emit response to stdout so the agent inner loop's
    # output=$(commands_dispatch ...) captures it into the action log.
    # In interactive mode llm_stream already displayed tokens to /dev/tty,
    # so only echo when stdout is NOT a terminal (i.e., captured by $()).
    if ! [ -t 1 ]; then
        echo "$response"
    fi

    # Journal the exchange — George writes a witty one-liner for posterity
    # Runs in background so user isn't blocked
    if declare -f journal_write_quip &>/dev/null; then
        journal_write_quip "$question" "$response" &
    fi
    
    # Model stays loaded during active session for fast response times.
}

# ── Interactive step-by-step mode ──────────────────────────────
agent_step_mode() {
    local task="$1"
    local workdir="${2:-.}"
    
    local plan
    plan=$(agent_plan "$task" "$workdir")
    if [ $? -ne 0 ]; then return 1; fi
    
    ui_section "Plan"
    echo "$plan"
    echo ""
    
    # Normalize inline plans before parsing
    plan=$(_agent_split_inline_steps "$plan")
    local -a steps=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9]+[\.\)] ]]; then
            steps+=("$(echo "$line" | sed 's/^[0-9]*[.)[:space:]]*//')")
        fi
    done <<< "$plan"
    
    for i in "${!steps[@]}"; do
        local step_num=$((i + 1))
        echo ""
        ui_info "Next: Step $step_num — ${steps[$i]}"
        if ui_confirm "Execute this step?"; then
            agent_inner_loop "${steps[$i]}" "$workdir"
        else
            ui_warn "Skipped step $step_num"
            memory_append_section "Completed Milestones" "Step $step_num: SKIPPED — ${steps[$i]}" "$workdir"
        fi
    done
}
