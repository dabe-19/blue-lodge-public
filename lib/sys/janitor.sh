#!/usr/bin/env bash
# lib/sys/janitor.sh — Storage retention for run artifacts (refinement P1/1.9)
#
#   runs/<id>/            FINISHED and older than RETENTION days → removed (RUNNING kept)
#   transcripts/*.md      older than GZIP days → gzip; anything older than RETENTION → removed
#   workspaces/<id>/      has .done and older than RETENTION → removed (top-level files kept)
#   discord_sessions/<d>/ per-session dirs older than RETENTION → removed (logs/history kept)
#
# janitor_run [retention_days=30] [gzip_days=7]   → prints a JSON summary
# JANITOR_DRY_RUN=1 reports without touching anything.
[ -n "${_LIB_JANITOR_LOADED:-}" ] && return 0; _LIB_JANITOR_LOADED=1

_jan_age_days() {  # file → integer age in days by mtime
    local m; m=$(stat -c %Y "$1" 2>/dev/null) || { echo 0; return; }
    echo $(( ( $(date +%s) - m ) / 86400 ))
}

janitor_run() {
    local keep="${1:-${JANITOR_RETENTION_DAYS:-30}}" gz="${2:-${JANITOR_GZIP_DAYS:-7}}"
    [[ "$keep" =~ ^[0-9]+$ && "$gz" =~ ^[0-9]+$ ]] || { echo '{"error":"invalid days"}'; return 1; }
    local G="${GEORGE_DIR:-${LODGE_DIR:?}/.george}" dry="${JANITOR_DRY_RUN:-0}"
    local now cutoff; now=$(date +%s); cutoff=$(( now - keep * 86400 ))
    local runs=0 tz=0 td=0 ws=0 ds=0 d f

    _jan_rm() { [ "$dry" = "1" ] || rm -rf -- "$1"; }

    # runs/
    for d in "$G"/runs/*/; do
        [ -f "$d/run.json" ] || continue
        local end; end=$(jq -r 'if .status=="FINISHED" then (.ended_epoch // 0) else -1 end' "$d/run.json" 2>/dev/null)
        [[ "$end" =~ ^[0-9]+$ ]] && [ "$end" -gt 0 ] && [ "$end" -lt "$cutoff" ] && { _jan_rm "$d"; runs=$((runs+1)); }
    done

    # transcripts/
    for f in "$G"/transcripts/*.md "$G"/transcripts/*.md.gz; do
        [ -f "$f" ] || continue
        local age; age=$(_jan_age_days "$f")
        if [ "$age" -ge "$keep" ]; then
            _jan_rm "$f"; td=$((td+1))
        elif [ "$age" -ge "$gz" ] && [[ "$f" == *.md ]]; then
            [ "$dry" = "1" ] || gzip -9 -- "$f" 2>/dev/null   # gzip preserves mtime
            tz=$((tz+1))
        fi
    done

    # workspaces/ (only finished session dirs; never loose files such as web_session.jsonl)
    for d in "$G"/workspaces/*/; do
        d="${d%/}"
        [ -f "$d/.done" ] || continue
        [ "$(_jan_age_days "$d/.done")" -ge "$keep" ] && { _jan_rm "$d"; ws=$((ws+1)); }
    done

    # discord_sessions/ per-session dirs (history/, active/, media are long-lived)
    for d in "$G"/discord_sessions/*/; do
        d="${d%/}"
        case "${d##*/}" in history|active|media|users) continue ;; esac
        [ "$(_jan_age_days "$d")" -ge "$keep" ] && { _jan_rm "$d"; ds=$((ds+1)); }
    done

    # Sovereign Gitea branch retention sweep
    local gb=0
    if [ "$dry" != "1" ]; then
        if [ -f "${LODGE_DIR:-$HOME/blue-lodge}/lib/tools/mcp_server_gitea.sh" ]; then
            source "${LODGE_DIR:-$HOME/blue-lodge}/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
            if declare -f gitea_prune_orphaned_branches &>/dev/null && declare -f gitea_is_online &>/dev/null && gitea_is_online; then
                local gres
                gres=$(gitea_prune_orphaned_branches 2>/dev/null || echo '{"pruned":0}')
                gb=$(echo "$gres" | jq -r '.pruned // 0' 2>/dev/null || echo 0)
            fi
        fi
        # FIFO IPC & Agent State Machine garbage collection
        if declare -f fifo_gc &>/dev/null; then
            fifo_gc >/dev/null 2>&1 || true
        fi
        if declare -f agent_sm_prune &>/dev/null; then
            agent_sm_prune "$(( keep * 86400 ))" >/dev/null 2>&1 || true
        fi
    fi

    jq -cn --argjson r "$runs" --argjson tz "$tz" --argjson td "$td" --argjson w "$ws" --argjson d "$ds" --argjson gb "$gb" \
        --argjson keep "$keep" --argjson gz "$gz" --arg dry "$dry" \
        '{runs_pruned:$r, transcripts_gzipped:$tz, transcripts_deleted:$td, workspaces_pruned:$w,
          discord_sessions_pruned:$d, gitea_branches_pruned:$gb, retention_days:$keep, gzip_days:$gz} + (if $dry=="1" then {dry_run:true} else {} end)'
}
