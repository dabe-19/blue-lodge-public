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
        tr -dc 'a-z0-9_ ' | tr -s ' ')

    local raw="${err_class}:${subsystem}:${norm_fault}"
    local hash=""
    if command -v sha256sum &>/dev/null; then
        hash=$(printf '%s' "$raw" | sha256sum | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        hash=$(printf '%s' "$raw" | shasum -a 256 | awk '{print $1}')
    elif command -v md5sum &>/dev/null; then
        hash=$(printf '%s' "$raw" | md5sum | awk '{print $1}')
    else
        hash=$(python3 -c "import hashlib; print(hashlib.sha256(b'''$raw''').hexdigest())" 2>/dev/null || echo "000000000000")
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

    # Assemble task envelope
    jq -n \
        --arg id "$tid" \
        --arg type "$ttype" \
        --arg workdir "$twkdir" \
        --arg log "$tlog" \
        --argjson pty "${tpty:-0}" \
        --argjson pid "$$" \
        --arg transcript "$ttranscript" \
        --argjson now "$now" \
        '{
            task_id: $id,
            type: $type,
            pid: $pid,
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
# Usage: telemetry_task_heartbeat "task_id" "turn" [last_tool] [max_turns]
telemetry_task_heartbeat() {
    local tid="$1"
    local turn="${2:-0}"
    local tool="${3:-}"
    local max_t="${4:-}"

    local active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
    [ ! -f "$active_file" ] && return 0

    local now
    now=$(date +%s)

    local tmp="${active_file}.tmp.$$"
    if [ -n "$max_t" ]; then
        jq --argjson now "$now" --argjson t "$turn" --arg tl "$tool" --argjson mt "$max_t" \
            '.heartbeat_ts = $now | .turn = $t | .last_tool = $tl | .max_turns = $mt' \
            "$active_file" > "$tmp" 2>/dev/null && mv "$tmp" "$active_file"
    else
        jq --argjson now "$now" --argjson t "$turn" --arg tl "$tool" \
            '.heartbeat_ts = $now | .turn = $t | .last_tool = $tl' \
            "$active_file" > "$tmp" 2>/dev/null && mv "$tmp" "$active_file"
    fi
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
    local ctx_json="${5:-{}}"

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
    event_json=$(jq -n \
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

    echo "$fp"
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

    # 4. Copy workspace artifacts if provided
    if [ -n "$extra_dir" ] && [ -d "$extra_dir" ]; then
        cp -r "$extra_dir"/* "$inc_dir/artifacts/" 2>/dev/null || true
    elif [ -n "$tworkdir" ] && [ -d "$tworkdir/artifacts" ]; then
        cp -r "$tworkdir/artifacts"/* "$inc_dir/artifacts/" 2>/dev/null || true
    fi

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

    telemetry_init
    local issues_dir="${GEORGE_CONFIG_DIR:-$PWD/.george}/issues"
    mkdir -p "$issues_dir" 2>/dev/null || true

    local sanitized_trace
    sanitized_trace=$(telemetry_redact "$error_trace")
    local fp
    fp=$(telemetry_fingerprint "$aclass" "$subsys" "$sanitized_trace")

    # Deduplication check against active issues
    local existing_issue
    existing_issue=$(grep -l "\[fingerprint:${fp}\]" "$issues_dir"/*.md 2>/dev/null | head -n 1)
    if [ -n "$existing_issue" ] && [ -f "$existing_issue" ]; then
        local rem_queue_dir="${GEORGE_CONFIG_DIR:-$PWD/.george}/remediation/queue"
        local is_queued
        is_queued=$(grep -l "\"fingerprint\": \"${fp}\"" "$rem_queue_dir"/*.json 2>/dev/null | head -n 1)
        if [ -n "$is_queued" ]; then
            declare -f ui_dim &>/dev/null && ui_dim "Operational failure already tracked & queued: $(basename "$existing_issue") ($fp)" >&2
            echo "$existing_issue"
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
${sanitized_trace}
\`\`\`

### Autonomous Remediation Objective
Diagnose the root cause of this failure. If this is a configuration or provider deficit, survey the environment and codebase for fallback adapters or disposable services, implement the necessary adaptation, and verify via automated tests.
EOF

    # Enqueue remediation task
    local q_id=""
    if declare -f remediation_queue_add &>/dev/null; then
        q_id=$(remediation_queue_add "$issue_file" "$inc_dir" "high" "$title" 2>/dev/null || true)
    else
        # If remediation.sh not yet sourced, try to source it
        if [ -f "${LODGE_DIR:-$PWD}/lib/remediation.sh" ]; then
            source "${LODGE_DIR:-$PWD}/lib/remediation.sh" 2>/dev/null || true
            if declare -f remediation_queue_add &>/dev/null; then
                q_id=$(remediation_queue_add "$issue_file" "$inc_dir" "high" "$title" 2>/dev/null || true)
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
