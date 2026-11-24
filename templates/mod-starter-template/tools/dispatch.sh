#!/usr/bin/env bash
# tools/dispatch.sh — Agent tool dispatcher for __MOD_NAME__
# Invoked by Blue Lodge native_tools_dispatch: dispatch.sh <tool_name> <args_json>
set -euo pipefail

TOOL_NAME="${1:-}"
ARGS_JSON="${2:-}"
[ -z "$ARGS_JSON" ] && ARGS_JSON="{}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf '%s' "$ARGS_JSON" | python3 "$SCRIPT_DIR/cli.py" "$TOOL_NAME"
