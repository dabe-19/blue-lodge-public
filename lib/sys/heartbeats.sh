#!/bin/bash
# ── George: Liveness Heartbeats (refinement P1/1.6) ──────────────────
# Each long-running subsystem writes $GEORGE_DIR/heartbeats/<name>.json:
#   {"name": "...", "ts": <epoch>, "pid": <pid>, ...extra}
# heartbeat_stale reports subsystems whose last beat is older than N seconds.
# The Workbench reads the same directory via /api/status.

[ -n "${_LIB_HEARTBEATS_LOADED:-}" ] && return 0; _LIB_HEARTBEATS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

_heartbeat_dir() { printf '%s' "${HEARTBEAT_DIR:-$GEORGE_DIR/heartbeats}"; }

# Usage: heartbeat_write <name> [extra_json_object]
# Zero-fork when no extra JSON is given (safe to call every cron tick).
heartbeat_write() {
    local name="${1:-}" extra="${2:-}"
    [[ "$name" =~ ^[a-z0-9_-]{1,40}$ ]] || return 1
    local dir; dir="$(_heartbeat_dir)"
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
    local now="${EPOCHSECONDS:-$(date +%s)}"
    local pid="${BASHPID:-$$}"
    local tmp="$dir/.${name}.json.$pid"
    if [ -n "$extra" ]; then
        jq -c --arg n "$name" --argjson ts "$now" --argjson pid "$pid" \
            '(if type == "object" then . else {} end) + {name: $n, ts: $ts, pid: $pid}' \
            <<<"$extra" > "$tmp" 2>/dev/null || printf '{"name":"%s","ts":%s,"pid":%s}\n' "$name" "$now" "$pid" > "$tmp"
    else
        printf '{"name":"%s","ts":%s,"pid":%s}\n' "$name" "$now" "$pid" > "$tmp" 2>/dev/null || return 1
    fi
    mv -f "$tmp" "$dir/${name}.json" 2>/dev/null
}

# Usage: heartbeat_stale [max_age_secs=1800]
# Prints one JSON line per stale heartbeat; returns 1 if any are stale.
heartbeat_stale() {
    local max="${1:-1800}"
    [[ "$max" =~ ^[0-9]+$ ]] || max=1800
    local dir; dir="$(_heartbeat_dir)"
    [ -d "$dir" ] || return 0
    local now="${EPOCHSECONDS:-$(date +%s)}" stale=0 f
    for f in "$dir"/*.json; do
        [ -f "$f" ] || continue
        local line
        line=$(jq -c --argjson now "$now" --argjson max "$max" \
            'select((.ts // 0) < ($now - $max)) | {name, ts, age_s: ($now - (.ts // 0))}' "$f" 2>/dev/null)
        if [ -n "$line" ]; then
            printf '%s\n' "$line"
            stale=1
        fi
    done
    [ "$stale" -eq 0 ]
}
