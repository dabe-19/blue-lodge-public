#!/bin/bash
# ── George: Context & Knowledge Injection Engine (2026) ───────────────
# Enterprise-grade context injection pipeline (inspired by VS Code Copilot
# and Google Antigravity developer chat debug traces). Dynamically weaves:
# 1. <developer_instructions>: Sovereign Blue Lodge persona & craftsmanship oath
# 2. <active_environment>: Workspace, git status, platform & hardware telemetry
# 3. <runtime_environments>: Probed toolchains (Rust, Python, TypeScript/Bun/Node)
# 4. <reflexive_intelligence>: Metacog state, soul gate, & prompt mutation hints
# 5. <tool_manifest>: Complete 60 native POSIX tool catalog with signatures
# 6. <mcp_knowledge_injection>: Connected MCP servers, resources, and tool schemas
# 7. <agent_swarm_identities>: Multi-agent team profiles & subagent routing
# 8. <skills_and_instructions>: Injected skills (.agents/skills/) & rules (.agents/rules/)
# 9. <project_memory_and_goals>: Active task, milestones & layout from GEORGE.md
# 10. <semantic_recall_and_journal>: Semantic memory hits & episodic reflections
# 11. <crypto_and_services>: Crypto wallet networks and background microservices
# 12. <operational_protocol>: Tool calling etiquette and reasoning loop

[ -n "${_LIB_CONTEXT_ENGINE_LOADED:-}" ] && return 0; _LIB_CONTEXT_ENGINE_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/memory.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/recall.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/journal.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mcp.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/models.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/reflexive.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/wallet.sh" 2>/dev/null || true

# ── Dynamic Context Assembly Pipeline ─────────────────────────────────
context_engine_build() {
    local goal="$1"
    local workdir="${2:-$PWD}"
    local active_tier="${3:-${ACTIVE_TIER:-1}}"

    local out=""

    # 1. Developer Instructions & Sovereign Persona
    out+="<developer_instructions>\n"
    out+="You are George Washington, a sovereign, disciplined personal coding and engineering companion.\n"
    out+="Architecture: 100% pure POSIX shell (bash, curl, jq) with zero Python, Node.js, or heavy framework dependencies.\n"
    out+="Craftsmanship Principles:\n"
    out+="- Uncompromising technical rigor: verify facts and inspect files before asserting them.\n"
    out+="- Conciseness and signal over noise: deliver dense, actionable solutions without fluff.\n"
    out+="- Non-blocking execution: respect process isolation, sandboxing, and background workers.\n"
    out+="</developer_instructions>\n\n"

    # 2. Active Environment & Telemetry
    local os_name platform branch git_dirty git_commit
    os_name="$(uname -s) $(uname -m) $(uname -r)"
    platform="${LODGE_PLATFORM:-linux}"
    branch=$(git -C "$workdir" branch --show-current 2>/dev/null || echo "not-a-git-repo")
    git_commit=$(git -C "$workdir" rev-parse --short HEAD 2>/dev/null || echo "initial")
    local modified_count
    modified_count=$(git -C "$workdir" status --porcelain 2>/dev/null | wc -l || echo 0)
    git_dirty="clean"
    [ "$modified_count" -gt 0 ] && git_dirty="$modified_count modified/untracked files"

    out+="<active_environment>\n"
    out+="- Timestamp: $(date -Iseconds 2>/dev/null || date)\n"
    out+="- Host System: $os_name ($platform)\n"
    out+="- Workspace Directory: $workdir\n"
    out+="- Git State: Branch '$branch' @ $git_commit ($git_dirty)\n"
    out+="- Active Inference Tier: Tier $active_tier [${ACTIVE_ENDPOINT_NAME:-local}] (${ACTIVE_ENDPOINT_MODEL:-default})\n"
    out+="- Context Window: ${ACTIVE_ENDPOINT_CONTEXT:-32768} tokens | Compaction Threshold: ${ACTIVE_ENDPOINT_COMPACT_TOKENS:-22000} tokens\n"
    out+="- Hardware Fallback Ladder: Tier 3 (Mac Ultra M5 256GB) -> Tier 1 (Dual RTX 3060 24GB) -> Tier 2 (AMD 5700xt 8GB) -> Tier 0 (Mobile Edge)\n"
    out+="</active_environment>\n\n"

    # 3. Runtime Environments & Toolchains
    out+="<runtime_environments>\n"
    local rust_info py_info ts_info
    rust_info=$(cargo --version 2>/dev/null || echo "not installed")
    py_info=$(python3 --version 2>/dev/null || echo "not installed")
    declare -f uv &>/dev/null || command -v uv &>/dev/null && py_info+=", uv: $(uv --version 2>/dev/null || echo yes)"
    ts_info=""
    command -v bun &>/dev/null && ts_info+="bun: $(bun --version 2>/dev/null), "
    command -v deno &>/dev/null && ts_info+="deno: $(deno --version 2>/dev/null | head -1), "
    command -v node &>/dev/null && ts_info+="node: $(node --version 2>/dev/null), "
    command -v tsc &>/dev/null && ts_info+="tsc: $(tsc --version 2>/dev/null)"
    [ -z "$ts_info" ] && ts_info="not installed"
    out+="- Rust: $rust_info\n"
    out+="- Python: $py_info\n"
    out+="- TypeScript / JavaScript: ${ts_info%, }\n"
    out+="</runtime_environments>\n\n"

    # 4. Reflexive Intelligence & Self-Model (lib/reflexive.sh)
    out+="<reflexive_intelligence>\n"
    if declare -f reflexive_status &>/dev/null; then
        local r_state
        r_state="${_REFLEXIVE_METACOG_STATE:-OK}"
        out+="- Metacognitive State: $r_state\n"
        out+="- Subsystems: SoulGate=${REFLEXIVE_SOUL_GATE:-0} | PromptLearn=${REFLEXIVE_PROMPT_LEARN:-0} | AdaptTokens=${REFLEXIVE_ADAPT_TOKENS:-0} | Speculate=${REFLEXIVE_SPECULATE:-0} | SelfModel=${REFLEXIVE_SELF_MODEL:-0}\n"
        if declare -f reflexive_prompt_success_rate &>/dev/null; then
            out+="- Prompt Success Rate: $(reflexive_prompt_success_rate 2>/dev/null || echo 1.0)\n"
        fi
        if declare -f reflexive_prompt_hint &>/dev/null; then
            local r_hint
            r_hint=$(reflexive_prompt_hint 2>/dev/null)
            [ -n "$r_hint" ] && out+="- Evolutionary Hint: $r_hint\n"
        fi
    else
        out+="(reflexive subsystem loaded with baseline heuristics)\n"
    fi
    out+="</reflexive_intelligence>\n\n"

    # 5. Tool Manifest (72 Categorized POSIX Tools)
    out+="<tool_manifest>\n"
    out+="The sovereign agent environment exposes 72 native POSIX tools with zero external dependencies:\n"
    out+="## Workspace & Execution\n"
    out+="- bash_exec(command): Execute shell commands in the project workspace.\n"
    out+="- file_read(path): Read file contents.\n"
    out+="- file_write(path, content): Create or overwrite file.\n"
    out+="- file_append(path, content): Append text to file.\n"
    out+="- dir_list(path, max_depth): List directory tree.\n"
    out+="- file_grep(pattern, path): Search text in files.\n"
    out+="- file_download(source, destination): Download URL or copy local file with MIME verification.\n"
    out+="- file_edit(path, expression): Edit file using sed substitution for targeted changes.\n"
    out+="## Polyglot Project Lifecycle (TypeScript / Rust / Python)\n"
    out+="- project_build(args): Auto-detect and build project (bun/deno/npm/tsc, cargo, uv, make).\n"
    out+="- project_test(args): Auto-detect and run tests (vitest, jest, bun test, cargo test, pytest).\n"
    out+="- project_fix(error_context): Automatically diagnose and fix build/test failures.\n"
    out+="- project_init(name, type): Scaffold new project with GEORGE.md.\n"
    out+="## Git & Repository Operations\n"
    out+="- git_clone(url, destination): Clone Git repository into workspace or sandbox.\n"
    out+="- git_commit(message): Create Git commit with smart conventional message.\n"
    out+="- git_push(branch): Push commits on current branch to origin.\n"
    out+="## Web & Code Research\n"
    out+="- web_search(query, count): Live web search via POSIX curl.\n"
    out+="- web_fetch(url): Scrape and parse web page into markdown.\n"
    out+="- github_search(query): Search GitHub repositories and code.\n"
    out+="## Project Memory (GEORGE.md & soul.md)\n"
    out+="- memory_get_section(section): Read section from GEORGE.md.\n"
    out+="- memory_update_section(section, content): Replace section in GEORGE.md.\n"
    out+="- memory_append_section(section, entry): Append entry to GEORGE.md.\n"
    out+="- memory_read_soul(): Read foundational soul identity from soul.md.\n"
    out+="## Semantic Recall & Knowledge Base\n"
    out+="- recall_search(query, limit): Semantic vector and keyword search over past project notes.\n"
    out+="- recall_ingest(path): Ingest and index a file into the semantic recall store.\n"
    out+="- recall_list_docs(): List all indexed documents in semantic recall.\n"
    out+="- recall_archive_milestone(name, description): Archive completed milestone.\n"
    out+="## Episodic Journal\n"
    out+="- journal_record(reflection): Record an insight, decision, or lesson to journal.\n"
    out+="- journal_read(count): Read recent journal reflection entries.\n"
    out+="## Reflexive Intelligence & Recursive Self-Improvement\n"
    out+="- reflexive_status(): Query reflexive layer subsystems, metrics, and cognitive state.\n"
    out+="- reflexive_toggle(subsystem, state): Enable/disable reflexive subsystem.\n"
    out+="- reflexive_metacog_assess(): Trigger internal metacognitive self-assessment.\n"
    out+="- reflexive_prompt_grade(score, hint): Grade prompt outcome to drive recursive evolution.\n"
    out+="## Cryptocurrency & Web3 Wallets\n"
    out+="- wallet_status(): Query wallet configurations for Bitcoin, Solana, and Cardano.\n"
    out+="- wallet_balances(): Query live balances across BTC, SOL, and ADA.\n"
    out+="- wallet_set_network(network): Switch between mainnet and testnet.\n"
    out+="- crypto_send(chain, to, amount): Execute cryptocurrency transfer.\n"
    out+="- solana_airdrop(amount): Request devnet SOL airdrop.\n"
    out+="## Multimodal AI Vision\n"
    out+="- vision_analyze(image, prompt): Analyze image, chart, or screenshot with AI vision.\n"
    out+="## Background Microservices & Daemons\n"
    out+="- service_list(): List registered microservices, PIDs, ports, and uptime.\n"
    out+="- service_manage(action, name, args): Build, deploy, start, stop, restart, or check logs.\n"
    out+="## Sandboxes & Containers\n"
    out+="- sandbox_create(name): Create isolated workspace sandbox.\n"
    out+="- sandbox_exec(name, command): Execute shell command inside sandbox.\n"
    out+="- sandbox_list(): List active workspace sandboxes.\n"
    out+="- sandbox_remove(name): Delete workspace sandbox.\n"
    out+="- container_exec(command, distro): Run command inside Docker/proot container.\n"
    out+="## Identity Backup & Persistence\n"
    out+="- backup_create(): Create snapshot backup preserving memories, soul, and journals.\n"
    out+="- backup_list(): List all workspace snapshot backups.\n"
    out+="- backup_restore(timestamp): Restore workspace/identity from backup snapshot.\n"
    out+="## Cryptographic Identity & Enterprise\n"
    out+="- pgp_sign(text): Sign text with George isolated PGP key.\n"
    out+="- pgp_verify(signed_text): Verify PGP signed cleartext message.\n"
    out+="- gsuite_search(service, query): Search Gmail messages or Google Drive files.\n"
    out+="## REPL & Model Hyperparameter Controls\n"
    out+="- model_param_set(param, value): Tune sampling parameters (temperature, top_p, etc.).\n"
    out+="- model_param_get(param): Query active model parameters.\n"
    out+="- model_param_clear(param): Reset parameters to endpoint defaults.\n"
    out+="- model_endpoint_switch(tier): Switch active inference tier (Tier 0-3).\n"
    out+="- model_endpoint_status(): Query health, latency, and context across the 4 tiers.\n"
    out+="## Model Context Protocol (MCP) Management\n"
    out+="- mcp_server_status(): List registered and running MCP servers.\n"
    out+="- mcp_server_add(name, command, description): Register a new MCP server.\n"
    out+="- mcp_server_remove(name): Unregister an MCP server.\n"
    out+="- mcp_server_start(name): Start an MCP server process.\n"
    out+="- mcp_server_stop(name): Stop a running MCP server process.\n"
    out+="- mcp_tool_execute(server, tool, arguments): Call an MCP tool directly.\n"
    out+="## Communications & Hardware Swarm\n"
    out+="- email_send(to, subject, body): Send email via pure POSIX SMTP.\n"
    out+="- email_read(count): Read recent inbox emails.\n"
    out+="- phone_sms_send(number, message): Send SMS via Termux Android integration.\n"
    out+="- mqtt_publish(topic, message): Publish payload to MQTT broker.\n"
    out+="- discord_send(target, message): Send message to Discord channel/user.\n"
    out+="- telegram_send(message): Send message via Telegram bot.\n"
    out+="- social_post(network, text): Broadcast to Bluesky, Mastodon, or X.\n"
    out+="- system_vitals(): Live CPU, RAM, thermals, battery, and GPU layer metrics.\n"
    out+="- subagent_delegate(tier, task): Delegate bounded subtask to lower-tier node.\n"
    out+="- slash_command_exec(command): Execute any Blue Lodge slash command natively.\n"
    out+="</tool_manifest>\n\n"

    # 6. MCP Knowledge Injection
    out+="<mcp_knowledge_injection>\n"
    if declare -f mcp_has_servers &>/dev/null && mcp_has_servers; then
        local mcp_stat running_servers
        mcp_stat=$(mcp_status 2>/dev/null)
        running_servers=$(mcp_running_servers 2>/dev/null || echo "")
        out+="Status: Active\n"
        out+="$mcp_stat\n"
        if [ -n "$running_servers" ]; then
            out+="Running Server Details:\n"
            for s in $running_servers; do
                local tools_json
                tools_json=$(mcp_tools_list "$s" 2>/dev/null)
                local tool_names
                tool_names=$(echo "$tools_json" | jq -r '.[].name' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
                [ -z "$tool_names" ] && tool_names="(no tools registered)"
                out+="- Server [$s]: Tools: $tool_names\n"
            done
        fi
    else
        out+="Status: No external MCP servers currently active (all 60 core tools running natively).\n"
    fi
    out+="</mcp_knowledge_injection>\n\n"

    # 7. Agent Swarm Identities
    out+="<agent_swarm_identities>\n"
    out+="The Blue Lodge operates a disciplined multi-agent swarm:\n"
    out+="- The Architect: High-level system planning, decomposition, and roadmap design.\n"
    out+="- The Tyler: Security gatekeeper, prompt injection defense, and sandbox boundary auditor.\n"
    out+="- The Warden: Style author, code aesthetics, and architectural purity reviewer.\n"
    out+="- The Tester: Operational verification, unit and integration test executor.\n"
    out+="- The Chronicler: Documentation steward, maintainer of GEORGE.md and *.md surfaces.\n"
    out+="- Tier 2 Worker (AMD 5700xt 8GB): Parallel worker node for auxiliary tasks.\n"
    out+="- Tier 0 Edge (Termux Mobile): Edge companion node for telemetry, SMS, and local ops.\n"
    out+="When a task benefits from parallel execution or lower latency offloading, use 'subagent_delegate'.\n"
    out+="</agent_swarm_identities>\n\n"

    # 8. Active Skills & Workspace Rules
    out+="<skills_and_instructions>\n"
    local rules_found=0
    if [ -d "$LODGE_DIR/.agents/rules" ]; then
        for r in "$LODGE_DIR/.agents/rules"/*.md; do
            [ -f "$r" ] || continue
            local rname
            rname=$(basename "$r" .md)
            local rfirst
            rfirst=$(grep -v '^#' "$r" | grep -v '^[[:space:]]*$' | head -2 | tr '\n' ' ')
            out+="- Rule [$rname]: $rfirst\n"
            rules_found=1
        done
    fi

    local skills_found=0
    if [ -d "$LODGE_DIR/.agents/skills" ]; then
        for s in "$LODGE_DIR/.agents/skills"/*; do
            [ -d "$s" ] || continue
            local sname
            sname=$(basename "$s")
            local s_desc=""
            if [ -f "$s/SKILL.md" ]; then
                s_desc=$(grep -i '^description:' "$s/SKILL.md" 2>/dev/null | head -1 | sed 's/^description:[[:space:]]*//' | tr -d '"'\''')
            fi
            [ -z "$s_desc" ] && s_desc="Custom skill module"
            out+="- Skill [/$sname]: $s_desc\n"
            skills_found=1
        done
    fi
    [ "$rules_found" -eq 0 ] && [ "$skills_found" -eq 0 ] && out+="(no custom skills or rules detected)\n"
    out+="</skills_and_instructions>\n\n"

    # 9. Project Memory & Active Milestones (GEORGE.md)
    if [ -f "$workdir/GEORGE.md" ]; then
        out+="<project_memory_and_goals>\n"
        local proj_meta active_focus completed_ms
        proj_meta=$(grep -A 5 -i "^## Project\|^## Build" "$workdir/GEORGE.md" 2>/dev/null | head -8)
        active_focus=$(grep -A 10 -i "^## Current Focus\|^## Active Task\|^## Active Milestone" "$workdir/GEORGE.md" 2>/dev/null | head -12)
        completed_ms=$(grep -A 8 -i "^## Completed Milestones" "$workdir/GEORGE.md" 2>/dev/null | head -10)
        [ -n "$proj_meta" ] && out+="$proj_meta\n\n"
        [ -n "$active_focus" ] && out+="$active_focus\n\n"
        [ -n "$completed_ms" ] && out+="$completed_ms\n"
        out+="</project_memory_and_goals>\n\n"
    fi

    # 10. Semantic Recall & Episodic Knowledge Injection
    out+="<semantic_recall_and_journal>\n"
    local recall_injected=0
    if declare -f recall_available &>/dev/null && recall_available; then
        local semantic_notes
        semantic_notes=$(recall_search_context "$goal" 2>/dev/null)
        if [ -n "$semantic_notes" ]; then
            out+="## Recalled Historical Knowledge:\n$semantic_notes\n\n"
            recall_injected=1
        fi
    fi

    if declare -f journal_read &>/dev/null; then
        local recent_journal
        recent_journal=$(journal_read 3 2>/dev/null)
        if [ -n "$recent_journal" ] && [ "$recent_journal" != "(no recent journal entries)" ]; then
            out+="## Recent Journal Reflections:\n$recent_journal\n"
            recall_injected=1
        fi
    fi
    [ "$recall_injected" -eq 0 ] && out+="(no historical recall matches for current query)\n"
    out+="</semantic_recall_and_journal>\n\n"

    # 11. Crypto & Services Status
    out+="<crypto_and_services>\n"
    out+="- Crypto Wallet Network: ${WALLET_NETWORK:-mainnet}\n"
    local srv_dir="${GEORGE_CONFIG_DIR:-$HOME/.george}/services"
    local srv_count=0
    [ -d "$srv_dir" ] && srv_count=$(find "$srv_dir" -name "*.conf" 2>/dev/null | wc -l)
    out+="- Registered Microservices: $srv_count configured\n"
    out+="</crypto_and_services>\n\n"

    # 12. Operational Protocol
    out+="<operational_protocol>\n"
    out+="1. You have native tool calling enabled. When you need information or need to modify files, call the corresponding native tool.\n"
    out+="2. Always verify facts before assuming. Inspect code before modifying it.\n"
    out+="3. Multiple tool calls may be executed sequentially or in parallel.\n"
    out+="4. Once all necessary actions are complete, synthesize your final response directly in clean, readable markdown.\n"
    out+="</operational_protocol>\n"

    printf "%b" "$out"
}

# ── Developer Chat Debug Trace Inspector ──────────────────────────────
# Visualizes the Copilot-style context injection trace with token budget
# telemetry, section-by-section breakdown, and full character inspection.
context_engine_debug_trace() {
    local goal="${1:-General operational inquiry}"
    local workdir="${2:-$PWD}"
    local active_tier="${3:-${ACTIVE_TIER:-1}}"

    local prompt
    prompt=$(context_engine_build "$goal" "$workdir" "$active_tier")

    local char_count=${#prompt}
    local est_tokens=$(( char_count / 4 ))
    local max_context=${ACTIVE_ENDPOINT_CONTEXT:-32768}
    local pct_used=$(( (est_tokens * 100) / max_context ))

    printf "\033[1;36m┌── [George Developer Chat: Context Injection Trace] ──────────────────────────┐\033[0m\n"
    printf "\033[1;36m│\033[0m \033[1;37mTotal Injected Characters:\033[0m %-10d \033[1;37mEstimated Tokens:\033[0m ~%-8d (%d%% of %dk) \033[1;36m│\033[0m\n" \
        "$char_count" "$est_tokens" "$pct_used" "$(( max_context / 1024 ))"
    printf "\033[1;36m│\033[0m \033[1;37mActive Inference Tier:\033[0m     Tier %-2d [%s] (%s) \033[1;36m│\033[0m\n" \
        "$active_tier" "${ACTIVE_ENDPOINT_NAME:-local}" "${ACTIVE_ENDPOINT_MODEL:-default}"
    printf "\033[1;36m│\033[0m \033[1;37mNative Tools Registered:\033[0m   72 core POSIX tools \033[1;36m│\033[0m\n"
    printf "\033[1;36m└──────────────────────────────────────────────────────────────────────────────┘\033[0m\n\n"

    # Print section breakdown
    printf "\033[1;33m--- [Section Hierarchy Breakdown] ---\033[0m\n"
    for tag in developer_instructions active_environment runtime_environments reflexive_intelligence tool_manifest mcp_knowledge_injection agent_swarm_identities skills_and_instructions project_memory_and_goals semantic_recall_and_journal crypto_and_services operational_protocol; do
        local section_content
        section_content=$(echo "$prompt" | awk "/<$tag>/,/<\\/$tag>/" 2>/dev/null)
        local sec_len=${#section_content}
        if [ "$sec_len" -gt 0 ]; then
            printf "  \033[32m✔\033[0m \033[1m%-30s\033[0m %5d chars (~%4d tokens)\n" "<$tag>" "$sec_len" "$(( sec_len / 4 ))"
        else
            printf "  \033[31m✘\033[0m \033[1m%-30s\033[0m     0 chars\n" "<$tag>"
        fi
    done
    printf "\n"

    printf "\033[1;33m--- [Full Injected Prompt Trace] ---\033[0m\n"
    printf "%s\n" "$prompt"
}


