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
        help|-h|--help)
            ui_section "George Sovereign Research Engine"
            echo "Usage: /research <command> [topic_or_slug]"
            echo ""
            echo "Commands:"
            echo "  start <topic> [--publish]  Launch deep research graph (optionally broadcast on completion)"
            echo "  start <topic> [--publish-mastodon|--publish-bluesky|--publish-x]"
            echo "  publish <topic>            Launch deep research and immediately broadcast to all social channels"
            echo "  list                       List completed dossiers in the Sovereign Library"
            echo "  read <slug>                Read a research dossier and inspect citations"
            echo "  queue <slug>               Stage an existing research thread for social broadcast"
            echo "  help                       Show this help menu"
            return 0
            ;;
        start|run|new)
            local do_pub=0
            local pub_masto=0
            local pub_bsky=0
            local pub_x=0
            if [[ "$rest" =~ --publish-mastodon ]]; then
                do_pub=1; pub_masto=1
                rest=$(echo "$rest" | sed 's/--publish-mastodon//; s/^[[:space:]]*//; s/[[:space:]]*$//')
            fi
            if [[ "$rest" =~ --publish-bluesky ]]; then
                do_pub=1; pub_bsky=1
                rest=$(echo "$rest" | sed 's/--publish-bluesky//; s/^[[:space:]]*//; s/[[:space:]]*$//')
            fi
            if [[ "$rest" =~ --publish-x ]]; then
                do_pub=1; pub_x=1
                rest=$(echo "$rest" | sed 's/--publish-x//; s/^[[:space:]]*//; s/[[:space:]]*$//')
            fi
            if [[ "$rest" =~ --publish(-all)? ]]; then
                do_pub=1; pub_masto=1; pub_bsky=1; pub_x=1
                rest=$(echo "$rest" | sed -E 's/--publish(-all)?//; s/^[[:space:]]*//; s/[[:space:]]*$//')
            fi
            research_graph_run "$rest"
            if [ "$do_pub" -eq 1 ]; then
                echo ""
                ui_section "Broadcasting Research Essay to Social Channels"
                source "$LODGE_DIR/lib/social_blog.sh" 2>/dev/null || true
                AUTONOMIC_PUBLISH_SOCIAL=1 \
                AUTONOMIC_PUBLISH_MASTODON="$pub_masto" \
                AUTONOMIC_PUBLISH_BLUESKY="$pub_bsky" \
                AUTONOMIC_PUBLISH_X="$pub_x" \
                x_blog_sweep
            fi
            ;;
        publish|live|broadcast)
            source "$LODGE_DIR/lib/social_blog.sh" 2>/dev/null || true
            research_graph_run "$rest"
            echo ""
            ui_section "Broadcasting Research Essay to Social Channels"
            AUTONOMIC_PUBLISH_SOCIAL=1 \
            AUTONOMIC_PUBLISH_MASTODON=1 \
            AUTONOMIC_PUBLISH_BLUESKY=1 \
            AUTONOMIC_PUBLISH_X=1 \
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
