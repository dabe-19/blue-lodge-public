#!/bin/bash
# ── Sovereign Financial & OSINT Synthesis Subagent (2026) ─────────────
# Executes LLM-powered intelligence synthesis as a first-class Blue Lodge subagent:
#   1. Registers in .george/subagents.json with live Task Bay tracking
#   2. Operates on a dedicated POSIX IPC FIFO channel (.george/ipc/channels/synth_<id>)
#   3. Streams execution trace & LLM tokens into .george/subagents/<id>.log and .out
#   4. Emits high-priority synthesis and opportunity events into event_bus.fifo
#   5. Conforms to okf/standards/subagent_sandbox_lifecycle.jsonld and fifo_async_ipc_protocol.jsonld

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export LODGE_DIR
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
export GEORGE_DIR

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/subagents.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/llm.sh" 2>/dev/null || true

_synthesis_subagent_run() {
    local input_data="$1"
    local is_async="${2:-0}"

    local now_ts
    now_ts=$(date +%s)
    local sub_id="sub_synth_${now_ts}_${RANDOM:-$$}"
    local target_tier="1"
    local tier_model="active_local_llm"
    local objective="Synthesize Financial OSINT Signals & Strategic Opportunities"

    local sandbox_base="${LODGE_DIR}/.sandboxes"
    local sub_dir="${sandbox_base}/${sub_id}"
    mkdir -p "$sandbox_base" "$sub_dir" "${GEORGE_DIR}/subagents" 2>/dev/null || true

    local log_file="${GEORGE_DIR}/subagents/${sub_id}.log"
    local out_file="${GEORGE_DIR}/subagents/${sub_id}.out"
    local stream_file="${GEORGE_DIR}/subagents/${sub_id}.stream"
    local sub_fifo="$sub_dir/stream.fifo"
    local ctrl_fifo="$sub_dir/control.fifo"

    rm -f "$sub_fifo" "$ctrl_fifo" 2>/dev/null || true
    mkfifo "$sub_fifo" 2>/dev/null || true
    mkfifo "$ctrl_fifo" 2>/dev/null || true

    # Write task metadata for web observability and Autonomic Task Bay
    mkdir -p "$sub_dir/.george" 2>/dev/null || true
    echo "$$" > "$sub_dir/.pid" 2>/dev/null || true
    echo "Initializing" > "$sub_dir/.phase" 2>/dev/null || true
    cat > "$sub_dir/task_meta.json" <<EOF
{
  "id": "$sub_id",
  "type": "subagent",
  "tier": "$target_tier",
  "model": "$tier_model",
  "objective": "$objective",
  "branch": "synthesis",
  "started_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date +'%Y-%m-%d %H:%M:%S')"
}
EOF
    ln -sf "$out_file" "$sub_dir/trajectory.log" 2>/dev/null || true

    # Register in central subagent registry
    subagents_register "$sub_id" "$$" "$PPID" "$target_tier" "$tier_model" "$objective" "synthesis" "$sub_dir" 10

    # NOTE: input is ingested directly. (A self-loopback IPC channel used to live here;
    # writing to and reading from one's own channel provides no flow control.)

    # Logging helper
    _log() {
        local tag="$1" msg="$2"
        local ts
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        local entry
        entry=$(printf '[%s] [%-12s] %s' "$ts" "$tag" "$msg")
        echo "$entry" >> "$log_file"
        echo "$entry" >> "$out_file"
        echo "$entry" >> "$stream_file"
    }

    _log "SPAWN" "Autonomic Synthesis Worker initialized (sub_id: $sub_id)"
    echo "Running" > "$sub_dir/.phase" 2>/dev/null || true
    subagents_update_status "$sub_id" "RUNNING" 1

    # Ingest incoming signals
    local raw_json=""
    if [ -f "$input_data" ]; then
        raw_json=$(< "$input_data")
    elif [ -n "$input_data" ]; then
        raw_json="$input_data"
    fi
    local signals_payload="$raw_json"
    _log "INGEST" "Ingested signal payload (${#raw_json} bytes)"

    _log "ANALYZE" "Parsing signal payload for top financial & grant catalysts"
    echo "Analyzing" > "$sub_dir/.phase" 2>/dev/null || true

    # Extract signals array count
    local sig_count=0
    if echo "$signals_payload" | jq empty 2>/dev/null; then
        sig_count=$(echo "$signals_payload" | jq 'if type == "array" then length elif .top_opportunities then (.top_opportunities | length) else 1 end' 2>/dev/null || echo 1)
    fi
    _log "SIGNALS" "Identified $sig_count high-scoring opportunities requiring strategic synthesis"

    # Build prompt for LLM synthesis
    local signals_text=""
    if echo "$signals_payload" | jq empty 2>/dev/null; then
        signals_text=$(echo "$signals_payload" | jq -r '
            if type == "array" then
                .[0:5][] | "• [\(.category // "OPP")] \(.title // "") | Score: \(.score // .composite_score // 0) | Yield: \(.amount // .amount_range // "Undisclosed") | Deadline: \(.deadline // .deadline_hint // "Rolling")\n  URL: \(.url // "")"
            elif .top_opportunities then
                .top_opportunities[0:5][] | "• [\(.category // "OPP")] \(.title // "") | Score: \(.score // 0) | Yield: \(.amount // "Undisclosed") | Deadline: \(.deadline // "Rolling")\n  URL: \(.url // "")"
            else
                . | tostring
            end
        ' 2>/dev/null)
    fi

    [ -z "$signals_text" ] && signals_text="General financial sweep signals discovered."

    local prompt="You are the Sovereign Financial & Grants Intelligence Analyst for the Blue Lodge autonomy framework.
Analyze the following newly discovered financial opportunities, developer grants, and market signals:

$signals_text

Provide a concise, high-impact tactical intelligence brief:
1. Executive Summary & Market Trajectory (2-3 sentences)
2. High-Priority Revenue & Capital Opportunities (Prioritize by feasibility and yield)
3. Concrete Action Items (Immediate next steps, proposal drafting, or application targets)
4. Risk & Feasibility Assessment

Keep output dense, analytical, and actionable. Do not use decorative emojis."

    _log "SYNTHESIZE" "Querying Sovereign LLM inference fabric..."
    echo "Synthesizing" > "$sub_dir/.phase" 2>/dev/null || true

    local narrative=""
    local llm_source="algorithmic_fallback"

    # Query local LLM via curl with stream into .out
    local llm_resp=""
    llm_resp=$(curl -s --connect-timeout 3 -m 15 http://127.0.0.1:8080/completion \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg p "$prompt" '{prompt: $p, n_predict: 500, temperature: 0.7}')" 2>/dev/null)

    if [ -n "$llm_resp" ] && echo "$llm_resp" | jq empty 2>/dev/null; then
        narrative=$(echo "$llm_resp" | jq -r '.content // empty' 2>/dev/null)
        if [ -n "$narrative" ]; then
            llm_source="llama.cpp:8080"
        fi
    fi

    # Fallback if local LLM offline
    if [ -z "$narrative" ]; then
        narrative=$(cat <<FALLBACK_EOF
### 1. Executive Summary & Market Trajectory
Autonomous sweep extracted $sig_count opportunities across developer tooling, open-source infrastructure, and prediction markets. Top-ranked opportunities exhibit strong alignment with autonomous agent infrastructure.

### 2. High-Priority Revenue & Capital Opportunities
$signals_text

### 3. Concrete Action Items
- Qualify application requirements for top-ranking grant and bounty opportunities.
- Prepare technical project summary and open-source architecture documentation.
- Monitor designated domain feeds and deadlines through the Sovereign Event Bus.

### 4. Risk & Feasibility Assessment
- Capital grants with explicit developer tooling and open-source milestones carry low operational overhead.
- Ensure compliance with submission cutoffs and technical deliverables.
FALLBACK_EOF
)
    fi

    _log "COMPLETE_SYNTH" "Synthesis generated via $llm_source ($sig_count signals analyzed)"
    echo "Appending Dossier" > "$sub_dir/.phase" 2>/dev/null || true

    # Write into dossier
    local dossier_file="${LODGE_DIR}/dossiers/finance_intel.md"
    mkdir -p "$(dirname "$dossier_file")" 2>/dev/null || true
    local ts_dossier
    ts_dossier=$(date '+%Y-%m-%d %H:%M:%S')

    cat >> "$dossier_file" <<DOSSIER_EOF

## Strategic Synthesis Brief: $ts_dossier
**Subagent ID:** \`$sub_id\` | **Source:** \`$llm_source\` | **Signals Analyzed:** $sig_count

$narrative

---

DOSSIER_EOF

    _log "DOSSIER" "Appended strategic brief to $dossier_file"

    # Emit to Sovereign Event Bus
    _log "EVENT_BUS" "Emitting finance_synthesis_complete to event_bus.fifo"
    event_bus_emit "finance_synthesis_complete" "$(jq -n \
        --arg id "$sub_id" \
        --arg src "$llm_source" \
        --arg nar "$narrative" \
        --argjson count "$sig_count" \
        --argjson ts "$now_ts" \
        '{subagent_id: $id, source: $src, narrative: $nar, signals_count: $count, timestamp: $ts}')" "synthesis_worker"

    # Check top opportunity for high-priority alert
    event_bus_emit "finance_opportunity_alert" "$(jq -n \
        --arg id "$sub_id" \
        --arg nar "${narrative:0:300}" \
        --argjson count "$sig_count" \
        --argjson ts "$now_ts" \
        '{title: "High-Priority Funding & Market Catalyst Discovered", executive_summary: $nar, signals_count: $count, timestamp: $ts}')" "synthesis_worker"

    # Dispatch Discord notification for newly created synthesis
    (
        source "$LODGE_DIR/lib/core/endpoints.sh" 2>/dev/null || true
        source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null || true
        local preview="${narrative:0:450}"
        local d_msg
        d_msg=$(cat <<DISCORD_MSG
[AUTONOMIC FINANCIAL INTELLIGENCE SYNTHESIS]
Autonomous OKF subagents run over POSIX FIFOs and synthesize strategic intelligence dossiers in dossiers/finance_intel.md.

Subagent ID: $sub_id | Signals Analyzed: $sig_count
Summary Highlight:
$preview
DISCORD_MSG
)
        local target_user="${DISCORD_DM_USER_ID:-${DISCORD_DEFAULT_USER:-${DISCORD_OWNER_USERNAME:-owner}}}"
        discord_dm "$target_user" "$d_msg" 2>&1 || true
    ) >> "$EVENT_BUS_LOG" 2>&1 &

    # Finalize task
    echo "Completed" > "$sub_dir/.phase" 2>/dev/null || true
    touch "$sub_dir/.done" 2>/dev/null || true
    subagents_update_status "$sub_id" "COMPLETED" 1 "Strategic intelligence synthesis generated"
    _log "EXIT" "Subagent $sub_id concluded successfully"

    printf '%s\n' "$narrative"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _synthesis_subagent_run "$1" "${2:-0}"
fi
