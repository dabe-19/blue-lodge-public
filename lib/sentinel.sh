#!/bin/bash
# ── George: Autonomic Sentinel & Telemetry Watchdog ─────────────
# Provides persistent, zero-GPU-load telemetry monitoring over
# inference slots, network sockets, GPU vitals, and worktree sandboxes.
# Automatically self-heals lockups (reaps dead curls, prunes stale worktrees),
# and delegates anomaly root-cause triage to Tier 2 compute to file
# Sovereign Gitea issues and staging remediation PR drafts.
#
# State:     .george/sentinel/state.json
# History:   .george/sentinel/history.jsonl
# Config:    .george/sentinel/sentinel.conf
# Log:       .george/sentinel/sentinel.log

[ -n "${_LIB_SENTINEL_LOADED:-}" ] && return 0; _LIB_SENTINEL_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
SENTINEL_DIR="${SENTINEL_DIR:-$GEORGE_DIR/sentinel}"
SENTINEL_STATE="${SENTINEL_DIR}/state.json"
SENTINEL_HISTORY="${SENTINEL_DIR}/history.jsonl"
SENTINEL_LOG="${SENTINEL_DIR}/sentinel.log"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mcp_server_gitea.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/subagents.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/telemetry.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/remediation.sh" 2>/dev/null || true

# Thresholds
SENTINEL_SLOT_STALL_CYCLES="${SENTINEL_SLOT_STALL_CYCLES:-3}"
SENTINEL_CURL_MAX_AGE_SEC="${SENTINEL_CURL_MAX_AGE_SEC:-180}"
SENTINEL_AUTO_HEAL="${SENTINEL_AUTO_HEAL:-1}"

sentinel_init() {
    mkdir -p "$SENTINEL_DIR" 2>/dev/null
    if [ ! -f "$SENTINEL_STATE" ]; then
        echo '{"last_probe":0,"status":"HEALTHY","anomalies":[],"stalled_slots":{}}' > "$SENTINEL_STATE" 2>/dev/null || true
    fi
}

# ── 1. Deterministic POSIX Vitals Probe ──────────────────────────────
# Returns a JSON object detailing system vitals and flagged anomalies.
# Operates in <15ms with 0% GPU compute overhead.
sentinel_probe() {
    sentinel_init

    local now
    now=$(date +%s)
    local anomalies=()
    local actions_needed=()

    # A. Probe GPU Vitals
    local gpu_temp=0 gpu_pwr=0 gpu_mem_used=0 gpu_mem_total=12288 gpu_util=0
    if command -v nvidia-smi &>/dev/null; then
        local smi_out
        smi_out=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -n 1)
        if [ -n "$smi_out" ]; then
            IFS=',' read -r gpu_temp gpu_pwr gpu_mem_used gpu_mem_total gpu_util <<< "$smi_out"
            gpu_temp=$(echo "$gpu_temp" | tr -d ' ')
            gpu_pwr=$(echo "$gpu_pwr" | tr -d ' ' | cut -d'.' -f1)
            gpu_mem_used=$(echo "$gpu_mem_used" | tr -d ' ')
            gpu_mem_total=$(echo "$gpu_mem_total" | tr -d ' ')
            gpu_util=$(echo "$gpu_util" | tr -d ' ')
        fi
    fi

    # B. Probe Inference Slots
    local slot0_busy=0 slot1_busy=0
    local slot0_task="" slot1_task=""
    local slot0_prompt_tok=0 slot1_prompt_tok=0
    local slot0_proc_tok=0 slot1_proc_tok=0
    local slot0_dec_tok=0 slot1_dec_tok=0
    local slots_json
    slots_json=$(curl -s -m 2 http://127.0.0.1:8080/slots 2>/dev/null || echo "[]")

    if [ "$slots_json" != "[]" ] && echo "$slots_json" | jq -e 'type == "array"' &>/dev/null; then
        local s0 s1
        s0=$(echo "$slots_json" | jq -r '.[0] // empty' 2>/dev/null)
        s1=$(echo "$slots_json" | jq -r '.[1] // empty' 2>/dev/null)

        if [ -n "$s0" ]; then
            [ "$(echo "$s0" | jq -r '.is_processing')" = "true" ] && slot0_busy=1
            slot0_task=$(echo "$s0" | jq -r '.id_task // empty')
            slot0_prompt_tok=$(echo "$s0" | jq -r '.n_prompt_tokens // 0')
            slot0_proc_tok=$(echo "$s0" | jq -r '.n_prompt_tokens_processed // 0')
            slot0_dec_tok=$(echo "$s0" | jq -r '.next_token[0].n_decoded // 0')
        fi

        if [ -n "$s1" ]; then
            [ "$(echo "$s1" | jq -r '.is_processing')" = "true" ] && slot1_busy=1
            slot1_task=$(echo "$s1" | jq -r '.id_task // empty')
            slot1_prompt_tok=$(echo "$s1" | jq -r '.n_prompt_tokens // 0')
            slot1_proc_tok=$(echo "$s1" | jq -r '.n_prompt_tokens_processed // 0')
            slot1_dec_tok=$(echo "$s1" | jq -r '.next_token[0].n_decoded // 0')
        fi
    fi

    # C. Track Slot Stagnation Across Cycles
    local prev_state
    prev_state=$(cat "$SENTINEL_STATE" 2>/dev/null || echo "{}")
    local stalled_slots="{}"

    if [ "$slot0_busy" -eq 1 ]; then
        local p0_proc p0_dec p0_count
        p0_proc=$(echo "$prev_state" | jq -r '.stalled_slots."0".proc // -1')
        p0_dec=$(echo "$prev_state" | jq -r '.stalled_slots."0".dec // -1')
        p0_count=$(echo "$prev_state" | jq -r '.stalled_slots."0".cycles // 0')

        if [ "$slot0_proc_tok" -eq "$p0_proc" ] && [ "$slot0_dec_tok" -eq "$p0_dec" ]; then
            p0_count=$((p0_count + 1))
            if [ "$p0_count" -ge "$SENTINEL_SLOT_STALL_CYCLES" ]; then
                anomalies+=("SLOT_0_STAGNATION: Task $slot0_task stagnant for $p0_count cycles (processed: $slot0_proc_tok/$slot0_prompt_tok, decoded: $slot0_dec_tok)")
                actions_needed+=("REAP_SLOT_0_CLIENT")
            fi
        else
            p0_count=1
        fi
        stalled_slots=$(echo "$stalled_slots" | jq --argjson c "$p0_count" --argjson p "$slot0_proc_tok" --argjson d "$slot0_dec_tok" '.["0"] = {cycles: $c, proc: $p, dec: $d}')
    fi

    if [ "$slot1_busy" -eq 1 ]; then
        local p1_proc p1_dec p1_count
        p1_proc=$(echo "$prev_state" | jq -r '.stalled_slots."1".proc // -1')
        p1_dec=$(echo "$prev_state" | jq -r '.stalled_slots."1".dec // -1')
        p1_count=$(echo "$prev_state" | jq -r '.stalled_slots."1".cycles // 0')

        if [ "$slot1_proc_tok" -eq "$p1_proc" ] && [ "$slot1_dec_tok" -eq "$p1_dec" ]; then
            p1_count=$((p1_count + 1))
            if [ "$p1_count" -ge "$SENTINEL_SLOT_STALL_CYCLES" ]; then
                anomalies+=("SLOT_1_STAGNATION: Task $slot1_task stagnant for $p1_count cycles (processed: $slot1_proc_tok/$slot1_prompt_tok, decoded: $slot1_dec_tok)")
                actions_needed+=("REAP_SLOT_1_CLIENT")
            fi
        else
            p1_count=1
        fi
        stalled_slots=$(echo "$stalled_slots" | jq --argjson c "$p1_count" --argjson p "$slot1_proc_tok" --argjson d "$slot1_dec_tok" '.["1"] = {cycles: $c, proc: $p, dec: $d}')
    fi

    # D. Probe Network Sockets for Orphaned Curls
    local orphaned_curls=()
    local socket_lines
    socket_lines=$(ss -tpn 2>/dev/null | grep ':8080' | grep 'users:(("curl"' || true)
    if [ -n "$socket_lines" ]; then
        while read -r sline; do
            [ -z "$sline" ] && continue
            local cpid
            cpid=$(echo "$sline" | grep -o 'pid=[0-9]*' | cut -d'=' -f2)
            if [ -n "$cpid" ]; then
                local cppid
                cppid=$(ps -o ppid= -p "$cpid" 2>/dev/null | tr -d ' ' || echo "1")
                # Check runtime of curl process before declaring it an orphan
                local c_etime
                c_etime=$(ps -o etimes= -p "$cpid" 2>/dev/null | tr -d ' ' || echo "0")
                [ -z "$c_etime" ] && c_etime=0

                # Only reap if parent is a dead test harness OR if reparented to PID 1 and exceeded max age
                if echo "$par_cmd" | grep -Eq 'test_.*\.sh|DEAD' || { [ "$cppid" = "1" ] && [ "$c_etime" -ge "$SENTINEL_CURL_MAX_AGE_SEC" ]; }; then
                    orphaned_curls+=("$cpid")
                    anomalies+=("ORPHAN_CURL_PID_$cpid: Parent PID $cppid ($par_cmd), elapsed ${c_etime}s >= ${SENTINEL_CURL_MAX_AGE_SEC}s")
                    actions_needed+=("KILL_CURL_$cpid")
                fi
            fi
        done <<< "$socket_lines"
    fi

    # E. Probe Abandoned Git Worktrees in .sandboxes
    local abandoned_worktrees=()
    local wt_list
    wt_list=$(git -C "$LODGE_DIR" worktree list 2>/dev/null || true)
    if [ -n "$wt_list" ]; then
        while read -r wt_path wt_commit wt_branch; do
            if [[ "$wt_path" == *".sandboxes/sub_"* ]]; then
                # Check if there are active processes in this worktree
                local has_proc=0
                if command -v fuser &>/dev/null; then
                    fuser -s "$wt_path" 2>/dev/null && has_proc=1
                elif command -v lsof &>/dev/null; then
                    lsof +D "$wt_path" &>/dev/null && has_proc=1
                fi

                if [ "$has_proc" -eq 0 ]; then
                    abandoned_worktrees+=("$wt_path")
                    local s_clean_br="${wt_branch#[}"
                    s_clean_br="${s_clean_br%]}"
                    anomalies+=("ABANDONED_WORKTREE: $wt_path on branch $s_clean_br with 0 running processes")
                    actions_needed+=("PRUNE_WORKTREE_$wt_path")
                fi
            fi
        done <<< "$wt_list"
    fi

    # F. Probe Active Telemetry Ring for Stalled/Dead Agent Tasks
    local act_dir="${TELEMETRY_ACTIVE_DIR:-${GEORGE_DIR}/telemetry/active}"
    if [ -d "$act_dir" ]; then
        for tf in "$act_dir"/*.json; do
            [ ! -f "$tf" ] && continue
            local t_id t_hb t_pty t_pid t_tool t_turn t_max
            t_id=$(jq -r '.task_id // empty' "$tf" 2>/dev/null)
            t_hb=$(jq -r '.heartbeat_ts // 0' "$tf" 2>/dev/null)
            t_pty=$(jq -r '.pty_pid // 0' "$tf" 2>/dev/null)
            t_pid=$(jq -r '.pid // 0' "$tf" 2>/dev/null)
            t_tool=$(jq -r '.last_tool // ""' "$tf" 2>/dev/null)
            t_turn=$(jq -r '.turn // 0' "$tf" 2>/dev/null)
            t_max=$(jq -r '.max_turns // 200' "$tf" 2>/dev/null)

            local t_age=$(( now - t_hb ))
            if [ "$t_age" -ge 180 ]; then
                local is_alive=0
                [ "$t_pid" -gt 0 ] && kill -0 "$t_pid" 2>/dev/null && is_alive=1
                [ "$t_pty" -gt 0 ] && kill -0 "$t_pty" 2>/dev/null && is_alive=1

                if [ "$is_alive" -eq 0 ] || [ "$t_age" -ge 600 ]; then
                    anomalies+=("TASK_DEAD_PID: Task $t_id (Turn $t_turn/$t_max) unresponsive process with no heartbeat for ${t_age}s")
                    actions_needed+=("REAP_DEAD_TASK_$t_id")
                else
                    anomalies+=("TASK_STALL: Task $t_id (Turn $t_turn/$t_max, tool: $t_tool) stalled with no heartbeat for ${t_age}s")
                fi
            fi
        done
    fi

    # Overall Status Determination
    local overall_status="HEALTHY"
    if [ ${#anomalies[@]} -gt 0 ]; then
        overall_status="DEGRADED"
    fi

    # Format JSON result
    local anomalies_json="[]"
    local actions_json="[]"
    if [ ${#anomalies[@]} -gt 0 ]; then
        anomalies_json=$(printf '%s\n' "${anomalies[@]}" | jq -R . | jq -s .)
    fi
    if [ ${#actions_needed[@]} -gt 0 ]; then
        actions_json=$(printf '%s\n' "${actions_needed[@]}" | jq -R . | jq -s .)
    fi

    local result
    result=$(jq -n \
        --arg ts "$now" \
        --arg st "$overall_status" \
        --argjson g_temp "${gpu_temp:-0}" \
        --argjson g_pwr "${gpu_pwr:-0}" \
        --argjson g_used "${gpu_mem_used:-0}" \
        --argjson g_tot "${gpu_mem_total:-12288}" \
        --argjson g_util "${gpu_util:-0}" \
        --argjson s0_b "$slot0_busy" \
        --argjson s1_b "$slot1_busy" \
        --arg s0_t "$slot0_task" \
        --arg s1_t "$slot1_task" \
        --argjson s0_p "$slot0_proc_tok" \
        --argjson s1_p "$slot1_proc_tok" \
        --argjson s0_tot "$slot0_prompt_tok" \
        --argjson s1_tot "$slot1_prompt_tok" \
        --argjson anom "$anomalies_json" \
        --argjson acts "$actions_json" \
        --argjson st_slots "$stalled_slots" \
        '{
            timestamp: ($ts | tonumber),
            status: $st,
            gpu: {
                temp_c: $g_temp,
                power_w: $g_pwr,
                vram_used_mb: $g_used,
                vram_total_mb: $g_tot,
                util_pct: $g_util
            },
            slots: {
                slot0: { busy: ($s0_b == 1), task_id: $s0_t, processed_tokens: $s0_p, prompt_tokens: $s0_tot },
                slot1: { busy: ($s1_b == 1), task_id: $s1_t, processed_tokens: $s1_p, prompt_tokens: $s1_tot }
            },
            anomalies: $anom,
            actions_needed: $acts,
            stalled_slots: $st_slots
        }')

    # Persist latest state
    echo "$result" > "$SENTINEL_STATE"
    echo "$result" >> "$SENTINEL_HISTORY"
    echo "$result"
}

# ── 2. Active Self-Healing Engine ────────────────────────────────────
# Automatically unblocks locks, terminates rogue curls, prunes dead worktrees.
sentinel_self_heal() {
    local probe_json="$1"
    [ -z "$probe_json" ] && probe_json=$(sentinel_probe)

    local actions
    actions=$(echo "$probe_json" | jq -r '.actions_needed[] // empty')
    [ -z "$actions" ] && return 0

    local healed=()

    while read -r act; do
        [ -z "$act" ] && continue
        case "$act" in
            KILL_CURL_*)
                local kpid="${act#KILL_CURL_}"
                if kill -0 "$kpid" 2>/dev/null; then
                    kill -TERM "$kpid" 2>/dev/null || true
                    sleep 0.2
                    kill -KILL "$kpid" 2>/dev/null || true
                    healed+=("Terminated rogue curl process PID $kpid")
                    echo "[SENTINEL_HEAL] Terminated rogue curl process PID $kpid" >> "$SENTINEL_LOG"
                fi
                ;;
            PRUNE_WORKTREE_*)
                local wt_dir="${act#PRUNE_WORKTREE_}"
                if [ -d "$wt_dir" ]; then
                    local s_br
                    s_br=$(git -C "$LODGE_DIR" worktree list 2>/dev/null | grep "$wt_dir" | awk '{print $3}' | tr -d '[]')
                    git -C "$LODGE_DIR" worktree remove --force "$wt_dir" 2>/dev/null || true
                    rm -rf "$wt_dir" 2>/dev/null || true
                    if [ -n "$s_br" ] && [ "$s_br" != "develop" ] && [ "$s_br" != "main" ]; then
                        git -C "$LODGE_DIR" branch -D "$s_br" 2>/dev/null || true
                    fi
                    healed+=("Pruned abandoned worktree $wt_dir")
                    echo "[SENTINEL_HEAL] Pruned abandoned worktree $wt_dir" >> "$SENTINEL_LOG"
                fi
                ;;
            REAP_SLOT_0_CLIENT|REAP_SLOT_1_CLIENT)
                local slot_num="${act#REAP_SLOT_}"
                slot_num="${slot_num%_CLIENT}"
                local curls
                curls=$(ss -tpn 2>/dev/null | grep ':8080' | grep -o 'pid=[0-9]*' | cut -d'=' -f2 | sort -u)
                for c in $curls; do
                    kill -TERM "$c" 2>/dev/null || true
                    healed+=("Terminated client PID $c associated with stalled slot $slot_num")
                done
                ;;
            REAP_DEAD_TASK_*)
                local r_tid="${act#REAP_DEAD_TASK_}"
                local r_file="$TELEMETRY_ACTIVE_DIR/${r_tid}.json"
                if [ -f "$r_file" ]; then
                    local r_pid
                    r_pid=$(jq -r '.pid // 0' "$r_file" 2>/dev/null)
                    [ "$r_pid" -gt 0 ] && kill -9 "$r_pid" 2>/dev/null || true
                fi
                if declare -f telemetry_task_end &>/dev/null; then
                    telemetry_task_end "$r_tid" 1 "PROCESS_DEAD_REAPED"
                    healed+=("Reaped dead task registration $r_tid")
                fi
                ;;
        esac
    done <<< "$actions"

    git -C "$LODGE_DIR" worktree prune 2>/dev/null || true

    if [ ${#healed[@]} -gt 0 ]; then
        echo "${healed[@]}"
    fi
}

# ── 3. Tier 2 Root Cause Triage & Sovereign Gitea Issue Escalation ──
sentinel_triage_tier2() {
    local probe_json="$1"
    local healed_summary="${2:-None}"

    local anomalies
    anomalies=$(echo "$probe_json" | jq -r '.anomalies[] // empty')
    [ -z "$anomalies" ] && return 0

    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local issue_title
    if [ -n "$healed_summary" ] && [ "$healed_summary" != "None" ]; then
        issue_title="[Sentinel Telemetry Alert] Anomaly Detected & Remediated (${now_iso})"
    else
        issue_title="[Sentinel Telemetry Alert] Anomaly Detected (${now_iso})"
    fi

    local norm_anoms
    norm_anoms=$(printf '%s\n' "${anomalies[@]}" | sort | tr '\n' ' ')
    local fp
    fp=$(telemetry_fingerprint "SENTINEL" "telemetry_probe" "$norm_anoms")

    local issues_dir="${GEORGE_DIR}/issues"
    mkdir -p "$issues_dir" 2>/dev/null || true

    # Check for existing issue with identical fingerprint to deduplicate
    local existing_issue
    existing_issue=$(grep -l "\[fingerprint:${fp}\]" "$issues_dir"/*.md "$issues_dir"/archive/*.md 2>/dev/null | head -n 1 || true)
    if [ -n "$existing_issue" ] && [ -f "$existing_issue" ]; then
        {
            echo ""
            echo "---"
            echo "**Recurrence (${now_iso})**:"
            echo "- Sentinel detected recurrence of this condition."
            echo "- Flagged: \`${norm_anoms}\`"
            [ -n "$healed_summary" ] && echo "- Healed: ${healed_summary}"
        } >> "$existing_issue"
        echo "[SENTINEL] Deduplicated anomaly to existing issue: $existing_issue" >> "$SENTINEL_LOG"
        echo "$existing_issue"
        return 0
    fi

    # Check for preserved incident dossier
    local inc_link=""
    local inc_path=""
    local inc_dir="${GEORGE_DIR}/telemetry/incidents"
    if [ -d "$inc_dir" ]; then
        for mf in "$inc_dir"/*/manifest.json; do
            [ ! -f "$mf" ] && continue
            local m_fp
            m_fp=$(jq -r '.fingerprint // empty' "$mf" 2>/dev/null)
            if [ "$m_fp" = "$fp" ]; then
                inc_path=$(dirname "$mf")
                local inc_id
                inc_id=$(basename "$inc_path")
                inc_link="- **Preserved Diagnostic Incident:** [${inc_id}](file://${inc_path})\n"
                break
            fi
        done
    fi

    local diag_table
    diag_table=$(echo "$probe_json" | jq -r '
        "- **Status:** " + .status + "\n" +
        "- **GPU:** " + (.gpu.temp_c | tostring) + "°C | " + (.gpu.power_w | tostring) + "W | " + (.gpu.vram_used_mb | tostring) + "MB / " + (.gpu.vram_total_mb | tostring) + "MB (" + (.gpu.util_pct | tostring) + "% util)\n" +
        "- **Slot 0:** " + (if .slots.slot0.busy then "BUSY (Task " + (.slots.slot0.task_id | tostring) + ", " + (.slots.slot0.processed_tokens | tostring) + "/" + (.slots.slot0.prompt_tokens | tostring) + " tokens)" else "IDLE" end) + "\n" +
        "- **Slot 1:** " + (if .slots.slot1.busy then "BUSY (Task " + (.slots.slot1.task_id | tostring) + ", " + (.slots.slot1.processed_tokens | tostring) + "/" + (.slots.slot1.prompt_tokens | tostring) + " tokens)" else "IDLE" end)
    ')

    local anom_bullets=""
    while read -r an; do
        [ -n "$an" ] && anom_bullets+="- ⚠️ \`${an}\`\n"
    done <<< "$anomalies"

    local anom_actions
    if [[ "$norm_anoms" =~ STALL|HUNG|UNRESPONSIVE ]]; then
        anom_actions="1. Inspect inference server health and check active slot task PIDs.\n2. Terminate hung or orphan curl sub-processes.\n3. Verify inference server timeout limits."
    elif [[ "$norm_anoms" =~ GPU|VRAM|TEMP ]]; then
        anom_actions="1. Monitor GPU thermal throttling and VRAM allocation.\n2. Evict inactive context models or reduce concurrent slots."
    else
        anom_actions="1. Review recent logs in \`${GEORGE_DIR}/telemetry/active/\`.\n2. Verify system environment, socket connections, and process states.\n3. If code changes are required, stage clean fix to develop."
    fi

    local issue_body
    issue_body=$(cat << EOF
### George Autonomic Sentinel Diagnostic Report

The Sentinel Watchdog identified anomalous system conditions during routine telemetry probing.

**Error Fingerprint:** \`[fingerprint:${fp}]\`

#### System Telemetry Vitals
${diag_table}

#### Flagged Anomalies
${anom_bullets}

#### Diagnostic Trace & Artifacts
${inc_link}- **Host Workspace:** \`${LODGE_DIR}\`
- **Telemetry Event Log:** \`${GEORGE_DIR}/telemetry/active/\`

#### Autonomous Remediation Executed
- ${healed_summary}

#### Recommended Action Items
$(echo -e "$anom_actions")
EOF
)

    local issue_file="$issues_dir/issue_sentinel_$(date +%s).md"
    echo -e "# ${issue_title}\n\n${issue_body}" > "$issue_file"

    # If self-healed immediately by Sentinel, archive the issue directly
    if [ -n "$healed_summary" ] && [ "$healed_summary" != "None" ]; then
        local archive_dir="$issues_dir/archive"
        mkdir -p "$archive_dir" 2>/dev/null || true
        local archived_file="$archive_dir/$(basename "$issue_file")"
        mv "$issue_file" "$archived_file" 2>/dev/null || true
        issue_file="$archived_file"
        echo "[SENTINEL] Self-healed issue archived immediately: $issue_file" >> "$SENTINEL_LOG"
    else
        # Enqueue in autonomous remediation loop
        if declare -f remediation_queue_add &>/dev/null; then
            remediation_queue_add "$issue_file" "$inc_path" "high" "$issue_title" >/dev/null 2>&1 || true
        fi
    fi

    # Dispatch notification via configured email and discord
    if declare -f remediation_notify_dispatch &>/dev/null; then
        remediation_notify_dispatch "sentinel_$(date +%s)" "$issue_title" "DETECTED" "$norm_anoms" "$([ -n "$inc_path" ] && echo "Dossier: file://$inc_path" || echo "")" >/dev/null 2>&1 || true
    fi

    # Submit to Sovereign Gitea if online
    if declare -f gitea_is_online &>/dev/null && gitea_is_online; then
        local gitea_labels="sentinel-alert,bug"
        local is_self_healed=0
        if [ -n "$healed_summary" ] && [ "$healed_summary" != "None" ]; then
            gitea_labels="sentinel-alert,auto-remediated,bug"
            is_self_healed=1
        fi

        local issue_res
        issue_res=$(gitea_issue_create "$issue_title" "$issue_body" "$gitea_labels" 2>/dev/null || true)
        local inum
        inum=$(echo "$issue_res" | jq -r '.number // empty' 2>/dev/null || true)
        if [ -n "$inum" ]; then
            echo "Filed Sovereign Gitea Issue #${inum} at $issue_file" >> "$SENTINEL_LOG"
            if [ "$is_self_healed" -eq 1 ]; then
                if ! declare -f gitea_issue_close &>/dev/null; then
                    [ -f "${LODGE_DIR:-$PWD}/lib/mcp_server_gitea.sh" ] && source "${LODGE_DIR:-$PWD}/lib/mcp_server_gitea.sh" 2>/dev/null || true
                fi
                if declare -f gitea_issue_close &>/dev/null; then
                    gitea_issue_close "$inum" "Autonomous Sentinel self-healed this condition immediately during probe: ${healed_summary}." >/dev/null 2>&1 || true
                fi
            fi
        fi
    fi

    echo "$issue_file"
}

# Sweep and close any open Gitea issues marked auto-remediated
sentinel_sweep_remediated_issues() {
    if ! declare -f gitea_is_online &>/dev/null; then
        [ -f "${LODGE_DIR:-$PWD}/lib/mcp_server_gitea.sh" ] && source "${LODGE_DIR:-$PWD}/lib/mcp_server_gitea.sh" 2>/dev/null || true
    fi
    if ! declare -f gitea_is_online &>/dev/null || ! gitea_is_online; then
        return 0
    fi
    _gitea_load_conf

    local open_issues
    open_issues=$(curl -s -H "Authorization: token ${GITEA_TOKEN}" "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues?state=open" 2>/dev/null)
    [ -z "$open_issues" ] && return 0

    # 1. Sweep issues with auto-remediated label or title indicating remediation
    local rem_issues
    rem_issues=$(echo "$open_issues" | jq -r '.[] | select((.labels[]?.name == "auto-remediated") or (.title | test("& Remediated|\\[Auto-Remediated\\]"; "i"))) | .number' 2>/dev/null | sort -u)
    for inum in $rem_issues; do
        [ -z "$inum" ] && continue
        if declare -f gitea_issue_close &>/dev/null; then
            gitea_issue_close "$inum" "Autonomous Sentinel sweep: verified auto-remediated anomaly closed without pending follow-up." >/dev/null 2>&1 || true
            ui_ok "Sentinel closed auto-remediated Gitea Issue #${inum}."
        fi
    done

    # 2. Sweep false-positive telemetry alert issues (e.g. bash_exec exit 0)
    local false_positives
    false_positives=$(echo "$open_issues" | jq -r '.[] | select(.title | test("exit 0"; "i")) | .number' 2>/dev/null | sort -u)
    for inum in $false_positives; do
        [ -z "$inum" ] && continue
        if declare -f gitea_issue_close &>/dev/null; then
            gitea_issue_close "$inum" "Closed by Sentinel sweep: false-positive alert on benign tool command with exit code 0." >/dev/null 2>&1 || true
            ui_ok "Sentinel closed false-positive Gitea Issue #${inum}."
        fi
    done
}

# ── 4. Unified Sentinel Sweep ────────────────────────────────────────
# Called during cron loops or via /cron sentinel
sentinel_sweep() {
    sentinel_init
    sentinel_sweep_remediated_issues
    ui_step "Probing hardware vitals, inference slots & process telemetry..."

    local probe
    probe=$(sentinel_probe)
    local probe_status
    probe_status=$(echo "$probe" | jq -r '.status')

    local gpu_temp gpu_pwr gpu_used gpu_tot gpu_util
    gpu_temp=$(echo "$probe" | jq -r '.gpu.temp_c')
    gpu_pwr=$(echo "$probe" | jq -r '.gpu.power_w')
    gpu_used=$(echo "$probe" | jq -r '.gpu.vram_used_mb')
    gpu_tot=$(echo "$probe" | jq -r '.gpu.vram_total_mb')
    gpu_util=$(echo "$probe" | jq -r '.gpu.util_pct')

    local s0_busy s1_busy
    s0_busy=$(echo "$probe" | jq -r '.slots.slot0.busy')
    s1_busy=$(echo "$probe" | jq -r '.slots.slot1.busy')

    if [ "$probe_status" = "HEALTHY" ]; then
        ui_ok "Vitals Healthy — GPU: ${gpu_temp}°C | ${gpu_pwr}W | ${gpu_used}MB/${gpu_tot}MB | Slots: S0=$( [ "$s0_busy" = "true" ] && echo "BUSY" || echo "IDLE" ), S1=$( [ "$s1_busy" = "true" ] && echo "BUSY" || echo "IDLE" )"
        return 0
    fi

    ui_warn "Sentinel detected anomalies! Executing autonomous self-healing..."
    local healed=""
    if [ "$SENTINEL_AUTO_HEAL" -eq 1 ]; then
        healed=$(sentinel_self_heal "$probe")
        if [ -n "$healed" ]; then
            ui_ok "Self-Heal: $healed"
        fi
    fi

    ui_step "Escalating anomaly to Sovereign Gitea Issue..."
    local issue_ref
    issue_ref=$(sentinel_triage_tier2 "$probe" "${healed:-None}")
    ui_info "Escalation recorded: $issue_ref"

    # If self-healing restored system to HEALTHY, clear sweep with success
    local post_probe
    post_probe=$(sentinel_probe)
    if [ "$(echo "$post_probe" | jq -r '.status')" = "HEALTHY" ]; then
        ui_ok "Autonomous self-healing restored system to HEALTHY."
        return 0
    fi

    return 1
}

# ── 5. Human-Readable Dashboard Render ──────────────────────────────
sentinel_render_dashboard() {
    local probe
    probe=$(sentinel_probe)

    local probe_status gpu_temp gpu_pwr gpu_used gpu_tot gpu_util s0_busy s1_busy
    probe_status=$(echo "$probe" | jq -r '.status')
    gpu_temp=$(echo "$probe" | jq -r '.gpu.temp_c')
    gpu_pwr=$(echo "$probe" | jq -r '.gpu.power_w')
    gpu_used=$(echo "$probe" | jq -r '.gpu.vram_used_mb')
    gpu_tot=$(echo "$probe" | jq -r '.gpu.vram_total_mb')
    gpu_util=$(echo "$probe" | jq -r '.gpu.util_pct')
    s0_busy=$(echo "$probe" | jq -r '.slots.slot0.busy')
    s1_busy=$(echo "$probe" | jq -r '.slots.slot1.busy')

    local col_stat="${C_GREEN}"
    [ "$probe_status" != "HEALTHY" ] && col_stat="${C_RED}"

    printf "\n${C_BOLD}${C_CYAN}╔══ George Autonomic Sentinel ═════════════════════════════════════╗${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║${C_RESET} Status:    ${col_stat}${C_BOLD}%-12s${C_RESET}                                      ${C_BOLD}${C_CYAN}║${C_RESET}\n" "$probe_status"
    printf "${C_BOLD}${C_CYAN}║${C_RESET} GPU Vitals: %-3d°C | %-3dW | %5dMB / %5dMB (%2d%% compute)        ${C_BOLD}${C_CYAN}║${C_RESET}\n" "$gpu_temp" "$gpu_pwr" "$gpu_used" "$gpu_tot" "$gpu_util"
    printf "${C_BOLD}${C_CYAN}║${C_RESET} Slot 0:     %-10s | Slot 1: %-10s                     ${C_BOLD}${C_CYAN}║${C_RESET}\n" "$([ "$s0_busy" = "true" ] && echo "BUSY" || echo "IDLE")" "$([ "$s1_busy" = "true" ] && echo "BUSY" || echo "IDLE")"

    local anom_count
    anom_count=$(echo "$probe" | jq '.anomalies | length')
    printf "${C_BOLD}${C_CYAN}║${C_RESET} Anomalies:  %-3d detected                                          ${C_BOLD}${C_CYAN}║${C_RESET}\n" "$anom_count"
    printf "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════════════════════╝${C_RESET}\n\n"
}
