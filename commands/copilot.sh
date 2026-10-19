#!/bin/bash
# DESC: Autonomous multi-model Co-Pilot engine for surgical patching, safe commenting, and tool forging
# Usage: /copilot [status|patch|comment|forge] [args...]

_CMD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
LODGE_DIR="${LODGE_DIR:-$(cd "${_CMD_DIR}/.." 2>/dev/null && pwd || echo "$HOME/blue-lodge")}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/native_tools.sh" 2>/dev/null || true

cmd_copilot() {
    local args="$1"
    local workdir="${2:-.}"

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    local py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
    local engine="$LODGE_DIR/lib/tools/copilot_engine.py"

    case "$subcmd" in
        ""|status)
            ui_section "Co-Pilot Engine Status"
            if [ -f "$engine" ]; then
                ui_ok "Engine core: $engine"
                "$py_bin" "$engine" status
            else
                ui_err "Engine core missing at $engine"
                return 1
            fi
            ;;
        patch)
            local target="${rest%% *}"
            local proposed="${rest#"$target"}"
            proposed="${proposed#"${proposed%%[![:space:]]*}"}"
            local instruction=""
            if [[ "$proposed" =~ [[:space:]] ]]; then
                local tmp_prop="${proposed%% *}"
                instruction="${proposed#"$tmp_prop"}"
                instruction="${instruction#"${instruction%%[![:space:]]*}"}"
                proposed="$tmp_prop"
            fi

            if [ -z "$target" ] || [ -z "$proposed" ]; then
                ui_err "Usage: /copilot patch <target_file> <proposed_patch_file> [instruction]"
                return 1
            fi

            ui_step "Synthesizing surgical patch for: $target"
            local res
            res=$(copilot_patch "$target" "$proposed" "$instruction")
            local status=$?
            echo "$res"
            return $status
            ;;
        comment)
            local target="${rest%% *}"
            local opts="${rest#"$target"}"
            opts="${opts#"${opts%%[![:space:]]*}"}"

            if [ -z "$target" ]; then
                ui_err "Usage: /copilot comment <file_path> [--style standard|verbose] [--max-lines N]"
                return 1
            fi

            ui_step "Applying safe AST comments to: $target"
            local style="standard"
            local max_lines=0
            if [[ "$opts" =~ --style[[:space:]]+([^[:space:]]+) ]]; then
                style="${BASH_REMATCH[1]}"
            fi
            if [[ "$opts" =~ --max-lines[[:space:]]+([0-9]+) ]]; then
                max_lines="${BASH_REMATCH[1]}"
            fi

            local res
            res=$(copilot_safe_comment "$target" "$style" "$max_lines")
            local status=$?
            echo "$res"
            return $status
            ;;
        forge)
            local tool_name="${rest%% *}"
            local tool_desc="${rest#"$tool_name"}"
            tool_desc="${tool_desc#"${tool_desc%%[![:space:]]*}"}"

            if [ -z "$tool_name" ] || [ -z "$tool_desc" ]; then
                ui_err "Usage: /copilot forge <tool_name> <description>"
                return 1
            fi

            ui_step "Forging and sandboxing tool: $tool_name"
            local res
            res=$(copilot_tool_forge "$tool_name" "$tool_desc")
            local status=$?
            echo "$res"
            return $status
            ;;
        *)
            ui_err "Unknown /copilot subcommand: '$subcmd'"
            ui_dim "Usage: /copilot [status | patch <target> <proposed> [instruction] | comment <file> | forge <name> <desc>]"
            return 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cmd_copilot "$@"
fi
