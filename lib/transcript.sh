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
    _TRANSCRIPT_START_TS=$(date '+%s')

    {
        echo "# Task Transcript"
        echo ""
        echo "**Task:** $task"
        echo "**Started:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "**Directory:** $workdir"
        echo "**Model:** ${LODGE_MODEL:-unknown}"
        echo "**Backend:** ${LLM_BACKEND:-auto}"
        echo ""
        echo "---"
        echo ""
    } > "$_TRANSCRIPT_FILE"
}

# ── Core logging functions ─────────────────────────────────────

# Log a single-line entry with a tag and timestamp.
# Usage: transcript_log "tag" "message"
transcript_log() {
    [ -z "$_TRANSCRIPT_FILE" ] && return
    local tag="$1"
    local msg="$2"
    local ts
    ts=$(date '+%H:%M:%S')
    # Strip ANSI escape codes
    msg=$(printf '%s' "$msg" | sed 's/\x1b\[[0-9;]*m//g')
    printf '`%s` **%s:** %s\n' "$ts" "$tag" "$msg" >> "$_TRANSCRIPT_FILE"
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
    {
        printf '\n`%s` **%s:**\n' "$ts" "$tag"
        printf '```\n%s\n```\n\n' "$content"
    } >> "$_TRANSCRIPT_FILE"
}

# Log a section divider (milestone boundaries, phase changes)
# Usage: transcript_section "Milestone 2"
transcript_section() {
    [ -z "$_TRANSCRIPT_FILE" ] && return
    local title="$1"
    local ts
    ts=$(date '+%H:%M:%S')
    printf '\n---\n\n### %s  `%s`\n\n' "$title" "$ts" >> "$_TRANSCRIPT_FILE"
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

    {
        echo ""
        echo "---"
        echo ""
        echo "**Ended:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
        [ -n "$duration" ] && echo "**Duration:** $duration"
    } >> "$_TRANSCRIPT_FILE"

    local saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""
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

# Return the path to the most recent transcript.
transcript_last() {
    local workdir="${1:-.}"
    local dir="$workdir/.george/transcripts"
    ls -1t "$dir"/*.md 2>/dev/null | head -1
}
