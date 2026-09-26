#!/bin/bash
# DESC: Software Phytology living tissue diagnostic, healing, and graft management
# Usage: /phytology [status|audit|heal|rollback|prune|test] [target]

_CMD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
LODGE_DIR="${LODGE_DIR:-$(cd "${_CMD_DIR}/.." 2>/dev/null && pwd || echo "$HOME/blue-lodge")}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/phytology.sh" 2>/dev/null || true

cmd_phytology() {
    local args="$1"
    local workdir="${2:-.}"

    phytology_init

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|status)
            phytology_introspect
            ;;
        audit)
            if [ "$rest" = "--json" ]; then
                phytology_audit --json
            else
                phytology_audit
            fi
            ;;
        heal)
            ui_section "Software Phytology Autonomic Healing"
            phytology_heal
            ;;
        rollback)
            local target="$rest"
            if [ -z "$target" ]; then
                ui_err "Usage: /phytology rollback <target_file>"
                return 1
            fi
            ui_step "Rolling back tissue '$target' to latest genetic snapshot..."
            phytology_rollback "$target"
            ;;
        prune)
            local job_name="$rest"
            if [ -z "$job_name" ]; then
                ui_err "Usage: /phytology prune <job_name>"
                return 1
            fi
            ui_step "Pruning foliage job '$job_name'..."
            phytology_prune "$job_name"
            ;;
        test)
            ui_section "Running Software Phytology Test Suite"
            if [ -f "$LODGE_DIR/tests/test_phytology.sh" ]; then
                bash "$LODGE_DIR/tests/test_phytology.sh"
            else
                ui_err "Test harness not found at tests/test_phytology.sh"
                return 1
            fi
            ;;
        *)
            ui_err "Unknown /phytology subcommand: '$subcmd'"
            ui_dim "Usage: /phytology [status | audit | heal | rollback <file> | prune <job> | test]"
            return 1
            ;;
    esac
}
