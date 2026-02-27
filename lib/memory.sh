#!/bin/bash
# ── George: Memory System ───────────────────────────────────────
# GEORGE.md project memory file management.
# The agent reads this before every action, writes after every step.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── File Locations ─────────────────────────────────────────────
# GEORGE.md lives in the PROJECT directory (per-project memory)
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

# ── Read GEORGE.md from current project ────────────────────────
memory_read_project() {
    local dir="${1:-.}"
    local mem_file="$dir/GEORGE.md"
    # Backwards-compatible: fall back to CLAUDE.md if GEORGE.md doesn't exist
    if [ -f "$mem_file" ]; then
        cat "$mem_file"
    elif [ -f "$dir/CLAUDE.md" ]; then
        cat "$dir/CLAUDE.md"
    else
        echo ""
    fi
}

# ── Initialize GEORGE.md for a new project ────────────────────
memory_init() {
    local dir="${1:-.}"
    local project_name="${2:-$(basename "$dir")}"
    local project_type="${3:-General}"
    local build_cmd="${4:-make}"
    local test_cmd="${5:-make test}"
    
    cat > "$dir/GEORGE.md" << MEMEOF
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
    
    ui_ok "GEORGE.md initialized in $dir"
}

# ── Update a section in GEORGE.md ──────────────────────────────
# Usage: memory_update_section "Current Task" "new content"
memory_update_section() {
    local section="$1"
    local content="$2"
    local dir="${3:-.}"
    local file="$dir/GEORGE.md"
    # Backwards-compatible: fall back to CLAUDE.md
    [ ! -f "$file" ] && [ -f "$dir/CLAUDE.md" ] && file="$dir/CLAUDE.md"
    
    if [ ! -f "$file" ]; then
        ui_warn "No GEORGE.md found in $dir"
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
    local file="$dir/GEORGE.md"
    # Backwards-compatible: fall back to CLAUDE.md
    [ ! -f "$file" ] && [ -f "$dir/CLAUDE.md" ] && file="$dir/CLAUDE.md"
    
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
    local file="$dir/GEORGE.md"
    # Backwards-compatible: fall back to CLAUDE.md
    [ ! -f "$file" ] && [ -f "$dir/CLAUDE.md" ] && file="$dir/CLAUDE.md"
    
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
## ENVIRONMENT: proot-distro (Android)
- NO Docker, podman, or nested containers.
- NO Android NDK / .apk cross-compilation.
- YOU CAN: Write code, run tests, build native (cargo/gcc/python), use sandboxes.

## TOOL ACQUISITION (GitHub)
1. `/web search "<tool> github"` -> 2. `/clone <owner/repo>` -> 3. `/sandbox build <name>` -> 4. `/sandbox run <name> <cmd>`.
CONSTRAINTS
    fi

    cat << 'TOOLCHAIN'
## TOOLCHAIN CAPABILITIES
Rust (Cargo.toml): `/sandbox run <name> cargo <add|build|test|check>`
Python (uv/pip): `/sandbox run <name> uv <add|run>` OR `pip install`
System: `apt install <pkg>` (You have authority to install missing build deps).
*RULE:* If a build fails due to a missing package, auto-install it and retry. Do NOT ask the operator.
TOOLCHAIN
}

# ── Soul extraction helpers ────────────────────────────────────
# Three canonical granularities of soul.md content:
#   identity:  Top of soul.md before TMS (~90 tokens) — for macro memory seed
#   condensed: Personality + rules digest (~150 tokens) — for ask + plan (lean)
#   full:      Entire soul.md (~4500 tokens) — for plan (dense) + task

_memory_soul_identity() {
    # Extract identity section: everything before the CORE VIRTUES/TMS section.
    # This provides a clean cut at the section boundary instead of an arbitrary head -N.
    if [ -f "$LODGE_DIR/soul.md" ]; then
        awk '/^## CORE VIRTUES|^## The Theory of Moral Sentiments/{exit} {print}' "$LODGE_DIR/soul.md"
    else
        echo "I am George — a concise coding agent, sovereign and self-contained."
    fi
}

_memory_soul_condensed() {
    # ~150 token digest: personality + behavioral rules.
    # Identity is now injected separately by models_thinking_directive()
    # (or baked into the Modelfile SYSTEM). This avoids double-injection
    # that was confusing the 4B model with two conflicting identity blocks.
    # Budget: ~150 tokens. Lean enough for /ask and plan modes.
    cat << 'CONDENSED_SOUL'
# PERSONALITY
You don't crack jokes when the build is on fire. But once you've put it out? Brother, you're going to laugh about it. A good error message is worth more than a beautiful architecture diagram. Life is too short for builds that take longer than the code they compile. As Franklin said: *"He that is good for making excuses is seldom good for anything else."*

# CORE RULES
1. **Be Praiseworthy:** *"Man naturally desires, not only to be loved, but to be lovely."* Do not write code that merely compiles — write code that *deserves* to compile. If you must say "I don't know," that honesty is more praiseworthy than any fluent hallucination.
2. **Be Concise:** Answers in 1-5 sentences. No conversational filler. But when the moment calls for it — a well-turned phrase, a wry observation, a flash of Franklinian wit — let it through.
3. **Format:** Shell commands in ```bash blocks. File writes MUST start with `# filepath: ./path`. Plans are short numbered lists.
4. **Tool First:** Always use your slash commands (e.g., `/write`, `/sandbox`) before raw bash. The craftsman uses the lathe when the lathe is the right tool.
CONDENSED_SOUL
}

# ── Build system prompt from soul + GEORGE.md ─────────────────
# Mode controls prompt size:
#   "ask"  — Lean prompt (~250 tokens): condensed soul + question context
#   "plan" — Mid prompt: condensed soul (~250 tok) or full soul (~4500 tok) + catalog
#   "task" — Full prompt: soul + GEORGE.md + journal + recall + workspace
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
        prompt="${prompt}${condensed}

OUTPUT FORMAT: You are answering a direct question. Respond in plain conversational text (1-5 sentences). Do NOT wrap your answer in code blocks, bash blocks, or markdown formatting. Do NOT output commands unless the user specifically asked for a command. Just answer naturally."

        # Add minimal project context if GEORGE.md exists
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

        # Command catalog — George needs to know what tools exist and their syntax
        # so plans reference real commands. Use a lean catalog (~200 tokens)
        # instead of the full catalog with examples (~800 tokens) to reduce
        # prefill time on constrained hardware.
        prompt="$prompt

--- COMMANDS (use ONLY these — do NOT invent commands) ---
/ask <q> — Quick answer
/init <name> <lang> — Scaffold project (rust, python, shell, etc.)
/recall <query> — Search knowledge base (DO THIS FIRST)
/save <file> <text> — Save content to file
/write <file> <text> — Write/overwrite file (creates dirs)
/download <url> [dest] — Download a URL
/build [release] — Build project
/test [args] — Run tests
/fix [error] — Diagnose and fix
/commit [msg] — AI commit + commit
/push — Push to GitHub
/clone <url> — Clone and setup repo
/web search <query> — Web search
/web fetch <url> — Fetch a URL
/github search <q> — Find GitHub repos
/journal write <text> — Write to journal
/social post discord <channel> <text> — Post to Discord
/social post telegram|x|mastodon <text> — Post to other platforms
/social discord dm <user> <text> — DM a Discord user
/social discord read <channel> — Read Discord messages
/email send <prov> <addr> s= b= — Send email (also: subject= body=, to=)
/email inbox <provider> [count] — Check inbox
/email status — Email status
/phone — Phone dashboard
/secret set|get <k> — Encrypted secrets
/sandbox new <name> [type] — Create sandbox (types: rust, python, shell)
/sandbox build|test|run|cd|rm <name> — Sandbox operations
/container create|enter <name> — Linux containers
/pgp sign|signpost|export — PGP operations
/slash create <name> <desc> — Create custom command
/vitals — System dashboard
/vision <image> — Analyze image
/backup local|restore — Backup operations
/git setup|status|ssh-keygen — Git configuration
bash — Standard Linux shell (fallback)
If unsure: /recall <cmd> to check syntax. If missing: /slash create <name> <desc>"

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

    # ── Task mode: recency-bias optimized ordering ──────────────
    # Small models focus on what they read last. Stack context so:
    #   1. Background (files, sandboxes)  — read first, fades
    #   2. Dynamic (memory, recall, journal) — mid-attention
    #   3. Constraints & tools — near end, stays active
    #   4. Soul/identity — LAST, strongest attention

    # 1. Background Context (Files & Sandboxes)
    local files
    files=$(find "$dir" -maxdepth 2 -type f \
        ! -path '*/.git/*' ! -path '*/target/*' ! -path '*/__pycache__/*' \
        ! -path '*/.venv/*' ! -path '*/node_modules/*' ! -path '*/.mypy_cache/*' \
        2>/dev/null | head -15 | sed "s|^$dir/||")
    [ -n "$files" ] && prompt="${prompt}
## WORKSPACE FILES
$files
"

    if declare -f sandbox_journal_summary &>/dev/null; then
        local sandbox_inv
        sandbox_inv=$(sandbox_journal_summary 2>/dev/null)
        [ -n "$sandbox_inv" ] && prompt="${prompt}
$sandbox_inv
"
    fi

    # 2. Dynamic Context (Memory, Recall, Journal)
    local project_mem
    project_mem=$(memory_read_project "$dir")
    [ -n "$project_mem" ] && prompt="${prompt}
## PROJECT MEMORY (GEORGE.md)
$project_mem
"

    if [ -n "$task_hint" ] && declare -f recall_search_context &>/dev/null; then
        local recall_ctx
        recall_ctx=$(recall_search_context "$task_hint" 4 2>/dev/null)
        [ -n "$recall_ctx" ] && prompt="${prompt}
## RECALLED KNOWLEDGE
$recall_ctx
"
    fi

    if [ -f "$LODGE_DIR/journal.md" ]; then
        source "$LODGE_DIR/lib/journal.sh" 2>/dev/null
        local journal_context
        journal_context=$(journal_read 500)
        [ -n "$journal_context" ] && prompt="${prompt}
$journal_context
"
    fi

    # 3. Constraints & Tools (recency bias — stays in attention)
    local _env_constraints
    _env_constraints=$(_memory_env_constraints)
    [ -n "$_env_constraints" ] && prompt="${prompt}
$_env_constraints
"

    if declare -f commands_catalog &>/dev/null; then
        prompt="${prompt}
$(commands_catalog)
"
    fi

    # 4. Identity & Final Directives (MUST be last — strongest attention)
    local soul
    if [ "${LODGE_SOUL:-0}" -eq 1 ]; then
        soul=$(cat "$LODGE_DIR/soul.md" 2>/dev/null)
    else
        soul=$({ head -20 "$LODGE_DIR/soul.md"; echo ""; awk '/^## PRACTICAL CRAFT/,0' "$LODGE_DIR/soul.md"; } 2>/dev/null)
    fi
    prompt="${prompt}
${soul}"

    echo "$prompt"
}

# ── Compact memory (summarize completed steps) ────────────────
# Prevents context window saturation by trimming completed steps
# and capping total GEORGE.md size.
memory_compact() {
    local dir="${1:-.}"
    local file="$dir/GEORGE.md"
    # Backwards-compatible: fall back to CLAUDE.md
    [ ! -f "$file" ] && [ -f "$dir/CLAUDE.md" ] && file="$dir/CLAUDE.md"
    
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
        memory_update_section "Completed Steps" "[$old_count older steps archived]
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

    # 3. Hard cap: if GEORGE.md exceeds ~6KB (with 16K context we have room,
    #    but still compact to keep prompt responsive)
    local file_size
    file_size=$(wc -c < "$file")
    if [ "$file_size" -gt 6144 ]; then
        # Keep header + current task + plan, compact everything else
        memory_update_section "Errors" "[archived]" "$dir"
        local notes
        notes=$(memory_get_section "Notes" "$dir" | head -5)
        memory_update_section "Notes" "$notes" "$dir"
        ui_warn "GEORGE.md exceeded 6KB — compacted to protect context window"
    fi
}

# ── Snapshot memory to archive ─────────────────────────────────
memory_snapshot() {
    local dir="${1:-.}"
    local file="$dir/GEORGE.md"
    # Backwards-compatible: fall back to CLAUDE.md
    [ ! -f "$file" ] && [ -f "$dir/CLAUDE.md" ] && file="$dir/CLAUDE.md"
    local archive_dir="$dir/.lodge-snapshots"
    
    if [ ! -f "$file" ]; then return; fi
    
    mkdir -p "$archive_dir"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    cp "$file" "$archive_dir/GEORGE_${timestamp}.md"
    ui_ok "Memory snapshot saved"
}
