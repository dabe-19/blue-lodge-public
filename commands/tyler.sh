#!/usr/bin/env bash
# DESC: The Tyler — Sovereign Home Network Defense Agent & Kali Linux Security Guardian
# Usage: /tyler [status|census|fingerprint --ip <ip>|traffic --ip <ip>|upnp|trust --mac <mac> --level <level>|intervene --ip <ip> --mode <mode>]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
PY_BIN="$LODGE_DIR/.venv/bin/python"
[ -x "$PY_BIN" ] || PY_BIN="python3"

cmd_tyler() {
    local args="${1:-status}"
    local -a _targs=()
    read -r -a _targs <<< "$args"
    [ "${#_targs[@]}" -eq 0 ] && _targs=("status")
    "$PY_BIN" "$LODGE_DIR/lib/tools/tyler_guardian.py" "${_targs[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    "$PY_BIN" "$LODGE_DIR/lib/tools/tyler_guardian.py" "$@"
fi

