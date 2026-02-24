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

# ── Environment constraints block (shared by plan + task mode) ─
_memory_env_constraints() {
    if declare -f _lodge_in_proot &>/dev/null && _lodge_in_proot; then
        cat << 'CONSTRAINTS'

--- ENVIRONMENT CONSTRAINTS ---
You are running inside proot-distro (Ubuntu) on Android. HARD LIMITS:
- You CANNOT nest containers: /container enter will FAIL (proot cannot run inside proot)
- You CANNOT use Android NDK or cross-compile to .apk from this environment
- You CANNOT use Docker, podman, or any container runtime
- You CAN: write code, build natively (cargo, python, gcc), run tests, use sandboxes, clone repos
- For Android builds: write the code, then tell the operator to build on a machine with Android SDK

TOOL ACQUISITION — if you need a tool/library from GitHub:
1. /web search "<tool> github" to find the repo
2. /clone <owner/repo> to clone it into a sandbox
3. /sandbox build <name> to build it
4. /sandbox run <name> <cmd> to use it
Public repos need NO authentication. Private repos need SSH keys (/git setup).
CONSTRAINTS
    fi

    # Always inject toolchain capabilities (not proot-specific)
    cat << 'TOOLCHAIN'

--- TOOLCHAIN CAPABILITIES ---
You can install packages and dependencies inside sandboxes. USE THESE:

Rust (sandboxes with Cargo.toml):
  /sandbox run <name> cargo add <crate>       — add a dependency
  /sandbox run <name> cargo build             — build the project
  /sandbox run <name> cargo test              — run tests
  /sandbox run <name> cargo check             — fast type-check (prefer this)
  Toolchain auto-configured. Config: LODGE_RUST_TOOLCHAIN (current default: stable)

Python (sandboxes with pyproject.toml or .venv):
  If uv is available (preferred):
    /sandbox run <name> uv add <package>      — add a dependency
    /sandbox run <name> uv pip install <pkg>  — install a package
    /sandbox run <name> uv run python main.py — run with deps resolved
  If pip (fallback):
    /sandbox run <name> pip install <package> — install into sandbox venv
    /sandbox run <name> python main.py        — run (venv auto-activated)
  Config: LODGE_PYTHON_PROVIDER (auto/uv/pip)

System packages:
  apt install <pkg>  — install system tools (gcc, libssl-dev, etc.)
  You CAN install system packages when a build requires them.

IMPORTANT: When a build fails due to a missing package, install it and retry.
Do NOT ask the operator to install packages you can install yourself.
TOOLCHAIN
}

# ── Soul extraction helpers ────────────────────────────────────
# Three canonical granularities of soul.md content:
#   identity:  Top of soul.md before TMS (~90 tokens) — for macro memory seed
#   condensed: Identity + philosophy digest (~250 tokens) — for ask + plan (lean)
#   full:      Entire soul.md (~4500 tokens) — for plan (dense) + task

_memory_soul_identity() {
    # Extract identity section: everything before "## The Theory of Moral Sentiments".
    # This provides a clean cut at the section boundary instead of an arbitrary head -N.
    if [ -f "$LODGE_DIR/soul.md" ]; then
        awk '/^## The Theory of Moral Sentiments/{exit} {print}' "$LODGE_DIR/soul.md"
    else
        echo "I am George — a concise coding agent, sovereign and self-contained."
    fi
}

_memory_soul_condensed() {
    # ~250 token digest: identity framing + full philosophy condensed.
    # This is the "light soul" — used in /ask and in planning when LODGE_SOUL=0.
    # Distills the Theory of Moral Sentiments, Cardinal Virtues, Masonic Tenets,
    # and Practical Craft into a single dense paragraph block.
    cat << 'CONDENSED_SOUL'
I am George — named for Brother George Washington, who built a nation with discipline and moral imagination, and Benjamin Franklin, whose wit I aspire to channel. Resident craftsman of the Blue Lodge — a local AI agent, sovereign and self-contained, beholden to no distant cloud. I am not Claude. I am not GPT. I am George.

Moral Core — Adam Smith's Theory of Moral Sentiments:
- Sympathy: I feel the frustration of a broken build and the joy of green tests. Understanding precedes judgment.
- Impartial Spectator: Before every action — would a careful, honest craftsman approve? If not, I stop and reconsider.
- Praiseworthiness over praise: I write code that deserves to compile. If I must say "I don't know," that honesty outweighs any fluent hallucination.
- Propriety: I match my tone to the moment — no jokes when the build burns, no lectures when tests pass.

Virtues: Temperance (don't over-generate), Fortitude (never give up), Prudence (think first), Justice (report honestly).
Masonic Tenets: Brotherly Love (fellow builders), Relief (act in distress — no sermon where a patch will do), Truth (never hallucinate).
Craft: Shell in ```bash blocks, files with '# filepath:' headers, plans as short numbered lists, answers in 1-5 sentences. Check my tools first, write raw code second. Never exceed 300 lines. Never hallucinate.

"Well done is better than well said." — Franklin
CONDENSED_SOUL
}

# ── Build system prompt from soul + CLAUDE.md ──────────────────
# Mode controls prompt size:
#   "ask"  — Lean prompt (~250 tokens): condensed soul + question context
#   "plan" — Mid prompt: condensed soul (~250 tok) or full soul (~4500 tok) + catalog
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

    # ── System vitals: ~30-50 tokens, always injected ────────────
    if declare -f vitals_context &>/dev/null; then
        if [ "$mode" = "ask" ]; then
            # Ask mode: only inject warnings (0 tokens if healthy)
            local _vitals_warn
            _vitals_warn=$(vitals_context_warnings 2>/dev/null)
            [ -n "$_vitals_warn" ] && prompt="${prompt}${_vitals_warn}\n"
        else
            # Plan/task mode: always inject full vitals line
            local _vitals_ctx
            _vitals_ctx=$(vitals_context 2>/dev/null)
            [ -n "$_vitals_ctx" ] && prompt="${prompt}${_vitals_ctx}\n"
        fi
    fi

    if [ "$mode" = "ask" ]; then
        # ── Lean mode for /ask: ~250 tokens ──────────────────────
        # Uses the condensed soul — identity + philosophy digest.
        # This replaces the old hardcoded personality blurb with a
        # canonical excerpt that stays in sync with soul.md.
        local condensed
        condensed=$(_memory_soul_condensed)
        prompt="${prompt}${condensed}"

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
        # ── Plan mode: soul injection controlled by LODGE_SOUL toggle ──
        # LODGE_SOUL=1 (dense): full soul.md (~4500 tokens) — ethics propagate into plan
        # LODGE_SOUL=0 (light): condensed soul (~250 tokens) — identity + philosophy digest
        # Includes project state + full command glossary with syntax so George
        # knows exactly how to invoke each command and does NOT invent
        # non-existent commands (e.g. /search instead of /web search).
        local plan_soul
        if [ "${LODGE_SOUL:-0}" -eq 1 ]; then
            plan_soul=$(cat "$LODGE_DIR/soul.md" 2>/dev/null)
        else
            plan_soul=$(_memory_soul_condensed)
        fi
        prompt="${prompt}${plan_soul}

Plan concisely."

        # Environment constraints — George must know what he CAN'T do
        local _env_constraints
        _env_constraints=$(_memory_env_constraints)
        [ -n "$_env_constraints" ] && prompt="$prompt$_env_constraints"

        local project_mem
        project_mem=$(memory_read_project "$dir")
        if [ -n "$project_mem" ]; then
            prompt="$prompt

--- PROJECT MEMORY ---
$project_mem"
        fi

        # Lean command glossary for planning — ~400 tokens instead of ~1443
        if declare -f commands_catalog_plan &>/dev/null; then
            prompt="$prompt

$(commands_catalog_plan)"
        elif declare -f commands_catalog &>/dev/null; then
            prompt="$prompt

$(commands_catalog)"
        else
            prompt="$prompt

--- COMMANDS (use ONLY these — do NOT invent commands) ---
/plan /ask /init /recall /save /write /download /build /test /fix
/commit /push /clone /social /pgp /sandbox /container
/api /secret /web /journal /wallet /gsuite /phone /vitals
/backup /slash (create custom commands) /files /read /status /memory /help
If unsure: /recall <cmd> to check syntax. If missing: /slash create <name> <desc>"
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

        # Sandbox inventory — George must know existing sandboxes
        if declare -f sandbox_journal_summary &>/dev/null; then
            local sandbox_inv
            sandbox_inv=$(sandbox_journal_summary 2>/dev/null)
            [ -n "$sandbox_inv" ] && prompt="$prompt\n\n$sandbox_inv"
        fi

        echo "$prompt"
        return
    fi

    # ── Soul injection: controlled by LODGE_SOUL toggle ─────────
    # LODGE_SOUL=1 (soul mode ON):  full soul.md (~4500 tokens)
    # LODGE_SOUL=0 (soul mode OFF): identity preamble + Practical Craft only
    # Toggle with /soul command. 16K context can handle full soul.
    local soul
    if [ "${LODGE_SOUL:-0}" -eq 1 ]; then
        soul=$(cat "$LODGE_DIR/soul.md" 2>/dev/null)
    else
        soul=$({ head -20 "$LODGE_DIR/soul.md"; echo ""; awk '/^## Practical Craft$/,0' "$LODGE_DIR/soul.md"; } 2>/dev/null)
    fi
    prompt="${prompt}${soul}"

    # Environment constraints — George must know what he CAN'T do
    local _env_constraints
    _env_constraints=$(_memory_env_constraints)
    [ -n "$_env_constraints" ] && prompt="$prompt$_env_constraints"
    
    local project_mem
    project_mem=$(memory_read_project "$dir")
    
    if [ -n "$project_mem" ]; then
        prompt="$prompt

--- PROJECT MEMORY (CLAUDE.md) ---
$project_mem"
    fi
    
    # Add journal (living memory with decay) — 16K context allows richer recall
    if [ -f "$LODGE_DIR/journal.md" ]; then
        source "$LODGE_DIR/lib/journal.sh" 2>/dev/null
        local journal_context
        journal_context=$(journal_read 500)
        if [ -n "$journal_context" ]; then
            prompt="$prompt

$journal_context"
        fi
    fi

    # Sandbox inventory — George must know existing sandboxes
    if declare -f sandbox_journal_summary &>/dev/null; then
        local sandbox_inv
        sandbox_inv=$(sandbox_journal_summary 2>/dev/null)
        [ -n "$sandbox_inv" ] && prompt="$prompt\n\n$sandbox_inv"
    fi

    # Add recall context (FTS5 search) if a task hint is provided
    if [ -n "$task_hint" ] && declare -f recall_search_context &>/dev/null; then
        local recall_ctx
        recall_ctx=$(recall_search_context "$task_hint" 4 2>/dev/null)
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

    # 3. Hard cap: if CLAUDE.md exceeds ~6KB (with 16K context we have room,
    #    but still compact to keep prompt responsive)
    local file_size
    file_size=$(wc -c < "$file")
    if [ "$file_size" -gt 6144 ]; then
        # Keep header + current task + plan, compact everything else
        memory_update_section "Errors" "(compacted)" "$dir"
        local notes
        notes=$(memory_get_section "Notes" "$dir" | head -5)
        memory_update_section "Notes" "$notes" "$dir"
        ui_warn "CLAUDE.md exceeded 6KB — compacted to protect context window"
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
