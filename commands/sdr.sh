#!/bin/bash
# DESC: Sovereign SDR Radio Lab & TrunkRecorder Hook for P25 Public Safety OSINT
# Usage:
#   /sdr status               — Show SDR ingest status, pending spool calls, and gateway config
#   /sdr ingest               — Ingest and process all pending P25 calls in local spool
#   /sdr sync                 — Rsync recent recordings from remote SDR gateway
#   /sdr transcribe           — Transcribe pending audio WAV calls via whisper engine
#   /sdr node-status          — Check AMD Radeon RX 5700 XT transcription node status
#   /sdr simulate             — Generate synthetic P25 routine patrol call and emit to bus
#   /sdr simulate emergency   — Generate synthetic P25 emergency SWAT/pursuit broadcast
#   /sdr dossier              — View recent SDR radio OSINT intelligence entries

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

cmd_sdr() {
    local args="$1"
    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|status)
            python3 "$LODGE_DIR/lib/tools/sdr_ingest.py" --status
            ;;
        ingest)
            python3 "$LODGE_DIR/lib/tools/sdr_ingest.py" --ingest
            ;;
        sync)
            declare -f ui_info &>/dev/null && ui_info "Syncing remote radio captures over jumpbox gateway..."
            python3 "$LODGE_DIR/lib/tools/sdr_ingest.py" --sync
            ;;
        simulate)
            if [ "$rest" = "emergency" ] || [ "$rest" = "alert" ]; then
                declare -f ui_warn &>/dev/null && ui_warn "Simulating P25 emergency tactical broadcast..."
                python3 "$LODGE_DIR/lib/tools/sdr_ingest.py" --simulate --emergency
            else
                declare -f ui_info &>/dev/null && ui_info "Simulating routine P25 patrol dispatch call..."
                python3 "$LODGE_DIR/lib/tools/sdr_ingest.py" --simulate
            fi
            ;;
        transcribe)
            declare -f ui_info &>/dev/null && ui_info "Transcribing audio recordings in spool via whisper engine..."
            python3 "$LODGE_DIR/lib/tools/sdr_transcribe.py" --spool
            ;;
        node-status|node)
            python3 "$LODGE_DIR/lib/tools/sdr_transcribe.py" --node-status
            ;;
        dossier|log)
            if [ -f "$LODGE_DIR/dossiers/sdr_osint.md" ]; then
                tail -n 25 "$LODGE_DIR/dossiers/sdr_osint.md"
            else
                declare -f ui_info &>/dev/null && ui_info "No SDR OSINT dossier generated yet."
            fi
            ;;
        *)
            declare -f ui_err &>/dev/null && ui_err "Unknown /sdr action: $subcmd"
            declare -f ui_dim &>/dev/null && ui_dim "Usage: /sdr [status|ingest|sync|transcribe|node-status|simulate [emergency]|dossier]"
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_sdr "$*"
fi
