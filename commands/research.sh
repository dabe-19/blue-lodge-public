#!/bin/bash
# DESC: Autonomous Research Graph & Dossier Library
# Usage: /research [start|list|read|queue] [topic_or_slug]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/research_graph.sh" 2>/dev/null || true

cmd_research() {
    local args="$1"
    local workdir="${2:-.}"

    research_init

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|list|ls)
            research_list
            ;;
        start|run|new)
            local do_pub=0
            if [[ "$rest" =~ --publish ]]; then
                do_pub=1
                rest=$(echo "$rest" | sed 's/--publish//; s/^[[:space:]]*//; s/[[:space:]]*$//')
            fi
            research_graph_run "$rest"
            if [ "$do_pub" -eq 1 ]; then
                echo ""
                ui_section "Broadcasting Research Essay to Social Channels"
                source "$LODGE_DIR/lib/social_blog.sh" 2>/dev/null || true
                x_blog_sweep
            fi
            ;;
        publish|live|broadcast)
            source "$LODGE_DIR/lib/social_blog.sh" 2>/dev/null || true
            research_graph_run "$rest"
            echo ""
            ui_section "Broadcasting Research Essay to Social Channels"
            x_blog_sweep
            ;;
        read|show|dossier)
            if [ -z "$rest" ]; then
                ui_info "Usage: /research read <slug_or_topic>"
                return 1
            fi
            research_query_sources "$rest"
            ;;
        queue)
            if [ -z "$rest" ]; then
                ui_info "Usage: /research queue <slug_or_topic>"
                return 1
            fi
            local matched_thread="${RESEARCH_DIR}/${rest}/thread.md"
            if [ -f "$matched_thread" ]; then
                local ts
                ts=$(date +%s)
                cp "$matched_thread" "${RESEARCH_QUEUE_DIR}/${ts}_research_${rest}.txt"
                ui_ok "Re-queued research piece: $rest for next publishing sweep."
            else
                ui_err "No thread found for: '$rest'"
                return 1
            fi
            ;;
        *)
            research_graph_run "$args"
            ;;
    esac
}
