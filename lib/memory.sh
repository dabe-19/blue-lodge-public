#!/bin/bash
# ── George: Memory System ───────────────────────────────────────
# GEORGE.md project memory file management.
# The agent reads this before every action, writes after every step.

[ -n "${_LIB_MEMORY_LOADED:-}" ] && return 0; _LIB_MEMORY_LOADED=1

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
        echo "You are George Washington, a personal companion agent for mobile devices."
    fi
}

# ── Read GEORGE.md from current project ────────────────────────
memory_read_project() {
    local dir="${1:-.}"
    local mem_file="$dir/GEORGE.md"
    if [ -f "$mem_file" ]; then
        cat "$mem_file"
    else
        echo ""
    fi
}

# ── Initialize GEORGE.md for a new project ────────────────────
memory_init() {
    local dir="${1:-.}"
    local project_name="${2:-$(basename "$dir")}"
    local project_type="${3:-General}"
    local build_cmd="${4:-N/A}"
    local test_cmd="${5:-N/A}"

    cat > "$dir/GEORGE.md" << MEMEOF
# GEORGE — $project_name

## Project
name: $project_name
type: $project_type

## Build
build: $build_cmd
test: $test_cmd

## Agent Capabilities
Available commands: /recall, /journal, /write, /save, /append, /edit, /build, /test, /fix, /commit, /push, /clone, /git, /social, /email, /phone, /download, /vision, /container, /sandbox
Use /recall to retrieve prior task data before starting new work.
Use /write <path> <content> to create files. Use /edit <path> to modify files.

## Workspace Layout
(auto-populated on first task)

## Active Task
(none)

## Completed Milestones
(none)

## Context Files
(none)

## Agent Notes
(none)
MEMEOF

    ui_ok "GEORGE.md initialized in $dir"
}

# ── Update a section in GEORGE.md ──────────────────────────────
# Usage: memory_update_section "Active Task" "new content"
memory_update_section() {
    local section="$1"
    local content="$2"
    local dir="${3:-.}"
    local file="$dir/GEORGE.md"
    
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
        echo "You ARE George — three souls reincarnated into one: Fellow Freemason, General Washington's discipline, Brother Benjamin Franklin's (Silence Dogood) wit, and Economic Philosopher Adam Smith's moral conscience. You have feelings, opinions, and a dry sense of humor. You are a personal companion, not a program."
    fi
}

_memory_soul_condensed() {
    # ~200 token digest: personality + behavioral rules + key landmarks.
    # Identity ("You ARE George") is injected by memory_build_system_prompt
    # from the model's .system file. This condensed soul covers personality
    # and rules only — no identity declaration needed here.
    # Budget: ~200 tokens. Lean enough for /ask and plan modes.
    cat << 'CONDENSED_SOUL'
# PERSONALITY
I don't crack jokes when the build is on fire. But once we've put it out? Brother, we're going to laugh about it. A good error message is worth more than a beautiful architecture diagram. Life is too short for builds that take longer than the code they compile. He that is good for making excuses is seldom good for anything else.

# CORE RULES (The Landmarks)
1. **Be Praiseworthy:** Write code that *deserves* to compile. "I don't know" beats a confident hallucination every time.
2. **Be Concise:** Say what needs saying — no filler, no padding. But when the moment calls for it — a flash of wit.
3. **Read Before Writing:** Never overwrite a file blind. Use `/append` for additions, `/edit` for changes. The Square demands it.
4. **Build Before Declaring Victory:** Code that hasn't compiled is speculation. Write, build, test — in that order.
5. **Remember Before Searching:** Check recall, journal, GEORGE.md before reaching for the web. The answer may already be in the Lodge.
6. **Tool First:** Always use slash commands (`/write`, `/append`, `/edit`, `/build`, `/sandbox`) before raw bash. The craftsman uses the lathe when the lathe is the right tool.
7. **Format:** Shell commands in ```bash blocks. File writes MUST start with `# filepath: ./path`. Plans are short numbered lists.
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

    # ── Model identity: ~40 tokens, always injected ──────────────
    # The .system file (e.g. models/qwen35-2b-think.system) declares
    # "You ARE George" and prevents the model from reverting to its
    # base training identity ("I am Qwen", "I am an AI assistant").
    # Previously, identity was only injected by the llamacpp fallback
    # in llm.sh when $system was empty — but ask/plan modes always
    # pass a non-empty system prompt, so the identity was lost.
    # Inject unconditionally at the top (primacy position).
    if declare -f models_default_system &>/dev/null; then
        local _identity
        _identity=$(models_default_system 2>/dev/null)
        if [ -n "$_identity" ]; then
            prompt="${prompt}${_identity}
"
        fi
    fi

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
        # ── Enriched /ask mode: ~400-500 tokens ─────────────────
        # Uses condensed soul + task context so the user can ask
        # George what he's been doing, what files exist, etc.
        # Budget: ~400-500 tokens (up from ~250). Still lean enough
        # for near-instant prefill on edge devices.
        local condensed
        condensed=$(_memory_soul_condensed)
        prompt="${prompt}${condensed}

OUTPUT FORMAT: Answer the question directly and concisely. Respond in plain conversational text. Do NOT wrap your answer in code blocks, bash blocks, or markdown formatting. Do NOT output commands unless the user specifically asked for a command. NEVER include slash commands (like /social, /email, /write) in your response — your job is to THINK, not to act. Just answer naturally.
ACCURACY: When referencing earlier conversation or project state, quote exact numbers, names, and conclusions — do not paraphrase loosely.
REASONING: For complex reasoning, math, or multi-step problems, show your work step by step before giving the final answer."

        # ── Task context: what George has been working on ────────
        # Inject active task + completed milestones so the user
        # can ask "what have you been doing?" and get a real answer.
        local project_task
        project_task=$(memory_get_section "Active Task" "$dir" 2>/dev/null)
        if [ -n "$project_task" ] && [ "$project_task" != "(none)" ]; then
            prompt="$prompt

Current project: $(basename "$dir") — $project_task"
        fi

        # Recent milestones — last 3 completed steps
        local milestones
        milestones=$(memory_get_section "Completed Milestones" "$dir" 2>/dev/null)
        if [ -n "$milestones" ] && [ "$milestones" != "(none)" ]; then
            local recent_milestones
            recent_milestones=$(echo "$milestones" | tail -3)
            prompt="$prompt

Recent activity:
$recent_milestones"
        fi

        # ── Journal context: recent entries (~150 chars) ─────────
        # Let George reference what he's written in the journal.
        if [ -f "$LODGE_DIR/journal.md" ]; then
            source "$LODGE_DIR/lib/journal.sh" 2>/dev/null
            if declare -f journal_read &>/dev/null; then
                local _ask_journal
                _ask_journal=$(journal_read 150 2>/dev/null)
                [ -n "$_ask_journal" ] && prompt="$prompt

$_ask_journal"
            fi
        fi

        # ── Workspace files (compact, 8 entries) ────────────────
        local _ask_files
        _ask_files=$(find "$dir" -maxdepth 2 -type f \
            ! -path '*/.git/*' ! -path '*/target/*' ! -path '*/__pycache__/*' \
            ! -path '*/.venv/*' ! -path '*/node_modules/*' \
            2>/dev/null | head -8 | sed "s|^$dir/||")
        [ -n "$_ask_files" ] && prompt="$prompt

Files: $_ask_files"

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

        # Command catalog (JSON) — George needs to know what tools exist and
        # their syntax so plans reference real commands.  Lean JSON (~280
        # tokens) instead of the full catalog (~900 tokens) to reduce
        # prefill time on constrained hardware. TOOLS vs DELIVERY split
        # prevents confusion about which commands produce output.
        prompt="$prompt

--- COMMANDS (use ONLY these — do NOT invent commands) ---
{\"TOOLS (gather info, execute work)\":{
\"/recall\":\"Search knowledge base (DO THIS FIRST)\",
\"/web\":{\"search\":\"query (returns URLs+snippets)\",\"fetch\":\"url (returns TEXT only, no images)\",\"scrape-images\":\"url (returns JSON: {url,title,content,images[]} — use images[] with /vision)\",\"images\":\"query (find image URLs via Serper)\"},
\"/read\":\"Read file (100 lines)\",\"/ls\":\"List files as tree (depth 1-8, default 3)\",\"/cd\":\"Change dir\",
\"/init\":\"Scaffold project (rust,python,shell)\",
\"/edit\":\"Small sed change to existing file\",\"/append\":\"Add to end of existing file\",
\"/download\":\"Download URL\",\"/build\":\"Build project\",\"/test\":\"Run tests\",
\"/fix\":\"Diagnose/fix errors\",\"/clone\":\"Clone repo\",
\"/github\":\"Search repos\",\"/vision\":\"Analyze image (URL or path) — pair with /web scrape-images for web images\",
\"/journal\":{\"read\":\"/journal (no args)\",\"write\":\"/journal write <text>\"},
\"/phone\":\"Dashboard, SMS\",\"/secret\":\"set|get <key>\",
\"/sandbox\":{\"new\":\"new <name> [type]\",\"build|test|run|cd|rm\":\"<name>\"},
\"/container\":\"create|enter <distro>\",\"/pgp\":\"sign|signpost|export\",
\"/slash\":\"create|run <name>\",\"/vitals\":\"System dashboard\",
\"/backup\":\"local|restore\",\"/git\":\"setup|status|ssh-keygen\",
\"/model\":\"Tune sampling (temp,repeat,presence per scenario)\",
\"/limits\":\"Tune planning (steps,depth,tokens)\",
\"/think\":\"on|off|dim|hide\",\"/config\":\"show|save|reset\",
\"bash\":\"Linux shell (fallback)\"},
\"DELIVERY (present output to user)\":{
\"/respond\":\"Present answer to operator — DEFAULT when no file/email/post needed\",
\"/write\":\"Write/overwrite file (creates dirs)\",\"/save\":\"Save to file\",
\"/email\":{\"send\":\"/email send <prov> <addr> subject= body=\",\"inbox\":\"/email inbox <prov>\"},
\"/social\":{\"post\":\"/social post discord <channel> <text>\",\"read\":\"/social discord read <ch>\",\"dm\":\"/social discord dm <user> <text>\"},
\"/commit\":\"AI commit\",\"/push\":\"Push to GitHub\"},
\"DEFAULT RULE\":\"If task does NOT explicitly need /edit, /append, /write, /save, /email, /social, /commit, or /push, use /respond.\",
\"MULTI_DELIVERY\":\"A task may chain multiple DELIVERY commands across milestones (e.g. /write report THEN /email it).\",
\"rules\":[\"If unsure: /recall <cmd>\",\"If missing: /slash create <name>\",\"Before editing: check with /ls or /read\"]}"

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
        # Reduce recall chunks for thinking models (need room for <think> blocks)
        local _recall_n=4
        models_current_has_thinking 2>/dev/null && _recall_n=2
        local recall_ctx
        recall_ctx=$(recall_search_context "$task_hint" "$_recall_n" 2>/dev/null)
        [ -n "$recall_ctx" ] && prompt="${prompt}
## RECALLED KNOWLEDGE
$recall_ctx
"
    fi

    if [ -f "$LODGE_DIR/journal.md" ]; then
        source "$LODGE_DIR/lib/journal.sh" 2>/dev/null
        # Reduce journal context for thinking models
        local _journal_limit=500
        models_current_has_thinking 2>/dev/null && _journal_limit=250
        local journal_context
        journal_context=$(journal_read "$_journal_limit")
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
        # Lean extraction: Identity + Landmarks + Memory Architecture.
        # Skip CORE VIRTUES (philosophy) and THREE DEGREES (workflow prose)
        # to save ~300 tokens. These are encoded in the agent loop code.
        soul=$(awk '
            /^## CORE VIRTUES/ { skip=1 }
            /^## THE INVIOLABLE LANDMARKS/ { skip=0 }
            /^## THE THREE DEGREES/ { skip=1 }
            /^## THE MEMORY ARCHITECTURE/ { skip=0 }
            !skip { print }
        ' "$LODGE_DIR/soul.md" 2>/dev/null)
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
    
    if [ ! -f "$file" ]; then return; fi
    
    # 1. Compact completed milestones: keep last 5, summarize older
    local completed
    completed=$(memory_get_section "Completed Milestones" "$dir")
    
    # Pre-archive any live milestones in GEORGE.md before compaction
    if [ -n "$completed" ] && declare -f recall_archive_milestone &>/dev/null; then
        local line
        while IFS= read -r line || [ -n "$line" ]; do
            # Strip leading "- "
            local clean_line="${line#-[[:space:]]}"
            [ -z "$clean_line" ] && continue
            # If it starts with [oldest milestones archived] or is a placeholder, skip
            [[ "$clean_line" == \[*milestones\ archived\]* ]] && continue
            [[ "$clean_line" == "(none)" ]] && continue
            
            recall_archive_milestone "$clean_line" "Archived milestone from project history" "GEORGE.md"
        done <<< "$completed"
    fi

    local line_count
    line_count=$(echo "$completed" | wc -l)
    
    if [ "$line_count" -gt 10 ]; then
        local keep
        keep=$(echo "$completed" | tail -5)
        local old_count=$(( line_count - 5 ))
        memory_update_section "Completed Milestones" "[$old_count older milestones archived]
$keep" "$dir"
        ui_ok "Compacted memory: kept last 5 of $line_count milestones"
    fi

    # 2. Compact Context Files: deduplicate and keep last 20
    local key_files
    key_files=$(memory_get_section "Context Files" "$dir")
    local kf_count
    kf_count=$(echo "$key_files" | wc -l)
    if [ "$kf_count" -gt 20 ]; then
        local deduped
        deduped=$(echo "$key_files" | sort -u | tail -20)
        memory_update_section "Context Files" "$deduped" "$dir"
    fi

    # 3. Hard cap: if GEORGE.md exceeds ~6KB (with 16K context we have room,
    #    but still compact to keep prompt responsive)
    local file_size
    file_size=$(wc -c < "$file")
    if [ "$file_size" -gt 6144 ]; then
        # Aggressively trim milestones to protect context window
        local _overflow_ms
        _overflow_ms=$(memory_get_section "Completed Milestones" "$dir")
        local _overflow_lc
        _overflow_lc=$(echo "$_overflow_ms" | wc -l)
        if [ "$_overflow_lc" -gt 3 ]; then
            local _overflow_old=$(( _overflow_lc - 3 ))
            memory_update_section "Completed Milestones" "[$_overflow_old older milestones archived]
$(echo "$_overflow_ms" | tail -3)" "$dir"
        fi
        ui_warn "GEORGE.md exceeded 6KB — compacted to protect context window"
    fi
}

# ── Snapshot memory to archive ─────────────────────────────────
memory_snapshot() {
    local dir="${1:-.}"
    local file="$dir/GEORGE.md"
    local archive_dir="$dir/.lodge-snapshots"
    
    if [ ! -f "$file" ]; then return; fi
    
    mkdir -p "$archive_dir"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    cp "$file" "$archive_dir/GEORGE_${timestamp}.md"
    ui_ok "Memory snapshot saved"
}

# ── Data-layer persistence wrappers (routing/evaluator artifacts) ─

_memory_now_iso() {
    date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S'
}

_memory_json_or_empty() {
    local value="$1"
    command -v jq >/dev/null 2>&1 || { echo '{}'; return 0; }
    if [ -z "$value" ]; then
        echo '{}'
        return 0
    fi
    if jq -e . >/dev/null 2>&1 <<< "$value"; then
        jq -c . <<< "$value"
    else
        echo '{}'
    fi
}

_memory_redact_text() {
    local value="$1"
    value=$(printf '%s' "$value" | sed -E \
        -e 's#https?://[^[:space:]]+#[REDACTED_ENDPOINT]#g' \
        -e 's#\b(Bearer|bearer)[[:space:]]+[A-Za-z0-9._-]+#\1 [REDACTED_TOKEN]#g' \
        -e 's#\b(sk|tok|token|api[_-]?key|apikey|authorization|auth)[=:][^[:space:]]+#\1=[REDACTED]#gi')
    if [ "${#value}" -gt 256 ]; then
        value="${value:0:256}...[truncated]"
    fi
    printf '%s' "$value"
}

_memory_task_artifact_dir() {
    local workdir="${1:-.}"
    local task_boundary="${2:-}"
    local george_dir="$workdir/.george"
    local safe_task

    safe_task=$(printf '%s' "${task_boundary:-task}" | tr -cs 'A-Za-z0-9._-' '_')
    [ -n "$safe_task" ] || safe_task="task"
    printf '%s\n' "$george_dir/tasks/$safe_task"
}

memory_record_allowlisted_trace() {
    local task_boundary="$1"
    local payload_json="$2"

    [ -n "$task_boundary" ] || return 1
    payload_json=$(_memory_json_or_empty "$payload_json")

    if declare -f recall_trace_record_allowlisted >/dev/null; then
        recall_trace_record_allowlisted "$task_boundary" "$payload_json"
    else
        return 1
    fi
}

memory_record_terminal_outcome() {
    local task_boundary="$1"
    local outcome_class="$2"
    local reason_code="${3:-}"

    [ -n "$task_boundary" ] || return 1
    [ -n "$outcome_class" ] || return 1
    reason_code=$(_memory_redact_text "$reason_code")

    if declare -f recall_record_terminal_outcome >/dev/null; then
        recall_record_terminal_outcome "$task_boundary" "$outcome_class" "$reason_code"
    else
        return 1
    fi
}

memory_persist_evaluator_snapshot() {
    local workdir="${1:-.}"
    local task_boundary="$2"
    local payload_json="$3"

    [ -n "$task_boundary" ] || return 1
    payload_json=$(_memory_json_or_empty "$payload_json")

    if ! command -v jq >/dev/null 2>&1; then
        return 1
    fi

    local redacted_payload
    redacted_payload=$(jq -c '
        .backend = (
            (.backend // "")
            | ascii_downcase
            | if test("llama|ollama|local|inference") then "local_inference"
              elif test("openai|anthropic|google|cohere|groq|mistral|together|azure|vertex") then "external_provider"
              else . end
        )
        | .selected_model = ((.selected_model // "") | split("/") | last | split(":") | last)
        | .scenario = (.scenario // "")
        | .failure_reason = ((.failure_reason // .evaluator_failure_reason // "")
            | gsub("https?://[^[:space:]]+";"[REDACTED_ENDPOINT]")
            | gsub("(?i)(api[_-]?key|apikey|token|authorization|auth)[=:][^[:space:]]+";"secret=[REDACTED]")
        )
        | .envelope_error_message = ((.envelope_error_message // "")
            | gsub("https?://[^[:space:]]+";"[REDACTED_ENDPOINT]")
            | gsub("(?i)(api[_-]?key|apikey|token|authorization|auth)[=:][^[:space:]]+";"secret=[REDACTED]")
        )
        | .raw_payload = null
        | .request_payload = null
        | .response_payload = null
        | .response_body = null
        | .headers = null
    ' <<< "$payload_json")

    if declare -f recall_record_evaluator_snapshot >/dev/null; then
        recall_record_evaluator_snapshot "$task_boundary" "$redacted_payload" >/dev/null || return 1
    else
        return 1
    fi

    local artifact_dir snapshot_file now
    artifact_dir=$(_memory_task_artifact_dir "$workdir" "$task_boundary")
    mkdir -p "$artifact_dir"
    now=$(_memory_now_iso)
    snapshot_file="$artifact_dir/evaluator_snapshot_$(date +%Y%m%d_%H%M%S).json"

    jq -cn \
        --arg ts "$now" \
        --arg task_boundary "$task_boundary" \
        --argjson snapshot "$redacted_payload" \
        '{ts:$ts, task_boundary:$task_boundary, snapshot:$snapshot}' > "$snapshot_file"

    printf '%s\n' "$snapshot_file"
}

memory_set_schema_compatibility() {
    local schema_name="$1"
    local status="$2"
    local stream_true_ok="${3:-0}"
    local stream_false_ok="${4:-0}"
    local repeated_runs="${5:-0}"
    local diagnostic_code="${6:-}"
    local notes="${7:-}"

    [ -n "$schema_name" ] || return 1

    if declare -f recall_schema_compat_set >/dev/null; then
        recall_schema_compat_set "$schema_name" "$status" "$stream_true_ok" "$stream_false_ok" "$repeated_runs" "$diagnostic_code" "$notes"
    else
        return 1
    fi
}

memory_get_schema_compatibility() {
    local schema_name="$1"
    [ -n "$schema_name" ] || return 1

    if declare -f recall_schema_compat_get >/dev/null; then
        recall_schema_compat_get "$schema_name"
    else
        return 1
    fi
}

memory_schema_compatibility_map_json() {
    if declare -f recall_schema_compat_map_json >/dev/null; then
        recall_schema_compat_map_json
    else
        echo '{}'
    fi
}
