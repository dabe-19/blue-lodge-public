#!/bin/bash
# ── George: Multi-Tier Alert & Notification Dispatcher (2026) ────────
# Handles autonomous escalation events across three tiers:
#   Tier 1: Internal Code / Harness Bugs (Autonomous PR)
#   Tier 2: Container Sandbox / Tooling Gaps (Autonomous Container Fix)
#   Tier 3: Human Operator Required (Discord Webhook, Email, Gitea Labels)
# Bridges local MQTT bus with external operator notifications.

[ -n "${_LIB_ALERTS_LOADED:-}" ] && return 0; _LIB_ALERTS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
ALERTS_DIR="${GEORGE_DIR}/alerts"
ALERTS_CONF="${ALERTS_CONF:-$GEORGE_DIR/alerts.conf}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mqtt.sh" 2>/dev/null || true

alerts_init() {
    mkdir -p "$ALERTS_DIR" 2>/dev/null || true
    if [ -f "$ALERTS_CONF" ]; then
        # Source key=value configs if present
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            key=$(echo "$key" | tr -d '[:space:]')
            val=$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"' | tr -d "'")
            if [ -z "${!key+x}" ] || [ -z "${!key}" ]; then
                export "$key"="$val"
            fi
        done < "$ALERTS_CONF"
    fi
}

# ── Discord Webhook Dispatcher ───────────────────────────────────────
_alerts_send_discord() {
    local webhook_url="${DISCORD_WEBHOOK_URL:-}"
    [ -z "$webhook_url" ] && return 0

    local tier="$1"
    local subject="$2"
    local message="$3"
    local issue_url="${4:-}"
    local iso_ts
    iso_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")

    local color=3447003 # Blue for info
    local tier_title="Tier 1 (Harness / Code)"
    if [ "$tier" = "tier2" ] || [ "$tier" = "2" ]; then
        color=16744192 # Orange for Tier 2
        tier_title="Tier 2 (Environment / Tooling)"
    elif [ "$tier" = "tier3" ] || [ "$tier" = "3" ]; then
        color=15158332 # Red for Tier 3
        tier_title="Tier 3 (Operator Intervention Required)"
    fi

    local payload
    payload=$(jq -n \
        --arg content "🚨 **[George Swarm Alert - ${tier_title}]**" \
        --arg title "$subject" \
        --arg desc "$message" \
        --arg url "$issue_url" \
        --argjson color "$color" \
        --arg ts "$iso_ts" \
        --arg tier_val "$tier_title" \
        '{
            content: $content,
            embeds: [{
                title: $title,
                description: $desc,
                url: (if $url == "" then null else $url end),
                color: $color,
                timestamp: $ts,
                fields: [
                    { name: "Severity", value: $tier_val, inline: true },
                    { name: "Issue Reference", value: (if $url == "" then "None" else $url end), inline: true }
                ],
                footer: { text: "Blue Lodge Sovereign Swarm Engine" }
            }]
        }')

    curl -s -H "Content-Type: application/json" -d "$payload" "$webhook_url" >/dev/null 2>&1 || true
}

# ── Email Dispatcher ─────────────────────────────────────────────────
_alerts_send_email() {
    local to="${ALERT_EMAIL_TO:-}"
    [ -z "$to" ] && return 0

    local tier="$1"
    local subject="$2"
    local message="$3"
    local issue_url="${4:-}"

    local email_subj="[George Swarm Alert - Tier ${tier}] ${subject}"
    local email_body=$(printf "George Swarm Alert\nSeverity: Tier %s\nSubject: %s\nIssue URL: %s\n\nDetails:\n%s\n" \
        "$tier" "$subject" "${issue_url:-N/A}" "$message")

    if command -v mail &>/dev/null; then
        echo "$email_body" | mail -s "$email_subj" "$to" 2>/dev/null || true
    elif command -v sendmail &>/dev/null; then
        printf "To: %s\nSubject: %s\n\n%s\n" "$to" "$email_subj" "$email_body" | sendmail "$to" 2>/dev/null || true
    fi
}

# ── Primary Unified Alert Dispatcher ─────────────────────────────────
alerts_dispatch() {
    local tier="${1:-tier1}"
    local subject="$2"
    local message="$3"
    local issue_url="${4:-}"
    local context_json="${5:-}"
    if [ -z "$context_json" ] || ! echo "$context_json" | jq empty >/dev/null 2>&1; then
        context_json="{}"
    fi

    alerts_init

    local ts_id
    ts_id=$(date +%Y%m%d_%H%M%S)
    local alert_file="$ALERTS_DIR/alert_${ts_id}_${tier}.json"
    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")

    # 1. Write local diagnostic record
    jq -n \
        --arg id "alert_${ts_id}_${tier}" \
        --arg tier "$tier" \
        --arg subject "$subject" \
        --arg message "$message" \
        --arg issue_url "$issue_url" \
        --arg created "$now_iso" \
        --argjson ctx "$context_json" \
        '{
            id: $id,
            tier: $tier,
            subject: $subject,
            message: $message,
            issue_url: $issue_url,
            created_at: $created,
            status: "ACTIVE",
            context: $ctx
        }' > "$alert_file" 2>/dev/null || true

    # 2. Publish to Sovereign MQTT Bus
    local mqtt_payload
    mqtt_payload=$(jq -c . "$alert_file" 2>/dev/null || echo "{\"tier\": \"$tier\", \"subject\": \"$subject\"}")

    if declare -f mqtt_publish &>/dev/null; then
        mqtt_publish "george/alerts/escalation" "$mqtt_payload" >/dev/null 2>&1 || true
        if [ "$tier" = "tier3" ] || [ "$tier" = "3" ]; then
            mqtt_publish "george/alerts/tier3" "$mqtt_payload" >/dev/null 2>&1 || true
        fi
    fi

    # 3. External dispatch for Tier 3
    if [ "$tier" = "tier3" ] || [ "$tier" = "3" ]; then
        _alerts_send_discord "$tier" "$subject" "$message" "$issue_url"
        _alerts_send_email "$tier" "$subject" "$message" "$issue_url"
        ui_warn "🚨 [TIER 3 ESCALATED TO OPERATOR] $subject" >&2
    else
        ui_info "⚡ [TIER ${tier} ESCALATION] $subject" >&2
    fi

    echo "$alert_file"
}

# ── Alert Query & Dismiss CLI ────────────────────────────────────────
alerts_list() {
    alerts_init
    local found=0
    for f in "$ALERTS_DIR"/alert_*.json; do
        [ ! -f "$f" ] && continue
        found=1
        local id tier subj st
        id=$(jq -r .id "$f" 2>/dev/null || basename "$f")
        tier=$(jq -r .tier "$f" 2>/dev/null || "unknown")
        subj=$(jq -r .subject "$f" 2>/dev/null || "")
        st=$(jq -r .status "$f" 2>/dev/null || "UNKNOWN")
        printf "  %b[%-6s]%b %-26s %b%-8s%b %s\n" "$C_CYAN" "$tier" "$C_RESET" "$id" "$C_BOLD" "$st" "$C_RESET" "$subj"
    done
    [ "$found" -eq 0 ] && ui_info "No active alerts."
}

alerts_dismiss() {
    local alert_id="$1"
    alerts_init
    local target="$ALERTS_DIR/${alert_id}.json"
    [ ! -f "$target" ] && target="$ALERTS_DIR/alert_${alert_id}.json"

    if [ -f "$target" ]; then
        local tmp="${target}.tmp.$$"
        jq '.status = "DISMISSED"' "$target" > "$tmp" && mv "$tmp" "$target"
        ui_ok "Alert '$alert_id' dismissed."
        return 0
    else
        ui_err "Alert '$alert_id' not found in $ALERTS_DIR."
        return 1
    fi
}
