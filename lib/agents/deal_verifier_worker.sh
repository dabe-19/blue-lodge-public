#!/bin/bash
# ── Sovereign Deal Verification Subagent (2026) ───────────────────────
# Executes the Agentic Deal Verification Graph as a first-class Blue Lodge subagent:
#   1. Registers in .george/subagents.json with live Task Bay tracking
#   2. Operates on a dedicated POSIX IPC FIFO channel (.george/ipc/channels/deal_verif_<id>)
#   3. Pulls down listing webpage and extracts condition, seller feedback, and format
#   4. Executes forensic rules audit (detecting parts/broken, empty boxes, scams, auction bids)
#   5. Queries Sovereign LLM inference fabric for semantic sanity check
#   6. Updates compute_deal_alerts and commits audit trail into deal_verifications
#   7. Conforms to okf/standards/subagent_sandbox_lifecycle.jsonld and fifo_async_ipc_protocol.jsonld

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export LODGE_DIR
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
export GEORGE_DIR

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/subagents.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true

_deal_verifier_run() {
    local input_data="$1"
    local is_async="${2:-0}"

    local now_ts
    now_ts=$(date +%s)
    local sub_id="sub_deal_verif_${now_ts}_${RANDOM:-$$}"
    local target_tier="1"
    local tier_model="active_local_llm"
    local objective="Verify Secondary Marketplace Compute Deal Authenticity"

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
  "branch": "verification",
  "started_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date +'%Y-%m-%d %H:%M:%S')"
}
EOF
    ln -sf "$out_file" "$sub_dir/trajectory.log" 2>/dev/null || true

    # Register in central subagent registry
    subagents_register "$sub_id" "$$" "$PPID" "$target_tier" "$tier_model" "$objective" "verification" "$sub_dir" 10

    # NOTE: input is ingested directly. (A self-loopback IPC channel used to live here;
    # writing to and reading from one's own channel provides no flow control.)

    # Logging helper
    _log() {
        local tag="$1" msg="$2"
        local ts
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        local entry
        entry=$(printf '[%s] [%-12s] %s\n' "$ts" "$tag" "$msg")
        echo "$entry" >> "$log_file"
        echo "$entry" >> "$out_file"
        echo "$entry" >> "$stream_file"
    }

    _log "SPAWN" "Deal Verification Worker initialized (sub_id: $sub_id)"
    echo "Running" > "$sub_dir/.phase" 2>/dev/null || true
    subagents_update_status "$sub_id" "RUNNING" 1

    # Ingest incoming candidate payload
    local raw_json=""
    if [ -f "$input_data" ]; then
        raw_json=$(< "$input_data")
    elif [ -n "$input_data" ]; then
        raw_json="$input_data"
    fi
    local candidate_payload="$raw_json"
    _log "INGEST" "Ingested candidate payload (${#raw_json} bytes)"

    _log "FETCH" "Pulling down candidate listing webpage and checking reachability..."
    echo "Fetching Page" > "$sub_dir/.phase" 2>/dev/null || true

    # Parse arguments from candidate_payload if JSON
    local deal_url=""
    local deal_price=""
    local deal_model=""
    local deal_hw=""
    local deal_fmv=""
    local deal_id=""

    if echo "$candidate_payload" | jq empty 2>/dev/null; then
        deal_url=$(echo "$candidate_payload" | jq -r '.url // empty' 2>/dev/null)
        deal_price=$(echo "$candidate_payload" | jq -r '.price // .total_price_usd // empty' 2>/dev/null)
        deal_model=$(echo "$candidate_payload" | jq -r '.model // .raw_title // empty' 2>/dev/null)
        deal_hw=$(echo "$candidate_payload" | jq -r '.hardware_id // empty' 2>/dev/null)
        deal_fmv=$(echo "$candidate_payload" | jq -r '.target_fmv_usd // .benchmark_fmv_usd // 0' 2>/dev/null)
        deal_id=$(echo "$candidate_payload" | jq -r '.deal_id // .id // empty' 2>/dev/null)
    fi

    [ -z "$deal_url" ] && deal_url="$input_data"
    [ -z "$deal_price" ] && deal_price="499.0"
    [ -z "$deal_model" ] && deal_model="Hardware Component"
    [ -z "$deal_hw" ] && deal_hw="UNKNOWN_HW"
    [ -z "$deal_fmv" ] && deal_fmv="680.0"

    _log "AUDIT" "Executing forensic rules audit on '$deal_model' ($deal_url)..."
    echo "Forensic Audit" > "$sub_dir/.phase" 2>/dev/null || true

    # Execute Python Agentic Deal Verification Graph
    local verif_output
    local py_cmd=("python3" "$LODGE_DIR/lib/tools/deal_verifier.py" "--url" "$deal_url" "--price" "$deal_price" "--model" "$deal_model" "--hardware-id" "$deal_hw" "--target-fmv" "$deal_fmv" "--json")
    if [ -n "$deal_id" ]; then
        py_cmd=("python3" "$LODGE_DIR/lib/tools/deal_verifier.py" "--deal-id" "$deal_id" "--json")
    fi

    verif_output=$("${py_cmd[@]}" 2>> "$log_file")
    local verif_ec=$?

    _log "AGENT_EVAL" "Completed semantic analysis. Exit code: $verif_ec"
    echo "$verif_output" >> "$log_file"

    local is_authentic="false"
    local verdict="UNKNOWN"
    local reasoning="Verification completed."
    local confidence="0.0"

    if [ "$verif_ec" -eq 0 ] && echo "$verif_output" | jq empty 2>/dev/null; then
        is_authentic=$(echo "$verif_output" | jq -r '.is_authentic' 2>/dev/null)
        verdict=$(echo "$verif_output" | jq -r '.verdict' 2>/dev/null)
        reasoning=$(echo "$verif_output" | jq -r '.reasoning' 2>/dev/null)
        confidence=$(echo "$verif_output" | jq -r '.confidence' 2>/dev/null)
    else
        reasoning="Failed to parse verification result."
    fi

    _log "VERDICT" "Verdict: $verdict (Authentic: $is_authentic, Confidence: $confidence)"
    _log "REASON" "$reasoning"

    echo "Completed" > "$sub_dir/.phase" 2>/dev/null || true
    subagents_update_status "$sub_id" "COMPLETED" 0


    # Output formatted verdict card
    echo ""
    if [ "$is_authentic" = "true" ]; then
        printf " %b╭─────────────────────────────────────────────────────────────╮%b\n" "$C_LODGE" "$C_RESET"
        printf " %b│%b  %b✓ DEAL VERIFIED: AUTHENTIC%b                                 %b│%b\n" "$C_LODGE" "$C_RESET" "$C_BOLD$C_GREEN" "$C_RESET" "$C_LODGE" "$C_RESET"
        printf " %b│%b  Model:     %-48s %b│%b\n" "$C_LODGE" "$C_RESET" "${deal_model:0:48}" "$C_LODGE" "$C_RESET"
        printf " %b│%b  Verdict:   %-48s %b│%b\n" "$C_LODGE" "$C_RESET" "$verdict (Confidence: $(awk "BEGIN {print int($confidence*100)}")%)" "$C_LODGE" "$C_RESET"
        printf " %b│%b  Reasoning: %-48s %b│%b\n" "$C_LODGE" "$C_RESET" "${reasoning:0:48}" "$C_LODGE" "$C_RESET"
        printf " %b╰─────────────────────────────────────────────────────────────╯%b\n" "$C_LODGE" "$C_RESET"
    else
        printf " %b╭─────────────────────────────────────────────────────────────╮%b\n" "$C_LODGE" "$C_RESET"
        printf " %b│%b  %b✗ DEAL REJECTED: FAKE OR FRAUDULENT%b                      %b│%b\n" "$C_LODGE" "$C_RESET" "$C_BOLD$C_RED" "$C_RESET" "$C_LODGE" "$C_RESET"
        printf " %b│%b  Model:     %-48s %b│%b\n" "$C_LODGE" "$C_RESET" "${deal_model:0:48}" "$C_LODGE" "$C_RESET"
        printf " %b│%b  Verdict:   %-48s %b│%b\n" "$C_LODGE" "$C_RESET" "$verdict" "$C_LODGE" "$C_RESET"
        printf " %b│%b  Reasoning: %-48s %b│%b\n" "$C_LODGE" "$C_RESET" "${reasoning:0:48}" "$C_LODGE" "$C_RESET"
        printf " %b╰─────────────────────────────────────────────────────────────╯%b\n" "$C_LODGE" "$C_RESET"
    fi
    echo ""

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _deal_verifier_run "$1" "${2:-0}"
fi
