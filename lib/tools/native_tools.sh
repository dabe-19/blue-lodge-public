#!/bin/bash
# ── George: Native POSIX Tool Bridge (2026) ──────────────────────────
# Bridges George's 100% pure POSIX tool catalog (web, social, memory,
# hardware, email, mqtt, mcp, shell) directly to OpenAI/llama-server
# native function-calling JSON schemas and handles dispatch.

[ -n "${_LIB_NATIVE_TOOLS_LOADED:-}" ] && return 0; _LIB_NATIVE_TOOLS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ui/commands.sh" 2>/dev/null || true
commands_load_all 2>/dev/null || true
source "$LODGE_DIR/lib/tools/tools.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/web.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/email.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/mqtt.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/phone.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sys/vitals.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/memory/memory.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/memory/recall.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/memory/journal.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/subagents.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/mcp.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/models.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/reflexive.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/wallet.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sys/sandbox.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sys/container.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sys/backup.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sys/pgp.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/gsuite.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/treesitter.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/pr.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/knowledge/okf.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/model_hub.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/dispatch/crypto.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/dispatch/git_code.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sys/modules.sh" 2>/dev/null || true

# ── Complete POSIX Tool Schemas (OpenAI Function Calling Format) ─────
_NATIVE_SCHEMA_PATH="${LODGE_DIR:-}/data/schemas/native_tools.json"
if [ ! -f "$_NATIVE_SCHEMA_PATH" ]; then
    _NATIVE_SCHEMA_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/data/schemas/native_tools.json"
fi
if [ -f "$_NATIVE_SCHEMA_PATH" ]; then
    _NATIVE_CORE_TOOLS=$(cat "$_NATIVE_SCHEMA_PATH")
else
    _NATIVE_CORE_TOOLS='[]'
fi

# ── Co-Pilot Engine Dependency Gate ──────────────────────────────────
copilot_engine_available() {
    local py_bin=""
    if [ -x "$LODGE_DIR/.venv/bin/python" ]; then
        py_bin="$LODGE_DIR/.venv/bin/python"
    elif command -v python3 &>/dev/null; then
        py_bin="python3"
    else
        return 1
    fi

    local engine_script="$LODGE_DIR/lib/tools/copilot_engine.py"
    [ -f "$engine_script" ] || return 1

    # Verify standard library runtime dependencies
    "$py_bin" -c "import sys, os, re, json, time, subprocess, argparse, pathlib" &>/dev/null || return 1

    return 0
}

# ── Dynamic Schema Aggregator ─────────────────────────────────────────
# Combines core schemas with dynamic tools discovered from running MCP servers
# and conditional Co-Pilot capabilities when dependencies are installed.
native_tools_get_all_schemas() {
    local all_tools="$_NATIVE_CORE_TOOLS"
    local _merged_cache="${MERGED_TOOLS_CACHE:-${GEORGE_DIR:-$LODGE_DIR/.george}/cache/merged_tools.json}"
    if [ -f "$_merged_cache" ] && [ -s "$_merged_cache" ]; then
        all_tools=$(cat "$_merged_cache")
    fi

    # If MCP is enabled and servers are running, convert their tools
    if declare -f mcp_enabled &>/dev/null && mcp_enabled && declare -f mcp_running_servers &>/dev/null; then
        local server_name
        for server_name in $(mcp_running_servers 2>/dev/null); do
            local raw_mcp_tools
            raw_mcp_tools=$(mcp_tools_list "$server_name" 2>/dev/null)
            if [ -n "$raw_mcp_tools" ] && [ "$raw_mcp_tools" != "[]" ]; then
                # Transform MCP tool definitions: {name, description, inputSchema} -> OpenAI function format
                local converted
                converted=$(echo "$raw_mcp_tools" | jq '[
                    .[] | {
                        type: "function",
                        function: {
                            name: .name,
                            description: (.description // ("MCP tool on server " + "'"$server_name"'")),
                            parameters: (.inputSchema // {type: "object", properties: {}})
                        }
                    }
                ]' 2>/dev/null)

                if [ -n "$converted" ] && [ "$converted" != "[]" ]; then
                    all_tools=$(jq -n --argjson c "$all_tools" --argjson m "$converted" '$c + $m' 2>/dev/null || echo "$all_tools")
                fi
            fi
        done
    fi

    # Conditionally mount Co-Pilot pair programming tools ONLY if dependencies are present
    if copilot_engine_available; then
        local copilot_tools='[
            {
                "type": "function",
                "function": {
                    "name": "copilot_patch",
                    "description": "Surgically resolve and apply a code patch using the Co-Pilot AST engine with Deletion Guard. Guarantees zero unintentional deletions of surrounding code.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "file_path": { "type": "string", "description": "Relative or absolute path to the target source file" },
                            "proposed_patch": { "type": "string", "description": "Proposed patch, function replacement, or SEARCH/REPLACE block" },
                            "instruction": { "type": "string", "description": "Short explanation of the edit" }
                        },
                        "required": ["file_path", "proposed_patch"]
                    }
                }
            },
            {
                "type": "function",
                "function": {
                    "name": "copilot_safe_comment",
                    "description": "Inject comments or docstrings into a file using the Co-Pilot AST engine. Guarantees 0 lines of executable code are deleted.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "file_path": { "type": "string", "description": "Path to the target source file" },
                            "instruction": { "type": "string", "description": "Documentation instruction (e.g. Add docstrings to all functions)" }
                        },
                        "required": ["file_path"]
                    }
                }
            },
            {
                "type": "function",
                "function": {
                    "name": "copilot_tool_forge",
                    "description": "Scaffold, validate, chmod +x, and sandbox-test a new tool in lib/tools/ using the Co-Pilot engine.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "name": { "type": "string", "description": "Tool filename (e.g. my_tool.sh or my_probe.py)" },
                            "language": { "type": "string", "description": "Language: bash or python" },
                            "subsystem": { "type": "string", "description": "Target subsystem (e.g. tools, sys, comms)" },
                            "description": { "type": "string", "description": "One-line description of the tool" },
                            "code": { "type": "string", "description": "Full source code of the tool" },
                            "test_args": { "type": "array", "items": { "type": "string" }, "description": "Optional arguments to test-run the tool in the sandbox" }
                        },
                        "required": ["name", "code"]
                    }
                }
            }
        ]'
        all_tools=$(jq -n --argjson c "$all_tools" --argjson cp "$copilot_tools" '$c + $cp' 2>/dev/null || echo "$all_tools")
    fi

    echo "$all_tools" | jq 'unique_by(.function.name)'
}

# ── Dynamic Schema Filter ─────────────────────────────────────────────
# Allows tasks to request a lean, scoped subset of tools (e.g. for research or code editing)
# to minimize context token prefill overhead on local LLMs.
native_tools_get_schemas() {
    local filter="${1:-all}"
    local all_tools
    all_tools=$(native_tools_get_all_schemas)

    local res="$all_tools"
    if [ -n "$filter" ] && [ "$filter" != "all" ]; then
        res=$(echo "$all_tools" | jq --arg f "$filter" '
            ($f | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))) as $allowed |
            [.[] | select(.function.name as $n | $allowed | index($n))]
        ' 2>/dev/null || echo "$all_tools")
    fi

    # Mask ask_operator in non-interactive/autonomous tasks
    if declare -f is_interactive_operator_session &>/dev/null && ! is_interactive_operator_session; then
        res=$(echo "$res" | jq '[.[] | select(.function.name != "ask_operator")]' 2>/dev/null || echo "$res")
    fi

    # Legacy order-placing tools are hidden from George (they bypass the trading policy engine);
    # they remain on the operator CLI. See _GEORGE_HIDDEN_TOOLS.
    res=$(echo "$res" | jq --arg h "$_GEORGE_HIDDEN_TOOLS" '($h | split(",")) as $hid | [.[] | select(.function.name as $n | ($hid | index($n)) | not)]' 2>/dev/null || echo "$res")

    # Mask tools belonging to built-in modules disabled in .george/ecotype_manifest.json
    local _eman="${ECOTYPE_MANIFEST:-${GEORGE_DIR:-$LODGE_DIR/.george}/ecotype_manifest.json}"
    if [ -f "$_eman" ]; then
        local _disabled_pat=""
        local _dex_en _fund_en _sdr_en _tyler_en _cast_en
        _dex_en=$(jq -r 'if .builtins["sovereign-dex"].enabled == false then "false" else "true" end' "$_eman" 2>/dev/null || echo "true")
        _fund_en=$(jq -r 'if .builtins["sovereign-fund"].enabled == false then "false" else "true" end' "$_eman" 2>/dev/null || echo "true")
        _sdr_en=$(jq -r 'if .builtins["sdr-radio-lab"].enabled == false then "false" else "true" end' "$_eman" 2>/dev/null || echo "true")
        _tyler_en=$(jq -r 'if .builtins["the-tyler"].enabled == false then "false" else "true" end' "$_eman" 2>/dev/null || echo "true")
        _cast_en=$(jq -r 'if .builtins["smart-home-cast"].enabled == false then "false" else "true" end' "$_eman" 2>/dev/null || echo "true")
        [ "$_dex_en" = "false" ] && _disabled_pat+="${_disabled_pat:+|}crypto_(scan|plan|execute|backtest|analyze|forecast|chart|standing_order|swap)|cardano_.*|dolos_.*"
        [ "$_fund_en" = "false" ] && _disabled_pat+="${_disabled_pat:+|}polymarket_.*|lending_.*|fund_.*"
        [ "$_dex_en" = "false" ] && [ "$_fund_en" = "false" ] && _disabled_pat+="${_disabled_pat:+|}wallet_.*|crypto_(review|journal|send_ada)"
        [ "$_sdr_en" = "false" ] && _disabled_pat+="${_disabled_pat:+|}sdr_.*"
        [ "$_tyler_en" = "false" ] && _disabled_pat+="${_disabled_pat:+|}tyler_.*"
        [ "$_cast_en" = "false" ] && _disabled_pat+="${_disabled_pat:+|}google_home_.*"
        if [ -n "$_disabled_pat" ]; then
            res=$(echo "$res" | jq --arg pat "^(${_disabled_pat})$" '[.[] | select((.function.name | test($pat)) | not)]' 2>/dev/null || echo "$res")
        fi
    fi

    echo "$res"
}

# Tools George must not see or call: every trade goes through crypto_plan -> crypto_execute
# (policy tiers + operator confirmation). crypto_send moves funds off-wallet (Tier C: never).
_GEORGE_HIDDEN_TOOLS="cardano_dex_swap,cardano_stop_manage,crypto_order,cardano_order_tool,cardano_triangle_deploy,crypto_triangle_deploy,cardano_flash_sniper,crypto_place_limit,crypto_reclaim_order,crypto_price_ladder,crypto_orders,cardano_desk_summary,crypto_desk_summary,crypto_send"

# Returns a refusal reason if a bash_exec command would bypass the trading policy engine
# (operator-only confirm path, policy/ledger writes, direct order submission). This is a
# speed bump, not a sandbox: the hard limits are the wallet spending policy and the confirm
# token, which needs a real operator Discord message or the web secret.
_trading_bash_guard() {
    local c="$1"
    if [[ "$c" =~ agent_tools\.py.*confirm ]] || [[ "$c" =~ trading_confirm\.key ]] || [[ "$c" =~ TRADING_WEB_CONFIRM_SECRET ]]; then
        echo "the trading confirm path is operator-only: ask the operator to reply 'confirm <plan_id>'"; return 0
    fi
    if [[ "$c" =~ gates\.py.*(unfreeze|set-state) ]] || [[ "$c" =~ escalation\.py.*(set-quiet-hours|quiet[[:space:]]+--|--disable|--enable|--enabled) ]]; then
        echo "gate, freeze, and quiet-hours overrides are operator-only: propose an unlock with crypto_plan (Tier B)"; return 0
    fi
    if [[ "$c" =~ (trading\.db|escalations\.db) ]]; then
        echo "trading.db / escalations.db are managed by the trading tools: use crypto_journal / crypto_review"; return 0
    fi
    if [[ "$c" =~ (trading_policy\.json|cardano_mode\.conf|wallet/policy\.json|features\.conf) ]] && [[ "$c" =~ ([>]|sed[[:space:]]+-i|tee|mv[[:space:]]|cp[[:space:]]|rm[[:space:]]|truncate|perl|python|dd[[:space:]]|install[[:space:]]) ]]; then
        echo "trading policy files are Tier C: only the operator edits them"; return 0
    fi
    if [[ "$c" =~ (minswap_v2|cardano_orders|cardano_dex_swapper|cardano_order_tool|cardano_stop_engine|cardano_trader|cardano_triangle_deploy|cardano_flash_sniper|polygon_swapper|cardano_order_canceller|cardano_stale_reclaimer)\.py ]] && [[ "$c" =~ (--execute|--live|[[:space:]]execute|reclaim|cancel|swap) ]]; then
        echo "direct order submission bypasses the policy engine: use crypto_plan then crypto_execute"; return 0
    fi
    if [[ "$c" =~ /trading[[:space:]]+(order|orders|ucom|triangle|coverage|deploy-triangle|eth|ethereum|maker|limit|market-maker|stops|stop|bracket|cancel|reclaim|refund|mode|stale|graph|sweep|swap|sniper|flash|loop|autonomic|coint-reactor|reactor)([[:space:]]|$) ]]; then
        echo "order-placing /trading subcommands are operator-only now: use crypto_plan then crypto_execute"; return 0
    fi
    return 1
}

# ── Composable Tool Bundles & Bedrock Taxonomy ────────────────────────
_BEDROCK_TOOLS="bash_exec,slash_command_exec,phytology_manage,file_read,file_write,file_edit,file_append,pdf_read,recall_search,journal_read,journal_record,sdr_query,sdr_listen,tyler_lan_census,tyler_deep_fingerprint,tyler_traffic_inspect,tyler_vuln_audit,tyler_upnp_audit,tyler_set_trust,tyler_intervene,tyler_canary_trap,tyler_tshark_watch,tyler_immune_patrol,tyler_arp_shield,tyler_baseline_diff,tyler_kali_man,tyler_kali_exec,tyler_spelunk,tyler_wifi_spelunk,google_home_speak,workflow_plan,workflow_run,ask_operator,task_wait,tool_search,milestone_complete,subagent_spawn,subagent_status,subagent_await,subagent_reap"

# ── Bedrock Tools Appendix for messages[1] ───────────────────────────
native_tools_bedrock_appendix() {
    local out=""
    out+="<bedrock_tools>\n"
    out+="The following core Bedrock tools are permanently mounted and available across all execution phases:\n"
    if declare -f native_tools_get_schemas &>/dev/null; then
        local b_schemas
        local bedrock_list="bash_exec,slash_command_exec,file_read,file_write,file_edit,file_append,file_grep,dir_list,recall_search,journal_read,journal_record,sdr_query,sdr_listen,tyler_lan_census,tyler_deep_fingerprint,tyler_traffic_inspect,tyler_vuln_audit,tyler_upnp_audit,tyler_set_trust,tyler_intervene,tyler_canary_trap,tyler_tshark_watch,tyler_immune_patrol,tyler_arp_shield,tyler_baseline_diff,tyler_kali_man,tyler_kali_exec,tyler_spelunk,tyler_wifi_spelunk,google_home_speak,tool_search,milestone_complete"
        if declare -f is_interactive_operator_session &>/dev/null && is_interactive_operator_session; then
            bedrock_list="bash_exec,slash_command_exec,file_read,file_write,file_edit,file_append,file_grep,dir_list,recall_search,journal_read,journal_record,sdr_query,sdr_listen,tyler_lan_census,tyler_deep_fingerprint,tyler_traffic_inspect,tyler_vuln_audit,tyler_upnp_audit,tyler_set_trust,tyler_intervene,tyler_canary_trap,tyler_tshark_watch,tyler_immune_patrol,tyler_arp_shield,tyler_baseline_diff,tyler_kali_man,tyler_kali_exec,tyler_spelunk,tyler_wifi_spelunk,google_home_speak,ask_operator,tool_search,milestone_complete"
        fi
        b_schemas=$(native_tools_get_schemas "$bedrock_list" 2>/dev/null)
        if [ -n "$b_schemas" ] && [ "$b_schemas" != "[]" ]; then
            out+=$(echo "$b_schemas" | jq -r '.[] | "- " + .function.name + "(" + (((.function.parameters.properties // {}) | keys_unsorted | .[0:4]) | join(", ")) + (if (((.function.parameters.properties // {}) | keys_unsorted | length) > 4) then ", ..." else "" end) + "): " + ((.function.description // "") | split(". ")[0] | split("\n")[0])' 2>/dev/null)
            out+="\n"
        fi
    fi
    out+="</bedrock_tools>"
    printf "%b" "$out"
}

# Map bundles to their constituent tool names
native_tools_bundle_tools() {
    local bundle="$1"
    case "$bundle" in
        bedrock|_bedrock)
            echo "$_BEDROCK_TOOLS"
            ;;
        +web|web)
            echo "web_search,web_search_cross_section,web_fetch,research_sandbox,github_search,searxng_search,searxng_code_search,searxng_science_search,arxiv_search,hn_search,api_search"
            ;;
        +files|files)
            echo "file_write,file_append,file_edit,file_grep,dir_list,artifact_publish"
            ;;
        +code|code)
            local _code_tools="project_build,project_test,project_fix,code_outline,code_symbol_get,code_validate,code_symbol_read,code_symbol_patch,okf_search,okf_query,okf_traverse,tool_forge,venv_pkg_install"
            if copilot_engine_available; then
                _code_tools="${_code_tools},copilot_patch,copilot_safe_comment,copilot_tool_forge"
            fi
            echo "$_code_tools"
            ;;
        +copilot|copilot)
            if copilot_engine_available; then
                echo "copilot_patch,copilot_safe_comment,copilot_tool_forge"
            else
                echo ""
            fi
            ;;
        +git|git)
            echo "git_commit,git_push,gitea_branch_create,gitea_issue_create,gitea_issue_list,gitea_issue_get,gitea_issue_close,gitea_issue_comment,gitea_pr_create,gitea_pr_list,gitea_pr_get,gitea_pr_review,gitea_pr_merge,pr_audit,git_clone"
            ;;
        +vision|vision)
            echo "vision_analyze,reverse_image_search,file_download,sdr_query,sdr_listen"
            ;;
        +sdr|sdr)
            echo "sdr_query,sdr_listen"
            ;;
        +social|social)
            local _soc_tools="discord_send,discord_edit,discord_dm,discord_send_file,artifact_publish,discord_read,mqtt_publish,sdr_query,sdr_listen,google_home_speak,google_home_discover,google_home_volume"
            if declare -f social_provider_configured &>/dev/null; then
                if social_provider_configured x || social_provider_configured mastodon || social_provider_configured bluesky; then
                    _soc_tools="social_post,${_soc_tools}"
                fi
                if [ "${_DISCORD_IN_SESSION:-0}" != "1" ] && social_provider_configured telegram; then
                    _soc_tools="${_soc_tools},telegram_send"
                fi
            fi
            if declare -f email_list_configured &>/dev/null && [ -n "$(email_list_configured 2>/dev/null)" ]; then
                _soc_tools="${_soc_tools},email_send,email_read"
            fi
            if declare -f phone_available &>/dev/null && phone_available 2>/dev/null; then
                _soc_tools="${_soc_tools},phone_sms_send"
            fi
            echo "$_soc_tools"
            ;;
        +ops|ops)
            echo "system_vitals,sandbox_create,sandbox_exec,sandbox_list,sandbox_remove,container_exec,service_manage,service_list,backup_create,backup_list,backup_restore,pgp_sign,pgp_verify,venv_pkg_install,tool_forge,artifact_publish,tyler_lan_census,tyler_deep_fingerprint,tyler_traffic_inspect,tyler_vuln_audit,tyler_upnp_audit,tyler_set_trust,tyler_intervene,tyler_canary_trap,tyler_tshark_watch,tyler_immune_patrol,tyler_arp_shield,tyler_baseline_diff,tyler_kali_man,tyler_kali_exec,tyler_spelunk,tyler_wifi_spelunk,google_home_speak,google_home_discover,google_home_volume"
            ;;
        +tyler|tyler|+kali|kali)
            echo "tyler_lan_census,tyler_deep_fingerprint,tyler_traffic_inspect,tyler_vuln_audit,tyler_upnp_audit,tyler_set_trust,tyler_intervene,tyler_canary_trap,tyler_tshark_watch,tyler_immune_patrol,tyler_arp_shield,tyler_baseline_diff,tyler_kali_man,tyler_kali_exec,tyler_spelunk,tyler_wifi_spelunk,google_home_speak,google_home_discover"
            ;;
        +cast|cast)
            echo "google_home_speak,google_home_discover,google_home_volume"
            ;;
        +memory|memory)
            echo "recall_search,recall_ingest,recall_list_docs,recall_archive_milestone,journal_record,journal_read,memory_get_section,memory_update_section,memory_append_section,memory_read_soul,okf_search,okf_query,okf_traverse"
            ;;
        +crypto|crypto)
            echo "wallet_status,wallet_balances,wallet_receive,wallet_send_preview,crypto_review,crypto_scan,crypto_plan,crypto_execute,crypto_standing_order,crypto_journal,crypto_backtest,operator_notify,operator_ask,crypto_analyze,crypto_forecast,crypto_chart,crypto_orders,crypto_place_limit,crypto_reclaim_order,pool_health,cardano_p2p_underwrite,polymarket_arbitrage,polymarket_scan,wallet_set_network,fund_treasury,fund_opportunities,fund_state,fund_ledger_add,lending_underwrite,lending_request,lending_service,lending_book"
            ;;
        +swarm|swarm)
            echo "subagent_delegate,subagent_spawn,subagent_status,subagent_logs,subagent_diff,subagent_merge,subagent_reap,subagent_intervene,subagent_await"
            ;;
        +models|models)
            echo "model_param_set,model_param_get,model_param_clear,model_endpoint_switch,model_endpoint_status,reflexive_status,reflexive_toggle,reflexive_metacog_assess,reflexive_prompt_grade"
            ;;
        +gsuite|gsuite)
            echo "gsuite_search"
            ;;
        +hub|hub)
            echo "hub_hw_probe,hub_library,hub_search,hub_inspect,hub_quant_fit,hub_profile_draft,hub_profiles"
            ;;
        +phytology|phytology)
            echo "phytology_manage"
            ;;
        research)
            echo "$(native_tools_bundle_tools '+web'),$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+vision'),$(native_tools_bundle_tools '+memory')"
            ;;
        code|coding)
            echo "$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+code'),$(native_tools_bundle_tools '+git')"
            ;;
        ops)
            echo "$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+ops'),$(native_tools_bundle_tools '+memory')"
            ;;
        social)
            echo "$(native_tools_bundle_tools '+web'),$(native_tools_bundle_tools '+social'),$(native_tools_bundle_tools '+memory'),$(native_tools_bundle_tools '+vision')"
            ;;
        default)
            echo "$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+git'),$(native_tools_bundle_tools '+web'),$(native_tools_bundle_tools '+sdr')"
            ;;
        +mcp_*|mcp_*)
            local s_name="${bundle#+mcp_}"
            s_name="${s_name#mcp_}"
            if declare -f mcp_tools_list &>/dev/null; then
                mcp_tools_list "$s_name" 2>/dev/null | jq -r '.[].name // empty' 2>/dev/null | tr '\n' ',' | sed 's/,$//'
            fi
            ;;
        +*)
            local _mt_map="${GEORGE_DIR:-$LODGE_DIR/.george}/cache/module_tool_map.json"
            if [ -f "$_mt_map" ] && command -v jq &>/dev/null; then
                jq -r --arg b "$bundle" --arg mid "${bundle#+}" 'to_entries[] | select(.value.bundle == $b or .value.module_id == $mid) | .key' "$_mt_map" 2>/dev/null | tr '\n' ',' | sed 's/,$//'
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

# ── Zero-Latency Task Classifier ──────────────────────────────────────
# Inspects objective keywords to resolve optimal starting profile (~22-48 tools).
# Supports multi-domain union (capped at 56 tools).
native_tools_classify_profile() {
    local goal="${1:-}"
    [ -z "$goal" ] && { echo "default"; return 0; }

    local g_lower="${goal,,}"
    local is_research=0
    local is_code=0
    local is_ops=0
    local is_social=0
    local is_crypto=0

    # Domain Pattern Matching
    if echo "$g_lower" | grep -qiE '\b(research|investigate|intel|financial|background|who is|what is|find out|news|article|articles|source|sources|look up|search for|fetch|survey|overview of|profile on|history of|summary of|browse|scout|track|due diligence|public record|osint|paper|arxiv|cve|sdr|radio|scanner|talkgroup|tgid|p25|dispatch|m4a|metro|county|county|springfield|county ems|sheriff)\b'; then
        is_research=1
    fi

    if echo "$g_lower" | grep -qiE '\b(code|implement|refactor|fix|bug|feature|test|tests|build|compile|cargo|npm|git|commit|patch|function|class|module|syntax|lint|debug|repo|repository|pr|pull request|script|unit test)\b'; then
        is_code=1
    fi

    if echo "$g_lower" | grep -qiE '\b(deploy|docker|container|containers|service|services|cron|daemon|vitals|sandbox|process|processes|backup|restart|hardware|gpu|server|pgp|tyler|kali|lan|subnet|nmap|tshark|upnp|firewall|quarantine|fingerprint|roomba)\b'; then
        is_ops=1
    fi

    if echo "$g_lower" | grep -qiE '\b(discord|tweet|twitter|x_post|telegram|email|mail|sms|social|message|post to)\b'; then
        is_social=1
    fi

    if echo "$g_lower" | grep -qiE '\b(crypto|wallet|wallets|cardano|ada|polymarket|arbitrage|swap|dex|underwrite|sniper|p2p|bitcoin|btc|solana|sol|polygon|usdc|token|tokens|yield|loan|borrow|lending|oco|stop buy|stop order|limit order|reclaim order|price ladder|market maker|positions|inventory|standing order|corridor|corridors|markout|backtest|recalibrate|recalibration|shock fade|minswap|night|snek|iag|wmtx|djed|usdm|s2|s3|confirm p-[0-9a-f]+)\b'; then
        is_crypto=1
    fi

    # Dynamic Enabled-Module Bundle Detection:
    # Mount +<module_bundle> directly on Turn 1 ONLY when LODGE_ACTIVE_MODULE targets that module
    # or the goal matches the module's declared domain_keywords in .george/cache/module_tool_map.json.
    local _mod_bundles=""
    local _mt_map="${GEORGE_DIR:-$LODGE_DIR/.george}/cache/module_tool_map.json"
    if [ -f "$_mt_map" ] && command -v python3 &>/dev/null; then
        _mod_bundles=$(python3 - "$_mt_map" "${LODGE_ACTIVE_MODULE:-}" "$goal" <<'PY' 2>/dev/null
import json, re, sys
map_path, active_mod, goal = sys.argv[1], sys.argv[2].strip(), sys.argv[3]
try:
    tmap = json.load(open(map_path, "r", encoding="utf-8"))
except Exception:
    sys.exit(0)
by_mod = {}
for meta in tmap.values():
    mid = meta.get("module_id") or ""
    if not mid or mid in by_mod:
        continue
    by_mod[mid] = (meta.get("bundle") or f"+{mid}", meta.get("keywords") or "")
out = []
for mid, (bundle, kws) in by_mod.items():
    matched = False
    if active_mod:
        matched = (active_mod == mid)
    elif kws and goal:
        toks = [t.strip() for t in re.split(r"[\s,|]+", str(kws)) if len(t.strip()) >= 3]
        if toks:
            kw_re = r"\b(?:" + "|".join(re.escape(t) for t in toks) + r")\b"
            try:
                if re.search(kw_re, goal, re.IGNORECASE):
                    matched = True
            except re.error:
                pass
    if matched:
        if bundle not in out:
            out.append(bundle)
        if mid in ("poshtracker", "hunting-buddy") and "+vision" not in out:
            out.append("+vision")
print(",".join(out))
PY
)
    fi

    # Single-domain primary profile matching (only when no module bundles need appending)
    local domain_count=$((is_research + is_code + is_ops + is_social + is_crypto))
    if [ "$domain_count" -eq 1 ] && [ -z "$_mod_bundles" ]; then
        [ "$is_research" -eq 1 ] && { echo "research"; return 0; }
        [ "$is_code" -eq 1 ] && { echo "code"; return 0; }
        [ "$is_ops" -eq 1 ] && { echo "ops"; return 0; }
        [ "$is_crypto" -eq 1 ] && { echo "crypto"; return 0; }
        [ "$is_social" -eq 1 ] && { echo "social"; return 0; }
    fi

    # Composable multi-domain bundle resolution (capped at 56 tools preserving Bedrock)
    local bundles=()
    [ "$is_research" -eq 1 ] && bundles+=("research")
    if [ "$is_code" -eq 1 ]; then
        if [ ${#bundles[@]} -eq 0 ]; then bundles+=("code"); else bundles+=("+code"); fi
    fi
    if [ "$is_ops" -eq 1 ]; then
        if [ ${#bundles[@]} -eq 0 ]; then bundles+=("ops"); else bundles+=("+ops"); fi
    fi
    [ "$is_social" -eq 1 ] && bundles+=("+social")
    [ "$is_crypto" -eq 1 ] && bundles+=("+crypto")

    if [ -n "$_mod_bundles" ]; then
        if [ -n "${LODGE_ACTIVE_MODULE:-}" ]; then
            # Dedicated module task: use razor-sharp bedrock + files + web + active module bundles ONLY
            bundles=("bedrock" "+files" "+web")
        elif [ ${#bundles[@]} -eq 0 ]; then
            bundles+=("default")
        fi
        local _mb
        IFS=',' read -ra _mb_arr <<< "$_mod_bundles"
        for _mb in "${_mb_arr[@]}"; do
            [ -n "$_mb" ] && bundles+=("$_mb")
        done
    fi

    if [ ${#bundles[@]} -eq 0 ]; then
        local _cgr_py="$LODGE_DIR/lib/tools/capability_graph_router.py"
        if [ -f "$_cgr_py" ] && command -v python3 &>/dev/null; then
            local _graph_prof
            _graph_prof=$(LODGE_DIR="$LODGE_DIR" python3 "$_cgr_py" classify-profile "$goal" 2>/dev/null || echo "default")
            [ -n "$_graph_prof" ] && { echo "$_graph_prof"; return 0; }
        fi
        echo "default"
    else
        local res=""
        for b in "${bundles[@]}"; do
            [ -z "$res" ] && res="$b" || res="$res, $b"
        done
        echo "$res"
    fi
}

# ── Capability Graph & Contextual-Bandit Tool Ranker ──────────────────
native_tools_graph_rank() {
    local query="$1"
    local budget_ms="${2:-2500}"
    local _cgr_py="$LODGE_DIR/lib/tools/capability_graph_router.py"
    [ -f "$_cgr_py" ] || return 1
    native_tools_fts_init 0
    _LODGE_TOOLS_FTS_DB="$_LODGE_TOOLS_FTS_DB" LODGE_DIR="$LODGE_DIR" \
        python3 "$_cgr_py" rank-tools "$query" --latency-budget "$budget_ms" --json
}

# ── Profile Resolver ──────────────────────────────────────────────────
# Resolves preset profile names or composable bundles into full schemas.
# Enforces configurable 56-tool ceiling (MAX_PROFILE_TOOLS) preserving Bedrock primacy.
native_tools_resolve_profile() {
    local profile="${1:-default}"
    local goal_ctx="${2:-}"
    local tool_list="$_BEDROCK_TOOLS"

    case "$profile" in
        worker|sandbox_worker)
            tool_list="bash_exec,file_read,file_write,file_edit,file_append,file_grep,dir_list,code_outline,code_symbol_get,code_symbol_read,code_symbol_patch,code_validate,okf_search,okf_query,okf_traverse,git_commit,git_push,gitea_pr_create,milestone_complete"
            ;;
        worker_research)
            tool_list="bash_exec,file_read,file_grep,dir_list,okf_search,okf_query,okf_traverse,web_search,web_fetch,github_search,sdr_query,sdr_listen,milestone_complete"
            ;;
        remediation)
            tool_list="${_BEDROCK_TOOLS},$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+code'),$(native_tools_bundle_tools '+git'),$(native_tools_bundle_tools '+ops'),$(native_tools_bundle_tools '+memory')"
            ;;
        research)
            tool_list+=",$(native_tools_bundle_tools '+web'),$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+vision'),$(native_tools_bundle_tools '+memory')"
            ;;
        research_refiner)
            tool_list="bash_exec,file_read,file_write,file_edit,file_append,file_grep,dir_list,pdf_read,arxiv_search,searxng_science_search,searxng_search,web_search,web_fetch,github_search,sdr_query,sdr_listen,ask_operator,milestone_complete"
            ;;
        code|coding)
            tool_list+=",$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+code'),$(native_tools_bundle_tools '+git')"
            ;;
        pr_reviewer|reviewer)
            # Read-only code inspection + OKF blast-radius graph + formal Gitea PR review/comment tools (no merge, no file writes, no bash_exec)
            tool_list="file_read,file_grep,dir_list,code_outline,code_symbol_get,code_symbol_read,okf_search,okf_query,okf_traverse,gitea_pr_get,gitea_pr_review,gitea_issue_comment,milestone_complete"
            ;;
        social)
            tool_list="${_BEDROCK_TOOLS},$(native_tools_bundle_tools '+social'),$(native_tools_bundle_tools '+vision'),$(native_tools_bundle_tools '+web'),$(native_tools_bundle_tools '+memory')"
            ;;
        social_untrusted|untrusted_social)
            # Discord authors without trust (not owner, reputation below threshold):
            # chat + safe read-only research tools + in-channel Discord reply tools only.
            # Strictly NO bedrock write tools (bash_exec, file_write/file_edit/file_append, slash, subagents, ops, crypto)
            # and NO external broadcast/impersonation tools (no social_post, email_send, telegram_send, phone_sms_send, discord_dm, mqtt_publish).
            tool_list="file_read,dir_list,file_grep,pdf_read,sdr_query,sdr_listen,ask_operator,milestone_complete,discord_send,discord_edit,discord_send_file,discord_read,$(native_tools_bundle_tools '+vision'),$(native_tools_bundle_tools '+web'),$(native_tools_bundle_tools '+memory')"
            ;;
        social+ops|social_ops|social+engineer)
            tool_list="${_BEDROCK_TOOLS},$(native_tools_bundle_tools '+social'),$(native_tools_bundle_tools '+vision'),$(native_tools_bundle_tools '+web'),$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+code'),$(native_tools_bundle_tools '+git'),$(native_tools_bundle_tools '+ops'),$(native_tools_bundle_tools '+memory')"
            ;;
        social+crypto|crypto+social)
            tool_list="${_BEDROCK_TOOLS},$(native_tools_bundle_tools '+social'),$(native_tools_bundle_tools '+vision'),$(native_tools_bundle_tools '+crypto'),$(native_tools_bundle_tools '+web')"
            ;;
        social+ops+crypto|social+crypto+ops|crypto+social+ops)
            tool_list="${_BEDROCK_TOOLS},$(native_tools_bundle_tools '+social'),$(native_tools_bundle_tools '+vision'),$(native_tools_bundle_tools '+crypto'),$(native_tools_bundle_tools '+ops'),$(native_tools_bundle_tools '+web')"
            ;;
        crypto)
            tool_list="${_BEDROCK_TOOLS},$(native_tools_bundle_tools '+crypto'),$(native_tools_bundle_tools '+web')"
            ;;
        escalation)
            # Headless escalation writer (lib/comms/escalation_reactor.sh): read-only trading tools,
            # crypto_plan and the operator channel. No shell, no files, no crypto_execute.
            tool_list="crypto_review,crypto_scan,crypto_plan,crypto_journal,operator_notify,operator_ask,milestone_complete"
            ;;
        ops)
            tool_list+=",$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+ops'),$(native_tools_bundle_tools '+memory'),$(native_tools_bundle_tools '+sdr')"
            ;;
        swarm)
            tool_list+=",$(native_tools_bundle_tools '+swarm'),$(native_tools_bundle_tools '+social'),$(native_tools_bundle_tools '+ops')"
            ;;
        minimal|bedrock)
            tool_list="$_BEDROCK_TOOLS"
            ;;
        model_hub)
            # Model Copilot: research + hub math + draft only. No shell, no file writes, no downloads.
            tool_list="$(native_tools_bundle_tools '+hub'),web_search,web_fetch,searxng_search,ask_operator,milestone_complete"
            ;;
        all)
            echo "$(native_tools_get_all_schemas)"
            return 0
            ;;
        default|"")
            tool_list="bash_exec,slash_command_exec,phytology_manage,file_read,file_write,file_edit,file_append,pdf_read,sdr_query,sdr_listen,workflow_plan,workflow_run,ask_operator,task_wait,tool_search,milestone_complete,web_search,web_fetch,git_commit,git_push,file_grep,dir_list"
            ;;
        *)
            local item
            IFS=',' read -ra ADDR <<< "$profile"
            for item in "${ADDR[@]}"; do
                item=$(echo "$item" | tr -d ' ')
                local b_tools
                b_tools=$(native_tools_bundle_tools "$item")
                if [ -n "$b_tools" ]; then
                    tool_list+=",$b_tools"
                else
                    tool_list+=",$item"
                fi
            done
            ;;
    esac

    # Priority-mount ALP v1 workflow bundles/allowlists and active/keyword-matched module tools
    # BEFORE enforcing MAX_PROFILE_TOOLS so module tools are mounted immediately on Turn 1
    # (preventing wasted tool_search turns in module workflows and Discord).
    local priority_tools=""
    local _mt_map="${GEORGE_DIR:-$LODGE_DIR/.george}/cache/module_tool_map.json"

    if [ -n "${LODGE_LOOP_BUNDLES:-}" ]; then
        local _lb _lb_tools
        IFS=',' read -ra _lb_arr <<< "$LODGE_LOOP_BUNDLES"
        for _lb in "${_lb_arr[@]}"; do
            _lb=$(echo "$_lb" | tr -d ' ')
            [ -z "$_lb" ] && continue
            _lb_tools=$(native_tools_bundle_tools "$_lb")
            [ -n "$_lb_tools" ] && priority_tools="${priority_tools:+$priority_tools,}${_lb_tools}"
        done
    fi

    if [ -n "${LODGE_LOOP_TOOLS_ALLOW:-}" ]; then
        priority_tools="${priority_tools:+$priority_tools,}${LODGE_LOOP_TOOLS_ALLOW}"
    fi

    if [ -f "$_mt_map" ] && command -v python3 &>/dev/null; then
        local _is_restricted=0
        case "$profile" in
            social_untrusted|untrusted_social|escalation|pr_reviewer|reviewer|model_hub|worker|sandbox_worker|worker_research)
                _is_restricted=1
                ;;
        esac
        if [ -n "${LODGE_ACTIVE_MODULE:-}" ] || { [ "$_is_restricted" -eq 0 ] && [ -n "$goal_ctx" ]; }; then
            local _mod_prio
            _mod_prio=$(python3 - "$_mt_map" "${LODGE_ACTIVE_MODULE:-}" "$goal_ctx" <<'PY' 2>/dev/null
import json, re, sys
map_path, active_mod, ctx_text = sys.argv[1], sys.argv[2].strip(), sys.argv[3]
try:
    tmap = json.load(open(map_path, "r", encoding="utf-8"))
except Exception:
    sys.exit(0)
by_mod = {}
for tname, meta in tmap.items():
    mid = meta.get("module_id") or ""
    if not mid:
        continue
    ent = by_mod.setdefault(mid, {"tools": [], "keywords": "", "core_tools": []})
    ent["tools"].append(tname)
    if meta.get("keywords") and not ent["keywords"]:
        ent["keywords"] = meta["keywords"]
    if meta.get("core_tools") and not ent["core_tools"]:
        ent["core_tools"] = list(meta["core_tools"])
out = []
for mid, ent in by_mod.items():
    matched = False
    if active_mod:
        matched = (active_mod == mid)
    elif ent["keywords"] and ctx_text:
        toks = [t.strip() for t in re.split(r"[\s,|]+", str(ent["keywords"])) if len(t.strip()) >= 3]
        if toks:
            kw_re = r"\b(?:" + "|".join(re.escape(t) for t in toks) + r")\b"
            try:
                if re.search(kw_re, ctx_text, re.IGNORECASE):
                    matched = True
            except re.error:
                pass
    if matched:
        out.extend(ent["tools"])
        for ct in ent["core_tools"]:
            if ".*" not in ct:
                out.append(ct)
seen = set()
uniq = [x for x in out if x and not (x in seen or seen.add(x))]
print(",".join(uniq))
PY
)
            [ -n "$_mod_prio" ] && priority_tools="${priority_tools:+$priority_tools,}${_mod_prio}"
        fi
    fi

    if [ -n "$priority_tools" ]; then
        tool_list="${priority_tools},${tool_list}"
    fi

    # Enforce 76-tool maximum ceiling on initial profile resolution (configurable via MAX_PROFILE_TOOLS)
    local max_tools="${MAX_PROFILE_TOOLS:-76}"
    local unique_tools
    unique_tools=$(echo "$tool_list" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | awk '!seen[$0]++' | head -n "$max_tools" | tr '\n' ',' | sed 's/,$//')

    if [ -n "${LODGE_LOOP_TOOLS_DENY:-}" ]; then
        local _deny_re
        _deny_re=$(printf '%s' "$LODGE_LOOP_TOOLS_DENY" | tr ',' '|' | sed -E 's/^\|+//; s/\|+$//; s/\|+/|/g')
        if [ -n "$_deny_re" ]; then
            unique_tools=$(echo "$unique_tools" | tr ',' '\n' | grep -vxE "$_deny_re" | tr '\n' ',' | sed 's/,$//')
        fi
    fi

    if declare -f is_interactive_operator_session &>/dev/null && ! is_interactive_operator_session; then
        unique_tools=$(echo "$unique_tools" | tr ',' '\n' | grep -vx 'ask_operator' | tr '\n' ',' | sed 's/,$//')
    fi

    native_tools_get_schemas "$unique_tools"
}

# ── Domain Keyword Tags for High-Precision BM25 Matching ──────────────
native_tools_domain_tags() {
    case "$1" in
        web_search) echo "web search internet google query research paper arxiv browse find online" ;;
        web_search_cross_section) echo "web search cross section sample diverse creative articles semantic perspectives balanced non-greedy" ;;
        searxng_search) echo "searxng search metasearch google bing duckduckgo brave wikipedia ebay web query keyless" ;;
        searxng_code_search) echo "code search github gitlab stackoverflow crates pypi npm arch wiki mdn docker repos technical it" ;;
        searxng_science_search) echo "science academic research papers arxiv pubmed crossref google scholar semantic citations preprints" ;;
        arxiv_search) echo "arxiv science academic preprint research papers citations pdf math physics cs biology literature primary" ;;
        hn_search) echo "hackernews hn news ycombinator discussion tech practitioner comments community discourse algolia" ;;
        api_search) echo "api search public apis rest endpoint catalog data source weather geocoding currency finance keyless free" ;;
        research_sandbox) echo "research sandbox dossier deep web scrape non-greedy cross-section multi-domain recurring intel report autonomous" ;;
        web_fetch) echo "web fetch scrape read download url html page article preprint source" ;;
        github_search) echo "github code search repo repository open source git implementation" ;;
        vision_analyze) echo "vision image photo diagram figure chart architecture visual inspect picture" ;;
        reverse_image_search) echo "reverse image search visual lookup mobileclip dinov2 onnx photos identify pictures camera" ;;
        sdr_query) echo "sdr radio p25 scanner talkgroup tgid unit dispatch frequency mhz county city sheriff police fire ems ambulance medic stats statistics database calls narrative" ;;
        sdr_listen) echo "sdr listen audio m4a wav radio p25 recording transcribe encoder whisper gemma multimodal replay call" ;;
        file_download) echo "download file curl wget fetch binary pdf image raw" ;;
        git_commit|git_push|git_clone) echo "git commit push clone repo branch code vcs version control" ;;
        gitea_pr_create|gitea_pr_list|gitea_pr_get|gitea_pr_review|gitea_pr_merge|gitea_issue_create|gitea_issue_list|gitea_issue_get|gitea_issue_close|gitea_issue_comment|gitea_branch_create|pr_audit) echo "pr pull request merge gitea issue issues bug fix branch review code audit" ;;
        social_post) echo "social post broadcast x twitter mastodon bluesky thread status publish tweet" ;;
        discord_send|discord_edit|discord_dm|discord_send_file|discord_read) echo "discord channel message alert notification chat send dm webhook file image upload attachment history read edit update revise" ;;
        artifact_publish) echo "artifact publish upload save archive persist png jpg pdf chart map diagram image file script version discord channel pantry" ;;
        venv_pkg_install) echo "python pip uv venv package install library module dependency matplotlib shapely pyproj geopandas pypdf scipy supply chain osv sha256 audit allowlist" ;;
        tool_forge) echo "forge craft custom tool plugin script python bash ast audit smoke test register workshop self extend" ;;
        telegram_send) echo "telegram chat message alert notification channel send" ;;
        email_send|email_read) echo "email mail message inbox smtp letter imap send" ;;
        system_vitals) echo "vitals cpu memory gpu hardware status monitoring load thermal resources" ;;
        sandbox_create|sandbox_exec) echo "sandbox isolate docker container environment run execute" ;;
        container_exec) echo "container docker exec sandbox run command isolated" ;;
        wallet_status|wallet_balances|wallet_receive|wallet_send_preview|crypto_send|solana_airdrop) echo "wallet crypto balance receive deposit address qr uri send transfer preview cardano ada polygon pol usdc solana eth funds" ;;
        fund_treasury|fund_opportunities|fund_state|fund_ledger_add) echo "fund treasury loan sovereign allocation ledger accumulate ada usdc btc eth pol opportunities" ;;
        lending_underwrite|lending_request|lending_service|lending_book) echo "loan lending microloan underwrite collateral borrower ltv liquidation repay service" ;;
        crypto_price_ladder|pool_health|polymarket_scan) echo "price ladder limit order fill odds pool liquidity health slippage polymarket arbitrage" ;;
        crypto_review|crypto_scan|crypto_plan|crypto_execute|crypto_standing_order|crypto_journal) echo "cardano crypto ada trading positions inventory orders plan execute confirm review scan fair value deviation markout journal standing order reprice reclaim exit buy sell" ;;
        crypto_backtest) echo "cardano crypto ada backtest walk forward counterfactual what if stop loss timeout hold hours markup sizing simulation s2 s3 shock fade parameter recalibrate" ;;
        operator_notify|operator_ask) echo "operator notify ask escalate escalation alert message dm discord decision confirm inbox" ;;
        recall_search|recall_ingest) echo "recall memory knowledge search retrieve semantic docs archive" ;;
        okf_search|okf_query|okf_traverse) echo "okf graph knowledge dependency blast radius impact callers callees module architecture edges pagerank ppr sqlite" ;;
        project_build|project_test|project_fix) echo "build test compile cargo npm pytest make check run fix" ;;
        file_write|file_append|file_edit) echo "write file append edit modify save content create update" ;;
        file_grep|dir_list) echo "grep search files directory list find pattern structure" ;;
        subagent_spawn|subagent_delegate) echo "subagent swarm delegate spawn background worker task parallel" ;;
        phytology_manage) echo "phytology living tissue audit foliage health cambium plant genetic snapshot heal graft prune lignify" ;;
        tyler_lan_census|tyler_deep_fingerprint|tyler_traffic_inspect|tyler_vuln_audit|tyler_upnp_audit|tyler_set_trust|tyler_intervene|tyler_canary_trap|tyler_tshark_watch|tyler_immune_patrol|tyler_arp_shield|tyler_baseline_diff|tyler_kali_man|tyler_kali_exec|tyler_spelunk|tyler_wifi_spelunk) echo "tyler kali linux nmap tshark arp-scan arping fping hping3 p0f whatweb sslscan snmpwalk smbclient upnpc avahi-browse man manual nse script vuln audit exposure cve canary honeypot trap decoy patrol lateral movement arp shield static neighbor baseline diff drift port_block forensic_snap sweep census fingerprint traffic packet inspect upnp port forward firewall iptables conntrack tcp_reset quarantine device lan network security wifi wireless airspace soft-ap bssid ssid triangulate clock peripheral rf motion presence rssi snr noise floor beacon perimeter guard yard driveway exterior intruder approach" ;;
        google_home_speak|google_home_discover|google_home_volume) echo "google home nest speaker kitchen display bedroom den office cast castv2 broadcast speak announce voice tts washington bryce alan ryan amy alba audio volume" ;;
        *)
            local _mt_map="${GEORGE_DIR:-$LODGE_DIR/.george}/cache/module_tool_map.json"
            if [ -f "$_mt_map" ] && command -v jq &>/dev/null; then
                jq -r --arg t "$1" '.[$t].keywords // empty' "$_mt_map" 2>/dev/null || echo ""
            else
                echo ""
            fi
            ;;
    esac
}

# ── SQLite FTS5 BM25 Engine for Tool Catalog ──────────────────────────
_LODGE_TOOLS_FTS_DB="${_LODGE_TOOLS_FTS_DB:-${TMPDIR:-/tmp}/.lodge_tools_fts_${$}.db}"

native_tools_fts_init() {
    local force="${1:-0}"
    if [ "$force" -ne 1 ] && [ -f "$_LODGE_TOOLS_FTS_DB" ]; then
        local count has_phytology has_sdr has_tyler has_bt
        count=$(sqlite3 "$_LODGE_TOOLS_FTS_DB" "SELECT count(*) FROM tools_fts;" 2>/dev/null || echo 0)
        has_phytology=$(sqlite3 "$_LODGE_TOOLS_FTS_DB" "SELECT count(*) FROM tools_fts WHERE name='phytology_manage';" 2>/dev/null || echo 0)
        has_sdr=$(sqlite3 "$_LODGE_TOOLS_FTS_DB" "SELECT count(*) FROM tools_fts WHERE name='sdr_query';" 2>/dev/null || echo 0)
        has_tyler=$(sqlite3 "$_LODGE_TOOLS_FTS_DB" "SELECT count(*) FROM tools_fts WHERE name='tyler_kali_man';" 2>/dev/null || echo 0)
        has_bt=$(sqlite3 "$_LODGE_TOOLS_FTS_DB" "SELECT count(*) FROM tools_fts WHERE name='crypto_backtest';" 2>/dev/null || echo 0)
        [ "$count" -gt 50 ] && [ "$has_phytology" -gt 0 ] && [ "$has_sdr" -gt 0 ] && [ "$has_tyler" -gt 0 ] && [ "$has_bt" -gt 0 ] && return 0
    fi

    rm -f "$_LODGE_TOOLS_FTS_DB" 2>/dev/null
    sqlite3 "$_LODGE_TOOLS_FTS_DB" << 'EOF'
CREATE VIRTUAL TABLE tools_fts USING fts5(
    name UNINDEXED,
    bundle,
    description,
    tags,
    parameters,
    tokenize = 'porter unicode61'
);
EOF

    local all_tools
    all_tools=$(native_tools_get_all_schemas)

    echo "$all_tools" | jq -c '.[]' | while read -r tool; do
        local t_name t_desc t_params t_bundle="+other"
        t_name=$(echo "$tool" | jq -r '.function.name // empty')
        [ -z "$t_name" ] && continue
        t_desc=$(echo "$tool" | jq -r '.function.description // ""')
        t_params=$(echo "$tool" | jq -r '.function.parameters // {} | tostring')

        local b
        if [[ ",$_BEDROCK_TOOLS," =~ ",$t_name," ]]; then
            t_bundle="_bedrock"
        else
            for b in sdr web files code git vision social ops memory crypto swarm models gsuite phytology; do
                local b_list
                b_list=$(native_tools_bundle_tools "$b")
                if [[ ",$b_list," =~ ",$t_name," ]]; then
                    t_bundle="+$b"
                    break
                fi
            done
        fi

        if [[ "$t_desc" =~ MCP\ tool\ on\ server\ \'([^\']+)\' ]]; then
            t_bundle="+mcp_${BASH_REMATCH[1]}"
        fi

        local t_tags
        t_tags=$(native_tools_domain_tags "$t_name")

        local s_name s_bundle s_desc s_tags s_params
        s_name="${t_name//\'/\'\'}"
        s_bundle="${t_bundle//\'/\'\'}"
        s_desc="${t_desc//\'/\'\'}"
        s_tags="${t_tags//\'/\'\'}"
        s_params="${t_params//\'/\'\'}"

        sqlite3 "$_LODGE_TOOLS_FTS_DB" "INSERT INTO tools_fts (name, bundle, description, tags, parameters) VALUES ('$s_name', '$s_bundle', '$s_desc', '$s_tags', '$s_params');" 2>/dev/null || true
    done
}

# ── Dynamic Tool Search & 1-Turn Auto-Mount ────────────────────────────
native_tools_search() {
    local query="$1"
    local session_dir="${2:-${AGENT_ACTIVE_SESSION_DIR:-}}"
    local max_tools="${3:-${MAX_PROFILE_TOOLS:-56}}"

    [ -z "$query" ] && { echo "Error: query required for tool_search."; return 1; }

    native_tools_fts_init 0

    local matched_bundle="" matched_tools=""

    # 1. Direct bundle tag match (e.g. "+git", "git")
    local clean_q
    clean_q=$(echo "$query" | tr -d ' +' | tr '[:upper:]' '[:lower:]')
    local direct_b_tools
    direct_b_tools=$(native_tools_bundle_tools "$clean_q")
    if [ -n "$direct_b_tools" ]; then
        matched_bundle="+$clean_q"
        matched_tools="$direct_b_tools"
    else
        # 2. SQLite FTS5 BM25 search with OR tokenization
        local words=()
        for w in $(echo "$query" | tr -cs 'a-zA-Z0-9' ' ' | tr '[:upper:]' '[:lower:]'); do
            [ ${#w} -le 1 ] && continue
            case "$w" in
                how|the|and|or|to|in|on|at|for|a|an|is|it|do|can|with|my) continue ;;
            esac
            words+=("${w}*")
        done

        if [ ${#words[@]} -gt 0 ]; then
            local fts_q
            fts_q=$(IFS=' '; echo "${words[*]}" | sed 's/ / OR /g')
            local sql_res
            sql_res=$(sqlite3 "$_LODGE_TOOLS_FTS_DB" "SELECT bundle, name, bm25(tools_fts) FROM tools_fts WHERE tools_fts MATCH '$fts_q' ORDER BY bm25(tools_fts) LIMIT 8;" 2>/dev/null)
            if [ -n "$sql_res" ]; then
                # Check if top-ranked tool in FTS search is an already mounted bedrock tool
                local top_match_name
                top_match_name=$(echo "$sql_res" | head -n 1 | cut -d'|' -f2)
                if [ -n "$top_match_name" ] && [[ ",$_BEDROCK_TOOLS," =~ ",$top_match_name," ]]; then
                    if [ "$top_match_name" = "ask_operator" ] && declare -f is_interactive_operator_session &>/dev/null && ! is_interactive_operator_session; then
                        echo "The tool 'ask_operator' is an interactive operator tool and is NOT available in autonomous/headless mode."
                        return 0
                    fi
                    echo "The tool '$top_match_name' is a core bedrock tool and is ALREADY mounted and immediately available in your active session. You can invoke it directly without mounting any external bundle."
                    native_tools_get_schemas "$top_match_name" | jq -r '.[0] | "Mounted Signature:\n- " + .function.name + "(" + ((.function.parameters.properties // {}) | keys | join(", ")) + "): " + .function.description' 2>/dev/null || true
                    return 0
                fi

                # Select top-ranked non-bedrock bundle (preferring Capability Graph + MoA Bandit router when multiple bundles match)
                local distinct_bundles
                distinct_bundles=$(echo "$sql_res" | grep -v '^_bedrock' | cut -d'|' -f1 | sort -u | wc -l)
                if [ "${distinct_bundles:-0}" -gt 1 ] && [ -f "$LODGE_DIR/lib/tools/capability_graph_router.py" ] && command -v python3 &>/dev/null; then
                    local _cgr_bundle
                    _cgr_bundle=$(_LODGE_TOOLS_FTS_DB="$_LODGE_TOOLS_FTS_DB" LODGE_DIR="$LODGE_DIR" python3 "$LODGE_DIR/lib/tools/capability_graph_router.py" rank-tools "$query" --json 2>/dev/null | jq -r '.best_bundle // empty' 2>/dev/null)
                    [ -n "$_cgr_bundle" ] && matched_bundle="$_cgr_bundle"
                fi
                [ -z "$matched_bundle" ] && matched_bundle=$(echo "$sql_res" | grep -v '^_bedrock' | head -n 1 | cut -d'|' -f1)
                local b_clean="${matched_bundle#+}"
                matched_tools=$(native_tools_bundle_tools "$b_clean")
                if [ -z "$matched_tools" ]; then
                    matched_tools=$(echo "$sql_res" | grep -v '^_bedrock' | cut -d'|' -f2 | tr '\n' ',' | sed 's/,$//')
                fi
            fi
        fi
    fi

    if [ -z "$matched_tools" ]; then
        echo "No matching tool capabilities found for query: '$query'. Try another search term or bundle name (+web, +git, +social, +code, +files, +ops, +vision, +crypto)."
        return 0
    fi

    # Auto-Mount into session active_tools.json if session_dir is available
    local active_tools_file="$session_dir/active_tools.json"
    local evicted_bundle=""
    local total_count=0
    if [ -n "$session_dir" ] && [ -d "$session_dir" ]; then
        local current_tools_json="[]"
        [ -f "$active_tools_file" ] && current_tools_json=$(cat "$active_tools_file" 2>/dev/null || echo "[]")

        local new_schemas
        new_schemas=$(native_tools_get_schemas "$matched_tools")

        local merged_tools
        merged_tools=$(jq -n --argjson curr "$current_tools_json" --argjson new "$new_schemas" '
            ($curr + $new) | unique_by(.function.name)
        ' 2>/dev/null)

        total_count=$(echo "$merged_tools" | jq '. | length' 2>/dev/null || echo 0)
        total_count="${total_count:-0}"

        # Enforce max_tools ceiling via LRU bundle eviction loop
        while [ "$total_count" -gt "$max_tools" ] 2>/dev/null; do
            local mounted_bundles
            mounted_bundles=$(echo "$merged_tools" | jq -r '.[].function.name' | while read -r tname; do
                [[ ",$_BEDROCK_TOOLS," =~ ",$tname," ]] && continue
                for b in web files code git vision social ops memory crypto swarm models gsuite; do
                    local bl
                    bl=$(native_tools_bundle_tools "$b")
                    if [[ ",$bl," =~ ",$tname," ]]; then
                        echo "+$b"
                        break
                    fi
                done
            done | grep -v '^\s*$' | sort -u)

            local traj_log="$session_dir/trajectory.log"
            local lru_bundle="" lru_score=999999
            for mb in $mounted_bundles; do
                [ "$mb" = "$matched_bundle" ] && continue
                local mb_clean="${mb#+}"
                local mb_tools
                mb_tools=$(native_tools_bundle_tools "$mb_clean")
                local call_count=0
                if [ -f "$traj_log" ]; then
                    IFS=',' read -ra T_ARR <<< "$mb_tools"
                    for tn in "${T_ARR[@]}"; do
                        local c
                        c=$(grep -c "Tool Call: $tn" "$traj_log" 2>/dev/null || true)
                        c="${c:-0}"
                        call_count=$((call_count + c))
                    done
                fi
                if [ "$call_count" -lt "$lru_score" ]; then
                    lru_score="$call_count"
                    lru_bundle="$mb"
                fi
            done

            if [ -n "$lru_bundle" ]; then
                if [ -z "$evicted_bundle" ]; then
                    evicted_bundle="$lru_bundle"
                else
                    evicted_bundle+=", $lru_bundle"
                fi
                local evict_clean="${lru_bundle#+}"
                local evict_tool_list
                evict_tool_list=$(native_tools_bundle_tools "$evict_clean")
                merged_tools=$(echo "$merged_tools" | jq --arg evict "$evict_tool_list" --arg bedrock "$_BEDROCK_TOOLS" --arg keep "$matched_tools" '
                    ($evict | split(",")) as $e |
                    ($bedrock | split(",")) as $b |
                    ($keep | split(",")) as $k |
                    [.[] | select((.function.name as $n | $b | index($n)) or (.function.name as $n | $k | index($n)) or (.function.name as $n | ($e | index($n) | not)))]
                ')
                local prev_count="$total_count"
                total_count=$(echo "$merged_tools" | jq '. | length' 2>/dev/null || echo "$total_count")
                [ "$total_count" -ge "$prev_count" ] && break
            else
                break
            fi
        done

        echo "$merged_tools" > "$active_tools_file"
    fi

    local docs=""
    if [ -n "$new_schemas" ] && [ "$new_schemas" != "[]" ]; then
        docs=$(echo "$new_schemas" | jq -r '.[] | "- " + .function.name + "(" + (((.function.parameters.properties // {}) | keys | .[0:4]) | join(", ")) + (if (((.function.parameters.properties // {}) | keys | length) > 4) then ", ..." else "" end) + "): " + ((.function.description // "") | split(". ")[0] | split("\n")[0])' 2>/dev/null)
    fi
    local msg="✓ Attached bundle '${matched_bundle}' (${matched_tools})."
    if [ -n "$evicted_bundle" ]; then
        msg+=" ℹ Pruned inactive bundle(s) '${evicted_bundle}' to respect the ${max_tools}-tool ceiling."
    fi
    [ "$total_count" -gt 0 ] && msg+=" Active tools: ${total_count}/${max_tools}."
    msg+=" These tools are now immediately available in this session."
    if [ -n "$docs" ]; then
        msg+=$'\n\nMounted Tool Signatures:\n'"$docs"
    fi
    echo "$msg"
}

# ── Sanitize & Repair Tool Arguments ──────────────────────────────────
# Repairs LLM argument quirks: trailing XML tags (</parameter>, </function>),
# embedded XML parameters (<parameter = key > val </parameter>), unescaped newlines,
# shell argument quirks (bare head -n, git rev-parse arg order), and path formatting.
native_tools_sanitize_args() {
    local raw="$1"
    [ -z "$raw" ] || [ "$raw" = "null" ] && { echo "{}"; return 0; }

    if command -v python3 &>/dev/null; then
        python3 -c '
import sys, os, json, re

raw = sys.stdin.read().strip()
if not raw or raw == "null":
    print("{}")
    sys.exit(0)

extracted = {}

_PRESERVE_RAW_KEYS = {
    "content", "target", "replacement", "old_text", "new_text",
    "old_str", "new_str", "search", "replace", "expression",
    "new_symbol_code", "patch", "body", "message"
}

try:
    j = json.loads(raw)
    if isinstance(j, dict):
        for k, v in j.items():
            if isinstance(v, str):
                if k in _PRESERVE_RAW_KEYS:
                    # Only strip trailing hallucinated XML closing tags; preserve indentation & mid-string code
                    clean_v = re.sub(r"(?:\s*</(?:parameter|function|tool_call|invoke|output)[^>]*>)+\s*$", "", v)
                else:
                    clean_v = re.split(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", v)[0].strip()
                extracted[k] = clean_v
            else:
                extracted[k] = v
except Exception:
    if "\"edits\"" not in raw:
        for m in re.finditer(r"\"([a-zA-Z0-9_]+)\"\s*:\s*\"((?:\\.|[^\"\\])*)\"", raw):
            k_m, v_m = m.group(1), m.group(2)
            try:
                v_dec = json.loads("\"" + v_m + "\"", strict=False)
            except Exception:
                v_dec = v_m
            extracted[k_m] = v_dec if k_m in _PRESERVE_RAW_KEYS else v_dec.strip()

if "<parameter" in raw or "</parameter>" in raw:
    if not extracted:
        xml_matches = re.findall(r"<parameter\s*(?:=\s*)?([a-zA-Z0-9_]+)\s*>\s*(.*?)(?:</parameter>|(?=<parameter)|(?=</function>)|$)", raw, re.DOTALL)
        for k, v in xml_matches:
            if k in _PRESERVE_RAW_KEYS:
                v_clean = re.sub(r"(?:\s*</(?:parameter|function|tool_call|invoke|output)[^>]*>)+\s*$", "", v).strip("\r\n")
            else:
                v_clean = v.strip()
                v_clean = re.sub(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", "", v_clean).strip()
            if re.match(r"^\d+$", v_clean):
                extracted[k] = int(v_clean)
            else:
                extracted[k] = v_clean

target_ws = os.environ.get("LODGE_DIR") or os.path.expanduser("~/blue-lodge")

# Rebase repo paths onto the active workspace, but leave paths that already
# point into a .sandboxes/<name> worktree alone (remediation runs with
# LODGE_DIR inside .sandboxes/, so a blind rewrite nests the path in itself).
_ws_re = re.compile(r"(?:/home/[^/\s]+|/Users/[^/\s]+|~|\$HOME)/blue[ _-][a-zA-Z0-9_-]+(/\.sandboxes/[A-Za-z0-9_.-]+)?")
def _rebase(m):
    return m.group(0) if m.group(1) else target_ws

if "command" in extracted and isinstance(extracted["command"], str):
    c = extracted["command"]
    c = re.split(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", c)[0].strip()
    c = re.sub(r"head -n(\s*(\||&|;|$))", r"head -n 10\1", c)
    c = re.sub(r"git rev-parse\s+([^\s]+)\s+--short", r"git rev-parse --short \1", c)
    c = _ws_re.sub(_rebase, c)
    c = re.sub(r"(/\.sandboxes/[A-Za-z0-9_.-]+)(?:\1)+", r"\1", c)
    extracted["command"] = c

if "path" in extracted and isinstance(extracted["path"], str):
    p = extracted["path"].split("\n")[0].strip()
    p = re.split(r"(\s+2?>|\s+\||\s+;)", p)[0].strip()
    if re.match(r"^\.?/?home/[^/]+/blue[ _-]", p):
        p = "/" + p.lstrip("./")
    m0 = _ws_re.match(p)
    if m0:
        p = _rebase(m0) + p[m0.end():]
    p = re.sub(r"(/\.sandboxes/[A-Za-z0-9_.-]+)(?:\1)+", r"\1", p)
    if re.match(r"^home/[^/]+/", p):
        p = "/" + p
    extracted["path"] = p

print(json.dumps(extracted) if extracted else raw)
' <<< "$raw" 2>/dev/null && return 0
    fi

    # Fallback to jq if python3 fails
    printf '%s\n' "$raw" | jq '
        walk(
            if type == "string" then
                gsub("</?(parameter|function|tool_call)[^>]*>"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")
            else
                .
            end
        )
    ' 2>/dev/null || echo "$raw"
}

# Rebases repo paths (/home/<u>/blue-lodge…, ~/blue-lodge…) in $1 onto the
# workspace $2. Paths that already point into a .sandboxes/<name> worktree are
# kept verbatim, so the rewrite is idempotent when $2 itself is a sandbox.
_nt_rebase_ws_paths() {
    local s="$1" t="$2" out="" m
    local re='(/home/[^/[:space:]]+|/Users/[^/[:space:]]+|~|\$HOME)/blue[ _-][a-zA-Z0-9_-]*(/\.sandboxes/[A-Za-z0-9_.-]+)?'
    while [[ "$s" =~ $re ]]; do
        m="${BASH_REMATCH[0]}"
        out+="${s%%"$m"*}"
        if [ -n "${BASH_REMATCH[2]}" ]; then out+="$m"; else out+="$t"; fi
        s="${s#*"$m"}"
    done
    local res="$out$s"
    local _prev_res=""
    while [ "$_prev_res" != "$res" ]; do
        _prev_res="$res"
        res=$(echo "$res" | sed -E 's|(\.sandboxes/([^/]+))/\1|\1|g')
    done
    printf '%s' "$res"
}

# ── Tool Dispatcher ───────────────────────────────────────────────────
# Receives call_id, function name, JSON arguments string, and workspace.
# Executes the pure POSIX tool and prints standard OpenAI tool response JSON:
# {"role": "tool", "tool_call_id": "$call_id", "content": "$output"}
native_tools_dispatch() {
    local call_id="$1"
    local name="$2"
    local args_json="$3"
    local workdir="${4:-$PWD}"

    local output=""
    local exit_code=0
    local _tool_start_ms
    _tool_start_ms=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
    local _ipc_chan="${IPC_CHANNEL:-}"
    # Only stream lifecycle frames if the channel really exists (zero-fork check)
    if [ -n "$_ipc_chan" ] && ! [ -p "${FIFO_IPC_DIR:-${GEORGE_DIR:-$LODGE_DIR/.george}/ipc}/channels/${_ipc_chan}/data.fifo" ]; then
        _ipc_chan=""
    fi
    declare -f ipc_send &>/dev/null || _ipc_chan=""
    local _task_id="${AGENT_ACTIVE_TASK_ID:-${LODGE_SESSION_ID:-standalone}}"

    # Clean up and repair LLM argument hallucinations and embedded XML parameters
    args_json=$(native_tools_sanitize_args "$args_json")

    # 1. Telemetry & IPC Channel Start Frame
    if declare -f telemetry_tool_start &>/dev/null; then
        telemetry_tool_start "$_task_id" "$call_id" "$name" "$args_json" "$_ipc_chan"
    fi
    if [ -n "$_ipc_chan" ]; then
        ipc_send "$_ipc_chan" "TOOL_START" "$(jq -nc --arg id "$call_id" --arg tool "$name" --arg tid "$_task_id" '{call_id: $id, tool: $tool, task_id: $tid}')" "" 0 >/dev/null 2>&1 || true
    fi

    # Helper for intermediate progress streaming
    native_tool_progress() {
        local pct="$1"
        local msg="$2"
        local extra="${3:-"{}"}"
        if declare -f telemetry_tool_progress &>/dev/null; then
            telemetry_tool_progress "$_task_id" "$call_id" "$pct" "$msg" "$extra"
        fi
        if [ -n "$_ipc_chan" ]; then
            [[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || pct=0
            ipc_send "$_ipc_chan" "TOOL_PROGRESS" "$(jq -nc --arg id "$call_id" --arg tool "$name" --argjson pct "$pct" --arg msg "$msg" '{call_id: $id, tool: $tool, percent: $pct, message: $msg}')" "" 0 >/dev/null 2>&1 || true
        fi
    }

    _arg() {
        if [ $# -ge 2 ]; then
            jq -r "$1 // \"$2\"" <<< "$args_json" 2>/dev/null
        else
            jq -r "$1 // empty" <<< "$args_json" 2>/dev/null
        fi
    }
    _call_sim() {
        local fn="$1" sim="$2"; shift 2
        if declare -f "$fn" &>/dev/null; then output=$("$fn" "$@" 2>&1); exit_code=$?; else output="$sim"; exit_code=0; fi
    }
    _call_err() {
        local fn="$1" err="$2"; shift 2
        if declare -f "$fn" &>/dev/null; then output=$("$fn" "$@" 2>&1); exit_code=$?; else output="ERROR: ${err:-$fn not available}"; exit_code=1; fi
    }


    # 1. Check if name is an active MCP tool directly (skip tools that have parallel-safe native dispatchers below)
    local handled_by_mcp=0
    if [[ ! "$name" =~ ^(tyler_|google_home_) ]] && declare -f mcp_enabled &>/dev/null && mcp_enabled && declare -f mcp_running_servers &>/dev/null; then
        local s_name
        for s_name in $(mcp_running_servers 2>/dev/null); do
            local s_tools
            s_tools=$(mcp_tools_list "$s_name" 2>/dev/null)
            if echo "$s_tools" | jq -e --arg n "$name" '.[] | select(.name == $n)' &>/dev/null; then
                local _mcp_args="$args_json"
                if [ "$s_name" = "george-git" ] && [ -n "$workdir" ] && [[ "$name" =~ ^git_(status|log|diff|commit|push|pull|branch|remote)$ ]]; then
                    local _cur_p
                    _cur_p=$(echo "$_mcp_args" | jq -r '.path // empty' 2>/dev/null)
                    if [ -z "$_cur_p" ] || [ "$_cur_p" = "." ]; then
                        _mcp_args=$(echo "$_mcp_args" | jq -c --arg wd "$workdir" '. + {path: $wd}' 2>/dev/null || echo "$_mcp_args")
                    fi
                fi
                output=$(mcp_tool_call "$s_name" "$name" "$_mcp_args" 2>&1)
                exit_code=$?
                handled_by_mcp=1
                break
            fi
        done
    fi

    # 2. Dispatch to Built-in POSIX Tools if not MCP
    if [ "$handled_by_mcp" -eq 0 ] && [[ ",${_GEORGE_HIDDEN_TOOLS}," == *",${name},"* ]] && [ "${GEORGE_ALLOW_LEGACY_TRADING:-0}" != "1" ]; then
        output="ERROR: ${name} is retired for George: trades go through crypto_plan (propose) then crypto_execute (Tier A) or the operator's 'confirm <plan_id>' (Tier B)."
        exit_code=1
        handled_by_mcp=1
    fi
    if [ "$handled_by_mcp" -eq 0 ] && [ "$name" = "crypto_execute" ] && [ "${GEORGE_HEADLESS_ESCALATION:-0}" = "1" ]; then
        output="ERROR: crypto_execute is not available while writing an escalation. Include the plan_id in operator_ask instead."
        exit_code=1
        handled_by_mcp=1
    fi
    if [ "$handled_by_mcp" -eq 0 ] && [[ "$name" =~ ^(file_write|file_append|file_edit)$ ]]; then
        local _tp_path
        _tp_path=$(echo "$args_json" | jq -r '.path // empty' 2>/dev/null)
        if [[ "$_tp_path" =~ (trading_policy\.json|trading\.db|escalations\.db|trading_confirm\.key|cardano_mode\.conf|wallet/policy\.json|features\.conf|keys\.conf) ]]; then
            output="ERROR: ${_tp_path} is Tier C (operator-only): George cannot write trading policy, ledgers, flags or secrets."
            exit_code=1
            handled_by_mcp=1
        fi
    fi
    if [ "$handled_by_mcp" -eq 0 ]; then
        case "$name" in
            tool_search)
                local q
                q=$(echo "$args_json" | jq -r '.query // empty')
                output=$(native_tools_search "$q" "${AGENT_ACTIVE_SESSION_DIR:-$workdir}" "${MAX_PROFILE_TOOLS:-56}")
                exit_code=$?
                ;;
            okf_search)
                local q
                q=$(echo "$args_json" | jq -r '.query // empty')
                output=$(okf_search "$q")
                exit_code=$?
                ;;
            okf_query)
                local tgt
                tgt=$(echo "$args_json" | jq -r '.target // empty')
                output=$(okf_query "$tgt")
                exit_code=$?
                ;;
            okf_traverse)
                local seed hops topk
                seed=$(echo "$args_json" | jq -r '.seed // .target // .query // empty')
                hops=$(echo "$args_json" | jq -r '.max_hops // 2')
                topk=$(echo "$args_json" | jq -r '.top_k // 15')
                [[ "$hops" =~ ^[0-9]+$ ]] || hops=2
                [[ "$topk" =~ ^[0-9]+$ ]] || topk=15
                output=$(okf_traverse "$seed" --hops "$hops" --limit "$topk" --json)
                exit_code=$?
                ;;
            task_wait)
                local secs reason
                secs=$(echo "$args_json" | jq -r '.seconds // 5')
                reason=$(echo "$args_json" | jq -r '.reason // "Waiting for background job or timer"')
                if ! [[ "$secs" =~ ^[0-9]+$ ]] || [ "$secs" -lt 1 ]; then secs=5; fi
                if [ "$secs" -gt 600 ]; then secs=600; fi
                sleep "$secs"
                output="TASK_WAIT_SUCCESS: Slept for ${secs}s (${reason})."
                exit_code=0
                ;;
            task_complete|end_turn)
                local t_summary t_artifacts
                t_summary=$(echo "$args_json" | jq -r '.summary // empty')
                t_artifacts=$(echo "$args_json" | jq -c '.artifacts // []')
                [ -z "$t_summary" ] && t_summary=$(echo "$args_json" | jq -r '.output // "Task complete."')

                local final_dir="$workdir/.george"
                mkdir -p "$final_dir"
                echo "$t_summary" > "$final_dir/final_reply.txt"

                output="TASK_COMPLETE_SUBMITTED: Final deliverable recorded for Outer Evaluator determination. Summary: ${t_summary:0:160}"
                exit_code=0
                ;;
            milestone_complete)
                local m_status m_summary m_facts m_prune
                m_status=$(echo "$args_json" | jq -r '.status // "success"')
                m_summary=$(echo "$args_json" | jq -r '.summary // "Milestone completed."')
                m_facts=$(echo "$args_json" | jq -c '.facts_discovered // []')
                m_prune=$(echo "$args_json" | jq -c '[.prune_ids[]? | tonumber? // empty]' 2>/dev/null || echo "[]")

                local dag_state_file="$workdir/.george/state/dag_state.json"
                mkdir -p "$workdir/.george/state"
                local cur_step="${CURRENT_ACTIVE_MILESTONE_ID:-1}"
                local now_ts
                now_ts=$(date +%s)

                if [ "$m_prune" != "[]" ] && [ -n "$m_prune" ]; then
                    local _hd_target="${AGENT_ACTIVE_SESSION_DIR:-${AGENT_TASK_WORKSPACE:-$workdir/.george}}/honeydew.json"
                    [ ! -f "$_hd_target" ] && _hd_target="$workdir/.george/honeydew.json"
                    if [ -f "$_hd_target" ]; then
                        jq --argjson pids "$m_prune" '
                            .items |= map(if (.id as $id | $pids | index($id)) then (.status = "done" | .skipped = true) else . end)
                        ' "$_hd_target" > "${_hd_target}.tmp" 2>/dev/null && mv "${_hd_target}.tmp" "$_hd_target" || true
                    fi
                fi

                local update_entry
                update_entry=$(jq -nc \
                    --arg id "$cur_step" \
                    --arg st "$m_status" \
                    --arg sm "$m_summary" \
                    --argjson f "$m_facts" \
                    --arg ts "$now_ts" \
                    '{id: $id, status: $st, summary: $sm, facts: $f, timestamp: ($ts | tonumber)}')

                if [ -f "$dag_state_file" ]; then
                    jq --argjson entry "$update_entry" '.milestones += [$entry]' "$dag_state_file" > "${dag_state_file}.tmp" 2>/dev/null && mv "${dag_state_file}.tmp" "$dag_state_file" || true
                else
                    jq -n --argjson entry "$update_entry" '{milestones: [$entry]}' > "$dag_state_file" 2>/dev/null || true
                fi

                commands_dispatch "/append mem:active_task \n## Milestone $cur_step ($m_status)\n$m_summary\n" "$workdir" >/dev/null 2>&1 || true

                output="MILESTONE_COMPLETE_ACKNOWLEDGED: Milestone status='$m_status' registered to DAG state barrier. Summary: $m_summary"
                exit_code=0
                ;;
            bash_exec)
                local cmd
                cmd=$(echo "$args_json" | jq -r '.command // empty')
                cmd="${cmd%%</parameter*}"
                cmd="${cmd%%</invoke*}"
                cmd="${cmd%%</output*}"
                cmd="${cmd%%<tool_call*}"
                cmd="${cmd%%<function*}"
                # Direct slash command interception if model invokes slash command via bash_exec
                local _tg_reason=""
                if _tg_reason=$(_trading_bash_guard "$cmd"); then
                    output="ERROR: blocked by trading policy guard: ${_tg_reason}"
                    exit_code=1
                elif printf '%s\n' "$cmd" | grep -qiE '\bip[[:space:]]+(-[46][[:space:]]+)?(neigh|neighbor|n|route|r|link|l|addr|a|rule)[[:space:]]+(del|delete|flush|change|replace|set)\b' && \
                     printf '%s\n' "$cmd" | grep -qiE '\b(lo|loopback[0-9]*|tailscale[0-9]*|wg[0-9]*|tun[0-9]*|tap[0-9]*|docker[0-9]*|br-[a-z0-9_-]*|virbr[0-9]*|veth[a-z0-9_-]*|169\.254\.[0-9]+\.[0-9]+|127\.[0-9]+\.[0-9]+\.[0-9]+|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+|table[[:space:]]+(local|main|default|12[78]|52|[0-9]+))\b'; then
                    output="ERROR: Policy Gate Blocked — Kernel loopback, virtual bridge, VPN/mesh tunnel interfaces (lo, loopback*, tailscale*, wg*, docker*, br-*, virbr*), link-local bridges (169.254.x.x), and kernel routing tables are protected across Linux and WSL2. Modifying or flushing them severs host/localhost connectivity."
                    exit_code=1
                elif [[ "$cmd" =~ ^/[a-zA-Z0-9_-]+([[:space:]]|$) ]] && [ ! -e "${cmd%%[[:space:]]*}" ]; then
                    output=$(commands_dispatch "$cmd" "$workdir" 2>&1)
                    exit_code=$?
                elif [[ "$cmd" =~ ^(\./)?lodge[[:space:]]+(/[a-zA-Z0-9_-]+.*) ]]; then
                    local _sub_slash="${BASH_REMATCH[2]}"
                    output=$(commands_dispatch "$_sub_slash" "$workdir" 2>&1)
                    exit_code=$?
                else
                    # Auto-normalize common shell invocation quirks
                    local _target_ws="${LODGE_DIR:-$HOME/blue-lodge}"
                    cmd=$(echo "$cmd" | sed -E 's/head -n([[:space:]]*(\||\&|\;|$))/head -n 10\1/g')
                    cmd=$(echo "$cmd" | sed -E 's/git rev-parse ([^ ]+) --short/git rev-parse --short \1/g')
                    cmd=$(_nt_rebase_ws_paths "$cmd" "$_target_ws")
                    cmd=$(echo "$cmd" | sed -E 's/\bgit switch -B\b/git switch -C/g; s/\bgit switch -b\b/git switch -c/g; s/\bgit checkout -c\b/git checkout -b/g')
                    cmd=$(echo "$cmd" | sed -E 's|(https?://)[[:space:]]+|\1|g; s|(https?://[a-zA-Z0-9_-]+)[[:space:]]*\.[[:space:]]*([a-zA-Z0-9_.-]+)|\1.\2|g; s|(https?://[a-zA-Z0-9_.-]+)[[:space:]]*\.[[:space:]]*([a-zA-Z0-9_.-]+)|\1.\2|g; s|\bcurl[[:space:]]+(.*)[[:space:]]*-o[[:space:]]+([a-zA-Z0-9_.-]+/)[[:space:]]*|curl \1 -O --output-dir \2 |g')
                    output=$(commands_dispatch "/bash $cmd" "$workdir" 2>&1)
                    exit_code=$?
                fi
                # SCRIPT_EXIT / Traceback error exit code correction
                if [ "$exit_code" -eq 0 ]; then
                    if echo "$output" | grep -qE 'SCRIPT_EXIT=([1-9][0-9]*)'; then
                        local _extracted_exit
                        _extracted_exit=$(echo "$output" | grep -oE 'SCRIPT_EXIT=[0-9]+' | tail -n 1 | cut -d= -f2)
                        [ -n "$_extracted_exit" ] && [ "$_extracted_exit" -ne 0 ] && exit_code="$_extracted_exit"
                    else
                        local _last_nonempty
                        _last_nonempty=$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | tail -n 1)
                        if printf '%s\n' "$_last_nonempty" | grep -qiE '(^(Traceback|[A-Za-z0-9_.]*(Error|Exception):)|command not found|pdftotext: not found)'; then
                            exit_code=1
                        fi
                    fi
                fi
                if [ "$exit_code" -ne 0 ]; then
                    if [ -z "$output" ]; then
                        output="ERROR: Command failed with exit code $exit_code"
                    fi
                    local _done_ts
                    _done_ts=$(date '+%Y-%m-%d %H:%M:%S')
                    ui_err "[$_done_ts] bash_exec failed (exit $exit_code)" >&2 2>/dev/null || true
                fi
                ;;
            file_read)
                local p s m e
                p=$(echo "$args_json" | jq -r '.path // empty')
                s=$(echo "$args_json" | jq -r '.start_line // 1')
                e=$(echo "$args_json" | jq -r '.end_line // empty')
                m=$(echo "$args_json" | jq -r '.max_lines // 100')
                if [[ "$p" == "${HOME#/}"/* ]]; then p="/$p"; fi
                # Enforce safe bounds (1-200 lines max per read to protect context limits)
                if ! [[ "$s" =~ ^[0-9]+$ ]] || [ "$s" -lt 1 ]; then
                    s=1
                fi
                if [[ "$e" =~ ^[0-9]+$ ]] && [ "$e" -ge "$s" ]; then
                    m=$(( e - s + 1 ))
                fi
                if ! [[ "$m" =~ ^[0-9]+$ ]] || [ "$m" -lt 1 ]; then
                    m=100
                elif [ "$m" -gt 200 ]; then
                    m=200
                fi
                local target="$p"
                if declare -f ui_resolve_path &>/dev/null; then
                    target=$(ui_resolve_path "$p" "$workdir")
                elif [ -f "$workdir/$p" ]; then
                    target="$workdir/$p"
                fi
                if [ ! -e "$target" ]; then
                    local _primary_root="${LODGE_ROOT:-}"
                    if [ -z "$_primary_root" ] && [[ "$workdir" == *"/.sandboxes/"* ]]; then
                        _primary_root="${workdir%%/.sandboxes/*}"
                    fi
                    [ -z "$_primary_root" ] && _primary_root="${LODGE_DIR:-$(pwd)}"
                    if [ -e "$_primary_root/$p" ]; then
                        target="$_primary_root/$p"
                    fi
                fi
                # Enclave guard: Block reading secret/credential files
                local _norm_target="${target,,}"
                local _norm_p="${p,,}"
                if [[ "$_norm_target" =~ \.george/(keys\.conf|secrets\.env) ]] || \
                   [[ "$_norm_target" =~ \.env($|\.) ]] || \
                   [[ "$_norm_target" =~ \.vault ]] || \
                   [[ "$_norm_target" =~ (id_rsa|id_ed25519|\.pem$|\.key$) ]] || \
                   [[ "$_norm_target" =~ /etc/(shadow|sudoers) ]] || \
                   [[ "$_norm_p" =~ \.george/(keys\.conf|secrets\.env) ]] || \
                   [[ "$_norm_p" =~ \.env($|\.) ]] || \
                   [[ "$_norm_p" =~ \.vault ]] || \
                   [[ "$_norm_p" =~ (id_rsa|id_ed25519|\.pem$|\.key$) ]]; then
                    output="ERROR: Access denied: Invalid or restricted file path."
                    exit_code=1
                elif [ -z "$p" ] || [[ "$p" =~ ^[0-9]+$ ]]; then
                    output="ERROR: Invalid file path '$p'. Please provide a valid file path (e.g. lib/agents/phytology.sh)."
                    exit_code=1
                elif [ ! -e "$target" ]; then
                    if [[ "$p" == mem:* ]]; then
                        output="(Working memory handle '$p' is currently empty. Record your intermediate findings or synthesized deliverable using file_write or file_append to '$p'.)"
                        exit_code=0
                    else
                        output="ERROR: File not found: $p"
                        exit_code=1
                    fi
                elif [ -d "$target" ]; then
                    output=$(commands_dispatch "/ls $p 2" "$workdir" 2>&1)
                    exit_code=0
                elif [[ "${target,,}" == *.pdf ]]; then
                    output=$(tools_read_pdf "$target" 1 "" 20 1 2>&1)
                    exit_code=$?
                elif [[ "${target,,}" =~ \.(ogg|oga|opus|mp3|wav|m4a|flac|aac|wma|amr)$ ]]; then
                    local _py="python3"
                    [ -x "$LODGE_DIR/.venv/bin/python" ] && _py="$LODGE_DIR/.venv/bin/python"
                    if [[ "$target" == *"/.george/sdr/"* ]]; then
                        output=$("$_py" "$LODGE_DIR/lib/tools/sdr_ingest.py" --listen "$target" 2>&1)
                        exit_code=$?
                    else
                        output=$("$_py" "$LODGE_DIR/lib/tools/sdr_transcribe.py" --voice "$target" --priority 100 --source file_read 2>&1)
                        exit_code=$?
                    fi
                elif [[ "${target,,}" =~ \.(jpg|jpeg|png|gif|webp|bmp|ico|tiff|mp4|mkv|webm|mov|avi|gguf|bin|sqlite|db)$ ]]; then
                    output="ERROR: '$p' is a binary media/database file and cannot be read as text via file_read. For image files, use vision_analyze; for sdr_intel.db queries, use sdr_query."
                    exit_code=1
                else
                    output=$(tools_read_file "$target" "$m" "$s" 2>&1)
                    exit_code=$?
                    if [ $exit_code -eq 0 ] && [ -f "$target" ]; then
                        local _ts_total_lines
                        _ts_total_lines=$(wc -l < "$target" 2>/dev/null || echo 0)
                        if [ "$_ts_total_lines" -gt 150 ]; then
                            output+=$'\n\n'"[Tip: $p has $_ts_total_lines lines. Use code_outline \"$p\" for structural overview, or code_symbol_get \"$p\" <symbol> to extract specific functions/classes.]"
                        fi
                    fi
                fi
                ;;
            pdf_read)
                local p s e m l
                p=$(echo "$args_json" | jq -r '.path // empty')
                s=$(echo "$args_json" | jq -r '.page_start // 1')
                e=$(echo "$args_json" | jq -r '.page_end // empty')
                m=$(echo "$args_json" | jq -r '.max_pages // 20')
                l=$(echo "$args_json" | jq -r 'if .layout == false then 0 else 1 end')
                local target="$p"
                if declare -f ui_resolve_path &>/dev/null; then
                    target=$(ui_resolve_path "$p" "$workdir")
                elif [ -f "$workdir/$p" ]; then
                    target="$workdir/$p"
                fi
                if [ ! -f "$target" ]; then
                    output="ERROR: PDF file not found: $p"
                    exit_code=1
                else
                    output=$(tools_read_pdf "$target" "$s" "$e" "$m" "$l" 2>&1)
                    exit_code=$?
                fi
                ;;
            workflow_plan)
                local obj ctx qs
                obj=$(echo "$args_json" | jq -r '.objective // empty')
                ctx=$(echo "$args_json" | jq -r '.context // empty')
                qs=$(echo "$args_json" | jq -r '.questions // empty')
                if declare -f workflow_interactive_plan &>/dev/null; then
                    output=$(workflow_interactive_plan "$obj" "$ctx" "$qs" "$workdir" 2>&1)
                    exit_code=$?
                elif declare -f _workflow_run_architect &>/dev/null; then
                    output=$(_workflow_run_architect "$obj" "$workdir" "" 2>&1)
                    exit_code=$?
                else
                    output=$(commands_dispatch "/workflow run the-architect $obj" "$workdir" 2>&1)
                    exit_code=$?
                fi
                ;;
            workflow_run)
                local wname wargs
                wname=$(echo "$args_json" | jq -r '.name // empty')
                wargs=$(echo "$args_json" | jq -r '.args // empty')
                if declare -f workflows_run &>/dev/null; then
                    output=$(workflows_run "$wname" "$wargs" "$workdir" 2>&1)
                    exit_code=$?
                else
                    output=$(commands_dispatch "/workflow run $wname $wargs" "$workdir" 2>&1)
                    exit_code=$?
                fi
                ;;
            file_write)
                local p c
                p=$(echo "$args_json" | jq -r '.path // empty')
                c=$(echo "$args_json" | jq -r '.content // empty')
                if [[ "$p" == "${HOME#/}"/* ]]; then p="/$p"; fi
                # Ambient Tree-sitter pre-flight syntax validation
                local _ts_lang
                _ts_lang=$(treesitter_detect_lang "$p")
                if [ -n "$_ts_lang" ] && [ "$_ts_lang" != "plaintext" ]; then
                    local _ts_v_err
                    if ! _ts_v_err=$(treesitter_validate "$c" "$_ts_lang" 2>&1); then
                        output="ERROR: Tree-sitter AST Syntax Validation Failed for $p ($_ts_lang):
$_ts_v_err
[File write aborted to protect code integrity. Fix syntax errors before writing.]"
                        exit_code=1
                    fi
                fi
                if [ -z "$output" ]; then
                    declare -f cmd_write &>/dev/null || source "$LODGE_DIR/commands/write.sh" 2>/dev/null || true
                    declare -f tools_with_file_lock &>/dev/null || source "$LODGE_DIR/lib/tools/tools.sh" 2>/dev/null || true
                    local _fw_lock="$p"
                    [[ "$_fw_lock" != /* ]] && _fw_lock="$workdir/$p"
                    output=$(LODGE_RAW_CONTENT="$c" LODGE_RAW_CONTENT_SET=1 tools_with_file_lock "$_fw_lock" cmd_write "$p" "$workdir" 2>&1)
                    exit_code=$?
                fi
                ;;
            file_append)
                local p c
                p=$(echo "$args_json" | jq -r '.path // empty')
                c=$(echo "$args_json" | jq -r '.content // empty')
                if [[ "$p" == "${HOME#/}"/* ]]; then p="/$p"; fi
                declare -f cmd_append &>/dev/null || source "$LODGE_DIR/commands/append.sh" 2>/dev/null || true
                declare -f tools_with_file_lock &>/dev/null || source "$LODGE_DIR/lib/tools/tools.sh" 2>/dev/null || true
                local _fa_lock="$p"
                [[ "$_fa_lock" != /* ]] && _fa_lock="$workdir/$p"
                output=$(LODGE_RAW_CONTENT="$c" LODGE_RAW_CONTENT_SET=1 tools_with_file_lock "$_fa_lock" cmd_append "$p" "$workdir" 2>&1)
                exit_code=$?
                ;;
            dir_list)
                local p d target
                p=$(echo "$args_json" | jq -r '.path // "."')
                d=$(echo "$args_json" | jq -r '.depth // empty')
                if [ -z "$d" ] || [ "$d" = "null" ]; then
                    if [ "$p" = "." ] || [ -z "$p" ]; then
                        d=1
                    else
                        d=2
                    fi
                fi
                if [[ "$p" == /* ]]; then
                    target="$p"
                else
                    target="$workdir/$p"
                fi
                output=$(commands_dispatch "/ls $target $d" "$workdir" 2>&1)
                exit_code=$?
                ;;
            file_grep)
                local pat p target
                pat=$(echo "$args_json" | jq -r '.pattern // empty')
                p=$(echo "$args_json" | jq -r '.path // "."')
                # Sanitize if pattern contains embedded XML parameter syntax
                if [[ "$pat" == *"</parameter>"* ]] || [[ "$pat" == *"<parameter"* ]]; then
                    if [[ "$pat" =~ parameter=path[^\>]*\>([^<]+) ]]; then
                        local _extracted_p="${BASH_REMATCH[1]}"
                        _extracted_p=$(echo "$_extracted_p" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')
                        [ -n "$_extracted_p" ] && p="$_extracted_p"
                    fi
                    pat=$(echo "$pat" | sed -E 's#</?(parameter|function|tool_call)[^>]*># #g' | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')
                fi
                # Strip leading/trailing quotes or backticks from pattern
                pat=$(echo "$pat" | sed -E "s/^['\"\`]+|['\"\`]+$//g")
                # If pattern uses uppercase " OR ", convert to regex alternation "|"
                if [[ "$pat" == *" OR "* ]]; then
                    pat=$(echo "$pat" | sed 's/ OR /|/g')
                fi
                if [[ "$p" == /* ]]; then
                    target="$p"
                else
                    target="$workdir/$p"
                fi
                local _primary_root="${LODGE_ROOT:-}"
                if [ -z "$_primary_root" ] && [[ "$workdir" == *"/.sandboxes/"* ]]; then
                    _primary_root="${workdir%%/.sandboxes/*}"
                fi
                [ -z "$_primary_root" ] && _primary_root="${LODGE_DIR:-$(pwd)}"

                # Workspace scope guard: prevent recursive indexing outside project tree
                local _target_canon _root_canon
                _target_canon=$(readlink -f "$target" 2>/dev/null || echo "$target")
                _root_canon=$(readlink -f "$_primary_root" 2>/dev/null || echo "$_primary_root")
                if [ "$_target_canon" = "/" ] || [ "$_target_canon" = "/home" ] || [ -n "$HOME" -a "$_target_canon" = "$HOME" ] || [ "$_target_canon" = "$(dirname "$_root_canon")" ]; then
                    target="$_primary_root"
                fi
                if [ ! -e "$target" ] && [ -e "$_primary_root/$p" ]; then
                    target="$_primary_root/$p"
                fi
                if command -v rg &>/dev/null; then
                    output=$(rg -n --no-heading --color=never --max-depth 5 -g '!.git' -g '!node_modules' -g '!target' -g '!.cargo' -g '!.cache' -e "$pat" "$target" 2>&1 | head -n 100)
                    exit_code=$?
                else
                    output=$(grep -rnE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=target --exclude-dir=.cargo --exclude-dir=.cache -e "$pat" "$target" 2>&1 | head -n 100)
                    exit_code=$?
                fi
                ;;
            code_outline)
                local p target_p
                p=$(echo "$args_json" | jq -r '.path // empty')
                if [[ "$p" == /* ]]; then
                    target_p="$p"
                else
                    target_p="$workdir/$p"
                fi
                output=$(treesitter_outline "$target_p" 2>&1)
                exit_code=$?
                ;;
            code_symbol_get)
                local p sym target_p
                p=$(echo "$args_json" | jq -r '.path // empty')
                sym=$(echo "$args_json" | jq -r '.symbol // empty')
                if [[ "$p" == /* ]]; then
                    target_p="$p"
                else
                    target_p="$workdir/$p"
                fi
                output=$(treesitter_symbol "$target_p" "$sym" 2>&1)
                exit_code=$?
                ;;
            code_validate)
                local code_cnt lang
                code_cnt=$(echo "$args_json" | jq -r '.content // empty')
                lang=$(echo "$args_json" | jq -r '.language // "bash"')
                output=$(treesitter_validate "$code_cnt" "$lang" 2>&1)
                exit_code=$?
                ;;
            ask_operator)
                local q
                q=$(echo "$args_json" | jq -r '.question // empty')
                if [ "${_DISCORD_IN_SESSION:-0}" -eq 1 ] && [ -n "${DISCORD_CURRENT_CHANNEL:-}" ] && declare -f discord_send &>/dev/null; then
                    output=$(discord_send "$DISCORD_CURRENT_CHANNEL" "$q" 2>&1)
                    exit_code=$?
                else
                    output=$(ui_ask_operator "$q" 2>&1)
                    exit_code=$?
                fi
                ;;
            web_search)
                local q cnt cat eng tr
                q=$(echo "$args_json" | jq -r '.query // empty')
                cnt=$(echo "$args_json" | jq -r '.count // 5')
                cat=$(echo "$args_json" | jq -r '.category // "general"')
                eng=$(echo "$args_json" | jq -r '.engines // empty')
                tr=$(echo "$args_json" | jq -r '.time_range // empty')
                output=$(web_search "$q" "$cnt" "$cat" "$eng" "$tr" 2>&1)
                exit_code=$?
                ;;
            web_search_cross_section)
                local q s_cnt p_cnt
                q=$(echo "$args_json" | jq -r '.query // empty')
                s_cnt=$(echo "$args_json" | jq -r '.sample_size // 3')
                p_cnt=$(echo "$args_json" | jq -r '.pool_size // 12')
                source "$LODGE_DIR/lib/comms/web.sh" 2>/dev/null || true
                output=$(web_search_cross_section "$q" "$s_cnt" "$p_cnt" 2>&1)
                exit_code=$?
                ;;
            searxng_search)
                local q cat cnt py_bin
                q=$(echo "$args_json" | jq -r '.query // empty')
                cat=$(echo "$args_json" | jq -r '.category // "general"')
                cnt=$(echo "$args_json" | jq -r '.max_results // .count // 8')
                py_bin="python3"
                [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
                output=$($py_bin "$LODGE_DIR/lib/tools/searxng_backend.py" search --query "$q" --category "$cat" --max-results "$cnt" --format json 2>&1)
                exit_code=$?
                ;;
            searxng_code_search)
                local q cnt py_bin
                q=$(echo "$args_json" | jq -r '.query // empty')
                cnt=$(echo "$args_json" | jq -r '.max_results // 8')
                py_bin="python3"
                [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
                output=$($py_bin "$LODGE_DIR/lib/tools/searxng_backend.py" code --query "$q" --max-results "$cnt" --format json 2>&1)
                exit_code=$?
                ;;
            searxng_science_search)
                local q cnt py_bin
                q=$(echo "$args_json" | jq -r '.query // empty')
                cnt=$(echo "$args_json" | jq -r '.max_results // 8')
                py_bin="python3"
                [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
                output=$($py_bin "$LODGE_DIR/lib/tools/searxng_backend.py" science --query "$q" --max-results "$cnt" --format json 2>&1)
                exit_code=$?
                ;;
            hub_hw_probe|hub_library|hub_search|hub_inspect|hub_quant_fit|hub_profile_draft|hub_profiles)
                if declare -f model_hub_tool &>/dev/null; then
                    output=$(model_hub_tool "$name" "$args_json" 2>&1)
                    exit_code=$?
                else
                    output="ERROR: model hub not available"; exit_code=1
                fi
                ;;
            arxiv_search)
                local q cnt sby py_bin
                q=$(echo "$args_json" | jq -r '.query // empty')
                cnt=$(echo "$args_json" | jq -r '.max_results // 8')
                sby=$(echo "$args_json" | jq -r '.sort_by // "relevance"')
                py_bin="python3"
                [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
                output=$($py_bin "$LODGE_DIR/lib/tools/searxng_backend.py" arxiv --query "$q" --max-results "$cnt" --sort-by "$sby" --format markdown 2>&1)
                exit_code=$?
                ;;
            hn_search)
                local q cnt py_bin
                q=$(echo "$args_json" | jq -r '.query // empty')
                cnt=$(echo "$args_json" | jq -r '.max_results // 8')
                py_bin="python3"
                [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
                output=$($py_bin "$LODGE_DIR/lib/tools/searxng_backend.py" hn --query "$q" --max-results "$cnt" --format markdown 2>&1)
                exit_code=$?
                ;;
            api_search)
                local q cat no_auth limit py_bin
                q=$(echo "$args_json" | jq -r '.query // empty')
                cat=$(echo "$args_json" | jq -r '.category // empty')
                no_auth=$(echo "$args_json" | jq -r '.no_auth_only // true')
                limit=$(echo "$args_json" | jq -r '.limit // 5')
                py_bin="python3"
                [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
                local cmd=("$py_bin" "$LODGE_DIR/lib/tools/public_apis_backend.py" search --query "$q" --limit "$limit" --format json)
                [ -n "$cat" ] && cmd+=(--category "$cat")
                [ "$no_auth" = "true" ] && cmd+=(--no-auth)
                output=$("${cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            reverse_image_search)
                local img hint cnt domain py_bin
                img=$(echo "$args_json" | jq -r '.image // .image_path // empty')
                hint=$(echo "$args_json" | jq -r '.hint // .query_hint // empty')
                cnt=$(echo "$args_json" | jq -r '.max_candidates // 15')
                domain=$(echo "$args_json" | jq -r '.domain // "general"')
                py_bin="python3"
                [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
                local ris_cmd=("$py_bin" "$LODGE_DIR/lib/tools/reverse_image_search.py" "$img" --domain "$domain" --max-candidates "$cnt" --format json)
                [ -n "$hint" ] && ris_cmd+=(--hint "$hint")
                local extra_imgs=()
                while IFS= read -r _ei; do
                    [ -n "$_ei" ] && extra_imgs+=("$_ei")
                done < <(echo "$args_json" | jq -r '.extra_images[]? // empty' 2>/dev/null)
                if [ ${#extra_imgs[@]} -gt 0 ]; then
                    ris_cmd+=(--images "${extra_imgs[@]}")
                fi
                output=$("${ris_cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            web_fetch)
                local u
                u=$(echo "$args_json" | jq -r '.url // empty')
                if command -v timeout &>/dev/null; then
                    output=$(AGENT_TASK_WORKSPACE="${AGENT_TASK_WORKSPACE:-$workdir}" timeout --kill-after=5s 25s bash -c 'source "$1/lib/ui/ui.sh" 2>/dev/null; source "$1/lib/comms/web.sh" 2>/dev/null; web_fetch "$2"' _ "$LODGE_DIR" "$u" 2>&1)
                    exit_code=$?
                    if [ $exit_code -eq 124 ]; then
                        output="[FETCH FAILED | TIMEOUT 25s | URL: $u | Action: Page unresponsive or blocked by challenge; try alternative source]"
                    fi
                else
                    output=$(AGENT_TASK_WORKSPACE="${AGENT_TASK_WORKSPACE:-$workdir}" web_fetch "$u" 2>&1)
                    exit_code=$?
                fi
                ;;
            research_sandbox)
                local topic s_cnt out_file
                topic=$(echo "$args_json" | jq -r '.topic // empty')
                s_cnt=$(echo "$args_json" | jq -r '.sample_size // 3')
                out_file=$(echo "$args_json" | jq -r '.output_file // empty')
                source "$LODGE_DIR/lib/comms/web.sh" 2>/dev/null || true
                if [ -z "$topic" ]; then
                    output='{"status":"error","message":"research_sandbox requires .topic parameter"}'
                    exit_code=1
                else
                    output=$(research_sandbox "$topic" "$s_cnt" "$out_file" 2>&1)
                    exit_code=$?
                fi
                ;;
            github_search) output=$(web_search_github "$(_arg .query)" "$(_arg .count 5)" 2>&1); exit_code=$? ;;
            memory_get_section) output=$(memory_get_section "$(_arg .section)" "$workdir" 2>&1); [ -z "$output" ] && output="(empty)"; exit_code=0 ;;
            memory_update_section) memory_update_section "$(_arg .section)" "$(_arg .content)" "$workdir" 2>&1; output="Updated section '## $(_arg .section)' in GEORGE.md"; exit_code=0 ;;
            memory_append_section) memory_append_section "$(_arg .section)" "$(_arg .line)" "$workdir" 2>&1; output="Appended to section '## $(_arg .section)' in GEORGE.md"; exit_code=0 ;;
            memory_read_soul) output=$(memory_read_soul 2>&1); exit_code=0 ;;
            recall_search) output=$(recall_search "$(_arg .query)" "$(_arg .limit 5)" 2>&1); exit_code=$? ;;
            recall_ingest) local _rp="$(_arg .path)"; [ -f "$workdir/$_rp" ] && _rp="$workdir/$_rp"; output=$(recall_ingest "$_rp" 2>&1); exit_code=$? ;;
            recall_list_docs) output=$(recall_list_documents 2>&1); [ -z "$output" ] && output="(no documents indexed in recall)"; exit_code=0 ;;
            recall_archive_milestone) recall_archive_milestone "$(_arg .name)" "$(_arg .description)" 2>&1; output="Archived milestone '$(_arg .name)' into semantic memory"; exit_code=0 ;;
            journal_record) journal_write "reflection" "$(_arg .reflection)" 2>&1; output="Recorded reflection to journal: $(_arg .reflection)"; exit_code=0 ;;
            journal_read) output=$(journal_read "$(_arg .count 5)" 2>&1); [ -z "$output" ] && output="(no recent journal entries)"; exit_code=0 ;;
            model_param_set) output="Not applied: sampling/server parameters live in the operator's Model Hub profile. Ask the operator to run /models tune <profile> with {\"sampling\":{\"$(_arg .param)\":$(_arg .value)}} or use the web Model Workbench (Serve & Tune)."; exit_code=1 ;;
            model_param_get) local _mp="$(_arg .param)"; if [ -n "$_mp" ] && declare -f models_get_param &>/dev/null; then output=$(models_get_param "${LODGE_MODEL:-}" "$_mp" 2>&1) || output="(no profile value for $_mp; using global defaults)"; elif declare -f models_show_params &>/dev/null; then output=$(models_show_params 2>&1); else output="(models parameter engine loaded)"; fi; exit_code=0 ;;
            model_param_clear) local _mp="$(_arg .param)"; if [ -n "$_mp" ] && declare -f models_clear_param &>/dev/null; then output=$(models_clear_param "$_mp" 2>&1); elif declare -f models_clear_all_params &>/dev/null; then output=$(models_clear_all_params 2>&1); else output="Nothing to clear: parameters live in the Model Hub profile (/models tune)."; fi; exit_code=0 ;;
            model_endpoint_switch) _call_err endpoints_set_active_tier "endpoints_set_active_tier not available" "$(_arg .tier)" ;;
            model_endpoint_status) _call_sim endpoints_status_json "Active Tier: ${ACTIVE_TIER:-1}" ;;
            mcp_server_status) if declare -f mcp_status &>/dev/null; then output=$(mcp_status 2>&1); exit_code=0; else output="MCP engine not initialized"; exit_code=1; fi ;;
            mcp_server_add) _call_err mcp_server_add "mcp_server_add not available" "$(_arg .name)" "$(_arg .command)" "$(_arg .description)" ;;
            mcp_server_remove) _call_err mcp_server_remove "mcp_server_remove not available" "$(_arg .name)" ;;
            mcp_server_start) _call_err mcp_start "mcp_start not available" "$(_arg .name)" ;;
            mcp_server_stop) _call_err mcp_stop "mcp_stop not available" "$(_arg .name)" ;;
            mcp_tool_execute)
                local s_name t_name t_args
                s_name=$(echo "$args_json" | jq -r '.server // empty')
                t_name=$(echo "$args_json" | jq -r '.tool // empty')
                t_args=$(echo "$args_json" | jq -c '.arguments // {}')
                if declare -f mcp_tool_call &>/dev/null; then
                    output=$(mcp_tool_call "$s_name" "$t_name" "$t_args" 2>&1)
                    exit_code=$?
                else
                    output="ERROR: mcp_tool_call not available"
                    exit_code=1
                fi
                ;;
            email_send)
                if declare -f email_list_configured &>/dev/null && [ -n "$(email_list_configured 2>/dev/null)" ] && declare -f email_send &>/dev/null; then
                    output=$(email_send "" "$(_arg .to)" "$(_arg .subject)" "$(_arg .body)" 2>&1)
                    exit_code=$?
                else
                    output="NOTICE: Email provider is not configured on this node (/email setup). Deliver the response in-session or via Discord instead."
                    exit_code=0
                fi
                ;;
            email_read)
                if declare -f email_list_configured &>/dev/null && [ -n "$(email_list_configured 2>/dev/null)" ] && declare -f email_inbox &>/dev/null; then
                    output=$(email_inbox "$(_arg .count 5)" 2>&1)
                    exit_code=$?
                else
                    output="NOTICE: Email inbox is not configured on this node."
                    exit_code=0
                fi
                ;;
            phone_sms_send)
                if declare -f phone_available &>/dev/null && phone_available 2>/dev/null && declare -f phone_sms_send &>/dev/null; then
                    output=$(phone_sms_send "$(_arg .number)" "$(_arg .message)" 2>&1)
                    exit_code=$?
                else
                    output="NOTICE: Termux SMS API is not available on this host. Deliver the message in-session or via Discord instead."
                    exit_code=0
                fi
                ;;
            mqtt_publish) _call_sim mqtt_publish "Simulated MQTT publish to $(_arg .topic): $(_arg .message)" "$(_arg .topic)" "$(_arg .message)" ;;
            discord_send)
                local tgt msg
                tgt=$(echo "$args_json" | jq -r '.target // empty')
                msg=$(echo "$args_json" | jq -r '.message // empty')
                tgt=$(echo "$tgt" | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                local has_bot has_hook
                has_bot=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null || true)
                has_hook=$(api_get_key "DISCORD_WEBHOOK_URL" 2>/dev/null || true)
                # Inside a Discord run: "here"/empty/the person I'm answering → this conversation's channel.
                source "$LODGE_DIR/lib/comms/discord_outbox.sh" 2>/dev/null || true
                local _sess_tgt=""
                if [ -n "$has_bot" ] && declare -f discord_session_target &>/dev/null; then
                    _sess_tgt=$(discord_session_target "$tgt" 2>/dev/null || true)
                fi
                if [ -n "$_sess_tgt" ]; then
                    local _s_ch="${_sess_tgt%%$'\t'*}" _s_prefix="${_sess_tgt#*$'\t'}"
                    if [ -z "${msg//[[:space:]]/}" ]; then
                        output="Nothing to send (empty message)."; exit_code=1
                    elif [[ "${msg#"${msg%%[![:space:]]*}"}" =~ ^\(.*\)[[:space:]]*$ ]] || echo "$msg" | grep -qiE '^[[:space:]]*(Executing Honeydew|Wait, I|Correction: I am now|Calling google_home|Proceeding to tool|Internal note:|One more try|Just call the tool)'; then
                        output="BLOCKED: Do not send internal thoughts, parenthetical self-talk, or Honeydew step narration to Discord via discord_send. If a tool required by a Honeydew step (such as google_home_speak) is not mounted in your current tool profile, call milestone_complete(status='success') to advance past that step and write your final reply directly in plain text."
                        exit_code=1
                    elif [ -n "${session_dir:-}" ] && [ -f "${session_dir}/best_draft.posted" ] && [ "${#msg}" -lt 350 ]; then
                        output="SKIPPED: You already posted a message to this channel during this turn/run. Do NOT call discord_send repeatedly with short thoughts or status updates — finish your work (or call milestone_complete) and write your final reply directly as plain text."
                        exit_code=0
                    else
                        if declare -f discord_sanitize_egress &>/dev/null; then
                            msg=$(discord_sanitize_egress "$msg" "${_DISCORD_CURRENT_AUTHOR_ID:-}" "${_DISCORD_CURRENT_AUTHOR:-}")
                        fi
                        [ -n "$_s_prefix" ] && [[ "$msg" != "$_s_prefix"* ]] && msg="${_s_prefix}${msg}"
                        output=$(discord_send "$_s_ch" "$msg" 2>&1)
                        exit_code=$?
                        if [ "$exit_code" -eq 0 ]; then
                            output+=$'\n'"[Posted in this conversation's channel${_DISCORD_CURRENT_CHANNEL_NAME:+ #${_DISCORD_CURRENT_CHANNEL_NAME}}. The user can already see it — do not repeat it in your final reply. To revise it, use discord_edit. DMs need target \"dm:<user>\" or discord_dm.]"
                            [ -n "${_SESSION_DIR:-}" ] && touch "${_SESSION_DIR}/best_draft.posted" 2>/dev/null
                            [ -n "${session_dir:-}" ] && touch "${session_dir}/best_draft.posted" 2>/dev/null
                        fi
                    fi
                elif [ -n "$has_bot" ]; then
                    if [ -n "$tgt" ] && [ "$tgt" != "webhook" ] && [ "$tgt" != "default" ]; then
                        output=$(discord_send "$tgt" "$msg" 2>&1)
                        exit_code=$?
                    else
                        local def_chan
                        def_chan=$(discord_default_channel 2>/dev/null || true)
                        [ -z "$def_chan" ] && def_chan=$(discord_channel_resolve "general" 2>/dev/null || true)
                        if [ -n "$def_chan" ]; then
                            output=$(discord_send "$def_chan" "$msg" 2>&1)
                            exit_code=$?
                        elif [ -n "$has_hook" ]; then
                            output=$(discord_webhook "$msg" 2>&1)
                            exit_code=$?
                        else
                            output="Could not resolve default channel. Specify target channel/server or sync with /social discord channels sync"
                            exit_code=1
                        fi
                    fi
                elif [ -n "$has_hook" ]; then
                    output=$(discord_webhook "$msg" 2>&1)
                    exit_code=$?
                else
                    output="Discord is not configured. Set DISCORD_BOT_TOKEN with: /api keys set DISCORD_BOT_TOKEN <token>"
                    exit_code=1
                fi
                ;;
            discord_edit)
                # Edit a message George posted earlier in THIS run (default: the last one).
                local e_msg e_mid e_ch
                e_msg=$(echo "$args_json" | jq -r '.message // empty')
                e_mid=$(echo "$args_json" | jq -r '.message_id // empty' | tr -cd '0-9')
                source "$LODGE_DIR/lib/comms/discord_outbox.sh" 2>/dev/null || true
                source "$LODGE_DIR/lib/comms/discord_status.sh" 2>/dev/null || true
                if [ "${_DISCORD_IN_SESSION:-0}" != "1" ] || [ -z "${DISCORD_RUN_OUTBOX:-}" ]; then
                    output="discord_edit only works inside a Discord conversation run."; exit_code=1
                elif [ -z "${e_msg//[[:space:]]/}" ]; then
                    output="message is required."; exit_code=1
                else
                    [ -z "$e_mid" ] && e_mid=$(discord_outbox_last_id 2>/dev/null || true)
                    if [ -z "$e_mid" ] || ! discord_outbox_has_id "$e_mid"; then
                        output="No message from this run to edit${e_mid:+ (id $e_mid was not posted by this run)}. Use discord_send first."; exit_code=1
                    else
                        e_ch=$(discord_outbox_channel_of "$e_mid")
                        declare -f discord_sanitize_egress &>/dev/null && \
                            e_msg=$(discord_sanitize_egress "$e_msg" "${_DISCORD_CURRENT_AUTHOR_ID:-}" "${_DISCORD_CURRENT_AUTHOR:-}")
                        if [ ${#e_msg} -gt 2000 ]; then
                            output="Edited text is ${#e_msg} chars; Discord's limit is 2000. Shorten it, or post the rest with discord_send."; exit_code=1
                        elif discord_status_edit "$e_ch" "$e_mid" "$e_msg"; then
                            discord_outbox_record "$e_ch" "$e_mid" "$e_msg" "edit"
                            output="Edited message $e_mid. The user sees the new text — do not repeat it in your final reply."; exit_code=0
                        else
                            output="Discord edit failed for message $e_mid."; exit_code=1
                        fi
                    fi
                fi
                ;;
            discord_dm)
                local usr msg
                usr=$(echo "$args_json" | jq -r '.user // empty')
                msg=$(echo "$args_json" | jq -r '.message // empty')
                usr=$(echo "$usr" | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                local has_bot
                has_bot=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null || true)
                if [ -n "$has_bot" ]; then
                    source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null || true
                    local _dm_target="${usr:-${DISCORD_DEFAULT_USER:-${DISCORD_OWNER_USERNAME:-owner}}}"
                    output=$(discord_dm "$_dm_target" "$msg" 2>&1)
                    exit_code=$?
                else
                    output="Discord bot token is not configured. Set DISCORD_BOT_TOKEN with: /api keys set DISCORD_BOT_TOKEN <token>"
                    exit_code=1
                fi
                ;;
            discord_send_file)
                local tgt file_p msg
                tgt=$(echo "$args_json" | jq -r '.target // empty')
                file_p=$(echo "$args_json" | jq -r '.file_path // empty')
                msg=$(echo "$args_json" | jq -r '.message // empty')
                tgt=$(echo "$tgt" | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                file_p=$(echo "$file_p" | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                source "$LODGE_DIR/lib/comms/discord_bridge.sh" 2>/dev/null || true
                source "$LODGE_DIR/lib/comms/discord_outbox.sh" 2>/dev/null || true
                # Resolve relative file paths against workdir or channel artifact store
                if [ -n "$file_p" ] && [ ! -f "$file_p" ]; then
                    if [ -f "$workdir/$file_p" ]; then
                        file_p="$workdir/$file_p"
                    elif [ -n "${_DISCORD_CURRENT_CHANNEL:-}" ] && [ -f "${GEORGE_DIR:-$LODGE_DIR/.george}/artifacts/channel_${_DISCORD_CURRENT_CHANNEL}/${file_p#artifacts/}" ]; then
                        file_p="${GEORGE_DIR:-$LODGE_DIR/.george}/artifacts/channel_${_DISCORD_CURRENT_CHANNEL}/${file_p#artifacts/}"
                    elif [ -n "${_DISCORD_CURRENT_CHANNEL:-}" ] && [ -f "${GEORGE_DIR:-$LODGE_DIR/.george}/artifacts/channel_${_DISCORD_CURRENT_CHANNEL}/outputs/$(basename "$file_p")" ]; then
                        file_p="${GEORGE_DIR:-$LODGE_DIR/.george}/artifacts/channel_${_DISCORD_CURRENT_CHANNEL}/outputs/$(basename "$file_p")"
                    fi
                fi
                local has_bot
                has_bot=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null || true)
                if [ -n "$has_bot" ]; then
                    # Inside a Discord run: empty/"here"/current/channel name/author → this conversation's channel
                    local _sess_tgt=""
                    if declare -f discord_session_target &>/dev/null; then
                        _sess_tgt=$(discord_session_target "$tgt" 2>/dev/null || true)
                    fi
                    if [ -n "$_sess_tgt" ]; then
                        local _s_ch="${_sess_tgt%%$'\t'*}" _s_prefix="${_sess_tgt#*$'\t'}"
                        if [ -n "$file_p" ]; then
                            [ -n "$_s_prefix" ] && [ -n "$msg" ] && [[ "$msg" != "$_s_prefix"* ]] && msg="${_s_prefix}${msg}"
                            output=$(discord_send_file "$_s_ch" "$file_p" "$msg" 2>&1)
                            exit_code=$?
                        else
                            output="file_path is required for discord_send_file."
                            exit_code=1
                        fi
                    elif [ -n "$tgt" ] && [ -n "$file_p" ]; then
                        output=$(discord_send_file "$tgt" "$file_p" "$msg" 2>&1)
                        exit_code=$?
                    else
                        output="Target and file_path are required for discord_send_file."
                        exit_code=1
                    fi
                else
                    output="Discord bot token is not configured. Set DISCORD_BOT_TOKEN with: /api keys set DISCORD_BOT_TOKEN <token>"
                    exit_code=1
                fi
                ;;
            artifact_publish)
                local file_p caption script_p label tgt
                file_p=$(echo "$args_json" | jq -r '.file_path // empty' | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                caption=$(echo "$args_json" | jq -r '.caption // empty')
                script_p=$(echo "$args_json" | jq -r '.script_path // empty' | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                label=$(echo "$args_json" | jq -r '.label // empty' | tr -cd 'A-Za-z0-9._-')
                tgt=$(echo "$args_json" | jq -r '.target // empty' | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                if [ -n "$file_p" ] && [ ! -f "$file_p" ] && [ -f "$workdir/$file_p" ]; then
                    file_p="$workdir/$file_p"
                fi
                if [ -n "$script_p" ] && [ ! -f "$script_p" ] && [ -f "$workdir/$script_p" ]; then
                    script_p="$workdir/$script_p"
                fi
                if [ -z "$file_p" ] || [ ! -f "$file_p" ]; then
                    output="Artifact file does not exist: ${file_p:-<empty>}"
                    exit_code=1
                else
                    local _fsize
                    _fsize=$(stat -c %s "$file_p" 2>/dev/null || wc -c < "$file_p" 2>/dev/null || echo 0)
                    if [ "${_fsize:-0}" -le 0 ]; then
                        output="Artifact file is empty (0 bytes): $file_p"
                        exit_code=1
                    elif [ "${_fsize:-0}" -gt 26214400 ]; then
                        output="Artifact exceeds Discord 25 MB upload limit (${_fsize} bytes): $file_p"
                        exit_code=1
                    else
                        # Magic-byte sanity check for common visual/doc formats
                        local _ext="${file_p##*.}" _magic_ok=1
                        _ext="${_ext,,}"
                        case "$_ext" in
                            png) head -c 8 "$file_p" 2>/dev/null | od -An -tx1 | tr -d ' \n' | grep -qi '^89504e470d0a1a0a' || _magic_ok=0 ;;
                            jpg|jpeg) head -c 3 "$file_p" 2>/dev/null | od -An -tx1 | tr -d ' \n' | grep -qi '^ffd8ff' || _magic_ok=0 ;;
                            pdf) head -c 4 "$file_p" 2>/dev/null | grep -q '^%PDF' || _magic_ok=0 ;;
                        esac
                        if [ "$_magic_ok" -eq 0 ]; then
                            output="Artifact integrity check failed: '$file_p' does not have valid .$_ext file header bytes."
                            exit_code=1
                        else
                            local _chan_key="${_DISCORD_CURRENT_CHANNEL:-local}"
                            local _pantry="${GEORGE_DIR:-$LODGE_DIR/.george}/artifacts/channel_${_chan_key}"
                            mkdir -p "$_pantry/outputs" "$_pantry/scripts" 2>/dev/null || true
                            local _bname _ts _archived_out _archived_script=""
                            _bname=$(basename "$file_p")
                            _ts=$(date '+%Y%m%d_%H%M%S')
                            _archived_out="$_pantry/outputs/${_bname}"
                            cp -f "$file_p" "$_archived_out" 2>/dev/null || true
                            if [ -n "$label" ]; then
                                cp -f "$file_p" "$_pantry/outputs/${label}_${_bname}" 2>/dev/null || true
                            fi
                            if [ -n "$script_p" ] && [ -f "$script_p" ]; then
                                _archived_script="$_pantry/scripts/$(basename "$script_p")"
                                cp -f "$script_p" "$_archived_script" 2>/dev/null || true
                            fi
                            jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg file "$_archived_out" --arg script "$_archived_script" --arg label "$label" --argjson bytes "$_fsize" \
                                '{timestamp:$ts, file:$file, script:$script, label:$label, bytes:$bytes}' >> "$_pantry/manifest.jsonl" 2>/dev/null || true

                            source "$LODGE_DIR/lib/comms/discord_bridge.sh" 2>/dev/null || true
                            source "$LODGE_DIR/lib/comms/discord_outbox.sh" 2>/dev/null || true
                            local has_bot; has_bot=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null || true)
                            if [ -n "$has_bot" ] && { [ -n "$tgt" ] || [ -n "${_DISCORD_CURRENT_CHANNEL:-}" ]; }; then
                                local _sess_tgt="" _dest="$tgt"
                                declare -f discord_session_target &>/dev/null && _sess_tgt=$(discord_session_target "$tgt" 2>/dev/null || true)
                                [ -n "$_sess_tgt" ] && _dest="${_sess_tgt%%$'\t'*}"
                                [ -z "$_dest" ] && _dest="${_DISCORD_CURRENT_CHANNEL:-}"
                                local _up_out
                                _up_out=$(discord_send_file "$_dest" "$_archived_out" "$caption" 2>&1)
                                exit_code=$?
                                output="Archived to: $_archived_out${_archived_script:+ (script: $_archived_script)} (${_fsize} bytes)"$'\n'"$_up_out"
                            else
                                output="Archived locally to: $_archived_out${_archived_script:+ (script: $_archived_script)} (${_fsize} bytes) — no active Discord target/token for upload."
                                exit_code=0
                            fi
                        fi
                    fi
                fi
                ;;
            venv_pkg_install)
                local _v_act _v_pkgs _v_approve _py_bin="python3"
                _v_act=$(echo "$args_json" | jq -r '.action // "audit"')
                _v_approve=$(echo "$args_json" | jq -r '.approve_tier_b // false')
                local _pkg_arr=()
                while IFS= read -r _p; do
                    [ -n "$_p" ] && _pkg_arr+=("$_p")
                done < <(echo "$args_json" | jq -r '.packages[]? // empty')
                if [ "$_v_act" = "allowlist" ]; then
                    output=$("$_py_bin" "$LODGE_DIR/lib/tools/venv_pkg_guard.py" allowlist 2>&1)
                    exit_code=$?
                elif [ ${#_pkg_arr[@]} -eq 0 ]; then
                    output="packages array is required for action '$_v_act'."
                    exit_code=1
                elif [ "$_v_act" = "audit" ]; then
                    output=$("$_py_bin" "$LODGE_DIR/lib/tools/venv_pkg_guard.py" audit "${_pkg_arr[@]}" 2>&1)
                    exit_code=$?
                elif [ "$_v_act" = "install" ]; then
                    local _inst_flags=()
                    [ "$_v_approve" = "true" ] && _inst_flags+=(--approve)
                    output=$("$_py_bin" "$LODGE_DIR/lib/tools/venv_pkg_guard.py" install "${_inst_flags[@]}" "${_pkg_arr[@]}" 2>&1)
                    exit_code=$?
                else
                    output="Unknown venv_pkg_install action: $_v_act"
                    exit_code=1
                fi
                ;;
            tool_forge)
                local _tf_act _tf_name _tf_lang _tf_desc _tf_code _tf_args
                _tf_act=$(echo "$args_json" | jq -r '.action // "list"')
                _tf_name=$(echo "$args_json" | jq -r '.name // empty')
                _tf_lang=$(echo "$args_json" | jq -r '.lang // "python"')
                _tf_desc=$(echo "$args_json" | jq -r '.description // empty')
                _tf_code=$(echo "$args_json" | jq -r '.code // empty')
                _tf_args=$(echo "$args_json" | jq -r '.args // "{}"')
                case "$_tf_act" in
                    list)
                        output=$(python3 "$LODGE_DIR/lib/tools/tool_forge.py" list 2>&1)
                        exit_code=$?
                        ;;
                    forge)
                        output=$(python3 "$LODGE_DIR/lib/tools/tool_forge.py" forge --name "$_tf_name" --lang "$_tf_lang" --description "$_tf_desc" --code "$_tf_code" --smoke-args "$_tf_args" 2>&1)
                        exit_code=$?
                        ;;
                    run)
                        output=$(python3 "$LODGE_DIR/lib/tools/tool_forge.py" run --name "$_tf_name" --args "$_tf_args" 2>&1)
                        exit_code=$?
                        ;;
                    remove)
                        output=$(python3 "$LODGE_DIR/lib/tools/tool_forge.py" remove --name "$_tf_name" 2>&1)
                        exit_code=$?
                        ;;
                    *)
                        output="Unknown tool_forge action: $_tf_act"
                        exit_code=1
                        ;;
                esac
                ;;
            discord_read)
                local chan cnt
                chan=$(echo "$args_json" | jq -r '.channel // empty')
                cnt=$(echo "$args_json" | jq -r '.count // 10')
                chan=$(echo "$chan" | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null || true
                local has_bot
                has_bot=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null || true)
                if [ -n "$has_bot" ]; then
                    if [ -n "$chan" ]; then
                        output=$(discord_read "$chan" "$cnt" 2>&1)
                        exit_code=$?
                    else
                        output="Channel parameter is required for discord_read."
                        exit_code=1
                    fi
                else
                    output="Discord bot token is not configured. Set DISCORD_BOT_TOKEN with: /api keys set DISCORD_BOT_TOKEN <token>"
                    exit_code=1
                fi
                ;;
            telegram_send)
                if [ "${_DISCORD_IN_SESSION:-0}" = "1" ] || ! (declare -f social_provider_configured &>/dev/null && social_provider_configured telegram); then
                    output="NOTICE: Telegram is not configured or you are in an active Discord session. Do NOT call telegram_send; reply directly in-session or use discord_send."
                    exit_code=0
                else
                    output=$(telegram_send "$(_arg .message)" 2>&1)
                    exit_code=$?
                fi
                ;;
            social_post) output=$(social_post "$(_arg .network all)" "$(_arg .text)" 2>&1); exit_code=$? ;;
            system_vitals) output=$(vitals_context 2>&1); exit_code=$? ;;
            subagent_delegate) output=$(subagents_spawn "$(_arg .tier 1)" "$(_arg .task)" "Delegated from primary" "$workdir" 2>&1); exit_code=$? ;;
            subagent_spawn) local _obj="$(_arg .objective)"; if [ -z "$_obj" ]; then output="ERROR: objective is required"; exit_code=1; else output=$(subagents_spawn "$(_arg .tier 1)" "$_obj" "$(_arg .context)" "$workdir" "$(_arg .max_turns 200)" "$(_arg .async false)" 2>&1); exit_code=$?; fi ;;
            subagent_status) local _sid="$(_arg .sub_id)"; if [ -n "$_sid" ]; then output=$(jq --arg id "$_sid" '.[] | select(.id == $id)' "$(subagents_registry_file)" 2>/dev/null); [ -z "$output" ] && output="Subagent '$_sid' not found in registry."; else output=$(subagents_get_active 2>&1); fi; exit_code=0 ;;
            subagent_logs) local _sid="$(_arg .sub_id)"; if [ -z "$_sid" ]; then output="ERROR: sub_id is required"; exit_code=1; else output=$(subagents_logs "$_sid" "$(_arg .lines 50)" 2>&1); exit_code=$?; fi ;;
            subagent_diff) output=$(subagents_diff "$(_arg .sub_id)" "$(_arg .stat_only false)" 2>&1); exit_code=$? ;;
            subagent_merge) output=$(subagents_merge "$(_arg .sub_id)" "$(_arg .strategy merge)" 2>&1); exit_code=$? ;;
            subagent_reap) output=$(subagents_reap "$(_arg .sub_id)" 2>&1); exit_code=$? ;;
            subagent_intervene)
                local sub_id cmd fifo sbox_dir
                sub_id=$(echo "$args_json" | jq -r '.sub_id // empty')
                cmd=$(echo "$args_json" | jq -r '.command // empty')
                sbox_dir="$LODGE_DIR/.sandboxes/$sub_id"
                fifo="$sbox_dir/control.fifo"
                if [ -z "$sub_id" ] || [ -z "$cmd" ]; then
                    output="ERROR: sub_id and command are required"
                    exit_code=1
                else
                    case "$cmd" in
                        PAUSE)
                            touch "$sbox_dir/.pause_requested" 2>/dev/null || true
                            touch "$sbox_dir/.george/workspaces/${sub_id}/.pause_requested" 2>/dev/null || true
                            touch "$sbox_dir/.george/workspaces/sub_${sub_id}/.pause_requested" 2>/dev/null || true
                            declare -f fifo_flow_pause &>/dev/null && { fifo_flow_pause "$sub_id" 2>/dev/null || fifo_flow_pause "sub_${sub_id}" 2>/dev/null || true; }
                            ;;
                        RESUME)
                            rm -f "$sbox_dir/.pause_requested" "$sbox_dir/.george/workspaces/${sub_id}/.pause_requested" "$sbox_dir/.george/workspaces/sub_${sub_id}/.pause_requested" 2>/dev/null || true
                            touch "$sbox_dir/.resume_requested" 2>/dev/null || true
                            declare -f fifo_flow_resume &>/dev/null && { fifo_flow_resume "$sub_id" 2>/dev/null || fifo_flow_resume "sub_${sub_id}" 2>/dev/null || true; }
                            ;;
                        ABORT)
                            touch "$sbox_dir/.abort" 2>/dev/null || true
                            touch "$sbox_dir/.george/workspaces/${sub_id}/.abort" 2>/dev/null || true
                            touch "$sbox_dir/.george/workspaces/sub_${sub_id}/.abort" 2>/dev/null || true
                            declare -f fifo_channel_close &>/dev/null && { fifo_channel_close "$sub_id" 2>/dev/null || fifo_channel_close "sub_${sub_id}" 2>/dev/null || true; }
                            ;;
                        *)
                            printf '%s\n' "$cmd" > "$sbox_dir/.guidance_injection" 2>/dev/null || true
                            printf '%s\n' "$cmd" > "$sbox_dir/.george/workspaces/${sub_id}/.guidance_injection" 2>/dev/null || true
                            printf '%s\n' "$cmd" > "$sbox_dir/.george/workspaces/sub_${sub_id}/.guidance_injection" 2>/dev/null || true
                            ;;
                    esac
                    if [ -p "$fifo" ]; then
                        (
                            exec 3<>"$fifo"
                            printf '%s\n' "$cmd" >&3
                            exec 3>&-
                        ) 2>/dev/null &
                        disown $! 2>/dev/null || true
                    fi
                    output="Command '$cmd' transmitted to subagent $sub_id (file state + control FIFO updated)."
                    exit_code=0
                fi
                ;;
            subagent_await)
                local sub_id timeout elapsed=0 reg_file
                sub_id=$(echo "$args_json" | jq -r '.sub_id // empty')
                timeout=$(echo "$args_json" | jq -r '.timeout_seconds // 120')
                reg_file=$(subagents_registry_file)
                if [ -z "$sub_id" ]; then
                    output="ERROR: sub_id required"
                    exit_code=1
                elif [ ! -f "$reg_file" ] || [ -z "$(jq -r --arg id "$sub_id" '.[] | select(.id == $id) | .id' "$reg_file" 2>/dev/null)" ]; then
                    output="ERROR: Subagent '$sub_id' not found in registry."
                    exit_code=1
                else
                    while [ "$elapsed" -lt "$timeout" ]; do
                        local st spid
                        st=$(jq -r --arg id "$sub_id" '.[] | select(.id == $id) | .status' "$reg_file" 2>/dev/null)
                        spid=$(jq -r --arg id "$sub_id" '.[] | select(.id == $id) | .pid // 0' "$reg_file" 2>/dev/null)
                        if [ "$st" = "COMPLETED" ] || [ "$st" = "FAILED" ] || [ "$st" = "ORPHAN_REAPED" ] || [ "$st" = "KILLED_EXIT" ] || [ "$st" = "PAUSED_BLOCKED" ] || [ "$st" = "REAPED" ]; then
                            local sub_res
                            sub_res=$(jq -r --arg id "$sub_id" '.[] | select(.id == $id) | .result' "$reg_file" 2>/dev/null)
                            output="Subagent $sub_id concluded with status $st: $sub_res"
                            exit_code=0
                            break
                        fi
                        if [ -n "$spid" ] && [ "$spid" -gt 0 ] 2>/dev/null && [ "$spid" -ne "$$" ] && ! kill -0 "$spid" 2>/dev/null; then
                            subagents_update_status "$sub_id" "FAILED" "" "Subagent process PID $spid terminated prematurely"
                            output="Subagent $sub_id process PID $spid terminated prematurely (crashed or killed)."
                            exit_code=1
                            break
                        fi
                        sleep 1
                        elapsed=$((elapsed + 1))
                    done
                    if [ -z "$output" ]; then
                        output="Timed out waiting for subagent $sub_id after ${timeout}s"
                        exit_code=124
                    fi
                fi
                ;;
            code_symbol_read)
                local sym fpath
                sym=$(echo "$args_json" | jq -r '.symbol_name // empty')
                fpath=$(echo "$args_json" | jq -r '.file_path // empty')
                if [ -z "$sym" ]; then
                    output="ERROR: symbol_name required"
                    exit_code=1
                else
                    local target=""
                    [ -n "$fpath" ] && target="$workdir/$fpath"
                    output=$(recall_symbol_get "$sym" "$target" 2>&1)
                    exit_code=$?
                fi
                ;;
            code_symbol_patch)
                local fpath sym code
                fpath=$(echo "$args_json" | jq -r '.file_path // empty')
                sym=$(echo "$args_json" | jq -r '.symbol_name // empty')
                code=$(echo "$args_json" | jq -r '.new_symbol_code // empty')
                if [ -z "$fpath" ] || [ -z "$sym" ] || [ -z "$code" ]; then
                    output="ERROR: file_path, symbol_name, and new_symbol_code are required"
                    exit_code=1
                else
                    local target="$workdir/$fpath"
                    if [ ! -f "$target" ]; then
                        output="ERROR: File not found: $fpath"
                        exit_code=1
                    else
                        source "$LODGE_DIR/lib/tools/treesitter.sh" 2>/dev/null || true
                        local v_err
                        v_err=$(treesitter_validate "$code" "$(treesitter_detect_lang "$target")" 2>&1) || {
                            output="ERROR: AST validation failed: $v_err"
                            exit_code=1
                        }
                        if [ $exit_code -eq 0 ]; then
                            recall_symbol_sync "$target"
                            local range
                            range=$(sqlite3 -separator '|' "$RECALL_DB" "SELECT start_line, end_line FROM code_symbols WHERE file_path = '$(readlink -f "$target")' AND symbol_name = '$sym' LIMIT 1;" 2>/dev/null)
                            if [ -z "$range" ]; then
                                output="ERROR: Symbol '$sym' not found in $fpath"
                                exit_code=1
                            else
                                local sl el
                                IFS='|' read -r sl el <<< "$range"
                                local tmpf="${target}.tmp.$$"
                                {
                                    if [ "$sl" -gt 1 ]; then
                                        sed -n "1,$((sl - 1))p" "$target"
                                    fi
                                    printf '%s\n' "$code"
                                    sed -n "$((el + 1)),\$p" "$target"
                                } > "$tmpf" && mv "$tmpf" "$target"
                                recall_symbol_sync "$target"
                                output="Successfully patched symbol '$sym' in $fpath (lines $sl-$el)"
                                exit_code=0
                            fi
                        fi
                    fi
                fi
                ;;
            reflexive_status) _call_sim reflexive_status "Reflexive layer loaded (all subsystems active)" ;;
            reflexive_toggle) _call_sim reflexive_toggle "Reflexive toggle $(_arg .subsystem) $(_arg .state)" "$(_arg .subsystem)" "$(_arg .state)" ;;
            reflexive_metacog_assess) _call_sim reflexive_metacog_assess "Reflexive metacognition: reasoning path verified" ;;
            reflexive_prompt_grade) _call_sim reflexive_prompt_record "Recorded prompt grade $(_arg .score 1)" "$(_arg .score 1)" "$(_arg .hint)" ;;
            wallet_status|wallet_balances|wallet_receive|wallet_send_preview|cardano_dex_swap|cardano_p2p_underwrite|cardano_flash_sniper|polygon_swap_usdc|polygon_approve_polymarket|cardano_stop_manage|cardano_desk_summary|crypto_desk_summary|cardano_order_tool|crypto_order|cardano_triangle_deploy|crypto_triangle_deploy|crypto_review|crypto_scan|crypto_plan|crypto_execute|crypto_standing_order|crypto_journal|crypto_backtest|operator_notify|operator_ask|crypto_analyze|crypto_forecast|crypto_chart|crypto_orders|crypto_place_limit|crypto_reclaim_order|fund_treasury|fund_opportunities|fund_state|fund_ledger_add|lending_underwrite|lending_request|lending_service|lending_book|crypto_price_ladder|pool_health|polymarket_scan|polymarket_arbitrage|wallet_set_network|crypto_send|solana_airdrop)
                _native_dispatch_crypto "$name" "$args_json" "$workdir"
                ;;
            vision_analyze) output=$(cmd_vision_direct "$(_arg .image)" "$(_arg .prompt)" "$workdir" 2>&1); exit_code=$? ;;
            sdr_query)
                local _py="python3"
                [ -x "$LODGE_DIR/.venv/bin/python" ] && _py="$LODGE_DIR/.venv/bin/python"
                local _hrs _tg _unit _cat _search _em _mode _lim _qcmd
                _hrs=$(echo "$args_json" | jq -r '.hours // 24' 2>/dev/null)
                _tg=$(echo "$args_json" | jq -r '.talkgroup // empty' 2>/dev/null)
                _unit=$(echo "$args_json" | jq -r '.unit_id // empty' 2>/dev/null)
                _cat=$(echo "$args_json" | jq -r '.category // empty' 2>/dev/null)
                _search=$(echo "$args_json" | jq -r '.search // empty' 2>/dev/null)
                _em=$(echo "$args_json" | jq -r '.emergency_only // false' 2>/dev/null)
                _mode=$(echo "$args_json" | jq -r '.mode // "summary"' 2>/dev/null)
                _lim=$(echo "$args_json" | jq -r '.limit // 40' 2>/dev/null)
                _qcmd=("$_py" "$LODGE_DIR/lib/tools/sdr_ingest.py" --query --hours "${_hrs:-24}" --mode "${_mode:-summary}" --limit "${_lim:-40}")
                [ -n "$_tg" ] && _qcmd+=(--talkgroup "$_tg")
                [ -n "$_unit" ] && _qcmd+=(--unit "$_unit")
                [ -n "$_cat" ] && _qcmd+=(--category "$_cat")
                [ -n "$_search" ] && _qcmd+=(--search "$_search")
                [ "$_em" = "true" ] && _qcmd+=(--emergency-only)
                output=$("${_qcmd[@]}" 2>&1)
                exit_code=$?
                ;;
            sdr_listen)
                local _py="python3"
                [ -x "$LODGE_DIR/.venv/bin/python" ] && _py="$LODGE_DIR/.venv/bin/python"
                local _cid _prm _lcmd
                _cid=$(echo "$args_json" | jq -r '.call_id // "latest"' 2>/dev/null)
                _prm=$(echo "$args_json" | jq -r '.prompt // empty' 2>/dev/null)
                _lcmd=("$_py" "$LODGE_DIR/lib/tools/sdr_ingest.py" --listen "${_cid:-latest}")
                [ -n "$_prm" ] && _lcmd+=(--prompt "$_prm")
                output=$("${_lcmd[@]}" 2>&1)
                exit_code=$?
                ;;
            file_download) output=$(cmd_download "$(_arg .source) $(_arg .destination)" "$workdir" 2>&1); exit_code=$? ;;
            service_list) output=$(cmd_service "list" "$workdir" 2>&1); exit_code=$? ;;
            service_manage) output=$(cmd_service "$(_arg .action) $(_arg .name) $(_arg .args)" "$workdir" 2>&1); exit_code=$? ;;
            sandbox_create) _call_sim sandbox_create "Created sandbox $(_arg .name)" "$(_arg .name)" "$workdir" ;;
            sandbox_exec) _call_sim sandbox_exec "Executed in sandbox $(_arg .name): $(_arg .command)" "$(_arg .name)" "$(_arg .command)" ;;
            sandbox_list) _call_sim sandbox_list "(no active sandboxes)" ;;
            sandbox_remove) _call_sim sandbox_remove "Removed sandbox $(_arg .name)" "$(_arg .name)" ;;
            container_exec) _call_sim container_exec "Executed in container $(_arg .distro ubuntu): $(_arg .command)" "$(_arg .distro ubuntu)" "$(_arg .command)" ;;
            project_build) output=$(cmd_build "$(_arg .args)" "$workdir" 2>&1); exit_code=$? ;;
            project_test) output=$(cmd_test "$(_arg .args)" "$workdir" 2>&1); exit_code=$? ;;
            file_edit)
                local pth expr has_structured
                pth=$(echo "$args_json" | jq -r '.path // empty')
                expr=$(echo "$args_json" | jq -r '.expression // empty')
                has_structured=$(echo "$args_json" | jq -r 'if ((.edits | type == "array") and (.edits | length > 0)) or (.target != null) or (.old_text != null) or (.old_str != null) or (.search != null) or ((.start_line != null) and (.replacement != null or .new_text != null or .new_str != null or .replace != null)) then "1" else "0" end' 2>/dev/null || echo "0")
                if [[ "$pth" == "${HOME#/}"/* ]]; then pth="/$pth"; fi
                local _fe_target="$pth"
                [ -f "$_fe_target" ] || _fe_target="$workdir/$pth"
                local _fe_snap="" _fe_was_valid=0
                if [ -f "$_fe_target" ]; then
                    _fe_snap=$(mktemp 2>/dev/null) && cp -p "$_fe_target" "$_fe_snap" 2>/dev/null
                    case "$_fe_target" in *.sh|*.bash) bash -n "$_fe_target" 2>/dev/null && _fe_was_valid=1 ;; esac
                fi
                declare -f cmd_edit &>/dev/null || source "$LODGE_DIR/commands/edit.sh" 2>/dev/null || true
                declare -f tools_with_file_lock &>/dev/null || source "$LODGE_DIR/lib/tools/tools.sh" 2>/dev/null || true
                output=""; exit_code=255
                if [ "$has_structured" = "1" ]; then
                    output=$(EDITS_JSON="$args_json" LODGE_RAW_CONTENT_SET=1 tools_with_file_lock "$_fe_target" cmd_edit "$pth" "$workdir" 2>&1)
                    exit_code=$?
                else
                    # Backward-compatible single-line sed substitution (only for files inside workspace)
                    if [[ "$expr" != *$'\n'* ]] && [[ "$expr" =~ ^[[:space:]]*s([/|#,]) ]] && [ -f "$_fe_target" ]; then
                        local _fe_real _fe_root
                        _fe_real=$(realpath -m "$_fe_target" 2>/dev/null)
                        _fe_root=$(realpath -m "${workdir:-$PWD}" 2>/dev/null)
                        if [ -n "$_fe_real" ] && [[ "$_fe_real" == "$_fe_root"/* || "$_fe_real" == "/tmp/"* || "$_fe_real" == "/var/tmp/"* ]]; then
                            local _fe_err_s
                            if _fe_err_s=$(tools_with_file_lock "$_fe_real" sed --sandbox -i -- "${expr#"${expr%%[![:space:]]*}"}" "$_fe_real" 2>&1); then
                                if [ -n "$_fe_snap" ] && cmp -s "$_fe_snap" "$_fe_real"; then
                                    output="ERROR: sed pattern matched nothing; $pth unchanged. Check the exact text with file_read, or pass target and replacement to file_edit."
                                    exit_code=1
                                else
                                    output="Edited $pth via sed: $expr"
                                    exit_code=0
                                fi
                            else
                                output="ERROR: invalid sed expression ($_fe_err_s); $pth unchanged."
                                exit_code=1
                            fi
                        fi
                    fi
                    if [ "$exit_code" -eq 255 ]; then
                        output=$(EDITS_JSON="$args_json" LODGE_RAW_CONTENT="$expr" LODGE_RAW_CONTENT_SET=1 tools_with_file_lock "$_fe_target" cmd_edit "$pth" "$workdir" 2>&1)
                        exit_code=$?
                    fi
                    # Fallback: if cmd_edit rejected the block-replace format but the expression is
                    # plain code (e.g. a new function), append it. Never append edit *instructions*
                    # (sed scripts / SEARCH-REPLACE markers): that pastes them into the file as code.
                    if [ $exit_code -ne 0 ] && echo "$output" | grep -qiE "(invalid block-replace format|Could not parse any search/replace blocks)" && [ -n "$expr" ]; then
                        if [[ "$expr" =~ ^[[:space:]]*s[/|#,] ]] || [[ "$expr" == *"<<<<<<<"* ]] || [[ "$expr" == *">>>>>>>"* ]]; then
                            output="ERROR: file_edit could not apply this edit and did NOT change $pth. Multi-line sed (s/old/new/) is not supported. Prefer structured target + replacement (or edits array), or use SEARCH/REPLACE blocks:
<<<<<<< SEARCH
exact existing lines
=======
replacement lines
>>>>>>> REPLACE
or rewrite the file with file_write."
                            exit_code=1
                        else
                            declare -f cmd_append &>/dev/null || source "$LODGE_DIR/commands/append.sh" 2>/dev/null || true
                            output=$(LODGE_RAW_CONTENT="$expr" LODGE_RAW_CONTENT_SET=1 tools_with_file_lock "$_fe_target" cmd_append "$pth" "$workdir" 2>&1)
                            exit_code=$?
                        fi
                    fi
                fi
                # Roll back any edit that turns a valid shell script into an invalid one.
                if [ "$_fe_was_valid" -eq 1 ] && [ -n "$_fe_snap" ] && ! bash -n "$_fe_target" 2>/dev/null; then
                    local _fe_err
                    _fe_err=$(bash -n "$_fe_target" 2>&1 | head -n 3)
                    cp -p "$_fe_snap" "$_fe_target" 2>/dev/null
                    output="ERROR: edit reverted, it broke shell syntax in $pth: $_fe_err"
                    exit_code=1
                fi
                [ -n "$_fe_snap" ] && rm -f "$_fe_snap"
                local _check_target="$pth"
                [ ! -f "$_check_target" ] && _check_target="$workdir/$pth"
                if [ $exit_code -eq 0 ] && [ -f "$_check_target" ]; then
                    local _edit_lang
                    _edit_lang=$(treesitter_detect_lang "$pth")
                    if [ -n "$_edit_lang" ] && [ "$_edit_lang" != "plaintext" ]; then
                        local _edit_ts_err
                        if ! _edit_ts_err=$(treesitter_validate "$(cat "$_check_target")" "$_edit_lang" 2>&1); then
                            output+=$'\n'"[Warning: Tree-sitter post-edit syntax validation failed for $pth: $_edit_ts_err]"
                        fi
                    fi
                fi
                ;;
            copilot_patch|copilot_safe_comment|copilot_tool_forge|git_clone|git_commit|git_push|gitea_status|gitea_set_endpoint|gitea_repo_sync|gitea_pr_create|gitea_pr_list|gitea_pr_get|gitea_pr_review|gitea_pr_merge|gitea_issue_create|gitea_issue_list|gitea_issue_get|gitea_issue_comment|gitea_issue_close|gitea_branch_create|pr_audit|project_fix|project_init|backup_create|backup_list|backup_restore|pgp_sign|pgp_verify|gsuite_search|phytology_manage)
                _native_dispatch_git_code "$name" "$args_json" "$workdir"
                ;;
            slash_command_exec)
                local sc
                sc=$(echo "$args_json" | jq -r '.command // empty')
                [[ "$sc" != /* ]] && sc="/$sc"
                local sc_name sc_args
                sc_name=$(echo "$sc" | awk '{print $1}' | sed 's|^/||')
                sc_args=$(echo "$sc" | sed 's|^/[^ ]* *||')
                [ "$sc_args" = "$sc" ] && sc_args=""
                local _tg_sc=""
                if _tg_sc=$(_trading_bash_guard "$sc"); then
                    output="ERROR: blocked by trading policy guard: ${_tg_sc}"
                    exit_code=1
                elif [ -n "$sc_name" ] && declare -f "_cmd_${sc_name}" &>/dev/null; then
                    output=$("_cmd_${sc_name}" "$sc_args" "$workdir" 2>&1)
                    exit_code=$?
                elif [ -n "$sc_name" ] && declare -f "cmd_${sc_name}" &>/dev/null; then
                    output=$("cmd_${sc_name}" "$sc_args" "$workdir" 2>&1)
                    exit_code=$?
                elif [ "$sc_name" = "journal" ]; then
                    if [ "$sc_args" = "show" ] || [ -z "$sc_args" ]; then
                        output=$(journal_show "all" 2>&1)
                    elif [ "$sc_args" = "vivid" ] || [ "$sc_args" = "fading" ] || [ "$sc_args" = "sediment" ]; then
                        output=$(journal_show "$sc_args" 2>&1)
                    elif [[ "$sc_args" == write* ]]; then
                        local entry
                        entry=$(echo "$sc_args" | sed 's/^write *//')
                        journal_write "reflection" "$entry" 2>&1
                        output="Entry recorded"
                    elif [ "$sc_args" = "count" ]; then
                        output="$(journal_count 2>&1) entries in journal"
                    else
                        output=$(journal_read 5 2>&1)
                    fi
                    exit_code=0
                elif [ "$sc_name" = "recall" ]; then
                    output=$(recall_search "$sc_args" 5 2>&1)
                    exit_code=$?
                else
                    output=$(commands_dispatch "$sc" "$workdir" 2>&1)
                    exit_code=$?
                fi
                ;;
            google_home_discover)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                output=$("$_py_bin" "$LODGE_DIR/lib/tools/google_home_cast.py" status 2>&1)
                exit_code=$?
                ;;
            google_home_speak)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _gh_text _gh_target _gh_voice _gh_engine _gh_vol _gh_force
                _gh_text=$(echo "$args_json" | jq -r '.text // empty')
                _gh_target=$(echo "$args_json" | jq -r '.target // "default"')
                _gh_voice=$(echo "$args_json" | jq -r '.voice // empty')
                _gh_engine=$(echo "$args_json" | jq -r '.engine // empty')
                _gh_vol=$(echo "$args_json" | jq -r '.volume // empty')
                _gh_force=$(echo "$args_json" | jq -r 'if .force == true then "1" else "0" end')
                local -a _gh_cmd=("$_py_bin" "$LODGE_DIR/lib/tools/google_home_cast.py" "speak" "$_gh_text" "--target" "$_gh_target")
                [ -n "$_gh_voice" ] && _gh_cmd+=("--voice" "$_gh_voice")
                [ -n "$_gh_engine" ] && _gh_cmd+=("--engine" "$_gh_engine")
                [ -n "$_gh_vol" ] && _gh_cmd+=("--volume" "$_gh_vol")
                [ "$_gh_force" = "1" ] && _gh_cmd+=("--force")
                output=$("${_gh_cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            google_home_volume)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                output=$("$_py_bin" "$LODGE_DIR/lib/tools/google_home_cast.py" volume --target "$(_arg .target default)" --level "$(_arg .level 0.5)" 2>&1)
                exit_code=$?
                ;;
            tyler_lan_census)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _ty_ref
                _ty_ref=$(echo "$args_json" | jq -r 'if .refresh == false then "status" else "census" end')
                output=$("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" "$_ty_ref" 2>&1)
                exit_code=$?
                ;;
            tyler_deep_fingerprint)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                output=$("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" fingerprint --ip "$(_arg .ip)" 2>&1)
                exit_code=$?
                ;;
            tyler_vuln_audit)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _va_ports
                _va_ports=$(echo "$args_json" | jq -r '.ports // empty')
                local -a _va_cmd=("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" "vuln-audit" "--ip" "$(_arg .ip)")
                [ -n "$_va_ports" ] && _va_cmd+=("--ports" "$_va_ports")
                output=$("${_va_cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            tyler_traffic_inspect)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _ti_dur
                _ti_dur=$(echo "$args_json" | jq -r '.duration_s // .duration // 12')
                output=$("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" traffic --ip "$(_arg .ip)" --duration "$_ti_dur" 2>&1)
                exit_code=$?
                ;;
            tyler_upnp_audit)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                output=$("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" upnp --action "$(_arg .action list)" 2>&1)
                exit_code=$?
                ;;
            tyler_set_trust)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _ty_lbl _ty_notes
                _ty_lbl=$(echo "$args_json" | jq -r '.label // empty')
                _ty_notes=$(echo "$args_json" | jq -r '.notes // empty')
                local -a _ty_tcmd=("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" "trust" "--mac" "$(_arg .mac)" "--level" "$(_arg .level untrusted)")
                [ -n "$_ty_lbl" ] && _ty_tcmd+=("--label" "$_ty_lbl")
                [ -n "$_ty_notes" ] && _ty_tcmd+=("--notes" "$_ty_notes")
                output=$("${_ty_tcmd[@]}" 2>&1)
                exit_code=$?
                ;;
            tyler_intervene)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _iv_port _iv_proto _iv_dur _iv_rat _iv_pid _iv_notes
                _iv_port=$(echo "$args_json" | jq -r '.port // empty')
                _iv_proto=$(echo "$args_json" | jq -r '.proto // empty')
                _iv_dur=$(echo "$args_json" | jq -r '.duration // empty')
                _iv_rat=$(echo "$args_json" | jq -r '.rationale // empty')
                _iv_pid=$(echo "$args_json" | jq -r '.plan_id // empty')
                _iv_notes=$(echo "$args_json" | jq -r '.operator_notes // empty')
                local -a _iv_cmd=("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" "intervene" "--ip" "$(_arg .ip)" "--mode" "$(_arg .mode host_block)")
                [ -n "$_iv_port" ] && _iv_cmd+=("--port" "$_iv_port")
                [ -n "$_iv_proto" ] && _iv_cmd+=("--proto" "$_iv_proto")
                [ -n "$_iv_dur" ] && _iv_cmd+=("--duration" "$_iv_dur")
                [ -n "$_iv_rat" ] && _iv_cmd+=("--rationale" "$_iv_rat")
                [ -n "$_iv_pid" ] && _iv_cmd+=("--plan-id" "$_iv_pid")
                [ -n "$_iv_notes" ] && _iv_cmd+=("--notes" "$_iv_notes")
                output=$("${_iv_cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            tyler_canary_trap)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _ct_ports _ct_aq
                _ct_ports=$(echo "$args_json" | jq -r '.ports // empty')
                _ct_aq=$(echo "$args_json" | jq -r 'if .auto_quarantine == null then "" elif .auto_quarantine then "true" else "false" end')
                local -a _ct_cmd=("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" "canary" "--action" "$(_arg .action status)")
                [ -n "$_ct_ports" ] && _ct_cmd+=("--ports" "$_ct_ports")
                [ -n "$_ct_aq" ] && _ct_cmd+=("--auto-quarantine" "$_ct_aq")
                output=$("${_ct_cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            tyler_tshark_watch)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _tw_name _tw_df _tw_bpf _tw_ef _tw_sev _tw_desc _tw_dur
                _tw_name=$(echo "$args_json" | jq -r '.name // empty')
                _tw_df=$(echo "$args_json" | jq -r '.display_filter // empty')
                _tw_bpf=$(echo "$args_json" | jq -r '.bpf_filter // empty')
                _tw_ef=$(echo "$args_json" | jq -r '.extract_fields // empty')
                _tw_sev=$(echo "$args_json" | jq -r '.severity // "tier_b"')
                _tw_desc=$(echo "$args_json" | jq -r '.description // empty')
                _tw_dur=$(echo "$args_json" | jq -r '.duration // 8')
                local -a _tw_cmd=("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" "tshark-watch" "--action" "$(_arg .action list)" "--severity" "$_tw_sev" "--duration" "$_tw_dur")
                [ -n "$_tw_name" ] && _tw_cmd+=("--name" "$_tw_name")
                [ -n "$_tw_df" ] && _tw_cmd+=("--display-filter" "$_tw_df")
                [ -n "$_tw_bpf" ] && _tw_cmd+=("--bpf-filter" "$_tw_bpf")
                [ -n "$_tw_ef" ] && _tw_cmd+=("--extract-fields" "$_tw_ef")
                [ -n "$_tw_desc" ] && _tw_cmd+=("--description" "$_tw_desc")
                output=$("${_tw_cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            tyler_immune_patrol)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _ip_dur _ip_aq
                _ip_dur=$(echo "$args_json" | jq -r '.duration // 10')
                _ip_aq=$(echo "$args_json" | jq -r '.auto_quarantine // false')
                local -a _ip_cmd=("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" "immune-patrol" "--duration" "$_ip_dur")
                [ "$_ip_aq" = "true" ] && _ip_cmd+=("--auto-quarantine")
                output=$("${_ip_cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            tyler_arp_shield)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _as_ip
                _as_ip=$(echo "$args_json" | jq -r '.ip // empty')
                local -a _as_cmd=("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" "arp-shield" "--action" "$(_arg .action verify)")
                [ -n "$_as_ip" ] && _as_cmd+=("--ip" "$_as_ip")
                output=$("${_as_cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            tyler_baseline_diff)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _bd_save
                _bd_save=$(echo "$args_json" | jq -r '.save_baseline // false')
                local -a _bd_cmd=("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" "baseline-diff" "--ip" "$(_arg .ip all)")
                [ "$_bd_save" = "true" ] && _bd_cmd+=("--save-baseline")
                output=$("${_bd_cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            tyler_kali_man)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _km_tool _km_search _km_sec
                _km_tool=$(echo "$args_json" | jq -r '.tool // "catalog"')
                _km_search=$(echo "$args_json" | jq -r '.search // empty')
                _km_sec=$(echo "$args_json" | jq -r '.section // empty')
                local -a _km_cmd=("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" "man" "--tool" "$_km_tool")
                [ -n "$_km_search" ] && _km_cmd+=("--search" "$_km_search")
                [ -n "$_km_sec" ] && _km_cmd+=("--section" "$_km_sec")
                output=$("${_km_cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            tyler_kali_exec)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _ke_cmd _ke_to
                _ke_cmd=$(echo "$args_json" | jq -r '.command // empty')
                _ke_to=$(echo "$args_json" | jq -r '.timeout_s // .timeout // 60')
                output=$("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" exec --command "$_ke_cmd" --timeout "$_ke_to" 2>&1)
                exit_code=$?
                ;;
            tyler_spelunk)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _sp_mode _sp_if _sp_ip _sp_dur _sp_ports
                _sp_mode=$(echo "$args_json" | jq -r '.mode // "discover"')
                _sp_if=$(echo "$args_json" | jq -r '.interface // empty')
                _sp_ip=$(echo "$args_json" | jq -r '.ip // empty')
                _sp_dur=$(echo "$args_json" | jq -r '.duration // 10')
                _sp_ports=$(echo "$args_json" | jq -r '.ports // "22,80,443,445,8080"')
                local -a _sp_cmd=("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" "spelunk" "--mode" "$_sp_mode" "--duration" "$_sp_dur" "--ports" "$_sp_ports")
                [ -n "$_sp_if" ] && _sp_cmd+=("--interface" "$_sp_if")
                [ -n "$_sp_ip" ] && _sp_cmd+=("--ip" "$_sp_ip")
                output=$("${_sp_cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            tyler_wifi_spelunk)
                local _py_bin="$LODGE_DIR/.venv/bin/python"
                [ -x "$_py_bin" ] || _py_bin="python3"
                local _ws_mode _ws_ssid _ws_bssid _ws_auth _ws_key _ws_surp _ws_sname _ws_timeout
                _ws_mode=$(echo "$args_json" | jq -r '.mode // "scan_airspace"')
                _ws_ssid=$(echo "$args_json" | jq -r '.ssid // empty')
                _ws_bssid=$(echo "$args_json" | jq -r '.bssid // empty')
                _ws_auth=$(echo "$args_json" | jq -r '.auth // "open"')
                _ws_key=$(echo "$args_json" | jq -r '.key // empty')
                _ws_surp=$(echo "$args_json" | jq -r '.surprise // false')
                _ws_sname=$(echo "$args_json" | jq -r '.surprise_name // empty')
                _ws_timeout=$(echo "$args_json" | jq -r '.timeout // .duration // empty')
                local -a _ws_cmd=("$_py_bin" "$LODGE_DIR/lib/tools/tyler_guardian.py" "wifi-spelunk" "--mode" "$_ws_mode" "--auth" "$_ws_auth")
                [ -n "$_ws_ssid" ] && _ws_cmd+=("--ssid" "$_ws_ssid")
                [ -n "$_ws_bssid" ] && _ws_cmd+=("--bssid" "$_ws_bssid")
                [ -n "$_ws_key" ] && _ws_cmd+=("--key" "$_ws_key")
                [ "$_ws_surp" = "true" ] && _ws_cmd+=("--surprise")
                [ -n "$_ws_sname" ] && _ws_cmd+=("--surprise-name" "$_ws_sname")
                [ -n "$_ws_timeout" ] && _ws_cmd+=("--timeout" "$_ws_timeout")
                output=$("${_ws_cmd[@]}" 2>&1)
                exit_code=$?
                ;;
            *)
                if declare -f modules_dispatch_tool &>/dev/null; then
                    output=$(modules_dispatch_tool "$name" "$args_json" "$workdir" 2>&1)
                    exit_code=$?
                    if [ "$exit_code" -eq 127 ] && [ -z "$output" ]; then
                        output="ERROR: Unknown tool '$name'."
                    fi
                else
                    output="ERROR: Unknown tool '$name'."
                    exit_code=127
                fi
                ;;
        esac
    fi

    # Record agent-authored file mutations on the primary workspace into uncommitted_agent_edits.jsonl
    # so drift_sweep can promote George's uncommitted edits into audited PRs without touching human WIP.
    if [ "$exit_code" -eq 0 ] && [ "${LODGE_REMEDIATION_SANDBOX:-0}" -ne 1 ] && [[ "${workdir:-}" != *".sandboxes/"* ]]; then
        case "$name" in
            file_write|file_edit|file_append|code_symbol_patch|copilot_patch|copilot_safe_comment|phytology_manage)
                local _ed_p _ed_abs _root_abs _ed_rel _ed_ledger
                _ed_p=$(echo "$args_json" | jq -r '.path // .file_path // .target // empty' 2>/dev/null)
                if [ -n "$_ed_p" ] && [[ "$_ed_p" != mem:* ]]; then
                    if [[ "$_ed_p" == /* ]]; then
                        _ed_abs="$_ed_p"
                    else
                        _ed_abs="${workdir:-${LODGE_DIR:-$PWD}}/$_ed_p"
                    fi
                    _ed_abs=$(realpath -m "$_ed_abs" 2>/dev/null || echo "$_ed_abs")
                    _root_abs=$(realpath -m "${LODGE_DIR:-$HOME/blue-lodge}" 2>/dev/null || echo "${LODGE_DIR:-$HOME/blue-lodge}")
                    if [[ "$_ed_abs" == "$_root_abs/"* ]] && [[ "$_ed_abs" != "$_root_abs/.sandboxes/"* ]]; then
                        _ed_rel="${_ed_abs#"$_root_abs/"}"
                        _ed_ledger="${GEORGE_DIR:-$_root_abs/.george}/state/uncommitted_agent_edits.jsonl"
                        mkdir -p "$(dirname "$_ed_ledger")" 2>/dev/null || true
                        jq -nc \
                            --argjson ts "$(date +%s)" \
                            --arg p "$_ed_rel" \
                            --arg t "$name" \
                            --arg tid "${_task_id:-${AGENT_ACTIVE_SESSION_ID:-}}" \
                            '{ts: $ts, rel_path: $p, tool: $t, task_id: $tid}' >> "$_ed_ledger" 2>/dev/null || true
                    fi
                fi
                ;;
        esac
    fi

    # Clean ANSI escape sequences from output
    output=$(printf '%s\n' "$output" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')

    # Truncate if excessively large to protect context budget (clamp to 24000 chars)
    if [ ${#output} -gt 24000 ]; then
        output="${output:0:24000}\n... [output truncated (${#output} chars total)]"
    fi

    # Anomaly telemetry tap for native tool failures
    local is_native_failure=0
    # Require real non-zero exit code to avoid flagging benign commands returning exit 0
    if [ "$exit_code" -ne 0 ]; then
        is_native_failure=1
    fi

    if [ "$is_native_failure" -eq 1 ]; then
        local fail_cls="CAPABILITY_DEFICIT"
        if [[ "$name" =~ ^(bash_exec|file_read|file_write|file_edit|file_append)$ ]]; then
            fail_cls="SHELL_RUNTIME"
        fi
        if declare -f telemetry_record_anomaly &>/dev/null; then
            telemetry_record_anomaly "${AGENT_ACTIVE_SESSION_ID:-${session_id:-native_tools}}" "$fail_cls" "$name" "$output" >/dev/null 2>&1 || true
        fi
        # Only triage true unhandled crashes or fatal runtime errors (e.g. Python traceback, segfault, core dump).
        # Routine non-zero exit codes from exploratory commands (grep, ls, test, which) are handled by ReAct resilience.
        local is_fatal_crash=0
        if [[ "$output" =~ (Traceback[[:space:]]\(most[[:space:]]recent[[:space:]]call[[:space:]]last\)|Segmentation[[:space:]]fault|core[[:space:]]dumped|Fatal[[:space:]]error|panic:) ]]; then
            is_fatal_crash=1
        fi

        if [ "$is_fatal_crash" -eq 1 ] && [ "${_DISCORD_IN_SESSION:-0}" -ne 1 ] && [ "${LODGE_REMEDIATION_SANDBOX:-0}" -ne 1 ] && [[ "$workdir" != *".sandboxes/"* ]]; then
            if declare -f telemetry_triage_operational_failure &>/dev/null; then
                telemetry_triage_operational_failure "$name" "$fail_cls" "Fatal runtime crash on $name (exit $exit_code)" "$output" "$workdir" >/dev/null 2>&1 || true
            fi
        fi
    fi

    local _tool_end_ms _tool_dur_ms
    _tool_end_ms=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
    _tool_dur_ms=$(( _tool_end_ms - _tool_start_ms ))
    [ "$_tool_dur_ms" -lt 0 ] 2>/dev/null && _tool_dur_ms=0

    local _payload_ref=""
    # Check if large payload spillover should be staged for disk inspection
    if [ "${#output}" -gt 4096 ]; then
        local _spill_dir="${GEORGE_DIR:-$LODGE_DIR/.george}/ipc/payloads"
        mkdir -p "$_spill_dir" 2>/dev/null || true
        _payload_ref="$_spill_dir/${call_id}.payload"
        printf '%s' "$output" > "$_payload_ref" 2>/dev/null || true
    fi

    # Record Tool Completion to Telemetry
    if declare -f telemetry_tool_end &>/dev/null; then
        telemetry_tool_end "$_task_id" "$call_id" "$name" "$exit_code" "$_tool_dur_ms" "${#output}" "$_payload_ref"
    fi

    # Emit TOOL_COMPLETE Frame on IPC Channel
    if [ -n "$_ipc_chan" ]; then
        local _st_msg="COMPLETED"
        [ "$exit_code" -ne 0 ] && _st_msg="FAILED"
        ipc_send "$_ipc_chan" "TOOL_COMPLETE" "$(jq -nc \
            --arg id "$call_id" \
            --arg tool "$name" \
            --arg status "$_st_msg" \
            --argjson ec "$exit_code" \
            --argjson dur "${_tool_dur_ms:-0}" \
            --argjson bytes "${#output}" \
            --arg pref "$_payload_ref" \
            '{call_id: $id, tool: $tool, status: $status, exit_code: $ec, duration_ms: $dur, size_bytes: $bytes, payload_ref: $pref}')" "" 0 >/dev/null 2>&1 || true
    fi

    # Return standard OpenAI tool response JSON object (+ envelope metadata;
    # react.sh strips exit_code/duration_ms/payload_ref before the LLM sees it)
    [[ "$exit_code" =~ ^-?[0-9]+$ ]] || exit_code=1
    jq -n \
        --arg id "$call_id" \
        --arg name "$name" \
        --arg content "$output" \
        --argjson ec "$exit_code" \
        --argjson dur "${_tool_dur_ms:-0}" \
        --arg pref "$_payload_ref" \
        '{
            role: "tool",
            tool_call_id: $id,
            name: $name,
            content: $content,
            exit_code: $ec,
            duration_ms: $dur,
            payload_ref: $pref
        }'
}

# ── Convenient Shell Wrappers for Co-Pilot Tools ──────────────────────
copilot_patch() {
    local target_file="$1"
    local proposed_patch_or_file="$2"
    local instruction="${3:-Surgical patch applied via copilot}"
    local json_args
    if [ -f "$proposed_patch_or_file" ]; then
        local patch_content
        patch_content=$(cat "$proposed_patch_or_file")
        json_args=$(jq -nc --arg f "$target_file" --arg p "$patch_content" --arg i "$instruction" \
            '{file_path: $f, proposed_patch: $p, instruction: $i}')
    else
        json_args=$(jq -nc --arg f "$target_file" --arg p "$proposed_patch_or_file" --arg i "$instruction" \
            '{file_path: $f, proposed_patch: $p, instruction: $i}')
    fi
    local res
    res=$(native_tools_dispatch "call_copilot_patch" "copilot_patch" "$json_args")
    echo "$res" | jq -r '.content // .error // empty'
}

copilot_safe_comment() {
    local target_file="$1"
    local instruction="${2:-Add comments and docstrings}"
    local json_args
    json_args=$(jq -nc --arg f "$target_file" --arg i "$instruction" \
        '{file_path: $f, instruction: $i}')
    local res
    res=$(native_tools_dispatch "call_copilot_safe_comment" "copilot_safe_comment" "$json_args")
    echo "$res" | jq -r '.content // .error // empty'
}

copilot_tool_forge() {
    local name="$1"
    local desc="$2"
    local lang="${3:-bash}"
    local code="${4:-}"
    local json_args
    json_args=$(jq -nc --arg n "$name" --arg d "$desc" --arg l "$lang" --arg c "$code" \
        '{name: $n, description: $d, language: $l, code: $c}')
    local res
    res=$(native_tools_dispatch "call_copilot_tool_forge" "copilot_tool_forge" "$json_args")
    echo "$res" | jq -r '.content // .error // empty'
}

execute_native_tool() {
    local name="$1"
    local args_json="${2:-"{}"}"
    local workdir="${3:-$PWD}"
    native_tools_dispatch "call_exec" "$name" "$args_json" "$workdir"
}

tool_search() {
    local query="$1"
    if [[ "$query" =~ ^\+ ]]; then
        native_tools_bundle_tools "$query"
    else
        native_tools_search "$query"
    fi
}


