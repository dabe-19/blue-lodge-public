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
            elif [ "$rest" = "--parallel" ]; then
                phytology_parallel_audit
            else
                phytology_audit
            fi
            ;;
        parallel-audit)
            phytology_parallel_audit ${rest:-15}
            ;;
        parallel-graft)
            local manifest="$rest"
            if [ -z "$manifest" ]; then
                ui_err "Usage: /phytology parallel-graft '<manifest_json>' [max_parallel]"
                return 1
            fi
            phytology_parallel_graft "$manifest"
            ;;
        auto-remediate)
            local target="${rest%% *}"
            local reason="${rest#"$target"}"
            reason="${reason#"${reason%%[![:space:]]*}"}"
            if [ -z "$target" ]; then
                ui_err "Usage: /phytology auto-remediate <target_file> [reason]"
                return 1
            fi
            ui_step "Autonomously remediating tissue anomaly in '$target'..."
            phytology_auto_remediate "$target" "${reason:-AST_CORRUPTION}"
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
        fitness)
            local target="$rest"
            if [ -z "$target" ]; then
                ui_err "Usage: /phytology fitness <target_file>"
                return 1
            fi
            phytology_fitness "$target"
            ;;
        lignify)
            local foliage="${rest%% *}"
            local cmd_name="${rest#"$foliage"}"
            cmd_name="${cmd_name#"${cmd_name%%[![:space:]]*}"}"
            if [ -z "$foliage" ]; then
                ui_err "Usage: /phytology lignify <foliage_file> [target_cmd_name]"
                return 1
            fi
            phytology_lignify "$foliage" "$cmd_name"
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
            ui_dim "Usage: /phytology [status | audit | parallel-audit | parallel-graft <json> | auto-remediate <file> | heal | rollback <file> | prune <job> | fitness <file> | lignify <file> [cmd] | test]"
            return 1
            ;;
    esac
}
