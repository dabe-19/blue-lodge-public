#!/bin/bash
# ── George: Sovereign Entity Judgment & Themeable Reputation Ledger ──
# Tracks external chatter trust scores, customizable role degrees,
# immutable audit history, anti-farming caps, and declarative capabilities
# across Discord, X, Mastodon, and Gitea.
#
# Canonical Tier IDs (default theme = "masonic", customizable via policy JSON):
#   tier_0 (< 0 pts)    : Cowan        — Quarantined. No tool execution permitted.
#   tier_1 (0 - 24 pts) : Stranger     — Tier 1. Ambient conversational tools.
#   tier_2 (25-49 pts)  : Brother      — Tier 2. Interactive sandboxes & Gitea PRs.
#   tier_3 (50+ pts)    : Master Mason — Tier 3. Elevated agency & priority scheduling.

[ -n "${_LIB_REPUTATION_LOADED:-}" ] && return 0; _LIB_REPUTATION_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
REPUTATION_DB="${REPUTATION_DB:-$GEORGE_DIR/reputation.db}"
REPUTATION_POLICY_FILE="${REPUTATION_POLICY_FILE:-}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

# ── Input validation (SQL safety) ─────────────────────────────────────
_rep_valid_user_id() {
    [[ "$1" =~ ^[A-Za-z0-9_.:@-]{1,64}$ ]]
}
_rep_valid_platform() {
    [[ "$1" =~ ^[a-z0-9_]{1,32}$ ]]
}
_rep_valid_int() {
    [[ "$1" =~ ^-?[0-9]{1,9}$ ]]
}
_rep_valid_tier_id() {
    [[ "$1" =~ ^tier_[0-3]$ ]]
}
_rep_sql_text() {
    local v
    v=$(printf '%s' "$1" | tr -d '\000-\037\177' | cut -c1-160)
    printf '%s' "${v//\'/\'\'}"
}

# ── Policy & Theme Loader (cached per mtime) ──────────────────────────
_REP_POLICY_CACHE=""
_REP_POLICY_MTIME=""
_REP_POLICY_PATH_CACHE=""

_rep_default_policy_json() {
    local tmpl="$LODGE_DIR/configs/reputation_policy.example.json"
    if [ -f "$tmpl" ]; then
        cat "$tmpl"
        return 0
    fi
    cat <<'EOF'
{
  "theme": "masonic",
  "ledger_title": "George's Judgment Ledger & Reputation Score",
  "starting_score": 10,
  "passive_reward": { "enabled": true, "delta": 1, "cooldown_secs": 600, "daily_cap": 3, "ceiling_offset_below_tier_3": 1 },
  "probation_recovery": { "enabled": true, "interval_secs": 172800, "delta": 1 },
  "default_moderator_floor": "tier_1",
  "discord_role_floors": {},
  "tiers": {
    "tier_0": { "name": "Cowan",        "min_score": null, "max_score": -1, "description": "Quarantined by The Tyler. No tool execution permitted.", "capabilities": [] },
    "tier_1": { "name": "Stranger",     "min_score": 0,                     "description": "Tier 1: Ambient conversational tools (weather_report, system_time, web_search, system vitals).", "capabilities": ["weather_report","system_time","web_search","system_vitals","recall"] },
    "tier_2": { "name": "Brother",      "min_score": 25,                    "description": "Tier 2: Interactive task requests, ephemeral git sandbox clones on Slot 1, Sovereign Gitea PR landing.", "capabilities": ["weather_report","system_time","web_search","system_vitals","recall","file_read","dir_list","file_grep","gitea_pr","sandbox_task"] },
    "tier_3": { "name": "Master Mason", "min_score": 50,                    "description": "Tier 3: Elevated agency, slash command dispatcher, priority scheduling, full sandbox authority.", "capabilities": ["*"] }
  },
  "quarantine_reply": "Being ignorant is not so much a shame, as being unwilling to learn. Your current standing ({score} points · {tier}) places your requests in quarantine under The Tyler's watch.",
  "presets": {
    "masonic":  { "ledger_title": "George's Judgment Ledger & Reputation Score", "names": ["Cowan", "Stranger", "Brother", "Master Mason"] },
    "standard": { "ledger_title": "Community Trust & Standing Ledger",           "names": ["Quarantined", "Guest", "Member", "Steward"] },
    "guild":    { "ledger_title": "Craftsman Guild Standing Ledger",             "names": ["Exiled", "Apprentice", "Journeyman", "Master"] },
    "cyber":    { "ledger_title": "Node Access & Trust Matrix",                  "names": ["Blacklisted", "Visitor", "Operator", "Architect"] }
  }
}
EOF
}

_rep_policy_file() {
    echo "${REPUTATION_POLICY_FILE:-$GEORGE_DIR/configs/reputation_policy.json}"
}

reputation_policy_init() {
    local pf
    pf=$(_rep_policy_file)
    mkdir -p "$(dirname "$pf")" 2>/dev/null || true
    if [ ! -f "$pf" ]; then
        _rep_default_policy_json > "$pf" 2>/dev/null || true
    fi
}

reputation_load_policy() {
    local pf mtime=""
    pf=$(_rep_policy_file)
    if [ -f "$pf" ]; then
        mtime=$(stat -c '%Y:%s' "$pf" 2>/dev/null || echo "1")
        if [ "$pf" = "$_REP_POLICY_PATH_CACHE" ] && [ "$mtime" = "$_REP_POLICY_MTIME" ] && [ -n "$_REP_POLICY_CACHE" ]; then
            printf '%s' "$_REP_POLICY_CACHE"
            return 0
        fi
        local raw
        raw=$(cat "$pf" 2>/dev/null || echo "")
        if [ -n "$raw" ] && command -v jq &>/dev/null && jq empty <<<"$raw" >/dev/null 2>&1; then
            _REP_POLICY_PATH_CACHE="$pf"
            _REP_POLICY_MTIME="$mtime"
            _REP_POLICY_CACHE="$raw"
            printf '%s' "$raw"
            return 0
        fi
    fi
    _rep_default_policy_json
}

_rep_policy_jq() {
    local expr="$1" fallback="${2:-}"
    if ! command -v jq &>/dev/null; then
        printf '%s' "$fallback"
        return 0
    fi
    local val
    val=$(reputation_load_policy | jq -r "$expr" 2>/dev/null || true)
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        printf '%s' "$fallback"
    else
        printf '%s' "$val"
    fi
}

reputation_policy_save() {
    local json_in="$1"
    command -v jq &>/dev/null || return 1
    jq empty <<<"$json_in" >/dev/null 2>&1 || return 1
    local pf tmp
    pf=$(_rep_policy_file)
    mkdir -p "$(dirname "$pf")" 2>/dev/null || true
    tmp="${pf}.tmp.$$"
    jq '.' <<<"$json_in" > "$tmp" && mv "$tmp" "$pf"
    _REP_POLICY_CACHE=""
    _REP_POLICY_MTIME=""
    reputation_sync_tier_labels >/dev/null 2>&1 || true
    return 0
}

# ── Database Init & Non-Destructive Migration ─────────────────────────
reputation_init() {
    mkdir -p "$GEORGE_DIR" 2>/dev/null || true
    if command -v sqlite3 &>/dev/null; then
        sqlite3 "$REPUTATION_DB" << 'EOF'
CREATE TABLE IF NOT EXISTS reputation (
    user_id TEXT PRIMARY KEY,
    username TEXT,
    platform TEXT DEFAULT 'discord',
    score INTEGER DEFAULT 10,
    tier TEXT DEFAULT 'Stranger',
    tier_id TEXT DEFAULT 'tier_1',
    notes TEXT DEFAULT '',
    created_at INTEGER,
    last_seen INTEGER
);
CREATE INDEX IF NOT EXISTS idx_reputation_username ON reputation(username);
CREATE TABLE IF NOT EXISTS reputation_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    username TEXT DEFAULT '',
    platform TEXT DEFAULT 'discord',
    delta INTEGER NOT NULL,
    old_score INTEGER NOT NULL,
    new_score INTEGER NOT NULL,
    old_tier TEXT NOT NULL,
    new_tier TEXT NOT NULL,
    reason TEXT DEFAULT '',
    actor TEXT DEFAULT 'system',
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rep_events_user_ts ON reputation_events(user_id, created_at DESC);
EOF
        # Idempotent migration for pre-existing reputation.db without tier_id
        local has_tid
        has_tid=$(sqlite3 "$REPUTATION_DB" "PRAGMA table_info(reputation);" 2>/dev/null | awk -F'|' '$2=="tier_id"{print 1}')
        if [ "$has_tid" != "1" ]; then
            sqlite3 "$REPUTATION_DB" "ALTER TABLE reputation ADD COLUMN tier_id TEXT DEFAULT 'tier_1';" 2>/dev/null || true
        fi
    fi
}

# ── Tier Thresholds, Display Labels & Theme Management ────────────────
reputation_tier_min_score() {
    local tid="$1"
    case "$tid" in
        tier_1) _rep_policy_jq '.tiers.tier_1.min_score // 0' "0" ;;
        tier_2) _rep_policy_jq '.tiers.tier_2.min_score // 25' "25" ;;
        tier_3) _rep_policy_jq '.tiers.tier_3.min_score // 50' "50" ;;
        *) echo "-1" ;;
    esac
}

reputation_tier_id() {
    local score="${1:-10}"
    _rep_valid_int "$score" || score=10
    local t1 t2 t3
    t1=$(reputation_tier_min_score tier_1)
    t2=$(reputation_tier_min_score tier_2)
    t3=$(reputation_tier_min_score tier_3)
    if [ "$score" -lt "$t1" ]; then
        echo "tier_0"
    elif [ "$score" -lt "$t2" ]; then
        echo "tier_1"
    elif [ "$score" -lt "$t3" ]; then
        echo "tier_2"
    else
        echo "tier_3"
    fi
}

reputation_tier_name_by_id() {
    local tid="${1:-tier_1}"
    case "$tid" in
        tier_0) _rep_policy_jq '.tiers.tier_0.name // "Cowan"' "Cowan" ;;
        tier_1) _rep_policy_jq '.tiers.tier_1.name // "Stranger"' "Stranger" ;;
        tier_2) _rep_policy_jq '.tiers.tier_2.name // "Brother"' "Brother" ;;
        tier_3) _rep_policy_jq '.tiers.tier_3.name // "Master Mason"' "Master Mason" ;;
        *) echo "Stranger" ;;
    esac
}

reputation_tier() {
    local score="${1:-10}"
    local tid
    tid=$(reputation_tier_id "$score")
    reputation_tier_name_by_id "$tid"
}

reputation_features() {
    local tier_in="${1:-tier_1}"
    local tid=""
    if _rep_valid_tier_id "$tier_in"; then
        tid="$tier_in"
    else
        local t
        for t in tier_0 tier_1 tier_2 tier_3; do
            if [ "$(reputation_tier_name_by_id "$t")" = "$tier_in" ]; then
                tid="$t"
                break
            fi
        done
    fi
    if [ -n "$tid" ]; then
        local desc
        desc=$(_rep_policy_jq ".tiers.${tid}.description // empty" "")
        if [ -n "$desc" ]; then
            echo "$desc"
            return 0
        fi
    fi
    case "$tier_in" in
        "Cowan"|tier_0) echo "Quarantined by The Tyler. No tool execution permitted." ;;
        "Stranger"|tier_1) echo "Tier 1: Ambient conversational tools (weather_report, system_time, web_search, system vitals)." ;;
        "Brother"|tier_2) echo "Tier 2: Interactive task requests, ephemeral git sandbox clones on Slot 1, Sovereign Gitea PR landing." ;;
        "Master Mason"|tier_3) echo "Tier 3: Elevated agency, slash command dispatcher, priority scheduling, full sandbox authority." ;;
        *) echo "Tier 1: Ambient conversational tools." ;;
    esac
}

# Sync display tier labels in reputation.db after a theme or threshold change
reputation_sync_tier_labels() {
    [ -f "$REPUTATION_DB" ] || return 0
    command -v sqlite3 &>/dev/null || return 0
    local rows uid sc tid tname safe_tname
    rows=$(sqlite3 "$REPUTATION_DB" "SELECT user_id, score FROM reputation;" 2>/dev/null || true)
    while IFS='|' read -r uid sc; do
        [ -z "$uid" ] && continue
        _rep_valid_user_id "$uid" || continue
        _rep_valid_int "$sc" || continue
        tid=$(reputation_tier_id "$sc")
        tname=$(reputation_tier_name_by_id "$tid")
        safe_tname=$(_rep_sql_text "$tname")
        sqlite3 "$REPUTATION_DB" \
            "UPDATE reputation SET tier = '$safe_tname', tier_id = '$tid' WHERE user_id = '$uid';" 2>/dev/null || true
    done <<< "$rows"
}

reputation_apply_preset() {
    local preset="$1"
    command -v jq &>/dev/null || return 1
    local cur updated
    cur=$(reputation_load_policy)
    jq -e --arg p "$preset" '.presets[$p] != null' <<<"$cur" >/dev/null 2>&1 || return 1
    updated=$(jq --arg p "$preset" '
        .theme = $p
        | .ledger_title = (.presets[$p].ledger_title // .ledger_title)
        | .tiers.tier_0.name = .presets[$p].names[0]
        | .tiers.tier_1.name = .presets[$p].names[1]
        | .tiers.tier_2.name = .presets[$p].names[2]
        | .tiers.tier_3.name = .presets[$p].names[3]
    ' <<<"$cur") || return 1
    reputation_policy_save "$updated"
}

reputation_set_tier_name() {
    local tid="$1" new_name="$2"
    _rep_valid_tier_id "$tid" || return 1
    [ -n "$new_name" ] || return 1
    command -v jq &>/dev/null || return 1
    local cur updated
    cur=$(reputation_load_policy)
    updated=$(jq --arg tid "$tid" --arg nm "$new_name" '.theme = "custom" | .tiers[$tid].name = $nm' <<<"$cur") || return 1
    reputation_policy_save "$updated"
}

reputation_set_threshold() {
    local tid="$1" min_val="$2"
    [[ "$tid" =~ ^tier_[1-3]$ ]] || return 1
    _rep_valid_int "$min_val" || return 1
    command -v jq &>/dev/null || return 1
    local cur updated
    cur=$(reputation_load_policy)
    updated=$(jq --arg tid "$tid" --argjson mv "$min_val" '.tiers[$tid].min_score = $mv' <<<"$cur") || return 1
    reputation_policy_save "$updated"
}

# ── Declarative Capabilities & Discord Role Floor Resolution ──────────
_rep_tier_rank() {
    case "$1" in
        tier_0) echo 0 ;; tier_1) echo 1 ;; tier_2) echo 2 ;; tier_3) echo 3 ;; *) echo 1 ;;
    esac
}

# reputation_effective_tier_id <user_id> [roles_csv] [is_moderator_0_1]
# Quarantined users (tier_0) ALWAYS stay quarantined regardless of Discord roles.
reputation_effective_tier_id() {
    local uid="$1" roles_csv="${2:-}" is_mod="${3:-0}"
    local row sc tid
    row=$(reputation_get "$uid" 2>/dev/null) || { echo "tier_1"; return 1; }
    sc="${row%%|*}"
    tid=$(reputation_tier_id "$sc")
    if [ "$tid" = "tier_0" ]; then
        echo "tier_0"
        return 0
    fi
    local best_rank best_tid="$tid"
    best_rank=$(_rep_tier_rank "$tid")

    if [ "$is_mod" = "1" ]; then
        local mod_floor
        mod_floor=$(_rep_policy_jq '.default_moderator_floor // "tier_1"' "tier_1")
        if _rep_valid_tier_id "$mod_floor"; then
            local mr; mr=$(_rep_tier_rank "$mod_floor")
            if [ "$mr" -gt "$best_rank" ]; then best_rank="$mr"; best_tid="$mod_floor"; fi
        fi
    fi

    if [ -n "$roles_csv" ] && command -v jq &>/dev/null; then
        local pol rid rfloor rr
        pol=$(reputation_load_policy)
        IFS=',' read -ra _rlist <<<"$roles_csv"
        for rid in "${_rlist[@]}"; do
            rid="${rid// /}"
            [ -z "$rid" ] && continue
            rfloor=$(jq -r --arg r "$rid" '.discord_role_floors[$r] // empty' <<<"$pol" 2>/dev/null)
            if _rep_valid_tier_id "$rfloor"; then
                rr=$(_rep_tier_rank "$rfloor")
                if [ "$rr" -gt "$best_rank" ]; then best_rank="$rr"; best_tid="$rfloor"; fi
            fi
        done
    fi
    echo "$best_tid"
}

# reputation_can_use_tool <tier_id_or_score> <tool_name>
reputation_can_use_tool() {
    local target="$1" tool="$2" tid=""
    if _rep_valid_tier_id "$target"; then
        tid="$target"
    elif _rep_valid_int "$target"; then
        tid=$(reputation_tier_id "$target")
    else
        tid="tier_1"
    fi
    [ "$tid" = "tier_0" ] && return 1
    if ! command -v jq &>/dev/null; then
        [ "$tid" = "tier_3" ] && return 0
        return 1
    fi
    reputation_load_policy | jq -e --arg tid "$tid" --arg tool "$tool" '
        (.tiers[$tid].capabilities // []) | any(. == "*" or . == $tool)
    ' >/dev/null 2>&1
}

# ── Core CRUD + Immutable Audit Ledger ────────────────────────────────
reputation_get() {
    local user_id="$1"
    local username="${2:-unknown}"
    local platform="${3:-discord}"
    reputation_init

    [ -z "$user_id" ] && return 1
    _rep_valid_user_id "$user_id" || return 1
    _rep_valid_platform "$platform" || platform="discord"

    local row
    row=$(sqlite3 "$REPUTATION_DB" "SELECT score FROM reputation WHERE user_id = '$user_id' LIMIT 1;" 2>/dev/null || true)

    if [ -z "$row" ]; then
        local now safe_name start_sc tid tname safe_tname
        now=$(date +%s)
        safe_name=$(_rep_sql_text "$username")
        start_sc=$(_rep_policy_jq '.starting_score // 10' "10")
        _rep_valid_int "$start_sc" || start_sc=10
        tid=$(reputation_tier_id "$start_sc")
        tname=$(reputation_tier_name_by_id "$tid")
        safe_tname=$(_rep_sql_text "$tname")
        sqlite3 "$REPUTATION_DB" \
            "INSERT OR IGNORE INTO reputation (user_id, username, platform, score, tier, tier_id, created_at, last_seen) \
             VALUES ('$user_id', '$safe_name', '$platform', $start_sc, '$safe_tname', '$tid', $now, $now);" 2>/dev/null || true
        echo "${start_sc}|${tname}"
        return 0
    fi

    local tname
    tname=$(reputation_tier "$row")
    echo "${row}|${tname}"
}

reputation_add() {
    local user_id="$1"
    local delta="${2:-1}"
    local reason="${3:-interaction}"
    local username="${4:-}"
    local actor="${5:-system}"
    local platform="${6:-discord}"
    reputation_init

    [ -z "$user_id" ] && return 1
    _rep_valid_user_id "$user_id" || return 1
    _rep_valid_int "$delta" || return 1
    _rep_valid_platform "$platform" || platform="discord"

    local cur_data cur_score cur_tier
    cur_data=$(reputation_get "$user_id" "$username" "$platform") || return 1
    cur_score=$(echo "$cur_data" | cut -d'|' -f1)
    cur_tier=$(echo "$cur_data" | cut -d'|' -f2)
    _rep_valid_int "$cur_score" || return 1

    local new_score=$((cur_score + delta))
    local new_tid new_tier
    new_tid=$(reputation_tier_id "$new_score")
    new_tier=$(reputation_tier_name_by_id "$new_tid")

    local now safe_tier safe_old_tier safe_reason safe_actor safe_user
    now=$(date +%s)
    safe_tier=$(_rep_sql_text "$new_tier")
    safe_old_tier=$(_rep_sql_text "$cur_tier")
    safe_reason=$(_rep_sql_text "$reason")
    safe_actor=$(_rep_sql_text "$actor")
    safe_user=$(_rep_sql_text "$username")

    local user_clause=""
    [ -n "$safe_user" ] && [ "$safe_user" != "unknown" ] && user_clause=", username = '$safe_user'"

    sqlite3 "$REPUTATION_DB" \
        "UPDATE reputation SET score = $new_score, tier = '$safe_tier', tier_id = '$new_tid', last_seen = $now${user_clause} WHERE user_id = '$user_id';
         INSERT INTO reputation_events (user_id, username, platform, delta, old_score, new_score, old_tier, new_tier, reason, actor, created_at)
         VALUES ('$user_id', '$safe_user', '$platform', $delta, $cur_score, $new_score, '$safe_old_tier', '$safe_tier', '$safe_reason', '$safe_actor', $now);" \
        2>/dev/null || true

    echo "${new_score}|${new_tier}"
}

# ── Anti-Farming Passive Reward Gate (10m cooldown + max +3/day) ──────
reputation_can_reward_passive() {
    local user_id="$1"
    reputation_init
    _rep_valid_user_id "$user_id" || return 1

    local enabled cooldown cap
    enabled=$(_rep_policy_jq '.passive_reward.enabled // true' "true")
    [ "$enabled" = "false" ] && return 1
    cooldown=$(_rep_policy_jq '.passive_reward.cooldown_secs // 600' "600")
    cap=$(_rep_policy_jq '.passive_reward.daily_cap // 3' "3")
    _rep_valid_int "$cooldown" || cooldown=600
    _rep_valid_int "$cap" || cap=3

    local now last_ts day_total
    now=$(date +%s)
    last_ts=$(sqlite3 "$REPUTATION_DB" \
        "SELECT COALESCE(MAX(created_at), 0) FROM reputation_events WHERE user_id = '$user_id' AND reason = 'constructive_turn';" \
        2>/dev/null || echo 0)
    if [ "${last_ts:-0}" -gt 0 ] && [ $((now - last_ts)) -lt "$cooldown" ]; then
        return 1
    fi
    day_total=$(sqlite3 "$REPUTATION_DB" \
        "SELECT COALESCE(SUM(delta), 0) FROM reputation_events WHERE user_id = '$user_id' AND reason = 'constructive_turn' AND created_at >= $((now - 86400));" \
        2>/dev/null || echo 0)
    if [ "${day_total:-0}" -ge "$cap" ]; then
        return 1
    fi
    return 0
}

# ── Formatting, Quarantine, History & Listing ─────────────────────────
reputation_format_quarantine() {
    local score="${1:--1}" tier="${2:-$(reputation_tier_name_by_id tier_0)}"
    local tmpl
    tmpl=$(_rep_policy_jq '.quarantine_reply // empty' "")
    if [ -z "$tmpl" ]; then
        tmpl="Being ignorant is not so much a shame, as being unwilling to learn. Your current standing ({score} points · {tier}) places your requests in quarantine under The Tyler's watch."
    fi
    tmpl="${tmpl//\{score\}/$score}"
    tmpl="${tmpl//\{tier\}/$tier}"
    printf '%s' "$tmpl"
}

reputation_format_status() {
    local user_id="$1"
    local username="${2:-User}"
    local data score tier tid feats title t2 t3 t2_name t3_name
    data=$(reputation_get "$user_id" "$username")
    score=$(echo "$data" | cut -d'|' -f1)
    tier=$(echo "$data" | cut -d'|' -f2)
    tid=$(reputation_tier_id "$score")
    feats=$(reputation_features "$tid")
    title=$(_rep_policy_jq '.ledger_title // "George'\''s Judgment Ledger & Reputation Score"' "George's Judgment Ledger & Reputation Score")
    t2=$(reputation_tier_min_score tier_2)
    t3=$(reputation_tier_min_score tier_3)
    t2_name=$(reputation_tier_name_by_id tier_2)
    t3_name=$(reputation_tier_name_by_id tier_3)

    local next_goal=""
    if [ "$score" -lt "$t2" ]; then
        local needed=$((t2 - score))
        next_goal="You are **${needed} points** away from **${t2_name}** tier."
    elif [ "$score" -lt "$t3" ]; then
        local needed=$((t3 - score))
        next_goal="You are **${needed} points** away from **${t3_name}** tier."
    else
        next_goal="You hold the highest standing (**${t3_name}**)."
    fi

    cat << EOF
🏛️ **${title}**

- **Entity:** @${username}
- **Score:** **${score} points**
- **Standing:** **${tier}** (${tid})
- **Unlocked Privileges:** ${feats}

${next_goal}
EOF
}

reputation_penalize_violation() {
    local user_id="$1"
    local username="${2:-unknown}"
    local reason="${3:-security_violation}"
    local penalty="${4:--15}"
    local actor="${5:-tyler_gate}"
    reputation_add "$user_id" "$penalty" "$reason" "$username" "$actor"
}

reputation_quarantine() {
    local user_id="$1"
    local username="${2:-unknown}"
    local reason="${3:-operator_quarantine}"
    local actor="${4:-operator}"
    reputation_init
    _rep_valid_user_id "$user_id" || return 1
    local cur_data cur_score delta
    cur_data=$(reputation_get "$user_id" "$username") || return 1
    cur_score="${cur_data%%|*}"
    delta=$(( -15 - cur_score ))
    [ "$cur_score" -lt 0 ] && delta=-5
    reputation_add "$user_id" "$delta" "$reason" "$username" "$actor"
}

reputation_reset() {
    local user_id="$1"
    local username="${2:-unknown}"
    local actor="${3:-operator}"
    reputation_init
    _rep_valid_user_id "$user_id" || return 1
    local cur_data cur_score cur_tier start_sc tid tname safe_tname safe_old safe_actor safe_user now delta
    cur_data=$(reputation_get "$user_id" "$username") || return 1
    cur_score="${cur_data%%|*}"
    cur_tier="${cur_data#*|}"
    start_sc=$(_rep_policy_jq '.starting_score // 10' "10")
    _rep_valid_int "$start_sc" || start_sc=10
    tid=$(reputation_tier_id "$start_sc")
    tname=$(reputation_tier_name_by_id "$tid")
    safe_tname=$(_rep_sql_text "$tname")
    safe_old=$(_rep_sql_text "$cur_tier")
    safe_actor=$(_rep_sql_text "$actor")
    safe_user=$(_rep_sql_text "$username")
    delta=$((start_sc - cur_score))
    now=$(date +%s)
    sqlite3 "$REPUTATION_DB" \
        "UPDATE reputation SET score = $start_sc, tier = '$safe_tname', tier_id = '$tid', last_seen = $now WHERE user_id = '$user_id';
         INSERT INTO reputation_events (user_id, username, platform, delta, old_score, new_score, old_tier, new_tier, reason, actor, created_at)
         VALUES ('$user_id', '$safe_user', 'discord', $delta, $cur_score, $start_sc, '$safe_old', '$safe_tname', 'operator_reset', '$safe_actor', $now);" \
        2>/dev/null || true
    echo "${start_sc}|${tname}"
}

reputation_list() {
    local limit="${1:-50}"
    reputation_init
    _rep_valid_int "$limit" || limit=50
    sqlite3 -separator '|' "$REPUTATION_DB" \
        "SELECT user_id, COALESCE(username,''), COALESCE(platform,'discord'), score, COALESCE(tier_id,'tier_1'), tier, COALESCE(last_seen,0)
         FROM reputation ORDER BY score DESC, last_seen DESC LIMIT $limit;" 2>/dev/null || true
}

reputation_history() {
    local user_id="$1" limit="${2:-20}"
    reputation_init
    _rep_valid_user_id "$user_id" || return 1
    _rep_valid_int "$limit" || limit=20
    sqlite3 -separator '|' "$REPUTATION_DB" \
        "SELECT id, created_at, delta, old_score, new_score, new_tier, reason, actor
         FROM reputation_events WHERE user_id = '$user_id' ORDER BY id DESC LIMIT $limit;" 2>/dev/null || true
}

reputation_probation_decay() {
    local user_id="$1"
    local username="${2:-unknown}"
    reputation_init
    _rep_valid_user_id "$user_id" || return 0

    local enabled interval delta
    enabled=$(_rep_policy_jq '.probation_recovery.enabled // true' "true")
    [ "$enabled" = "false" ] && return 0
    interval=$(_rep_policy_jq '.probation_recovery.interval_secs // 172800' "172800")
    delta=$(_rep_policy_jq '.probation_recovery.delta // 1' "1")
    _rep_valid_int "$interval" || interval=172800
    _rep_valid_int "$delta" || delta=1

    local row
    row=$(sqlite3 "$REPUTATION_DB" "SELECT score, last_seen FROM reputation WHERE user_id = '$user_id' LIMIT 1;" 2>/dev/null || true)
    [ -z "$row" ] && return 0
    local cur_score cur_last_seen
    cur_score=$(echo "$row" | cut -d'|' -f1)
    cur_last_seen=$(echo "$row" | cut -d'|' -f2)

    if [ "$cur_score" -lt 0 ]; then
        local now
        now=$(date +%s)
        if [ $((now - cur_last_seen)) -ge "$interval" ]; then
            reputation_add "$user_id" "$delta" "probation_recovery" "$username" "probation_decay" >/dev/null 2>&1 || true
        fi
    fi
}
