#!/bin/bash
# ── Blue Lodge: Memory System ─────────────────────────────────
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
        echo "You are Blue Lodge, a concise coding agent for mobile devices."
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
    current=$(echo "$current" | grep -v '^\(none\)$' | grep -v '^\(auto-populated' || true)
    
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
memory_build_system_prompt() {
    local dir="${1:-.}"
    local soul
    soul=$(memory_read_soul)
    local project_mem
    project_mem=$(memory_read_project "$dir")
    
    local prompt="$soul"
    
    if [ -n "$project_mem" ]; then
        prompt="$prompt

--- PROJECT MEMORY (CLAUDE.md) ---
$project_mem"
    fi
    
    # Add workspace file listing (lightweight)
    local files
    files=$(find "$dir" -maxdepth 3 -type f \
        ! -path '*/.git/*' ! -path '*/target/*' ! -path '*/__pycache__/*' \
        ! -path '*/.venv/*' ! -path '*/node_modules/*' ! -path '*/.mypy_cache/*' \
        2>/dev/null | head -40 | sed "s|^$dir/||")
    
    if [ -n "$files" ]; then
        prompt="$prompt

--- WORKSPACE FILES ---
$files"
    fi
    
    echo "$prompt"
}

# ── Compact memory (summarize completed steps) ────────────────
memory_compact() {
    local dir="${1:-.}"
    local file="$dir/CLAUDE.md"
    
    if [ ! -f "$file" ]; then return; fi
    
    local completed
    completed=$(memory_get_section "Completed Steps" "$dir")
    local line_count
    line_count=$(echo "$completed" | wc -l)
    
    if [ "$line_count" -gt 10 ]; then
        # Keep last 5 steps, summarize the rest
        local keep
        keep=$(echo "$completed" | tail -5)
        local old_count=$(( line_count - 5 ))
        memory_update_section "Completed Steps" "(...$old_count earlier steps compacted...)
$keep" "$dir"
        ui_ok "Compacted memory: kept last 5 of $line_count steps"
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
