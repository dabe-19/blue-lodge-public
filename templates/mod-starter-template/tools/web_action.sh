#!/usr/bin/env bash
# tools/web_action.sh — Direct REST UI action handler (/api/modules/__MOD_ID__/action/:action)
# Receives JSON payload on stdin and prints JSON to stdout.
set -euo pipefail

ACTION="${1:-list}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "$SCRIPT_DIR/cli.py" "$ACTION"
