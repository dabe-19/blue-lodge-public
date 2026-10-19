#!/usr/bin/env bash
# lib/core/run_ledger.sh — Per-run ledger + outcome taxonomy (refinement P1/1.7)
#
# Every ReAct run gets $GEORGE_DIR/runs/<session_id>/run.json describing what
# was asked, which engine ran it, how it ended, and (if any) the final reply.
# Consumers (Discord reply contract, nightly eval, LoRA export) read ONLY this
# ledger instead of scraping workspaces/transcripts.
[ -n "${_LIB_RUN_LEDGER_LOADED:-}" ] && return 0; _LIB_RUN_LEDGER_LOADED=1

RUN_LEDGER_OUTCOMES="SUCCESS PARTIAL STALL LOOP TOOL_FAIL MAX_TURNS TIMEOUT INJECTION_BLOCKED MISALIGNED ABORTED"
RUN_LEDGER_LABELS="good bad partial wrong unsafe slow"

run_ledger_root() { printf '%s/runs' "${GEORGE_DIR:-${LODGE_DIR:-.}/.george}"; }

_rl_valid_id() { [[ "${1:-}" =~ ^[A-Za-z0-9_.-]{1,160}$ ]] && [[ "$1" != *..* ]]; }

_rl_file() { printf '%s/%s/run.json' "$(run_ledger_root)" "$1"; }

# Atomic jq update of run.json (creates a skeleton when missing).
_rl_update() {
    local sid="$1"; shift
    local f; f="$(_rl_file "$sid")"
    mkdir -p "${f%/*}" 2>/dev/null || return 1
    [ -s "$f" ] || printf '{"session_id":"%s","status":"RUNNING","labels":[]}\n' "$sid" > "$f"
    local tmp="${f}.tmp.$$"
    if jq "$@" "$f" > "$tmp" 2>/dev/null; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}

# run_ledger_start <session_id> <goal> [type] [tier] [model] [workspace]
run_ledger_start() {
    local sid="${1:-}" goal="${2:-}" type="${3:-react}" tier="${4:-${ACTIVE_TIER:-}}" model="${5:-${ACTIVE_ENDPOINT_MODEL:-}}" ws="${6:-}"
    _rl_valid_id "$sid" || { echo "run_ledger: invalid session id" >&2; return 1; }
    local now; now=$(date +%s)
    local cur_pid="${BASHPID:-$$}"
    _rl_update "$sid" --arg g "$goal" --arg t "$type" --arg tier "$tier" --arg m "$model" --arg ws "$ws" \
        --argjson e "$now" --arg iso "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" --arg p "${GEORGE_PARENT_TASK_ID:-}" \
        --arg pid "$cur_pid" \
        '.goal=$g | .type=$t | .tier=$tier | .model=$m | .workspace=$ws | .parent=(if $p=="" then null else $p end)
         | .pid=(($pid|tonumber?) // $pid) | .started_at=$iso | .started_epoch=$e | .status="RUNNING" | .labels=(.labels // [])'
}

# run_ledger_finish <session_id> <OUTCOME> [reason] [final_reply_src] [turns] [tool_calls] [tool_fails] [breaker_trips]
# Idempotent: the first terminal outcome wins (later cleanup paths are no-ops).
run_ledger_finish() {
    local sid="${1:-}" outcome="${2:-}" reason="${3:-}" reply_src="${4:-}"
    local turns="${5:-0}" calls="${6:-0}" fails="${7:-0}" trips="${8:-0}"
    _rl_valid_id "$sid" || return 1
    [[ " $RUN_LEDGER_OUTCOMES " == *" $outcome "* ]] || { echo "run_ledger: invalid outcome '$outcome'" >&2; return 2; }
    local n; for n in turns calls fails trips; do [[ "${!n}" =~ ^[0-9]+$ ]] || printf -v "$n" 0; done
    local f; f="$(_rl_file "$sid")"
    if [ -s "$f" ] && [ "$(jq -r '.status // ""' "$f" 2>/dev/null)" = "FINISHED" ]; then return 0; fi

    local now started reply_dst=""
    now=$(date +%s)
    started=$(jq -r '.started_epoch // empty' "$f" 2>/dev/null)
    [[ "$started" =~ ^[0-9]+$ ]] || started=$now
    if [ -n "$reply_src" ] && [ -s "$reply_src" ]; then
        reply_dst="${f%/*}/final_reply.md"
        mkdir -p "${f%/*}"
        cp "$reply_src" "$reply_dst" 2>/dev/null || reply_dst=""
    fi
    # Preserve the full trajectory for eval/LoRA export: workspaces can be culled from the Workbench.
    local ws; ws=$(jq -r '.workspace // empty' "$f" 2>/dev/null)
    if [ -n "$ws" ] && [ -s "$ws/messages.json" ]; then
        mkdir -p "${f%/*}" && cp "$ws/messages.json" "${f%/*}/messages.json" 2>/dev/null || true
    fi
    if [ -n "$ws" ] && [ -s "$ws/trajectory.log" ]; then
        mkdir -p "${f%/*}" && cp "$ws/trajectory.log" "${f%/*}/trajectory.log" 2>/dev/null || true
    fi
    local wall=$(( now - started ))
    _rl_update "$sid" --arg o "$outcome" --arg r "$reason" --arg fr "$reply_dst" \
        --argjson e "$now" --arg iso "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" --argjson w "$wall" \
        --argjson tu "$turns" --argjson tc "$calls" --argjson tf "$fails" --argjson bt "$trips" --arg tr "${_TRANSCRIPT_FILE:-}" \
        '.status="FINISHED" | .outcome=$o | .reason=(if $r=="" then null else $r end)
         | .final_reply=(if $fr=="" then null else $fr end) | .ended_at=$iso | .ended_epoch=$e | .wall_s=$w
         | .turns=$tu | .tool_calls=$tc | .tool_fails=$tf | .breaker_trips=$bt
         | .transcript=(if $tr=="" then (.transcript // null) else $tr end)' || return 1

    local payload
    payload=$(jq -cn --arg s "$sid" --arg o "$outcome" --argjson t "$turns" --argjson w "$wall" \
        --arg r "$reason" --arg ty "$(jq -r '.type // "react"' "$f" 2>/dev/null)" \
        '{session_id:$s, outcome:$o, turns:$t, wall_s:$w, type:$ty} + (if $r=="" then {} else {reason:$r} end)')
    if ! declare -f event_bus_emit &>/dev/null && [ -f "${LODGE_DIR:-}/lib/ipc/event_bus.sh" ]; then
        source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true
    fi
    if declare -f event_bus_emit &>/dev/null; then
        if [ "${RUN_LEDGER_EMIT_SYNC:-0}" = "1" ]; then
            event_bus_emit "agent.run_complete" "$payload" "run_ledger"
        else
            ( event_bus_emit "agent.run_complete" "$payload" "run_ledger" >/dev/null 2>&1 & )
        fi
    fi
    return 0
}

# run_ledger_label <session_id> <label> <source> <user> [note]
run_ledger_label() {
    local sid="${1:-}" label="${2:-}" src="${3:-manual}" user="${4:-}" note="${5:-}"
    _rl_valid_id "$sid" || return 1
    [[ " $RUN_LEDGER_LABELS " == *" $label "* ]] || return 2
    _rl_update "$sid" --arg l "$label" --arg s "$src" --arg u "$user" --arg n "${note:0:500}" \
        --arg iso "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.labels = ((.labels // []) + [{label:$l, source:$s, user:$u, ts:$iso} + (if $n=="" then {} else {note:$n} end)])'
}

# Map a breaker reason string to LOOP vs TOOL_FAIL.
run_ledger_classify_breaker() {
    case "${1:-}" in
        *"tool failure"*|*"Tool failure"*|*CAPABILITY*|*exhausted*) echo "TOOL_FAIL" ;;
        *) echo "LOOP" ;;
    esac
}

# run_ledger_infer_outcome <rc> <macro_status> <has_final_reply yes|no>
run_ledger_infer_outcome() {
    local rc="${1:-0}" status="${2:-}" has_reply="${3:-no}"
    [ "$rc" = "130" ] && { echo "ABORTED"; return; }
    case "$status" in
        COMPLETED) echo "SUCCESS"; return ;;
        CIRCUIT_BREAKER_TRIPPED) echo "LOOP"; return ;;
        CAPABILITY_EXHAUSTED) echo "TOOL_FAIL"; return ;;
        TURN_CEILING_PRESERVED) echo "MAX_TURNS"; return ;;
    esac
    [ "$has_reply" = "yes" ] && { echo "SUCCESS"; return; }
    echo "ABORTED"
}
# Retention lives in lib/sys/janitor.sh (janitor_run).
