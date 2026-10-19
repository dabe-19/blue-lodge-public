#!/bin/bash
# ── George: Sovereign POSIX Reactive Event Bus & Autonomic Reaction Engine ────
# Event-driven reflexes built ON the FIFO Async/Await & Flow Control protocol:
#   1. Named FIFO ingress (.george/ipc/event_bus.fifo). Envelopes are single-line
#      NDJSON < PIPE_BUF (large payloads spill to disk) => kernel-atomic writes.
#   2. Synchronous, ordered emission with bounded wait; if the daemon is down or the
#      pipe is saturated the envelope goes to a durable replay spool (never dropped).
#   3. Declarative reactor registry (.george/reactors.json), mutated only under flock.
#   4. Every reaction runs as an ipc_async promise (own process group, timeout, exit
#      code) gated by a per-reactor IPC credit channel "rx_<id>" (max_concurrency).
#   5. Overflow policy per reactor when debounced or saturated:
#        drop     – discard (legacy behaviour)
#        coalesce – keep only the newest pending event, fire on the trailing edge
#        queue    – keep every event, fire in order as cooldown/credits allow
#   6. Causal depth propagates automatically through reactor-emitted events
#      (EVENT_DEPTH / EVENT_ID), so the circuit breaker actually bounds cascades.
#   7. Zero-fork hot path: reactors are cached in memory and pattern-matched with
#      Bash regex; event-store writes are batched once per tick.

[ -n "${_LIB_EVENT_BUS_LOADED:-}" ] && return 0; _LIB_EVENT_BUS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

_EB_LIB_DIR="${BASH_SOURCE[0]%/*}"
[ "$_EB_LIB_DIR" = "${BASH_SOURCE[0]}" ] && _EB_LIB_DIR="."
_EB_LIB_DIR="$(cd "$_EB_LIB_DIR" 2>/dev/null && pwd)"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || source "$_EB_LIB_DIR/../ui/ui.sh" 2>/dev/null || true
source "$_EB_LIB_DIR/fifo_ipc.sh" 2>/dev/null || source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null || true

EVENT_BUS_DIR="${EVENT_BUS_DIR:-${FIFO_IPC_DIR:-$GEORGE_DIR/ipc}}"
EVENT_BUS_FIFO="${EVENT_BUS_FIFO:-$EVENT_BUS_DIR/event_bus.fifo}"
EVENT_BUS_REACTORS="${EVENT_BUS_REACTORS:-$GEORGE_DIR/reactors.json}"
EVENT_BUS_LOG="${EVENT_BUS_LOG:-$EVENT_BUS_DIR/event_bus.log}"
EVENT_BUS_PID_FILE="${EVENT_BUS_PID_FILE:-$EVENT_BUS_DIR/event_bus.pid}"
EVENT_BUS_LOCK="${EVENT_BUS_LOCK:-$EVENT_BUS_DIR/locks/event_bus.lock}"
EVENT_BUS_COOLDOWNS_DIR="${EVENT_BUS_COOLDOWNS_DIR:-$EVENT_BUS_DIR/cooldowns}"
EVENT_BUS_MAX_DEPTH="${EVENT_BUS_MAX_DEPTH:-3}"
EVENT_BUS_DEFAULT_DEBOUNCE="${EVENT_BUS_DEFAULT_DEBOUNCE:-2}"
EVENT_BUS_DEFAULT_CONCURRENCY="${EVENT_BUS_DEFAULT_CONCURRENCY:-4}"
EVENT_BUS_DEFAULT_TIMEOUT="${EVENT_BUS_DEFAULT_TIMEOUT:-300}"
EVENT_BUS_DEFAULT_OVERFLOW="${EVENT_BUS_DEFAULT_OVERFLOW:-drop}"
EVENT_BUS_PENDING_MAX="${EVENT_BUS_PENDING_MAX:-500}"
EVENT_BUS_EMIT_TIMEOUT="${EVENT_BUS_EMIT_TIMEOUT:-2}"
EVENT_BUS_MAX_LINE="${EVENT_BUS_MAX_LINE:-3900}"
EVENT_BUS_LOG_MAX_BYTES="${EVENT_BUS_LOG_MAX_BYTES:-10485760}"
EVENT_BUS_TICK="${EVENT_BUS_TICK:-0.5}"
[ -n "${EVENT_STORE_DB:-}" ] && _EB_STORE_PINNED=1
EVENT_STORE_DB="${EVENT_STORE_DB:-$GEORGE_DIR/events.db}"
# Event contract registry (refinement P1/1.1). Warn-only unless strict.
EVENT_CONTRACTS_FILE="${EVENT_CONTRACTS_FILE:-$LODGE_DIR/configs/event_contracts.json}"
EVENT_CONTRACTS_STRICT="${EVENT_CONTRACTS_STRICT:-0}"
declare -gA _EB_CONTRACT_H=() _EB_CONTRACT_REQ=() 2>/dev/null || true
_EB_CONTRACTS_MTIME=""
_EB_LAST_GDIR="$GEORGE_DIR"
_EB_LAST_EBDIR="$EVENT_BUS_DIR"

# Derived paths (re-evaluated lazily so tests can override GEORGE_DIR/EVENT_BUS_DIR after sourcing)
_eb_paths() {
    if [ "${_EB_LAST_GDIR:-}" != "$GEORGE_DIR" ]; then
        EVENT_BUS_DIR="${GEORGE_DIR}/ipc"
        EVENT_BUS_REACTORS="${GEORGE_DIR}/reactors.json"
        _EB_LAST_GDIR="$GEORGE_DIR"
    fi
    if [ "${_EB_LAST_EBDIR:-}" != "$EVENT_BUS_DIR" ]; then
        EVENT_BUS_FIFO="$EVENT_BUS_DIR/event_bus.fifo"
        EVENT_BUS_LOG="$EVENT_BUS_DIR/event_bus.log"
        EVENT_BUS_PID_FILE="$EVENT_BUS_DIR/event_bus.pid"
        EVENT_BUS_LOCK="$EVENT_BUS_DIR/locks/event_bus.lock"
        EVENT_BUS_COOLDOWNS_DIR="$EVENT_BUS_DIR/cooldowns"
        FIFO_IPC_DIR="$EVENT_BUS_DIR"
        _EB_LAST_EBDIR="$EVENT_BUS_DIR"
    fi
    [ -z "${_EB_STORE_PINNED:-}" ] && EVENT_STORE_DB="$GEORGE_DIR/events.db"
    _EB_SPOOL="$EVENT_BUS_DIR/event_spool.ndjson"
    _EB_PENDING="$EVENT_BUS_DIR/pending"
    _EB_PAYLOADS="$EVENT_BUS_DIR/payloads"
    _EB_STATS="$EVENT_BUS_DIR/event_bus_stats.json"
}

# ── Helper: Epoch Seconds ────────────────────────────────────────────
_eb_now() {
    echo "${EPOCHSECONDS:-$(date +%s)}"
}

# ── Helper: Log Message (zero-fork timestamp) ────────────────────────
_eb_log() {
    local level="$1"
    local msg="$2"
    [ -d "${EVENT_BUS_LOG%/*}" ] || mkdir -p "${EVENT_BUS_LOG%/*}" 2>/dev/null
    printf "[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n" -1 "$level" "$msg" >> "$EVENT_BUS_LOG" 2>/dev/null || true
}

# ── Helper: SQL literal quoting (zero-fork) ──────────────────────────
_eb_sqv() { local __o="$1" __s="${2//\'/\'\'}"; printf -v "$__o" "'%s'" "$__s"; }

# Executes (daemon: batches) a SQL statement against the event store.
_eb_sql() {
    local stmt="$1"
    [ -f "$EVENT_STORE_DB" ] || return 0
    command -v sqlite3 &>/dev/null || return 0
    if [ "${_EB_DAEMON:-0}" = "1" ]; then
        _EB_SQL_BUF+="${stmt}"$'\n'
        _EB_SQL_N=$(( ${_EB_SQL_N:-0} + 1 ))
        [ "$_EB_SQL_N" -ge 200 ] && _eb_sql_flush
    else
        ( printf 'PRAGMA busy_timeout = 3000;\n%s\n' "$stmt" | sqlite3 "$EVENT_STORE_DB" >/dev/null 2>&1 ) &
        disown $! 2>/dev/null || true
    fi
}

_eb_sql_flush() {
    [ -z "${_EB_SQL_BUF:-}" ] && return 0
    local buf="$_EB_SQL_BUF"
    _EB_SQL_BUF=""; _EB_SQL_N=0
    ( printf 'PRAGMA busy_timeout = 5000;\nBEGIN;\n%sCOMMIT;\n' "$buf" | sqlite3 "$EVENT_STORE_DB" >/dev/null 2>&1 ) &
    disown $! 2>/dev/null || true
}

# ── Initialization ───────────────────────────────────────────────────
event_bus_init() {
    _eb_paths
    [ -d "$EVENT_BUS_COOLDOWNS_DIR" ] && [ -d "$EVENT_BUS_DIR/locks" ] && [ -d "$_EB_PENDING" ] && [ -d "$_EB_PAYLOADS" ] \
        || mkdir -p "$EVENT_BUS_DIR" "$EVENT_BUS_DIR/locks" "$EVENT_BUS_COOLDOWNS_DIR" "$_EB_PENDING" "$_EB_PAYLOADS" 2>/dev/null || true

    if [ ! -p "$EVENT_BUS_FIFO" ]; then
        rm -f "$EVENT_BUS_FIFO" 2>/dev/null || true
        mkfifo -m 0600 "$EVENT_BUS_FIFO" 2>/dev/null || true
    fi

    if [ ! -f "$EVENT_STORE_DB" ] && [ -f "$LODGE_DIR/lib/tools/event_store.py" ]; then
        python3 "$LODGE_DIR/lib/tools/event_store.py" --init >/dev/null 2>&1 || true
    fi

    if [ ! -f "$EVENT_BUS_REACTORS" ]; then
        mkdir -p "$(dirname "$EVENT_BUS_REACTORS")" 2>/dev/null || true
        cat << 'EOF' > "$EVENT_BUS_REACTORS"
{
  "reactors": [],
  "stats": {
    "events_total": 0,
    "reactions_fired": 0,
    "last_event_ts": 0,
    "last_reaction_ts": 0
  }
}
EOF
    fi
    return 0
}

# ── Daemon Running Check ─────────────────────────────────────────────
event_bus_is_running() {
    [ -f "$EVENT_BUS_PID_FILE" ] || return 1
    local pid=""
    pid=$(< "$EVENT_BUS_PID_FILE") 2>/dev/null
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    rm -f "$EVENT_BUS_PID_FILE" 2>/dev/null || true
    return 1
}

# Appends an envelope to the durable replay spool (O_APPEND, < PIPE_BUF => atomic).
_eb_spool() {
    _eb_paths
    mkdir -p "$EVENT_BUS_DIR" 2>/dev/null
    printf '%s\n' "$1" >> "$_EB_SPOOL" 2>/dev/null
}

# ── Event Contracts ──────────────────────────────────────────────────
# Loads config/event_contracts.json into memory (reloaded when mtime changes).
_eb_contracts_load() {
    [ -f "$EVENT_CONTRACTS_FILE" ] || return 1
    local mt
    mt=$(stat -c %Y "$EVENT_CONTRACTS_FILE" 2>/dev/null) || return 1
    [ "$mt" = "$_EB_CONTRACTS_MTIME" ] && return 0
    _EB_CONTRACT_H=(); _EB_CONTRACT_REQ=()
    local t h r
    while IFS=$'\t' read -r t h r; do
        [ -n "$t" ] || continue
        _EB_CONTRACT_H["$t"]="$h"
        _EB_CONTRACT_REQ["$t"]="$r"
    done < <(jq -r '.contracts[] | [.type, .handling, ((.required // []) | join(","))] | @tsv' "$EVENT_CONTRACTS_FILE" 2>/dev/null)
    _EB_CONTRACTS_MTIME="$mt"
    return 0
}

# Usage: _eb_contract_check <type> <payload_json>
# Returns 0 ok, 3 uncontracted/deprecated/test-only outside sandbox,
# 4 missing required payload fields. Sets _EB_CONTRACT_MSG.
_eb_contract_check() {
    local t="$1" pl="$2"
    _EB_CONTRACT_MSG=""
    _eb_contracts_load || return 0   # no registry => nothing to enforce
    local h="${_EB_CONTRACT_H[$t]:-}"
    if [ -z "$h" ]; then
        _EB_CONTRACT_MSG="uncontracted event type '$t'"; return 3
    fi
    case "$h" in
        deprecated) _EB_CONTRACT_MSG="deprecated event type '$t'"; return 3 ;;
        test_only)
            if [ -z "${GEORGE_TEST_SANDBOX:-}" ]; then
                _EB_CONTRACT_MSG="test-only event type '$t' emitted outside the test sandbox"; return 3
            fi ;;
    esac
    local req="${_EB_CONTRACT_REQ[$t]:-}"
    [ -z "$req" ] && return 0
    local missing
    missing=$(jq -r --arg req "$req" \
        '($req | split(",")) as $r | if type != "object" then $r | join(",") else [ $r[] as $k | select(.[$k] == null) | $k ] | join(",") end' \
        <<<"$pl" 2>/dev/null) || missing="$req"
    if [ -n "$missing" ]; then
        _EB_CONTRACT_MSG="'$t' missing required fields: $missing"; return 4
    fi
    return 0
}

# ── Event Emission ───────────────────────────────────────────────────
# Usage: event_bus_emit <event_type> <json_payload_or_string> [source] [depth]
# Depth defaults to the inherited causal depth (EVENT_DEPTH) so reactor-emitted
# events are bounded by the circuit breaker. Returns 0 when the envelope was
# written to the bus or durably spooled for replay.
event_bus_emit() {
    local event_type="${1:-}"
    local payload="${2:-}"
    local source="${3:-direct}"
    local depth="${4:-${EVENT_DEPTH:-0}}"
    [ -z "$event_type" ] && return 1
    [[ "$depth" =~ ^[0-9]+$ ]] || depth=0

    event_bus_init

    local payload_json=""
    [ -n "$payload" ] && payload_json=$(printf '%s' "$payload" | jq -c . 2>/dev/null)
    if [ -z "$payload_json" ] || [[ "$payload_json" == *$'\n'* ]]; then
        payload_json=$(printf '%s' "$payload" | jq -Rsc . 2>/dev/null)
    fi
    [ -z "$payload_json" ] && payload_json='""'

    _eb_contract_check "$event_type" "$payload_json"
    local _crc=$?
    if [ "$_crc" -ne 0 ]; then
        if [ "$EVENT_CONTRACTS_STRICT" = "1" ]; then
            _eb_log "CONTRACT_REJECT" "[$event_type] from $source: $_EB_CONTRACT_MSG"
            return "$_crc"
        fi
        _eb_log "CONTRACT_WARN" "[$event_type] from $source: $_EB_CONTRACT_MSG"
    fi

    local ts="${EPOCHSECONDS:-$(date +%s)}"
    local evt_id="evt_${ts}_${BASHPID}_${RANDOM}"

    # PIPE_BUF protection: spill large payloads to disk, keep the envelope atomic
    local plen
    _ipc_blen plen "$payload_json"
    if [ $((plen + 600)) -gt "$EVENT_BUS_MAX_LINE" ]; then
        local pfile="$_EB_PAYLOADS/${evt_id}.json"
        printf '%s' "$payload_json" > "$pfile" || return 1
        payload_json=$(printf '%s' "${payload_json:0:200}" | jq -Rsc --arg f "$pfile" --argjson b "$plen" \
            '{__spillover_ref__: $f, bytes: $b, preview: .}')
    fi

    local envelope
    envelope=$(jq -n -c \
        --arg id "$evt_id" \
        --arg type "$event_type" \
        --arg src "$source" \
        --argjson pl "$payload_json" \
        --argjson dp "$depth" \
        --argjson ts "$ts" \
        --arg parent "${EVENT_ID:-}" \
        '{event_id: $id, type: $type, source: $src, payload: $pl, depth: $dp, timestamp: $ts}
         + (if $parent != "" then {parent_event_id: $parent} else {} end)' 2>/dev/null)
    [ -z "$envelope" ] && return 1

    local delivered=0
    if event_bus_is_running && [ -p "$EVENT_BUS_FIFO" ]; then
        if command -v timeout &>/dev/null; then
            timeout "$EVENT_BUS_EMIT_TIMEOUT" bash -c 'exec 4<>"$2"; printf "%s\n" "$1" >&4' _ "$envelope" "$EVENT_BUS_FIFO" 2>/dev/null && delivered=1
        else
            { printf '%s\n' "$envelope" >&4; } 4<> "$EVENT_BUS_FIFO" 2>/dev/null && delivered=1
        fi
    fi

    if [ "$delivered" -eq 1 ]; then
        _eb_log "EMIT" "[$event_type] from $source (id: $evt_id, depth: $depth)"
        return 0
    fi
    if _eb_spool "$envelope"; then
        _eb_log "SPOOL" "[$event_type] from $source (id: $evt_id) spooled for replay (bus offline/saturated)"
        return 0
    fi
    _eb_log "EMIT_FAIL" "[$event_type] from $source (id: $evt_id) could not be delivered or spooled"
    return 1
}

# ── Reactor Registry Management (all mutations under EVENT_BUS_LOCK) ──

_eb_reactor_add_locked() {
    local rid="$1" rtype="$2" rpattern="$3" raction="$4" rdebounce="$5" rover="$6" rconc="$7" rtmo="$8"
    local tmp="${EVENT_BUS_REACTORS}.tmp.${BASHPID}"
    jq --arg id "$rid" \
       --arg type "$rtype" \
       --arg pat "$rpattern" \
       --arg act "$raction" \
       --argjson deb "$rdebounce" \
       --arg ovf "$rover" \
       --argjson conc "$rconc" \
       --argjson tmo "$rtmo" \
       '
       .reactors |= (map(select(.id != $id)) + [{
           id: $id,
           event_type: $type,
           pattern: $pat,
           action: $act,
           debounce_secs: $deb,
           overflow: $ovf,
           max_concurrency: $conc,
           timeout_secs: $tmo,
           enabled: true,
           created_at: (now | floor)
       }])
       ' "$EVENT_BUS_REACTORS" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv -f "$tmp" "$EVENT_BUS_REACTORS"
}

# Usage: reactor_add <id> <event_type> <pattern> <action> [debounce_secs] [overflow] [max_concurrency] [timeout_secs]
reactor_add() {
    local rid="$1"
    local rtype="$2"
    local rpattern="$3"
    local raction="$4"
    local rdebounce="${5:-$EVENT_BUS_DEFAULT_DEBOUNCE}"
    local rover="${6:-$EVENT_BUS_DEFAULT_OVERFLOW}"
    local rconc="${7:-$EVENT_BUS_DEFAULT_CONCURRENCY}"
    local rtmo="${8:-$EVENT_BUS_DEFAULT_TIMEOUT}"

    if [ -z "$rid" ] || [ -z "$rtype" ] || [ -z "$raction" ]; then
        return 1
    fi
    [[ "$rdebounce" =~ ^[0-9]+$ ]] || rdebounce="$EVENT_BUS_DEFAULT_DEBOUNCE"
    [[ "$rconc" =~ ^[1-9][0-9]*$ ]] || rconc="$EVENT_BUS_DEFAULT_CONCURRENCY"
    [[ "$rtmo" =~ ^[1-9][0-9]*$ ]] || rtmo="$EVENT_BUS_DEFAULT_TIMEOUT"
    case "$rover" in drop|coalesce|queue) ;; *) rover="$EVENT_BUS_DEFAULT_OVERFLOW" ;; esac

    event_bus_init
    _ipc_with_lock "$EVENT_BUS_LOCK" _eb_reactor_add_locked "$rid" "$rtype" "$rpattern" "$raction" "$rdebounce" "$rover" "$rconc" "$rtmo" || return 1

    _eb_log "REACTOR_ADD" "Registered reactor '$rid' on event '$rtype' (pattern: '$rpattern', overflow: $rover, concurrency: $rconc)"
    return 0
}

_eb_reactor_filter_locked() {
    local filt="$1"; shift
    local tmp="${EVENT_BUS_REACTORS}.tmp.${BASHPID}"
    jq "$@" "$filt" "$EVENT_BUS_REACTORS" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv -f "$tmp" "$EVENT_BUS_REACTORS"
}

# Usage: reactor_remove <id>
reactor_remove() {
    local rid="$1"
    [ -z "$rid" ] && return 1
    event_bus_init
    _ipc_with_lock "$EVENT_BUS_LOCK" _eb_reactor_filter_locked '.reactors |= map(select(.id != $id))' --arg id "$rid" || return 1
    _eb_log "REACTOR_REMOVE" "Removed reactor '$rid'"
    return 0
}

# Usage: reactor_list
reactor_list() {
    event_bus_init
    jq -r '.reactors // []' "$EVENT_BUS_REACTORS" 2>/dev/null || echo "[]"
}

# Usage: reactor_toggle <id> [true|false]
reactor_toggle() {
    local rid="$1"
    local state="${2:-toggle}"
    [ -z "$rid" ] && return 1
    event_bus_init
    local filt
    if [ "$state" = "true" ] || [ "$state" = "enable" ]; then
        filt='(.reactors[] | select(.id == $id)).enabled = true'
    elif [ "$state" = "false" ] || [ "$state" = "disable" ]; then
        filt='(.reactors[] | select(.id == $id)).enabled = false'
    else
        filt='(.reactors[] | select(.id == $id)).enabled |= not'
    fi
    _ipc_with_lock "$EVENT_BUS_LOCK" _eb_reactor_filter_locked "$filt" --arg id "$rid"
}

# Sets one field on a reactor (overflow, max_concurrency, timeout_secs, debounce_secs, ...)
# Usage: reactor_set <id> <field> <json_value>
reactor_set() {
    local rid="$1" field="$2" val="$3"
    [ -z "$rid" ] || [ -z "$field" ] && return 1
    [[ "$field" =~ ^[a-z_]+$ ]] || return 1
    printf '%s' "$val" | jq -e . >/dev/null 2>&1 || val=$(jq -nc --arg v "$val" '$v')
    event_bus_init
    _ipc_with_lock "$EVENT_BUS_LOCK" _eb_reactor_filter_locked \
        "(.reactors[] | select(.id == \$id)).${field} = \$v" --arg id "$rid" --argjson v "$val"
}

# Idempotently registers the built-in system reactors that close IPC control loops.
event_bus_seed_system_reactors() {
    event_bus_init
    local have
    have=$(jq -r '[.reactors[]?.id] | join(" ")' "$EVENT_BUS_REACTORS" 2>/dev/null)
    if [[ " $have " != *" rx_wake_task "* ]]; then
        reactor_add "rx_wake_task" "WAKE_TASK" ".*" \
            'source "${LODGE_DIR:-$HOME/blue-lodge}/lib/core/agent_sm.sh" && agent_sm_resume "$(printf "%s" "$EVENT_PAYLOAD" | jq -r ".uuid // empty")"' \
            0 queue 2 120
    fi
    if [[ " $have " != *" rx_fault_quarantine "* ]]; then
        reactor_add "rx_fault_quarantine" "FAULT_QUARANTINE" ".*" \
            'printf "[%(%Y-%m-%d %H:%M:%S)T] QUARANTINE %s\n" -1 "$EVENT_PAYLOAD" >> "${LODGE_DIR:-$HOME/blue-lodge}/.george/ipc/quarantine.log"' \
            0 queue 1 30
    fi
}

# ── Reactor Cache (reloaded only when reactors.json changes) ─────────
_eb_reactors_load() {
    _eb_paths
    local stamp="$EVENT_BUS_DIR/.reactors.stamp.${BASHPID}"
    if [ -n "${_EB_RX_LOADED:-}" ] && [ -f "$stamp" ] && ! [ "$EVENT_BUS_REACTORS" -nt "$stamp" ]; then
        return 0
    fi
    _EB_RX_ID=(); _EB_RX_TYPE=(); _EB_RX_PAT=(); _EB_RX_ACT=()
    _EB_RX_DEB=(); _EB_RX_OVF=(); _EB_RX_CONC=(); _EB_RX_TMO=()
    local f1 f2 f3 f4 f5 f6 f7 f8
    while IFS= read -r -d '' f1 && IFS= read -r -d '' f2 && IFS= read -r -d '' f3 && IFS= read -r -d '' f4 \
       && IFS= read -r -d '' f5 && IFS= read -r -d '' f6 && IFS= read -r -d '' f7 && IFS= read -r -d '' f8; do
        _EB_RX_ID+=("$f1"); _EB_RX_TYPE+=("$f2"); _EB_RX_PAT+=("$f3"); _EB_RX_ACT+=("$f4")
        _EB_RX_DEB+=("$f5"); _EB_RX_OVF+=("$f6"); _EB_RX_CONC+=("$f7"); _EB_RX_TMO+=("$f8")
    done < <(jq -j --arg dconc "$EVENT_BUS_DEFAULT_CONCURRENCY" --arg dtmo "$EVENT_BUS_DEFAULT_TIMEOUT" --arg dovf "$EVENT_BUS_DEFAULT_OVERFLOW" '
        .reactors[]? | select(.enabled == true) |
        [ .id, .event_type, (.pattern // ""), .action,
          ((.debounce_secs // 0) | tostring),
          (.overflow // $dovf),
          ((.max_concurrency // ($dconc|tonumber)) | tostring),
          ((.timeout_secs // ($dtmo|tonumber)) | tostring) ]
        | map(tostring | gsub("\u0000"; "")) | join("\u0000") + "\u0000"' "$EVENT_BUS_REACTORS" 2>/dev/null)
    : > "$stamp" 2>/dev/null
    _EB_RX_LOADED=1
}

# ── Envelope Parsing (single jq) ─────────────────────────────────────
# Sets: _EV_ID _EV_TYPE _EV_SRC _EV_DEPTH _EV_TS _EV_PARENT _EV_PAYLOAD
_eb_parse_envelope() {
    local env="$1"
    _EV_ID=""; _EV_TYPE=""; _EV_SRC="unknown"; _EV_DEPTH=0; _EV_TS=0; _EV_PARENT=""; _EV_PAYLOAD="{}"
    {
        IFS= read -r -d '' _EV_ID; IFS= read -r -d '' _EV_TYPE; IFS= read -r -d '' _EV_SRC
        IFS= read -r -d '' _EV_DEPTH; IFS= read -r -d '' _EV_TS; IFS= read -r -d '' _EV_PARENT
        IFS= read -r -d '' _EV_PAYLOAD
    } < <(printf '%s' "$env" | jq -j '
        [ (.event_id // ""), ((.type // .event_type) // ""), (.source // "unknown"),
          ((.depth // 0) | tostring), ((.timestamp // 0) | tostring), (.parent_event_id // ""),
          ((.payload // {}) | tojson) ] | map(tostring | gsub("\u0000"; "")) | join("\u0000") + "\u0000"' 2>/dev/null)
    [[ "$_EV_DEPTH" =~ ^[0-9]+$ ]] || _EV_DEPTH=0
    [[ "$_EV_TS" =~ ^[0-9]+$ ]] || _EV_TS=0
    [ -z "$_EV_PAYLOAD" ] && _EV_PAYLOAD="{}"

    # Hydrate spilled payloads (only from our own payload store)
    if [[ "$_EV_PAYLOAD" =~ ^\{\"__spillover_ref__\":\"([^\"]+)\" ]]; then
        local pf="${BASH_REMATCH[1]}"
        _eb_paths
        if [[ "$pf" == "$_EB_PAYLOADS/"* ]] && [[ "$pf" != *..* ]] && [ -f "$pf" ]; then
            _EV_PAYLOAD=$(< "$pf")
            _EV_SPILL_FILE="$pf"
        fi
    fi
    [ -n "$_EV_TYPE" ]
}

# ── Credit-gated Reaction Launch ─────────────────────────────────────
# Opens (lazily) the reactor's credit channel sized to its max_concurrency.
_eb_rx_channel() {
    local rid="$1" conc="$2" cid="rx_${1//[^A-Za-z0-9_.-]/_}"
    local sf="$FIFO_IPC_DIR/channels/$cid/state.json"
    if ! ipc_channel_is_open "$cid"; then
        ipc_channel_open "$cid" "$conc" 31536000 "$IPC_PRIO_SYSTEM" credit >/dev/null 2>&1 || return 1
    else
        local raw win
        raw=$(< "$sf")
        _ipc_jget_raw win "$raw" window_size 0
        if [ "$win" != "$conc" ]; then
            _ipc_with_lock "$FIFO_IPC_DIR/channels/$cid/state.lock" _ipc_state_patch "$sf" "window_size=$conc"
        fi
    fi
    _EB_RX_CID="$cid"
}

# Returns the credit for a finished reaction exactly once (idempotent across the
# reaction runner and the daemon reaper).
_eb_release() {
    local rid="$1" prom="$2" cid="rx_${1//[^A-Za-z0-9_.-]/_}"
    [ -z "$prom" ] && return 0
    mkdir "$FIFO_IPC_DIR/promises/${prom}.rel" 2>/dev/null || return 0
    ipc_flow_grant "$cid" 1 >/dev/null 2>&1 || true
}

# Runs inside the ipc_async worker (own process group).
_eb_run_reaction() {
    local t0="${EPOCHREALTIME//[.,]/}"
    ( eval "$REACTOR_ACTION" ) >> "$EVENT_BUS_LOG" 2>&1
    local rc=$?
    local t1="${EPOCHREALTIME//[.,]/}"
    local dur=$(( (t1 - t0) / 1000 ))
    local st_val="SUCCESS"
    [ "$rc" -ne 0 ] && st_val="ERROR"
    local q_id q_type q_rid q_act
    _eb_sqv q_id "$EVENT_ID"; _eb_sqv q_type "$EVENT_TYPE"; _eb_sqv q_rid "$REACTOR_ID"; _eb_sqv q_act "$REACTOR_ACTION"
    _EB_DAEMON=0 _eb_sql "INSERT INTO reactions (event_id, event_type, reactor_id, action_cmd, status, exit_code, duration_ms, output_snippet, fired_at) VALUES ($q_id, $q_type, $q_rid, $q_act, '$st_val', $rc, $dur, '', ${EPOCHSECONDS});"
    _eb_release "$REACTOR_ID" "${IPC_PROMISE_ID:-}"
    return "$rc"
}

# Attempts to fire reactor index $1 for the currently parsed event (_EV_*).
# Returns 0 fired | 1 saturated (no credit) | 2 launch failure
_eb_fire() {
    local i="$1"
    local rid="${_EB_RX_ID[$i]}" conc="${_EB_RX_CONC[$i]}" tmo="${_EB_RX_TMO[$i]}"
    _eb_rx_channel "$rid" "$conc" || return 2
    ipc_flow_acquire "$_EB_RX_CID" 0 || return 1

    local now_ts="${EPOCHSECONDS}"
    printf '%s\n' "$now_ts" > "$EVENT_BUS_COOLDOWNS_DIR/${rid}.ts" 2>/dev/null || true

    local payload_env="$_EV_PAYLOAD" payload_file=""
    local plen
    _ipc_blen plen "$payload_env"
    if [ "$plen" -gt 100000 ]; then
        # Avoid E2BIG on exec: hand very large payloads over by file
        payload_file="$_EB_PAYLOADS/rx_${_EV_ID}_${rid}.json"
        printf '%s' "$payload_env" > "$payload_file"
        payload_env=$(jq -nc --arg f "$payload_file" --argjson b "$plen" '{__payload_file__: $f, bytes: $b}')
    fi

    local next_depth=$((_EV_DEPTH + 1))
    local prom
    prom=$(
        export EVENT_ID="$_EV_ID" EVENT_TYPE="$_EV_TYPE" EVENT_SOURCE="$_EV_SRC" EVENT_DEPTH="$next_depth"
        export EVENT_PAYLOAD="$payload_env" EVENT_PAYLOAD_FILE="$payload_file" EVENT_TIMESTAMP="$_EV_TS"
        export REACTOR_ID="$rid" REACTOR_ACTION="${_EB_RX_ACT[$i]}" EVENT_BUS_LOG
        ipc_async "$_EB_RX_CID" "_eb_run_reaction"
    )
    if [ -z "$prom" ]; then
        _ipc_with_lock "$FIFO_IPC_DIR/channels/$_EB_RX_CID/state.lock" _ipc_state_add_credits "$FIFO_IPC_DIR/channels/$_EB_RX_CID/state.json" 1
        return 2
    fi
    _EB_INFLIGHT["$prom"]="${rid}|${now_ts}|${tmo}"
    _EB_REACTIONS=$(( ${_EB_REACTIONS:-0} + 1 ))
    _EB_LAST_RX_TS="$now_ts"
    _eb_log "REACTION" "Firing reactor '$rid' on event '$_EV_TYPE' (id: $_EV_ID, promise: $prom, depth: $next_depth)"
    return 0
}

# Parks an event for a reactor according to its overflow policy.
_eb_park() {
    local i="$1" env="$2" why="$3"
    local rid="${_EB_RX_ID[$i]}" ovf="${_EB_RX_OVF[$i]}"
    local pdir="$_EB_PENDING/${rid//[^A-Za-z0-9_.-]/_}"
    case "$ovf" in
        coalesce)
            mkdir -p "$pdir" 2>/dev/null
            rm -f "$pdir"/*.env 2>/dev/null
            printf '%s\n' "$env" > "$pdir/latest.env.tmp" && mv -f "$pdir/latest.env.tmp" "$pdir/0000000000000000_latest.env"
            _eb_log "COALESCED" "Reactor '$rid' $why; kept newest event $_EV_ID for trailing-edge fire"
            ;;
        queue)
            mkdir -p "$pdir" 2>/dev/null
            local -a pq=("$pdir"/*.env)
            local n=0; [ -e "${pq[0]}" ] && n=${#pq[@]}
            if [ "$n" -ge "$EVENT_BUS_PENDING_MAX" ]; then
                _eb_log "QUEUE_FULL" "Reactor '$rid' pending queue full ($n); dropping event $_EV_ID"
                return 1
            fi
            local qf
            printf -v qf '%s/%s_%05d.env' "$pdir" "${EPOCHREALTIME//[.,]/}" "$RANDOM"
            printf '%s\n' "$env" > "${qf}.tmp" && mv -f "${qf}.tmp" "$qf"
            _eb_log "QUEUED" "Reactor '$rid' $why; queued event $_EV_ID (depth $((n + 1)))"
            ;;
        *)
            if [ "$why" = "debounced" ]; then
                _eb_log "DEBOUNCE" "Reactor '$rid' suppressed (cooldown ${_EB_RX_DEB[$i]}s)"
            else
                _eb_log "BACKPRESSURE" "Reactor '$rid' saturated (max_concurrency ${_EB_RX_CONC[$i]}); dropped event $_EV_ID"
            fi
            local q_id q_type q_rid q_act
            _eb_sqv q_id "$_EV_ID"; _eb_sqv q_type "$_EV_TYPE"; _eb_sqv q_rid "$rid"; _eb_sqv q_act "${_EB_RX_ACT[$i]}"
            _eb_sql "INSERT INTO reactions (event_id, event_type, reactor_id, action_cmd, status, exit_code, duration_ms, output_snippet, fired_at) VALUES ($q_id, $q_type, $q_rid, $q_act, 'DEBOUNCED', 0, 0, '$why', ${EPOCHSECONDS});"
            ;;
    esac
    return 0
}

# Returns 0 if reactor index $1 is within its debounce cooldown.
_eb_in_cooldown() {
    local i="$1" deb="${_EB_RX_DEB[$1]}" last=0
    [[ "$deb" =~ ^[0-9]+$ ]] || deb=0
    [ "$deb" -le 0 ] && return 1
    local cd_file="$EVENT_BUS_COOLDOWNS_DIR/${_EB_RX_ID[$i]}.ts"
    [ -f "$cd_file" ] || return 1
    last=$(< "$cd_file") 2>/dev/null
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    [ $(( EPOCHSECONDS - last )) -lt "$deb" ]
}

# ── Single Event Evaluation & Dispatch ───────────────────────────────
event_bus_dispatch_single() {
    local envelope="$1"
    [ -z "$envelope" ] && return 0
    event_bus_init
    declare -p _EB_INFLIGHT &>/dev/null || declare -gA _EB_INFLIGHT=()

    _EV_SPILL_FILE=""
    _eb_parse_envelope "$envelope" || return 0
    [ -n "$_EV_SPILL_FILE" ] && rm -f "$_EV_SPILL_FILE" 2>/dev/null

    local q_id q_type q_src q_pl
    _eb_sqv q_id "$_EV_ID"; _eb_sqv q_type "$_EV_TYPE"; _eb_sqv q_src "$_EV_SRC"; _eb_sqv q_pl "$_EV_PAYLOAD"

    # 0. Global Event Store Persistence
    [ -n "$_EV_ID" ] && _eb_sql "INSERT INTO events (event_id, event_type, source, depth, payload, timestamp, created_at) VALUES ($q_id, $q_type, $q_src, $_EV_DEPTH, $q_pl, $_EV_TS, ${EPOCHSECONDS}) ON CONFLICT(event_id) DO NOTHING;"

    # 1. Circuit Breaker: bound cascading recursion
    if [ "$_EV_DEPTH" -ge "$EVENT_BUS_MAX_DEPTH" ]; then
        _eb_log "CIRCUIT_BREAKER" "Event '$_EV_ID' ($_EV_TYPE) depth $_EV_DEPTH >= max $EVENT_BUS_MAX_DEPTH. Halting cascade."
        _eb_sql "INSERT INTO reactions (event_id, event_type, reactor_id, action_cmd, status, exit_code, duration_ms, output_snippet, fired_at) VALUES ($q_id, $q_type, 'circuit_breaker', 'halt', 'CIRCUIT_BREAKER', 1, 0, 'Max depth exceeded', ${EPOCHSECONDS});"
        return 0
    fi

    _EB_EVENTS=$(( ${_EB_EVENTS:-0} + 1 ))
    _EB_LAST_EVT_TS="${EPOCHSECONDS}"

    # 1b. Mesh Broadcast: publish envelope to MQTT topic george/events/<event_type> for remote sentinel nodes
    if [ "${EVENT_BUS_MQTT_BRIDGE:-1}" = "1" ] && [ -z "${GEORGE_TEST_SANDBOX:-}" ] && command -v mosquitto_pub &>/dev/null; then
        local _mb_host="127.0.0.1" _mb_port="${MQTT_PORT:-1883}"
        if [[ "${MQTT_BROKER:-}" == *:* ]]; then
            _mb_host="${MQTT_BROKER%:*}"
            _mb_port="${MQTT_BROKER##*:}"
        elif [ -n "${MQTT_BROKER:-}" ]; then
            _mb_host="$MQTT_BROKER"
        fi
        [ -z "$_mb_host" ] && _mb_host="127.0.0.1"
        [[ "$_mb_port" =~ ^[0-9]+$ ]] || _mb_port="1883"
        ( mosquitto_pub -h "$_mb_host" -p "$_mb_port" -t "george/events/${_EV_TYPE}" -m "$envelope" >/dev/null 2>&1 ) &
        disown $! 2>/dev/null || true
    fi

    # 2. Match reactors (cached, zero-fork)
    _eb_reactors_load
    local i n="${#_EB_RX_ID[@]}" r_type r_pat
    for (( i = 0; i < n; i++ )); do
        r_type="${_EB_RX_TYPE[$i]}"
        # shellcheck disable=SC2254
        case "$_EV_TYPE" in
            $r_type) ;;
            *) continue ;;
        esac
        r_pat="${_EB_RX_PAT[$i]}"
        if [ -n "$r_pat" ] && [ "$r_pat" != "*" ] && [ "$r_pat" != ".*" ]; then
            [[ "$_EV_PAYLOAD" =~ $r_pat ]] || continue
        fi

        # Preserve ordering: if events are already pending for this reactor, join the line
        local pdir="$_EB_PENDING/${_EB_RX_ID[$i]//[^A-Za-z0-9_.-]/_}"
        local -a pend=("$pdir"/*.env)
        if [ -e "${pend[0]}" ] && [ "${_EB_RX_OVF[$i]}" != "drop" ]; then
            _eb_park "$i" "$envelope" "backlogged"
            continue
        fi

        if _eb_in_cooldown "$i"; then
            _eb_park "$i" "$envelope" "debounced"
            continue
        fi

        _eb_fire "$i"
        case $? in
            0) ;;
            1) _eb_park "$i" "$envelope" "saturated" ;;
            *) _eb_log "REACTION_FAIL" "Reactor '${_EB_RX_ID[$i]}' failed to launch for event $_EV_ID" ;;
        esac
    done

    [ "${_EB_DAEMON:-0}" = "1" ] || _eb_stats_write
    return 0
}

# ── Daemon Tick: reap, retry pending, flush, persist stats ───────────
_eb_reap() {
    local prom meta rid start tmo pf raw st pid
    for prom in "${!_EB_INFLIGHT[@]}"; do
        meta="${_EB_INFLIGHT[$prom]}"
        rid="${meta%%|*}"; meta="${meta#*|}"
        start="${meta%%|*}"; tmo="${meta#*|}"
        pf="$FIFO_IPC_DIR/promises/${prom}.json"
        raw=""
        [ -f "$pf" ] && raw=$(< "$pf")
        _ipc_jget_raw st "$raw" status MISSING
        _ipc_jget_raw pid "$raw" pid 0
        case "$st" in
            RESOLVED|REJECTED|CANCELED|MISSING)
                ;;
            *)
                if [ $(( EPOCHSECONDS - start )) -ge "$tmo" ]; then
                    _eb_log "REACTION_TIMEOUT" "Reactor '$rid' promise $prom exceeded ${tmo}s; cancelling process group"
                    ipc_cancel "$prom" TERM >/dev/null 2>&1
                elif [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && ! kill -0 "$pid" 2>/dev/null; then
                    _ipc_with_lock "$FIFO_IPC_DIR/promises/${prom}.lock" _ipc_prom_finalize "$pf" REJECTED 137
                else
                    continue
                fi
                ;;
        esac
        _eb_release "$rid" "$prom"
        rm -rf "$FIFO_IPC_DIR/promises/${prom}".{json,out,lock,rel} 2>/dev/null
        unset "_EB_INFLIGHT[$prom]"
    done
}

_eb_process_pending() {
    _eb_paths
    local -a dirs=("$_EB_PENDING"/*/)
    [ -e "${dirs[0]}" ] || return 0
    _eb_reactors_load
    local d rid i idx n="${#_EB_RX_ID[@]}" ef env
    for d in "${dirs[@]}"; do
        d="${d%/}"; rid="${d##*/}"
        idx=-1
        for (( i = 0; i < n; i++ )); do
            [ "${_EB_RX_ID[$i]//[^A-Za-z0-9_.-]/_}" = "$rid" ] && { idx=$i; break; }
        done
        if [ "$idx" -lt 0 ]; then
            # Reactor removed/disabled: discard its backlog
            rm -rf "$d" 2>/dev/null
            continue
        fi
        while :; do
            local -a pq=("$d"/*.env)
            [ -e "${pq[0]}" ] || break
            _eb_in_cooldown "$idx" && break
            ef="${pq[0]}"
            env=$(< "$ef")
            if ! _eb_parse_envelope "$env"; then rm -f "$ef"; continue; fi
            _eb_fire "$idx"
            case $? in
                0) rm -f "$ef" ;;
                1) break ;;
                *) rm -f "$ef"; break ;;
            esac
            # Respect debounce between queued fires
            [ "${_EB_RX_DEB[$idx]:-0}" -gt 0 ] 2>/dev/null && break
        done
        rmdir "$d" 2>/dev/null || true
    done
}

_eb_replay_spool() {
    _eb_paths
    [ -s "$_EB_SPOOL" ] || return 0
    local work="${_EB_SPOOL}.replay.${BASHPID}"
    mv -f "$_EB_SPOOL" "$work" 2>/dev/null || return 0
    local line cnt=0
    while IFS= read -r line; do
        [ -n "$line" ] && event_bus_dispatch_single "$line" && cnt=$((cnt + 1))
    done < "$work"
    rm -f "$work" 2>/dev/null
    [ "$cnt" -gt 0 ] && _eb_log "REPLAY" "Replayed $cnt spooled event(s)"
}

_eb_stats_write() {
    _eb_paths
    local tmp="${_EB_STATS}.tmp.${BASHPID}"
    local base_e=0 base_r=0 raw=""
    if [ "${_EB_DAEMON:-0}" != "1" ]; then
        # One-shot dispatch: accumulate into the persisted totals
        [ -f "$_EB_STATS" ] && raw=$(< "$_EB_STATS")
        _ipc_jget_raw base_e "$raw" events_total 0
        _ipc_jget_raw base_r "$raw" reactions_fired 0
    else
        base_e="${_EB_BASE_EVENTS:-0}"; base_r="${_EB_BASE_REACTIONS:-0}"
    fi
    printf '{"events_total":%d,"reactions_fired":%d,"last_event_ts":%d,"last_reaction_ts":%d,"inflight":%d,"daemon_pid":%d,"updated_at":%d}\n' \
        $(( base_e + ${_EB_EVENTS:-0} )) $(( base_r + ${_EB_REACTIONS:-0} )) "${_EB_LAST_EVT_TS:-0}" "${_EB_LAST_RX_TS:-0}" \
        "${#_EB_INFLIGHT[@]}" "${_EB_DAEMON_PID:-0}" "${EPOCHSECONDS}" > "$tmp" 2>/dev/null && mv -f "$tmp" "$_EB_STATS"
    if [ "${_EB_DAEMON:-0}" != "1" ]; then _EB_EVENTS=0; _EB_REACTIONS=0; fi
}

_eb_rotate_log() {
    local sz
    sz=$(stat -c %s "$EVENT_BUS_LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$EVENT_BUS_LOG_MAX_BYTES" ]; then
        mv -f "$EVENT_BUS_LOG" "${EVENT_BUS_LOG}.1" 2>/dev/null
        _eb_log "LOG_ROTATE" "Rotated event bus log ($sz bytes)"
    fi
}

_eb_tick() {
    _eb_reap
    _eb_process_pending
    _eb_replay_spool
    _eb_sql_flush
    _EB_TICKS=$(( ${_EB_TICKS:-0} + 1 ))
    [ $(( _EB_TICKS % 5 )) -eq 0 ] && _eb_stats_write
    [ $(( _EB_TICKS % 60 )) -eq 0 ] && _eb_rotate_log
}

# ── Dispatcher Daemon Loop ───────────────────────────────────────────
event_bus_dispatch_loop() {
    event_bus_init
    _EB_DAEMON=1
    _EB_DAEMON_PID="${BASHPID}"
    declare -gA _EB_INFLIGHT=()
    _EB_EVENTS=0; _EB_REACTIONS=0; _EB_TICKS=0; _EB_SQL_BUF=""; _EB_SQL_N=0

    # Continue cumulative stats across restarts
    local raw=""
    [ -f "$_EB_STATS" ] && raw=$(< "$_EB_STATS")
    _ipc_jget_raw _EB_BASE_EVENTS "$raw" events_total 0
    _ipc_jget_raw _EB_BASE_REACTIONS "$raw" reactions_fired 0
    [ "$_EB_BASE_EVENTS" = "0" ] && _EB_BASE_EVENTS=$(jq '.stats.events_total // 0' "$EVENT_BUS_REACTORS" 2>/dev/null || echo 0)
    [ "$_EB_BASE_REACTIONS" = "0" ] && _EB_BASE_REACTIONS=$(jq '.stats.reactions_fired // 0' "$EVENT_BUS_REACTORS" 2>/dev/null || echo 0)

    _eb_log "DAEMON_START" "Sovereign Reactive Event Bus daemon online (PID: $BASHPID)"

    # Hold the FIFO open read+write so writers never see EOF/ENXIO
    exec 3<>"$EVENT_BUS_FIFO"

    trap '_eb_sql_flush; _eb_stats_write; exec 3>&-; rm -f "$EVENT_BUS_PID_FILE" "$EVENT_BUS_DIR/.reactors.stamp.$BASHPID"; _eb_log "DAEMON_STOP" "Event Bus daemon terminated"; exit 0' SIGTERM SIGINT SIGHUP

    _eb_replay_spool

    local line="" part="" last_tick=0 rc
    while [ -p "$EVENT_BUS_FIFO" ]; do
        part=""
        IFS= read -r -t "$EVENT_BUS_TICK" -u 3 part
        rc=$?
        if [ "$rc" -eq 0 ]; then
            line+="$part"
            [ -n "$line" ] && event_bus_dispatch_single "$line"
            line=""
        elif [ "$rc" -gt 128 ] && [ -n "$part" ]; then
            line+="$part"   # partial line on timeout: keep accumulating
        fi
        if [ "${EPOCHSECONDS}" != "$last_tick" ]; then
            last_tick="${EPOCHSECONDS}"
            _eb_tick
        fi
    done

    _eb_sql_flush
    _eb_stats_write
    exec 3>&-
    rm -f "$EVENT_BUS_PID_FILE" 2>/dev/null || true
}

# ── Daemon Lifecycle Management ──────────────────────────────────────

# Usage: event_bus_start
event_bus_start() {
    event_bus_init

    if event_bus_is_running; then
        local pid
        pid=$(< "$EVENT_BUS_PID_FILE")
        declare -f ui_info &>/dev/null && ui_info "Reactive Event Bus is already active (PID: $pid)"
        return 0
    fi

    (
        exec -a "george-event-bus" bash -c '
            source "$1/event_bus.sh"
            event_bus_dispatch_loop
        ' _ "$_EB_LIB_DIR"
    ) </dev/null >> "$EVENT_BUS_LOG" 2>&1 &
    local new_pid=$!
    disown "$new_pid" 2>/dev/null || true

    echo "$new_pid" > "$EVENT_BUS_PID_FILE"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        grep -q "DAEMON_START.*PID: $new_pid" "$EVENT_BUS_LOG" 2>/dev/null && break
        _ipc_sleep 0.05
    done

    if kill -0 "$new_pid" 2>/dev/null; then
        declare -f ui_ok &>/dev/null && ui_ok "Reactive Event Bus started (PID: $new_pid)"
        return 0
    else
        declare -f ui_err &>/dev/null && ui_err "Failed to start Reactive Event Bus daemon"
        return 1
    fi
}

# Usage: event_bus_stop
event_bus_stop() {
    if [ ! -f "$EVENT_BUS_PID_FILE" ]; then
        declare -f ui_info &>/dev/null && ui_info "Reactive Event Bus is not running"
        return 0
    fi

    local pid
    pid=$(cat "$EVENT_BUS_PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$pid" 2>/dev/null || true
        declare -f ui_ok &>/dev/null && ui_ok "Reactive Event Bus stopped (PID: $pid)"
    fi

    rm -f "$EVENT_BUS_PID_FILE" 2>/dev/null || true
    return 0
}

# Usage: event_bus_status
event_bus_status() {
    event_bus_init

    local pid=""
    local alive=0
    if event_bus_is_running; then
        pid=$(< "$EVENT_BUS_PID_FILE")
        alive=1
    fi

    local num_reactors evts_total=0 rxns_total=0 last_evt=0 inflight=0 raw=""
    num_reactors=$(jq '.reactors | length' "$EVENT_BUS_REACTORS" 2>/dev/null || echo 0)
    if [ -f "$_EB_STATS" ]; then
        raw=$(< "$_EB_STATS")
        _ipc_jget_raw evts_total "$raw" events_total 0
        _ipc_jget_raw rxns_total "$raw" reactions_fired 0
        _ipc_jget_raw last_evt "$raw" last_event_ts 0
        _ipc_jget_raw inflight "$raw" inflight 0
    else
        evts_total=$(jq '.stats.events_total // 0' "$EVENT_BUS_REACTORS" 2>/dev/null || echo 0)
        rxns_total=$(jq '.stats.reactions_fired // 0' "$EVENT_BUS_REACTORS" 2>/dev/null || echo 0)
        last_evt=$(jq '.stats.last_event_ts // 0' "$EVENT_BUS_REACTORS" 2>/dev/null || echo 0)
    fi
    local spooled=0
    [ -f "$_EB_SPOOL" ] && spooled=$(wc -l < "$_EB_SPOOL" 2>/dev/null || echo 0)

    echo "EVENT_BUS_PID=$pid"
    echo "EVENT_BUS_ALIVE=$alive"
    echo "EVENT_BUS_REACTORS_COUNT=$num_reactors"
    echo "EVENT_BUS_EVENTS_TOTAL=$evts_total"
    echo "EVENT_BUS_REACTIONS_TOTAL=$rxns_total"
    echo "EVENT_BUS_LAST_EVENT_TS=$last_evt"
    echo "EVENT_BUS_INFLIGHT=$inflight"
    echo "EVENT_BUS_SPOOLED=$spooled"
    echo "EVENT_BUS_FIFO=$EVENT_BUS_FIFO"
}

# ── Extensible Filesystem Watcher ────────────────────────────────────
# Usage: event_bus_watch_fs <directory> <event_type> [pattern]
event_bus_watch_fs() {
    local dir="$1"
    local evt_type="${2:-file_changed}"
    local pat="${3:-.*}"

    [ ! -d "$dir" ] && return 1

    if command -v inotifywait &>/dev/null; then
        (
            inotifywait -m -r -e modify,create,delete --format '%w%f' "$dir" 2>/dev/null | while read -r changed_file; do
                if [[ "$changed_file" =~ $pat ]]; then
                    event_bus_emit "$evt_type" "$(jq -nc --arg p "$changed_file" '{path: $p}')" "inotifywait"
                fi
            done
        ) </dev/null >/dev/null 2>&1 &
        local watcher_pid=$!
        echo "$watcher_pid" > "$EVENT_BUS_DIR/watcher_fs.pid"
    fi
}

# ── Namespace Aliases ────────────────────────────────────────────────
event_bus_reactor_add() { reactor_add "$@"; }
event_bus_reactor_remove() { reactor_remove "$@"; }
event_bus_reactor_list() { reactor_list "$@"; }
event_bus_reactor_toggle() { reactor_toggle "$@"; }
event_bus_reactor_set() { reactor_set "$@"; }

# ── Event Bus Garbage Collection & Reclamation ───────────────────────
event_bus_gc() {
    local force=0
    local dry_run=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1 ;;
            --dry-run) dry_run=1 ;;
        esac
        shift
    done

    _eb_paths
    local now_ts
    now_ts=$(_eb_now)
    local reaped=0

    # 1. Check PID File
    if [ -f "$EVENT_BUS_PID_FILE" ]; then
        local pid
        pid=$(cat "$EVENT_BUS_PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            [ "$dry_run" -eq 0 ] && rm -f "$EVENT_BUS_PID_FILE" 2>/dev/null || true
            reaped=$((reaped + 1))
        fi
    fi

    # 2. Check File Watcher PID
    local w_pid_file="$EVENT_BUS_DIR/watcher_fs.pid"
    if [ -f "$w_pid_file" ]; then
        local w_pid
        w_pid=$(cat "$w_pid_file" 2>/dev/null || true)
        if [ -n "$w_pid" ] && ! kill -0 "$w_pid" 2>/dev/null; then
            [ "$dry_run" -eq 0 ] && rm -f "$w_pid_file" 2>/dev/null || true
            reaped=$((reaped + 1))
        fi
    fi

    # 3. Clean Cooldowns older than 1h (or all on force)
    local cd_files=("$EVENT_BUS_COOLDOWNS_DIR"/*.ts)
    if [ -e "${cd_files[0]}" ]; then
        for cdf in "${cd_files[@]}"; do
            [ -f "$cdf" ] || continue
            local cd_ts
            cd_ts=$(cat "$cdf" 2>/dev/null || echo 0)
            if [ "$force" -eq 1 ] || [ $((now_ts - cd_ts)) -gt 3600 ]; then
                [ "$dry_run" -eq 0 ] && rm -f "$cdf" 2>/dev/null || true
            fi
        done
    fi

    # 4. Stale reactor stamps and spilled payloads (> 1h)
    local st
    for st in "$EVENT_BUS_DIR"/.reactors.stamp.*; do
        [ -f "$st" ] || continue
        kill -0 "${st##*.}" 2>/dev/null || { [ "$dry_run" -eq 0 ] && rm -f "$st"; }
    done
    local pf
    for pf in "$_EB_PAYLOADS"/*.json; do
        [ -f "$pf" ] || continue
        local age=$((now_ts - $(stat -c %Y "$pf" 2>/dev/null || echo "$now_ts")))
        if [ "$age" -gt 3600 ] || [ "$force" -eq 1 ]; then
            [ "$dry_run" -eq 0 ] && rm -f "$pf" 2>/dev/null
        fi
    done

    # NOTE: the event bus lock file is intentionally never unlinked (flock safety).

    # 5. FIFO Validation
    if [ "$force" -eq 1 ]; then
        local live_eb_pid
        live_eb_pid=$(cat "$EVENT_BUS_PID_FILE" 2>/dev/null || true)
        if [ -z "$live_eb_pid" ] || ! kill -0 "$live_eb_pid" 2>/dev/null; then
            [ "$dry_run" -eq 0 ] && rm -f "$EVENT_BUS_FIFO" 2>/dev/null || true
        fi
    fi

    return 0
}
