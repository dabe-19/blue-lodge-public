#!/bin/bash
# ── George: Multi-Tier Inference Endpoints & Hardware Ladder ──────────────
# Manages the 4-tier hardware ladder (Frontier, Workhorse, Legacy, Edge),
# fast cached health probing, strict cascading fallback, and downward subagent inventory.

[ -n "${_LIB_ENDPOINTS_LOADED:-}" ] && return 0; _LIB_ENDPOINTS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
ENDPOINTS_CONF="${ENDPOINTS_CONF:-$GEORGE_DIR/endpoints.conf}"
[ -f "$LODGE_DIR/lib/ui.sh" ] && source "$LODGE_DIR/lib/ui.sh"

# ── Probe Cache Table (key=tier, value="status:timestamp") ───────────
declare -A _ENDPOINT_PROBE_CACHE 2>/dev/null || true
_PROBE_CACHE_TTL=5  # cache health probe for 5 seconds

# ── Load Configuration ──────────────────────────────────────────────
endpoints_init() {
    if [ -f "$ENDPOINTS_CONF" ]; then
        local _key _val
        while IFS='=' read -r _key _val; do
            [[ "$_key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$_key" ]] && continue
            _key=$(echo "$_key" | tr -d '[:space:]')
            _val=$(echo "$_val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
            # Only set if not already defined in environment
            if [ -z "${!_key+x}" ]; then
                printf -v "$_key" '%s' "$_val"
            fi
        done < "$ENDPOINTS_CONF"
    fi

    # Ensure research graph functions stay synchronized across multi-phase sweeps
    if [ -f "$LODGE_DIR/lib/research_graph.sh" ] && [ -n "${_LIB_RESEARCH_GRAPH_LOADED:-}" ]; then
        _LIB_RESEARCH_GRAPH_LOADED="" source "$LODGE_DIR/lib/research_graph.sh" 2>/dev/null || true
    fi

    # Fallback defaults if not set
    TIER3_NAME="${TIER3_NAME:-frontier-sovereign}"
    TIER3_URL="${TIER3_URL:-http://mac-m5.local:8080}"
    TIER3_MODEL="${TIER3_MODEL:-glm-5.3-flash}"
    TIER3_CONTEXT="${TIER3_CONTEXT:-65536}"
    TIER3_ROLES="${TIER3_ROLES:-planning,synthesis,deep_coding,audit}"
    TIER3_ENABLED="${TIER3_ENABLED:-0}"
    TIER3_MAX_TOKENS="${TIER3_MAX_TOKENS:-60000}"
    TIER3_COMPACT_TOKENS="${TIER3_COMPACT_TOKENS:-45000}"
    TIER3_TIMEOUT="${TIER3_TIMEOUT:-300}"
    TIER3_TEMPERATURE="${TIER3_TEMPERATURE:-0.6}"
    TIER3_TOP_P="${TIER3_TOP_P:-0.95}"

    TIER1_NAME="${TIER1_NAME:-cuda-workhorse}"
    TIER1_URL="${TIER1_URL:-http://127.0.0.1:8080}"
    TIER1_MODEL="${TIER1_MODEL:-ternary-bonsai-27b}"
    TIER1_CONTEXT="${TIER1_CONTEXT:-24576}"
    TIER1_ROLES="${TIER1_ROLES:-architecture,planning,tools,testing}"
    TIER1_ENABLED="${TIER1_ENABLED:-1}"
    TIER1_MAX_TOKENS="${TIER1_MAX_TOKENS:-22528}"
    TIER1_COMPACT_TOKENS="${TIER1_COMPACT_TOKENS:-19000}"
    TIER1_TIMEOUT="${TIER1_TIMEOUT:-180}"
    TIER1_TEMPERATURE="${TIER1_TEMPERATURE:-0.6}"
    TIER1_TOP_P="${TIER1_TOP_P:-0.95}"

    TIER2_NAME="${TIER2_NAME:-legacy-5700xt}"
    TIER2_URL="${TIER2_URL:-http://192.168.1.150:8080}"
    TIER2_MODEL="${TIER2_MODEL:-gemma-4-12b-agentic}"
    TIER2_CONTEXT="${TIER2_CONTEXT:-16384}"
    TIER2_ROLES="${TIER2_ROLES:-fast_tools,web_scrape,batch_grep}"
    TIER2_ENABLED="${TIER2_ENABLED:-0}"
    TIER2_MAX_TOKENS="${TIER2_MAX_TOKENS:-15000}"
    TIER2_COMPACT_TOKENS="${TIER2_COMPACT_TOKENS:-10000}"
    TIER2_TIMEOUT="${TIER2_TIMEOUT:-120}"
    TIER2_TEMPERATURE="${TIER2_TEMPERATURE:-0.3}"
    TIER2_TOP_P="${TIER2_TOP_P:-0.9}"

    TIER0_NAME="${TIER0_NAME:-edge-mobile}"
    TIER0_URL="${TIER0_URL:-http://127.0.0.1:11434}"
    TIER0_MODEL="${TIER0_MODEL:-gemma4-e2b-inst}"
    TIER0_CONTEXT="${TIER0_CONTEXT:-8192}"
    TIER0_ROLES="${TIER0_ROLES:-offgrid_fallback}"
    TIER0_ENABLED="${TIER0_ENABLED:-1}"
    TIER0_MAX_TOKENS="${TIER0_MAX_TOKENS:-7000}"
    TIER0_COMPACT_TOKENS="${TIER0_COMPACT_TOKENS:-5000}"
    TIER0_TIMEOUT="${TIER0_TIMEOUT:-180}"
    TIER0_TEMPERATURE="${TIER0_TEMPERATURE:-0.2}"
    TIER0_TOP_P="${TIER0_TOP_P:-0.9}"
}

# ── Fast Health Probing with Cache ──────────────────────────────────
# Returns 0 if online, 1 if offline.
endpoints_probe() {
    local tier="$1"
    local enabled_var="TIER${tier}_ENABLED"
    local url_var="TIER${tier}_URL"
    [ -z "${!enabled_var+x}" ] && endpoints_init

    [ "${!enabled_var:-0}" -ne 1 ] && return 1

    local url="${!url_var:-}"
    [ -z "$url" ] && return 1

    # Check cache
    local now
    now=$(date +%s)
    local cached="${_ENDPOINT_PROBE_CACHE[$tier]:-}"
    if [ -n "$cached" ]; then
        local c_status="${cached%%:*}"
        local c_time="${cached##*:}"
        if [ $((now - c_time)) -lt "$_PROBE_CACHE_TTL" ]; then
            [ "$c_status" -eq 0 ] && return 0 || return 1
        fi
    fi

    # Probe HTTP endpoint with sub-second / 1.5s max-time
    local is_online=1
    if [ "$tier" -eq 0 ] && [[ "$url" == *":11434"* ]]; then
        # Ollama endpoint
        if curl -sf --max-time 1.5 "${url}/api/tags" &>/dev/null; then
            is_online=0
        fi
    else
        # llama-server endpoint
        if curl -sf --max-time 1.5 "${url}/health" 2>/dev/null | grep -qE '"status"|"ok"'; then
            is_online=0
        elif curl -sf --max-time 1.5 "${url}/v1/models" &>/dev/null; then
            is_online=0
        fi
    fi

    _ENDPOINT_PROBE_CACHE["$tier"]="${is_online}:${now}"
    return "$is_online"
}

# ── Strict Cascading Fallback ───────────────────────────────────────
# Cascades from highest tier to lowest: Tier 3 -> Tier 1 -> Tier 2 -> Tier 0.
# Sets ACTIVE_TIER and companion variables. Returns 0 if an endpoint is found.
endpoints_cascade() {
    endpoints_init

    local candidates=(3 1 2 0)
    local t
    for t in "${candidates[@]}"; do
        if endpoints_probe "$t"; then
            ACTIVE_TIER="$t"
            local name_var="TIER${t}_NAME"
            local url_var="TIER${t}_URL"
            local model_var="TIER${t}_MODEL"
            local ctx_var="TIER${t}_CONTEXT"
            local roles_var="TIER${t}_ROLES"
            local max_var="TIER${t}_MAX_TOKENS"
            local compact_var="TIER${t}_COMPACT_TOKENS"
            local timeout_var="TIER${t}_TIMEOUT"
            local temp_var="TIER${t}_TEMPERATURE"
            local topp_var="TIER${t}_TOP_P"

            ACTIVE_ENDPOINT_NAME="${!name_var}"
            ACTIVE_ENDPOINT_URL="${!url_var}"
            ACTIVE_ENDPOINT_MODEL="${!model_var}"
            ACTIVE_ENDPOINT_CONTEXT="${!ctx_var}"
            ACTIVE_ENDPOINT_ROLES="${!roles_var}"
            ACTIVE_ENDPOINT_MAX_TOKENS="${!max_var}"
            ACTIVE_ENDPOINT_COMPACT_TOKENS="${!compact_var}"
            ACTIVE_ENDPOINT_TIMEOUT="${!timeout_var:-180}"
            ACTIVE_ENDPOINT_TEMPERATURE="${!temp_var:-${AGENT_LLM_TEMPERATURE:-0.2}}"
            ACTIVE_ENDPOINT_TOP_P="${!topp_var:-0.95}"
            if [ -n "$ACTIVE_ENDPOINT_MODEL" ]; then
                export LODGE_MODEL="$ACTIVE_ENDPOINT_MODEL"
                export LODGE_MODEL_PRIMARY="$ACTIVE_ENDPOINT_MODEL"
            fi
            if [ -n "$ACTIVE_ENDPOINT_URL" ]; then
                export LLAMA_CPP_URL="$ACTIVE_ENDPOINT_URL"
            fi
            return 0
        fi
    done

    ACTIVE_TIER=""
    ACTIVE_ENDPOINT_NAME=""
    ACTIVE_ENDPOINT_URL=""
    ACTIVE_ENDPOINT_MODEL=""
    ACTIVE_ENDPOINT_TIMEOUT="180"
    ACTIVE_ENDPOINT_TEMPERATURE="0.2"
    ACTIVE_ENDPOINT_TOP_P="0.95"
    return 1
}

# ── Downward Subagent Inventory ─────────────────────────────────────
# Returns available online tiers strictly BELOW current_tier.
# Formatted as JSON array for direct model consumption / tool context.
endpoints_get_downward_inventory() {
    local parent_tier="${1:-$ACTIVE_TIER}"
    parent_tier="${parent_tier:-1}"

    endpoints_init
    local candidates=(3 1 2 0)
    local results=()
    local t

    for t in "${candidates[@]}"; do
        # Only tiers strictly lower in the hierarchy order (or worker roles)
        # Note: Hierarchy order is Tier 3 (Frontier) -> Tier 1 (Workhorse) -> Tier 2 (Legacy GPU) -> Tier 0 (Edge)
        local is_lower=0
        case "$parent_tier" in
            3) [ "$t" -eq 1 ] || [ "$t" -eq 2 ] || [ "$t" -eq 0 ] && is_lower=1 ;;
            1) [ "$t" -eq 2 ] || [ "$t" -eq 0 ] && is_lower=1 ;;
            2) [ "$t" -eq 0 ] && is_lower=1 ;;
            0) is_lower=0 ;;
        esac

        if [ "$is_lower" -eq 1 ] && endpoints_probe "$t"; then
            local name_var="TIER${t}_NAME"
            local url_var="TIER${t}_URL"
            local model_var="TIER${t}_MODEL"
            local ctx_var="TIER${t}_CONTEXT"
            local roles_var="TIER${t}_ROLES"

            results+=("{\"tier\":$t,\"name\":\"${!name_var}\",\"model\":\"${!model_var}\",\"context\":${!ctx_var},\"roles\":\"${!roles_var}\"}")
        fi
    done

    if [ ${#results[@]} -eq 0 ]; then
        echo "[]"
    else
        local IFS=','
        echo "[${results[*]}]"
    fi
}

# ── Query Specific Tier Info ────────────────────────────────────────
# Usage: endpoints_get_tier_info <tier_number> <field_name>
endpoints_get_tier_info() {
    local tier="$1"
    local field="$2"
    local var_name="TIER${tier}_${field}"
    echo "${!var_name:-}"
}

# ── Endpoints Status Table & JSON ───────────────────────────────────
endpoints_status_table() {
    endpoints_cascade >/dev/null 2>&1 || endpoints_init
    if declare -f ui_section &>/dev/null; then
        ui_section "Inference Hardware Ladder (4 Tiers)"
    else
        printf "\n── Inference Hardware Ladder (4 Tiers) ──\n"
    fi

    local candidates=(3 1 2 0)
    local t
    for t in "${candidates[@]}"; do
        local name_var="TIER${t}_NAME"
        local url_var="TIER${t}_URL"
        local model_var="TIER${t}_MODEL"
        local ctx_var="TIER${t}_CONTEXT"
        local enabled_var="TIER${t}_ENABLED"

        local name="${!name_var:-tier-$t}"
        local url="${!url_var:-N/A}"
        local model="${!model_var:-default}"
        local ctx="${!ctx_var:-8192}"
        local enabled="${!enabled_var:-0}"

        local status_str="${C_RED}OFFLINE${C_RESET}"
        local mark="  "
        if [ "$enabled" -eq 1 ]; then
            local t_start t_end latency_ms="?"
            t_start=$(date +%s%3N 2>/dev/null || date +%s)
            if endpoints_probe "$t"; then
                t_end=$(date +%s%3N 2>/dev/null || date +%s)
                latency_ms=$((t_end - t_start))
                [ "$latency_ms" -lt 0 ] && latency_ms=0
                status_str="${C_GREEN}ONLINE${C_RESET} (${latency_ms}ms)"
            fi
        else
            status_str="${C_DIM}DISABLED${C_RESET}"
        fi

        if [ -n "${ACTIVE_TIER:-}" ] && [ "$t" = "$ACTIVE_TIER" ]; then
            mark="${C_CYAN}● ${C_RESET}"
        fi

        printf " %bTier %s [%s]%b\n" "$mark" "$t" "$name" "$([ -n "${ACTIVE_TIER:-}" ] && [ "$t" = "$ACTIVE_TIER" ] && echo " ${C_CYAN}← ACTIVE${C_RESET}" || echo "")"
        printf "    URL:     %s\n" "$url"
        printf "    Model:   %s (%s ctx)\n" "$model" "$ctx"
        printf "    Status:  %b\n" "$status_str"
        echo ""
    done
}

endpoints_status_json() {
    endpoints_cascade >/dev/null 2>&1 || endpoints_init
    local candidates=(3 1 2 0)
    local t
    local json="[]"
    for t in "${candidates[@]}"; do
        local name_var="TIER${t}_NAME" url_var="TIER${t}_URL" model_var="TIER${t}_MODEL" ctx_var="TIER${t}_CONTEXT" enabled_var="TIER${t}_ENABLED"
        local online=false
        endpoints_probe "$t" && online=true
        local active=false
        [ -n "${ACTIVE_TIER:-}" ] && [ "$t" = "$ACTIVE_TIER" ] && active=true

        json=$(echo "$json" | jq -c \
            --arg t "$t" \
            --arg name "${!name_var:-tier-$t}" \
            --arg url "${!url_var:-N/A}" \
            --arg model "${!model_var:-default}" \
            --arg ctx "${!ctx_var:-8192}" \
            --argjson online "$online" \
            --argjson active "$active" \
            '. += [{tier: ($t|tonumber), name: $name, url: $url, model: $model, context: ($ctx|tonumber), online: $online, active: $active}]' 2>/dev/null || echo "$json")
    done
    echo "$json"
}
