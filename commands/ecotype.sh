#!/usr/bin/env bash
# ── George Slash Command: /ecotype ───────────────────────────────────
# DESC: Manage per-node ecotype/<node> branches, sandboxed upstream pollination, and foliage-safe Heartwood promotion
# USAGE: /ecotype [status | init [name] | sync | promote --title "..." <paths...> | backup [--cloud] [-m "msg"]]

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$LODGE_DIR/lib/sys/ecotype.sh"

cmd_ecotype() {
    local args="${1:-status}"
    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        status|"")
            # shellcheck disable=SC2086
            ecotype_status $rest
            ;;
        init|switch)
            # shellcheck disable=SC2086
            ecotype_init $rest
            ;;
        sync|pollinate)
            # shellcheck disable=SC2086
            ecotype_sync $rest
            ;;
        promote)
            # Evaluate quoted arguments cleanly
            eval "ecotype_promote $rest"
            ;;
        backup|save)
            eval "ecotype_backup $rest"
            ;;
        fetch|check)
            ecotype_fetch
            ;;
        diff)
            ecotype_diff "$rest"
            ;;
        help|--help|-h)
            cat <<EOF
/ecotype — Software Phytology Branch & Pollination Manager

Each George node operates on its own 'ecotype/<node_name>' branch so local
adaptations (Foliage) never collide with shared core systems (Heartwood).

Usage:
  /ecotype status [--json]
      Show active ecotype branch, commits ahead/behind trunk, and Heartwood vs Foliage split.
  /ecotype fetch
      Fetch latest refs from origin/gitea without modifying the working tree.
  /ecotype diff [path]
      Show diff summary vs upstream trunk (or unified diff for a specific path).
  /ecotype init [node_name]
      Ensure this node is on 'ecotype/<node_name>' (creating it if needed) and sync to local Gitea.
  /ecotype sync [remote] [branch]
      Sandboxed Pollination: test-merge upstream (default: origin/develop) in a temporary
      worktree, verify AST syntax, and update live branch only if 100% conflict-free.
  /ecotype promote --title "<summary>" [--push-origin] <heartwood_paths...>
      Foliage-Firewalled Promotion: graft ONLY specified Heartwood files onto a clean
      'candidate/<slug>' branch off develop (blocks .george/*, keys, and personal alpha).
  /ecotype backup [--cloud] [-m "<commit message>"]
      Push 'ecotype/<node_name>' to local Gitea (and optionally mirror to GitHub origin/ecotype/<node_name>).
EOF
            ;;
        *)
            ui_err "Unknown /ecotype command: '$subcmd' (run '/ecotype help')"
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_ecotype "$*"
fi
