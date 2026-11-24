#!/bin/bash
# DESC: Sovereign SDR Radio Lab & TrunkRecorder Hook for P25 Public Safety OSINT
# Usage:
#   /sdr status               — Show SDR ingest status, pending spool calls, and gateway config
#   /sdr stats [hours]        — Show call volume and talkgroup activity summary
#   /sdr query <search>       — Search transcribed radio calls
#   /sdr talkgroup <tg>       — Query calls by talkgroup / department
#   /sdr unit <unit_id>       — Reconstruct timeline for a specific radio unit
#   /sdr listen [call_id]     — Inspect or analyze a specific call audio
#   /sdr ingest               — Ingest and process all pending P25 calls in local spool
#   /sdr sync                 — Rsync recent recordings from remote SDR gateway
#   /sdr prune                — Prune excess audio recordings beyond retention cap
#   /sdr transcribe           — Transcribe pending audio WAV calls via whisper engine
#   /sdr node-status          — Check AMD Radeon RX 5700 XT transcription node status
#   /sdr simulate [emergency] — Generate synthetic P25 patrol or emergency broadcast
#   /sdr dossier              — View recent SDR radio OSINT intelligence entries

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

cmd_sdr() {
    local args="$1"
    local py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
    local subcmd
    subcmd=$(echo "$args" | awk '{print $1}')
    local rest
    rest=$(echo "$args" | sed -E 's/^[^[:space:]]+[[:space:]]*//')
    [ "$rest" = "$subcmd" ] && rest=""

    case "$subcmd" in
        ""|status)
            "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --status
            ;;
        stats|summary|osint)
            local hrs="${rest:-24}"
            "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --query --mode stats --hours "$hrs"
            ;;
        query|search)
            if [[ "$rest" == --* ]]; then
                # shellcheck disable=SC2086
                "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --query $rest
            else
                "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --query --hours 24 --search "$rest"
            fi
            ;;
        talkgroup|tg|dept)
            "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --query --hours 24 --talkgroup "$rest"
            ;;
        unit)
            "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --query --hours 24 --mode unit_timeline --unit "$rest"
            ;;
        listen|audio)
            local cid prm
            cid=$(echo "$rest" | awk '{print $1}')
            prm=$(echo "$rest" | sed -E 's/^[^[:space:]]+[[:space:]]*//')
            [ "$prm" = "$cid" ] && prm=""
            if [ -n "$prm" ]; then
                "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --listen "${cid:-latest}" --prompt "$prm"
            else
                "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --listen "${cid:-latest}"
            fi
            ;;
        ingest)
            "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --ingest
            ;;
        sync)
            declare -f ui_info &>/dev/null && ui_info "Syncing remote radio captures over jumpbox gateway..."
            "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --sync
            ;;
        prune)
            "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --prune
            ;;
        simulate)
            if [ "$rest" = "emergency" ] || [ "$rest" = "alert" ]; then
                declare -f ui_warn &>/dev/null && ui_warn "Simulating P25 emergency tactical broadcast..."
                "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --simulate --emergency
            else
                declare -f ui_info &>/dev/null && ui_info "Simulating routine P25 patrol dispatch call..."
                "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --simulate
            fi
            ;;
        transcribe)
            declare -f ui_info &>/dev/null && ui_info "Transcribing audio recordings in spool via whisper engine..."
            "$py_bin" "$LODGE_DIR/lib/tools/sdr_transcribe.py" --spool
            ;;
        node-status|node)
            "$py_bin" "$LODGE_DIR/lib/tools/sdr_transcribe.py" --node-status
            ;;
        dossier|log)
            if [ -f "$LODGE_DIR/dossiers/sdr_osint.md" ]; then
                tail -n 25 "$LODGE_DIR/dossiers/sdr_osint.md"
            else
                declare -f ui_info &>/dev/null && ui_info "No SDR OSINT dossier generated yet."
            fi
            ;;
        *)
            if [[ "$args" == --* ]]; then
                # shellcheck disable=SC2086
                "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" $args
            else
                "$py_bin" "$LODGE_DIR/lib/tools/sdr_ingest.py" --query --hours 24 --search "$args"
            fi
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_sdr "$*"
fi
