#!/bin/bash
# DESC: Execute shell command in workspace
# Usage: /bash <command...>

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"

cmd_bash() {
    local cmd_str="$1"
    local workdir="${2:-.}"

    if [ -z "$cmd_str" ]; then
        ui_err "Usage: /bash <command...>"
        return 1
    fi

    # Normalize hallucinated directory paths dynamically (portable across systems)
    local target_ws="${LODGE_DIR:-$HOME/blue-lodge}"
    if ! declare -f _nt_rebase_ws_paths &>/dev/null; then
        source "$LODGE_DIR/lib/tools/native_tools.sh" 2>/dev/null || true
    fi
    if declare -f _nt_rebase_ws_paths &>/dev/null; then
        local _cs_0
        _cs_0=$(_nt_rebase_ws_paths "$cmd_str" "$target_ws" 2>/dev/null)
        [ -n "$_cs_0" ] && cmd_str="$_cs_0"
    else
        local _cs_a
        _cs_a=$(echo "$cmd_str" | sed -E "s#(cd[[:space:]]+)?(/home/[^/]+|/Users/[^/]+|~|\$HOME)/blue[ _-][a-zA-Z0-9_-]*(/\.sandboxes/[A-Za-z0-9_.-]+)?#\1${target_ws}\3#g" 2>/dev/null)
        [ -n "$_cs_a" ] && cmd_str="$_cs_a"
        local _prev_c=""
        while [ "$_prev_c" != "$cmd_str" ]; do
            _prev_c="$cmd_str"
            local _cs_b
            _cs_b=$(echo "$cmd_str" | sed -E 's|(\.sandboxes/([^/]+))/\1|\1|g' 2>/dev/null)
            [ -n "$_cs_b" ] && cmd_str="$_cs_b" || break
        done
    fi
    local _cs_c
    _cs_c=$(echo "$cmd_str" | sed -E 's|(https?://)[[:space:]]+|\1|g; s|(https?://[a-zA-Z0-9_-]+)[[:space:]]*\.[[:space:]]*([a-zA-Z0-9_.-]+)|\1.\2|g; s|(https?://[a-zA-Z0-9_.-]+)[[:space:]]*\.[[:space:]]*([a-zA-Z0-9_.-]+)|\1.\2|g; s|\bcurl[[:space:]]+(.*)[[:space:]]*-o[[:space:]]+([a-zA-Z0-9_.-]+/)[[:space:]]*|curl \1 -O --output-dir \2 |g' 2>/dev/null)
    [ -n "$_cs_c" ] && cmd_str="$_cs_c"

    # Resolve task-workspace scripts created by file_write when missing in repo root
    if [ -n "${AGENT_TASK_WORKSPACE:-}" ] && [ -d "$AGENT_TASK_WORKSPACE" ]; then
        local _ws_f _ws_base _cs_ws
        for _ws_f in "$AGENT_TASK_WORKSPACE"/*.py "$AGENT_TASK_WORKSPACE"/*.sh "$AGENT_TASK_WORKSPACE"/*.js; do
            [ -f "$_ws_f" ] || continue
            _ws_base=$(basename "$_ws_f")
            if [ ! -f "$target_ws/$_ws_base" ]; then
                cmd_str="${cmd_str//${target_ws}\/${_ws_base}/${_ws_f}}"
                _cs_ws=$(echo "$cmd_str" | sed -E "s#(^|[[:space:]\"'])(\./)?${_ws_base}([[:space:]\"';|&)]|\$)#\1${_ws_f}\3#g" 2>/dev/null)
                [ -n "$_cs_ws" ] && cmd_str="$_cs_ws"
            fi
        done
    fi

    # Asynchronous Shell Execution (& trailing operator)
    if [[ "$cmd_str" =~ [[:space:]]*\&[[:space:]]*$ ]] && [ "${_LODGE_IN_ASYNC_DISPATCH:-0}" -ne 1 ]; then
        local _clean_cmd="${cmd_str%&}"
        _clean_cmd="${_clean_cmd%"${_clean_cmd%%[![:space:]]*}"}"
        source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null || true
        if declare -f ipc_async &>/dev/null; then
            local _async_cid="sh_$(date +%s)_$RANDOM"
            local _prom_id
            _prom_id=$(export _LODGE_IN_ASYNC_DISPATCH=1; ipc_async "$_async_cid" "cmd_bash '$_clean_cmd' '$workdir'")
            if [ -n "$_prom_id" ]; then
                if declare -f telemetry_tool_start &>/dev/null; then
                    telemetry_tool_start "async_shell" "$_prom_id" "bash_exec" "$(jq -nc --arg cmd "$_clean_cmd" '{command: $cmd}')" "$_async_cid"
                fi
                echo ""
                printf " %b╭─────────────────────────────────────────────────────────────╮%b\n" "$C_LODGE" "$C_RESET"
                printf " %b│%b  %b⚡ Background Shell Command Dispatched%b                     %b│%b\n" "$C_LODGE" "$C_RESET" "$C_BOLD$C_GREEN" "$C_RESET" "$C_LODGE" "$C_RESET"
                printf " %b╰─────────────────────────────────────────────────────────────╯%b\n" "$C_LODGE" "$C_RESET"
                printf "   %bCommand:%b     %s\n" "$C_DIM" "$C_RESET" "$_clean_cmd"
                printf "   %bPromise ID:%b  %b%s%b\n" "$C_DIM" "$C_RESET" "$C_CYAN" "$_prom_id" "$C_RESET"
                printf "   %bChannel:%b     %s\n" "$C_DIM" "$C_RESET" "$_async_cid"
                printf "   %bStatus:%b      %b[RUNNING]%b\n" "$C_DIM" "$C_RESET" "$C_GREEN" "$C_RESET"
                echo ""
                printf "   %bInspect / Await:%b  /ipc await %s [timeout_seconds]\n" "$C_DIM" "$C_RESET" "$_prom_id"
                printf "   %bCancel Task:%b      /ipc cancel %s\n" "$C_DIM" "$C_RESET" "$_prom_id"
                printf "   %bTask Telemetry:%b   /telemetry active\n" "$C_DIM" "$C_RESET"
                echo ""
                return 0
            fi
        fi
    fi

    local _watchdog_timeout="${SHELL_EXEC_TIMEOUT:-60}"
    (
        cd "$workdir" || exit 1
        export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$LODGE_DIR:$PATH"
        if command -v timeout &>/dev/null; then
            timeout "${_watchdog_timeout}s" bash -c "source '$LODGE_DIR/lib/tools/mcp_server_gitea.sh' 2>/dev/null || true; $cmd_str"
        else
            bash -c "source '$LODGE_DIR/lib/tools/mcp_server_gitea.sh' 2>/dev/null || true; $cmd_str"
        fi
    )
    return $?
}

# Alias /sh to /bash
cmd_sh() {
    cmd_bash "$@"
}
