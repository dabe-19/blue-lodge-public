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

    # Ensure value is numeric for known limit keys
    case "$key" in
        MAX_REMEDIATION_ATTEMPTS|WATCHDOG_TIMEOUT|CIRCUIT_BREAKER_MAX_FAILURES|MAX_SUBAGENT_TURNS|MAX_RESEARCH_TURNS)
            if ! [[ "$val" =~ ^[0-9]+$ ]]; then
                ui_err "Value for $key must be a positive integer (got: $val)" >&2
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

limits_reset() {
    limits_init
    cat > "$LIMITS_CONF" << EOF
# George Swarm Limits & Levers Configuration
MAX_REMEDIATION_ATTEMPTS=$LIMITS_DEFAULT_MAX_REMEDIATION_ATTEMPTS
WATCHDOG_TIMEOUT=$LIMITS_DEFAULT_WATCHDOG_TIMEOUT
CIRCUIT_BREAKER_MAX_FAILURES=$LIMITS_DEFAULT_CIRCUIT_BREAKER_MAX_FAILURES
MAX_SUBAGENT_TURNS=$LIMITS_DEFAULT_MAX_SUBAGENT_TURNS
MAX_RESEARCH_TURNS=$LIMITS_DEFAULT_MAX_RESEARCH_TURNS
EOF
    unset MAX_REMEDIATION_ATTEMPTS WATCHDOG_TIMEOUT CIRCUIT_BREAKER_MAX_FAILURES MAX_SUBAGENT_TURNS MAX_RESEARCH_TURNS 2>/dev/null || true
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

    printf "  %b%-32s%b %b%-12s%b %s\n" "$C_CYAN" "MAX_REMEDIATION_ATTEMPTS" "$C_RESET" "$C_BOLD" "$r_att" "$C_RESET" "Max auto-remediation PR loops before Tier 3 escalation"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$C_CYAN" "WATCHDOG_TIMEOUT" "$C_RESET" "$C_BOLD" "${w_to}s" "$C_RESET" "Inactivity threshold to terminate hung subagents"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$C_CYAN" "CIRCUIT_BREAKER_MAX_FAILURES" "$C_RESET" "$C_BOLD" "$cb_max" "$C_RESET" "Consecutive tool errors before tripping circuit breaker"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$C_CYAN" "MAX_SUBAGENT_TURNS" "$C_RESET" "$C_BOLD" "$turns" "$C_RESET" "Default maximum turn ceiling for worker subagents"
    printf "  %b%-32s%b %b%-12s%b %s\n" "$C_CYAN" "MAX_RESEARCH_TURNS" "$C_RESET" "$C_BOLD" "$res_turns" "$C_RESET" "Maximum turn ceiling for deep research loops"
}
