#!/bin/bash
# DESC: Social media integration (X, Mastodon, Bluesky, Discord, Telegram)
# Usage: /social <post|x|mastodon|bluesky|discord|telegram|validate|status>

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/api.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null || true

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
            source "$LODGE_DIR/lib/comms/discord_bridge.sh" 2>/dev/null || true
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
                    [ -z "$d_target" ] && d_target="${OPERATOR_DISCORD_HANDLE:-${OPERATOR_HANDLE:-operator}}"
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
                owner|owners)
                    local osub
                    osub=$(echo "$dargs" | awk '{print $1}')
                    case "$osub" in
                        user|username|usernames)
                            local uact unames
                            uact=$(echo "$dargs" | awk '{print $2}')
                            unames=$(echo "$dargs" | awk '{print $3}')
                            case "$uact" in
                                set)
                                    if [ -n "$unames" ]; then
                                        api_set_key "DISCORD_OWNER_USERNAMES" "$unames"
                                        export DISCORD_OWNER_USERNAMES="$unames"
                                        ui_ok "Discord owner usernames set to: $unames"
                                    else
                                        ui_err "Usage: /social discord owner username set <user1,user2...>"
                                    fi ;;
                                add)
                                    if [ -n "$unames" ]; then
                                        local cur_names
                                        cur_names=$(api_get_key "DISCORD_OWNER_USERNAMES" 2>/dev/null || echo "")
                                        [ -n "$cur_names" ] && unames="${cur_names},${unames}"
                                        api_set_key "DISCORD_OWNER_USERNAMES" "$unames"
                                        export DISCORD_OWNER_USERNAMES="$unames"
                                        ui_ok "Added to Discord owner usernames: $unames"
                                    else
                                        ui_err "Usage: /social discord owner username add <username>"
                                    fi ;;
                                list|"")
                                    local cur_u
                                    cur_u="${DISCORD_OWNER_USERNAMES:-$(api_get_key "DISCORD_OWNER_USERNAMES" 2>/dev/null || echo "")}"
                                    ui_info "Discord Owner Usernames: ${cur_u:-not configured}" ;;
                            esac ;;
                        id)
                            local iact i_val
                            iact=$(echo "$dargs" | awk '{print $2}')
                            i_val=$(echo "$dargs" | awk '{print $3}')
                            case "$iact" in
                                set)
                                    if [ -n "$i_val" ]; then
                                        api_set_key "DISCORD_OWNER_IDS" "$i_val"
                                        export DISCORD_OWNER_IDS="$i_val"
                                        ui_ok "Discord owner IDs set to: $i_val"
                                    else
                                        ui_err "Usage: /social discord owner id set <id1,id2...>"
                                    fi ;;
                                add)
                                    if [ -n "$i_val" ]; then
                                        local cur_ids
                                        cur_ids=$(api_get_key "DISCORD_OWNER_IDS" 2>/dev/null || echo "")
                                        [ -n "$cur_ids" ] && i_val="${cur_ids},${i_val}"
                                        api_set_key "DISCORD_OWNER_IDS" "$i_val"
                                        export DISCORD_OWNER_IDS="$i_val"
                                        ui_ok "Added $i_val to Discord owner IDs"
                                    else
                                        ui_err "Usage: /social discord owner id add <id>"
                                    fi ;;
                                list|"")
                                    local cur_i
                                    cur_i="${DISCORD_OWNER_IDS:-$(api_get_key "DISCORD_OWNER_IDS" 2>/dev/null || echo "")}"
                                    ui_info "Discord Owner IDs: ${cur_i:-not configured}" ;;
                            esac ;;
                        set)
                            local new_ids
                            new_ids=$(echo "$dargs" | awk '{print $2}')
                            if [ -n "$new_ids" ]; then
                                api_set_key "DISCORD_OWNER_IDS" "$new_ids"
                                export DISCORD_OWNER_IDS="$new_ids"
                                ui_ok "Discord owner IDs set to: $new_ids"
                            else
                                ui_err "Usage: /social discord owner set <id1,id2...>"
                            fi
                            ;;
                        add)
                            local add_id current_ids
                            add_id=$(echo "$dargs" | awk '{print $2}')
                            if [ -n "$add_id" ]; then
                                current_ids=$(api_get_key "DISCORD_OWNER_IDS" 2>/dev/null || echo "")
                                if [ -n "$current_ids" ]; then
                                    new_ids="${current_ids},${add_id}"
                                else
                                    new_ids="$add_id"
                                fi
                                api_set_key "DISCORD_OWNER_IDS" "$new_ids"
                                export DISCORD_OWNER_IDS="$new_ids"
                                ui_ok "Added $add_id to Discord owner IDs: $new_ids"
                            else
                                ui_err "Usage: /social discord owner add <id>"
                            fi
                            ;;
                        list|"")
                            local cur_ids cur_names
                            cur_ids="${DISCORD_OWNER_IDS:-$(api_get_key "DISCORD_OWNER_IDS" 2>/dev/null || echo "")}"
                            cur_names="${DISCORD_OWNER_USERNAMES:-$(api_get_key "DISCORD_OWNER_USERNAMES" 2>/dev/null || echo "")}"
                            ui_info "Discord Owner IDs:       ${cur_ids:-not configured}"
                            ui_info "Discord Owner Usernames: ${cur_names:-not configured}"
                            ;;
                    esac ;;
                validate|test) discord_validate ;;
                *) ui_info "Usage: /social discord <send|dm|upload|chat|sweep|channels|users|owner|validate>" ;;
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_social "$*"
fi
