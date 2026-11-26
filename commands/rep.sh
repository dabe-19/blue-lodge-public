#!/bin/bash
# ── /rep — Sovereign Reputation, Audit Ledger & Role Theme Manager ───
# Usage:
#   /rep list [N]
#   /rep inspect <user_id>
#   /rep grant <user_id> <+N> [reason]
#   /rep penalize <user_id> <-N> [reason]
#   /rep quarantine <user_id> [reason]
#   /rep reset <user_id>
#   /rep history <user_id> [N]
#   /rep theme [list | set <preset> | rename <tier_0..tier_3> <name> | threshold <tier_1..tier_3> <score>]
set -uo pipefail

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/reputation.sh"

_rep_usage() {
    cat <<'EOF'
Usage: /rep <subcommand> [args...]
  list [limit]                              List tracked participants and current standing
  inspect <user_id>                         Show user standing, capabilities, and recent history
  grant <user_id> <points> [reason]         Award positive reputation points
  penalize <user_id> <points> [reason]      Deduct reputation points (accepts positive or negative int)
  quarantine <user_id> [reason]             Immediately move user into tier_0 quarantine
  reset <user_id>                           Reset user back to starting_score
  history <user_id> [limit]                 Show immutable reputation_events audit log
  theme list                                Show active theme, role names, thresholds & presets
  theme set <preset>                        Apply built-in preset (masonic|standard|guild|cyber)
  theme rename <tier_0..tier_3> <name>      Customize a specific tier's display name
  theme threshold <tier_1..tier_3> <score>  Customize a tier's minimum score threshold
EOF
}

cmd="${1:-list}"
shift || true
ACTOR="${REP_ACTOR:-cli}"

case "$cmd" in
    list|ls)
        limit="${1:-50}"
        reputation_policy_init
        printf "%-20s %-18s %-10s %6s %-8s %s\n" "USER_ID" "USERNAME" "PLATFORM" "SCORE" "TIER_ID" "ROLE"
        printf "%-20s %-18s %-10s %6s %-8s %s\n" "--------------------" "------------------" "----------" "------" "--------" "----------------"
        rows=$(reputation_list "$limit")
        if [ -z "$rows" ]; then
            echo "(no participants recorded yet)"
        else
            while IFS='|' read -r uid uname plat sc tid tname _ls; do
                printf "%-20s %-18s %-10s %6s %-8s %s\n" "$uid" "${uname:0:18}" "$plat" "$sc" "$tid" "$tname"
            done <<< "$rows"
        fi
        ;;
    inspect|show|status)
        uid="${1:-}"
        [ -z "$uid" ] && { _rep_usage; exit 1; }
        reputation_format_status "$uid" "$uid"
        echo ""
        echo "Recent Audit History:"
        hist=$(reputation_history "$uid" 10)
        if [ -z "$hist" ]; then
            echo "  (no audit events yet)"
        else
            while IFS='|' read -r _id ts d old new nt rsn act; do
                dt=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts")
                printf "  [%s] %+d (%s -> %s, %s) reason=%s by=%s\n" "$dt" "$d" "$old" "$new" "$nt" "$rsn" "$act"
            done <<< "$hist"
        fi
        ;;
    grant|promote|add)
        uid="${1:-}"; pts="${2:-}"; shift 2 2>/dev/null || true
        rsn="${*:-operator_grant}"
        [ -z "$uid" ] || [ -z "$pts" ] && { _rep_usage; exit 1; }
        pts="${pts#+}"
        res=$(reputation_add "$uid" "$pts" "$rsn" "" "$ACTOR") || { echo "Invalid user_id or points" >&2; exit 1; }
        echo "Updated ${uid}: ${res} (reason: ${rsn})"
        ;;
    penalize|demote)
        uid="${1:-}"; pts="${2:-}"; shift 2 2>/dev/null || true
        rsn="${*:-operator_penalty}"
        [ -z "$uid" ] || [ -z "$pts" ] && { _rep_usage; exit 1; }
        pts="-${pts#-}"
        res=$(reputation_add "$uid" "$pts" "$rsn" "" "$ACTOR") || { echo "Invalid user_id or points" >&2; exit 1; }
        echo "Updated ${uid}: ${res} (reason: ${rsn})"
        ;;
    quarantine|ban|cowan)
        uid="${1:-}"; shift || true
        rsn="${*:-operator_quarantine}"
        [ -z "$uid" ] && { _rep_usage; exit 1; }
        res=$(reputation_quarantine "$uid" "" "$rsn" "$ACTOR") || { echo "Invalid user_id" >&2; exit 1; }
        echo "Quarantined ${uid}: ${res} (reason: ${rsn})"
        ;;
    reset)
        uid="${1:-}"
        [ -z "$uid" ] && { _rep_usage; exit 1; }
        res=$(reputation_reset "$uid" "" "$ACTOR") || { echo "Invalid user_id" >&2; exit 1; }
        echo "Reset ${uid}: ${res}"
        ;;
    history|audit)
        uid="${1:-}"; limit="${2:-20}"
        [ -z "$uid" ] && { _rep_usage; exit 1; }
        hist=$(reputation_history "$uid" "$limit")
        if [ -z "$hist" ]; then
            echo "(no audit events for ${uid})"
        else
            while IFS='|' read -r _id ts d old new nt rsn act; do
                dt=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts")
                printf "[%s] %+d (%s -> %s · %s) reason=%s actor=%s\n" "$dt" "$d" "$old" "$new" "$nt" "$rsn" "$act"
            done <<< "$hist"
        fi
        ;;
    theme)
        sub="${1:-list}"; shift || true
        case "$sub" in
            list|show)
                pol=$(reputation_load_policy)
                echo "$pol" | jq '{theme, ledger_title, default_moderator_floor, passive_reward, tiers: (.tiers | with_entries({key:.key, value:{name:.value.name, min_score:.value.min_score}})), presets: (.presets | keys)}'
                ;;
            set)
                preset="${1:-}"
                [ -z "$preset" ] && { echo "Usage: /rep theme set <masonic|standard|guild|cyber>" >&2; exit 1; }
                reputation_apply_preset "$preset" || { echo "Unknown preset: $preset" >&2; exit 1; }
                echo "Applied reputation theme preset: ${preset}"
                ;;
            rename)
                tid="${1:-}"; shift || true
                nm="${*:-}"
                [ -z "$tid" ] || [ -z "$nm" ] && { echo "Usage: /rep theme rename <tier_0..tier_3> <new name>" >&2; exit 1; }
                reputation_set_tier_name "$tid" "$nm" || { echo "Invalid tier_id (use tier_0..tier_3)" >&2; exit 1; }
                echo "Renamed ${tid} -> ${nm}"
                ;;
            threshold)
                tid="${1:-}"; val="${2:-}"
                [ -z "$tid" ] || [ -z "$val" ] && { echo "Usage: /rep theme threshold <tier_1..tier_3> <min_score>" >&2; exit 1; }
                reputation_set_threshold "$tid" "$val" || { echo "Invalid tier_id or threshold" >&2; exit 1; }
                echo "Updated ${tid} min_score -> ${val}"
                ;;
            *) _rep_usage; exit 1 ;;
        esac
        ;;
    -h|--help|help)
        _rep_usage
        ;;
    *)
        _rep_usage; exit 1
        ;;
esac
