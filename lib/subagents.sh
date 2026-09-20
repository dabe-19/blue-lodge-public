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
           max_turns: ($turns | tonumber? // 50),
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
            if [ -n "$swt" ] && [ -d "$swt" ]; then
                git -C "$LODGE_DIR" worktree remove --force "$swt" 2>/dev/null || rm -rf "$swt" 2>/dev/null || true
            fi
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
        if [ -n "$swt" ] && [ -d "$swt" ]; then
            git -C "$LODGE_DIR" worktree remove --force "$swt" 2>/dev/null || rm -rf "$swt" 2>/dev/null || true
        fi
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

    local sub_history="$sub_dir/history.log"
    : > "$sub_history"

    # Subagent System Prompt
    local sub_system="You are an autonomous subagent worker (Tier $target_tier: $tier_model).
Role: $tier_roles
Your specific objective: $objective
Parent Context: $parent_context

You operate in an isolated sandbox. You can execute tools via slash commands:
- /web search <query> : Search the web
- /web fetch <url> : Fetch markdown page
- /read <file> : Read file contents
- /bash <cmd> : Execute shell command in workspace
- /respond <text> : Conclude your task and return the final synthesized answer.

Output format for each turn:
Thought: <reasoning>
Action: <slash-command>

When your task is complete, finish with:
Action: /respond <distilled result>"

    local turn=1
    local final_result=""

    while [ "$turn" -le "$max_turns" ]; do
        declare -f ui_dashboard_worker_update &>/dev/null && ui_dashboard_worker_update "$sub_id" "turn $turn/$max_turns" >&2
        subagents_update_status "$sub_id" "RUNNING" "$turn"

        # Check in-flight control FIFO (non-blocking)
        if [ -p "$ctrl_fifo" ]; then
            local ctrl_cmd=""
            read -t 0.05 -r ctrl_cmd <> "$ctrl_fifo" 2>/dev/null || true
            if [ -n "$ctrl_cmd" ]; then
                case "$ctrl_cmd" in
                    PAUSE*)
                        subagents_update_status "$sub_id" "PAUSED" "$turn"
                        _subagent_log_event "$sub_id" "CONTROL" "Paused by parent. Awaiting RESUME..." "$sub_fifo"
                        declare -f ui_info &>/dev/null && ui_info "Subagent $sub_id paused by parent. Awaiting RESUME..."
                        while true; do
                            local resume_cmd=""
                            read -r resume_cmd <> "$ctrl_fifo" 2>/dev/null || true
                            if [[ "$resume_cmd" == RESUME* ]]; then
                                _subagent_log_event "$sub_id" "CONTROL" "Resumed by parent." "$sub_fifo"
                                break
                            fi
                            if [[ "$resume_cmd" == ABORT* ]]; then
                                _subagent_log_event "$sub_id" "CONTROL" "Aborted by parent while paused." "$sub_fifo"
                                final_result="ABORTED_BY_PARENT"
                                break 2
                            fi
                            sleep 0.2
                        done
                        subagents_update_status "$sub_id" "RUNNING" "$turn"
                        ;;
                    ABORT*)
                        _subagent_log_event "$sub_id" "CONTROL" "Aborted by parent." "$sub_fifo"
                        final_result="ABORTED_BY_PARENT"
                        break
                        ;;
                esac
            fi
        fi

        # 5-turn countdown alert for child subagent
        local countdown_notice=""
        if [ "$turn" -ge "$((max_turns - 5))" ]; then
            local rem=$((max_turns - turn))
            _subagent_log_event "$sub_id" "COUNTDOWN" "Approaching turn ceiling: Turn $turn/$max_turns ($rem turn(s) remaining)" "$sub_fifo"
            declare -f ui_warn &>/dev/null && ui_warn "Child subagent $sub_id approaching turn ceiling: Turn $turn/$max_turns ($rem turn(s) remaining)."
            countdown_notice="[SYSTEM NOTICE: APPROACHING TURN CEILING ($rem turn(s) remaining of $max_turns). Cease exploratory actions. Consolidate your deliverables and conclude with /respond.]\n\n"
        fi

        # Build messages payload
        local messages_json
        local recent_obs=""
        if [ -s "$sub_history" ]; then
            recent_obs=$(tail -n 30 "$sub_history")
        fi

        messages_json=$(jq -n \
            --arg sys "$sub_system" \
            --arg goal "$objective" \
            --arg cd "$countdown_notice" \
            --arg obs "$recent_obs" \
            '[
                {"role": "system", "content": $sys},
                {"role": "user", "content": ($cd + "Objective: " + $goal + "\n\nTrajectory:\n" + $obs + "\n\nNext Action:")}
            ]')

        local payload
        payload=$(jq -n \
            --arg model "$tier_model" \
            --argjson msgs "$messages_json" \
            '{
                model: $model,
                messages: $msgs,
                temperature: 0.2,
                max_tokens: 1024
            }')

        # Query endpoint
        local resp_json
        resp_json=$(curl -s --max-time 120 "$tier_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)

        if [ -z "$resp_json" ]; then
            echo "Action: /respond ERROR: Target model endpoint timed out or failed." >> "$sub_history"
            _subagent_log_event "$sub_id" "ERROR" "Target model endpoint timed out or failed." "$sub_fifo"
            final_result="ERROR: Subagent endpoint timed out."
            break
        fi

        local raw_content
        raw_content=$(echo "$resp_json" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

        # Extract and log internal reasoning thoughts if present
        local thoughts=""
        local cleaned="$raw_content"
        if echo "$raw_content" | grep -qE '<think>'; then
            if command -v perl &>/dev/null; then
                thoughts=$(printf '%s' "$raw_content" | perl -0777 -ne 'while (/<think>(.*?)<\/think>/sg) { my $t = $1; $t =~ s/^\s+|\s+$//g; print "$t\n" if $t }')
                cleaned=$(printf '%s' "$raw_content" | perl -0777 -pe 's/<think>.*?<\/think>//sg')
            else
                thoughts=$(echo "$raw_content" | sed -n 's/.*<think>\(.*\)<\/think>.*/\1/p')
                cleaned=$(echo "$raw_content" | sed -e 's/<think>.*<\/think>//g')
            fi
        fi
        if [ -n "$thoughts" ]; then
            _subagent_log_event "$sub_id" "THOUGHT" "$thoughts" "$sub_fifo"
        fi

        # Parse action
        local action=""

        if echo "$cleaned" | grep -qE '^Action:[[:space:]]*/'; then
            action=$(echo "$cleaned" | sed -n 's/^Action:[[:space:]]*\(\/.*\)/\1/p' | head -1)
        elif echo "$cleaned" | grep -qE '^[[:space:]]*/'; then
            action=$(echo "$cleaned" | grep -E '^[[:space:]]*/' | head -1)
            action="${action#"${action%%[![:space:]]*}"}"
        fi

        if [ -z "$action" ]; then
            # If model returned text without action on later turns, treat as completion
            if [ -n "$cleaned" ] && [ "$turn" -gt 1 ]; then
                final_result="$cleaned"
                _subagent_log_event "$sub_id" "RESULT" "$final_result" "$sub_fifo"
                break
            fi
            action="/respond $cleaned"
        fi

        _subagent_log_event "$sub_id" "ACTION" "$action" "$sub_fifo"

        # Check for /respond
        if [[ "$action" == /respond* ]]; then
            final_result="${action#/respond}"
            final_result="${final_result#"${final_result%%[![:space:]]*}"}"
            [ -z "$final_result" ] && final_result="$cleaned"
            _subagent_log_event "$sub_id" "RESULT" "$final_result" "$sub_fifo"
            break
        fi

        # Execute tool inside isolated worktree directory
        echo "Action: $action" >> "$sub_history"
        local obs
        obs=$(commands_dispatch "$action" "$sub_dir" 2>&1)

        # Log observation to persistent stream
        _subagent_log_event "$sub_id" "OBSERVATION" "$obs" "$sub_fifo"

        # Truncate observation to prevent context explosion in history
        if [ ${#obs} -gt 1500 ]; then
            obs="${obs:0:1500}... [truncated]"
        fi
        echo "Observation: $obs" >> "$sub_history"

        turn=$((turn + 1))
    done

    # Preserve and auto-commit deliverables in git worktree
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
    fi

    # Finalize visual dashboard and registry
    local exit_code=0
    [ -z "$final_result" ] && exit_code=1
    local final_status="COMPLETED"
    [ "$exit_code" -ne 0 ] && final_status="FAILED"
    subagents_update_status "$sub_id" "$final_status" "$turn" "$final_result"
    declare -f ui_dashboard_worker_finish &>/dev/null && ui_dashboard_worker_finish "$sub_id" "$exit_code" >&2
    _subagent_log_event "$sub_id" "FINISH" "Status: $final_status | Turns: $turn" "$sub_fifo"

    if [ -z "$final_result" ]; then
        echo "Subagent reached max turns without explicit response."
    else
        echo "$final_result"
    fi

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
    local max_turns="${5:-${AGENT_CHILD_MAX_TURNS:-50}}"
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

    # Provision git worktree if inside a git repository
    if git -C "$LODGE_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        if git -C "$LODGE_DIR" worktree add -q -b "$sub_branch" "$sub_dir" &>/dev/null; then
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

    # Register in central subagents registry
    subagents_register "$sub_id" "$$" "$$" "$target_tier" "$tier_model" "$objective" "$sub_branch" "$sub_dir" "$max_turns"

    # Register with visual dashboard
    declare -f ui_dashboard_worker_start &>/dev/null && ui_dashboard_worker_start "$sub_id" "$target_tier" "$tier_model" "$objective" >&2

    if [ "$is_async" = "1" ] || [ "$is_async" = "true" ]; then
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
