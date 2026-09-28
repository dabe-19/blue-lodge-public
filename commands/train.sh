#!/bin/bash
# DESC: Sovereign Training, LoRA/SVD Fusion & Colab Fleet Orchestrator
# Usage: /train [wizard | run <config.yaml> | credits | dry-run <config.yaml>]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true

cmd_train() {
    local args="$1"
    local workdir="${2:-.}"
    local action="${args%% *}"
    local subargs="${args#* }"
    [ "$action" = "$args" ] && subargs=""

    case "${action:-wizard}" in
        wizard)
            if [ -t 0 ]; then
                bash "$LODGE_DIR/scripts/training/wizard.sh"
            else
                ui_err "Interactive wizard requires a TTY terminal. Use: lodge /train wizard"
            fi
            ;;

        credits|quota)
            ui_info "Querying Google Cloud Colab Application Default Credentials (ADC)..."
            if [ -x "$LODGE_DIR/.venv/bin/python3" ]; then
                "$LODGE_DIR/.venv/bin/python3" "$LODGE_DIR/scripts/training/check_credits.py"
            else
                python3 "$LODGE_DIR/scripts/training/check_credits.py"
            fi
            ;;

        dry-run)
            local cfg="${subargs:-$LODGE_DIR/configs/training_run.template.yaml}"
            ui_info "Running dry-run validation on $cfg..."
            if [ -x "$LODGE_DIR/.venv/bin/python3" ]; then
                "$LODGE_DIR/.venv/bin/python3" "$LODGE_DIR/scripts/training/pipeline.py" --config "$cfg" --dry-run
            else
                python3 "$LODGE_DIR/scripts/training/pipeline.py" --config "$cfg" --dry-run
            fi
            ;;

        run)
            local cfg="${subargs:-$LODGE_DIR/configs/training_run.template.yaml}"
            ui_info "Launching declarative training pipeline with $cfg..."
            if [ -x "$LODGE_DIR/.venv/bin/python3" ]; then
                "$LODGE_DIR/.venv/bin/python3" "$LODGE_DIR/scripts/training/pipeline.py" --config "$cfg"
            else
                python3 "$LODGE_DIR/scripts/training/pipeline.py" --config "$cfg"
            fi
            ;;

        help|--help|-h|*)
            echo "Usage: /train [command]"
            echo ""
            echo "Commands:"
            echo "  /train wizard              Interactive TUI wizard for configuring training & fusion runs"
            echo "  /train credits             Query Google Cloud Colab ADC compute units balance"
            echo "  /train dry-run [spec.yaml] Validate configuration, datasets, and credentials"
            echo "  /train run [spec.yaml]     Execute full declarative training and fusion pipeline"
            ;;
    esac
}

[ "${BASH_SOURCE[0]}" = "$0" ] && cmd_train "$@"
