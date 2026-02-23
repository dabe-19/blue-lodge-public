#!/bin/bash
# ── George: Memory System ───────────────────────────────────────
# CLAUDE.md-compatible memory file management.
# The agent reads this before every action, writes after every step.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── File Locations ─────────────────────────────────────────────
# CLAUDE.md lives in the PROJECT directory (per-project memory)
# soul.md lives in LODGE_DIR (global personality)

# ── Read soul.md ───────────────────────────────────────────────
memory_read_soul() {
    local soul_file="$LODGE_DIR/soul.md"
    if [ -f "$soul_file" ]; then
        cat "$soul_file"
    else
        echo "You are George, a concise coding agent for mobile devices."
    fi
}

# ── Read CLAUDE.md from current project ────────────────────────
memory_read_project() {
    local dir="${1:-.}"
    local claude_file="$dir/CLAUDE.md"
    if [ -f "$claude_file" ]; then
        cat "$claude_file"
    else
        echo ""
    fi
}

# ── Initialize CLAUDE.md for a new project ─────────────────────
memory_init() {
    local dir="${1:-.}"
    local project_name="${2:-$(basename "$dir")}"
    local project_type="${3:-General}"
    local build_cmd="${4:-make}"
    local test_cmd="${5:-make test}"
    
    cat > "$dir/CLAUDE.md" << MEMEOF
# $project_name

## Type
$project_type

## Build
\`$build_cmd\`

## Test
\`$test_cmd\`

## Current Task
(none)

## Plan
(none)

## Completed Steps
(none)

## Key Files
(auto-populated as agent works)

## Errors
(none)

## Notes
- Hardware: Galaxy Fold 7, Snapdragon 8 Elite, 12GB RAM
- Keep context lean. Small functions. Structured logging.
MEMEOF
    
    ui_ok "CLAUDE.md initialized in $dir"
}

# ── Update a section in CLAUDE.md ──────────────────────────────
# Usage: memory_update_section "Current Task" "new content"
memory_update_section() {
    local section="$1"
    local content="$2"
    local dir="${3:-.}"
    local file="$dir/CLAUDE.md"
    
    if [ ! -f "$file" ]; then
        ui_warn "No CLAUDE.md found in $dir"
        return 1
    fi
    
    # Use awk to replace section content
    awk -v section="## $section" -v content="$content" '
    BEGIN { found=0; printed=0 }
    $0 == section { 
        print; 
        print content; 
        found=1; 
        printed=1; 
        next 
    }
    found && /^## / { found=0 }
    !found { print }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# ── Append to a section ───────────────────────────────────────
memory_append_section() {
    local section="$1"
    local line="$2"
    local dir="${3:-.}"
    local file="$dir/CLAUDE.md"
    
    if [ ! -f "$file" ]; then return 1; fi
    
    local current
    current=$(memory_get_section "$section" "$dir")
    
    # Remove (none) or (auto-populated) placeholders
    current=$(echo "$current" | grep -v '^(none)$' | grep -v '^(auto-populated' || true)
    
    if [ -n "$current" ]; then
        memory_update_section "$section" "$current
- $line" "$dir"
    else
        memory_update_section "$section" "- $line" "$dir"
    fi
}

# ── Get a section's content ───────────────────────────────────
memory_get_section() {
    local section="$1"
    local dir="${2:-.}"
    local file="$dir/CLAUDE.md"
    
    if [ ! -f "$file" ]; then echo ""; return; fi
    
    awk -v section="## $section" '
    $0 == section { found=1; next }
    found && /^## / { exit }
    found { print }
    ' "$file" | sed '/^$/d'
}

# ── Build system prompt from soul + CLAUDE.md ──────────────────
# Mode controls prompt size:
#   "ask"  — Lean prompt (~150 tokens): just personality + question context
#   "plan" — Mid prompt (~1,500 tokens): truncated soul + CLAUDE.md + workspace files
#   "task" — Full prompt: soul + CLAUDE.md + journal + recall + workspace
memory_build_system_prompt() {
    local dir="${1:-.}"
    local task_hint="${2:-}"  # optional: current task/question for recall augmentation
    local mode="${3:-task}"   # "ask" | "plan" | "task"

    # ── System clock: ~10 tokens, always injected ────────────────
    local now
    now=$(date '+%A, %B %d, %Y %H:%M %Z')
    local prompt="[Current time: $now]
"

    if [ "$mode" = "ask" ]; then
        # ── Lean mode for /ask: ~150 tokens ──────────────────────
        # The Modelfile SYSTEM prompt already has George's core personality.
        # Only add the essentials the model doesn't already know.
        prompt="${prompt}You are George — a local coding agent running on mobile (Galaxy Fold 7, 12GB RAM).
Answer concisely in 1-5 sentences. Be helpful and — when appropriate — witty."

        # Add minimal project context if CLAUDE.md exists
        local project_task
        project_task=$(memory_get_section "Current Task" "$dir" 2>/dev/null)
        if [ -n "$project_task" ] && [ "$project_task" != "(none)" ]; then
            prompt="$prompt

Current project: $(basename "$dir") — $project_task"
        fi

        # Add 1 recall chunk if available (not 3)
        if [ -n "$task_hint" ] && declare -f recall_search_context &>/dev/null; then
            local recall_ctx
            recall_ctx=$(recall_search_context "$task_hint" 1 2>/dev/null)
            if [ -n "$recall_ctx" ]; then
                # Cap recall to ~200 chars
                prompt="$prompt

${recall_ctx:0:200}"
            fi
        fi

        echo "$prompt"
        return
    fi

    if [ "$mode" = "plan" ]; then
        # ── Plan mode: ~1,500 tokens ─────────────────────────────
        # Planning only needs identity + project state + file list.
        # No journal, no recall, truncated soul.
        local soul
        soul=$(cat "$LODGE_DIR/soul.md" 2>/dev/null | head -40)
        prompt="${prompt}${soul}"

        local project_mem
        project_mem=$(memory_read_project "$dir")
        if [ -n "$project_mem" ]; then
            prompt="$prompt

--- PROJECT MEMORY ---
$project_mem"
        fi

        # Command catalog — George must know his tools to plan with them
        if declare -f commands_catalog &>/dev/null; then
            prompt="$prompt

$(commands_catalog)"
        fi

        # Workspace files (needed for planning)
        local files
        files=$(find "$dir" -maxdepth 2 -type f \
            ! -path '*/.git/*' ! -path '*/target/*' ! -path '*/__pycache__/*' \
            ! -path '*/.venv/*' ! -path '*/node_modules/*' ! -path '*/.mypy_cache/*' \
            2>/dev/null | head -15 | sed "s|^$dir/||")
        if [ -n "$files" ]; then
            prompt="$prompt

--- WORKSPACE FILES ---
$files"
        fi

        echo "$prompt"
        return
    fi

    # ── Full mode for tasks: budget-conscious ───────────────────
    local soul
    soul=$(memory_read_soul)
    prompt="${prompt}${soul}"
    
    local project_mem
    project_mem=$(memory_read_project "$dir")
    
    if [ -n "$project_mem" ]; then
        prompt="$prompt

--- PROJECT MEMORY (CLAUDE.md) ---
$project_mem"
    fi
    
    # Add journal (living memory with decay) — cap at 200 tokens for tasks
    if [ -f "$LODGE_DIR/journal.md" ]; then
        source "$LODGE_DIR/lib/journal.sh" 2>/dev/null
        local journal_context
        journal_context=$(journal_read 200)
        if [ -n "$journal_context" ]; then
            prompt="$prompt

$journal_context"
        fi
    fi

    # Add recall context (FTS5 search) if a task hint is provided
    if [ -n "$task_hint" ] && declare -f recall_search_context &>/dev/null; then
        local recall_ctx
        recall_ctx=$(recall_search_context "$task_hint" 2 2>/dev/null)
        if [ -n "$recall_ctx" ]; then
            prompt="$prompt

--- RECALLED KNOWLEDGE ---
$recall_ctx"
        fi
    fi

    # Command catalog — George must know his tools to use them in tasks
    if declare -f commands_catalog &>/dev/null; then
        prompt="$prompt

$(commands_catalog)"
    fi
    
    # Add workspace file listing (lightweight)
    local files
    files=$(find "$dir" -maxdepth 2 -type f \
        ! -path '*/.git/*' ! -path '*/target/*' ! -path '*/__pycache__/*' \
        ! -path '*/.venv/*' ! -path '*/node_modules/*' ! -path '*/.mypy_cache/*' \
        2>/dev/null | head -15 | sed "s|^$dir/||")
    
    if [ -n "$files" ]; then
        prompt="$prompt

--- WORKSPACE FILES ---
$files"
    fi
    
    echo "$prompt"
}

# ── Compact memory (summarize completed steps) ────────────────
# Prevents context window saturation by trimming completed steps
# and capping total CLAUDE.md size.
memory_compact() {
    local dir="${1:-.}"
    local file="$dir/CLAUDE.md"
    
    if [ ! -f "$file" ]; then return; fi
    
    # 1. Compact completed steps: keep last 5, summarize older
    local completed
    completed=$(memory_get_section "Completed Steps" "$dir")
    local line_count
    line_count=$(echo "$completed" | wc -l)
    
    if [ "$line_count" -gt 10 ]; then
        local keep
        keep=$(echo "$completed" | tail -5)
        local old_count=$(( line_count - 5 ))
        memory_update_section "Completed Steps" "(...$old_count earlier steps compacted...)
$keep" "$dir"
        ui_ok "Compacted memory: kept last 5 of $line_count steps"
    fi

    # 2. Compact Key Files: deduplicate and keep last 20
    local key_files
    key_files=$(memory_get_section "Key Files" "$dir")
    local kf_count
    kf_count=$(echo "$key_files" | wc -l)
    if [ "$kf_count" -gt 20 ]; then
        local deduped
        deduped=$(echo "$key_files" | sort -u | tail -20)
        memory_update_section "Key Files" "$deduped" "$dir"
    fi

    # 3. Hard cap: if CLAUDE.md exceeds ~3KB (roughly 1/3 of usable context
    #    after soul.md + journal + recall), truncate aggressively
    local file_size
    file_size=$(wc -c < "$file")
    if [ "$file_size" -gt 3072 ]; then
        # Keep header + current task + plan, compact everything else
        memory_update_section "Errors" "(compacted)" "$dir"
        local notes
        notes=$(memory_get_section "Notes" "$dir" | head -3)
        memory_update_section "Notes" "$notes" "$dir"
        ui_warn "CLAUDE.md exceeded 3KB — aggressively compacted to protect context window"
    fi
}

# ── Snapshot memory to archive ─────────────────────────────────
memory_snapshot() {
    local dir="${1:-.}"
    local file="$dir/CLAUDE.md"
    local archive_dir="$dir/.lodge-snapshots"
    
    if [ ! -f "$file" ]; then return; fi
    
    mkdir -p "$archive_dir"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    cp "$file" "$archive_dir/CLAUDE_${timestamp}.md"
    ui_ok "Memory snapshot saved"
}
