#!/bin/bash
# DESC: Sovereign Training, LoRA/SVD Fusion & Colab Fleet Orchestrator
# Usage: /train [wizard | forge <focus> <n> | pantry | recipes | audit | template | dry-run <spec.json> | run <spec.json>
#                | runs | status <run> | merge <run> | cancel <run> | collect <run> | credits]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

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

        template)
            python3 "$LODGE_DIR/scripts/training/runs.py" template | jq .
            ;;

        dry-run|run)
            local cfg="${subargs:-}"
            if [[ "$cfg" == *.json ]]; then
                # Real run manager: preflight (plan) or launch (start). Local runs detach; Colab plans unless --execute.
                local -a _ra=()
                read -r -a _ra <<<"$cfg"
                if [ "$action" = "dry-run" ]; then
                    python3 "$LODGE_DIR/scripts/training/runs.py" plan "${_ra[0]}" | jq .
                else
                    ui_info "Starting training run from ${_ra[0]}..."
                    python3 "$LODGE_DIR/scripts/training/runs.py" start "${_ra[@]}" | jq .
                fi
                return
            fi
            if [ -z "$cfg" ]; then
                echo "Usage: /train $action <spec.json> [--execute]   (get a starting spec with: /train template > my_run.json)"
                return 1
            fi
            # Legacy declarative YAML pipeline (kept for existing configs; see docs/DATASET_FORGE.md § Training runs).
            ui_warn "YAML specs use the legacy pipeline; prefer a JSON spec (/train template)." 2>/dev/null || true
            local _flag=()
            [ "$action" = "dry-run" ] && _flag=(--dry-run)
            if [ -x "$LODGE_DIR/.venv/bin/python3" ]; then
                "$LODGE_DIR/.venv/bin/python3" "$LODGE_DIR/scripts/training/pipeline.py" --config "$cfg" "${_flag[@]}"
            else
                python3 "$LODGE_DIR/scripts/training/pipeline.py" --config "$cfg" "${_flag[@]}"
            fi
            ;;

        runs)
            python3 "$LODGE_DIR/scripts/training/runs.py" list | jq -r \
                '.[]? | "\(.name)\t\(.backend)\t\(.state)\t\(.created)"' | column -t -s $'\t'
            ;;

        status|merge|cancel|collect)
            if ! [[ "$subargs" =~ ^[a-z0-9][a-z0-9._-]{1,47}$ ]]; then
                echo "Usage: /train $action <run-name>   (see /train runs)"
                return 1
            fi
            python3 "$LODGE_DIR/scripts/training/runs.py" "$action" "$subargs" | jq .
            ;;

        dataset|data|download-data)
            source "$LODGE_DIR/lib/tools/model_hub.sh" 2>/dev/null || true
            local -a _ds=()
            read -r -a _ds <<<"$subargs"
            if [ "${#_ds[@]}" -lt 2 ]; then
                echo "Usage: /train dataset <hf-dataset-repo> <file>   e.g. /train dataset HuggingFaceH4/no_robots data/train-00000-of-00001.parquet"
                return 1
            fi
            model_hub_cmd dataset-pull "${_ds[0]}" "${_ds[1]}"
            ;;

        forge)
            # /train forge <focus[,focus]|mix> <count> [--llm]
            source "$LODGE_DIR/lib/tools/model_hub.sh" 2>/dev/null || true
            local -a _fa=()
            read -r -a _fa <<<"$subargs"
            local _focus="${_fa[0]:-}" _count="${_fa[1]:-}" _llm=false _cur=false _x
            for _x in "${_fa[@]:2}"; do
                case "$_x" in --llm) _llm=true ;; --curricula) _cur=true ;; esac
            done
            if [ -z "$_focus" ] || ! [[ "$_count" =~ ^[0-9]{1,6}$ ]] || ! [[ "$_focus" =~ ^[a-z,-]{3,200}$ ]]; then
                echo "Usage: /train forge <focus|mix> <count> [--curricula] [--llm]"
                echo "  e.g. /train forge error-recovery,failure-modes 300"
                echo "       /train forge mix 1000 --curricula   (also use data/training, deduped, benchmark-guarded)"
                echo "       /train forge mix 1000 --llm         (local LLM writes missing 'chosen' replies + paraphrases)"
                echo "  See /train recipes for the focus list and /train pantry for what your transcripts can supply."
                return 1
            fi
            ui_info "Forging $_count samples (focus: $_focus) from your transcripts..."
            model_hub_cmd forge-build "$(jq -cn --arg f "$_focus" --argjson c "$_count" --argjson l "$_llm" \
                --argjson k "$_cur" '{focus:$f, count:$c, augment_llm:$l, include_curricula:$k}')"
            ;;

        pantry)
            source "$LODGE_DIR/lib/tools/model_hub.sh" 2>/dev/null || true
            ui_info "Scanning transcripts, run ledger and step log..."
            model_hub_cmd forge-pantry
            ;;

        recipes)
            python3 "$LODGE_DIR/scripts/training/forge.py" recipes | sed '$d'
            ;;

        audit)
            local -a _ap=()
            read -r -a _ap <<<"$subargs"
            python3 "$LODGE_DIR/scripts/training/forge.py" audit "${_ap[@]}" | sed '$d'
            ;;

        help|--help|-h|*)
            echo "Usage: /train [command]"
            echo ""
            echo "Commands:"
            echo "  /train wizard              Interactive TUI wizard for configuring training & fusion runs"
            echo "  /train recipes             What each Dataset Forge recipe teaches the model"
            echo "  /train pantry              How many unique samples your transcripts can supply per recipe"
            echo "  /train forge <focus> <n>   Build an SFT+DPO dataset from your transcripts (add --llm to augment)"
            echo "  /train audit [path]        Duplicate / diversity report for existing .jsonl datasets"
            echo "  /train dataset <repo> <file> Download a fine-tuning dataset file from Hugging Face (sha256-verified when available)"
            echo "  (LoRA kits for your own GPU environment: /models train-kit, or the web UI Models → Train tab)"
            echo "  /train credits             Query Google Cloud Colab ADC compute units balance"
            echo "  /train template            Print an example training-run spec (JSON) to edit"
            echo "  /train dry-run <spec.json> Validate a run: training env, GPUs, datasets, GGUF converter"
            echo "  /train run <spec.json>     Train every track (local GPUs; Colab with --execute) and merge to one GGUF"
            echo "  /train runs                List training runs"
            echo "  /train status <run>        Per-track state, loss, eval loss, DPO margin"
            echo "  /train merge <run>         Convert finished adapters to GGUF and fuse (concat | svd)"
            echo "  /train cancel <run>        Stop a run (deletes its Colab sessions)"
            echo "  /train collect <run>       Colab: download finished adapters and shut the sessions down"
            ;;
    esac
}

[ "${BASH_SOURCE[0]}" = "$0" ] && cmd_train "$@"
