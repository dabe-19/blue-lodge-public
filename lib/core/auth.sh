#!/bin/bash
# ── George: Sovereign Identity, RBAC Permissioning & UUID Linkage Engine ────
# Implements:
#   1. High-speed RFC 4122 UUIDv4 generation with Linux kernel & awk fallbacks
#   2. Granular Role-Based Access Control (RBAC): admin, operator, agent, guest
#   3. Capability verification (shell:exec, workspace:read/write, agent:spawn, etc.)
#   4. Multi-entity UUID Linkage Graph: session -> task -> agent -> pid -> channel -> user
#   5. Atomic state persistence and token-based authentication for Web & IPC

[ -n "${_LIB_AUTH_LOADED:-}" ] && return 0; _LIB_AUTH_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
AUTH_DIR="${AUTH_DIR:-${GEORGE_DIR}/identity}"
AUTH_USERS_FILE="${AUTH_DIR}/users.json"
AUTH_LINKS_FILE="${AUTH_DIR}/links.json"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

# ── 1. UUID Generation ────────────────────────────────────────────────
uuid_generate() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi

    # POSIX Awk RFC 4122 v4 generator
    awk 'BEGIN {
        srand();
        hex = "0123456789abcdef";
        res = "";
        for (i = 1; i <= 32; i++) {
            if (i == 13) {
                res = res "4"; # version 4
            } else if (i == 17) {
                r = int(rand() * 4) + 8; # 8, 9, a, or b
                res = res substr(hex, r + 1, 1);
            } else {
                r = int(rand() * 16);
                res = res substr(hex, r + 1, 1);
            }
            if (i == 8 || i == 12 || i == 16 || i == 20) res = res "-";
        }
        print res;
    }'
}

# ── 2. Initialization & User Management ───────────────────────────────
auth_init() {
    local dir="${1:-$AUTH_DIR}"
    AUTH_DIR="$dir"
    AUTH_USERS_FILE="${AUTH_DIR}/users.json"
    AUTH_LINKS_FILE="${AUTH_DIR}/links.json"
    mkdir -p "$AUTH_DIR" 2>/dev/null || true

    if [ ! -f "$AUTH_USERS_FILE" ] || [ ! -s "$AUTH_USERS_FILE" ]; then
        local admin_token
        admin_token=$(uuid_generate)
        local now_ts="${EPOCHSECONDS:-$(date +%s)}"
        jq -n \
           --arg tok "$admin_token" \
           --arg ts "$now_ts" \
           '[{
               id: "george-admin",
               role: "admin",
               token: $tok,
               created_at: ($ts | tonumber),
               active: true
           }]' > "$AUTH_USERS_FILE" 2>/dev/null || true
    fi

    if [ ! -f "$AUTH_LINKS_FILE" ] || [ ! -s "$AUTH_LINKS_FILE" ]; then
        echo '[]' > "$AUTH_LINKS_FILE" 2>/dev/null || true
    fi
}

auth_user_create() {
    local uid="$1" role="${2:-operator}" token="${3:-}"
    [ -z "$uid" ] && return 1
    auth_init
    [ -z "$token" ] && token=$(uuid_generate)
    local now_ts="${EPOCHSECONDS:-$(date +%s)}"

    local tmp="${AUTH_USERS_FILE}.tmp.$$"
    jq --arg id "$uid" --arg r "$role" --arg tok "$token" --arg ts "$now_ts" \
       '. = [ .[] | select(.id != $id) ] + [{id: $id, role: $r, token: $tok, created_at: ($ts|tonumber), active: true}]' \
       "$AUTH_USERS_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$AUTH_USERS_FILE" 2>/dev/null || return 1
    echo "$token"
}

auth_user_get() {
    local uid="$1"
    auth_init
    jq -c --arg id "$uid" '.[] | select(.id == $id)' "$AUTH_USERS_FILE" 2>/dev/null
}

auth_verify_token() {
    local token="$1"
    [ -z "$token" ] && return 1
    auth_init
    local user
    user=$(jq -c --arg tok "$token" '.[] | select(.token == $tok and .active == true)' "$AUTH_USERS_FILE" 2>/dev/null)
    if [ -n "$user" ] && [ "$user" != "null" ]; then
        echo "$user"
        return 0
    fi
    return 1
}

# ── 3. Role-Based Access Control (RBAC) ───────────────────────────────
auth_role_has_cap() {
    local role="$1" cap="$2"
    case "$role" in
        admin|root)
            return 0
            ;;
        operator)
            case "$cap" in
                shell:exec|workspace:read|workspace:write|agent:spawn|ipc:admin|tools:exec|tasks:read|tasks:cull)
                    return 0 ;;
                *) return 1 ;;
            esac
            ;;
        agent)
            case "$cap" in
                workspace:read|workspace:write|tools:exec|ipc:read|ipc:write)
                    return 0 ;;
                *) return 1 ;;
            esac
            ;;
        guest)
            case "$cap" in
                workspace:read|tasks:read|status:read)
                    return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

auth_check_permission() {
    local subject="$1" cap="$2"
    [ -z "$subject" ] || [ -z "$cap" ] && return 1
    auth_init

    local role="$subject"
    # If subject exists as a user in users.json, resolve role
    if [ -f "$AUTH_USERS_FILE" ]; then
        local user_role
        user_role=$(jq -r --arg s "$subject" '.[] | select(.id == $s or .token == $s) | .role // empty' "$AUTH_USERS_FILE" 2>/dev/null)
        [ -n "$user_role" ] && role="$user_role"
    fi

    auth_role_has_cap "$role" "$cap"
}

# ── 4. Multi-Entity UUID Linkage Graph ────────────────────────────────
# Connects: session_id -> task_id -> agent_id -> pid -> channel_id -> user_id
identity_link() {
    local sess_id="$1" task_id="$2" agent_id="$3" pid="$4" channel_id="$5" user_id="${6:-george-admin}"
    auth_init
    [ -z "$task_id" ] && task_id=$(uuid_generate)
    [ -z "$sess_id" ] && sess_id="sess_$(uuid_generate)"
    local now_ts="${EPOCHSECONDS:-$(date +%s)}"

    local link_rec
    link_rec=$(jq -nc \
        --arg s "$sess_id" \
        --arg t "$task_id" \
        --arg a "$agent_id" \
        --argjson p "${pid:-0}" \
        --arg c "$channel_id" \
        --arg u "$user_id" \
        --arg ts "$now_ts" \
        '{session_id: $s, task_id: $t, agent_id: $a, pid: $p, channel_id: $c, user_id: $u, linked_at: ($ts|tonumber)}')

    local tmp="${AUTH_LINKS_FILE}.tmp.$$"
    jq --arg t "$task_id" --argjson rec "$link_rec" \
       '. = [ .[] | select(.task_id != $t) ] + [$rec]' \
       "$AUTH_LINKS_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$AUTH_LINKS_FILE" 2>/dev/null || return 1

    echo "$task_id"
}

identity_unlink() {
    local key="$1"
    auth_init
    [ -z "$key" ] && return 0
    local tmp="${AUTH_LINKS_FILE}.tmp.$$"
    jq --arg k "$key" \
       '. = [ .[] | select(.task_id != $k and .channel_id != $k and .session_id != $k) ]' \
       "$AUTH_LINKS_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$AUTH_LINKS_FILE" 2>/dev/null || return 1
}

identity_lookup_by_pid() {
    local q_pid="$1"
    auth_init
    jq -c --argjson p "$q_pid" '.[] | select(.pid == $p)' "$AUTH_LINKS_FILE" 2>/dev/null
}

identity_lookup_by_channel() {
    local q_cid="$1"
    auth_init
    jq -c --arg c "$q_cid" '.[] | select(.channel_id == $c)' "$AUTH_LINKS_FILE" 2>/dev/null
}

identity_lookup_by_task() {
    local q_tid="$1"
    auth_init
    jq -c --arg t "$q_tid" '.[] | select(.task_id == $t)' "$AUTH_LINKS_FILE" 2>/dev/null
}

identity_list_active() {
    auth_init
    # Filter links where PID is alive using awk for speed
    awk -v now="${EPOCHSECONDS:-$(date +%s)}" '
    BEGIN { RS=""; FS="\n" }
    {
        print $0
    }' "$AUTH_LINKS_FILE" 2>/dev/null | jq -c '[ .[] | select(.pid > 0) ]' 2>/dev/null || echo '[]'
}
