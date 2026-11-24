#!/bin/bash
# DESC: Read file contents in the current workspace or sandbox
# Usage: /read <filepath> [max_lines] [start_line]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/tools.sh" 2>/dev/null || true

cmd_read() {
    local args="$1"
    local workdir="${2:-.}"

    if [ -z "$args" ]; then
        ui_err "Usage: /read <filepath> [max_lines] [start_line]"
        return 1
    fi

    # Parse args: [filepath] [max_lines] [start_line]
    local filepath max_lines start_line
    filepath=$(echo "$args" | awk '{print $1}')
    max_lines=$(echo "$args" | awk '{print $2}')
    start_line=$(echo "$args" | awk '{print $3}')

    if declare -f ui_clean_path_prefix &>/dev/null; then
        filepath=$(ui_clean_path_prefix "$filepath" "$workdir")
    fi

    local fullpath="$filepath"
    if declare -f ui_resolve_path &>/dev/null; then
        fullpath=$(ui_resolve_path "$filepath" "$workdir" 0 1)
    elif [[ "$fullpath" != /* ]]; then
        fullpath="$workdir/$filepath"
    fi

    if [ -f "$fullpath" ]; then
        if declare -f tools_read_file &>/dev/null; then
            tools_read_file "$fullpath" "${max_lines:-100}" "${start_line:-1}"
            return $?
        fi
        # Fallback if tools_read_file is not loaded
        local s="${start_line:-1}"
        local m="${max_lines:-100}"
        sed -n "${s},$((s + m - 1))p" "$fullpath" | awk -v start="$s" '{print (start + NR - 1) ": " $0}'
        return 0
    elif [ -d "$fullpath" ]; then
        if ! declare -f cmd_ls &>/dev/null && [ -f "$LODGE_DIR/commands/ls.sh" ]; then
            source "$LODGE_DIR/commands/ls.sh" 2>/dev/null || true
        fi
        if declare -f cmd_ls &>/dev/null; then
            cmd_ls "$filepath" "$workdir"
            return $?
        fi
    else
        # ── Recovery Cascade ────────────────────────────────────
        local rec_mode="${AGENT_FILE_RECOVERY:-auto}"
        local filename
        filename=$(basename "$filepath")

        local matches=()
        if [ "$rec_mode" != "off" ] && [ -n "$filename" ]; then
            local m
            while IFS= read -r m || [ -n "$m" ]; do
                [ -n "$m" ] && matches+=("$m")
            done < <(find "${LODGE_DIR:-.}/.george/workspaces" -maxdepth 4 -name "$filename" -type f 2>/dev/null)

            if [ "${#matches[@]}" -eq 0 ] && [ -f "${LODGE_DIR:-.}/$filename" ]; then
                matches+=("${LODGE_DIR:-.}/$filename")
            fi
        fi

        if [ "${#matches[@]}" -gt 0 ]; then
            local matched_file="${matches[0]}"
            local active_ws="${AGENT_TASK_WORKSPACE:-$workdir}"
            if [ -n "$active_ws" ] && [[ "$active_ws" == *".george/workspaces"* ]]; then
                local active_target="$active_ws/$(basename "$matched_file")"
                if [ ! -f "$active_target" ] && [ -f "$matched_file" ]; then
                    mkdir -p "$(dirname "$active_target")"
                    cp "$matched_file" "$active_target" 2>/dev/null
                fi
                if [ -f "$active_target" ]; then
                    matched_file="$active_target"
                fi
            fi
            if [ "$rec_mode" = "auto" ]; then
                local clean_match="$matched_file"
                declare -f ui_clean_path_prefix &>/dev/null && clean_match=$(ui_clean_path_prefix "$matched_file" "${LODGE_DIR:-.}")
                ui_warn "File not found at requested path. Auto-resolved and copied to active task workspace: $clean_match" >&2
                tools_read_file "$matched_file" 100
                return 0
            elif [ "$rec_mode" = "suggest" ]; then
                ui_err "File not found: $filepath"
                ui_info "Discovered matching files in workspaces:"
                local match_path
                for match_path in "${matches[@]}"; do
                    local clean_match="$match_path"
                    declare -f ui_clean_path_prefix &>/dev/null && clean_match=$(ui_clean_path_prefix "$match_path" "${LODGE_DIR:-.}")
                    ui_info "  - $clean_match"
                done
                return 1
            fi
        fi

        ui_err "File not found: $filepath"
        if [ "${AGENT_ASK_USER:-1}" -eq 1 ]; then
            ui_info "[INSTRUCTION] The required file is missing. You must pivot: either ask the operator to provide the content/location using /ask, create it with /write, or terminate the task."
        else
            ui_info "[INSTRUCTION] The required file is missing. Since /ask is disabled, you must immediately terminate the task and report the failure using /respond."
        fi
        declare -f ui_suggest_workspaces_tree &>/dev/null && ui_suggest_workspaces_tree
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_read "$@"
fi
