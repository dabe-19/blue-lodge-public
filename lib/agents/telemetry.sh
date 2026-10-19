#!/bin/bash
# ── George: Sovereign Telemetry, Anomaly Interception & Incident Ring ─
# Provides zero-overhead, pure POSIX bash telemetry monitoring over
# active agent tasks, tool failures, broken pipes, and runtime script errors.
#
# Ring Architecture:
#   Active Tasks:     .george/telemetry/active/<task_uuid>.json
#   Active Events:    .george/telemetry/active/<task_uuid>.events.jsonl
#   Preserved Dossier:.george/telemetry/incidents/<incident_id>/
#   Archived Tasks:   .george/telemetry/archive/<date>/
#
# Anomaly Classes:
#   Class 1: SHELL_RUNTIME_ERROR (unbound vars, script exit != 0, missing file traps)
#   Class 2: CAPABILITY_DEFICIT   (missing tools, module errors, empty turn circuit breaks)
#   Class 3: PROCESS_STALL        (hung turns, broken pipes, severed PTY pop-up windows)

[ -n "${_LIB_TELEMETRY_LOADED:-}" ] && return 0; _LIB_TELEMETRY_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
TELEMETRY_DIR="${TELEMETRY_DIR:-$GEORGE_DIR/telemetry}"
TELEMETRY_ACTIVE_DIR="${TELEMETRY_DIR}/active"
TELEMETRY_INCIDENTS_DIR="${TELEMETRY_DIR}/incidents"
TELEMETRY_ARCHIVE_DIR="${TELEMETRY_DIR}/archive"

# Secret redaction pattern (API keys, passwords, tokens)
_TELEMETRY_SECRET_PATTERN='(ghp_[A-Za-z0-9]+|sk-[A-Za-z0-9]+|bearer [A-Za-z0-9_.-]+|password=[^&[:space:]]+|token=[^&[:space:]]+|access_token=[^&[:space:]]+)'

telemetry_init() {
    mkdir -p "$TELEMETRY_ACTIVE_DIR" "$TELEMETRY_INCIDENTS_DIR" "$TELEMETRY_ARCHIVE_DIR" 2>/dev/null || true
}

# Redact sensitive secrets from telemetry strings
telemetry_redact() {
    local text="$1"
    if [ -n "$text" ]; then
        echo "$text" | sed -E "s/$_TELEMETRY_SECRET_PATTERN/[REDACTED_SECRET]/gI"
    else
        echo ""
    fi
}

# Deterministic Error Fingerprint Hash
# Returns a 12-char SHA256 signature: sha256(class + subsystem + normalized_fault)
telemetry_fingerprint() {
    local err_class="$1"
    local subsystem="$2"
    local fault="$3"

    # Normalize fault: lowercase, strip line numbers, dates, memory addresses, and paths
    local norm_fault
    norm_fault=$(echo "$fault" | tr '[:upper:]' '[:lower:]' | \
        sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}//g' | \
        sed -E 's/0x[0-9a-fA-F]+//g' | \
        sed -E 's/\/home\/[^ :"]+//g' | \
        sed -E 's/\/tmp\/[^ :"]+//g' | \
        sed -E 's/line [0-9]+/line N/g' | \
        sed -E 's/[0-9]+s\b/Ns/g' | \
        sed -E 's/turn [0-9]+\/[0-9]+/turn N\/M/g' | \
        tr -dc 'a-z0-9_ ' | tr -s ' ')

    local raw="${err_class}:${subsystem}:${norm_fault}"
    local hash=""
    if command -v sha256sum &>/dev/null; then
        hash=$(printf '%s' "$raw" | sha256sum | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        hash=$(printf '%s' "$raw" | shasum -a 256 | awk '{print $1}')
    elif command -v openssl &>/dev/null; then
        hash=$(printf '%s' "$raw" | openssl dgst -sha256 | awk '{print $NF}')
    elif command -v cksum &>/dev/null && cksum -a sha256 </dev/null &>/dev/null; then
        hash=$(printf '%s' "$raw" | cksum -a sha256 | awk '{print $1}')
    else
        local py_bin="${GEORGE_PYTHON:-python3}"
        if command -v "$py_bin" &>/dev/null; then
            hash=$("$py_bin" -c 'import sys, hashlib; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$raw" 2>/dev/null || echo "000000000000")
        else
            hash="000000000000"
        fi
    fi
    echo "${hash:0:12}"
}

# ── 1. Task Lifecycle Registration ───────────────────────────────────

# Starts and registers an active task
# Usage: telemetry_task_start "task_id" "type" "workdir" [session_log] [pty_pid] [transcript_file]
telemetry_task_start() {
    telemetry_init
    local tid="$1"
    local ttype="${2:-general}"
    local twkdir="${3:-$PWD}"
    local tlog="${4:-}"
    local tpty="${5:-}"
    local ttranscript="${6:-}"

    local now
    now=$(date +%s)
    local active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
    local tparent_id="${GEORGE_PARENT_TASK_ID:-}"
    local tparent_pid="${GEORGE_PARENT_PID:-0}"

    # Assemble task envelope
    jq -n \
        --arg id "$tid" \
        --arg type "$ttype" \
        --arg workdir "$twkdir" \
        --arg log "$tlog" \
        --argjson pty "${tpty:-0}" \
        --argjson pid "${BASHPID:-$$}" \
        --arg transcript "$ttranscript" \
        --argjson now "$now" \
        --arg parent_id "$tparent_id" \
        --argjson parent_pid "${tparent_pid:-0}" \
        '{
            task_id: $id,
            type: $type,
            pid: $pid,
            parent_task_id: (if $parent_id != "" then $parent_id else null end),
            parent_pid: (if $parent_pid > 0 then $parent_pid else null end),
            pty_pid: $pty,
            workdir: $workdir,
            log_file: $log,
            transcript_file: $transcript,
            status: "RUNNING",
            turn: 0,
            max_turns: 200,
            heartbeat_ts: $now,
            started_ts: $now,
            last_tool: "",
            failure_count: 0,
            consecutive_failures: 0,
            anomalies_count: 0
        }' > "$active_file" 2>/dev/null || true

    echo "$tid"
}

# Updates heartbeat timestamp, current turn, and last invoked tool
# Usage: telemetry_task_heartbeat "task_id" "turn" [last_tool] [max_turns] [context_tokens] [compaction_tokens] [context_limit]
telemetry_task_heartbeat() {
    local tid="$1"
    local turn="${2:-0}"
    local tool="${3:-}"
    local max_t="${4:-}"
    local ctx_tok="${5:-0}"
    local comp_tok="${6:-0}"
    local ctx_lim="${7:-0}"

    local active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
    [ ! -f "$active_file" ] && return 0

    local now
    now=$(date +%s)

    local pct=0
    if [ "${comp_tok:-0}" -gt 0 ] && [ "${ctx_tok:-0}" -gt 0 ]; then
        pct=$(( ctx_tok * 100 / comp_tok ))
        [ "$pct" -gt 100 ] && pct=100
    fi

    local tmp="${active_file}.tmp.$$"
    jq --argjson now "$now" --argjson t "$turn" --arg tl "$tool" \
       --argjson mt "${max_t:-0}" --argjson ctok "${ctx_tok:-0}" \
       --argjson comptok "${comp_tok:-0}" --argjson clim "${ctx_lim:-0}" \
       --argjson cpct "$pct" '
        .heartbeat_ts = $now | .turn = $t | .last_tool = $tl |
        (if $mt > 0 then .max_turns = $mt else . end) |
        (if $ctok > 0 then .context_tokens = $ctok else . end) |
        (if $comptok > 0 then .compaction_tokens = $comptok else . end) |
        (if $clim > 0 then .context_limit = $clim else . end) |
        (if $comptok > 0 then .compaction_pct = $cpct else . end)
    ' "$active_file" > "$tmp" 2>/dev/null && mv "$tmp" "$active_file"
}

# Concludes a task and moves its descriptor to the date-based archive
# Usage: telemetry_task_end "task_id" [exit_code] [status_label]
telemetry_task_end() {
    local tid="$1"
    local exit_code="${2:-0}"
    local status="${3:-}"

    local active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
    [ ! -f "$active_file" ] && return 0

    local now
    now=$(date +%s)
    local date_slug
    date_slug=$(date '+%Y-%m-%d')
    local archive_day_dir="$TELEMETRY_ARCHIVE_DIR/$date_slug"
    mkdir -p "$archive_day_dir" 2>/dev/null || true

    local final_status="COMPLETED"
    [ "$exit_code" -ne 0 ] && final_status="FAILED"
    [ -n "$status" ] && final_status="$status"

    local tmp="${active_file}.tmp.$$"
    jq --argjson now "$now" --argjson ec "$exit_code" --arg st "$final_status" \
        '.status = $st | .exit_code = $ec | .ended_ts = $now' \
        "$active_file" > "$tmp" 2>/dev/null && mv "$tmp" "$archive_day_dir/${tid}.json" 2>/dev/null || true

    rm -f "$active_file" 2>/dev/null || true

    # Move active events log to archive as well
    local events_file="$TELEMETRY_ACTIVE_DIR/${tid}.events.jsonl"
    if [ -f "$events_file" ]; then
        mv "$events_file" "$archive_day_dir/${tid}.events.jsonl" 2>/dev/null || true
    fi
}

# ── 2. Structured Anomaly Logging ────────────────────────────────────

# Logs an anomaly event into the active task's event stream
# Usage: telemetry_record_anomaly "task_id" "class" "subsystem" "message" [context_json]
telemetry_record_anomaly() {
    local tid="$1"
    local aclass="$2"
    local subsys="$3"
    local raw_msg="$4"
    local ctx_json="${5:-"{}"}"

    telemetry_init
    local sanitized_msg
    sanitized_msg=$(telemetry_redact "$raw_msg")

    local fp
    fp=$(telemetry_fingerprint "$aclass" "$subsys" "$sanitized_msg")

    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s)
    local now_ts
    now_ts=$(date +%s)

    local event_json
    event_json=$(jq -nc \
        --arg tid "$tid" \
        --arg ts "$now_iso" \
        --argjson epoch "$now_ts" \
        --arg cls "$aclass" \
        --arg sub "$subsys" \
        --arg msg "$sanitized_msg" \
        --arg fp "$fp" \
        --argjson ctx "$ctx_json" \
        '{
            task_id: $tid,
            timestamp: $ts,
            epoch: $epoch,
            class: $cls,
            subsystem: $sub,
            fingerprint: $fp,
            message: $msg,
            context: $ctx
        }')

    # Append to active task event stream
    local events_file="$TELEMETRY_ACTIVE_DIR/${tid}.events.jsonl"
    echo "$event_json" >> "$events_file" 2>/dev/null || true

    # Update active task failure metrics
    local active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
    if [ -f "$active_file" ]; then
        local tmp="${active_file}.tmp.$$"
        jq '.anomalies_count = (.anomalies_count + 1) | .consecutive_failures = (.consecutive_failures + 1) | .failure_count = (.failure_count + 1)' \
            "$active_file" > "$tmp" 2>/dev/null && mv "$tmp" "$active_file"
    fi

    telemetry_bus_bridge "$tid" "$aclass" "$subsys" "$sanitized_msg" "$fp"

    echo "$fp"
}

# ── 2a. Telemetry -> Event Bus Bridge (refinement P1/1.3) ────────────
# Maps anomaly classes onto contracted bus events:
#   CIRCUIT_BREAKER_PERTURBATION -> agent.circuit_breaker {kind: perturbation, breaker_class: <subsystem>}
#   CIRCUIT_BREAKER              -> agent.circuit_breaker {kind: trip, breaker_class: <prefix of message>}
#   PROCESS_STALL                -> agent.circuit_breaker {kind: trip, breaker_class: EMPTY_TURNS|PROCESS_STALL}
#   anything else                -> agent.tool_failure    {tool: <subsystem>, error_class: <class>}
# Emission runs in the background unless TELEMETRY_BUS_SYNC=1; TELEMETRY_BUS_BRIDGE=0 disables.
# Usage: telemetry_bus_bridge <session_id> <class> <subsystem> <sanitized_msg> <fingerprint>
telemetry_bus_bridge() {
    [ "${TELEMETRY_BUS_BRIDGE:-1}" = "0" ] && return 0
    local sid="${1:-unknown}" cls="$2" sub="$3" msg="${4:0:300}" fp="$5"
    if ! declare -f event_bus_emit &>/dev/null; then
        [ -f "$LODGE_DIR/lib/ipc/event_bus.sh" ] && source "$LODGE_DIR/lib/ipc/event_bus.sh" >/dev/null 2>&1
        declare -f event_bus_emit &>/dev/null || return 0
    fi
    local etype payload bclass kind
    case "$cls" in
        CIRCUIT_BREAKER_PERTURBATION)
            etype="agent.circuit_breaker"; kind="perturbation"; bclass="${sub:-UNKNOWN}" ;;
        CIRCUIT_BREAKER)
            etype="agent.circuit_breaker"; kind="trip"
            bclass="${msg%%:*}"
            [[ "$bclass" =~ ^[A-Za-z0-9_]{2,64}$ ]] || bclass="UNSPECIFIED" ;;
        PROCESS_STALL)
            etype="agent.circuit_breaker"; kind="trip"
            if [[ "$msg" == *"empty turns"* ]]; then bclass="EMPTY_TURNS"; else bclass="PROCESS_STALL"; fi ;;
        *)
            etype="agent.tool_failure" ;;
    esac
    if [ "$etype" = "agent.circuit_breaker" ]; then
        payload=$(jq -nc --arg s "$sid" --arg b "$bclass" --arg k "$kind" --arg m "$msg" --arg f "$fp" \
            '{session_id:$s, breaker_class:$b, kind:$k, message:$m, fingerprint:$f}')
    else
        payload=$(jq -nc --arg s "$sid" --arg t "${sub:-unknown}" --arg c "${cls:-UNKNOWN}" --arg m "$msg" --arg f "$fp" \
            '{session_id:$s, tool:$t, error_class:$c, message:$m, fingerprint:$f}')
    fi
    [ -n "$payload" ] || return 0
    if [ "${TELEMETRY_BUS_SYNC:-0}" = "1" ]; then
        event_bus_emit "$etype" "$payload" "telemetry" >/dev/null 2>&1 || true
    else
        ( event_bus_emit "$etype" "$payload" "telemetry" >/dev/null 2>&1 ) &
        disown $! 2>/dev/null || true
    fi
    return 0
}

# Resets the consecutive failure counter for a task after a successful tool action
telemetry_reset_consecutive_failures() {
    local tid="$1"
    local active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
    if [ -f "$active_file" ]; then
        local tmp="${active_file}.tmp.$$"
        jq '.consecutive_failures = 0' "$active_file" > "$tmp" 2>/dev/null && mv "$tmp" "$active_file"
    fi
}

# ── 2b. Asynchronous Tool Call Telemetry & Flow Tracking ─────────────

# Records tool invocation start in task telemetry ring
# Usage: telemetry_tool_start "task_id" "call_id" "tool_name" [args_json] [channel_id]
telemetry_tool_start() {
    local tid="${1:-standalone}"
    local cid="$2"
    local tool="$3"
    local args="${4:-"{}"}"
    local chan="${5:-}"

    telemetry_init
    local now_iso now_ts
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s)
    now_ts=$(date +%s)

    local sanitized_args
    sanitized_args=$(telemetry_redact "$args")

    local ev_json
    ev_json=$(jq -nc \
        --arg tid "$tid" \
        --arg cid "$cid" \
        --arg tool "$tool" \
        --arg ts "$now_iso" \
        --argjson epoch "$now_ts" \
        --arg chan "$chan" \
        --arg args "$sanitized_args" \
        '{
            task_id: $tid,
            event_type: "TOOL_START",
            call_id: $cid,
            tool: $tool,
            channel: $chan,
            timestamp: $ts,
            epoch: $epoch,
            args: $args
        }')

    local events_file="$TELEMETRY_ACTIVE_DIR/${tid}.events.jsonl"
    echo "$ev_json" >> "$events_file" 2>/dev/null || true

    local active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
    if [ -f "$active_file" ]; then
        local tmp="${active_file}.tmp.$$"
        jq --arg cid "$cid" --arg tool "$tool" --argjson epoch "$now_ts" --arg chan "$chan" '
            .active_tools = (.active_tools // {}) |
            .active_tools[$cid] = {
                tool: $tool,
                start_epoch: $epoch,
                status: "RUNNING",
                channel: $chan,
                percent: 0,
                message: "Dispatched"
            }
        ' "$active_file" > "$tmp" 2>/dev/null && mv "$tmp" "$active_file"
    fi
}

# Records intermediate progress for an active asynchronous tool call
# Usage: telemetry_tool_progress "task_id" "call_id" "percent" "message" [extra_json]
telemetry_tool_progress() {
    local tid="${1:-standalone}"
    local cid="$2"
    local pct="${3:-0}"
    local msg="$4"
    local extra="${5:-"{}"}"

    telemetry_init
    local now_iso now_ts
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s)
    now_ts=$(date +%s)

    local sanitized_msg
    sanitized_msg=$(telemetry_redact "$msg")

    local ev_json
    ev_json=$(jq -nc \
        --arg tid "$tid" \
        --arg cid "$cid" \
        --argjson pct "$pct" \
        --arg msg "$sanitized_msg" \
        --arg ts "$now_iso" \
        --argjson epoch "$now_ts" \
        --argjson extra "$extra" \
        '{
            task_id: $tid,
            event_type: "TOOL_PROGRESS",
            call_id: $cid,
            percent: $pct,
            message: $msg,
            timestamp: $ts,
            epoch: $epoch,
            extra: $extra
        }')

    local events_file="$TELEMETRY_ACTIVE_DIR/${tid}.events.jsonl"
    echo "$ev_json" >> "$events_file" 2>/dev/null || true

    local active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
    if [ -f "$active_file" ]; then
        local tmp="${active_file}.tmp.$$"
        jq --arg cid "$cid" --argjson pct "$pct" --arg msg "$sanitized_msg" --argjson epoch "$now_ts" '
            if .active_tools[$cid] then
                .active_tools[$cid].percent = $pct |
                .active_tools[$cid].message = $msg |
                .active_tools[$cid].last_progress_epoch = $epoch
            else . end
        ' "$active_file" > "$tmp" 2>/dev/null && mv "$tmp" "$active_file"
    fi
}

# Records completion or failure of a tool call in task telemetry
# Usage: telemetry_tool_end "task_id" "call_id" "tool_name" "exit_code" "duration_ms" "size_bytes" [payload_ref]
telemetry_tool_end() {
    local tid="${1:-standalone}"
    local cid="$2"
    local tool="$3"
    local ec="${4:-0}"
    local dur="${5:-0}"
    local bytes="${6:-0}"
    local pref="${7:-}"

    telemetry_init
    local now_iso now_ts
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s)
    now_ts=$(date +%s)

    local status="COMPLETED"
    [ "$ec" -ne 0 ] && status="FAILED"

    local ev_json
    ev_json=$(jq -nc \
        --arg tid "$tid" \
        --arg cid "$cid" \
        --arg tool "$tool" \
        --arg st "$status" \
        --argjson ec "$ec" \
        --argjson dur "$dur" \
        --argjson bytes "$bytes" \
        --arg pref "$pref" \
        --arg ts "$now_iso" \
        --argjson epoch "$now_ts" \
        '{
            task_id: $tid,
            event_type: "TOOL_END",
            call_id: $cid,
            tool: $tool,
            status: $st,
            exit_code: $ec,
            duration_ms: $dur,
            size_bytes: $bytes,
            payload_ref: $pref,
            timestamp: $ts,
            epoch: $epoch
        }')

    local events_file="$TELEMETRY_ACTIVE_DIR/${tid}.events.jsonl"
    echo "$ev_json" >> "$events_file" 2>/dev/null || true

    local active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
    if [ -f "$active_file" ]; then
        local tmp="${active_file}.tmp.$$"
        jq --arg cid "$cid" --arg st "$status" --argjson ec "$ec" --argjson dur "$dur" --argjson bytes "$bytes" '
            .active_tools = (.active_tools // {}) |
            del(.active_tools[$cid]) |
            .completed_tools_count = ((.completed_tools_count // 0) + 1)
        ' "$active_file" > "$tmp" 2>/dev/null && mv "$tmp" "$active_file"
    fi
}

# ── 3. Diagnostic Incident Preservation ──────────────────────────────

# Snapshots an active task's full execution state, logs, transcripts, and artifacts
# into .george/telemetry/incidents/<incident_id>/
# Usage: telemetry_preserve_incident "task_id" "class" "subsystem" "summary" [extra_artifact_dir]
telemetry_preserve_incident() {
    local tid="$1"
    local aclass="$2"
    local subsys="$3"
    local summary="$4"
    local extra_dir="${5:-}"

    telemetry_init
    local now_ts
    now_ts=$(date +%s)
    local incident_id="inc_${tid}_${now_ts}"
    local inc_dir="$TELEMETRY_INCIDENTS_DIR/$incident_id"
    mkdir -p "$inc_dir/artifacts" 2>/dev/null || true

    local active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
    local task_info="{}"
    [ -f "$active_file" ] && task_info=$(cat "$active_file")

    local tlog ttranscript tworkdir
    tlog=$(echo "$task_info" | jq -r '.log_file // empty' 2>/dev/null)
    ttranscript=$(echo "$task_info" | jq -r '.transcript_file // empty' 2>/dev/null)
    tworkdir=$(echo "$task_info" | jq -r '.workdir // empty' 2>/dev/null)

    # 1. Copy active descriptor & event stream
    [ -f "$active_file" ] && cp "$active_file" "$inc_dir/task_envelope.json" 2>/dev/null || true
    local events_file="$TELEMETRY_ACTIVE_DIR/${tid}.events.jsonl"
    [ -f "$events_file" ] && cp "$events_file" "$inc_dir/trace.jsonl" 2>/dev/null || true

    # 2. Copy transcript if available
    if [ -n "$ttranscript" ] && [ -f "$ttranscript" ]; then
        cp "$ttranscript" "$inc_dir/transcript.md" 2>/dev/null || true
    elif [ -n "${_TRANSCRIPT_FILE:-}" ] && [ -f "$_TRANSCRIPT_FILE" ]; then
        cp "$_TRANSCRIPT_FILE" "$inc_dir/transcript.md" 2>/dev/null || true
    fi

    # 3. Copy log file
    if [ -n "$tlog" ] && [ -f "$tlog" ]; then
        tail -n 200 "$tlog" > "$inc_dir/stderr.log" 2>/dev/null || true
    fi

    # 4. Copy workspace artifacts if provided (scoped strictly to artifacts directory)
    if [ -n "$extra_dir" ] && [ -d "$extra_dir/artifacts" ]; then
        cp -r "$extra_dir/artifacts"/* "$inc_dir/artifacts/" 2>/dev/null || true
    elif [ -n "$extra_dir" ] && [[ "$extra_dir" == */artifacts* ]] && [ -d "$extra_dir" ]; then
        cp -r "$extra_dir"/* "$inc_dir/artifacts/" 2>/dev/null || true
    elif [ -n "$tworkdir" ] && [ -d "$tworkdir/artifacts" ]; then
        cp -r "$tworkdir/artifacts"/* "$inc_dir/artifacts/" 2>/dev/null || true
    fi
    # Exclude models, gguf, bin, and heavy weights from incident preservation to prevent disk bloat
    rm -rf "$inc_dir/artifacts/models" "$inc_dir/artifacts"/*.gguf "$inc_dir/artifacts"/*.bin 2>/dev/null || true

    # 5. Compute Error Fingerprint
    local fp
    fp=$(telemetry_fingerprint "$aclass" "$subsys" "$summary")

    # 6. Generate Incident Manifest
    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s)
    jq -n \
        --arg inc_id "$incident_id" \
        --arg tid "$tid" \
        --arg ts "$now_iso" \
        --arg cls "$aclass" \
        --arg sub "$subsys" \
        --arg sum "$summary" \
        --arg fp "$fp" \
        --arg inc_path "$inc_dir" \
        --arg trans_path "$inc_dir/transcript.md" \
        --arg trace_path "$inc_dir/trace.jsonl" \
        --arg log_path "$inc_dir/stderr.log" \
        '{
            incident_id: $inc_id,
            task_id: $tid,
            timestamp: $ts,
            class: $cls,
            subsystem: $sub,
            fingerprint: $fp,
            summary: $sum,
            incident_dir: $inc_path,
            transcript_file: $trans_path,
            trace_file: $trace_path,
            log_file: $log_path
        }' > "$inc_dir/manifest.json" 2>/dev/null || true

    echo "$inc_dir"
}

# ── 3b. Operational Failure Triage & Remediation ──────────────────────

# Triages an operational or runtime failure by:
# 1. Computing SHA256 error fingerprint.
# 2. Checking for existing open issue with the same fingerprint (deduplication).
# 3. Preserving an incident dossier with error traces and metadata.
# 4. Generating a tracked issue in .george/issues/
# 5. Enqueueing an autonomous remediation task in .george/remediation/queue/
# Usage: telemetry_triage_operational_failure "subsystem" "class" "title" "error_trace" [workdir] [transcript]
telemetry_triage_operational_failure() {
    local subsys="$1"
    local aclass="$2"
    local title="$3"
    local error_trace="$4"
    local workdir="${5:-$PWD}"
    local transcript="${6:-}"

    # RECURSION, SANDBOX & TEST GUARD:
    # Do NOT triage or spawn new issues if we are ALREADY running inside
    # an autonomous remediation task, or inside test fixtures, or inside a sandbox, or in /tmp!
    if [ "${_ALLOW_TEST_TRIAGE:-0}" -ne 1 ]; then
        if [ "${AGENT_SOVEREIGN_REMEDIATION:-0}" -eq 1 ] || \
           [ "${_LODGE_TESTING:-0}" -eq 1 ] || \
           [ "${LODGE_TEST_MODE:-0}" -eq 1 ] || \
           [ "${_IN_NOTIFICATION_TRIAGE:-0}" -eq 1 ] || \
           [[ "$workdir" == *"/tmp/"* ]] || \
           [[ "$workdir" == *".sandboxes/test_"* ]] || \
           [[ "$workdir" == *".sandboxes/qtest_"* ]] || \
           [[ "$PWD" == *"/tmp/"* ]]; then
            return 0
        fi
    fi

    telemetry_init
    local issues_dir="${GEORGE_CONFIG_DIR:-$PWD/.george}/issues"
    mkdir -p "$issues_dir" 2>/dev/null || true

    local sanitized_trace
    sanitized_trace=$(telemetry_redact "$error_trace")
    local fp
    fp=$(telemetry_fingerprint "$aclass" "$subsys" "$sanitized_trace")

    # Strict Deduplication check against all active and in-flight issues:
    # If ANY active issue with this fingerprint exists in .george/issues/, DO NOT create another issue!
    local existing_issue
    existing_issue=$(grep -l "\[fingerprint:${fp}\]" "$issues_dir"/*.md 2>/dev/null | head -n 1)
    if [ -n "$existing_issue" ] && [ -f "$existing_issue" ]; then
        declare -f ui_dim &>/dev/null && ui_dim "Operational failure already tracked in $(basename "$existing_issue") ($fp)" >&2
        echo "$existing_issue"
        return 0
    fi

    # Also check if already queued, in progress, or recently failed with this fingerprint
    local rem_base="${GEORGE_CONFIG_DIR:-$PWD/.george}/remediation"
    if [ -d "$rem_base" ]; then
        local fp_match
        fp_match=$(grep -l "\"fingerprint\": \"${fp}\"" "$rem_base"/queue/*.json "$rem_base"/in_progress/*.json "$rem_base"/failed/*.json 2>/dev/null | head -n 1)
        if [ -n "$fp_match" ] && [ -f "$fp_match" ]; then
            declare -f ui_dim &>/dev/null && ui_dim "Operational failure already has active remediation task: $(basename "$fp_match") ($fp)" >&2
            return 0
        fi
    fi

    # Snapshot incident
    local now_ts
    now_ts=$(date +%s)
    local task_id="op_${subsys}_${now_ts}"
    local inc_dir
    inc_dir=$(telemetry_preserve_incident "$task_id" "$aclass" "$subsys" "$title" "$workdir")

    # Save diagnostic error trace into incident dir
    if [ -n "$inc_dir" ] && [ -d "$inc_dir" ]; then
        echo "$sanitized_trace" > "$inc_dir/stderr.log" 2>/dev/null || true
    fi

    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s)
    local issue_file="$issues_dir/issue_${fp}_${now_ts}.md"

    local excerpt
    excerpt=$(echo "$sanitized_trace" | sed '/^[[:space:]]*$/d' | head -n 12)

    cat > "$issue_file" << EOF
# [Autonomous Telemetry Alert] ${title}

- **Subsystem:** \`${subsys}\`
- **Class:** \`${aclass}\`
- **Error Fingerprint:** [fingerprint:${fp}]
- **Timestamp:** ${now_iso}
- **Incident Dossier:** \`${inc_dir}\`
- **Workdir:** \`${workdir}\`

### Diagnostic Trace & Failure Evidence
\`\`\`
${excerpt}
\`\`\`

### Autonomous Remediation Objective
- **Target Component:** Subsystem \`${subsys}\`
- **Root Cause Investigation:** Diagnose why \`${title}\` failed during execution in \`${workdir}\`.
- **Resolution Criteria:** Patch the fault in the target module, ensure graceful error handling on missing resources, and verify fix with test harness.
EOF

    # Submit issue to Sovereign Gitea if online
    local gitea_num=""
    if ! declare -f gitea_is_online &>/dev/null; then
        [ -f "${LODGE_DIR:-$PWD}/lib/tools/mcp_server_gitea.sh" ] && source "${LODGE_DIR:-$PWD}/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
    fi
    if [ "${_LODGE_TESTING:-0}" -ne 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ] && declare -f gitea_is_online &>/dev/null && gitea_is_online; then
        local g_title="[Autonomous Telemetry Alert] ${title}"
        local g_body
        g_body=$(cat "$issue_file")
        local g_labels="autonomous-remediation,telemetry-alert,bug"
        local g_res
        g_res=$(gitea_issue_create "$g_title" "$g_body" "$g_labels" 2>/dev/null || true)
        gitea_num=$(echo "$g_res" | jq -r '.number // empty' 2>/dev/null || true)
        if [ -n "$gitea_num" ]; then
            echo "- **Gitea Issue:** #${gitea_num}" >> "$issue_file"
        fi
    fi

    # Enqueue remediation task (throttled to max 3 pending tasks)
    local q_id=""
    local q_dir="${GEORGE_DIR}/remediation/queue"
    local q_count=0
    [ -d "$q_dir" ] && q_count=$(ls -1 "$q_dir"/*.json 2>/dev/null | wc -l)
    if [ "$q_count" -ge 3 ]; then
        ui_warn "Remediation queue depth reached maximum (3 pending tasks). Triaging as standard issue without auto-remediation."
    else
        if declare -f remediation_queue_add &>/dev/null; then
            q_id=$(remediation_queue_add "$issue_file" "$inc_dir" "high" "$title" 2>/dev/null || true)
        else
            if [ -f "${LODGE_DIR:-$PWD}/lib/agents/remediation.sh" ]; then
                source "${LODGE_DIR:-$PWD}/lib/agents/remediation.sh" 2>/dev/null || true
                if declare -f remediation_queue_add &>/dev/null; then
                    q_id=$(remediation_queue_add "$issue_file" "$inc_dir" "high" "$title" 2>/dev/null || true)
                fi
            fi
        fi
    fi

    # Dispatch operator notification of enqueued failure
    if [ -n "$q_id" ]; then
        local notify_details="Operational failure detected and auto-enqueued for sovereign remediation.\nTitle: ${title}\nSubsystem: ${subsys}\nClass: ${aclass}"
        [ -n "$gitea_num" ] && notify_details+="\nGitea Issue: #${gitea_num}"
        if declare -f remediation_notify_dispatch &>/dev/null; then
            remediation_notify_dispatch "$q_id" "$issue_file" "QUEUED" "$notify_details" 2>/dev/null || true
        elif [ -f "${LODGE_DIR:-$PWD}/lib/agents/remediation.sh" ]; then
            source "${LODGE_DIR:-$PWD}/lib/agents/remediation.sh" 2>/dev/null || true
            if declare -f remediation_notify_dispatch &>/dev/null; then
                remediation_notify_dispatch "$q_id" "$issue_file" "QUEUED" "$notify_details" 2>/dev/null || true
            fi
        fi
    fi

    declare -f ui_warn &>/dev/null && ui_warn "Operational failure triaged & remediation queued: $(basename "$issue_file") (fp: $fp)" >&2
    echo "$issue_file"
}

# ── 4. Task Query Helpers ─────────────────────────────────────────────

telemetry_active_list() {
    telemetry_init
    local files
    files=("$TELEMETRY_ACTIVE_DIR"/*.json)
    if [ ! -e "${files[0]}" ]; then
        echo "[]"
        return 0
    fi
    jq -s '.' "${files[@]}" 2>/dev/null || echo "[]"
}

telemetry_incidents_list() {
    telemetry_init
    local manifests
    manifests=("$TELEMETRY_INCIDENTS_DIR"/*/manifest.json)
    if [ ! -e "${manifests[0]}" ]; then
        echo "[]"
        return 0
    fi
    jq -s 'sort_by(.timestamp) | reverse' "${manifests[@]}" 2>/dev/null || echo "[]"
}

# ── 5. Telemetry Garbage Collection & Incident Pruning ────────────────
# Prunes incident snapshots older than max_days (default: 7) or caps incident count.
# Usage: telemetry_gc [max_days] [max_incidents]
telemetry_gc() {
    telemetry_init
    local max_days="${1:-7}"
    local max_count="${2:-20}"
    local pruned=0

    # 1. Prune by age
    if [ -d "$TELEMETRY_INCIDENTS_DIR" ]; then
        local now_ts
        now_ts=$(date +%s)
        local cutoff_ts=$(( now_ts - (max_days * 86400) ))

        for inc_dir in "$TELEMETRY_INCIDENTS_DIR"/inc_*; do
            [ -d "$inc_dir" ] || continue
            local inc_ts="${inc_dir##*_}"
            if [[ "$inc_ts" =~ ^[0-9]+$ ]] && [ "$inc_ts" -lt "$cutoff_ts" ]; then
                rm -rf "$inc_dir" 2>/dev/null && ((pruned++)) || true
            fi
        done

        # 2. Prune by maximum count (keep newest max_count)
        local all_incidents=()
        while IFS= read -r inc; do
            [ -d "$inc" ] && all_incidents+=("$inc")
        done < <(ls -td "$TELEMETRY_INCIDENTS_DIR"/inc_* 2>/dev/null || true)

        if [ "${#all_incidents[@]}" -gt "$max_count" ]; then
            for (( i=max_count; i<${#all_incidents[@]}; i++ )); do
                rm -rf "${all_incidents[$i]}" 2>/dev/null && ((pruned++)) || true
            done
        fi
    fi

    # 3. Prune old active session records (> 24 hours)
    if [ -d "$TELEMETRY_ACTIVE_DIR" ]; then
        find "$TELEMETRY_ACTIVE_DIR" -type f -name "*.json" -mtime +1 -delete 2>/dev/null || true
    fi

    echo "$pruned"
}
