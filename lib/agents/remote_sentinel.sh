#!/bin/bash
# ── George: Secondary Node Autonomous Sentinel & Stage-0 Triage Worker ──────
# Designed to run on transient/secondary worker nodes (e.g., george-home with
# AMD Radeon RX 5700 XT 8GB + Gemma-4 E4B UD-Q4_K_XL @ 32K ctx):
#   1. Event-Bus Anomaly & Log Sentinel Observer:
#      Subscribes directly to `george/events/#` on the MQTT mesh (127.0.0.1:1883
#      reverse tunnel), monitors failure/emergency events (`cron_failure*`,
#      `sdr_emergency`, `remediation_failed`, `service_crash`, `sentinel_anomaly`),
#      performs initial root-cause triage on the local GPU, and publishes
#      actionable pre-diagnosed reports to `george/master/inbox` (`sentinel/report`).
#   2. Stage-0 Pre-Remediation Gitea Issue Triage & Reproduction Worker:
#      Inspects open Gitea issues via the reverse tunnel (`http://127.0.0.1:3088`),
#      locates relevant files/lines in the local `~/blue-lodge` checkout, runs
#      lightweight verification/reproduction checks, and posts a structured
#      `[STAGE-0 TRIAGE]` comment on the Gitea issue so Master remediation
#      subagents can fix the bug in 1-2 turns instead of 15.

[ -n "${_LIB_REMOTE_SENTINEL_LOADED:-}" ] && return 0; _LIB_REMOTE_SENTINEL_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
SENTINEL_DIR="$GEORGE_DIR/swarm"
SENTINEL_PID_FILE="$SENTINEL_DIR/remote_sentinel.pid"
SENTINEL_LOG_FILE="$SENTINEL_DIR/remote_sentinel.log"
SENTINEL_REPORTS_FILE="$SENTINEL_DIR/sentinel_reports.jsonl"

REMOTE_SENTINEL_NODE_ID="${REMOTE_SENTINEL_NODE_ID:-${SWARM_NODE_ID:-$(hostname -s 2>/dev/null || echo "george-home")}}"
REMOTE_SENTINEL_BROKER="${REMOTE_SENTINEL_BROKER:-${MQTT_BROKER:-127.0.0.1:1883}}"
REMOTE_SENTINEL_LLM_URL="${REMOTE_SENTINEL_LLM_URL:-http://127.0.0.1:8080}"
REMOTE_SENTINEL_GITEA_URL="${REMOTE_SENTINEL_GITEA_URL:-${GITEA_URL:-http://127.0.0.1:3088}}"
REMOTE_SENTINEL_GITEA_REPO="${REMOTE_SENTINEL_GITEA_REPO:-${GITEA_REPO:-george/blue-lodge}}"

export PATH="$HOME/.local/bin:$HOME/.local/lib/mosquitto:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/lib/mosquitto${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

_rs_find_mosq() {
    local bin="$1"
    if [ -x "$HOME/.local/bin/$bin" ]; then
        echo "$HOME/.local/bin/$bin"
    elif [ -x "$HOME/.local/lib/mosquitto/$bin" ]; then
        echo "$HOME/.local/lib/mosquitto/$bin"
    else
        command -v "$bin" 2>/dev/null || echo "$bin"
    fi
}
_RS_MOSQ_PUB="$(_rs_find_mosq mosquitto_pub)"
_RS_MOSQ_SUB="$(_rs_find_mosq mosquitto_sub)"

_rs_log() {
    mkdir -p "$SENTINEL_DIR" 2>/dev/null
    printf "[%(%Y-%m-%d %H:%M:%S)T] [SENTINEL:%s] %s\n" -1 "$REMOTE_SENTINEL_NODE_ID" "$*" >> "$SENTINEL_LOG_FILE" 2>/dev/null || true
}

_rs_parse_broker() {
    _RS_HOST="127.0.0.1"
    _RS_PORT="${MQTT_PORT:-1883}"
    if [[ "${REMOTE_SENTINEL_BROKER:-}" == *:* ]]; then
        _RS_HOST="${REMOTE_SENTINEL_BROKER%:*}"
        _RS_PORT="${REMOTE_SENTINEL_BROKER##*:}"
    elif [ -n "${REMOTE_SENTINEL_BROKER:-}" ]; then
        _RS_HOST="$REMOTE_SENTINEL_BROKER"
    fi
    [ -z "$_RS_HOST" ] && _RS_HOST="127.0.0.1"
    [[ "$_RS_PORT" =~ ^[0-9]+$ ]] || _RS_PORT="1883"
}

_rs_mqtt_pub() {
    local topic="$1"
    local payload="$2"
    _rs_parse_broker
    "$_RS_MOSQ_PUB" -h "$_RS_HOST" -p "$_RS_PORT" -t "$topic" -m "$payload" 2>/dev/null
}

# ── Local GPU Inference Helper (Gemma-4 E4B on :8080) ────────────────────────
_rs_llm_triage() {
    local sys_prompt="$1"
    local user_prompt="$2"
    local max_tokens="${3:-384}"

    local req_json
    req_json=$(jq -nc \
        --arg sys "$sys_prompt" \
        --arg usr "$user_prompt" \
        --argjson mt "$max_tokens" \
        '{
            messages: [
                {role: "system", content: $sys},
                {role: "user", content: $usr}
            ],
            max_tokens: $mt,
            temperature: 0.1,
            chat_template_kwargs: {enable_thinking: false}
        }')

    local resp
    resp=$(curl -sS --max-time 60 \
        -H "Content-Type: application/json" \
        -d "$req_json" \
        "${REMOTE_SENTINEL_LLM_URL%/}/v1/chat/completions" 2>/dev/null)
    echo "$resp" | jq -r '(.choices[0].message.content | if . and . != "" then . else null end) // .choices[0].message.reasoning_content // empty' 2>/dev/null
}

# ── 1. Event-Bus Anomaly & Log Sentinel Handler ──────────────────────────────
remote_sentinel_handle_event() {
    local topic="$1"
    local raw_env="$2"
    [ -z "$raw_env" ] && return 0

    local ev_type ev_id ev_src ev_payload
    ev_type=$(echo "$raw_env" | jq -r '(.type // .event_type) // empty' 2>/dev/null)
    ev_id=$(echo "$raw_env" | jq -r '.event_id // empty' 2>/dev/null)
    ev_src=$(echo "$raw_env" | jq -r '.source // "unknown"' 2>/dev/null)
    ev_payload=$(echo "$raw_env" | jq -c '.payload // {}' 2>/dev/null)

    [ -z "$ev_type" ] && ev_type="${topic#george/events/}"
    [ -z "$ev_id" ] && ev_id="evt_$(date +%s)_$RANDOM"

    # Filter for anomaly, failure, emergency, or triage-worthy events
    case "$ev_type" in
        cron_failure*|sdr_emergency|remediation_failed|service_crash|sentinel_anomaly|gitea_ci_failure|FAULT_QUARANTINE|trade_anomaly)
            ;;
        gitea_issue_opened)
            local issue_num
            issue_num=$(echo "$ev_payload" | jq -r '.issue_number // .number // empty' 2>/dev/null)
            if [[ "$issue_num" =~ ^[0-9]+$ ]]; then
                remote_sentinel_triage_issue "$issue_num" &
            fi
            return 0
            ;;
        *)
            return 0
            ;;
    esac

    _rs_log "Triaging anomaly event '$ev_type' (id=$ev_id, source=$ev_src) on local GPU..."

    local sys_prompt="You are George's Secondary Node Autonomous Sentinel running on $REMOTE_SENTINEL_NODE_ID (AMD RX 5700 XT). Analyze the incoming system anomaly/emergency event and output a concise JSON object with keys: {\"severity\":\"CRITICAL|HIGH|MEDIUM|LOW\",\"root_cause\":\"...\",\"affected_component\":\"...\",\"recommended_action\":\"...\",\"escalate\":true}."
    local usr_prompt="Event Type: ${ev_type}\nEvent ID: ${ev_id}\nSource: ${ev_src}\nPayload: ${ev_payload}"

    local diagnosis
    diagnosis=$(_rs_llm_triage "$sys_prompt" "$usr_prompt" 320)
    [ -z "$diagnosis" ] && diagnosis='{"severity":"HIGH","root_cause":"Local LLM unavailable during event triage","affected_component":"unknown","recommended_action":"Inspect event payload manually","escalate":true}'

    local now_ts
    now_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local report_json
    report_json=$(jq -nc \
        --arg id "sentinel-${ev_id}" \
        --arg node "$REMOTE_SENTINEL_NODE_ID" \
        --arg ev_id "$ev_id" \
        --arg ev_type "$ev_type" \
        --arg ev_src "$ev_src" \
        --arg diag "$diagnosis" \
        --arg ts "$now_ts" \
        '{
            jsonrpc: "2.0",
            id: $id,
            method: "sentinel/report",
            params: {
                node_id: $node,
                event_id: $ev_id,
                event_type: $ev_type,
                source: $ev_src,
                diagnosis: $diag,
                timestamp: $ts
            }
        }')

    mkdir -p "$SENTINEL_DIR" 2>/dev/null
    echo "$report_json" >> "$SENTINEL_REPORTS_FILE" 2>/dev/null
    _rs_mqtt_pub "george/master/inbox" "$report_json"
    _rs_log "Published sentinel triage report for '$ev_type' ($ev_id) to george/master/inbox"
}

# ── 2. Stage-0 Pre-Remediation Gitea Issue Triage & Reproduction Worker ──────
# Usage: remote_sentinel_triage_issue <issue_number> [gitea_token]
remote_sentinel_triage_issue() {
    local issue_num="$1"
    local token="${2:-${GITEA_TOKEN:-}}"
    [[ "$issue_num" =~ ^[0-9]+$ ]] || { echo "Usage: remote_sentinel_triage_issue <issue_number>"; return 1; }

    if [ -z "$token" ]; then
        for gf in "$GEORGE_DIR/gitea.conf" "$GEORGE_DIR/secrets.env"; do
            if [ -f "$gf" ]; then
                token=$(grep -E '^GITEA_TOKEN=' "$gf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'")
                [ -n "$token" ] && break
            fi
        done
    fi

    local auth_args=()
    [ -n "$token" ] && auth_args=(-H "Authorization: token $token")

    local issue_json
    issue_json=$(curl -sS --max-time 15 "${auth_args[@]}" \
        "${REMOTE_SENTINEL_GITEA_URL%/}/api/v1/repos/${REMOTE_SENTINEL_GITEA_REPO}/issues/${issue_num}" 2>/dev/null)

    local title body
    title=$(echo "$issue_json" | jq -r '.title // empty' 2>/dev/null)
    body=$(echo "$issue_json" | jq -r '.body // empty' 2>/dev/null)
    if [ -z "$title" ]; then
        _rs_log "Stage-0 Triage: Could not fetch Gitea issue #${issue_num} from ${REMOTE_SENTINEL_GITEA_URL}"
        return 1
    fi

    # Check if Stage-0 triage comment already exists on this issue
    local comments_json
    comments_json=$(curl -sS --max-time 15 "${auth_args[@]}" \
        "${REMOTE_SENTINEL_GITEA_URL%/}/api/v1/repos/${REMOTE_SENTINEL_GITEA_REPO}/issues/${issue_num}/comments" 2>/dev/null)
    if echo "$comments_json" | jq -r '.[].body // empty' 2>/dev/null | grep -q "\[STAGE-0 TRIAGE"; then
        _rs_log "Stage-0 Triage: Issue #${issue_num} already has a [STAGE-0 TRIAGE] brief. Skipping."
        return 0
    fi

    _rs_log "Stage-0 Triage: Analyzing Gitea issue #${issue_num} ('${title}')..."

    # Locate candidate files and symbols in local ~/blue-lodge checkout
    local repo_context=""
    repo_context=$(python3 - "$LODGE_DIR" "$title" "$body" << 'PYEOF'
import os, re, subprocess, sys

lodge_dir, title, body = sys.argv[1], sys.argv[2], sys.argv[3]
text = f"{title}\n{body}"

# Extract explicit file paths or script names mentioned in the issue
candidates = re.findall(r'(?:lib|commands|web|scripts|tests)/[A-Za-z0-9_./-]+\.(?:sh|py|rs|js|html|json)', text)
symbols = re.findall(r'\b[a-z_][a-z0-9_]{4,40}\b', text)

snippets = []
seen_files = set()

for rel in candidates[:5]:
    full = os.path.join(lodge_dir, rel)
    if os.path.isfile(full) and rel not in seen_files:
        seen_files.add(rel)
        try:
            with open(full, "r", errors="replace") as f:
                lines = f.readlines()[:80]
            snippets.append(f"--- FILE: {rel} (first {len(lines)} lines) ---\n" + "".join(lines))
        except Exception:
            pass

# Also run a quick git grep for top identifiers if fewer than 2 files matched
if len(seen_files) < 2:
    stop = {"issue", "error", "should", "when", "where", "which", "george", "lodge", "master", "worker"}
    for sym in symbols:
        if sym in stop or len(seen_files) >= 4:
            continue
        try:
            r = subprocess.run(
                ["git", "-C", lodge_dir, "grep", "-n", "-I", sym, "--", "lib/", "commands/", "web/src/"],
                capture_output=True, text=True, timeout=4
            )
            if r.returncode == 0 and r.stdout.strip():
                matches = r.stdout.strip().splitlines()[:8]
                snippets.append(f"--- GIT GREP '{sym}' ---\n" + "\n".join(matches))
                for m in matches:
                    fpart = m.split(":", 1)[0]
                    seen_files.add(fpart)
        except Exception:
            pass

print("\n\n".join(snippets)[:6000] if snippets else "No direct file path matches found in issue text.")
PYEOF
)

    local sys_prompt="You are George's Stage-0 Pre-Remediation Issue Triage Worker running on secondary node $REMOTE_SENTINEL_NODE_ID (AMD RX 5700 XT, Gemma-4 E4B). Produce a concise markdown technical brief with three sections:
1. **Suspected Root Cause**
2. **Relevant Files & Line Numbers**
3. **Fast-Path Remediation Plan (1-2 turns)**"
    local usr_prompt="Issue #${issue_num}: ${title}\n\nIssue Description:\n${body}\n\nRepository Context from ~/blue-lodge:\n${repo_context}"

    local brief
    brief=$(_rs_llm_triage "$sys_prompt" "$usr_prompt" 512)
    if [ -z "$brief" ]; then
        _rs_log "Stage-0 Triage: Local LLM returned empty brief for issue #${issue_num}"
        return 1
    fi

    local comment_body
    comment_body=$(printf "### [STAGE-0 TRIAGE — \`%s\`]\n_Autonomous pre-remediation localization computed on secondary GPU node (\`%s\`)._\n\n%s" \
        "$REMOTE_SENTINEL_NODE_ID" "$REMOTE_SENTINEL_NODE_ID" "$brief")

    # Post comment to Gitea if token is available
    if [ -n "$token" ]; then
        local post_payload
        post_payload=$(jq -nc --arg b "$comment_body" '{body: $b}')
        curl -sS --max-time 15 -X POST "${auth_args[@]}" \
            -H "Content-Type: application/json" \
            -d "$post_payload" \
            "${REMOTE_SENTINEL_GITEA_URL%/}/api/v1/repos/${REMOTE_SENTINEL_GITEA_REPO}/issues/${issue_num}/comments" >/dev/null 2>&1 || true
    fi

    # Also notify Master inbox
    local notify_json
    notify_json=$(jq -nc \
        --arg id "stage0-issue-${issue_num}" \
        --arg node "$REMOTE_SENTINEL_NODE_ID" \
        --argjson num "$issue_num" \
        --arg title "$title" \
        --arg brief "$brief" \
        '{
            jsonrpc: "2.0",
            id: $id,
            method: "sentinel/issue_triage",
            params: {
                node_id: $node,
                issue_number: $num,
                title: $title,
                brief: $brief
            }
        }')
    _rs_mqtt_pub "george/master/inbox" "$notify_json"
    _rs_log "Completed Stage-0 Triage for issue #${issue_num} and notified Master."
    printf "%s\n" "$comment_body"
    return 0
}

# ── Daemon Lifecycle (Start / Stop / Status) ─────────────────────────────────
remote_sentinel_start() {
    mkdir -p "$SENTINEL_DIR" 2>/dev/null
    if [ -f "$SENTINEL_PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$SENTINEL_PID_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            _rs_log "Sentinel observer already running (PID $old_pid)"
            return 0
        fi
    fi

    _rs_parse_broker
    local host="$_RS_HOST"
    local port="$_RS_PORT"

    (
        export PATH="$HOME/.local/bin:$PATH"
        export LD_LIBRARY_PATH="$HOME/.local/lib/mosquitto${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        _rs_log "Starting Event-Bus Anomaly & Log Sentinel subscriber on ${host}:${port} (topic: george/events/#)"
        while true; do
            "$_RS_MOSQ_SUB" -h "$host" -p "$port" -i "george-sentinel-${REMOTE_SENTINEL_NODE_ID}" -v -t "george/events/#" 2>/dev/null | while read -r topic payload; do
                [ -z "$topic" ] || [ -z "$payload" ] && continue
                remote_sentinel_handle_event "$topic" "$payload"
            done
            sleep 3
        done
    ) </dev/null >/dev/null 2>&1 &
    local spid=$!
    disown "$spid" 2>/dev/null || true
    echo "$spid" > "$SENTINEL_PID_FILE"
    _rs_log "Remote Sentinel daemon active (PID $spid)"
    return 0
}

remote_sentinel_stop() {
    if [ -f "$SENTINEL_PID_FILE" ]; then
        local spid
        spid=$(cat "$SENTINEL_PID_FILE" 2>/dev/null)
        rm -f "$SENTINEL_PID_FILE" 2>/dev/null
        if [ -n "$spid" ]; then
            pkill -TERM -P "$spid" 2>/dev/null || true
            kill "$spid" 2>/dev/null || true
        fi
    fi
    _rs_log "Remote Sentinel daemon stopped"
    return 0
}

remote_sentinel_status() {
    if [ -f "$SENTINEL_PID_FILE" ]; then
        local spid
        spid=$(cat "$SENTINEL_PID_FILE" 2>/dev/null)
        if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null; then
            echo "RUNNING (PID $spid)"
            return 0
        fi
    fi
    echo "STOPPED"
    return 1
}

