#!/bin/bash
# DESC: Social media integration (X, Mastodon, Bluesky, Discord, Telegram)
# Usage: /social <post|x|mastodon|bluesky|discord|telegram|validate|status>

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/api.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/social.sh" 2>/dev/null || true

cmd_social() {
    local args="$1"
    local workdir="${2:-.}"

    if declare -f _cmd_social &>/dev/null; then
        _cmd_social "$args" "$workdir"
        return $?
    fi

    local action rest
    action=$(echo "$args" | awk '{print $1}')
    rest=$(echo "$args" | sed 's/^[^ ]* *//')

    case "$action" in
        validate|test|check)
            local target
            target=$(echo "$rest" | awk '{print $1}')
            case "$target" in
                mastodon|masto) mastodon_validate ;;
                x|twitter) x_validate ;;
                discord) discord_validate ;;
                all|"")
                    ui_info "Validating social connections..."
                    echo ""
                    mastodon_validate
                    echo ""
                    x_validate
                    echo ""
                    discord_validate
                    ;;
                *)
                    ui_info "Usage: /social validate [mastodon|x|discord|all]"
                    ;;
            esac ;;
        mastodon|masto)
            local sub margs
            sub=$(echo "$rest" | awk '{print $1}')
            margs=$(echo "$rest" | sed 's/^[^ ]* *//')
            case "$sub" in
                post)       mastodon_post "$margs" ;;
                timeline)   mastodon_timeline ;;
                search)     mastodon_search "$margs" ;;
                notify)     mastodon_notifications ;;
                validate|test|check) mastodon_validate "$margs" ;;
                thread)     mastodon_thread "$margs" ;;
                *)          ui_info "Usage: /social mastodon <post|thread|timeline|search|notify|instances|validate>" ;;
            esac ;;
        x|twitter)
            local sub xargs
            sub=$(echo "$rest" | awk '{print $1}')
            xargs=$(echo "$rest" | sed 's/^[^ ]* *//')
            case "$sub" in
                post)     x_post "$xargs" ;;
                thread)   x_thread "$xargs" ;;
                search)   x_search "$xargs" ;;
                timeline) x_timeline ;;
                validate|test) x_validate ;;
                *)        ui_info "Usage: /social x <post|thread|search|timeline|validate>" ;;
            esac ;;
        discord)
            source "$LODGE_DIR/lib/discord_bridge.sh" 2>/dev/null || true
            local sub dargs
            sub=$(echo "$rest" | awk '{print $1}')
            dargs=$(echo "$rest" | sed 's/^[^ ]* *//')
            case "$sub" in
                send)
                    local d_target d_msg
                    d_target=$(echo "$dargs" | awk '{print $1}')
                    d_msg=$(echo "$dargs" | sed 's/^[^ ]* *//')
                    discord_send "$d_target" "$d_msg" ;;
                dm)
                    local d_user d_msg
                    d_user=$(echo "$dargs" | awk '{print $1}')
                    d_msg=$(echo "$dargs" | sed 's/^[^ ]* *//')
                    discord_dm "$d_user" "$d_msg" ;;
                upload)
                    local d_target d_path d_msg
                    d_target=$(echo "$dargs" | awk '{print $1}')
                    d_path=$(echo "$dargs" | awk '{print $2}')
                    d_msg=$(echo "$dargs" | cut -d' ' -f3-)
                    discord_send_file "$d_target" "$d_path" "$d_msg" ;;
                chat)
                    local d_target
                    d_target=$(echo "$dargs" | awk '{print $1}')
                    [ -z "$d_target" ] && d_target="dabe"
                    discord_chat_session "$d_target" "Session initiated from operator terminal" "operator" "0" 1 "" ;;
                sweep|bridge)
                    discord_bridge_sweep ;;
                channels)
                    local csub
                    csub=$(echo "$dargs" | awk '{print $1}')
                    case "$csub" in
                        sync) discord_channels_sync ;;
                        list) discord_channel_list ;;
                        add) discord_channel_add $(echo "$dargs" | awk '{print $2, $3}') ;;
                        *) discord_channel_list ;;
                    esac ;;
                users)
                    local usub
                    usub=$(echo "$dargs" | awk '{print $1}')
                    case "$usub" in
                        sync) discord_users_sync ;;
                        list) discord_user_list ;;
                        *) discord_user_list ;;
                    esac ;;
                validate|test) discord_validate ;;
                *) ui_info "Usage: /social discord <send|dm|upload|chat|sweep|channels|users|validate>" ;;
            esac ;;
        telegram)
            local sub targs
            sub=$(echo "$rest" | awk '{print $1}')
            targs=$(echo "$rest" | sed 's/^[^ ]* *//')
            case "$sub" in
                send)     telegram_send "$targs" ;;
                validate) telegram_validate ;;
                *)        ui_info "Usage: /social telegram <send|validate>" ;;
            esac ;;
        status)
            social_status ;;
        *)
            ui_info "Usage: /social <post|x|mastodon|bluesky|discord|telegram|validate|status>"
            ui_dim "  /social discord sweep"
            ui_dim "  /social discord chat [channel|user]"
            ui_dim "  /social discord upload <channel|user> <path> [message]"
            ui_dim "  /social mastodon validate"
            ui_dim "  /social x validate"
            ui_dim "  /social validate [platform]"
            ;;
    esac
}
