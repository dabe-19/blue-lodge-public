#!/usr/bin/env bash
# ── lib/core/loop_engine.sh — Blue Lodge Sovereign Agentic Loop Engine (ALP v1) ──
# Unified multi-phase agentic loop & tool-flow runtime for Heartwood and Modules.
# Interleaves POSIX FIFO IPC v3 (ipc_channel_open, ipc_async, ipc_await_all_settled,
# ipc_flow_acquire, ipc_write_frame) with the Sovereign ReAct engine (`react_run`).

[ -n "${_LIB_LOOP_ENGINE_LOADED:-}" ] && [ "${#BASH_SOURCE[@]}" -gt 1 ] && return 0
_LIB_LOOP_ENGINE_LOADED=1

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
LOOP_SCHEMA_PY="${LOOP_SCHEMA_PY:-$LODGE_DIR/lib/core/loop_schema.py}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/native_tools.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/react.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/memory/transcript.sh" 2>/dev/null || true

declare -f ui_ok &>/dev/null   || ui_ok()   { printf "[✓] %s\n" "$*"; }
declare -f ui_info &>/dev/null || ui_info() { printf "[i] %s\n" "$*"; }
declare -f ui_step &>/dev/null || ui_step() { printf "[→] %s\n" "$*"; }
declare -f ui_warn &>/dev/null || ui_warn() { printf "[!] %s\n" "$*" >&2; }
declare -f ui_err &>/dev/null  || ui_err()  { printf "[✗] %s\n" "$*" >&2; }
declare -f ui_dim &>/dev/null  || ui_dim()  { printf "    %s\n" "$*"; }

# ── Helper: List / Resolve / Validate Loops ──────────────────────────
loop_list() {
    local owner="${1:-}"
    if [ -n "$owner" ]; then
        LODGE_DIR="$LODGE_DIR" GEORGE_DIR="$GEORGE_DIR" python3 "$LOOP_SCHEMA_PY" list --owner "$owner"
    else
        LODGE_DIR="$LODGE_DIR" GEORGE_DIR="$GEORGE_DIR" python3 "$LOOP_SCHEMA_PY" list
    fi
}

loop_resolve_path() {
    local owner="$1" loop_id="$2"
    LODGE_DIR="$LODGE_DIR" GEORGE_DIR="$GEORGE_DIR" python3 "$LOOP_SCHEMA_PY" resolve-path "$owner" "$loop_id"
}

loop_resolve_json() {
    local owner="$1" loop_id="$2"
    LODGE_DIR="$LODGE_DIR" GEORGE_DIR="$GEORGE_DIR" python3 "$LOOP_SCHEMA_PY" resolve "$owner" "$loop_id"
}

loop_validate() {
    local file="$1"
    LODGE_DIR="$LODGE_DIR" GEORGE_DIR="$GEORGE_DIR" python3 "$LOOP_SCHEMA_PY" validate "$file"
}

# ── Helper: Update Sandbox Phase + Emit FIFO Frame ───────────────────
_loop_emit_phase() {
    local sandbox_dir="$1" cid="$2" event="$3" phase_label="$4" extra_json="${5:-{}}"
    [ -n "$sandbox_dir" ] && [ -d "$sandbox_dir" ] && printf '%s\n' "$phase_label" > "$sandbox_dir/.phase" 2>/dev/null || true
    if declare -f ipc_write_frame &>/dev/null && declare -f ipc_channel_is_open &>/dev/null && ipc_channel_is_open "$cid"; then
        local payload
        payload=$(jq -nc --arg ev "$event" --arg ph "$phase_label" --argjson ex "$extra_json" \
            '{event: $ev, phase: $ph} + $ex' 2>/dev/null || printf '{"event":"%s","phase":"%s"}' "$event" "$phase_label")
        ipc_write_frame "$cid" "$payload" 2 >/dev/null 2>&1 || true
    fi
}

# ── Helper: Merge Phase Output Into loop_context.json ────────────────
_loop_merge_phase_output() {
    local ctx_file="$1" phase_id="$2" phase_out_file="$3"
    python3 - "$ctx_file" "$phase_id" "$phase_out_file" <<'PY'
import json, os, sys
ctx_path, pid, out_path = sys.argv[1:4]
try:
    ctx = json.load(open(ctx_path, "r", encoding="utf-8"))
except Exception:
    ctx = {}
try:
    out_obj = json.load(open(out_path, "r", encoding="utf-8"))
except Exception:
    out_obj = {}

# Keep inline template context bounded (<=12KB per key) while preserving full file path
compact = {"_file": out_path}
for k, v in out_obj.items():
    if isinstance(v, str) and len(v) > 12000:
        compact[k] = v[:12000] + f"\n...[truncated; full output in {out_path}]"
    else:
        s = json.dumps(v) if not isinstance(v, str) else v
        if len(s) > 12000:
            compact[k] = s[:12000] + f"...[truncated; full output in {out_path}]"
        else:
            compact[k] = v

ctx.setdefault("phase", {})[pid] = compact
tmp = ctx_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(ctx, f, indent=2)
os.replace(tmp, ctx_path)
PY
}

# ── Helper: Execute a Single Tool Inside FIFO Promise Worker ─────────
_loop_build_tool_cmd() {
    local tool_name="$1" args_json="$2" workdir="$3" call_id="$4" cid="$5" task_id="$6"
    local q_cid q_tid q_id q_name q_args q_wd
    printf -v q_cid '%q' "$cid"
    printf -v q_tid '%q' "$task_id"
    printf -v q_id '%q' "$call_id"
    printf -v q_name '%q' "$tool_name"
    printf -v q_args '%q' "$args_json"
    printf -v q_wd '%q' "$workdir"
    printf 'export IPC_CHANNEL=%s; export AGENT_ACTIVE_TASK_ID=%s; native_tools_dispatch %s %s %s %s' \
        "$q_cid" "$q_tid" "$q_id" "$q_name" "$q_args" "$q_wd"
}

# ── Phase Runner: fifo_parallel (Concurrent FIFO Tool Fan-Out) ───────
_loop_run_fifo_parallel() {
    local cid="$1" task_id="$2" sandbox_dir="$3" ctx_file="$4" phase_json="$5" workdir="$6" default_timeout="$7"

    local phase_id timeout_sec continue_on_error task_count
    phase_id=$(printf '%s' "$phase_json" | jq -r '.id')
    timeout_sec=$(printf '%s' "$phase_json" | jq -r --argjson d "$default_timeout" '.timeout_sec // $d')
    continue_on_error=$(printf '%s' "$phase_json" | jq -r '.continue_on_error // false')
    task_count=$(printf '%s' "$phase_json" | jq -r '.tasks | length')

    local out_dir="$sandbox_dir/phase_outputs"
    mkdir -p "$out_dir"
    local phase_out_file="$out_dir/${phase_id}.json"
    printf '{}\n' > "$phase_out_file"

    if [ "$task_count" -eq 0 ]; then
        _loop_merge_phase_output "$ctx_file" "$phase_id" "$phase_out_file"
        return 0
    fi

    local -a prom_ids=()
    local -a prom_keys=()
    local -a prom_tools=()
    local i
    for ((i=0; i<task_count; i++)); do
        local tk tid ttool tkey twhen targs_tmpl rendered_args
        tk=$(printf '%s' "$phase_json" | jq -c ".tasks[$i]")
        tid=$(printf '%s' "$tk" | jq -r '.id')
        ttool=$(printf '%s' "$tk" | jq -r '.tool')
        tkey=$(printf '%s' "$tk" | jq -r '.output_key // .id')
        twhen=$(printf '%s' "$tk" | jq -r '.when // empty')
        targs_tmpl=$(printf '%s' "$tk" | jq -c '.args_template // {}')

        if [ -n "$twhen" ]; then
            local cond_res
            cond_res=$(python3 "$LOOP_SCHEMA_PY" render --context-file "$ctx_file" --when "$twhen" --json-template '{}' 2>/dev/null || echo "__SKIP__")
            if [ "$cond_res" = "__SKIP__" ]; then
                ui_dim "[fifo_parallel] Skipping task '$tid' ($ttool): condition '$twhen' false"
                continue
            fi
        fi

        rendered_args=$(python3 "$LOOP_SCHEMA_PY" render --context-file "$ctx_file" --json-template "$targs_tmpl" 2>/dev/null || echo "{}")
        local call_id="loop_${phase_id}_${tid}_${RANDOM}"
        local cmd
        cmd=$(_loop_build_tool_cmd "$ttool" "$rendered_args" "$workdir" "$call_id" "$cid" "$task_id")

        ui_info "[fifo_parallel] Dispatching async FIFO promise: $ttool ($tid)"
        local prom_id
        prom_id=$(ipc_async "$cid" "$cmd" "$call_id" "$ttool" "$rendered_args")
        if [ -n "$prom_id" ]; then
            prom_ids+=("$prom_id")
            prom_keys+=("$tkey")
            prom_tools+=("$ttool")
        fi
    done

    if [ "${#prom_ids[@]}" -eq 0 ]; then
        _loop_merge_phase_output "$ctx_file" "$phase_id" "$phase_out_file"
        return 0
    fi

    # Wait for ALL parallel promises to settle concurrently via FIFO IPC barrier
    local await_rc=0
    ipc_await_all_settled "$timeout_sec" "${prom_ids[@]}" || await_rc=$?

    local idx any_err=0
    for ((idx=0; idx<${#prom_ids[@]}; idx++)); do
        local pid="${prom_ids[$idx]}"
        local okey="${prom_keys[$idx]}"
        local tname="${prom_tools[$idx]}"
        local resp="" ec=0
        resp=$(ipc_await "$pid" 0 2>&1) || ec=$?
        if [ "$ec" -ne 0 ]; then
            any_err=1
            ui_warn "[fifo_parallel] Task '$okey' ($tname) exited $ec"
        else
            ui_ok "[fifo_parallel] Task '$okey' ($tname) settled cleanly (${#resp} bytes)"
        fi
        # Store output in phase_outputs/<phase_id>.json (parse JSON if valid, else store string)
        python3 - "$phase_out_file" "$okey" "$resp" <<'PY'
import json, os, sys
fpath, key, raw = sys.argv[1:4]
obj = json.load(open(fpath, "r", encoding="utf-8"))
val = raw.strip()
try:
    parsed = json.loads(val)
    obj[key] = parsed
except Exception:
    obj[key] = val
tmp = fpath + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2)
os.replace(tmp, fpath)
PY
    done

    _loop_merge_phase_output "$ctx_file" "$phase_id" "$phase_out_file"
    _loop_emit_phase "$sandbox_dir" "$cid" "fifo_stage_done" "FIFO Stage Complete: $phase_id" \
        "$(jq -nc --arg pid "$phase_id" --argjson cnt "${#prom_ids[@]}" '{phase_id: $pid, tasks_settled: $cnt}')"

    if [ "$any_err" -ne 0 ] && [ "$continue_on_error" != "true" ]; then
        return 1
    fi
    return 0
}

# ── Phase Runner: fifo_pipe (Sequential FIFO Tool Pipeline) ──────────
_loop_run_fifo_pipe() {
    local cid="$1" task_id="$2" sandbox_dir="$3" ctx_file="$4" phase_json="$5" workdir="$6" default_timeout="$7"

    local phase_id timeout_sec continue_on_error task_count
    phase_id=$(printf '%s' "$phase_json" | jq -r '.id')
    timeout_sec=$(printf '%s' "$phase_json" | jq -r --argjson d "$default_timeout" '.timeout_sec // $d')
    continue_on_error=$(printf '%s' "$phase_json" | jq -r '.continue_on_error // false')
    task_count=$(printf '%s' "$phase_json" | jq -r '.tasks | length')

    local out_dir="$sandbox_dir/phase_outputs"
    mkdir -p "$out_dir"
    local phase_out_file="$out_dir/${phase_id}.json"
    printf '{}\n' > "$phase_out_file"

    local i
    for ((i=0; i<task_count; i++)); do
        local tk tid ttool tkey twhen targs_tmpl rendered_args
        tk=$(printf '%s' "$phase_json" | jq -c ".tasks[$i]")
        tid=$(printf '%s' "$tk" | jq -r '.id')
        ttool=$(printf '%s' "$tk" | jq -r '.tool')
        tkey=$(printf '%s' "$tk" | jq -r '.output_key // .id')
        twhen=$(printf '%s' "$tk" | jq -r '.when // empty')
        targs_tmpl=$(printf '%s' "$tk" | jq -c '.args_template // {}')

        if [ -n "$twhen" ]; then
            local cond_res
            cond_res=$(python3 "$LOOP_SCHEMA_PY" render --context-file "$ctx_file" --when "$twhen" --json-template '{}' 2>/dev/null || echo "__SKIP__")
            [ "$cond_res" = "__SKIP__" ] && continue
        fi

        rendered_args=$(python3 "$LOOP_SCHEMA_PY" render --context-file "$ctx_file" --json-template "$targs_tmpl" 2>/dev/null || echo "{}")
        local call_id="loop_pipe_${phase_id}_${tid}_${RANDOM}"
        local cmd
        cmd=$(_loop_build_tool_cmd "$ttool" "$rendered_args" "$workdir" "$call_id" "$cid" "$task_id")

        ui_info "[fifo_pipe] Stage $((i+1))/$task_count: $ttool ($tid)"
        local prom_id resp="" ec=0
        prom_id=$(ipc_async "$cid" "$cmd" "$call_id" "$ttool" "$rendered_args")
        resp=$(ipc_await "$prom_id" "$timeout_sec" 2>&1) || ec=$?

        python3 - "$phase_out_file" "$ctx_file" "$tkey" "$resp" <<'PY'
import json, os, sys
fpath, cpath, key, raw = sys.argv[1:5]
obj = json.load(open(fpath, "r", encoding="utf-8"))
val = raw.strip()
try:
    parsed = json.loads(val)
except Exception:
    parsed = val
obj[key] = parsed
tmp = fpath + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2)
os.replace(tmp, fpath)

ctx = json.load(open(cpath, "r", encoding="utf-8"))
ctx["prev"] = parsed if not isinstance(parsed, str) or len(parsed) <= 12000 else parsed[:12000]
ctmp = cpath + ".tmp"
with open(ctmp, "w", encoding="utf-8") as f:
    json.dump(ctx, f, indent=2)
os.replace(ctmp, cpath)
PY
        if [ "$ec" -ne 0 ] && [ "$continue_on_error" != "true" ]; then
            ui_err "[fifo_pipe] Stage '$tid' ($ttool) failed with exit $ec"
            _loop_merge_phase_output "$ctx_file" "$phase_id" "$phase_out_file"
            return 1
        fi
    done

    _loop_merge_phase_output "$ctx_file" "$phase_id" "$phase_out_file"
    return 0
}

# ── Phase Runner: react (Sovereign ReAct Engine) ─────────────────────
_loop_run_react_phase() {
    local cid="$1" task_id="$2" sandbox_dir="$3" ctx_file="$4" phase_json="$5" workdir="$6"
    local owner="$7" loop_id="$8" loop_allow="$9" loop_deny="${10}" loop_bundles="${11}"
    local default_turns="${12}" ipc_priority="${13}" override_turns="${14:-0}"

    local phase_id phase_name phase_turns tool_filter p_allow prompt_tmpl prompt_append
    phase_id=$(printf '%s' "$phase_json" | jq -r '.id')
    phase_name=$(printf '%s' "$phase_json" | jq -r '.name // .id')
    phase_turns=$(printf '%s' "$phase_json" | jq -r --argjson d "$default_turns" '.max_turns // $d')
    tool_filter=$(printf '%s' "$phase_json" | jq -r '.tool_filter // "default"')
    p_allow=$(printf '%s' "$phase_json" | jq -r '(.tools_allow // []) | join(",")')
    prompt_tmpl=$(printf '%s' "$phase_json" | jq -r '.prompt_template // ""')
    prompt_append=$(printf '%s' "$phase_json" | jq -r '.prompt_append // ""')

    local eff_turns="$phase_turns"
    if [[ "$override_turns" =~ ^[0-9]+$ ]] && [ "$override_turns" -gt 0 ]; then
        eff_turns="$override_turns"
    fi
    [ -z "$eff_turns" ] || [ "$eff_turns" -le 0 ] && eff_turns=200

    local merged_allow="$loop_allow"
    if [ -n "$p_allow" ]; then
        [ -n "$merged_allow" ] && merged_allow="${merged_allow},${p_allow}" || merged_allow="$p_allow"
    fi

    local tmpl_file="$sandbox_dir/phase_outputs/${phase_id}_prompt.tmpl"
    mkdir -p "$sandbox_dir/phase_outputs"
    printf '%s' "$prompt_tmpl" > "$tmpl_file"
    if [ -n "$prompt_append" ]; then
        printf '\n\nADDITIONAL OPERATOR STEERING:\n%s\n' "$prompt_append" >> "$tmpl_file"
    fi

    local rendered_prompt
    rendered_prompt=$(python3 "$LOOP_SCHEMA_PY" render --context-file "$ctx_file" --template-file "$tmpl_file")
    if [ -z "$rendered_prompt" ]; then
        ui_err "[react] Phase '$phase_id' rendered an empty prompt"
        return 1
    fi

    local phase_sid="${task_id}_${phase_id}"
    ui_step "[react] Launching '$phase_name' (max_turns=$eff_turns, ipc_priority=$ipc_priority, profile=$tool_filter)"

    local prev_mod="${LODGE_ACTIVE_MODULE:-}"
    local prev_wf="${LODGE_ACTIVE_WORKFLOW:-}"
    if [ "$owner" != "heartwood" ]; then
        export LODGE_ACTIVE_MODULE="$owner"
    fi
    export LODGE_ACTIVE_WORKFLOW="$loop_id"
    export LODGE_LOOP_TOOLS_ALLOW="$merged_allow"
    export LODGE_LOOP_TOOLS_DENY="$loop_deny"
    export LODGE_LOOP_BUNDLES="$loop_bundles"
    export AGENT_IPC_PRIORITY="$ipc_priority"
    export AGENT_MAX_TURNS="$eff_turns"

    local rc=0
    react_run "$rendered_prompt" "$workdir" "$eff_turns" "${ACTIVE_TIER:-1}" "$phase_sid" "$tool_filter" || rc=$?

    # Restore outer env cleanly
    if [ -n "$prev_mod" ]; then export LODGE_ACTIVE_MODULE="$prev_mod"; else unset LODGE_ACTIVE_MODULE; fi
    if [ -n "$prev_wf" ]; then export LODGE_ACTIVE_WORKFLOW="$prev_wf"; else unset LODGE_ACTIVE_WORKFLOW; fi
    unset LODGE_LOOP_TOOLS_ALLOW LODGE_LOOP_TOOLS_DENY LODGE_LOOP_BUNDLES

    return "$rc"
}

# ── Gate Evaluation + Optional Corrective Retry ──────────────────────
_loop_eval_gate() {
    local cid="$1" task_id="$2" sandbox_dir="$3" phase_json="$4" workdir="$5"
    local owner="$6" loop_id="$7" loop_allow="$8" loop_deny="$9" ipc_priority="${10}"

    local gate_json
    gate_json=$(printf '%s' "$phase_json" | jq -c '.gate // empty')
    [ -z "$gate_json" ] && return 0

    local gtype gonfail max_retries
    gtype=$(printf '%s' "$gate_json" | jq -r '.type // "none"')
    [ "$gtype" = "none" ] && return 0
    gonfail=$(printf '%s' "$gate_json" | jq -r '.on_fail // "warn"')
    max_retries=$(printf '%s' "$gate_json" | jq -r '.max_retries // 1')

    local attempt=0
    while :; do
        local gate_out="" gate_rc=0
        gate_out=$(python3 "$LOOP_SCHEMA_PY" check-gate "$sandbox_dir" "$gate_json" 2>/dev/null) || gate_rc=$?
        local reason
        reason=$(printf '%s' "$gate_out" | jq -r '.reason // "unknown"' 2>/dev/null)
        if [ "$gate_rc" -eq 0 ]; then
            ui_ok "[gate] Verification passed: $reason"
            _loop_emit_phase "$sandbox_dir" "$cid" "gate_pass" "Gate Verified: $reason" '{}'
            return 0
        fi

        ui_warn "[gate] Verification failed (attempt $((attempt+1))): $reason"
        if [ "$gonfail" = "retry" ] && [ "$attempt" -lt "$max_retries" ]; then
            attempt=$((attempt + 1))
            _loop_emit_phase "$sandbox_dir" "$cid" "gate_retry" "Gate Retry $attempt/$max_retries: $reason" '{}'
            local gpath
            gpath=$(printf '%s' "$gate_json" | jq -r '.path // "result.json"')
            local fix_prompt="VERIFICATION GATE RETRY ($attempt/$max_retries):
Your previous phase did not satisfy the required verification gate:
- Failure reason: $reason
- Expected artifact path: $sandbox_dir/$gpath

Inspect the existing outputs in $sandbox_dir (including $sandbox_dir/phase_outputs/), then write a valid, complete artifact to $sandbox_dir/$gpath using file_write that satisfies every required key, and conclude cleanly."
            if [ "$owner" != "heartwood" ]; then export LODGE_ACTIVE_MODULE="$owner"; fi
            export LODGE_ACTIVE_WORKFLOW="$loop_id"
            export LODGE_LOOP_TOOLS_ALLOW="${loop_allow:+$loop_allow,}file_read,file_write,dir_list"
            export LODGE_LOOP_TOOLS_DENY="$loop_deny"
            export AGENT_IPC_PRIORITY="$ipc_priority"
            react_run "$fix_prompt" "$workdir" 25 "${ACTIVE_TIER:-1}" "${task_id}_gate_retry_${attempt}" "default" || true
            unset LODGE_LOOP_TOOLS_ALLOW LODGE_LOOP_TOOLS_DENY
            continue
        fi

        if [ "$gonfail" = "quarantine" ] || [ "$gonfail" = "fail" ]; then
            {
                echo "# Loop Verification Gate Failure"
                echo ""
                echo "- **Loop:** $owner/$loop_id"
                echo "- **Task ID:** $task_id"
                echo "- **Reason:** $reason"
                echo "- **Timestamp:** $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            } > "$sandbox_dir/quarantine_report.md"
            _loop_emit_phase "$sandbox_dir" "$cid" "gate_fail" "Gate Failed: $reason" '{}'
            return 1
        fi
        # warn mode: continue pipeline
        return 0
    done
}

# ── Main Entry Point: loop_run ───────────────────────────────────────
# Usage: loop_run <owner> <loop_id> <sandbox_dir> [params_json_file] [override_max_turns]
loop_run() {
    local owner="$1"
    local loop_id="$2"
    local sandbox_dir="$3"
    local params_file="${4:-}"
    local override_turns="${5:-0}"

    local loop_path
    loop_path=$(loop_resolve_path "$owner" "$loop_id") || {
        ui_err "Declarative loop '$owner/$loop_id' not found."
        return 1
    }

    local val_out
    if ! val_out=$(loop_validate "$loop_path"); then
        ui_err "Loop definition '$loop_path' failed schema validation: $val_out"
        return 1
    fi

    local norm_json
    norm_json=$(printf '%s' "$val_out" | jq -c '.normalized')
    local loop_name runner default_turns ipc_priority fifo_window tool_timeout output_artifact
    loop_name=$(printf '%s' "$norm_json" | jq -r '.name')
    runner=$(printf '%s' "$norm_json" | jq -r '.runner // "loop_engine"')
    default_turns=$(printf '%s' "$norm_json" | jq -r '.defaults.max_turns // 200')
    ipc_priority=$(printf '%s' "$norm_json" | jq -r '.defaults.ipc_priority // 100')
    fifo_window=$(printf '%s' "$norm_json" | jq -r '.defaults.fifo_window // 16')
    tool_timeout=$(printf '%s' "$norm_json" | jq -r '.defaults.tool_timeout_sec // 180')
    output_artifact=$(printf '%s' "$norm_json" | jq -r '.defaults.output_artifact // "result.json"')

    local loop_allow loop_deny loop_bundles
    loop_allow=$(printf '%s' "$norm_json" | jq -r '(.tools.allow // []) | join(",")')
    loop_deny=$(printf '%s' "$norm_json" | jq -r '(.tools.deny // []) | join(",")')
    loop_bundles=$(printf '%s' "$norm_json" | jq -r '(.tools.bundles // []) | join(",")')

    # Special bridge for Sovereign Research Studio (`runner: "research_graph"`)
    if [ "$runner" = "research_graph" ]; then
        source "$LODGE_DIR/lib/tools/research_graph.sh" 2>/dev/null || true
        local r_topic=""
        if [ -n "$params_file" ] && [ -f "$params_file" ]; then
            r_topic=$(jq -r '.topic // empty' "$params_file" 2>/dev/null)
        fi
        export LODGE_LOOP_CONFIG_FILE="$loop_path"
        if [[ "$override_turns" =~ ^[0-9]+$ ]] && [ "$override_turns" -gt 0 ]; then
            export RESEARCH_MAX_TURNS="$override_turns"
        else
            export RESEARCH_MAX_TURNS="$default_turns"
        fi
        research_graph_run "$r_topic"
        return $?
    fi

    mkdir -p "$sandbox_dir/phase_outputs" "$sandbox_dir/inputs"
    local task_id="${GEORGE_TASK_ID:-$(basename "$sandbox_dir")}"
    local cid="loop_${task_id}"
    local mod_data_dir="$GEORGE_DIR/module_data/$owner"
    [ "$owner" = "heartwood" ] && mod_data_dir="$GEORGE_DIR"
    mkdir -p "$mod_data_dir" 2>/dev/null || true

    # Build initial loop_context.json safely
    local ctx_file="$sandbox_dir/loop_context.json"
    python3 - "$ctx_file" "$params_file" "$sandbox_dir" "$output_artifact" "$mod_data_dir" "$owner" "$loop_id" "$task_id" <<'PY'
import json, os, sys
ctx_path, params_path, sbox, out_art, mdata, owner, lid, tid = sys.argv[1:9]
params = {}
if params_path and os.path.isfile(params_path):
    try:
        params = json.load(open(params_path, "r", encoding="utf-8"))
    except Exception:
        params = {}
images = params.get("images") or []
ctx = {
    "owner": owner,
    "loop_id": lid,
    "task_id": tid,
    "sandbox_dir": sbox,
    "result_path": os.path.join(sbox, out_art),
    "module_data_dir": mdata,
    "primary_image": images[0] if images else "",
    "extra_images": images[1:] if len(images) > 1 else [],
    "params": params,
    "phase": {},
    "prev": None,
}
with open(ctx_path, "w", encoding="utf-8") as f:
    json.dump(ctx, f, indent=2)
PY

    # Ignore SIGPIPE so parent web-server restarts can never terminate an active loop
    trap '' PIPE 2>/dev/null || true
    printf '%s\n' "$$" > "$sandbox_dir/.pid" 2>/dev/null || true

    # Open dedicated loop-scoped FIFO channel for telemetry + flow control + parallel promises
    ipc_init 2>/dev/null || true
    ipc_channel_open "$cid" "$fifo_window" >/dev/null 2>&1 || true
    local _loop_cleaned=0
    _loop_cleanup() {
        local _rc=$?
        [ "${_loop_cleaned:-0}" -eq 1 ] && return 0
        _loop_cleaned=1
        declare -f ipc_channel_close &>/dev/null && ipc_channel_close "$cid" >/dev/null 2>&1 || true
        if [ -n "$sandbox_dir" ] && [ -d "$sandbox_dir" ]; then
            rm -f "$sandbox_dir/.pid" 2>/dev/null || true
            if [ ! -f "$sandbox_dir/.done" ]; then
                printf '1\n' > "$sandbox_dir/.done" 2>/dev/null || true
            fi
            if [ "$_rc" -ne 0 ] && [ -f "$sandbox_dir/.phase" ]; then
                local _cur_ph
                _cur_ph=$(cat "$sandbox_dir/.phase" 2>/dev/null || true)
                case "$_cur_ph" in
                    Completed*|Failed*|Aborted*) ;;
                    *) printf 'Failed (exit %s)\n' "$_rc" > "$sandbox_dir/.phase" 2>/dev/null || true ;;
                esac
            fi
        fi
        return 0
    }
    trap '_loop_cleanup' RETURN INT TERM 2>/dev/null || true

    export LODGE_LOOP_CONFIG_FILE="$loop_path"
    export LODGE_LOOP_FIFO_CHANNEL="$cid"
    export LODGE_SANDBOX_DIR="$sandbox_dir"

    ui_section "Agentic Loop: $loop_name ($owner/$loop_id)"
    ui_dim "Loop Spec: $loop_path"
    ui_dim "FIFO Chan: $cid (window=$fifo_window, priority=$ipc_priority, default_turns=$default_turns)"
    ui_dim "Sandbox:   $sandbox_dir"

    local phase_count enabled_total=0 idx
    phase_count=$(printf '%s' "$norm_json" | jq -r '.phases | length')
    for ((idx=0; idx<phase_count; idx++)); do
        [ "$(printf '%s' "$norm_json" | jq -r ".phases[$idx].enabled")" = "true" ] && enabled_total=$((enabled_total + 1))
    done

    local step_num=0 workdir="$LODGE_DIR"
    for ((idx=0; idx<phase_count; idx++)); do
        local ph_json ph_id ph_name ph_kind ph_en
        ph_json=$(printf '%s' "$norm_json" | jq -c ".phases[$idx]")
        ph_id=$(printf '%s' "$ph_json" | jq -r '.id')
        ph_name=$(printf '%s' "$ph_json" | jq -r '.name // .id')
        ph_kind=$(printf '%s' "$ph_json" | jq -r '.kind')
        ph_en=$(printf '%s' "$ph_json" | jq -r '.enabled // true')

        if [ "$ph_en" != "true" ]; then
            ui_dim "Skipping disabled phase: $ph_name ($ph_id)"
            continue
        fi
        step_num=$((step_num + 1))

        # Check FIFO control channel for PAUSE/ABORT before starting next phase
        local ctrl_fifo="$FIFO_IPC_DIR/channels/$cid/ctrl.fifo"
        if [ -p "$ctrl_fifo" ]; then
            local ctrl_cmd=""
            if read -t 0.02 -r ctrl_cmd <> "$ctrl_fifo" 2>/dev/null; then
                if [[ "$ctrl_cmd" == *"ABORT"* ]]; then
                    ui_warn "Loop aborted via FIFO control channel before phase '$ph_id'"
                    _loop_emit_phase "$sandbox_dir" "$cid" "loop_aborted" "Aborted via FIFO" '{}'
                    return 125
                fi
            fi
        fi

        local phase_banner="Phase ${step_num}/${enabled_total}: ${ph_name}"
        _loop_emit_phase "$sandbox_dir" "$cid" "phase_start" "$phase_banner" \
            "$(jq -nc --arg pid "$ph_id" --arg pk "$ph_kind" --argjson sn "$step_num" --argjson tot "$enabled_total" \
                '{phase_id: $pid, kind: $pk, step: $sn, total: $tot}')"

        local prc=0
        case "$ph_kind" in
            fifo_parallel)
                _loop_run_fifo_parallel "$cid" "$task_id" "$sandbox_dir" "$ctx_file" "$ph_json" "$workdir" "$tool_timeout" || prc=$?
                ;;
            fifo_pipe)
                _loop_run_fifo_pipe "$cid" "$task_id" "$sandbox_dir" "$ctx_file" "$ph_json" "$workdir" "$tool_timeout" || prc=$?
                ;;
            react)
                _loop_run_react_phase "$cid" "$task_id" "$sandbox_dir" "$ctx_file" "$ph_json" "$workdir" \
                    "$owner" "$loop_id" "$loop_allow" "$loop_deny" "$loop_bundles" \
                    "$default_turns" "$ipc_priority" "$override_turns" || prc=$?
                ;;
            delegate_script)
                local handler
                handler=$(printf '%s' "$ph_json" | jq -r '.handler // empty')
                if [ -n "$handler" ] && [ "$owner" != "heartwood" ]; then
                    local mod_root="$GEORGE_DIR/modules/$owner"
                    local hpath="$mod_root/$handler"
                    if [ -f "$hpath" ]; then
                        bash "$hpath" "$sandbox_dir" "$ctx_file" "$ph_json" || prc=$?
                    else
                        ui_warn "[delegate_script] Handler not found: $hpath"
                        prc=1
                    fi
                else
                    ui_dim "[delegate_script] Handled natively: $handler"
                fi
                ;;
            *)
                ui_err "Unsupported phase kind: $ph_kind"
                prc=1
                ;;
        esac

        if [ "$prc" -ne 0 ]; then
            local cont_err
            cont_err=$(printf '%s' "$ph_json" | jq -r '.continue_on_error // false')
            if [ "$cont_err" != "true" ]; then
                ui_err "Phase '$ph_name' failed (exit $prc). Halting loop."
                _loop_emit_phase "$sandbox_dir" "$cid" "phase_failed" "Failed in $ph_name (exit $prc)" '{}'
                return "$prc"
            fi
            ui_warn "Phase '$ph_name' exited $prc (continue_on_error=true); proceeding."
        fi

        if ! _loop_eval_gate "$cid" "$task_id" "$sandbox_dir" "$ph_json" "$workdir" \
                "$owner" "$loop_id" "$loop_allow" "$loop_deny" "$ipc_priority"; then
            return 1
        fi
    done

    _loop_emit_phase "$sandbox_dir" "$cid" "loop_complete" "Completed ($owner/$loop_id)" '{}'
    ui_ok "Agentic Loop completed: $loop_name ($owner/$loop_id)"
    return 0
}

# ── Direct CLI Execution Mode ────────────────────────────────────────
if [ "${#BASH_SOURCE[@]}" -eq 1 ] && [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    subcmd="${1:-}"
    shift || true
    case "$subcmd" in
        list) loop_list "$@" ;;
        resolve) loop_resolve_json "$@" ;;
        resolve-path) loop_resolve_path "$@" ;;
        validate) loop_validate "$@" ;;
        run) loop_run "$@" ;;
        *)
            echo "Usage: loop_engine.sh {list|resolve|resolve-path|validate|run} ..." >&2
            exit 1
            ;;
    esac
fi
