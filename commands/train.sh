#!/bin/bash
# DESC: Sovereign Training, Sleep-Cycle SVD-32 Fusion, Tier B Gate & Colab Fleet Orchestrator
# Usage: /train [wizard | credits | pantry | recipes | forge <focus> <n> | audit | template | dry-run <spec.json>
#                | run <spec.json> [--execute] | runs | status <run> | resume <run> | collect <run> | merge <run>
#                | approve <run> | deny <run> | gate | adapters | hotswap ... | backup ... | policy | cancel <run>]

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
declare -f ui_info &>/dev/null || ui_info() { printf "[i] %s\n" "$*"; }
declare -f ui_warn &>/dev/null || ui_warn() { printf "[!] %s\n" "$*" >&2; }
declare -f ui_err  &>/dev/null || ui_err()  { printf "[✗] %s\n" "$*" >&2; }

_train_py() {
    if [ -x "$LODGE_DIR/.venv/bin/python3" ]; then
        echo "$LODGE_DIR/.venv/bin/python3"
    else
        echo "python3"
    fi
}

cmd_train() {
    local args="$1"
    local workdir="${2:-.}"
    local action="${args%% *}"
    local subargs="${args#* }"
    [ "$action" = "$args" ] && subargs=""
    local py
    py="$(_train_py)"

    case "${action:-wizard}" in
        wizard)
            if [ -t 0 ]; then
                bash "$LODGE_DIR/scripts/training/wizard.sh"
            else
                ui_err "Interactive wizard requires a TTY terminal. Use: lodge /train wizard"
            fi
            ;;

        credits|quota|prereqs)
            ui_info "Checking Colab CLI, gcloud, ADC/OAuth2 prerequisites & Compute Units..."
            "$py" "$LODGE_DIR/scripts/training/check_credits.py" $subargs
            ;;

        template)
            "$py" "$LODGE_DIR/scripts/training/runs.py" template | jq .
            ;;

        dry-run|plan|run)
            local cfg="${subargs:-}"
            if [ -z "$cfg" ]; then
                echo "Usage: /train $action <spec.json> [--execute]   (see configs/playbooks/ or /train template)"
                return 1
            fi
            local -a _ra=()
            read -r -a _ra <<<"$cfg"
            if [ "$action" = "dry-run" ] || [ "$action" = "plan" ]; then
                "$py" "$LODGE_DIR/scripts/training/runs.py" plan "${_ra[0]}" | jq .
            else
                ui_info "Starting training run from ${_ra[0]}..."
                "$py" "$LODGE_DIR/scripts/training/runs.py" start "${_ra[@]}" | jq .
            fi
            ;;

        runs)
            "$py" "$LODGE_DIR/scripts/training/runs.py" list | jq -r \
                '.[]? | "\(.name)\t\(.role)\t\(.backend)\t\(.state)\t\(.gate_status)\t\(.created)"' | column -t -s $'\t'
            ;;

        sessions|vms)
            "$py" "$LODGE_DIR/scripts/training/runs.py" colab-sessions --probe | jq .
            ;;

        cull)
            local tgt="${subargs%% *}"
            if [ -z "$tgt" ]; then
                echo "Usage: /train cull <endpoint-or-session | all-stale>"
                return 1
            fi
            if [ "$tgt" = "all-stale" ] || [ "$tgt" = "--all-stale" ]; then
                "$py" "$LODGE_DIR/scripts/training/runs.py" cull-vm --all-stale | jq .
            else
                "$py" "$LODGE_DIR/scripts/training/runs.py" cull-vm --target "$tgt" | jq .
            fi
            ;;

        gate|queue)
            "$py" "$LODGE_DIR/scripts/training/runs.py" gate-queue | jq .
            ;;

        adapters|lineage)
            "$py" "$LODGE_DIR/scripts/training/runs.py" adapters | jq .
            ;;

        policy)
            if [ -n "$subargs" ]; then
                "$py" "$LODGE_DIR/scripts/training/runs.py" policy --set "$subargs" | jq .
            else
                "$py" "$LODGE_DIR/scripts/training/runs.py" policy | jq .
            fi
            ;;

        benchmark|h2h)
            local -a _ba=()
            read -r -a _ba <<<"$subargs"
            if [ "${#_ba[@]}" -lt 1 ] || ! [[ "${_ba[0]}" =~ ^[a-z0-9][a-z0-9._-]{1,47}$ ]]; then
                echo "Usage: /train benchmark <run-name> [--force-rebaseline] [--dry-run] [--notify-discord]"
                return 1
            fi
            local _rn="${_ba[0]}"
            if [ "${TRAIN_FROM_DISCORD:-0}" = "1" ]; then
                # Fast preflight first so model mismatches fail immediately in Discord
                local _pf
                _pf=$("$py" "$LODGE_DIR/scripts/training/runs.py" benchmark "$_rn" --dry-run 2>&1)
                if [ $? -ne 0 ]; then
                    printf '❌ Benchmark preflight failed for `%s`:\n%s\n' "$_rn" "$_pf"
                    return 1
                fi
                local _base_lbl
                _base_lbl=$(printf '%s' "$_pf" | jq -r '.baseline.label // "fresh baseline capture"' 2>/dev/null || echo "current baseline")
                local _blog="$LODGE_DIR/.george/training/runs/${_rn}/benchmark_bg.log"
                nohup "$py" "$LODGE_DIR/scripts/training/runs.py" benchmark "${_ba[@]}" --notify-discord >"$_blog" 2>&1 </dev/null &
                printf '⏳ **Head-to-Head Benchmark Launched** for `%s` against `%s`.\nI will temporarily stage the candidate SVD-32 layer, run the 7-pillar suite, restore production inference, and DM you the full scorecard with `/train approve %s` / `/train deny %s` options once finished.\n' "$_rn" "$_base_lbl" "$_rn" "$_rn"
            else
                "$py" "$LODGE_DIR/scripts/training/runs.py" benchmark "${_ba[@]}" | jq .
            fi
            ;;

        status|merge|cancel|collect|resume|approve|deny|rollback)
            local -a _sa=()
            read -r -a _sa <<<"$subargs"
            if [ "${#_sa[@]}" -lt 1 ] || ! [[ "${_sa[0]}" =~ ^[a-z0-9][a-z0-9._-]{1,47}$ ]]; then
                echo "Usage: /train $action <run-name>   (see /train runs)"
                return 1
            fi
            "$py" "$LODGE_DIR/scripts/training/runs.py" "$action" "${_sa[@]}" | jq .
            ;;

        hotswap)
            local -a _ha=()
            read -r -a _ha <<<"$subargs"
            "$py" "$LODGE_DIR/scripts/training/runs.py" hotswap "${_ha[@]}" | jq .
            ;;

        backup)
            local -a _bka=()
            read -r -a _bka <<<"$subargs"
            if [ "${#_bka[@]}" -eq 0 ]; then
                "$py" "$LODGE_DIR/scripts/training/backup_artifacts.py" status
            else
                "$py" "$LODGE_DIR/scripts/training/backup_artifacts.py" "${_bka[@]}"
            fi
            ;;

        bake)
            local -a _ba=()
            read -r -a _ba <<<"$subargs"
            if [ "${#_ba[@]}" -lt 2 ]; then
                echo "Usage: /train bake <run-name-or-adapter.gguf> --base <base.gguf> [--out <out-Merged.gguf>] [--dry-run]"
                return 1
            fi
            "$py" "$LODGE_DIR/scripts/training/runs.py" bake "${_ba[@]}" | jq .
            ;;

        dataset|data|download-data)
            source "$LODGE_DIR/lib/tools/model_hub.sh" 2>/dev/null || true
            local -a _ds=()
            read -r -a _ds <<<"$subargs"
            if [ "${#_ds[@]}" -lt 2 ]; then
                echo "Usage: /train dataset <hf-dataset-repo> <file>"
                return 1
            fi
            model_hub_cmd dataset-pull "${_ds[0]}" "${_ds[1]}"
            ;;

        forge)
            source "$LODGE_DIR/lib/tools/model_hub.sh" 2>/dev/null || true
            local -a _fa=()
            read -r -a _fa <<<"$subargs"
            local _focus="${_fa[0]:-}" _count="${_fa[1]:-}" _llm=false _cur=false _jrn=false _x
            for _x in "${_fa[@]:2}"; do
                case "$_x" in --llm) _llm=true ;; --curricula) _cur=true ;; --journal) _jrn=true ;; esac
            done
            if [ -z "$_focus" ] || ! [[ "$_count" =~ ^[0-9]{1,6}$ ]] || ! [[ "$_focus" =~ ^[a-z0-9,-]{3,200}$ ]]; then
                echo "Usage: /train forge <focus|mix> <count> [--curricula] [--journal] [--llm]"
                return 1
            fi
            ui_info "Forging $_count samples (focus: $_focus)..."
            local -a _fcmd=("$py" "$LODGE_DIR/scripts/training/forge.py" build --focus "$_focus" --count "$_count")
            [ "$_cur" = true ] && _fcmd+=(--include-curricula)
            [ "$_jrn" = true ] && _fcmd+=(--include-journal)
            [ "$_llm" = true ] && _fcmd+=(--augment-llm)
            "${_fcmd[@]}" | tail -n 1 | jq .
            ;;

        pantry)
            ui_info "Scanning transcripts, run ledger and step log..."
            "$py" "$LODGE_DIR/scripts/training/forge.py" pantry $subargs | sed '$d'
            ;;

        recipes)
            "$py" "$LODGE_DIR/scripts/training/forge.py" recipes | sed '$d'
            ;;

        audit)
            local -a _ap=()
            read -r -a _ap <<<"$subargs"
            "$py" "$LODGE_DIR/scripts/training/forge.py" audit "${_ap[@]}" | sed '$d'
            ;;

        help|--help|-h|*)
            echo "Usage: /train [command]"
            echo ""
            echo "Commands:"
            echo "  /train credits             Check Colab CLI, gcloud, ADC/OAuth2 readiness & Compute Units"
            echo "  /train recipes / pantry    Inspect Dataset Forge recipes (incl. persistence, sdr-p25) & supply"
            echo "  /train forge <focus> <n>   Build leak-guarded SFT+DPO dataset (--curricula --journal --llm)"
            echo "  /train template            Print modern JSON run spec template (see also configs/playbooks/)"
            echo "  /train plan <spec.json>    Preflight prerequisites, CU floor, GPU fallback ladder & datasets"
            echo "  /train run <spec.json>     Start local GPU run or plan Colab run (add --execute to provision)"
            echo "  /train runs / status <run> List runs or inspect per-track loss, DPO margin & selected GPU"
            echo "  /train resume <run>        Re-provision timed-out Colab VMs & resume from Drive checkpoint"
            echo "  /train collect <run>       Download Colab adapters (.gguf + PEFT) and terminate VMs"
            echo "  /train merge <run>         SVD-32 retention fusion into MODELS_DIR/adapters/<model>/<role>/"
            echo "  /train gate / approve / deny  Tier B candidate approval queue (or switch policy to Tier A)"
            echo "  /train adapters / hotswap  List (model, role) SVD-32 lineage & hot-swap via POST /lora-adapters"
            echo "  /train backup [status|backup --all --target both]  Backup SVD-32 layers to Drive / HF Hub"
            echo "  /train policy [json]       View or update Sleep-Cycle schedule & Tier B/A autonomy posture"
            echo "  /train cancel <run>        Stop local training or terminate Colab VMs immediately"
            ;;
    esac
}

[ "${BASH_SOURCE[0]}" = "$0" ] && cmd_train "$@"
