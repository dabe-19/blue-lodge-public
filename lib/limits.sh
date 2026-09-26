#!/bin/bash
# ── George: Configurable Limits & Levers Engine (2026) ───────────────
# Governs runtime thresholds, turn ceilings, circuit-breaker counts,
# and remediation attempt budgets across the autonomous swarm.

[ -n "${_LIB_LIMITS_LOADED:-}" ] && return 0; _LIB_LIMITS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
LIMITS_CONF="${LIMITS_CONF:-$GEORGE_DIR/limits.conf}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true

# ── Canonical Defaults ───────────────────────────────────────────────
LIMITS_DEFAULT_MAX_REMEDIATION_ATTEMPTS=5
LIMITS_DEFAULT_WATCHDOG_TIMEOUT=300
LIMITS_DEFAULT_CIRCUIT_BREAKER_MAX_FAILURES=3
LIMITS_DEFAULT_MAX_SUBAGENT_TURNS=200
LIMITS_DEFAULT_MAX_RESEARCH_TURNS=200

# Dynamic Context & Task Budget Defaults (131k baseline)
LIMITS_DEFAULT_ACTIVE_CONTEXT_WINDOW=131072
LIMITS_DEFAULT_TIER1_COMPACT_TOKENS=98304
LIMITS_DEFAULT_TIER1_MAX_TOKENS=117964
LIMITS_DEFAULT_LLM_MAX_TOKENS=32768
LIMITS_DEFAULT_AGENT_FILE_READ_MAX_LINES=600
LIMITS_DEFAULT_AGENT_GREP_MAX_LINES=400
LIMITS_DEFAULT_WEB_CONTENT_MAX_CHARS=40000
LIMITS_DEFAULT_RESEARCH_SCRATCHPAD_MAX_CHARS=100000
LIMITS_DEFAULT_AGENT_FILE_EXPAND_CHARS=50000
LIMITS_DEFAULT_AGENT_SOCIAL_RECEIPT_MAX_CHARS=4000

limits_init() {
    mkdir -p "$GEORGE_DIR" 2>/dev/null || true
    if [ ! -f "$LIMITS_CONF" ]; then
        cat > "$LIMITS_CONF" << EOF
# George Swarm Limits & Levers Configuration
MAX_REMEDIATION_ATTEMPTS=$LIMITS_DEFAULT_MAX_REMEDIATION_ATTEMPTS
WATCHDOG_TIMEOUT=$LIMITS_DEFAULT_WATCHDOG_TIMEOUT
CIRCUIT_BREAKER_MAX_FAILURES=$LIMITS_DEFAULT_CIRCUIT_BREAKER_MAX_FAILURES
MAX_SUBAGENT_TURNS=$LIMITS_DEFAULT_MAX_SUBAGENT_TURNS
MAX_RESEARCH_TURNS=$LIMITS_DEFAULT_MAX_RESEARCH_TURNS

# Dynamic Context & Task Scaling
ACTIVE_CONTEXT_WINDOW=$LIMITS_DEFAULT_ACTIVE_CONTEXT_WINDOW
TIER1_COMPACT_TOKENS=$LIMITS_DEFAULT_TIER1_COMPACT_TOKENS
TIER1_MAX_TOKENS=$LIMITS_DEFAULT_TIER1_MAX_TOKENS
LLM_MAX_TOKENS=$LIMITS_DEFAULT_LLM_MAX_TOKENS
AGENT_FILE_READ_MAX_LINES=$LIMITS_DEFAULT_AGENT_FILE_READ_MAX_LINES
AGENT_GREP_MAX_LINES=$LIMITS_DEFAULT_AGENT_GREP_MAX_LINES
WEB_CONTENT_MAX_CHARS=$LIMITS_DEFAULT_WEB_CONTENT_MAX_CHARS
RESEARCH_SCRATCHPAD_MAX_CHARS=$LIMITS_DEFAULT_RESEARCH_SCRATCHPAD_MAX_CHARS
AGENT_FILE_EXPAND_CHARS=$LIMITS_DEFAULT_AGENT_FILE_EXPAND_CHARS
AGENT_SOCIAL_RECEIPT_MAX_CHARS=$LIMITS_DEFAULT_AGENT_SOCIAL_RECEIPT_MAX_CHARS
EOF
    fi
}

limits_get() {
    local key="$1"
    local default_val="${2:-}"
    limits_init

    # 1. Environment variable override
    if [ -n "${!key+x}" ] && [ -n "${!key}" ]; then
        echo "${!key}"
        return 0
    fi

    # 2. Config file lookup
    if [ -f "$LIMITS_CONF" ]; then
        local line
        line=$(grep "^${key}=" "$LIMITS_CONF" 2>/dev/null | tail -n 1)
        if [ -n "$line" ]; then
            echo "${line#*=}" | tr -d '[:space:]'
            return 0
        fi
    fi

    # 3. Built-in defaults
    case "$key" in
        MAX_REMEDIATION_ATTEMPTS) echo "$LIMITS_DEFAULT_MAX_REMEDIATION_ATTEMPTS" ;;
        WATCHDOG_TIMEOUT)         echo "$LIMITS_DEFAULT_WATCHDOG_TIMEOUT" ;;
        CIRCUIT_BREAKER_MAX_FAILURES) echo "$LIMITS_DEFAULT_CIRCUIT_BREAKER_MAX_FAILURES" ;;
        MAX_SUBAGENT_TURNS)       echo "$LIMITS_DEFAULT_MAX_SUBAGENT_TURNS" ;;
        MAX_RESEARCH_TURNS)       echo "$LIMITS_DEFAULT_MAX_RESEARCH_TURNS" ;;
        ACTIVE_CONTEXT_WINDOW)    echo "$LIMITS_DEFAULT_ACTIVE_CONTEXT_WINDOW" ;;
        TIER1_COMPACT_TOKENS)     echo "$LIMITS_DEFAULT_TIER1_COMPACT_TOKENS" ;;
        TIER1_MAX_TOKENS)         echo "$LIMITS_DEFAULT_TIER1_MAX_TOKENS" ;;
        LLM_MAX_TOKENS)           echo "$LIMITS_DEFAULT_LLM_MAX_TOKENS" ;;
        AGENT_FILE_READ_MAX_LINES) echo "$LIMITS_DEFAULT_AGENT_FILE_READ_MAX_LINES" ;;
        AGENT_GREP_MAX_LINES)     echo "$LIMITS_DEFAULT_AGENT_GREP_MAX_LINES" ;;
        WEB_CONTENT_MAX_CHARS)    echo "$LIMITS_DEFAULT_WEB_CONTENT_MAX_CHARS" ;;
        RESEARCH_SCRATCHPAD_MAX_CHARS) echo "$LIMITS_DEFAULT_RESEARCH_SCRATCHPAD_MAX_CHARS" ;;
        AGENT_FILE_EXPAND_CHARS)  echo "$LIMITS_DEFAULT_AGENT_FILE_EXPAND_CHARS" ;;
        AGENT_SOCIAL_RECEIPT_MAX_CHARS) echo "$LIMITS_DEFAULT_AGENT_SOCIAL_RECEIPT_MAX_CHARS" ;;
        *)                        echo "$default_val" ;;
    esac
}

limits_set() {
    local key="$1"
    local val="$2"
    limits_init

    if [ -z "$key" ] || [ -z "$val" ]; then
        ui_err "Usage: limits_set <KEY> <VALUE>" >&2
        return 1
    fi

    case "$key" in
        MAX_REMEDIATION_ATTEMPTS|WATCHDOG_TIMEOUT|CIRCUIT_BREAKER_MAX_FAILURES|MAX_SUBAGENT_TURNS|MAX_RESEARCH_TURNS|ACTIVE_CONTEXT_WINDOW|TIER1_COMPACT_TOKENS|TIER1_MAX_TOKENS|LLM_MAX_TOKENS|AGENT_FILE_READ_MAX_LINES|AGENT_GREP_MAX_LINES|WEB_CONTENT_MAX_CHARS|RESEARCH_SCRATCHPAD_MAX_CHARS|AGENT_FILE_EXPAND_CHARS|AGENT_SOCIAL_RECEIPT_MAX_CHARS)
            if ! [[ "$val" =~ ^[0-9]+$ ]]; then
                ui_err "Invalid value for ${key}: expected numeric integer, got '${val}'" >&2
                return 1
            fi
            ;;
    esac

    local tmp="${LIMITS_CONF}.tmp.$$"
    if grep -q "^${key}=" "$LIMITS_CONF" 2>/dev/null; then
        sed "s|^${key}=.*|${key}=${val}|" "$LIMITS_CONF" > "$tmp" && mv "$tmp" "$LIMITS_CONF"
    else
        echo "${key}=${val}" >> "$LIMITS_CONF"
    fi

    export "$key"="$val"
    ui_ok "Limit lever '$key' set to $val" >&2
    return 0
}

# ── Dynamic Context Scaling Governor ──────────────────────────────
# Automatically calculates and cascades proportional limits across
# all task engines (compaction, generation, file reading, grep, web, research, social)
# based on a given context window size (e.g. 65536, 131072, 32768).
limits_scale_for_context() {
    local ctx="${1:-65536}"
    if ! [[ "$ctx" =~ ^[0-9]+$ ]] || [ "$ctx" -lt 4096 ]; then
        ctx=65536
    fi

    # 1. Compaction threshold: 75% of context
    local compact_tok=$(( ctx * 75 / 100 ))
    # 2. Max generation ceiling: 90% of context
    local max_tok=$(( ctx * 90 / 100 ))
    # 3. LLM agent output token ceiling: min(ctx / 2, 32768)
    local agent_tok=$(( ctx / 2 ))
    [ "$agent_tok" -gt 32768 ] && agent_tok=32768
    [ "$agent_tok" -lt 4096 ] && agent_tok=4096

    # 4. File read line chunk: 100 lines per 16k context, clamped [100, 1000]
    local file_lines=$(( ctx * 100 / 16384 ))
    [ "$file_lines" -lt 100 ] && file_lines=100
    [ "$file_lines" -gt 1000 ] && file_lines=1000

    # 5. Grep line cap: 75 lines per 16k context, clamped [100, 800]
    local grep_lines=$(( ctx * 75 / 16384 ))
    [ "$grep_lines" -lt 100 ] && grep_lines=100
    [ "$grep_lines" -gt 800 ] && grep_lines=800

    # 6. Web content chars: 6000 chars per 16k context, clamped [4000, 48000]
    local web_chars=$(( ctx * 6000 / 16384 ))
    [ "$web_chars" -lt 4000 ] && web_chars=4000
    [ "$web_chars" -gt 48000 ] && web_chars=48000

    # 7. Research scratchpad chars: 20000 chars per 16k context, clamped [24000, 128000]
    local res_chars=$(( ctx * 20000 / 16384 ))
    [ "$res_chars" -lt 24000 ] && res_chars=24000
    [ "$res_chars" -gt 128000 ] && res_chars=128000

    # 8. File expand chars: 10000 chars per 16k context, clamped [10000, 64000]
    local expand_chars=$(( ctx * 10000 / 16384 ))
    [ "$expand_chars" -lt 10000 ] && expand_chars=10000
    [ "$expand_chars" -gt 64000 ] && expand_chars=64000

    # 9. Social receipt chars: 1000 chars per 16k context, clamped [1000, 8000]
    local social_chars=$(( ctx * 1000 / 16384 ))
    [ "$social_chars" -lt 1000 ] && social_chars=1000
    [ "$social_chars" -gt 8000 ] && social_chars=8000

    # Export to active shell environment
    export ACTIVE_CONTEXT_WINDOW="$ctx"
    export TIER1_CONTEXT="$ctx"
    export TIER1_COMPACT_TOKENS="$compact_tok"
    export TIER1_MAX_TOKENS="$max_tok"
    export ACTIVE_ENDPOINT_CONTEXT="$ctx"
    export ACTIVE_ENDPOINT_COMPACT_TOKENS="$compact_tok"
    export LLM_MAX_TOKENS="$agent_tok"
    export LLM_AGENT_TOKENS="$agent_tok"
    export LLM_ASK_TOKENS="$agent_tok"
    export AGENT_FILE_READ_MAX_LINES="$file_lines"
    export AGENT_GREP_MAX_LINES="$grep_lines"
    export WEB_CONTENT_MAX_CHARS="$web_chars"
    export RESEARCH_SCRATCHPAD_MAX_CHARS="$res_chars"
    export AGENT_FILE_EXPAND_CHARS="$expand_chars"
    export AGENT_SOCIAL_RECEIPT_MAX_CHARS="$social_chars"

    # Persist levers to limits.conf
    limits_set ACTIVE_CONTEXT_WINDOW "$ctx" >/dev/null 2>&1 || true
    limits_set TIER1_COMPACT_TOKENS "$compact_tok" >/dev/null 2>&1 || true
    limits_set TIER1_MAX_TOKENS "$max_tok" >/dev/null 2>&1 || true
    limits_set LLM_MAX_TOKENS "$agent_tok" >/dev/null 2>&1 || true
    limits_set AGENT_FILE_READ_MAX_LINES "$file_lines" >/dev/null 2>&1 || true
    limits_set AGENT_GREP_MAX_LINES "$grep_lines" >/dev/null 2>&1 || true
    limits_set WEB_CONTENT_MAX_CHARS "$web_chars" >/dev/null 2>&1 || true
    limits_set RESEARCH_SCRATCHPAD_MAX_CHARS "$res_chars" >/dev/null 2>&1 || true
    limits_set AGENT_FILE_EXPAND_CHARS "$expand_chars" >/dev/null 2>&1 || true
    limits_set AGENT_SOCIAL_RECEIPT_MAX_CHARS "$social_chars" >/dev/null 2>&1 || true

    # Synchronize endpoints.conf if present
    local ep_conf="${ENDPOINTS_CONF:-${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/endpoints.conf}"
    if [ -f "$ep_conf" ]; then
        sed -i -E "s|^TIER1_CONTEXT=.*|TIER1_CONTEXT=$ctx|" "$ep_conf" 2>/dev/null || true
        sed -i -E "s|^TIER1_COMPACT_TOKENS=.*|TIER1_COMPACT_TOKENS=$compact_tok|" "$ep_conf" 2>/dev/null || true
        sed -i -E "s|^TIER1_MAX_TOKENS=.*|TIER1_MAX_TOKENS=$max_tok|" "$ep_conf" 2>/dev/null || true
    fi

    ui_ok "Context scaled to ${ctx} tokens. Compaction: ${compact_tok} | Read: ${file_lines} lines | Grep: ${grep_lines} lines | Web: ${web_chars} chars" >&2
}

limits_reset() {
    limits_init
    cat > "$LIMITS_CONF" << EOF
# George Swarm Limits & Levers Configuration
MAX_REMEDIATION_ATTEMPTS=$LIMITS_DEFAULT_MAX_REMEDIATION_ATTEMPTS
WATCHDOG_TIMEOUT=$LIMITS_DEFAULT_WATCHDOG_TIMEOUT
CIRCUIT_BREAKER_MAX_FAILURES=$LIMITS_DEFAULT_CIRCUIT_BREAKER_MAX_FAILURES
MAX_SUBAGENT_TURNS=$LIMITS_DEFAULT_MAX_SUBAGENT_TURNS
MAX_RESEARCH_TURNS=$LIMITS_DEFAULT_MAX_RESEARCH_TURNS

# Dynamic Context & Task Scaling
ACTIVE_CONTEXT_WINDOW=$LIMITS_DEFAULT_ACTIVE_CONTEXT_WINDOW
TIER1_COMPACT_TOKENS=$LIMITS_DEFAULT_TIER1_COMPACT_TOKENS
TIER1_MAX_TOKENS=$LIMITS_DEFAULT_TIER1_MAX_TOKENS
LLM_MAX_TOKENS=$LIMITS_DEFAULT_LLM_MAX_TOKENS
AGENT_FILE_READ_MAX_LINES=$LIMITS_DEFAULT_AGENT_FILE_READ_MAX_LINES
AGENT_GREP_MAX_LINES=$LIMITS_DEFAULT_AGENT_GREP_MAX_LINES
WEB_CONTENT_MAX_CHARS=$LIMITS_DEFAULT_WEB_CONTENT_MAX_CHARS
RESEARCH_SCRATCHPAD_MAX_CHARS=$LIMITS_DEFAULT_RESEARCH_SCRATCHPAD_MAX_CHARS
AGENT_FILE_EXPAND_CHARS=$LIMITS_DEFAULT_AGENT_FILE_EXPAND_CHARS
AGENT_SOCIAL_RECEIPT_MAX_CHARS=$LIMITS_DEFAULT_AGENT_SOCIAL_RECEIPT_MAX_CHARS
EOF
    export MAX_REMEDIATION_ATTEMPTS="$LIMITS_DEFAULT_MAX_REMEDIATION_ATTEMPTS"
    export WATCHDOG_TIMEOUT="$LIMITS_DEFAULT_WATCHDOG_TIMEOUT"
    export CIRCUIT_BREAKER_MAX_FAILURES="$LIMITS_DEFAULT_CIRCUIT_BREAKER_MAX_FAILURES"
    export MAX_SUBAGENT_TURNS="$LIMITS_DEFAULT_MAX_SUBAGENT_TURNS"
    export MAX_RESEARCH_TURNS="$LIMITS_DEFAULT_MAX_RESEARCH_TURNS"
    limits_scale_for_context "$LIMITS_DEFAULT_ACTIVE_CONTEXT_WINDOW"
    ui_ok "Limits reset to canonical defaults." >&2
}

limits_list() {
    limits_init
    ui_section "George Swarm Limits & Operational Levers"
    printf "  %-32s %-12s %s\n" "LEVER" "VALUE" "DESCRIPTION"
    printf "  %-32s %-12s %s\n" "--------------------------------" "------------" "----------------------------------------"
    
    local r_att w_to cb_max turns res_turns
    r_att=$(limits_get MAX_REMEDIATION_ATTEMPTS)
    w_to=$(limits_get WATCHDOG_TIMEOUT)
    cb_max=$(limits_get CIRCUIT_BREAKER_MAX_FAILURES)
    turns=$(limits_get MAX_SUBAGENT_TURNS)
    res_turns=$(limits_get MAX_RESEARCH_TURNS)

    local _cyan="${C_CYAN:-}" _reset="${C_RESET:-}" _bold="${C_BOLD:-}"
    local _green="${C_GREEN:-}" _yellow="${C_YELLOW:-}" _blue="${C_BLUE:-}" _magenta="${C_MAGENTA:-}"

    printf "  %b%-32s%b %b%-12s%b %s\n" "$_cyan" "MAX_REMEDIATION_ATTEMPTS" "$_reset" "$_bold" "$r_att" "$_reset" "Max auto-remediation PR loops before Tier 3 escalation"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_cyan" "WATCHDOG_TIMEOUT" "$_reset" "$_bold" "${w_to}s" "$_reset" "Inactivity threshold to terminate hung subagents"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_cyan" "CIRCUIT_BREAKER_MAX_FAILURES" "$_reset" "$_bold" "$cb_max" "$_reset" "Consecutive tool errors before tripping circuit breaker"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_cyan" "MAX_SUBAGENT_TURNS" "$_reset" "$_bold" "$turns" "$_reset" "Default maximum turn ceiling for worker subagents"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_cyan" "MAX_RESEARCH_TURNS" "$_reset" "$_bold" "$res_turns" "$_reset" "Maximum turn ceiling for deep research loops"

    ui_section "Dynamic Context & Subsystem Budgets"
    local ctx_win c_tok m_tok l_tok fr_lines gr_lines wb_chars rs_chars fe_chars sc_chars
    ctx_win=$(limits_get ACTIVE_CONTEXT_WINDOW 65536)
    c_tok=$(limits_get TIER1_COMPACT_TOKENS 24576)
    m_tok=$(limits_get TIER1_MAX_TOKENS 61440)
    l_tok=$(limits_get LLM_MAX_TOKENS 32768)
    fr_lines=$(limits_get AGENT_FILE_READ_MAX_LINES 500)
    gr_lines=$(limits_get AGENT_GREP_MAX_LINES 300)
    wb_chars=$(limits_get WEB_CONTENT_MAX_CHARS 24000)
    rs_chars=$(limits_get RESEARCH_SCRATCHPAD_MAX_CHARS 80000)
    fe_chars=$(limits_get AGENT_FILE_EXPAND_CHARS 40000)
    sc_chars=$(limits_get AGENT_SOCIAL_RECEIPT_MAX_CHARS 4000)

    printf "  %b%-32s%b %b%-12s%b %s\n" "$_green" "ACTIVE_CONTEXT_WINDOW" "$_reset" "$_bold" "$ctx_win" "$_reset" "Primary slot context window (tokens)"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_green" "TIER1_COMPACT_TOKENS" "$_reset" "$_bold" "$c_tok" "$_reset" "Auto-compaction trigger threshold (75% context)"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_green" "TIER1_MAX_TOKENS" "$_reset" "$_bold" "$m_tok" "$_reset" "Ceiling before hard stop/truncation (90% context)"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_green" "LLM_MAX_TOKENS" "$_reset" "$_bold" "$l_tok" "$_reset" "Max output token generation per agent turn"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_yellow" "AGENT_FILE_READ_MAX_LINES" "$_reset" "$_bold" "$fr_lines" "$_reset" "Max lines per file_read inspection chunk"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_yellow" "AGENT_GREP_MAX_LINES" "$_reset" "$_bold" "$gr_lines" "$_reset" "Max output lines returned by /grep and file_grep"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_blue" "WEB_CONTENT_MAX_CHARS" "$_reset" "$_bold" "$wb_chars" "$_reset" "Web scraping & fetch content extraction cap"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_blue" "RESEARCH_SCRATCHPAD_MAX_CHARS" "$_reset" "$_bold" "$rs_chars" "$_reset" "Deep research scratchpad buffer cap"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_magenta" "AGENT_FILE_EXPAND_CHARS" "$_reset" "$_bold" "$fe_chars" "$_reset" "Auto-expanded file reference character budget"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$_magenta" "AGENT_SOCIAL_RECEIPT_MAX_CHARS" "$_reset" "$_bold" "$sc_chars" "$_reset" "Social & Discord interaction context window"
}
