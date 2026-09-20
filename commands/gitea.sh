#!/bin/bash
# DESC: Sovereign Gitea forge operations, pull requests, and CI/CD runners
# Usage: /gitea [status|sync|pr|runner|keys] [args...]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mcp_server_gitea.sh" 2>/dev/null || true

cmd_gitea() {
    local args="$1"
    local workdir="${2:-.}"

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|status)
            ui_section "Sovereign Gitea Forge Status"
            local st
            st=$(gitea_status)
            local online ver url owner repo dbranch prs
            online=$(echo "$st" | jq -r .online)
            ver=$(echo "$st" | jq -r .version)
            url=$(echo "$st" | jq -r .url)
            owner=$(echo "$st" | jq -r .owner)
            repo=$(echo "$st" | jq -r .repo)
            dbranch=$(echo "$st" | jq -r .default_branch)
            prs=$(echo "$st" | jq -r .open_prs)

            if [ "$online" = "true" ]; then
                ui_ok "Gitea Server: ONLINE (${url}, version ${ver})"
                ui_info "Repository:   ${owner}/${repo}"
                ui_info "Default:      ${dbranch}"
                ui_info "Open PRs:     ${prs}"
            else
                ui_err "Gitea Server: OFFLINE (${url})"
                ui_dim "Run 'bash scripts/start-gitea.sh' to launch."
            fi

            echo ""
            ui_step "Act-Runner CI/CD Status:"
            if [ -x "$LODGE_DIR/scripts/start-act-runner.sh" ]; then
                "$LODGE_DIR/scripts/start-act-runner.sh" status
            else
                ui_dim "Runner script not found."
            fi
            ;;

        sync)
            local br="${rest%% *}"
            br="${br:-develop}"
            ui_step "Syncing branch '${br}' to sovereign Gitea remote..."
            gitea_repo_sync "$br"
            ;;

        pr)
            local pr_sub="${rest%% *}"
            local pr_args="${rest#"$pr_sub"}"
            pr_args="${pr_args#"${pr_args%%[![:space:]]*}"}"

            case "$pr_sub" in
                ""|list)
                    local filter="${pr_args:-open}"
                    ui_section "Sovereign Gitea Pull Requests (${filter})"
                    gitea_pr_list "$filter"
                    ;;
                show)
                    local idx="${pr_args%% *}"
                    if [ -z "$idx" ]; then
                        ui_err "Usage: /gitea pr show <index>"
                        return 1
                    fi
                    local pr_data
                    pr_data=$(gitea_pr_get "$idx")
                    if echo "$pr_data" | jq -e .number &>/dev/null; then
                        local pnum ptitle phead pbase pstate pbody purl
                        pnum=$(echo "$pr_data" | jq -r .number)
                        ptitle=$(echo "$pr_data" | jq -r .title)
                        phead=$(echo "$pr_data" | jq -r .head.ref)
                        pbase=$(echo "$pr_data" | jq -r .base.ref)
                        pstate=$(echo "$pr_data" | jq -r .state)
                        pbody=$(echo "$pr_data" | jq -r .body)
                        purl=$(echo "$pr_data" | jq -r .html_url)

                        ui_ok "PR #${pnum}: ${ptitle}"
                        ui_dim "  Branches: ${phead} → ${pbase}"
                        ui_dim "  State:    ${pstate}"
                        ui_dim "  URL:      ${purl}"
                        echo ""
                        echo "${pbody}"
                    else
                        ui_err "PR #${idx} not found or error: ${pr_data}"
                    fi
                    ;;
                create)
                    local src="${pr_args%% *}"
                    local title="${pr_args#"$src"}"
                    title="${title#"${title%%[![:space:]]*}"}"
                    if [ -z "$src" ] || [ -z "$title" ]; then
                        ui_err "Usage: /gitea pr create <source_branch> <title>"
                        return 1
                    fi
                    gitea_pr_create "$src" "develop" "$title" "Created via /gitea pr create"
                    ;;
                merge)
                    local idx="${pr_args%% *}"
                    local strat="${pr_args#"$idx"}"
                    strat="${strat#"${strat%%[![:space:]]*}"}"
                    strat="${strat:-merge}"
                    if [ -z "$idx" ]; then
                        ui_err "Usage: /gitea pr merge <index> [merge|squash]"
                        return 1
                    fi
                    gitea_pr_merge "$idx" "$strat"
                    ;;
                *)
                    ui_err "Unknown /gitea pr action: '$pr_sub'"
                    ui_info "Usage: /gitea pr [list|show <id>|create <src> <title>|merge <id>]"
                    return 1
                    ;;
            esac
            ;;

        runner)
            local r_action="${rest%% *}"
            r_action="${r_action:-status}"
            if [ -x "$LODGE_DIR/scripts/start-act-runner.sh" ]; then
                "$LODGE_DIR/scripts/start-act-runner.sh" "$r_action"
            else
                ui_err "Runner script not found at scripts/start-act-runner.sh"
                return 1
            fi
            ;;

        keys)
            _gitea_load_conf
            ui_section "George Sovereign Forge Keys"
            if ! gitea_is_online; then
                ui_err "Gitea server is offline."
                return 1
            fi
            ui_info "SSH Keys registered for user '$GITEA_USER':"
            curl -s -H "Authorization: token ${GITEA_TOKEN}" "${GITEA_URL}/api/v1/user/keys" | jq -r '.[] | "  - [\(.id)] \(.title): \(.key[:30])..."' 2>/dev/null || echo "  None"
            echo ""
            ui_info "GPG Keys registered for user '$GITEA_USER':"
            curl -s -H "Authorization: token ${GITEA_TOKEN}" "${GITEA_URL}/api/v1/user/gpg_keys" | jq -r '.[] | "  - [\(.id)] KeyID: \(.key_id) (Primary: \(.primary_key_id // .key_id))"' 2>/dev/null || echo "  None"
            ;;

        *)
            ui_err "Unknown /gitea command: '$subcmd'"
            ui_info "Available subcommands: status, sync [branch], pr [list|show|create|merge], runner [start|stop|status], keys"
            return 1
            ;;
    esac
}
