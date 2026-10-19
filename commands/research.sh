#!/bin/bash
# DESC: Autonomous Research Graph & Dossier Library
# Usage: /research [start|list|read|queue] [topic_or_slug]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/research_graph.sh" 2>/dev/null || true

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
            echo "  topics                     List all frontier topics in rotation with status & domain"
            echo "  edit                       Open research topics list in VIM ($EDITOR)"
            echo "  add <topic>                Append a new frontier topic to the rotation"
            echo "  list                       List completed dossiers in the Sovereign Library"
            echo "  read <slug>                Read a research dossier and inspect citations"
            echo "  queue <slug>               Stage an existing research thread for social broadcast"
            echo "  salvage [slug|--all]       Recover and publish verified quarantined dossiers"
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
            if [ "$do_pub" -eq 1 ]; then
                if ! RESEARCH_KEEP_TRANSCRIPT=1 research_graph_run "$rest"; then
                    ui_warn "Research inquiry failed verification gates and was quarantined. Halting social broadcast."
                    return 1
                fi
                echo ""
                ui_section "Broadcasting Research Essay to Social Channels"
                declare -f transcript_section &>/dev/null && transcript_section "Social Broadcast (Mastodon, Bluesky, X)"
                source "$LODGE_DIR/lib/comms/social_blog.sh" 2>/dev/null || true
                AUTONOMIC_PUBLISH_SOCIAL=1 \
                AUTONOMIC_PUBLISH_MASTODON="$pub_masto" \
                AUTONOMIC_PUBLISH_BLUESKY="$pub_bsky" \
                AUTONOMIC_PUBLISH_X="$pub_x" \
                x_blog_sweep
                if declare -f transcript_stop &>/dev/null && declare -f transcript_active &>/dev/null && transcript_active; then
                    local final_t
                    final_t=$(transcript_stop)
                    if [ -n "$final_t" ] && [ -f "$final_t" ]; then
                        local r_slug
                        r_slug=$(research_slugify "$rest")
                        local final_perm_dir="${RESEARCH_DIR:-${LODGE_DIR}/.george/research}/${r_slug}"
                        if [ -d "$final_perm_dir" ]; then
                            cp "$final_t" "$final_perm_dir/" 2>/dev/null || true
                            local final_p="${final_t%.md}_prompts.md"
                            [ -f "$final_p" ] && cp "$final_p" "$final_perm_dir/" 2>/dev/null || true
                        fi
                    fi
                fi
                export _TRANSCRIPT_FILE=""
                export _PROMPT_LOG_FILE=""
            else
                research_graph_run "$rest"
            fi
            ;;
        publish|live|broadcast)
            source "$LODGE_DIR/lib/comms/social_blog.sh" 2>/dev/null || true
            if ! RESEARCH_KEEP_TRANSCRIPT=1 research_graph_run "$rest"; then
                ui_warn "Research inquiry failed verification gates and was quarantined. Halting social broadcast."
                return 1
            fi
            echo ""
            ui_section "Broadcasting Research Essay to Social Channels"
            declare -f transcript_section &>/dev/null && transcript_section "Social Broadcast (Mastodon, Bluesky, X)"
            AUTONOMIC_PUBLISH_SOCIAL=1 \
            AUTONOMIC_PUBLISH_MASTODON=1 \
            AUTONOMIC_PUBLISH_BLUESKY=1 \
            AUTONOMIC_PUBLISH_X=1 \
            x_blog_sweep
            if declare -f transcript_stop &>/dev/null && declare -f transcript_active &>/dev/null && transcript_active; then
                local final_t
                final_t=$(transcript_stop)
                if [ -n "$final_t" ] && [ -f "$final_t" ]; then
                    local r_slug
                    r_slug=$(research_slugify "$rest")
                    local final_perm_dir="${RESEARCH_DIR:-${LODGE_DIR}/.george/research}/${r_slug}"
                    if [ -d "$final_perm_dir" ]; then
                        cp "$final_t" "$final_perm_dir/" 2>/dev/null || true
                        local final_p="${final_t%.md}_prompts.md"
                        [ -f "$final_p" ] && cp "$final_p" "$final_perm_dir/" 2>/dev/null || true
                    fi
                fi
            fi
            export _TRANSCRIPT_FILE=""
            export _PROMPT_LOG_FILE=""
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
        salvage)
            research_salvage "$rest"
            ;;
        resynthesize|repackage|plate)
            research_resynthesize_thread "$rest"
            ;;
        mode)
            if [ -z "$rest" ]; then
                local cur_mode
                cur_mode=$(jq -r '.active_domain // "academic"' "${GEORGE_DIR:-$LODGE_DIR/.george}/research.conf" 2>/dev/null)
                [ -z "$cur_mode" ] && cur_mode="academic"
                local label
                label=$(research_domain_theme_label "$cur_mode")
                ui_info "Active Research Mode: $label ($cur_mode)"
            else
                research_set_mode "$rest"
            fi
            ;;
        random)
            research_topics_random "$rest"
            ;;
        topics|list-topics)
            research_topics_list "$rest"
            ;;
        edit|edit-topics|vim)
            research_topics_edit "$rest"
            ;;
        add)
            if [ -z "$rest" ]; then
                ui_err "Usage: /research add [domain] <topic text>"
                return 1
            fi
            local maybe_domain="${rest%% *}"
            local topic_text=""
            local target_domain=""
            case "$maybe_domain" in
                academic|engineering|finance|gaming|general_sports_auto|sports_auto|sports)
                    target_domain="$maybe_domain"
                    topic_text="${rest#"$maybe_domain"}"
                    topic_text="${topic_text#"${topic_text%%[![:space:]]*}"}"
                    ;;
                *)
                    local cur_mode
                    cur_mode=$(jq -r '.active_domain // "academic"' "${GEORGE_DIR:-$LODGE_DIR/.george}/research.conf" 2>/dev/null)
                    target_domain="${cur_mode:-academic}"
                    topic_text="$rest"
                    ;;
            esac
            local topics_file
            topics_file=$(research_domain_topics_file "$target_domain")
            echo "$topic_text" >> "$topics_file"

            # Sync to master if target_domain is active
            local cur_mode
            cur_mode=$(jq -r '.active_domain // "academic"' "${GEORGE_DIR:-$LODGE_DIR/.george}/research.conf" 2>/dev/null)
            if [ "$target_domain" = "$cur_mode" ] || [ "$target_domain" = "academic" -a -z "$cur_mode" ]; then
                echo "$topic_text" >> "${GEORGE_DIR:-$LODGE_DIR/.george}/research_topics.txt"
            fi
            local cnt
            cnt=$(grep -v '^[[:space:]]*#' "$topics_file" 2>/dev/null | grep -v '^[[:space:]]*$' | wc -l)
            ui_ok "Added topic to $topics_file ($cnt total topics in $target_domain): $topic_text"
            ;;
        *)
            research_graph_run "$args"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_research "$*"
fi
