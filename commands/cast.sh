#!/usr/bin/env bash
# DESC: Broadcast speech or manage Google Home / Cast speakers via local neural TTS
# Usage: /cast [status|discover|speak <text> [--target <room|default|all>] [--voice <alan|ryan|amy|alba>]|volume <target> <0.0-1.0>]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
PY_BIN="$LODGE_DIR/.venv/bin/python"
[ -x "$PY_BIN" ] || PY_BIN="python3"

cmd_cast() {
    local args="${1:-status}"
    # shellcheck disable=SC2086
    eval "$PY_BIN \"$LODGE_DIR/lib/tools/google_home_cast.py\" $args"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    "$PY_BIN" "$LODGE_DIR/lib/tools/google_home_cast.py" "$@"
fi

