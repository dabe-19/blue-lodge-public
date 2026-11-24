#!/usr/bin/env bash
# DESC: Sovereign Lodge Guild App Store & Module Manager (/app)
# Usage:
#   /app list [--json]            — List installed, enabled, and catalog modules
#   /app catalog                  — Sync Lodge Guild App Store catalog from Gitea
#   /app install <id|url>         — Audit, verify wheels, and install a module
#   /app enable <id>              — Enable an installed or built-in module
#   /app disable <id>             — Disable a module (suspends its reactors & crons)
#   /app uninstall <id> [--purge] — Remove an external module
#   /app health <id>              — Run module healthcheck

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/sys/modules.sh"

cmd_app() {
    local args="$1"
    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|list|status)
            modules_list "$rest"
            ;;
        catalog|sync)
            if modules_catalog_sync; then
                local _safe_url
                _safe_url=$(_modules_guild_repo_url | sed -E 's|(https?://)[^/@]+@|\1|')
                ui_ok "Synced Lodge Guild catalog from ${_safe_url}"
                modules_list
            else
                ui_err "Failed to sync Lodge Guild catalog."
                return 1
            fi
            ;;
        install)
            # shellcheck disable=SC2086
            modules_install $rest
            ;;
        update|upgrade)
            # shellcheck disable=SC2086
            modules_update $rest
            ;;
        enable)
            modules_enable "$rest"
            ;;
        disable)
            modules_disable "$rest"
            ;;
        uninstall|remove)
            # shellcheck disable=SC2086
            modules_uninstall $rest
            ;;
        health)
            modules_health "$rest"
            ;;
        mirror-gitea|mirror)
            # shellcheck disable=SC2086
            bash "$LODGE_DIR/scripts/infra/sync_guild_gitea.sh" $rest
            ;;
        scaffold|new)
            # shellcheck disable=SC2086
            eval "modules_scaffold $rest"
            ;;
        *)
            ui_info "Usage: /app <list|catalog|install|update|enable|disable|uninstall|health|scaffold|mirror-gitea> [args]"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_app "$*"
fi
