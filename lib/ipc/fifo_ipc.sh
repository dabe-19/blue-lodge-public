#!/bin/bash
# ── George: Sovereign POSIX FIFO Async/Await & Flow Control Protocol (v3) ───
# Implements high-performance POSIX shell asynchronous IPC:
#   1. Named FIFO channel creation and lifecycle management with atomic locking
#   2. Credit-based flow control and backpressure signaling (CREDIT, PAUSE, RESUME, ACK, ABORT)
#   3. Standard OKF-compliant NDJSON message framing with PIPE_BUF (4096B) atomic guarantees
#   4. Transparent large-payload disk spillover and request-response UUID correlation routing
#   5. Asynchronous execution (ipc_async / fifo_async) returning Promise / Task handles
#   6. Zero-fork fast path in polling loops (Bash 5+ built-in parameter expansion & regex)
#   7. Microsecond non-blocking resolution (ipc_await) with process group reaping on timeout
#   8. Monadic promise pipelining (ipc_pipe) and task cancellation (ipc_cancel)
#   9. Single-pass GAWK protocol garbage collector & reconciliation supervisor
#  10. Native object-oriented / namespaced API (`ipc_*`) with backward-compatible `fifo_*` aliases

[ -n "${_LIB_FIFO_IPC_LOADED:-}" ] && return 0; _LIB_FIFO_IPC_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

# Load Configuration if present. Values act as defaults only: variables already set in
# the environment win, and empty assignments are ignored. Only FIFO_* keys are honoured.
if [ -f "${GEORGE_DIR}/ipc.conf" ]; then
    while IFS='=' read -r _ipc_ck _ipc_cv; do
        [[ "$_ipc_ck" =~ ^FIFO_[A-Z_]+$ ]] || continue
        _ipc_cv="${_ipc_cv%%#*}"; _ipc_cv="${_ipc_cv%"${_ipc_cv##*[![:space:]]}"}"
        _ipc_cv="${_ipc_cv#\"}"; _ipc_cv="${_ipc_cv%\"}"
        [ -z "$_ipc_cv" ] && continue
        [ -n "${!_ipc_ck:-}" ] && continue
        printf -v "$_ipc_ck" '%s' "$_ipc_cv"
    done < "${GEORGE_DIR}/ipc.conf"
    unset _ipc_ck _ipc_cv
fi

FIFO_IPC_DIR="${FIFO_IPC_DIR:-${GEORGE_DIR}/ipc}"
FIFO_DEFAULT_WINDOW="${FIFO_DEFAULT_WINDOW:-5}"
# Frames whose serialized size exceeds FIFO_SPILL_BYTES have their payload spilled to
# disk so every write(2) on a FIFO stays strictly below PIPE_BUF (4096B) => atomic.
FIFO_SPILL_BYTES="${FIFO_SPILL_BYTES:-3800}"
# Hard cap on a single logical payload. Only payloads above this are truncated.
FIFO_MAX_PAYLOAD_BYTES="${FIFO_MAX_PAYLOAD_BYTES:-67108864}"
# Linux pipe buffer capacity; used to guard against unbounded blocking writes.
FIFO_PIPE_CAPACITY="${FIFO_PIPE_CAPACITY:-65536}"
# Credit auto-recovery is OFF by default: a timeout must never silently bypass
# backpressure. When enabled it only fires if no live consumer and no PAUSE.
FIFO_AUTO_RECOVER="${FIFO_AUTO_RECOVER:-0}"
FIFO_AUTO_RECOVER_TIMEOUT="${FIFO_AUTO_RECOVER_TIMEOUT:-5}"
FIFO_POLL_INTERVAL="${FIFO_POLL_INTERVAL:-0.05}"
FIFO_LOCK_TIMEOUT="${FIFO_LOCK_TIMEOUT:-2}"
FIFO_GC_MAX_IDLE="${FIFO_GC_MAX_IDLE:-300}"
FIFO_GC_PROMISE_TTL="${FIFO_GC_PROMISE_TTL:-1800}"
FIFO_GC_WEDGE_SECS="${FIFO_GC_WEDGE_SECS:-15}"
FIFO_GC_ORPHAN_SECS="${FIFO_GC_ORPHAN_SECS:-21600}"
FIFO_QUEUE_MAX="${FIFO_QUEUE_MAX:-10000}"

# ── Standard Protocol Exit Codes & Errno Mapping ────────────────────
readonly IPC_OK=0                   # Operation completed successfully
readonly IPC_ERR_GENERIC=1          # Generic internal IPC failure
readonly IPC_ERR_NOTFOUND=2         # Channel or Promise not found (ENOENT)
readonly IPC_ERR_PERMISSION=13      # Lock or permission denied (EACCES)
readonly IPC_ERR_BUSY=16            # Resource locked / contention (EBUSY)
readonly IPC_ERR_INVALID=22         # Invalid argument or frame schema (EINVAL)
readonly IPC_ERR_PIPE=32            # Broken named pipe or closed reader (EPIPE)
readonly IPC_ERR_TIMEOUT=110        # Credit flow control timed out (ETIMEDOUT)
readonly IPC_ERR_AWAIT_TIMEOUT=124  # Promise await barrier timed out
readonly IPC_ERR_CANCELED=125       # Task explicitly canceled by operator/agent
readonly IPC_ERR_CRASH=137          # Process terminated prematurely (SIGKILL/OOM)
readonly IPC_QUEUED=75              # Frame accepted into durable spill queue, NOT yet delivered (EAGAIN-like)

# ── Protocol Priority Constants ─────────────────────────────────────
readonly IPC_PRIO_INTERACTIVE=100   # User typing in REPL, direct prompt
readonly IPC_PRIO_TRADE=90         # High-priority timed trades, arbitrage, and order dispatches
readonly IPC_PRIO_SYSTEM=80         # Health checks, sentinel alerts
readonly IPC_PRIO_CRON=50           # Scheduled background tasks
readonly IPC_PRIO_REMEDIATION=20    # Autonomous code remediation

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

# ── Helper: High-Speed Timestamp & UUID Generation ──────────────────
_ipc_now() {
    echo "${EPOCHSECONDS:-$(date +%s)}"
}

_ipc_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        printf '%04x%04x-%04x-%04x-%04x-%04x%04x%04x\n' \
            $RANDOM $RANDOM $RANDOM \
            $((RANDOM & 0x0fff | 0x4000)) \
            $((RANDOM & 0x3fff | 0x8000)) \
            $RANDOM $RANDOM $RANDOM
    fi
}

# ── Helper: Logging & Diagnostics ────────────────────────────────────
ipc_log() {
    local level="${1:-INFO}"
    local cid="${2:-system}"
    local msg="${3:-}"
    local log_file="$FIFO_IPC_DIR/ipc.log"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || _ipc_now)
    printf "[%s] [%s] [chan:%s] [pid:%s] %s\n" "$ts" "$level" "$cid" "$$" "$msg" >> "$log_file" 2>/dev/null || true
}
fifo_log() { ipc_log "$@"; }

# ── Helper: Atomic File / Directory Lock ─────────────────────────────
# Runs "$@" while holding an exclusive lock. Always executes in a subshell so the
# fallback path never clobbers the caller's traps. Lock files are NEVER unlinked
# while their owning channel exists (unlinking a flock file breaks mutual exclusion).
_ipc_with_lock() {
    local lockfile="$1"
    shift
    if command -v flock &>/dev/null; then
        (
            flock -x -w "$FIFO_LOCK_TIMEOUT" 200 || exit $IPC_ERR_BUSY
            "$@"
        ) 200>>"$lockfile"
    else
        (
            local lockdir="${lockfile}.d" tries=0
            while ! mkdir "$lockdir" 2>/dev/null; do
                tries=$((tries + 1))
                [ "$tries" -gt 40 ] && exit $IPC_ERR_BUSY
                sleep 0.05
            done
            trap 'rmdir "$lockdir" 2>/dev/null' EXIT
            "$@"
        )
    fi
}

# Byte length of a string (locale-independent) into a named variable.
_ipc_blen() { local LC_ALL=C; printf -v "$1" '%d' "${#2}"; }

# Zero-jq atomic JSON patcher for top-level scalar keys.
# Usage: _ipc_state_patch <file> key=<json-literal> [key=<json-literal> ...]
# Existing keys are rewritten in-place (pure Bash); missing keys fall back to jq.
# Writes via tmp+rename so lock-free readers never observe a torn file.
_ipc_state_patch() {
    local sf="$1"; shift
    local raw=""
    [ -f "$sf" ] && raw=$(< "$sf")
    [ -z "$raw" ] && return 1
    local kv k v whole pre
    local -a missing=()
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        if [[ "$raw" =~ (\"$k\":[[:space:]]*)(-?[0-9]+|true|false|null|\"[^\"]*\") ]]; then
            whole="${BASH_REMATCH[0]}"; pre="${BASH_REMATCH[1]}"
            raw="${raw/"$whole"/"$pre$v"}"
        else
            missing+=("$k" "$v")
        fi
    done
    local tmp="${sf}.tmp.${BASHPID}_${RANDOM}"
    if [ "${#missing[@]}" -gt 0 ]; then
        local filt="." i=0
        local -a jargs=()
        while [ "$i" -lt "${#missing[@]}" ]; do
            filt+=" | .${missing[i]} = \$v$i"
            jargs+=(--argjson "v$i" "${missing[i+1]}")
            i=$((i + 2))
        done
        printf '%s' "$raw" | jq "${jargs[@]}" "$filt" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    else
        printf '%s\n' "$raw" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    mv -f "$tmp" "$sf" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Reads a top-level scalar from a JSON file into a named variable (zero-fork).
# Usage: _ipc_jget <var> <file_or_raw_var_content> <key> [default]
_ipc_jget_raw() {
    local __out="$1" __raw="$2" __k="$3" __def="${4:-}"
    if [[ "$__raw" =~ \"$__k\":[[:space:]]*\"([^\"]*)\" ]]; then
        printf -v "$__out" '%s' "${BASH_REMATCH[1]}"
    elif [[ "$__raw" =~ \"$__k\":[[:space:]]*(-?[0-9]+|true|false|null) ]]; then
        printf -v "$__out" '%s' "${BASH_REMATCH[1]}"
    else
        printf -v "$__out" '%s' "$__def"
    fi
}

# ── Helper: Atomic State Mutators (all callers hold the channel lock) ──
_ipc_state_add_credits() {
    local sf="$1" amt="$2" raw="" cur win
    [ -f "$sf" ] && raw=$(< "$sf")
    _ipc_jget_raw cur "$raw" credits 0
    _ipc_jget_raw win "$raw" window_size 5
    local nxt=$((cur + amt))
    [ "$nxt" -gt "$win" ] && nxt="$win"
    [ "$nxt" -lt 0 ] && nxt=0
    _ipc_state_patch "$sf" "credits=$nxt" "last_activity=$(_ipc_now)"
}

_ipc_decrement_credit() {
    local sf="$1" raw="" cur bp
    [ -f "$sf" ] && raw=$(< "$sf")
    _ipc_jget_raw cur "$raw" credits 0
    _ipc_jget_raw bp "$raw" backpressure false
    # Re-validated under the lock: never go below zero, never bypass PAUSE.
    [ "$cur" -le 0 ] && return 1
    [ "$bp" = "true" ] && return 1
    _ipc_state_patch "$sf" "credits=$((cur - 1))" "last_activity=$(_ipc_now)"
}

_ipc_state_set_backpressure() {
    local sf="$1" bp_val="$2" by="${3:-0}"
    _ipc_state_patch "$sf" "backpressure=$bp_val" "paused_by=$by" "last_activity=$(_ipc_now)"
}

_ipc_state_reset_credits() {
    local sf="$1" win="$2"
    _ipc_state_patch "$sf" "credits=$win" "backpressure=false" "paused_by=0" "last_activity=$(_ipc_now)"
}

_ipc_increment_seq_in() {
    local sf="$1" consumer="${2:-0}" raw="" cur
    [ -f "$sf" ] && raw=$(< "$sf")
    _ipc_jget_raw cur "$raw" seq_in 0
    _ipc_state_patch "$sf" "seq_in=$((cur + 1))" "consumer_pid=$consumer" "last_activity=$(_ipc_now)"
}

# Returns 0 if the channel's registered consumer process is alive.
_ipc_consumer_alive() {
    local raw="$1" cpid
    _ipc_jget_raw cpid "$raw" consumer_pid 0
    [ "$cpid" -gt 0 ] 2>/dev/null && kill -0 "$cpid" 2>/dev/null
}

# Verifies a PID really is this channel's keeper (guards against PID reuse).
_ipc_is_keeper() {
    local pid="$1" cid="$2" arg0=""
    [ -r "/proc/$pid/cmdline" ] || return 1
    IFS= read -r -d '' arg0 < "/proc/$pid/cmdline" 2>/dev/null
    [ "$arg0" = "george-keeper-$cid" ]
}

# Kills an async worker and its whole job process group.
_ipc_kill_tree() {
    local pid="${1:-0}" pgid="${2:-0}" sig="${3:-TERM}"
    sig="${sig#SIG}"
    if [ "$pgid" -gt 1 ] 2>/dev/null; then
        kill -s "$sig" -- "-$pgid" 2>/dev/null || true
    fi
    if [ "$pid" -gt 1 ] 2>/dev/null; then
        pkill -"$sig" -P "$pid" 2>/dev/null || true
        kill -s "$sig" "$pid" 2>/dev/null || true
    fi
}

# ── Initialization ───────────────────────────────────────────────────
ipc_init() {
    local base="${1:-$FIFO_IPC_DIR}"
    FIFO_IPC_DIR="$base"
    mkdir -p "$FIFO_IPC_DIR/channels" \
             "$FIFO_IPC_DIR/promises" \
             "$FIFO_IPC_DIR/payloads" \
             "$FIFO_IPC_DIR/locks" 2>/dev/null || true
}
fifo_ipc_init() { ipc_init "$@"; }

# ── 1. Channel Lifecycle ─────────────────────────────────────────────

# Opens a structured FIFO channel:
#   data.fifo + ctrl.fifo + state.json + state.lock + queue/ (credit spill) + mailbox/ (correlation parking)
# Usage: ipc_channel_open <channel_id> [credit_window] [max_idle] [priority] [mode]
#   mode = stream (default): spawns a keeper that pins FIFO buffers between producers/consumers
#   mode = credit          : credit-only semaphore channel (no keeper process, no data plane)
ipc_channel_open() {
    local cid="$1"
    local window="${2:-$FIFO_DEFAULT_WINDOW}"
    local max_idle="${3:-$FIFO_GC_MAX_IDLE}"
    local priority="${4:-$IPC_PRIO_CRON}"
    local mode="${5:-${FIFO_CHANNEL_MODE:-stream}}"
    [ -z "$cid" ] && return $IPC_ERR_INVALID
    case "$cid" in */*|.*) return $IPC_ERR_INVALID ;; esac
    [[ "$window" =~ ^[0-9]+$ ]] || window="$FIFO_DEFAULT_WINDOW"
    [[ "$max_idle" =~ ^[0-9]+$ ]] || max_idle="$FIFO_GC_MAX_IDLE"
    [[ "$priority" =~ ^[0-9]+$ ]] || priority="$IPC_PRIO_CRON"
    [ "$mode" = "credit" ] || mode="stream"

    ipc_init

    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local data_fifo="$cdir/data.fifo"
    local ctrl_fifo="$cdir/ctrl.fifo"
    local state_file="$cdir/state.json"
    local config_file="$cdir/config.json"
    local lock_file="$cdir/state.lock"
    local keeper_file="$cdir/keeper.pid"

    # Re-open of an existing channel id: reap the previous keeper so keepers never leak
    if [ -f "$keeper_file" ]; then
        local old_kp=""
        old_kp=$(< "$keeper_file")
        if [ -n "$old_kp" ] && _ipc_is_keeper "$old_kp" "$cid"; then
            kill -TERM "$old_kp" 2>/dev/null || true
        fi
        rm -f "$keeper_file" 2>/dev/null || true
    fi

    mkdir -p "$cdir/queue" "$cdir/mailbox" 2>/dev/null
    chmod 0700 "$cdir" 2>/dev/null || true

    rm -f "$data_fifo" "$ctrl_fifo" 2>/dev/null || true
    mkfifo -m 0600 "$data_fifo" 2>/dev/null || true
    mkfifo -m 0600 "$ctrl_fifo" 2>/dev/null || true
    : >> "$lock_file"

    local now_ts="${EPOCHSECONDS:-$(_ipc_now)}"
    [[ "$now_ts" =~ ^[0-9]+$ ]] || now_ts=$(date +%s)
    local parent_chan="${GEORGE_PARENT_TASK_ID:-}"
    local my_pid="${BASHPID:-$$}"

    # Write immutable config + live dynamic state in a single jq invocation
    local both
    both=$(jq -nc \
        --arg cid "$cid" \
        --argjson ts "$now_ts" \
        --argjson win "$window" \
        --argjson idle "$max_idle" \
        --argjson prio "$priority" \
        --arg mode "$mode" \
        --arg owner "${GEORGE_AGENT_ID:-${USER:-george}}" \
        --argjson opid "$my_pid" \
        --arg parent "$parent_chan" \
        '[{
            channel_id: $cid, created_at: $ts, window_size: $win, max_idle_secs: $idle,
            priority: $prio, mode: $mode, owner: $owner
         },
         {
            channel_id: $cid,
            parent_channel: (if $parent != "" then $parent else null end),
            created_at: $ts,
            status: "OPEN",
            mode: $mode,
            window_size: $win,
            credits: $win,
            priority: $prio,
            max_idle_secs: $idle,
            backpressure: false,
            paused_by: 0,
            seq_out: 0,
            seq_in: 0,
            keeper_pid: 0,
            owner_pid: $opid,
            consumer_pid: 0,
            last_activity: $ts
         }]') || return $IPC_ERR_GENERIC
    jq '.[0]' <<< "$both" > "$config_file" 2>/dev/null || true
    jq '.[1]' <<< "$both" > "${state_file}.tmp.${my_pid}" 2>/dev/null && mv -f "${state_file}.tmp.${my_pid}" "$state_file"

    local keeper_pid=0
    if [ "$mode" = "stream" ]; then
        # Spawn named background pipe keeper. exec -a sets argv0 for PID-reuse-safe discovery.
        (
            exec 0</dev/null 1>/dev/null 2>/dev/null
            for fd in /proc/${BASHPID:-$$}/fd/*; do
                fd_num="${fd##*/}"
                case "$fd_num" in
                    0|1|2) ;;
                    *) eval "exec ${fd_num}>&-" 2>/dev/null || true ;;
                esac
            done
            exec -a "george-keeper-$cid" bash -c '
                cdir="$1"
                data_fifo="$cdir/data.fifo"
                ctrl_fifo="$cdir/ctrl.fifo"
                state_file="$cdir/state.json"
                ready_file="$cdir/keeper.ready"
                exec 9<> "$data_fifo" 10<> "$ctrl_fifo"
                echo READY > "$ready_file" 2>/dev/null || true
                trap "exec 9>&- 10>&-; exit 0" TERM INT EXIT
                misses=0
                while :; do
                    st_raw=""
                    [ -f "$state_file" ] && st_raw=$(< "$state_file")
                    if [ -z "$st_raw" ]; then
                        misses=$((misses + 1)); [ "$misses" -ge 3 ] && break
                    else
                        misses=0
                        [[ "$st_raw" =~ \"status\":[[:space:]]*\"OPEN\" ]] || break
                    fi
                    sleep 2
                done
                exec 9>&- 10>&-
            ' _ "$cdir"
        ) </dev/null >/dev/null 2>&1 &
        keeper_pid=$!
        disown "$keeper_pid" 2>/dev/null || true
        echo "$keeper_pid" > "$keeper_file" 2>/dev/null || true
        _ipc_with_lock "$lock_file" _ipc_state_patch "$state_file" "keeper_pid=$keeper_pid"

        # Wait for keeper to pin FIFOs open before unblocking callers
        local ready_file="$cdir/keeper.ready" wait_count=0
        while [ ! -f "$ready_file" ] && [ "$wait_count" -lt 100 ]; do
            _ipc_sleep 0.01
            wait_count=$((wait_count + 1))
        done
        rm -f "$ready_file" 2>/dev/null || true
    fi

    ipc_log "INFO" "$cid" "Channel opened (mode=$mode, window=$window, keeper_pid=$keeper_pid)"
    return $IPC_OK
}
fifo_channel_open() { ipc_channel_open "$@"; }

# Closes and cleans up an IPC channel
# Usage: ipc_channel_close <channel_id>
ipc_channel_close() {
    local cid="$1"
    [ -z "$cid" ] && return $IPC_ERR_INVALID
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    [ ! -d "$cdir" ] && return $IPC_OK

    local state_file="$cdir/state.json"
    local keeper_file="$cdir/keeper.pid"
    local lock_file="$cdir/state.lock"

    # 1. Resolve keeper pid (file first, then state)
    local keeper_pid=""
    [ -f "$keeper_file" ] && keeper_pid=$(< "$keeper_file")
    if [ -z "$keeper_pid" ] && [ -f "$state_file" ]; then
        local st_raw
        st_raw=$(< "$state_file")
        _ipc_jget_raw keeper_pid "$st_raw" keeper_pid ""
    fi

    # 2. Mark CLOSED first so waiters and the keeper loop observe it
    [ -f "$state_file" ] && _ipc_with_lock "$lock_file" _ipc_state_patch "$state_file" 'status="CLOSED"' 2>/dev/null

    # 3. Wake blocked acquirers immediately
    if [ -p "$cdir/ctrl.fifo" ]; then
        { printf 'ABORT\n' >&3; } 3<> "$cdir/ctrl.fifo" 2>/dev/null || true
    fi

    # 4. Terminate keeper (only if the PID really is this channel's keeper)
    if [ -n "$keeper_pid" ] && [ "$keeper_pid" -gt 1 ] 2>/dev/null && _ipc_is_keeper "$keeper_pid" "$cid"; then
        kill -TERM "$keeper_pid" 2>/dev/null || kill -9 "$keeper_pid" 2>/dev/null || true
    fi

    # 5. Remove FIFOs, locks, and channel directory
    rm -rf "$cdir" 2>/dev/null || true

    ipc_log "INFO" "$cid" "Channel closed and reclaimed"
    return $IPC_OK
}
fifo_channel_close() { ipc_channel_close "$@"; }

# Checks if a channel exists and is active (Pure Bash Zero-Fork Fast Path)
ipc_channel_is_open() {
    local cid="$1"
    local state_file="$FIFO_IPC_DIR/channels/$cid/state.json"
    [ -n "$cid" ] && [ -f "$state_file" ] || return 1
    local st_raw=""
    st_raw=$(< "$state_file") 2>/dev/null
    [[ "$st_raw" =~ \"status\":[[:space:]]*\"OPEN\" ]]
}
fifo_channel_is_open() { ipc_channel_is_open "$@"; }

# Lists channels with credits, backpressure, queue and mailbox depth (zero-fork)
ipc_channel_list() {
    ipc_init
    local files=("$FIFO_IPC_DIR/channels"/*/state.json)
    [ ! -e "${files[0]}" ] && return $IPC_OK
    local sf raw cid st win cred bp mode cons qd md cdir
    for sf in "${files[@]}"; do
        [ -f "$sf" ] || continue
        raw=$(< "$sf")
        cdir="${sf%/state.json}"
        _ipc_jget_raw cid "$raw" channel_id "${cdir##*/}"
        _ipc_jget_raw st "$raw" status CLOSED
        _ipc_jget_raw win "$raw" window_size 0
        _ipc_jget_raw cred "$raw" credits 0
        _ipc_jget_raw bp "$raw" backpressure false
        _ipc_jget_raw mode "$raw" mode stream
        _ipc_jget_raw cons "$raw" consumer_pid 0
        local -a q=("$cdir/queue"/*.frame) m=("$cdir/mailbox"/*.frame)
        qd=0; [ -e "${q[0]}" ] && qd=${#q[@]}
        md=0; [ -e "${m[0]}" ] && md=${#m[@]}
        printf "%-28s status=%-8s mode=%-6s window=%-4s credits=%-4s backpressure=%-5s queued=%-4s parked=%-4s consumer=%s\n" \
            "$cid" "$st" "$mode" "$win" "$cred" "$bp" "$qd" "$md" "$cons"
    done
}

# Displays dynamic telemetry and queue metrics for a channel
ipc_status() {
    local cid="$1"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local state_file="$cdir/state.json"
    [ ! -f "$state_file" ] && return $IPC_ERR_NOTFOUND
    local -a q=("$cdir/queue"/*.frame) m=("$cdir/mailbox"/*.frame)
    local qd=0 md=0
    [ -e "${q[0]}" ] && qd=${#q[@]}
    [ -e "${m[0]}" ] && md=${#m[@]}
    jq --argjson qd "$qd" --argjson md "$md" '.queue_depth = $qd | .mailbox_depth = $md' "$state_file" 2>/dev/null || cat "$state_file"
}
fifo_status() { ipc_status "$@"; }

# Displays dynamic telemetry for an async promise
ipc_promise_status() {
    local prom_id="$1"
    local prom_file="$FIFO_IPC_DIR/promises/${prom_id}.json"
    [ ! -f "$prom_file" ] && return $IPC_ERR_NOTFOUND
    jq . "$prom_file" 2>/dev/null || cat "$prom_file"
}
fifo_promise_status() { ipc_promise_status "$@"; }

# ── 2. Flow Control Primitives ──────────────────────────────────────

# Acquires one transmission credit. Blocks up to timeout_s (0 = non-blocking try).
# Never bypasses backpressure. Waiting is zero-fork: it blocks on ctrl.fifo, which
# doubles as the wake-up channel (ABORT on close).
# Returns: 0 OK | 2 NOTFOUND | 32 PIPE (closed/aborted) | 110 TIMEOUT
# Usage: ipc_flow_acquire <channel_id> [timeout_s]
ipc_flow_acquire() {
    local cid="$1"
    local timeout="${2:-10}"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local state_file="$cdir/state.json"
    local lock_file="$cdir/state.lock"
    local ctrl_fifo="$cdir/ctrl.fifo"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=10

    [ ! -f "$state_file" ] && return $IPC_ERR_NOTFOUND

    local start_ts="${EPOCHSECONDS:-$(_ipc_now)}"
    local raw st cred bp sig

    while :; do
        raw=""
        [ -f "$state_file" ] && raw=$(< "$state_file")
        if [ -z "$raw" ]; then
            # Torn read is impossible (rename-based writes); empty means channel removed
            [ -d "$cdir" ] || return $IPC_ERR_NOTFOUND
        else
            _ipc_jget_raw st "$raw" status ""
            case "$st" in
                OPEN) ;;
                "") ;;
                *) return $IPC_ERR_PIPE ;;
            esac
            _ipc_jget_raw cred "$raw" credits 0
            _ipc_jget_raw bp "$raw" backpressure false
            if [ "$st" = "OPEN" ] && [ "$cred" -gt 0 ] && [ "$bp" = "false" ]; then
                if _ipc_with_lock "$lock_file" _ipc_decrement_credit "$state_file"; then
                    return $IPC_OK
                fi
                continue   # lost the race for the last credit; re-evaluate immediately
            fi
        fi

        if [ $(( ${EPOCHSECONDS:-$(_ipc_now)} - start_ts )) -ge "$timeout" ]; then
            # Optional, conservative recovery: only when explicitly enabled, never under PAUSE,
            # and only if no live consumer exists to ever return the credits.
            if [ "${FIFO_AUTO_RECOVER:-0}" = "1" ] && [ "$timeout" -ge "${FIFO_AUTO_RECOVER_TIMEOUT:-5}" ] \
               && [ "$bp" = "false" ] && ! _ipc_consumer_alive "$raw"; then
                local win
                _ipc_jget_raw win "$raw" window_size 5
                ipc_log "WARN" "$cid" "Auto-recovering credits (no live consumer) after ${timeout}s"
                _ipc_with_lock "$lock_file" _ipc_state_reset_credits "$state_file" "$win"
                _ipc_with_lock "$lock_file" _ipc_decrement_credit "$state_file" && return $IPC_OK
            fi
            return $IPC_ERR_TIMEOUT
        fi

        if [ -p "$ctrl_fifo" ]; then
            sig=""
            if read -t "$FIFO_POLL_INTERVAL" -r sig <> "$ctrl_fifo" 2>/dev/null; then
                [ "$sig" = "ABORT" ] && return $IPC_ERR_PIPE
            fi
        else
            _ipc_sleep "$FIFO_POLL_INTERVAL"
        fi
    done
}
fifo_flow_acquire() { ipc_flow_acquire "$@"; }

# Consumer grants transmission credit to producer(s), then drains the spill queue
# strictly within the newly available credit.
# Usage: ipc_flow_grant <channel_id> [amount]
ipc_flow_grant() {
    local cid="$1"
    local amount="${2:-1}"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local state_file="$cdir/state.json"
    local lock_file="$cdir/state.lock"
    local ctrl_fifo="$cdir/ctrl.fifo"
    [[ "$amount" =~ ^[0-9]+$ ]] || return $IPC_ERR_INVALID
    [ ! -f "$state_file" ] && return $IPC_ERR_NOTFOUND

    local prev_raw="" prev_cred=0
    prev_raw=$(< "$state_file") 2>/dev/null
    _ipc_jget_raw prev_cred "$prev_raw" credits 0

    _ipc_with_lock "$lock_file" _ipc_state_add_credits "$state_file" "$amount" || return $IPC_ERR_BUSY
    if [ "${prev_cred:-0}" -le 0 ] && [ -p "$ctrl_fifo" ]; then
        { printf 'GRANT\n' >&3; } 3<> "$ctrl_fifo" 2>/dev/null || true
    fi
    ipc_queue_flush "$cid" >/dev/null 2>&1 || true
    return $IPC_OK
}
fifo_flow_grant() { ipc_flow_grant "$@"; }

# Transmits flow control command: PAUSE | RESUME | ABORT | PING | HEARTBEAT | UNSTICK | FLUSH
# state.json is the authoritative control plane; ctrl.fifo only carries wake-ups (ABORT).
# Usage: ipc_flow_send_ctrl <channel_id> <command>
ipc_flow_send_ctrl() {
    local cid="$1"
    local cmd="$2"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local state_file="$cdir/state.json"
    local lock_file="$cdir/state.lock"
    local ctrl_fifo="$cdir/ctrl.fifo"

    [ ! -f "$state_file" ] && return $IPC_ERR_NOTFOUND

    case "$cmd" in
        PAUSE)
            _ipc_with_lock "$lock_file" _ipc_state_set_backpressure "$state_file" "true" "${BASHPID:-$$}"
            ;;
        RESUME)
            _ipc_with_lock "$lock_file" _ipc_state_set_backpressure "$state_file" "false" "0"
            if [ -p "$ctrl_fifo" ]; then
                { printf 'RESUME\n' >&3; } 3<> "$ctrl_fifo" 2>/dev/null || true
            fi
            ipc_queue_flush "$cid" >/dev/null 2>&1 || true
            ;;
        UNSTICK|FLUSH)
            local win raw
            raw=$(< "$state_file")
            _ipc_jget_raw win "$raw" window_size 5
            _ipc_with_lock "$lock_file" _ipc_state_reset_credits "$state_file" "$win"
            if [ -p "$ctrl_fifo" ]; then
                { printf 'UNSTICK\n' >&3; } 3<> "$ctrl_fifo" 2>/dev/null || true
            fi
            ipc_queue_flush "$cid" >/dev/null 2>&1 || true
            ;;
        ABORT)
            _ipc_with_lock "$lock_file" _ipc_state_patch "$state_file" 'status="ABORTED"'
            if [ -p "$ctrl_fifo" ]; then
                { printf 'ABORT\n' >&3; } 3<> "$ctrl_fifo" 2>/dev/null || true
            fi
            ;;
        PING|HEARTBEAT|PONG)
            _ipc_with_lock "$lock_file" _ipc_state_patch "$state_file" "last_activity=${EPOCHSECONDS:-$(_ipc_now)}"
            ;;
        *)
            return $IPC_ERR_INVALID
            ;;
    esac
    return $IPC_OK
}
fifo_flow_send_ctrl() { ipc_flow_send_ctrl "$@"; }

ipc_flow_pause() { ipc_flow_send_ctrl "$1" "PAUSE"; }
fifo_flow_pause() { ipc_flow_pause "$@"; }

ipc_flow_resume() { ipc_flow_send_ctrl "$1" "RESUME"; }
fifo_flow_resume() { ipc_flow_resume "$@"; }

ipc_flow_unstick() { ipc_flow_send_ctrl "$1" "UNSTICK"; }
fifo_flow_unstick() { ipc_flow_unstick "$@"; }

ipc_flow_ping() { ipc_flow_send_ctrl "$1" "PING"; }
fifo_flow_ping() { ipc_flow_ping "$@"; }

# ── 3. Spillover Buffer Queue & Flowcontrol Ingress ──────────────────

# Durably enqueues a frame template (seq 0) when no credit is available.
# File names are microsecond-ordered so lexical glob order == FIFO order.
_ipc_queue_put() {
    local qdir="$1" tmpl="$2"
    mkdir -p "$qdir" 2>/dev/null || return $IPC_ERR_GENERIC
    local -a q=("$qdir"/*.frame)
    local n=0
    [ -e "${q[0]}" ] && n=${#q[@]}
    [ "$n" -ge "$FIFO_QUEUE_MAX" ] && return $IPC_ERR_BUSY
    local qf
    printf -v qf '%s/%s_%07d_%05d.frame' "$qdir" "${EPOCHREALTIME//[.,]/}" "$BASHPID" "$RANDOM"
    printf '%s\n' "$tmpl" > "${qf}.tmp" && mv -f "${qf}.tmp" "$qf"
}

# Flushes credit-spilled frames from queue/ into data.fifo, consuming exactly one
# credit per frame and stopping when credits run out (never bypasses the window).
# Usage: ipc_queue_flush <channel_id>   (prints number of frames flushed)
ipc_queue_flush() {
    local cid="$1"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local qdir="$cdir/queue"
    local data_fifo="$cdir/data.fifo"
    local state_file="$cdir/state.json"
    local lock_file="$cdir/state.lock"

    local -a q=("$qdir"/*.frame)
    if [ ! -e "${q[0]}" ] || [ ! -p "$data_fifo" ]; then
        echo 0
        return $IPC_OK
    fi

    local flushed=0 qf claim tmpl
    for qf in "${q[@]}"; do
        [ -f "$qf" ] || continue
        ipc_flow_acquire "$cid" 0 || break
        claim="${qf}.claim.${BASHPID}"
        if ! mv "$qf" "$claim" 2>/dev/null; then
            # Another flusher claimed it; refund the credit
            _ipc_with_lock "$lock_file" _ipc_state_add_credits "$state_file" 1
            continue
        fi
        tmpl=$(< "$claim")
        if [ -n "$tmpl" ] && _ipc_with_lock "$lock_file" _ipc_emit_locked "$state_file" "$data_fifo" "$tmpl" >/dev/null; then
            rm -f "$claim" 2>/dev/null || true
            flushed=$((flushed + 1))
        else
            mv "$claim" "$qf" 2>/dev/null || true
            _ipc_with_lock "$lock_file" _ipc_state_add_credits "$state_file" 1
            break
        fi
    done
    echo "$flushed"
    return $IPC_OK
}
fifo_queue_flush() { ipc_queue_flush "$@"; }

# ── 4. Standard Framing & Data Transmission (OKF Protocol) ───────────

# Validates whether a string is a well-formed JSON frame
ipc_validate_frame() {
    local frame="$1"
    [ -z "$frame" ] && return $IPC_ERR_INVALID
    printf '%s' "$frame" | jq -e . >/dev/null 2>&1
}
fifo_validate_frame() { ipc_validate_frame "$@"; }

# Assigns the next sequence number and writes the frame — called ONLY under the
# channel lock, so seq order == FIFO order and seq numbers are unique.
# Prints the assigned seq.
_ipc_emit_locked() {
    local sf="$1" fifo="$2" tmpl="$3" raw cur win
    raw=$(< "$sf") || return $IPC_ERR_NOTFOUND
    _ipc_jget_raw cur "$raw" seq_out 0
    _ipc_jget_raw win "$raw" window_size 5
    local nxt=$((cur + 1))
    local frame="{\"seq\":${nxt},${tmpl#\{\"seq\":0,}"
    local flen
    _ipc_blen flen "$frame"
    [ "$flen" -ge 4096 ] && return $IPC_ERR_INVALID
    if command -v timeout &>/dev/null; then
        # Always bound pipe write so a full kernel buffer never wedges holding the channel lock
        timeout 2 bash -c 'exec 4<>"$2"; printf "%s\n" "$1" >&4' _ "$frame" "$fifo" 2>/dev/null || return $IPC_ERR_PIPE
    else
        { printf '%s\n' "$frame" >&4; } 4<> "$fifo" 2>/dev/null || return $IPC_ERR_PIPE
    fi
    _ipc_state_patch "$sf" "seq_out=$nxt" "last_activity=${EPOCHSECONDS:-$(_ipc_now)}"
    printf '%s' "$nxt"
}

# Writes an atomic NDJSON message frame conforming to OKF Standard
# Schema: {seq, type, channel, uuid, sender_id, sender_role, timestamp, credits_granted, payload}
# Every frame is < PIPE_BUF; payloads that would not fit are spilled to disk and
# transparently re-hydrated by ipc_recv. Only payloads > FIFO_MAX_PAYLOAD_BYTES are truncated.
# Returns: 0 delivered | 75 IPC_QUEUED (credit window full; durably queued) | 2 | 22 | 32 | 110
# Usage: ipc_send <channel_id> [type] [payload_json_or_string] [uuid] [timeout_s]
ipc_send() {
    local cid="$1"
    local type="${2:-DATA}"
    local payload="${3:-"{}"}"
    local uuid="${4:-}"
    local timeout="${5:-10}"

    [ -z "$cid" ] && return $IPC_ERR_INVALID
    if [ -z "$uuid" ]; then
        if [ -r /proc/sys/kernel/random/uuid ]; then
            read -r uuid < /proc/sys/kernel/random/uuid
        else
            uuid=$(_ipc_uuid)
        fi
    fi

    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local data_fifo="$cdir/data.fifo"
    local state_file="$cdir/state.json"
    local lock_file="$cdir/state.lock"
    local qdir="$cdir/queue"

    [ ! -p "$data_fifo" ] && return $IPC_ERR_NOTFOUND
    local st_raw="" ch_mode
    st_raw=$(< "$state_file") 2>/dev/null
    _ipc_jget_raw ch_mode "$st_raw" mode stream
    [ "$ch_mode" = "credit" ] && return $IPC_ERR_INVALID

    # Normalize payload to a single compact JSON value (NDJSON-safe: no raw newlines)
    local payload_json=""
    payload_json=$(printf '%s' "$payload" | jq -c . 2>/dev/null)
    if [ -z "$payload_json" ] || [[ "$payload_json" == *$'\n'* ]]; then
        payload_json=$(printf '%s' "$payload" | jq -Rsc '{text: .}')
    fi

    local plen
    _ipc_blen plen "$payload_json"
    if [ "$plen" -gt "$FIFO_MAX_PAYLOAD_BYTES" ]; then
        payload_json=$(printf '%s' "${payload_json:0:4096}" | jq -Rsc --argjson orig "$plen" \
            '{truncated: true, original_bytes: $orig, snippet: .}')
        _ipc_blen plen "$payload_json"
    fi

    # PIPE_BUF protection: spill payloads that would push the frame past FIFO_SPILL_BYTES
    if [ $((plen + 600)) -gt "$FIFO_SPILL_BYTES" ]; then
        mkdir -p "$FIFO_IPC_DIR/payloads" 2>/dev/null || true
        local payload_file
        printf -v payload_file '%s/payloads/%s_%s_%05d.payload' "$FIFO_IPC_DIR" "$uuid" "${EPOCHREALTIME//[.,]/}" "$RANDOM"
        printf '%s' "$payload_json" > "$payload_file" || return $IPC_ERR_GENERIC
        payload_json=$(printf '%s' "${payload_json:0:256}" | jq -Rsc --arg pfile "$payload_file" --argjson bytes "$plen" \
            '{__spillover_ref__: $pfile, bytes: $bytes, preview: .}')
    fi

    local tmpl
    tmpl=$(jq -nc \
        --arg type "$type" \
        --arg chan "$cid" \
        --arg uuid "$uuid" \
        --arg sid "${GEORGE_AGENT_ID:-${USER:-agent}}" \
        --arg srole "${GEORGE_AGENT_ROLE:-agent}" \
        --argjson ts "${EPOCHSECONDS:-$(_ipc_now)}" \
        --argjson body "$payload_json" \
        '{seq: 0, type: $type, channel: $chan, uuid: $uuid, sender_id: $sid,
          sender_role: $srole, timestamp: $ts, credits_granted: 0, payload: $body}') || return $IPC_ERR_INVALID
    [[ "$tmpl" == '{"seq":0,'* ]] || return $IPC_ERR_INVALID

    # Preserve FIFO order: if a backlog exists, drain it (credit-gated) before new frames
    local -a q=("$qdir"/*.frame)
    if [ -e "${q[0]}" ]; then
        ipc_queue_flush "$cid" >/dev/null 2>&1
        q=("$qdir"/*.frame)
        if [ -e "${q[0]}" ]; then
            _ipc_queue_put "$qdir" "$tmpl" || return $IPC_ERR_BUSY
            return $IPC_QUEUED
        fi
    fi

    # Acquire transmission credit (enforces credit window & backpressure)
    ipc_flow_acquire "$cid" "$timeout"
    local acq=$?
    if [ "$acq" -ne 0 ]; then
        if [ "$acq" -eq "$IPC_ERR_TIMEOUT" ] && [ -d "$qdir" ]; then
            _ipc_queue_put "$qdir" "$tmpl" || return $IPC_ERR_BUSY
            return $IPC_QUEUED
        fi
        return "$acq"
    fi

    # Sequence assignment + kernel write happen atomically under the channel lock
    if ! _ipc_with_lock "$lock_file" _ipc_emit_locked "$state_file" "$data_fifo" "$tmpl" >/dev/null; then
        _ipc_with_lock "$lock_file" _ipc_state_add_credits "$state_file" 1
        return $IPC_ERR_PIPE
    fi
    return $IPC_OK
}
fifo_send() { ipc_send "$@"; }

# Backward compatible writer shim
ipc_write_frame() {
    local cid="$1"
    local payload="$2"
    local timeout="${3:-10}"
    ipc_send "$cid" "DATA" "$payload" "" "$timeout"
}
fifo_write_frame() { ipc_write_frame "$@"; }

# Returns 0 if a frame matches the (optional) type and uuid filters.
_ipc_frame_matches() {
    local frame="$1" ftype="$2" fuuid="$3" t="" u=""
    if [ -n "$ftype" ] && [ "$ftype" != "*" ]; then
        [[ "$frame" =~ \"type\":[[:space:]]*\"([^\"]+)\" ]] && t="${BASH_REMATCH[1]}"
        [ "$t" = "$ftype" ] || return 1
    fi
    if [ -n "$fuuid" ]; then
        [[ "$frame" =~ \"uuid\":[[:space:]]*\"([^\"]+)\" ]] && u="${BASH_REMATCH[1]}"
        [ "$u" = "$fuuid" ] || return 1
    fi
    return 0
}

# Hydrates spillover, updates consumer bookkeeping, grants credit, and prints the frame.
_ipc_recv_deliver() {
    local cid="$1" frame="$2" auto_grant="$3"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    if [[ "$frame" =~ \"__spillover_ref__\":[[:space:]]*\"([^\"]+)\" ]]; then
        local sp_file="${BASH_REMATCH[1]}"
        # Only hydrate files inside our payload store (defends against path injection)
        if [[ "$sp_file" == "$FIFO_IPC_DIR/payloads/"* ]] && [[ "$sp_file" != *..* ]] && [ -f "$sp_file" ]; then
            local hydrated
            hydrated=$(printf '%s' "$frame" | jq -c --slurpfile p "$sp_file" '.payload = $p[0]' 2>/dev/null)
            if [ -n "$hydrated" ]; then
                frame="$hydrated"
                rm -f "$sp_file" 2>/dev/null || true
            fi
        fi
    fi
    _ipc_with_lock "$cdir/state.lock" _ipc_increment_seq_in "$cdir/state.json" "${BASHPID:-$$}"
    [ "$auto_grant" = "1" ] && ipc_flow_grant "$cid" 1
    printf '%s\n' "$frame"
}

# Reads the next frame with correlation matching & auto-credit replenishment.
# Non-matching frames are parked in mailbox/ (ordered by seq) instead of being
# re-written to the pipe tail, so filtering never reorders the stream.
# Usage: ipc_recv <channel_id> [timeout_s] [filter_type] [filter_uuid] [auto_grant]
ipc_recv() {
    local cid="$1"
    local timeout="${2:-5}"
    local filter_type="${3:-}"
    local filter_uuid="${4:-}"
    local auto_grant="${5:-1}"

    [ -z "$cid" ] && return $IPC_ERR_INVALID
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local data_fifo="$cdir/data.fifo"
    local mbox="$cdir/mailbox"
    [ ! -p "$data_fifo" ] && return $IPC_ERR_NOTFOUND
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=5

    local frame="" mf
    # 1. Parked frames first (they precede anything still in the pipe)
    #    Note: credit was already granted when the frame was drained from data.fifo into mailbox/
    local -a mb=("$mbox"/*.frame)
    if [ -e "${mb[0]}" ]; then
        for mf in "${mb[@]}"; do
            [ -f "$mf" ] || continue
            frame=$(< "$mf") 2>/dev/null || continue
            if _ipc_frame_matches "$frame" "$filter_type" "$filter_uuid"; then
                mv "$mf" "${mf}.taken.${BASHPID}" 2>/dev/null || continue
                rm -f "${mf}.taken.${BASHPID}" 2>/dev/null
                _ipc_recv_deliver "$cid" "$frame" "0"
                return $IPC_OK
            fi
        done
    fi

    # 2. Pipe
    local deadline=$(( ${EPOCHSECONDS:-$(_ipc_now)} + timeout )) remain fseq mfn
    while :; do
        remain=$(( deadline - ${EPOCHSECONDS:-$(_ipc_now)} ))
        [ "$remain" -le 0 ] && return $IPC_ERR_AWAIT_TIMEOUT
        frame=""
        if read -t "$remain" -r frame <> "$data_fifo" 2>/dev/null; then
            [ -z "$frame" ] && continue
            if _ipc_frame_matches "$frame" "$filter_type" "$filter_uuid"; then
                _ipc_recv_deliver "$cid" "$frame" "$auto_grant"
                return $IPC_OK
            fi
            fseq=0
            [[ "$frame" =~ ^\{\"seq\":([0-9]+) ]] && fseq="${BASH_REMATCH[1]}"
            mkdir -p "$mbox" 2>/dev/null
            # Enforce bounded mailbox capacity (evict oldest if full)
            local -a cur_mb=("$mbox"/*.frame)
            if [ -e "${cur_mb[0]}" ] && [ "${#cur_mb[@]}" -ge "${FIFO_QUEUE_MAX:-512}" ]; then
                rm -f "${cur_mb[0]}" 2>/dev/null || true
            fi
            printf -v mfn '%s/%012d_%05d.frame' "$mbox" "$fseq" "$RANDOM"
            printf '%s\n' "$frame" > "${mfn}.tmp" && mv -f "${mfn}.tmp" "$mfn"
            # Frame is now off the kernel pipe and in disk mailbox; replenish window credit to prevent HoL deadlock
            [ "$auto_grant" = "1" ] && ipc_flow_grant "$cid" 1
        else
            [ -p "$data_fifo" ] || return $IPC_ERR_PIPE
            return $IPC_ERR_AWAIT_TIMEOUT
        fi
    done
}
fifo_recv() { ipc_recv "$@"; }

# Backward compatible reader shim
ipc_read_frame() {
    local cid="$1"
    local timeout="${2:-5}"
    local auto_grant="${3:-1}"
    ipc_recv "$cid" "$timeout" "" "" "$auto_grant"
}
fifo_read_frame() { ipc_read_frame "$@"; }

# Flushes and discards unread frames from data.fifo, queue and mailbox; resets credits
ipc_channel_flush() {
    local cid="$1"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local data_fifo="$cdir/data.fifo"
    local state_file="$cdir/state.json"
    local lock_file="$cdir/state.lock"
    [ ! -f "$state_file" ] && return $IPC_ERR_NOTFOUND

    if [ -p "$data_fifo" ]; then
        local junk=""
        while read -t 0.05 -r junk <> "$data_fifo" 2>/dev/null; do :; done
    fi
    rm -f "$cdir/queue"/*.frame "$cdir/mailbox"/*.frame 2>/dev/null || true

    local win raw
    raw=$(< "$state_file")
    _ipc_jget_raw win "$raw" window_size 5
    _ipc_with_lock "$lock_file" _ipc_state_reset_credits "$state_file" "$win"
    return $IPC_OK
}
fifo_channel_flush() { ipc_channel_flush "$@"; }

# ── 5. Async / Await Execution Runtime & Process Management ──────────

# Zero-fork sleep: blocks on a private never-written FIFO with read -t.
_ipc_sleep() {
    local secs="${1:-0.05}"
    if [ -z "${_IPC_SLEEP_FIFO:-}" ] || [ ! -p "$_IPC_SLEEP_FIFO" ]; then
        _IPC_SLEEP_FIFO="${FIFO_IPC_DIR}/.sleep.${BASHPID}.fifo"
        mkdir -p "$FIFO_IPC_DIR" 2>/dev/null
        mkfifo -m 0600 "$_IPC_SLEEP_FIFO" 2>/dev/null || { sleep "$secs"; return 0; }
    fi
    read -t "$secs" -r _ <> "$_IPC_SLEEP_FIFO" 2>/dev/null
    return 0
}

# Transitions a promise to a terminal state ONLY if it is still RUNNING/PENDING.
# Must be called under the promise lock. Returns 1 if another party already finalized.
_ipc_prom_finalize() {
    local pf="$1" st="$2" ec="$3" raw cur
    [ -f "$pf" ] || return 1
    raw=$(< "$pf")
    _ipc_jget_raw cur "$raw" status ""
    case "$cur" in
        RUNNING|PENDING) ;;
        *) return 1 ;;
    esac
    _ipc_state_patch "$pf" "status=\"$st\"" "exit_code=$ec" "finished_at=${EPOCHSECONDS:-$(_ipc_now)}"
}

# Pattern to redact sensitive tokens/secrets from error logs before event emission
_IPC_SECRET_PATTERN='(ghp_[A-Za-z0-9_]+|gh[ousr]_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+|xox[abpr]-[A-Za-z0-9-]+|bearer[[:space:]]+[A-Za-z0-9_.~+/=-]+|(password|passwd|pass|token|access_token|api_key|apikey|secret|key)=[^&[:space:]"]+)'

# Emits a system.job_failure event to the Reactive Event Bus when an async IPC command fails.
# Bridges asynchronous background execution into the Sovereign Remediation Loop.
# Usage: _ipc_emit_failure_event <prom_id> <channel_id> <cmd> <exit_code> <prom_out> <start_ts>
_ipc_emit_failure_event() {
    local prom_id="$1"
    local cid="$2"
    local cmd="$3"
    local ec="${4:-1}"
    local prom_out="${5:-}"
    local start_ts="${6:-}"

    [ "${IPC_ASYNC_EMIT_FAILURES:-1}" = "1" ] || return 0
    [[ "$ec" =~ ^-?[0-9]+$ ]] || ec=1

    local wall_s=0
    if [[ "$start_ts" =~ ^[0-9]+$ ]]; then
        wall_s=$(( ${EPOCHSECONDS:-$(_ipc_now)} - start_ts ))
        [ "$wall_s" -lt 0 ] && wall_s=0
    fi

    # Derive clean, valid job_id matching ^[A-Za-z0-9_.-]{1,80}$
    local base_cmd
    base_cmd=$(echo "$cmd" | sed -E 's/^[[:space:]]*(cd[[:space:]]+[^;&]+;[[:space:]]*)?//' | awk '{print $1" "$2}' | tr -cs 'a-zA-Z0-9_.-' '_')
    local clean_id="${cid:-ipc}_${base_cmd}"
    clean_id=$(echo "$clean_id" | tr -cs 'A-Za-z0-9_.-' '_' | sed -E 's/^_+|_+$//g')
    [ "${#clean_id}" -gt 60 ] && clean_id="${clean_id:0:60}"
    [ -z "$clean_id" ] && clean_id="ipc_task"

    local tail_txt=""
    if [ -n "$prom_out" ] && [ -r "$prom_out" ]; then
        tail_txt=$(tail -n 40 "$prom_out" 2>/dev/null \
            | sed -E 's/\x1B\[[0-9;?]*[A-Za-z]//g' \
            | tr -d '\000-\010\013\014\016-\037' \
            | sed -E "s#$_IPC_SECRET_PATTERN#[REDACTED_SECRET]#gI")
        if [ "${#tail_txt}" -gt 4000 ]; then
            tail_txt="${tail_txt: -4000}"
        fi
    fi

    # Satisfies system.job_failure event contract:
    # required: [job, job_id, label, exit_code, stderr_tail, wall_s]
    local payload
    payload=$(jq -nc \
        --arg j "$clean_id" \
        --arg jid "$clean_id" \
        --arg lbl "${cmd:0:120}" \
        --argjson ec "$ec" \
        --arg log "$prom_out" \
        --arg tail "$tail_txt" \
        --argjson wall "$wall_s" \
        --arg prom "$prom_id" \
        --arg chan "$cid" \
        --arg src "ipc_async" \
        '{job: $j, job_id: $jid, label: $lbl, exit_code: $ec, log: $log, stderr_tail: $tail, wall_s: $wall, promise_id: $prom, channel: $chan, source: $src}')

    if ! declare -f ipc_dispatch_event &>/dev/null; then
        source "${BASH_SOURCE[0]%/*}/event_bus.sh" 2>/dev/null \
            || source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true
        declare -f event_bus_emit &>/dev/null && event_bus_emit "system.job_failure" "$payload" "ipc_async" 2>/dev/null || true
    else
        ipc_dispatch_event "system.job_failure" "$payload" "ipc_async" 2>/dev/null || true
    fi
}

# Spawns a command or function in the background attached to channel IPC.
# The command runs in its own process group (job control) so cancel/timeout reap the
# entire tree. All promise-manifest writes are serialized by a per-promise lock and
# terminal transitions are first-writer-wins, so results can never be lost.
# The worker sees IPC_PROMISE_ID / IPC_PROMISE_CHANNEL in its environment.
# Usage: ipc_async <channel_id> <command_line> [tool_call_id] [tool_name] [tool_args]
ipc_async() {
    local cid="$1"
    local cmd="$2"
    local t_call_id="${3:-}"
    local t_name="${4:-}"
    local t_args="${5:-}"
    ipc_init

    local start_ts="${EPOCHSECONDS:-$(_ipc_now)}"
    local prom_id="prom_${start_ts}_${BASHPID}_${RANDOM}"
    local prom_file="$FIFO_IPC_DIR/promises/${prom_id}.json"
    local prom_out="$FIFO_IPC_DIR/promises/${prom_id}.out"
    local prom_lock="$FIFO_IPC_DIR/promises/${prom_id}.lock"

    jq -n \
        --arg pid "$prom_id" \
        --arg cid "$cid" \
        --arg cmd "$cmd" \
        --arg tcid "$t_call_id" \
        --arg tname "$t_name" \
        --arg targs "$t_args" \
        --argjson ts "$start_ts" \
        '{
            promise_id: $pid,
            channel_id: $cid,
            command: $cmd,
            tool_call_id: (if $tcid == "" then null else $tcid end),
            tool_name: (if $tname == "" then null else $tname end),
            tool_args: (if $targs == "" then null else $targs end),
            status: "RUNNING",
            pid: 0,
            pgid: 0,
            started_at: $ts,
            finished_at: null,
            exit_code: null
        }' > "$prom_file" 2>/dev/null || return $IPC_ERR_GENERIC

    (
        exec </dev/null
        export IPC_PROMISE_ID="$prom_id" IPC_PROMISE_CHANNEL="$cid"
        set -m
        ( eval "$cmd" ) > "$prom_out" 2>&1 &
        local job=$!
        set +m
        _ipc_with_lock "$prom_lock" _ipc_state_patch "$prom_file" "pgid=$job"
        wait "$job"
        local exit_code=$?

        local p_status="RESOLVED"
        [ "$exit_code" -ne 0 ] && p_status="REJECTED"
        if _ipc_with_lock "$prom_lock" _ipc_prom_finalize "$prom_file" "$p_status" "$exit_code"; then
            if [ -n "$cid" ] && ipc_channel_is_open "$cid"; then
                local out_body=""
                out_body=$(head -c 2000 "$prom_out" 2>/dev/null)
                local res_payload
                res_payload=$(jq -nc --arg prom "$prom_id" --argjson ec "$exit_code" \
                    --arg out "$out_body" --arg st "$p_status" \
                    '{promise_id: $prom, exit_code: $ec, output: $out, status: $st}')
                ipc_send "$cid" "PROMISE_SETTLED" "$res_payload" "$prom_id" 2 2>/dev/null || true
            fi
            if [ "$exit_code" -ne 0 ]; then
                _ipc_emit_failure_event "$prom_id" "$cid" "$cmd" "$exit_code" "$prom_out" "$start_ts"
            fi
        fi
    ) </dev/null >/dev/null 2>&1 &

    local bg_pid=$!
    _ipc_with_lock "$prom_lock" _ipc_state_patch "$prom_file" "pid=$bg_pid"

    echo "$prom_id"
    return $IPC_OK
}
fifo_async() { ipc_async "$@"; }

# Explicitly attaches/updates tool call metadata on an existing promise manifest
_ipc_prom_register_tool_call() {
    local prom_id="$1"
    local call_id="$2"
    local tool_name="$3"
    local tool_args="$4"
    local pf="$FIFO_IPC_DIR/promises/${prom_id}.json"
    local pl="$FIFO_IPC_DIR/promises/${prom_id}.lock"
    [ -f "$pf" ] || return $IPC_ERR_NOTFOUND
    _ipc_with_lock "$pl" bash -c '
        pf="$1"; cid="$2"; tn="$3"; ta="$4"
        tmp="${pf}.tmp.$$"
        jq --arg cid "$cid" --arg tn "$tn" --arg ta "$ta" \
            '\'' . + {tool_call_id: $cid, tool_name: $tn, tool_args: $ta} '\'' "$pf" > "$tmp" 2>/dev/null && mv "$tmp" "$pf"
    ' _ "$pf" "$call_id" "$tool_name" "$tool_args"
}
fifo_prom_register_tool_call() { _ipc_prom_register_tool_call "$@"; }

# Reads promise state into the caller's variables: _p_st _p_ec _p_pid _p_pgid
_ipc_prom_read() {
    local pf="$1" raw=""
    [ -f "$pf" ] && raw=$(< "$pf")
    _ipc_jget_raw _p_st "$raw" status PENDING
    _ipc_jget_raw _p_ec "$raw" exit_code ""
    _ipc_jget_raw _p_pid "$raw" pid 0
    _ipc_jget_raw _p_pgid "$raw" pgid 0
    [[ "$_p_ec" =~ ^-?[0-9]+$ ]] || _p_ec=""
    [[ "$_p_pid" =~ ^[0-9]+$ ]] || _p_pid=0
    [[ "$_p_pgid" =~ ^[0-9]+$ ]] || _p_pgid=0
}

# Emits the agent keep-alive pulse used by long awaits
_ipc_await_pulse() {
    local sess="${AGENT_ACTIVE_SESSION_ID:-}"
    [ -z "$sess" ] && return 0
    declare -f telemetry_task_heartbeat &>/dev/null && telemetry_task_heartbeat "$sess" "${AGENT_ACTIVE_TURN:-1}" "${AGENT_ACTIVE_TOOL:-async_ipc}" "${AGENT_ACTIVE_MAX_TURNS:-200}"
    declare -f agent_sm_heartbeat &>/dev/null && agent_sm_heartbeat "$sess"
    return 0
}

# Awaits resolution of an async promise with zero-fork polling and process-group
# reaping on timeout / crash.
# Usage: ipc_await <promise_id> [timeout_s]
ipc_await() {
    local prom_id="$1"
    local timeout="${2:-30}"
    local prom_file="$FIFO_IPC_DIR/promises/${prom_id}.json"
    local prom_out="$FIFO_IPC_DIR/promises/${prom_id}.out"
    local prom_lock="$FIFO_IPC_DIR/promises/${prom_id}.lock"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=30

    if [ ! -f "$prom_file" ]; then
        ui_err "Promise $prom_id not found" >&2
        return $IPC_ERR_NOTFOUND
    fi

    local start_ts="${EPOCHSECONDS:-$(_ipc_now)}" elapsed last_pulse=0
    local _p_st _p_ec _p_pid _p_pgid

    while :; do
        elapsed=$(( ${EPOCHSECONDS:-$(_ipc_now)} - start_ts ))
        if [ $((elapsed - last_pulse)) -ge 15 ]; then
            last_pulse="$elapsed"
            _ipc_await_pulse
        fi

        _ipc_prom_read "$prom_file"
        case "$_p_st" in
            RESOLVED)
                [ -f "$prom_out" ] && cat "$prom_out"
                return "${_p_ec:-0}"
                ;;
            REJECTED)
                [ -f "$prom_out" ] && cat "$prom_out" >&2
                return "${_p_ec:-1}"
                ;;
            CANCELED)
                [ -f "$prom_out" ] && cat "$prom_out" >&2
                return $IPC_ERR_CANCELED
                ;;
        esac

        # Crash detection: wrapper died without settling the promise
        if [ "$_p_pid" -gt 1 ] && ! kill -0 "$_p_pid" 2>/dev/null; then
            _ipc_sleep 0.05
            _ipc_prom_read "$prom_file"
            case "$_p_st" in RESOLVED|REJECTED|CANCELED) continue ;; esac
            if _ipc_with_lock "$prom_lock" _ipc_prom_finalize "$prom_file" "REJECTED" 137; then
                _ipc_kill_tree 0 "$_p_pgid" KILL
                ui_err "Process PID $_p_pid for promise $prom_id died unexpectedly." >&2
                printf "ERROR: Process PID %s terminated prematurely (crashed or killed)\n" "$_p_pid" >&2
                return $IPC_ERR_CRASH
            fi
            continue
        fi

        if [ "$elapsed" -ge "$timeout" ]; then
            # Settle first (first-writer-wins), then reap the whole process group
            if _ipc_with_lock "$prom_lock" _ipc_prom_finalize "$prom_file" "REJECTED" 124; then
                ui_warn "Promise $prom_id timed out after ${timeout}s" >&2
                _ipc_kill_tree "$_p_pid" "$_p_pgid" TERM
                return $IPC_ERR_AWAIT_TIMEOUT
            fi
            continue
        fi

        _ipc_sleep "$FIFO_POLL_INTERVAL"
    done
}
fifo_await() { ipc_await "$@"; }

# Awaits resolution of multiple async promise handles concurrently (fail-fast barrier by default, settled-all with --settled)
# Usage:
#   ipc_await_all [--settled] <p1,p2,...|p1 p2 ...> [timeout_s]
#   fifo_await_all_settled <p1,p2,...|p1 p2 ...> [timeout_s]
ipc_await_all() {
    local settled_mode=false
    if [ "${1:-}" = "--settled" ] || [ "${1:-}" = "--settled-all" ]; then
        settled_mode=true
        shift
    fi

    local promises=()
    local timeout=60

    local args=("$@")
    if [ "${#args[@]}" -gt 1 ]; then
        if [[ "${args[0]}" =~ ^[0-9]+$ ]]; then
            timeout="${args[0]}"
            args=("${args[@]:1}")
        else
            local last_idx=$((${#args[@]} - 1))
            if [[ "${args[$last_idx]}" =~ ^[0-9]+$ ]]; then
                timeout="${args[$last_idx]}"
                unset 'args[last_idx]'
            fi
        fi
    fi

    local a p
    for a in "${args[@]}"; do
        IFS=',' read -ra split_arr <<< "$a"
        for p in "${split_arr[@]}"; do
            [ -n "$p" ] && promises+=("$p")
        done
    done
    [ "${#promises[@]}" -eq 0 ] && return $IPC_OK

    local start_ts="${EPOCHSECONDS:-$(_ipc_now)}" elapsed last_pulse=0
    local _p_st _p_ec _p_pid _p_pgid prom_id pf pl

    while :; do
        elapsed=$(( ${EPOCHSECONDS:-$(_ipc_now)} - start_ts ))
        if [ $((elapsed - last_pulse)) -ge 15 ]; then
            last_pulse="$elapsed"
            _ipc_await_pulse
        fi

        if [ "$elapsed" -ge "$timeout" ]; then
            ui_warn "ipc_await_all timed out after ${timeout}s" >&2
            for prom_id in "${promises[@]}"; do
                pf="$FIFO_IPC_DIR/promises/${prom_id}.json"
                pl="$FIFO_IPC_DIR/promises/${prom_id}.lock"
                [ -f "$pf" ] || continue
                _ipc_prom_read "$pf"
                case "$_p_st" in RESOLVED|REJECTED|CANCELED) continue ;; esac
                if _ipc_with_lock "$pl" _ipc_prom_finalize "$pf" "REJECTED" 124; then
                    _ipc_kill_tree "$_p_pid" "$_p_pgid" TERM
                fi
            done
            return $IPC_ERR_AWAIT_TIMEOUT
        fi

        local all_done=true any_failed=false fail_code=1
        for prom_id in "${promises[@]}"; do
            pf="$FIFO_IPC_DIR/promises/${prom_id}.json"
            pl="$FIFO_IPC_DIR/promises/${prom_id}.lock"
            if [ ! -f "$pf" ]; then
                any_failed=true; fail_code=$IPC_ERR_NOTFOUND
                if [ "$settled_mode" = "false" ]; then break; else continue; fi
            fi
            _ipc_prom_read "$pf"
            case "$_p_st" in
                RESOLVED) ;;
                REJECTED) any_failed=true; [ "$fail_code" -eq 1 ] && fail_code="${_p_ec:-1}" ;;
                CANCELED) any_failed=true; [ "$fail_code" -eq 1 ] && fail_code=$IPC_ERR_CANCELED ;;
                *)
                    if [ "$_p_pid" -gt 1 ] && ! kill -0 "$_p_pid" 2>/dev/null; then
                        _ipc_sleep 0.05
                        _ipc_prom_read "$pf"
                        if [ "$_p_st" = "RESOLVED" ]; then
                            :
                        elif _ipc_with_lock "$pl" _ipc_prom_finalize "$pf" "REJECTED" 137; then
                            _ipc_kill_tree 0 "$_p_pgid" KILL
                            any_failed=true; [ "$fail_code" -eq 1 ] && fail_code=$IPC_ERR_CRASH
                        else
                            all_done=false
                        fi
                    else
                        all_done=false
                    fi
                    ;;
            esac
            if [ "$settled_mode" = "false" ] && [ "$any_failed" = "true" ]; then break; fi
        done

        if [ "$settled_mode" = "false" ] && [ "$any_failed" = "true" ]; then return "$fail_code"; fi
        if [ "$all_done" = "true" ]; then
            [ "$any_failed" = "true" ] && return "$fail_code"
            return $IPC_OK
        fi
        _ipc_sleep "$FIFO_POLL_INTERVAL"
    done
}
fifo_await_all() { ipc_await_all "$@"; }
ipc_await_all_settled() { ipc_await_all --settled "$@"; }
fifo_await_all_settled() { ipc_await_all --settled "$@"; }

# Explicitly terminates an in-flight async promise and reaps its process group
# Usage: ipc_cancel <promise_id> [signal]
ipc_cancel() {
    local prom_id="$1"
    local sig="${2:-TERM}"
    sig="${sig#SIG}"
    local prom_file="$FIFO_IPC_DIR/promises/${prom_id}.json"
    local prom_out="$FIFO_IPC_DIR/promises/${prom_id}.out"
    local prom_lock="$FIFO_IPC_DIR/promises/${prom_id}.lock"

    [ ! -f "$prom_file" ] && return $IPC_ERR_NOTFOUND

    local _p_st _p_ec _p_pid _p_pgid
    _ipc_prom_read "$prom_file"
    case "$_p_st" in RESOLVED|REJECTED|CANCELED) return $IPC_OK ;; esac

    if _ipc_with_lock "$prom_lock" _ipc_prom_finalize "$prom_file" "CANCELED" 125; then
        _ipc_kill_tree "$_p_pid" "$_p_pgid" "$sig"
        printf "\n[CANCELED: Task explicitly terminated by operator via SIG%s]\n" "$sig" >> "$prom_out" 2>/dev/null || true
    fi
    return $IPC_OK
}
fifo_cancel() { ipc_cancel "$@"; }

# Chains the output of a resolved promise into a subsequent async command.
# SECURITY: the previous output is NEVER spliced into the command text. It is exposed
# as the shell variable IPC_PIPE_INPUT; '{}' in the template expands to ${IPC_PIPE_INPUT}
# (use it inside double quotes). Without '{}', the output is piped to stdin.
# Usage: ipc_pipe <promise_id> <channel_id> <next_command_template> [timeout_s]
ipc_pipe() {
    local prom_id="$1"
    local cid="$2"
    local next_cmd="$3"
    local timeout="${4:-30}"

    local prev_out
    prev_out=$(ipc_await "$prom_id" "$timeout")
    local ec=$?
    if [ "$ec" -ne 0 ]; then
        ui_err "ipc_pipe: previous promise $prom_id failed with exit code $ec" >&2
        return "$ec"
    fi

    local final_cmd
    if [[ "$next_cmd" == *"{}"* ]]; then
        final_cmd="${next_cmd//\{\}/\$\{IPC_PIPE_INPUT\}}"
    else
        final_cmd="printf '%s' \"\${IPC_PIPE_INPUT}\" | { ${next_cmd}
}"
    fi

    IPC_PIPE_INPUT="$prev_out"
    ipc_async "$cid" "$final_cmd"
}
fifo_pipe() { ipc_pipe "$@"; }

# Bridges IPC subsystems into the Reactive Event Bus (FAULT_QUARANTINE, WAKE_TASK, ...).
# Returns 0 only if the event was durably accepted (bus FIFO or replay spool).
# Usage: ipc_dispatch_event <event_type> [payload_json] [source]
ipc_dispatch_event() {
    local etype="$1"
    local payload="${2:-}"
    local src="${3:-ipc}"
    [ -z "$etype" ] && return $IPC_ERR_INVALID
    [ -z "$payload" ] && payload='{}'
    if ! declare -f event_bus_emit &>/dev/null; then
        source "${BASH_SOURCE[0]%/*}/event_bus.sh" 2>/dev/null \
            || source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || return $IPC_ERR_GENERIC
    fi
    event_bus_emit "$etype" "$payload" "$src"
}
fifo_dispatch_event() { ipc_dispatch_event "$@"; }

# ── 6. FIFO <-> MQTT Bridge Integration ──────────────────────────────

ipc_mqtt_bridge_start() {
    local cid="$1"
    local topic="$2"
    local dir="${3:-out}"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local state_file="$cdir/state.json"

    [ ! -f "$state_file" ] && return $IPC_ERR_NOTFOUND

    source "$LODGE_DIR/lib/comms/mqtt.sh" 2>/dev/null || true
    MQTT_QUIET=1
    declare -f mqtt_init &>/dev/null && mqtt_init || true

    local bridge_pid_file="$cdir/bridge_${dir}.pid"

    if [ "$dir" = "out" ]; then
        (
            local _bst="" _braw=""
            while [ -f "$state_file" ] && _braw=$(< "$state_file") && _ipc_jget_raw _bst "$_braw" status "" && [ "$_bst" = "OPEN" ]; do
                frame=$(ipc_read_frame "$cid" 2 1 2>/dev/null || true)
                if [ -n "$frame" ]; then
                    declare -f mqtt_publish &>/dev/null && mqtt_publish "$topic" "$frame" >/dev/null 2>&1 || true
                fi
                sleep 0.05
            done
        ) </dev/null >/dev/null 2>&1 &
        local b_pid=$!
        echo "$b_pid" > "$bridge_pid_file"
        local tmp="${state_file}.tmp.$$"
        jq --argjson bp "$b_pid" --arg top "$topic" '.mqtt_out_bridge = {pid: $bp, topic: $top}' "$state_file" > "$tmp" 2>/dev/null && mv "$tmp" "$state_file" 2>/dev/null || true
    elif [ "$dir" = "in" ]; then
        (
            local _bst="" _braw=""
            while [ -f "$state_file" ] && _braw=$(< "$state_file") && _ipc_jget_raw _bst "$_braw" status "" && [ "$_bst" = "OPEN" ]; do
                local msg
                msg=$(mqtt_subscribe "$topic" --count 1 --timeout 2 2>/dev/null || true)
                if [ -n "$msg" ]; then
                    ipc_write_frame "$cid" "$msg" 2 2>/dev/null || true
                fi
                sleep 0.05
            done
        ) </dev/null >/dev/null 2>&1 &
        local b_pid=$!
        echo "$b_pid" > "$bridge_pid_file"
        local tmp="${state_file}.tmp.$$"
        jq --argjson bp "$b_pid" --arg top "$topic" '.mqtt_in_bridge = {pid: $bp, topic: $top}' "$state_file" > "$tmp" 2>/dev/null && mv "$tmp" "$state_file" 2>/dev/null || true
    fi

    return $IPC_OK
}
fifo_mqtt_bridge_start() { ipc_mqtt_bridge_start "$@"; }

ipc_mqtt_bridge_stop() {
    local cid="$1"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    [ ! -d "$cdir" ] && return $IPC_OK

    for pf in "$cdir"/bridge_*.pid; do
        if [ -f "$pf" ]; then
            local bpid
            bpid=$(cat "$pf" 2>/dev/null)
            [ -n "$bpid" ] && kill "$bpid" 2>/dev/null || true
            rm -f "$pf" 2>/dev/null || true
        fi
    done
    return $IPC_OK
}
fifo_mqtt_bridge_stop() { ipc_mqtt_bridge_stop "$@"; }

# ── 7. Protocol Garbage Collector & Flowcontrol Reconciliation ───────
# Sweeps and purges:
#   1. Stale / crashed FIFO channels (dead keeper PID, idle > max_idle)
#   2. Wedged / stalled flowcontrol queues (credits exhausted, dead producers/consumers)
#   3. Orphaned keeper processes with no active channel
#   4. Stale promise files and outputs older than TTL
#   5. Orphaned spillover payload files
#   6. Orphaned lock files
# Usage: ipc_gc [--dry-run] [--force] [--ttl <seconds>]
ipc_gc() {
    ipc_init
    local dry_run=0 force=0 explicit_ttl=0
    local max_idle="${FIFO_GC_MAX_IDLE:-300}"
    local prom_ttl="${FIFO_GC_PROMISE_TTL:-1800}"

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            --force) force=1; explicit_ttl=1; max_idle=0; prom_ttl=0; shift ;;
            --ttl) explicit_ttl=1; max_idle="${2:-$max_idle}"; prom_ttl="${2:-$prom_ttl}"; shift 2 ;;
            *) shift ;;
        esac
    done

    local now_ts="${EPOCHSECONDS:-$(date +%s)}"
    local swept_channels=0
    local reaped_keepers=0
    local pruned_promises=0
    local unwedged_queues=0
    local cleaned_locks=0

    # 1. Sweep Channels & Reconcile Flowcontrol (zero-fork per channel)
    #    - close: keeper verified dead | idle > channel max_idle | CLOSED/ABORTED | --force
    #    - unwedge: credits exhausted or paused, idle > FIFO_GC_WEDGE_SECS, AND nobody alive
    #      can ever release it (no live consumer, no live pauser). A slow-but-alive consumer
    #      or an operator PAUSE is never overridden.
    local sf raw cdir cid st kp last_act win cred bp ch_idle paused_by
    for sf in "$FIFO_IPC_DIR/channels"/*/state.json; do
        [ -f "$sf" ] || continue
        raw=$(< "$sf")
        cdir="${sf%/state.json}"
        _ipc_jget_raw cid "$raw" channel_id "${cdir##*/}"
        _ipc_jget_raw st "$raw" status UNKNOWN
        _ipc_jget_raw kp "$raw" keeper_pid 0
        _ipc_jget_raw last_act "$raw" last_activity 0
        _ipc_jget_raw win "$raw" window_size 5
        _ipc_jget_raw cred "$raw" credits 0
        _ipc_jget_raw bp "$raw" backpressure false
        _ipc_jget_raw ch_idle "$raw" max_idle_secs 0
        _ipc_jget_raw paused_by "$raw" paused_by 0
        [[ "$kp" =~ ^[0-9]+$ ]] || kp=0
        [[ "$last_act" =~ ^[0-9]+$ ]] || last_act=0
        [[ "$ch_idle" =~ ^[0-9]+$ ]] || ch_idle=0
        [[ "$paused_by" =~ ^[0-9]+$ ]] || paused_by=0

        local eff_idle="$max_idle"
        [ "$explicit_ttl" -eq 0 ] && [ "$ch_idle" -gt 0 ] && eff_idle="$ch_idle"
        local idle=$((now_ts - last_act))
        local should_close=0

        if [ "$kp" -gt 1 ] && ! _ipc_is_keeper "$kp" "$cid"; then
            should_close=1
        fi
        if [ "$idle" -gt "$eff_idle" ] || [ "$force" -eq 1 ] || [ "$st" = "CLOSED" ] || [ "$st" = "ABORTED" ]; then
            should_close=1
        fi

        if [ "$should_close" -eq 1 ]; then
            [ "$dry_run" -eq 0 ] && ipc_channel_close "$cid"
            swept_channels=$((swept_channels + 1))
            continue
        fi

        if { [ "$bp" = "true" ] || [ "$cred" -eq 0 ]; } && [ "$idle" -gt "$FIFO_GC_WEDGE_SECS" ]; then
            local pauser_alive=0
            [ "$bp" = "true" ] && [ "$paused_by" -gt 1 ] && kill -0 "$paused_by" 2>/dev/null && pauser_alive=1
            if [ "$pauser_alive" -eq 0 ] && ! _ipc_consumer_alive "$raw"; then
                [ "$dry_run" -eq 0 ] && ipc_flow_unstick "$cid" 2>/dev/null
                unwedged_queues=$((unwedged_queues + 1))
            fi
        fi

        # Restore queue frames orphaned mid-flush by a crashed flusher
        local cl
        for cl in "$cdir/queue"/*.frame.claim.*; do
            [ -f "$cl" ] || continue
            local cl_pid="${cl##*.claim.}"
            if ! kill -0 "$cl_pid" 2>/dev/null; then
                [ "$dry_run" -eq 0 ] && mv -f "$cl" "${cl%.claim.*}" 2>/dev/null
            fi
        done

        # Prune stale mailbox frames older than prom_ttl
        local mbf
        for mbf in "$cdir/mailbox"/*.frame; do
            [ -f "$mbf" ] || continue
            local mb_age=$((now_ts - $(stat -c %Y "$mbf" 2>/dev/null || echo "$now_ts")))
            if [ "$mb_age" -gt "$prom_ttl" ] || [ "$force" -eq 1 ]; then
                [ "$dry_run" -eq 0 ] && rm -f "$mbf" 2>/dev/null || true
            fi
        done
    done

    # 2. Reap Orphaned Keeper Processes (argv0-named discovery)
    local kpid kname kcid
    while read -r kpid kname; do
        [ -z "$kpid" ] && continue
        kcid="${kname#george-keeper-}"
        if [ ! -f "$FIFO_IPC_DIR/channels/$kcid/state.json" ]; then
            # Only reap keepers that belong to THIS ipc dir (fd points into it) or whose dir is gone
            local kfd=""
            kfd=$(readlink "/proc/$kpid/fd/9" 2>/dev/null)
            if [ -z "$kfd" ] || [[ "$kfd" == "$FIFO_IPC_DIR/"* ]] || [[ "$kfd" == *"(deleted)"* ]]; then
                [ "$dry_run" -eq 0 ] && kill -9 "$kpid" 2>/dev/null
                reaped_keepers=$((reaped_keepers + 1))
            fi
        fi
    done < <(ps -eo pid=,args= 2>/dev/null | awk '$2 ~ /^george-keeper-/ { print $1, $2 }')

    # 3. Sweep Promises
    local pf praw prom_id p_st p_pid p_fin p_start
    for pf in "$FIFO_IPC_DIR/promises"/prom_*.json; do
        [ -f "$pf" ] || continue
        prom_id="${pf##*/}"; prom_id="${prom_id%.json}"
        praw=$(< "$pf")
        _ipc_jget_raw p_st "$praw" status CORRUPT
        _ipc_jget_raw p_pid "$praw" pid 0
        _ipc_jget_raw p_fin "$praw" finished_at 0
        _ipc_jget_raw p_start "$praw" started_at 0
        [[ "$p_pid" =~ ^[0-9]+$ ]] || p_pid=0
        [[ "$p_fin" =~ ^[0-9]+$ ]] || p_fin=0
        [[ "$p_start" =~ ^[0-9]+$ ]] || p_start=0
        local pl="$FIFO_IPC_DIR/promises/${prom_id}.lock"

        case "$p_st" in
            RUNNING|PENDING)
                local dead=0
                if [ "$p_pid" -gt 1 ]; then
                    kill -0 "$p_pid" 2>/dev/null || dead=1
                elif [ "$p_start" -gt 0 ] && [ $((now_ts - p_start)) -gt "$FIFO_GC_ORPHAN_SECS" ]; then
                    dead=1   # never acquired a pid (legacy race) and far too old
                fi
                if [ "$dead" -eq 1 ] && [ "$dry_run" -eq 0 ]; then
                    _ipc_with_lock "$pl" _ipc_prom_finalize "$pf" "REJECTED" 137 2>/dev/null
                fi
                ;;
            CORRUPT)
                local p_age=$((now_ts - $(stat -c %Y "$pf" 2>/dev/null || echo "$now_ts")))
                if [ "$p_age" -gt "$prom_ttl" ] || [ "$force" -eq 1 ]; then
                    [ "$dry_run" -eq 0 ] && rm -rf "$FIFO_IPC_DIR/promises/${prom_id}".{json,out,lock,rel} 2>/dev/null
                    pruned_promises=$((pruned_promises + 1))
                fi
                ;;
            *)
                if [ "$force" -eq 1 ] || [ "$p_fin" -eq 0 ] || [ $((now_ts - p_fin)) -gt "$prom_ttl" ]; then
                    [ "$dry_run" -eq 0 ] && rm -rf "$FIFO_IPC_DIR/promises/${prom_id}".{json,out,lock,rel} 2>/dev/null
                    pruned_promises=$((pruned_promises + 1))
                fi
                ;;
        esac
    done
    # Orphaned promise sidecars (.out/.lock/.rel without manifest)
    local side
    for side in "$FIFO_IPC_DIR/promises"/prom_*.out "$FIFO_IPC_DIR/promises"/prom_*.lock "$FIFO_IPC_DIR/promises"/prom_*.rel; do
        [ -e "$side" ] || continue
        [ -f "${side%.*}.json" ] && continue
        local s_age=$((now_ts - $(stat -c %Y "$side" 2>/dev/null || echo "$now_ts")))
        if [ "$s_age" -gt 60 ] || [ "$force" -eq 1 ]; then
            [ "$dry_run" -eq 0 ] && rm -rf "$side" 2>/dev/null
        fi
    done

    # 4. Clean Stale Large Payload Files
    for pfile in "$FIFO_IPC_DIR/payloads"/*.payload; do
        [ ! -f "$pfile" ] && continue
        local p_age=$((now_ts - $(stat -c %Y "$pfile" 2>/dev/null || echo "$now_ts")))
        if [ "$p_age" -gt "$prom_ttl" ] || [ "$force" -eq 1 ]; then
            [ "$dry_run" -eq 0 ] && rm -f "$pfile" 2>/dev/null || true
        fi
    done

    # 5. Clean Orphaned Locks & Sleep FIFOs
    #    flock files are NEVER unlinked while their owner exists: unlinking a lock file
    #    lets two processes hold "exclusive" locks on different inodes simultaneously.
    for lk in "$FIFO_IPC_DIR/channels"/*/state.lock; do
        [ -f "$lk" ] || continue
        if [ ! -f "${lk%/state.lock}/state.json" ]; then
            [ "$dry_run" -eq 0 ] && rm -f "$lk" 2>/dev/null
            cleaned_locks=$((cleaned_locks + 1))
        fi
    done
    local sfifo spid
    for sfifo in "$FIFO_IPC_DIR"/.sleep.*.fifo; do
        [ -p "$sfifo" ] || continue
        spid="${sfifo##*/.sleep.}"; spid="${spid%.fifo}"
        if ! kill -0 "$spid" 2>/dev/null; then
            [ "$dry_run" -eq 0 ] && rm -f "$sfifo" 2>/dev/null
        fi
    done

    # 5b. Clean Stale Heartbeat Ticker PIDs
    for t_pid_file in "$GEORGE_DIR"/sessions/*/.heartbeat_ticker.pid "$LODGE_DIR"/.sandboxes/*/.heartbeat_ticker.pid; do
        [ ! -f "$t_pid_file" ] && continue
        local t_pid
        t_pid=$(cat "$t_pid_file" 2>/dev/null || echo "")
        if [ -z "$t_pid" ] || ! kill -0 "$t_pid" 2>/dev/null; then
            [ "$dry_run" -eq 0 ] && rm -f "$t_pid_file" 2>/dev/null || true
        fi
    done

    # 6. Reconcile Quarantined Task Checkpoints
    local reconciled_checkpoints=0
    local cp_dir="${GEORGE_DIR:-$LODGE_DIR/.george}/checkpoints"
    local cp_files=("$cp_dir"/*.json)
    if [ -e "${cp_files[0]}" ]; then
        for cpf in "${cp_files[@]}"; do
            [ -f "$cpf" ] || continue
            local q_uuid q_status q_created q_exp q_issue q_wdir
            q_uuid=$(jq -r '.uuid // empty' "$cpf" 2>/dev/null)
            q_status=$(jq -r '.status // empty' "$cpf" 2>/dev/null)
            q_created=$(jq -r '.created_at // 0' "$cpf" 2>/dev/null)
            q_exp=$(jq -r '.ttl_expires_at // 0' "$cpf" 2>/dev/null)
            q_issue=$(jq -r '.issue_ref // empty' "$cpf" 2>/dev/null)
            q_wdir=$(jq -r '.sandbox_path // empty' "$cpf" 2>/dev/null)

            [ -z "$q_uuid" ] && continue
            local action_taken=""

            if [ -n "$q_issue" ] && [[ "$q_issue" =~ issues/issue_.*\.md$ ]] && [ ! -f "$q_issue" ]; then
                action_taken="WAKE"
            elif [ "$now_ts" -ge "$q_exp" ] && [ "$q_exp" -gt 0 ]; then
                action_taken="EXPIRE"
            elif [ "$force" -eq 1 ]; then
                action_taken="EXPIRE"
            fi

            if [ "$action_taken" = "WAKE" ]; then
                if [ "$dry_run" -eq 0 ]; then
                    if ipc_dispatch_event "WAKE_TASK" "$(jq -cn --arg uuid "$q_uuid" --arg sb "$q_wdir" '{uuid:$uuid, sandbox_path:$sb, reason:"Remediation complete"}')" "ipc_gc" 2>/dev/null; then
                        mkdir -p "$cp_dir/woken" 2>/dev/null || true
                        mv -f "$cpf" "$cp_dir/woken/" 2>/dev/null || rm -f "$cpf" 2>/dev/null || true
                        reconciled_checkpoints=$((reconciled_checkpoints + 1))
                    else
                        ipc_log "WARN" "gc" "WAKE_TASK dispatch failed for $q_uuid; checkpoint retained for retry"
                    fi
                else
                    reconciled_checkpoints=$((reconciled_checkpoints + 1))
                fi
            elif [ "$action_taken" = "EXPIRE" ]; then
                if [ "$dry_run" -eq 0 ]; then
                    mkdir -p "$cp_dir/expired" 2>/dev/null || true
                    mv "$cpf" "$cp_dir/expired/" 2>/dev/null || true
                    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$q_uuid" "ABORTED" "Quarantine TTL expired" 2>/dev/null || true
                fi
                reconciled_checkpoints=$((reconciled_checkpoints + 1))
            fi
        done
    fi

    # 7. Reconcile Reactive Event Bus & Cooldowns
    local event_bus_reaped=0
    local eb_pid_file="$FIFO_IPC_DIR/event_bus.pid"
    if [ -f "$eb_pid_file" ]; then
        local eb_pid
        eb_pid=$(cat "$eb_pid_file" 2>/dev/null || true)
        if [ -n "$eb_pid" ] && ! kill -0 "$eb_pid" 2>/dev/null; then
            if [ "$dry_run" -eq 0 ]; then
                rm -f "$eb_pid_file" 2>/dev/null || true
            fi
            event_bus_reaped=$((event_bus_reaped + 1))
        fi
    fi

    local watcher_pid_file="$FIFO_IPC_DIR/watcher_fs.pid"
    if [ -f "$watcher_pid_file" ]; then
        local w_pid
        w_pid=$(cat "$watcher_pid_file" 2>/dev/null || true)
        if [ -n "$w_pid" ] && ! kill -0 "$w_pid" 2>/dev/null; then
            if [ "$dry_run" -eq 0 ]; then
                rm -f "$watcher_pid_file" 2>/dev/null || true
            fi
            event_bus_reaped=$((event_bus_reaped + 1))
        fi
    fi

    # Prune stale cooldown files (> 3600s old or --force)
    local cd_files=("$FIFO_IPC_DIR/cooldowns"/*.ts)
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

    # 8. Sweep Dead Daemon PID Files & Unconsumed FIFOs
    local dead_pids_pruned=0
    local cron_pid_file="${GEORGE_DIR:-$LODGE_DIR/.george}/.cron.pid"
    if [ -f "$cron_pid_file" ]; then
        local c_pid
        c_pid=$(cat "$cron_pid_file" 2>/dev/null || true)
        if [ -n "$c_pid" ] && ! kill -0 "$c_pid" 2>/dev/null; then
            [ "$dry_run" -eq 0 ] && rm -f "$cron_pid_file" 2>/dev/null || true
            dead_pids_pruned=$((dead_pids_pruned + 1))
        fi
    fi

    for jpidf in "${GEORGE_DIR:-$LODGE_DIR/.george}/cron_jobs"/.*.pid; do
        [ ! -f "$jpidf" ] && continue
        local jpid
        jpid=$(cat "$jpidf" 2>/dev/null || true)
        if [ -n "$jpid" ] && ! kill -0 "$jpid" 2>/dev/null; then
            [ "$dry_run" -eq 0 ] && rm -f "$jpidf" 2>/dev/null || true
            dead_pids_pruned=$((dead_pids_pruned + 1))
        fi
    done

    # Unconsumed FIFOs in closed/stale channels
    for ch_fifo in "$FIFO_IPC_DIR/channels"/*/*.fifo; do
        [ ! -p "$ch_fifo" ] && continue
        local ch_state_file
        ch_state_file="$(dirname "$ch_fifo")/state.json"
        if [ ! -f "$ch_state_file" ]; then
            [ "$dry_run" -eq 0 ] && rm -f "$ch_fifo" 2>/dev/null || true
        else
            local ch_st
            ch_st=$(jq -r '.status // ""' "$ch_state_file" 2>/dev/null)
            if [ "$ch_st" = "CLOSED" ] || [ "$ch_st" = "ABORTED" ] || [ "$force" -eq 1 ]; then
                [ "$dry_run" -eq 0 ] && rm -f "$ch_fifo" 2>/dev/null || true
            fi
        fi
    done

    if [ "$force" -eq 1 ]; then
        local live_eb_pid
        live_eb_pid=$(cat "$FIFO_IPC_DIR/event_bus.pid" 2>/dev/null || true)
        if [ -z "$live_eb_pid" ] || ! kill -0 "$live_eb_pid" 2>/dev/null; then
            [ "$dry_run" -eq 0 ] && rm -f "$FIFO_IPC_DIR/event_bus.fifo" 2>/dev/null || true
        fi
    fi

    jq -nc \
       --argjson ch "$swept_channels" \
       --argjson kp "$reaped_keepers" \
       --argjson pr "$pruned_promises" \
       --argjson uw "$unwedged_queues" \
       --argjson lk "$cleaned_locks" \
       --argjson cp "$reconciled_checkpoints" \
       --argjson eb "$event_bus_reaped" \
       --argjson dp "$dead_pids_pruned" \
       '{status: "ok", channels_swept: $ch, keepers_reaped: $kp, promises_pruned: $pr, queues_unwedged: $uw, locks_cleaned: $lk, checkpoints_reconciled: $cp, event_bus_reaped: $eb, dead_pids_pruned: $dp}'
}
fifo_gc() { ipc_gc "$@"; }

# ── 10. Sovereign Inference Slot FIFO Lease & Priority Preemption ─────
# Manages single-tenant access to inference_slot_0 (Tier 1 GPU port 8080)
# with priority preemption across interactive, trading, cron, and remediation.

ipc_inference_slot_dir() {
    local s_dir="${FIFO_IPC_DIR:-${GEORGE_DIR}/ipc}/inference_slots/slot_0"
    mkdir -p "$s_dir" 2>/dev/null
    echo "$s_dir"
}

# Checks if human operator is actively engaged (Discord live session, terminal REPL, or Game Mode)
ipc_is_human_present() {
    local lodge="${LODGE_DIR:-$HOME/blue-lodge}"
    local gdir="${GEORGE_DIR:-$lodge/.george}"

    # 1. Game mode check
    [ -f "$gdir/.game_mode" ] && return 0

    # 2. Interactive terminal lock
    local ilock="$gdir/interactive.lock"
    if [ -f "$ilock" ]; then
        local ipid
        ipid=$(cat "$ilock" 2>/dev/null)
        if [ -n "$ipid" ] && kill -0 "$ipid" 2>/dev/null; then
            return 0
        fi
    fi

    # 3. Active Discord session check
    local d_sess_dir="$gdir/discord_sessions"
    if [ -d "$d_sess_dir" ]; then
        for pf in "$d_sess_dir"/session_*.pid; do
            [ -f "$pf" ] || continue
            local dpid
            dpid=$(cat "$pf" 2>/dev/null)
            if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
                return 0
            fi
        done
        for ar in "$d_sess_dir"/active_run_*.json; do
            [ -f "$ar" ] || continue
            local apid
            apid=$(jq -r '.pid // empty' "$ar" 2>/dev/null)
            if [ -n "$apid" ] && kill -0 "$apid" 2>/dev/null; then
                return 0
            fi
        done
    fi

    return 1
}

ipc_acquire_inference_lease() {
    local prio="${1:-$IPC_PRIO_CRON}"
    local task_name="${2:-task_${BASHPID}}"
    local timeout="${3:-60}"
    local slot_dir
    slot_dir=$(ipc_inference_slot_dir)
    local lease_file="$slot_dir/lease.json"
    local lock_file="$slot_dir/lease.lock"
    local start_ts
    start_ts=$(_ipc_now)

    while :; do
        # If background priority (< 100) and human is present, wait cooperatively
        if [ "$prio" -lt "$IPC_PRIO_INTERACTIVE" ] && ipc_is_human_present; then
            _ipc_sleep 2
            local cur_ts
            cur_ts=$(_ipc_now)
            if [ $((cur_ts - start_ts)) -ge "$timeout" ]; then
                ui_dim "Inference lease yielded: human operator present (timeout ${timeout}s)." >&2
                return $IPC_ERR_BUSY
            fi
            continue
        fi

        _ipc_with_lock "$lock_file" _ipc_eval_inference_lease "$lease_file" "$prio" "$task_name"
        local rc=$?
        if [ "$rc" -eq 0 ]; then
            return 0
        fi

        _ipc_sleep "$FIFO_POLL_INTERVAL"
        local cur_ts
        cur_ts=$(_ipc_now)
        if [ $((cur_ts - start_ts)) -ge "$timeout" ]; then
            ui_warn "Timed out acquiring inference lease for $task_name ($prio) after ${timeout}s" >&2
            return $IPC_ERR_TIMEOUT
        fi
    done
}

_ipc_eval_inference_lease() {
    local lease_file="$1" prio="$2" task_name="$3"
    local now
    now=$(_ipc_now)
    local my_pid="${BASHPID:-$$}"

    if [ -f "$lease_file" ]; then
        local cur_pid cur_prio cur_task acq_ts
        cur_pid=$(jq -r '.holder_pid // empty' "$lease_file" 2>/dev/null)
        cur_prio=$(jq -r '.priority // 0' "$lease_file" 2>/dev/null)
        cur_task=$(jq -r '.task_name // ""' "$lease_file" 2>/dev/null)
        acq_ts=$(jq -r '.acquired_at // 0' "$lease_file" 2>/dev/null)

        # Same task/PID already holds the lease
        if [ "$cur_pid" = "$my_pid" ] || [ "$cur_task" = "$task_name" ]; then
            jq -nc --arg pid "$my_pid" --argjson prio "$prio" --arg task "$task_name" --argjson now "$now" \
               '{holder_pid: ($pid|tonumber), priority: $prio, task_name: $task, acquired_at: $now}' > "$lease_file"
            return 0
        fi

        # Check if current holder is dead
        if [ -n "$cur_pid" ] && ! kill -0 "$cur_pid" 2>/dev/null; then
            jq -nc --arg pid "$my_pid" --argjson prio "$prio" --arg task "$task_name" --argjson now "$now" \
               '{holder_pid: ($pid|tonumber), priority: $prio, task_name: $task, acquired_at: $now}' > "$lease_file"
            return 0
        fi

        # Preemption check: Higher priority preempts lower priority
        if [ "$prio" -gt "$cur_prio" ]; then
            jq -nc --arg pid "$my_pid" --argjson prio "$prio" --arg task "$task_name" --argjson now "$now" \
               '{holder_pid: ($pid|tonumber), priority: $prio, task_name: $task, acquired_at: $now}' > "$lease_file"
            return 0
        fi

        # Max lease guard (120s max for background tasks to avoid wedging)
        if [ "$cur_prio" -lt "$IPC_PRIO_INTERACTIVE" ] && [ $((now - acq_ts)) -gt 120 ]; then
            jq -nc --arg pid "$my_pid" --argjson prio "$prio" --arg task "$task_name" --argjson now "$now" \
               '{holder_pid: ($pid|tonumber), priority: $prio, task_name: $task, acquired_at: $now}' > "$lease_file"
            return 0
        fi

        return 1
    fi

    # Unclaimed lease
    jq -nc --arg pid "$my_pid" --argjson prio "$prio" --arg task "$task_name" --argjson now "$now" \
       '{holder_pid: ($pid|tonumber), priority: $prio, task_name: $task, acquired_at: $now}' > "$lease_file"
    return 0
}

ipc_release_inference_lease() {
    local task_name="${1:-}"
    local slot_dir
    slot_dir=$(ipc_inference_slot_dir)
    local lease_file="$slot_dir/lease.json"
    local lock_file="$slot_dir/lease.lock"

    [ -f "$lease_file" ] || return 0
    _ipc_with_lock "$lock_file" _ipc_do_release_lease "$lease_file" "$task_name"
    return $?
}

_ipc_do_release_lease() {
    local lease_file="$1" task_name="$2"
    [ -f "$lease_file" ] || return 0
    local cur_pid cur_task
    cur_pid=$(jq -r '.holder_pid // empty' "$lease_file" 2>/dev/null)
    cur_task=$(jq -r '.task_name // ""' "$lease_file" 2>/dev/null)
    local my_pid="${BASHPID:-$$}"

    if [ -z "$task_name" ] || [ "$cur_task" = "$task_name" ] || [ "$cur_pid" = "$my_pid" ] || ! kill -0 "$cur_pid" 2>/dev/null; then
        rm -f "$lease_file" 2>/dev/null || true
    fi
    return 0
}
