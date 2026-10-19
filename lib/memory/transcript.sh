#!/bin/bash
# ── George: Task Transcript Logging ────────────────────────
# Captures everything displayed to TTY and agent output into
# a timestamped markdown file for post-task review.
#
# Zero overhead when inactive: every function gates on a single
# empty-string check before doing any work.
#
# Usage (automatic — wired into agent_run):
#   transcript_start "task description" "/path/to/workdir"
#   ... task executes, ui_* and agent hooks log entries ...
#   transcript_stop
#
# Manual review:
#   /transcript list     — show recent transcripts
#   /transcript last     — open the most recent one
#   /transcript path     — print path to active transcript

# ── State ──────────────────────────────────────────────────────
[ -n "${_LIB_TRANSCRIPT_LOADED:-}" ] && return 0; _LIB_TRANSCRIPT_LOADED=1

_TRANSCRIPT_FILE=""
_TRANSCRIPT_DIR=""
_TRANSCRIPT_START_TS=""
_PROMPT_LOG_FILE=""

# ── Start a new transcript ─────────────────────────────────────
# Creates a timestamped .md file and writes the header.
transcript_start() {
    local task="$1"
    local workdir="${2:-.}"

    _TRANSCRIPT_DIR="${workdir}/.george/transcripts"
    mkdir -p "$_TRANSCRIPT_DIR"

    local ts
    ts=$(date '+%Y-%m-%d_%H-%M-%S')
    _TRANSCRIPT_FILE="$_TRANSCRIPT_DIR/${ts}.md"
    # Avoid filename collisions when multiple transcripts start in the same second
    if [ -f "$_TRANSCRIPT_FILE" ]; then
        local _sfx=2
        while [ -f "$_TRANSCRIPT_DIR/${ts}_${_sfx}.md" ]; do
            _sfx=$((_sfx + 1))
        done
        _TRANSCRIPT_FILE="$_TRANSCRIPT_DIR/${ts}_${_sfx}.md"
    fi
    _TRANSCRIPT_START_TS=$(date '+%s')
    _PROMPT_LOG_FILE="${_TRANSCRIPT_FILE%.md}_prompts.md"
    export _TRANSCRIPT_DIR
    export _TRANSCRIPT_FILE
    export _PROMPT_LOG_FILE
    export _TRANSCRIPT_START_TS
 
    {
        echo "# Task Transcript"
        echo ""
        echo "**Task:** $task"
        echo "**Started:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "**Directory:** $workdir"
        echo "**Model:** ${LODGE_MODEL:-unknown}"
        echo "**Backend:** ${LLM_BACKEND:-auto}"
        echo "**Prompts Log:** [$(basename "$_PROMPT_LOG_FILE")](file://$_PROMPT_LOG_FILE)"
        echo ""
        echo "---"
        echo ""
    } > "$_TRANSCRIPT_FILE"
 
    {
        echo "# Task Prompts Log"
        echo ""
        echo "**Task:** $task"
        echo "**Started:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "**Directory:** $workdir"
        echo "**Model:** ${LODGE_MODEL:-unknown}"
        echo "**Backend:** ${LLM_BACKEND:-auto}"
        echo "**Main Transcript:** [$(basename "$_TRANSCRIPT_FILE")](file://$_TRANSCRIPT_FILE)"
        echo ""
        echo "---"
        echo ""
    } > "$_PROMPT_LOG_FILE"
}

# ── Core logging functions ─────────────────────────────────────

# Log a single-line entry with a tag and timestamp.
# Usage: transcript_log "tag" "message"
transcript_log() {
    [ -z "$_TRANSCRIPT_FILE" ] && return
    local tag="$1"
    local msg="$2"

    # Route transport-level MQTT chatter and low-level MCP debug to dedicated mqtt.log
    if [[ "$tag" == "mcp" || "$tag" == "dim" ]]; then
        if [[ "$msg" == *"george-mqtt"* || "$msg" == *"mqtt_publish"* || "$msg" == *"mqtt_status"* || "$msg" == *"mqtt_subscribe"* ]]; then
            local _mqtt_log="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-$HOME/blue-lodge}/.george}/mqtt.log"
            mkdir -p "$(dirname "$_mqtt_log")" 2>/dev/null || true
            local ts
            ts=$(date '+%H:%M:%S')
            msg=$(printf '%s' "$msg" | sed 's/\x1b\[[0-9;]*m//g')
            printf '`%s` **%s:** %s\n' "$ts" "$tag" "$msg" >> "$_mqtt_log" 2>/dev/null || true
            return
        fi
    fi

    local ts
    ts=$(date '+%H:%M:%S')
    # Strip ANSI escape codes
    msg=$(printf '%s' "$msg" | sed 's/\x1b\[[0-9;]*m//g')
    mkdir -p "$(dirname "$_TRANSCRIPT_FILE")" 2>/dev/null || true
    printf '`%s` **%s:** %s\n' "$ts" "$tag" "$msg" >> "$_TRANSCRIPT_FILE" 2>/dev/null || true
}

# Log a multi-line block (command output, LLM responses, etc.)
# Usage: transcript_log_block "tag" "content"
transcript_log_block() {
    [ -z "$_TRANSCRIPT_FILE" ] && return
    local tag="$1"
    local content="$2"
    local ts
    ts=$(date '+%H:%M:%S')
    # Strip ANSI escape codes
    content=$(printf '%s' "$content" | sed 's/\x1b\[[0-9;]*m//g')
    mkdir -p "$(dirname "$_TRANSCRIPT_FILE")" 2>/dev/null || true
    {
        printf '\n`%s` **%s:**\n' "$ts" "$tag"
        printf '```\n%s\n```\n\n' "$content"
    } >> "$_TRANSCRIPT_FILE" 2>/dev/null || true
}

# Log an expandable details block
# Usage: transcript_log_details "Summary Title" "Content" [language]
transcript_log_details() {
    [ -z "$_TRANSCRIPT_FILE" ] && return
    local summary_title="$1"
    local content="$2"
    local lang="${3:-markdown}"
    local ts
    ts=$(date '+%H:%M:%S')
    content=$(printf '%s' "$content" | sed 's/\x1b\[[0-9;]*m//g')
    mkdir -p "$(dirname "$_TRANSCRIPT_FILE")" 2>/dev/null || true
    {
        printf '\n<details>\n'
        printf '<summary>`%s` %s</summary>\n\n' "$ts" "$summary_title"
        printf '```%s\n%s\n```\n\n' "$lang" "$content"
        printf '</details>\n\n'
    } >> "$_TRANSCRIPT_FILE" 2>/dev/null || true
}

# Log a collapsible tool execution card with arguments, observation, status, and metrics
# Usage: transcript_log_tool_call "tool_name" "call_id" "args_json" "resp_content" [exit_code] [duration_ms] [size_bytes]
transcript_log_tool_call() {
    [ -z "$_TRANSCRIPT_FILE" ] && return
    local tool="$1"
    local call_id="$2"
    local args="$3"
    local content="$4"
    local ec="${5:-0}"
    local dur="${6:-0}"
    local bytes="${7:-${#content}}"
    local ts
    ts=$(date '+%H:%M:%S')

    # Strip ANSI escape codes
    args=$(printf '%s' "$args" | sed 's/\x1b\[[0-9;]*m//g')
    content=$(printf '%s' "$content" | sed 's/\x1b\[[0-9;]*m//g')

    local status_badge="<span style=\"color:#2ecc71;\">SUCCESS</span>"
    if [ "$ec" -eq 124 ]; then
        status_badge="<span style=\"color:#e67e22;\">TIMEOUT (124)</span>"
    elif [ "$ec" -ne 0 ]; then
        status_badge="<span style=\"color:#e74c3c;\">FAILED (exit $ec)</span>"
    fi

    local dur_str=""
    [ "$dur" -gt 0 ] && dur_str="${dur}ms"

    local size_str=""
    if [ "$bytes" -ge 1048576 ]; then
        size_str="$(awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}")"
    elif [ "$bytes" -ge 1024 ]; then
        size_str="$(awk "BEGIN {printf \"%.1f KB\", $bytes/1024}")"
    else
        size_str="${bytes} B"
    fi

    local meta_parts=()
    [ -n "$dur_str" ] && meta_parts+=("$dur_str")
    [ -n "$size_str" ] && meta_parts+=("$size_str")
    local meta_summary=""
    [ ${#meta_parts[@]} -gt 0 ] && meta_summary="($(IFS=', '; echo "${meta_parts[*]}"))"

    mkdir -p "$(dirname "$_TRANSCRIPT_FILE")" 2>/dev/null || true
    {
        printf '\n<details>\n'
        printf '<summary>`%s` ⚡ <b>Tool Execution:</b> <code>%s</code> — %b %s</summary>\n\n' "$ts" "$tool" "$status_badge" "$meta_summary"
        printf '**Call ID:** `%s`\n\n' "$call_id"
        if [ -n "$args" ] && [ "$args" != "{}" ]; then
            printf '**Arguments:**\n```json\n%s\n```\n\n' "$args"
        fi
        printf '**Observation:**\n```markdown\n%s\n```\n\n' "$content"
        printf '</details>\n\n'
    } >> "$_TRANSCRIPT_FILE" 2>/dev/null || true
}

# Log a section divider (milestone boundaries, phase changes)
# Usage: transcript_section "Milestone 2"
transcript_section() {
    [ -z "$_TRANSCRIPT_FILE" ] && return
    local title="$1"
    local ts
    ts=$(date '+%H:%M:%S')
    mkdir -p "$(dirname "$_TRANSCRIPT_FILE")" 2>/dev/null || true
    printf '\n---\n\n### %s  `%s`\n\n' "$title" "$ts" >> "$_TRANSCRIPT_FILE" 2>/dev/null || true
}

# ── UI hook ────────────────────────────────────────────────────
# Called from each ui_* function. Maps ui function names to tags.
# Overhead when inactive: one empty-string test (~0 ns).
_transcript_ui() {
    [ -z "$_TRANSCRIPT_FILE" ] && return
    local tag="$1"
    local msg="$2"
    transcript_log "$tag" "$msg"
}

# ── Stop the active transcript ─────────────────────────────────
# Writes the footer and returns the file path.
transcript_stop() {
    [ -z "$_TRANSCRIPT_FILE" ] && return

    local end_ts
    end_ts=$(date '+%s')
    local duration=""
    if [ -n "$_TRANSCRIPT_START_TS" ]; then
        local elapsed=$(( end_ts - _TRANSCRIPT_START_TS ))
        local mins=$(( elapsed / 60 ))
        local secs=$(( elapsed % 60 ))
        if [ "$mins" -gt 0 ]; then
            duration="${mins}m ${secs}s"
        else
            duration="${secs}s"
        fi
    fi

    mkdir -p "$(dirname "$_TRANSCRIPT_FILE")" 2>/dev/null || true
    {
        echo ""
        echo "---"
        echo ""
        echo "**Ended:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
        [ -n "$duration" ] && echo "**Duration:** $duration"
    } >> "$_TRANSCRIPT_FILE" 2>/dev/null || true
 
    if [ -n "$_PROMPT_LOG_FILE" ] && [ -f "$_PROMPT_LOG_FILE" ]; then
        mkdir -p "$(dirname "$_PROMPT_LOG_FILE")" 2>/dev/null || true
        {
            echo ""
            echo "---"
            echo ""
            echo "**Ended:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
            [ -n "$duration" ] && echo "**Duration:** $duration"
        } >> "$_PROMPT_LOG_FILE" 2>/dev/null || true
    fi
 
    local saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""
    _PROMPT_LOG_FILE=""
    _TRANSCRIPT_START_TS=""
    echo "$saved"
}

# ── Query functions ────────────────────────────────────────────

# Is a transcript currently active?
transcript_active() {
    [ -n "$_TRANSCRIPT_FILE" ]
}

# Return path to active transcript (empty if none).
transcript_path() {
    echo "$_TRANSCRIPT_FILE"
}

# List recent transcripts (most recent first).
# Usage: transcript_list [workdir] [limit]
transcript_list() {
    local workdir="${1:-.}"
    local limit="${2:-10}"
    local dir="$workdir/.george/transcripts"

    if [ ! -d "$dir" ]; then
        echo "(no transcripts)"
        return
    fi

    local count=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        local fname
        fname=$(basename "$f" .md)
        local task_line
        task_line=$(sed -n 's/^\*\*Task:\*\* //p' "$f" | head -1)
        local duration_line
        duration_line=$(sed -n 's/^\*\*Duration:\*\* //p' "$f" | head -1)
        # Format: date_time — task (duration)
        local display_ts
        display_ts=$(echo "$fname" | sed 's/_/ /g; s/-/:/4; s/-/:/4')
        printf "  %s — %s" "$display_ts" "${task_line:-(untitled)}"
        [ -n "$duration_line" ] && printf " (%s)" "$duration_line"
        printf "\n"
        count=$((count + 1))
        [ "$count" -ge "$limit" ] && break
    done <<< "$(ls -1t "$dir"/*.md 2>/dev/null)"

    [ "$count" -eq 0 ] && echo "(no transcripts)"
}

# Log an injected prompt with its role/type.
# Usage: transcript_log_prompt "role" "prompt" "system"
transcript_log_prompt() {
    [ -z "$_PROMPT_LOG_FILE" ] && return
    local role="$1"
    local prompt="$2"
    local system="${3:-}"
    local ts
    ts=$(date '+%H:%M:%S')
    mkdir -p "$(dirname "$_PROMPT_LOG_FILE")" 2>/dev/null || true
    {
        printf '\n`%s` **prompt-injection (%s):**\n' "$ts" "$role"
        if [ -n "$system" ]; then
            printf '<details>\n<summary>System Prompt</summary>\n\n```\n%s\n```\n\n</details>\n' "$system"
        fi
        printf '<details>\n<summary>User Prompt</summary>\n\n```\n%s\n```\n\n</details>\n' "$prompt"
    } >> "$_PROMPT_LOG_FILE" 2>/dev/null || true
}
typeset -xf transcript_log_prompt
typeset -xf transcript_log_details 2>/dev/null || true
typeset -xf transcript_log_tool_call 2>/dev/null || true

# Return the path to the most recent transcript.
transcript_last() {
    local workdir="${1:-.}"
    local dir="$workdir/.george/transcripts"
    ls -1t "$dir"/*.md 2>/dev/null | head -1
}

# ── UI integration overrides (loaded after lib/ui/ui.sh and lib/core/agent_helpers.sh) ─
# Keep agent core untouched: when available, route limitation rendering
# through standardized UI blocks and concise enum-only prompt text.
if declare -f ui_limitation_block &>/dev/null; then
    _agent_emit_limitation_block() {
        local constraint="$1" tried="$2" choices="$3" outcome="$4"
        local episode_key="${constraint}|${outcome}"
        ui_limitation_block "$constraint" "$tried" "$choices" "$outcome" "$episode_key"
    }
fi

_agent_limitation_prompt_text() {
    local reason_code="$1"
    printf 'Constraint (%s). Choose one: RESCOPE | ALT_PATH | TERMINATE. Reply with one token.' "$reason_code"
}

# ── Fine-Tuning JSONL Telemetry ──────────────────────────────────────
transcript_log_jsonl() {
    local instruction="$1"
    local thinking="$2"
    local action="$3"
    local observation="$4"
    local tdir="${_TRANSCRIPT_DIR:-${LODGE_DIR:-.}/.george/transcripts}"
    local jsonl_file="$tdir/trajectories.jsonl"
    mkdir -p "$tdir" 2>/dev/null || true

    jq -c -n \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")" \
        --arg inst "$instruction" \
        --arg think "$thinking" \
        --arg act "$action" \
        --arg obs "$observation" \
        '{
            timestamp: $ts,
            instruction: $inst,
            thinking: $think,
            action: $act,
            observation: $obs
        }' >> "$jsonl_file" 2>/dev/null || true
}

