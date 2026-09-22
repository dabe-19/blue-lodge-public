#!/bin/bash
# ── George: Sovereign Entity Judgment & Reputation Ledger ────────────
# Tracks external chatter trust scores, tiers, and unlocked privileges
# on the Masonic Square across Discord, X, Mastodon, and Gitea.
#
# Tiers:
#   Cowan        (< 0 pts)   : Untrusted / quarantined. Canned Franklin wit only.
#   Stranger     (0 - 24 pts): Tier 1. Ambient conversational tools (weather, time, web search).
#   Brother      (25-49 pts) : Tier 2. Ephemeral git sandbox tasks on Slot 1, Gitea PR landing.
#   Master Mason (50+ pts)   : Tier 3. Elevated agency, slash commands, priority scheduling.

[ -n "${_LIB_REPUTATION_LOADED:-}" ] && return 0; _LIB_REPUTATION_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
REPUTATION_DB="${REPUTATION_DB:-$GEORGE_DIR/reputation.db}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true

reputation_init() {
    mkdir -p "$GEORGE_DIR" 2>/dev/null
    if command -v sqlite3 &>/dev/null; then
        sqlite3 "$REPUTATION_DB" << 'EOF'
CREATE TABLE IF NOT EXISTS reputation (
    user_id TEXT PRIMARY KEY,
    username TEXT,
    platform TEXT DEFAULT 'discord',
    score INTEGER DEFAULT 10,
    tier TEXT DEFAULT 'Stranger',
    notes TEXT DEFAULT '',
    created_at INTEGER,
    last_seen INTEGER
);
CREATE INDEX IF NOT EXISTS idx_reputation_username ON reputation(username);
EOF
    fi
}

reputation_tier() {
    local score="${1:-10}"
    if [ "$score" -lt 0 ]; then
        echo "Cowan"
    elif [ "$score" -lt 25 ]; then
        echo "Stranger"
    elif [ "$score" -lt 50 ]; then
        echo "Brother"
    else
        echo "Master Mason"
    fi
}

reputation_features() {
    local tier="${1:-Stranger}"
    case "$tier" in
        "Cowan")
            echo "Quarantined by The Tyler. No tool execution permitted."
            ;;
        "Stranger")
            echo "Tier 1: Ambient conversational tools (weather_report, system_time, web_search, system vitals)."
            ;;
        "Brother")
            echo "Tier 2: Interactive task requests, ephemeral git sandbox clones on Slot 1, Sovereign Gitea PR landing."
            ;;
        "Master Mason")
            echo "Tier 3: Elevated agency, slash command dispatcher, priority scheduling, full sandbox authority."
            ;;
    esac
}

reputation_get() {
    local user_id="$1"
    local username="${2:-unknown}"
    local platform="${3:-discord}"
    reputation_init

    [ -z "$user_id" ] && return 1

    local row
    row=$(sqlite3 "$REPUTATION_DB" "SELECT score, tier FROM reputation WHERE user_id = '$user_id' LIMIT 1;" 2>/dev/null || true)

    if [ -z "$row" ]; then
        local now
        now=$(date +%s)
        # Default starting score is 10 (Stranger)
        sqlite3 "$REPUTATION_DB" \
            "INSERT OR IGNORE INTO reputation (user_id, username, platform, score, tier, created_at, last_seen) \
             VALUES ('$user_id', '$username', '$platform', 10, 'Stranger', $now, $now);" 2>/dev/null || true
        echo "10|Stranger"
        return 0
    fi

    echo "$row"
}

reputation_add() {
    local user_id="$1"
    local delta="${2:-1}"
    local reason="${3:-interaction}"
    local username="${4:-}"
    reputation_init

    [ -z "$user_id" ] && return 1

    local cur_data cur_score cur_tier
    cur_data=$(reputation_get "$user_id" "$username")
    cur_score=$(echo "$cur_data" | cut -d'|' -f1)

    local new_score=$((cur_score + delta))
    local new_tier
    new_tier=$(reputation_tier "$new_score")

    local now
    now=$(date +%s)

    sqlite3 "$REPUTATION_DB" \
        "UPDATE reputation SET score = $new_score, tier = '$new_tier', last_seen = $now \
         WHERE user_id = '$user_id';" 2>/dev/null || true

    echo "$new_score|$new_tier"
}

reputation_format_status() {
    local user_id="$1"
    local username="${2:-Brother}"
    local data score tier feats
    data=$(reputation_get "$user_id" "$username")
    score=$(echo "$data" | cut -d'|' -f1)
    tier=$(echo "$data" | cut -d'|' -f2)
    feats=$(reputation_features "$tier")

    local next_goal=""
    if [ "$score" -lt 25 ]; then
        local needed=$((25 - score))
        next_goal="You are **${needed} points** away from **Brother** tier (unlocks interactive task requests & Gitea PR sandboxes)."
    elif [ "$score" -lt 50 ]; then
        local needed=$((50 - score))
        next_goal="You are **${needed} points** away from **Master Mason** tier (elevated agency and priority scheduling)."
    else
        next_goal="You hold the highest degree of trust on the Square."
    fi

    cat << EOF
🏛️ **George's Judgment Ledger & Reputation Score**

- **Entity:** @${username}
- **Score on the Square:** **${score} points**
- **Standing Degree:** **${tier}**
- **Unlocked Privileges:** ${feats}

${next_goal}
EOF
}

reputation_penalize_violation() {
    local user_id="$1"
    local username="${2:-unknown}"
    local reason="${3:-security_violation}"
    local penalty="${4:--15}"

    reputation_add "$user_id" "$penalty" "$reason" "$username"
}

reputation_reset() {
    local user_id="$1"
    local username="${2:-unknown}"
    reputation_init
    local now
    now=$(date +%s)
    sqlite3 "$REPUTATION_DB" \
        "UPDATE reputation SET score = 10, tier = 'Stranger', last_seen = $now \
         WHERE user_id = '$user_id';" 2>/dev/null || true
    echo "10|Stranger"
}

reputation_probation_decay() {
    local user_id="$1"
    local username="${2:-unknown}"
    reputation_init

    local row
    row=$(sqlite3 "$REPUTATION_DB" "SELECT score, last_seen FROM reputation WHERE user_id = '$user_id' LIMIT 1;" 2>/dev/null || true)
    [ -z "$row" ] && return 0
    local cur_score cur_last_seen
    cur_score=$(echo "$row" | cut -d'|' -f1)
    cur_last_seen=$(echo "$row" | cut -d'|' -f2)

    if [ "$cur_score" -lt 0 ]; then
        local now
        now=$(date +%s)
        # 48 hours = 172800 seconds
        if [ $((now - cur_last_seen)) -ge 172800 ]; then
            reputation_add "$user_id" 1 "probation_recovery" "$username" >/dev/null 2>&1 || true
        fi
    fi
}
