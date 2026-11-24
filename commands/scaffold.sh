#!/bin/bash
# ── George Slash Command: /scaffold ──────────────────────────────────
# DESC: Scaffold domain modules, FIFO-IPC workers, and RBAC tools
# USAGE: /scaffold [module <domain> <name> [--polyglot] | ipc <worker> [channel] | tool <name> [cap] | help]

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

cmd_scaffold() {
    local args="$1"
    local workdir="${2:-$PWD}"

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        module|ipc|tool)
            # shellcheck disable=SC2086
            "$LODGE_DIR/bin/scaffold" "$subcmd" $rest
            ;;
        help|--help|-h|"")
            cat <<EOF
/scaffold — Blue Lodge Four-Layer Immune System & Component Generator

Usage:
  /scaffold module <domain> <name> [--polyglot] [--desc "<text>"]
      Generate a domain-partitioned library module and unit test.
      Domains: core, ipc, tools, knowledge, sys, comms, memory, agents, ui.

  /scaffold ipc <worker_name> [channel_id] [--desc "<text>"]
      Generate an async FIFO-IPC worker adhering to sliding-window credit flow
      control and RFC 4122 UUID multi-entity identity linkage.

  /scaffold tool <name> [required_cap] [--desc "<text>"]
      Generate an operator tool with RBAC permission gate and UUID correlation.

Examples:
  /scaffold module ipc ring_buffer --desc "POSIX ring buffer"
  /scaffold module tools code_ast --polyglot --desc "AST analyzer"
  /scaffold ipc sync_worker sync_channel_1
  /scaffold tool flush_cache "workspace:write"
EOF
            ;;
        *)
            ui_err "Unknown scaffolding type: $subcmd"
            "$LODGE_DIR/bin/scaffold" help
            return 1
            ;;
    esac
}
