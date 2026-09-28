#!/bin/bash
# ── George: Subagent Delegation Engine (2026) ────────────────────────
# Manages child worker agents delegated across the 4-tier model hierarchy.
# Provides git worktree sandboxing, central process registry, in-flight control FIFO,
# 50-turn child limit, 5-turn countdown alert, and zero-orphan lifecycle reaping.

[ -n "${_LIB_SUBAGENTS_LOADED:-}" ] && return 0; _LIB_SUBAGENTS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
SUBAGENTS_REGISTRY="${SUBAGENTS_REGISTRY:-$GEORGE_DIR/subagents.json}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ui_dashboard.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/commands.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/limits.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/alerts.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mcp_server_gitea.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/treesitter.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/pr.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/fifo_ipc.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/react.sh" 2>/dev/null || true

# ── Central Subagents Registry ───────────────────────────────────────
subagents_registry_file() {
    echo "$SUBAGENTS_REGISTRY"
}

subagents_init() {
    mkdir -p "$GEORGE_DIR" 2>/dev/null || true
    if [ ! -f "$SUBAGENTS_REGISTRY" ] || [ ! -s "$SUBAGENTS_REGISTRY" ]; then
        echo "[]" > "$SUBAGENTS_REGISTRY"
    fi
}

subagents_register() {
    local sub_id="$1"
    local pid="$2"
    local parent_pid="$3"
    local tier="$4"
    local model="$5"
    local objective="$6"
    local branch="$7"
    local worktree_dir="$8"
    local max_turns="$9"
    local started_at
    started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")
    local log_file="${GEORGE_DIR}/subagents/${sub_id}.log"

    subagents_init
    mkdir -p "${GEORGE_DIR}/subagents" 2>/dev/null || true
    local tmp_reg="${SUBAGENTS_REGISTRY}.tmp.$$"
    jq --arg id "$sub_id" \
       --arg pid "$pid" \
       --arg ppid "$parent_pid" \
       --arg tier "$tier" \
       --arg model "$model" \
       --arg obj "$objective" \
       --arg br "$branch" \
       --arg wt "$worktree_dir" \
       --arg turns "$max_turns" \
       --arg start "$started_at" \
       --arg log "$log_file" \
       '. += [{
           id: $id,
           pid: ($pid | tonumber? // 0),
           parent_pid: ($ppid | tonumber? // 0),
           tier: $tier,
           model: $model,
           objective: $obj,
           branch: $br,
           worktree_dir: $wt,
           log_file: $log,
           max_turns: ($turns | tonumber? // 200),
           current_turn: 1,
           status: "RUNNING",
           started_at: $start,
           updated_at: $start
       }]' "$SUBAGENTS_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SUBAGENTS_REGISTRY"
}

subagents_set_pid() {
    local sub_id="$1"
    local pid="$2"
    subagents_init
    local tmp_reg="${SUBAGENTS_REGISTRY}.tmp.$$"
    jq --arg id "$sub_id" \
       --arg pid "$pid" \
       'map(if .id == $id then .pid = ($pid | tonumber? // .pid) else . end)' \
       "$SUBAGENTS_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SUBAGENTS_REGISTRY"
}

_subagent_log_event() {
    local sub_id="$1"
    local tag="$2"
    local msg="$3"
    local log_dir="${GEORGE_DIR}/subagents"
    mkdir -p "$log_dir" 2>/dev/null || true
    local log_file="${log_dir}/${sub_id}.log"
    local stream_file="${log_dir}/${sub_id}.stream"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    local formatted
    formatted=$(printf '[%s] [%-11s] %s\n' "$ts" "$tag" "$msg")
    printf '%s\n' "$formatted" >> "$log_file"
    printf '%s\n' "$formatted" >> "$stream_file"
}

subagents_logs() {
    local sub_id="$1"
    local lines="${2:-50}"
    local log_file="${GEORGE_DIR}/subagents/${sub_id}.log"
    if [ -f "$log_file" ]; then
        tail -n "$lines" "$log_file"
    else
        echo "No logs found for subagent $sub_id (expected: $log_file)"
        return 1
    fi
}

subagents_stream() {
    local sub_id="$1"
    local log_file="${GEORGE_DIR}/subagents/${sub_id}.log"
    if [ ! -f "$log_file" ]; then
        echo "Awaiting stream log for subagent $sub_id..."
        local w=0
        while [ ! -f "$log_file" ] && [ "$w" -lt 30 ]; do
            sleep 0.2
            w=$((w + 1))
        done
    fi
    if [ -f "$log_file" ]; then
        tail -f -n 25 "$log_file"
    else
        echo "ERROR: Stream log not found for subagent $sub_id."
        return 1
    fi
}

subagents_update_status() {
    local sub_id="$1"
    local status="$2"
    local turn="${3:-}"
    local result="${4:-}"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")

    subagents_init
    local tmp_reg="${SUBAGENTS_REGISTRY}.tmp.$$"
    jq --arg id "$sub_id" \
       --arg st "$status" \
       --arg turn "$turn" \
       --arg res "$result" \
       --arg now "$now" \
       'map(if .id == $id then
           .status = $st |
           .updated_at = $now |
           (if $turn != "" then .current_turn = ($turn | tonumber? // .current_turn) else . end) |
           (if $res != "" then .result = $res else . end)
       else . end)' "$SUBAGENTS_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SUBAGENTS_REGISTRY"
}

subagents_get_active() {
    subagents_init
    jq -c '[.[] | select(.status == "RUNNING" or .status == "PAUSED")]' "$SUBAGENTS_REGISTRY" 2>/dev/null || echo "[]"
}

_subagent_safe_remove_worktree() {
    local wt="$1"
    [ -z "$wt" ] && return 0
    [ ! -d "$wt" ] && return 0

    # Always try git worktree remove first
    git -C "$LODGE_DIR" worktree remove --force "$wt" 2>/dev/null || true

    # Only fall back to rm -rf if the directory is strictly inside a sandboxes directory
    case "$wt" in
        */.sandboxes/*|*lodge-sandboxes/*)
            rm -rf "$wt" 2>/dev/null || true
            ;;
        *)
            # Refuse to rm -rf system directories like /tmp, /, /home, etc.
            ;;
    esac
}

subagents_reap_orphans() {
    subagents_init
    local running
    running=$(jq -r '.[] | select(.status == "RUNNING" or .status == "PAUSED") | "\(.id)|\(.pid)|\(.branch)|\(.worktree_dir)"' "$SUBAGENTS_REGISTRY" 2>/dev/null || true)
    [ -z "$running" ] && return 0

    while IFS='|' read -r sid spid sbranch swt; do
        [ -z "$sid" ] && continue
        local is_alive=0
        if [ -n "$spid" ] && [ "$spid" -gt 0 ] 2>/dev/null; then
            if kill -0 "$spid" 2>/dev/null; then
                is_alive=1
            fi
        fi

        if [ "$is_alive" -eq 0 ]; then
            declare -f ui_warn &>/dev/null && ui_warn "Reaping orphaned subagent $sid (PID $spid dead)..."
            _subagent_safe_remove_worktree "$swt"
            if [ -n "$sbranch" ]; then
                git -C "$LODGE_DIR" branch -D "$sbranch" 2>/dev/null || true
            fi
            subagents_update_status "$sid" "ORPHAN_REAPED" "" "Process disappeared"
        fi
    done <<< "$running"

    git -C "$LODGE_DIR" worktree prune 2>/dev/null || true
}

subagents_cleanup_all() {
    subagents_init
    local running
    running=$(jq -r '.[] | select(.status == "RUNNING" or .status == "PAUSED") | "\(.id)|\(.pid)|\(.branch)|\(.worktree_dir)"' "$SUBAGENTS_REGISTRY" 2>/dev/null || true)
    [ -z "$running" ] && return 0

    while IFS='|' read -r sid spid sbranch swt; do
        [ -z "$sid" ] && continue
        if [ -n "$spid" ] && [ "$spid" -gt 0 ] 2>/dev/null; then
            if kill -0 "$spid" 2>/dev/null; then
                kill -TERM "$spid" 2>/dev/null || true
            fi
        fi
        _subagent_safe_remove_worktree "$swt"
        if [ -n "$sbranch" ]; then
            git -C "$LODGE_DIR" branch -D "$sbranch" 2>/dev/null || true
        fi
        subagents_update_status "$sid" "KILLED_EXIT" "" "Lodge exit cleanup"
    done <<< "$running"

    git -C "$LODGE_DIR" worktree prune 2>/dev/null || true
}

# ── Subagent Worker Execution Loop ──────────────────────────────────
_subagent_worker_run() {
    local sub_id="$1"
    local target_tier="$2"
    local tier_model="$3"
    local tier_url="$4"
    local tier_roles="$5"
    local objective="$6"
    local parent_context="$7"
    local sub_dir="$8"
    local sub_branch="$9"
    local is_worktree="${10}"
    local sub_fifo="${11}"
    local ctrl_fifo="${12}"
    local max_turns="${13}"

    # Cleanup FIFOs when worker concludes
    local _worker_sub_fifo="${sub_fifo:-}"
    local _worker_ctrl_fifo="${ctrl_fifo:-}"
    _subagent_fifo_cleanup() {
        rm -f "${_worker_sub_fifo:-}" "${_worker_ctrl_fifo:-}" 2>/dev/null || true
    }
    trap _subagent_fifo_cleanup EXIT INT TERM

    _subagent_log_event "$sub_id" "SPAWN" "Tier $target_tier ($tier_model) | Objective: $objective | Worktree: $sub_dir" "$sub_fifo"

    # Determine worker profile: worker_research vs worker (code/files/git)
    local sub_profile="worker"
    if [[ "$objective" =~ (research|query|search|find|analyze|explain|inspect|report) ]] && ! [[ "$objective" =~ (create|edit|fix|update|implement|write|delete|refactor|build|test) ]]; then
        sub_profile="worker_research"
    fi

    # Initialize subagent flow channel
    declare -f fifo_channel_open &>/dev/null && fifo_channel_open "sub_${sub_id}" 5 2>/dev/null || true

    # Configure environment for scoped ReAct worker execution
    export ACTIVE_TIER="$target_tier"
    export ACTIVE_ENDPOINT_URL="$tier_url"
    export ACTIVE_ENDPOINT_MODEL="$tier_model"
    export AGENT_MODE="worker"
    export REACT_TOOL_FILTER="$sub_profile"

    declare -f ui_dashboard_worker_update &>/dev/null && ui_dashboard_worker_update "$sub_id" "starting react worker ($sub_profile)" >&2
    subagents_update_status "$sub_id" "RUNNING" 1

    _subagent_log_event "$sub_id" "START" "Executing scoped ReAct loop in $sub_dir ($sub_profile)" "$sub_fifo"

    local react_ec=0
    local worker_output_log="${GEORGE_DIR}/subagents/${sub_id}.out"
    mkdir -p "${GEORGE_DIR}/subagents" 2>/dev/null || true
    local prev_dir="$PWD"
    cd "$sub_dir" 2>/dev/null || true
    react_run "$objective" "$sub_dir" "$max_turns" 1.0 4096 "$sub_profile" "sub_${sub_id}" "worker" > "$worker_output_log" 2>&1 || react_ec=$?
    cd "$prev_dir" 2>/dev/null || true
    local worker_res=""
    [ -f "$worker_output_log" ] && worker_res=$(cat "$worker_output_log")

    local circuit_tripped=0
    local circuit_reason=""
    local final_result=""
    local final_status="COMPLETED"
    local exit_code=0

    # Handle Circuit Breaker & Failure Quarantine
    if [ "$react_ec" -ne 0 ]; then
        circuit_tripped=1
        circuit_reason="Subagent failed or exited with code $react_ec (Objective: ${objective:0:80}). Escalating to Parent George."
        _subagent_log_event "$sub_id" "CIRCUIT_BREAKER" "$circuit_reason" "$sub_fifo"
        _subagent_log_event "$sub_id" "ALERT_PARENT" "Escalation triggered for subagent $sub_id (worktree: $sub_dir)" "$sub_fifo"

        # 1. Quarantined checkpoint branch commit & push
        local checkpoint_br="checkpoint/${sub_id}"
        if [ -d "$sub_dir" ]; then
            (
                cd "$sub_dir" || exit 0
                git branch -D "$checkpoint_br" >/dev/null 2>&1 || true
                git checkout -B "$checkpoint_br" >/dev/null 2>&1 || true
                git add -A >/dev/null 2>&1 || true
                git commit -m "checkpoint(${sub_id}): state at circuit-breaker trip" >/dev/null 2>&1 || true
            )
            git -C "$LODGE_DIR" push gitea "$checkpoint_br" >/dev/null 2>&1 || true
        fi

        # 2. Create structured Issue on Sovereign Gitea
        local issue_num="" issue_url=""
        if declare -f gitea_is_online &>/dev/null && gitea_is_online; then
            local issue_title="[Escalation] Subagent ${sub_id} blocked: ${objective:0:60}"
            local issue_body
            issue_body=$(printf "### Subagent Circuit Breaker Escalation\n\n- **Subagent ID:** \`%s\`\n- **Tier:** %s (\`%s\`)\n- **Objective:** %s\n- **Checkpoint Branch:** \`%s\`\n- **Sandbox Worktree:** \`%s\`\n\n#### Diagnostic Trace:\n\`\`\`\n%s\n\`\`\`\n" \
                "$sub_id" "$target_tier" "$tier_model" "$objective" "$checkpoint_br" "$sub_dir" "${worker_res: -2000}")
            local issue_res
            issue_res=$(gitea_issue_create "$issue_title" "$issue_body" "escalation,blocked" 2>/dev/null || true)
            issue_num=$(echo "$issue_res" | jq -r .number 2>/dev/null || true)
            issue_url=$(echo "$issue_res" | jq -r .html_url 2>/dev/null || true)
        fi

        # 3. Dispatch Multi-Tier Alert
        local ctx_json
        ctx_json=$(jq -n \
            --arg sub "$sub_id" \
            --arg tier "$target_tier" \
            --arg model "$tier_model" \
            --arg br "$checkpoint_br" \
            --arg wt "$sub_dir" \
            --arg is_num "${issue_num:-}" \
            '{ subagent_id: $sub, tier: $tier, model: $model, checkpoint: $br, worktree: $wt, issue_number: $is_num }')
        alerts_dispatch tier1 "Subagent $sub_id Blocked" "$circuit_reason" "${issue_url:-}" "$ctx_json" >/dev/null 2>&1 || true

        exit_code=75
        final_status="PAUSED_BLOCKED"
        final_result="⚡ [CIRCUIT BREAKER] $circuit_reason"
    else
        # Success Path: Deliverable auto-commit & Sovereign Gitea PR Promotion
        final_result="$worker_res"
        if [ "$is_worktree" -eq 1 ] && [ -d "$sub_dir" ]; then
            (
                cd "$sub_dir" || exit 0
                if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
                    GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-George}" \
                    GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-george@bluelodge.local}" \
                    GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-George}" \
                    GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-george@bluelodge.local}" \
                    git add -A 2>/dev/null || true
                    git commit -q -m "subagent(${sub_id}): deliverable for ${objective:0:50}" 2>/dev/null || true
                fi
            )
            _subagent_log_event "$sub_id" "DELIVERABLE" "Deliverables auto-committed to branch $sub_branch in $sub_dir" "$sub_fifo"

            # Check if code changes were introduced against develop
            local branch_diff
            branch_diff=$(git -C "$LODGE_DIR" diff "develop..$sub_branch" --stat 2>/dev/null || echo "")
            if [ -n "$branch_diff" ]; then
                # Push branch to Gitea
                git -C "$LODGE_DIR" push gitea "$sub_branch" >/dev/null 2>&1 || true

                # Check if PR already exists or needs creation
                local pr_ref=""
                if [ ! -f "$sub_dir/.pr_issued" ]; then
                    local pr_out
                    pr_out=$(pr_create "$sub_branch" "feat(${sub_id}): ${objective:0:60}" "Automated subagent deliverable.\n\n### Objective\n${objective}\n\n### Diffstat\n\`\`\`\n${branch_diff:0:1000}\n\`\`\`" "develop" 2>&1)
                    touch "$sub_dir/.pr_issued" 2>/dev/null || true
                    pr_ref=$(echo "$pr_out" | grep -oE '(PR-[0-9]+|pulls/[0-9]+)' | head -1 || echo "")
                    [ -z "$pr_ref" ] && pr_ref="$pr_out"
                fi
                _subagent_log_event "$sub_id" "PR_CREATED" "Pull Request created ($pr_ref)" "$sub_fifo"
                final_result=$(printf "Subagent completed deliverable.\nBranch: %s\nPR: %s\n\n%s" "$sub_branch" "${pr_ref:-submitted}" "$worker_res")
            fi
        fi
    fi

    subagents_update_status "$sub_id" "$final_status" 1 "$final_result"
    declare -f ui_dashboard_worker_finish &>/dev/null && ui_dashboard_worker_finish "$sub_id" "$exit_code" >&2
    _subagent_log_event "$sub_id" "FINISH" "Status: $final_status" "$sub_fifo"

    echo "$final_result"
    _subagent_fifo_cleanup 2>/dev/null || true
    trap - EXIT INT TERM
    return "$exit_code"
}

# ── Subagent Dispatcher ──────────────────────────────────────────────
# Spawns a dedicated subagent on the specified tier to accomplish a delegated goal.
# Usage: subagents_spawn <tier> <objective> [context] [workdir] [max_turns] [is_async]
subagents_spawn() {
    local target_tier="$1"
    local objective="$2"
    local parent_context="${3:-}"
    local workdir="${4:-$PWD}"
    local max_turns="${5:-${AGENT_CHILD_MAX_TURNS:-200}}"
    local is_async="${6:-0}"

    if [ -z "$target_tier" ] || [ -z "$objective" ]; then
        echo "ERROR: subagents_spawn requires tier and objective arguments."
        return 1
    fi

    endpoints_init 2>/dev/null || true

    # Check if target tier is available
    if ! endpoints_probe "$target_tier"; then
        local t_name
        t_name=$(endpoints_get_tier_info "$target_tier" "NAME")
        echo "ERROR: Tier $target_tier ($t_name) is currently offline or unreachable."
        return 1
    fi

    local tier_name tier_url tier_model tier_ctx tier_roles
    tier_name=$(endpoints_get_tier_info "$target_tier" "NAME")
    tier_url=$(endpoints_get_tier_info "$target_tier" "URL")
    tier_model=$(endpoints_get_tier_info "$target_tier" "MODEL")
    tier_ctx=$(endpoints_get_tier_info "$target_tier" "CONTEXT")
    tier_roles=$(endpoints_get_tier_info "$target_tier" "ROLES")

    # Generate unique subagent ID and isolated runtime directory in git worktree
    local sub_id="sub_t${target_tier}_${RANDOM}_$(date +%s)"
    local sub_branch="subagent/${sub_id}"
    local sandbox_base="${LODGE_DIR}/.sandboxes"
    local sub_dir="${sandbox_base}/${sub_id}"
    local is_worktree=0

    mkdir -p "$sandbox_base" 2>/dev/null || true

    local is_research=0
    if [[ "$objective" =~ (research|query|search|find|analyze|explain|inspect|report) ]] && ! [[ "$objective" =~ (create|edit|fix|update|implement|write|delete|refactor|build|test) ]]; then
        is_research=1
        sub_branch=""
    fi

    # Provision git worktree if inside a git repository (branch from develop)
    if [ "$is_research" -eq 0 ] && git -C "$LODGE_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        local base_ref="develop"
        git -C "$LODGE_DIR" rev-parse --verify develop &>/dev/null || base_ref="HEAD"
        if git -C "$LODGE_DIR" worktree add -q -b "$sub_branch" "$sub_dir" "$base_ref" &>/dev/null; then
            is_worktree=1
        fi
    fi

    # Fallback to plain directory if worktree add fails
    if [ ! -d "$sub_dir" ]; then
        mkdir -p "$sub_dir"
    fi

    # Setup FIFOs: stream.fifo and control.fifo
    local sub_fifo="$sub_dir/stream.fifo"
    local ctrl_fifo="$sub_dir/control.fifo"
    rm -f "$sub_fifo" "$ctrl_fifo"
    mkfifo "$sub_fifo" 2>/dev/null || true
    mkfifo "$ctrl_fifo" 2>/dev/null || true

    # Scoped endpoints configuration for child
    mkdir -p "$sub_dir/.george" 2>/dev/null || true
    cat > "$sub_dir/.george/endpoints.conf" <<EOF
# Subagent Scoped Endpoints Configuration
TIER${target_tier}_NAME="${tier_name}"
TIER${target_tier}_URL="${tier_url}"
TIER${target_tier}_MODEL="${tier_model}"
TIER${target_tier}_CONTEXT=${tier_ctx}
TIER${target_tier}_ENABLED=1
EOF
    [ -f "$GEORGE_DIR/keys.conf" ] && cp "$GEORGE_DIR/keys.conf" "$sub_dir/.george/keys.conf" 2>/dev/null || true
    [ -f "$GEORGE_DIR/gitea.conf" ] && cp "$GEORGE_DIR/gitea.conf" "$sub_dir/.george/gitea.conf" 2>/dev/null || true

    # Register in central subagents registry
    subagents_register "$sub_id" "$$" "$$" "$target_tier" "$tier_model" "$objective" "$sub_branch" "$sub_dir" "$max_turns"

    # Register with visual dashboard
    declare -f ui_dashboard_worker_start &>/dev/null && ui_dashboard_worker_start "$sub_id" "$target_tier" "$tier_model" "$objective" >&2

    if [ "$is_async" = "1" ] || [ "$is_async" = "true" ]; then
        export _LODGE_SKIP_SUBAGENT_CLEANUP=1
        (
            _subagent_worker_run "$sub_id" "$target_tier" "$tier_model" "$tier_url" "$tier_roles" \
                "$objective" "$parent_context" "$sub_dir" "$sub_branch" "$is_worktree" \
                "$sub_fifo" "$ctrl_fifo" "$max_turns"
        ) >/dev/null 2>&1 &
        local bg_pid=$!
        subagents_set_pid "$sub_id" "$bg_pid"
        jq -n \
            --arg id "$sub_id" \
            --arg pid "$bg_pid" \
            --arg tier "$target_tier" \
            --arg model "$tier_model" \
            --arg branch "$sub_branch" \
            --arg wt "$sub_dir" \
            --arg log "${GEORGE_DIR}/subagents/${sub_id}.log" \
            '{
                sub_id: $id,
                pid: ($pid | tonumber),
                tier: ($tier | tonumber),
                model: $model,
                branch: $branch,
                worktree: $wt,
                log_file: $log,
                status: "RUNNING"
            }'
        return 0
    else
        _subagent_worker_run "$sub_id" "$target_tier" "$tier_model" "$tier_url" "$tier_roles" \
            "$objective" "$parent_context" "$sub_dir" "$sub_branch" "$is_worktree" \
            "$sub_fifo" "$ctrl_fifo" "$max_turns"
        return $?
    fi
}

# ── Subagent Deliverable & Worktree Management ────────────────────────
subagents_diff() {
    local sub_id="$1"
    local stat_only="${2:-false}"
    if [ -z "$sub_id" ]; then
        echo "ERROR: sub_id is required."
        return 1
    fi
    local branch="subagent/$sub_id"
    if ! git -C "$LODGE_DIR" rev-parse --verify "$branch" &>/dev/null; then
        echo "ERROR: Branch $branch does not exist."
        return 1
    fi
    local diff_cmd=(git -C "$LODGE_DIR" diff HEAD.."$branch")
    [ "$stat_only" = "true" ] && diff_cmd+=(--stat)
    local out
    out=$("${diff_cmd[@]}" 2>&1)
    [ -z "$out" ] && out="No differences between HEAD and $branch."
    echo "$out"
}

subagents_merge() {
    local sub_id="$1"
    local strategy="${2:-merge}"
    if [ -z "$sub_id" ]; then
        echo "ERROR: sub_id is required."
        return 1
    fi
    local branch="subagent/$sub_id"
    if ! git -C "$LODGE_DIR" rev-parse --verify "$branch" &>/dev/null; then
        echo "ERROR: Branch $branch does not exist."
        return 1
    fi
    local out
    if [ "$strategy" = "squash" ]; then
        out=$(git -C "$LODGE_DIR" merge --squash "$branch" 2>&1)
    else
        out=$(git -C "$LODGE_DIR" merge --no-ff -m "Merge subagent deliverable ($sub_id)" "$branch" 2>&1)
    fi
    local code=$?
    echo "$out"
    return "$code"
}

subagents_reap() {
    local sub_id="$1"
    if [ -z "$sub_id" ]; then
        echo "ERROR: sub_id is required."
        return 1
    fi
    local wt_path="${LODGE_DIR}/.sandboxes/$sub_id"
    local branch="subagent/$sub_id"

    # Kill process if still alive in background
    local spid sstat
    spid=$(jq -r --arg id "$sub_id" '.[] | select(.id == $id) | .pid' "$SUBAGENTS_REGISTRY" 2>/dev/null || true)
    sstat=$(jq -r --arg id "$sub_id" '.[] | select(.id == $id) | .status' "$SUBAGENTS_REGISTRY" 2>/dev/null || true)
    if [ "$sstat" = "RUNNING" ] || [ "$sstat" = "PAUSED" ]; then
        if [ -n "$spid" ] && [ "$spid" -gt 0 ] 2>/dev/null && [ "$spid" -ne "$$" ] && kill -0 "$spid" 2>/dev/null; then
            kill -TERM "$spid" 2>/dev/null || true
        fi
    fi

    if [ -d "$wt_path" ]; then
        git -C "$LODGE_DIR" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path" 2>/dev/null || true
    fi
    git -C "$LODGE_DIR" branch -D "$branch" 2>/dev/null || true
    git -C "$LODGE_DIR" worktree prune 2>/dev/null || true

    subagents_update_status "$sub_id" "REAPED" "" "Worktree and branch reaped"
    echo "Worktree $wt_path and branch $branch cleanly reaped."
}

subagents_resume() {
    local sub_id="$1"
    local resolved_pr="${2:-}"
    subagents_init

    local reg_entry
    reg_entry=$(jq -r --arg id "$sub_id" '.[] | select(.id == $id)' "$SUBAGENTS_REGISTRY" 2>/dev/null)
    if [ -z "$reg_entry" ]; then
        ui_err "Subagent '$sub_id' not found in registry."
        return 1
    fi

    local swt sbranch sstatus obj tier model turns
    swt=$(echo "$reg_entry" | jq -r .worktree_dir)
    sbranch=$(echo "$reg_entry" | jq -r .branch)
    sstatus=$(echo "$reg_entry" | jq -r .status)
    obj=$(echo "$reg_entry" | jq -r .objective)
    tier=$(echo "$reg_entry" | jq -r .tier)
    model=$(echo "$reg_entry" | jq -r .model)
    turns=$(echo "$reg_entry" | jq -r .max_turns)

    ui_section "Resuming Subagent $sub_id ($sstatus)"

    if [ -d "$swt" ]; then
        ui_step "Updating worktree at $swt with latest changes from develop..."
        git -C "$swt" fetch origin develop >/dev/null 2>&1 || git -C "$swt" fetch gitea develop >/dev/null 2>&1 || true
        git -C "$swt" merge --no-edit origin/develop >/dev/null 2>&1 || git -C "$swt" merge --no-edit develop >/dev/null 2>&1 || true
        ui_ok "Worktree synchronized with develop."
    else
        ui_err "Worktree directory '$swt' missing. Cannot resume."
        return 1
    fi

    # Update status to RESUMED / RUNNING
    subagents_update_status "$sub_id" "RUNNING" "" "Resumed execution after resolution"

    # Emit resumption event to MQTT
    if declare -f mqtt_publish &>/dev/null; then
        local resume_payload
        resume_payload=$(jq -n \
            --arg id "$sub_id" \
            --arg pr "${resolved_pr:-none}" \
            --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")" \
            '{ event: "WORKER_RESUME", subagent_id: $id, resolved_pr: $pr, timestamp: $ts }')
        mqtt_publish "george/workers/${sub_id}/resume" "$resume_payload" >/dev/null 2>&1 || true
    fi

    ui_ok "Subagent $sub_id resumed."
}

subagents_prune() {
    local opt="${1:-stale}"
    subagents_init

    local entries
    if [ "$opt" = "--all" ] || [ "$opt" = "all" ]; then
        entries=$(jq -r '.[] | "\(.id)|\(.status)|\(.worktree_dir)|\(.branch)"' "$SUBAGENTS_REGISTRY" 2>/dev/null || true)
    else
        entries=$(jq -r '.[] | select(.status == "COMPLETED" or .status == "DONE" or .status == "CRASHED_ORPHAN" or .status == "KILLED_EXIT" or .status == "FAILED" or .status == "REAPED") | "\(.id)|\(.status)|\(.worktree_dir)|\(.branch)"' "$SUBAGENTS_REGISTRY" 2>/dev/null || true)
    fi

    local pruned_count=0
    while IFS='|' read -r sid st swt sbranch; do
        [ -z "$sid" ] && continue
        if [ -n "$swt" ] && [ -d "$swt" ]; then
            _subagent_safe_remove_worktree "$swt"
        fi
        if [ -n "$sbranch" ] && [ "$sbranch" != "develop" ] && [ "$sbranch" != "main" ]; then
            git -C "$LODGE_DIR" branch -D "$sbranch" 2>/dev/null || true
        fi
        pruned_count=$((pruned_count + 1))
    done <<< "$entries"

    git -C "$LODGE_DIR" worktree prune 2>/dev/null || true
    ui_ok "Pruned $pruned_count subagent worktrees and branches."
}

