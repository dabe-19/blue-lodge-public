#!/bin/bash
# DESC: Model Workbench from the terminal: your local GGUF library, hub search/download, serving, tuning and fine-tuning prep
# Usage: /models [library | search <q> | import <file> | status | presets | ask <question> | help]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/model_hub.sh" 2>/dev/null || true

_models_help() {
    cat <<'EOF'
Usage: /models [command]

Your library (whatever GGUFs are in MODELS_DIR; nothing is pre-selected for you):
  /models                              Same as /models library
  /models library                      List every GGUF on disk: models, adapters, vision projectors, drafts
  /models fit-local <file> [--ctx N] [--kv f16|q8_0|q4_0] [--mmproj F] [--draft F]
                                       Will this local file fit my GPUs? (max context per KV type)
  /models import <file> [--name N] [--ctx N] [--kv K] [--mmproj F] [--draft F] [--approve]
                                       Pin a local file as a sha256-verified profile so it can be served
  /models delete-file <file> [--force] Delete a GGUF from disk (refuses if a profile uses it)

Discover + download (verified, approval-gated):
  /models ask <question>               Model Copilot: George checks your library + hardware, researches, drafts a profile
  /models hw                           Hardware probe (GPUs/VRAM, RAM, disk)
  /models search <query> [--provider huggingface|modelscope|all] [--sort downloads|likes|lastModified|trending]
  /models quants <provider> <repo> [--ctx N] [--kv f16|q8_0|q4_0]   Fit table for every quant in a repo
  /models fit <provider> <repo> <quant> [--ctx N] [--with-mmproj] [--with-draft]
  /models draft <provider> <repo> <quant> [--ctx N] [--name N] [--with-mmproj] [--with-draft]
  /models approve <name>               Review + approve a draft (binds to its content hash)
  /models install <name>               Download + sha256-verify (resumable)  | progress <name> | cancel <name>
  /models jobs                         Downloads / imports in progress
  /models login|logout <huggingface|modelscope>   /models accounts   /models disk

Serve + tune:
  /models profiles | show <name>       List / inspect profiles
  /models activate <name> [--dry-run]  Serve an installed profile with llama-server (docker or native)
  /models status                       What is actually being served (real model + context from llama-server)
  /models rollback                     Undo the last activation
  /models tune <name> '<json>'         Edit server/sampling, e.g. '{"server":{"ctx":32768,"cache_type_k":"q8_0"}}'
  /models attach <name> lora|control_vector <file.gguf> [--scale S]   Attach an adapter (needs re-approval)
  /models detach <name> <file.gguf>
  /models remove <name> [--delete-files]
  /models presets [id]                 Optional operator launch presets (.george/models/presets.json)

Fine-tuning prep (training itself runs in your own GPU environment):
  /models datasets                     Local datasets (data/training, exported George runs)
  /models dataset-pull <hf-dataset-repo> <file>
  /models export-runs [--since YYYY-MM-DD]   George's successful runs -> train/val JSONL
  /models train-kit '<json>'           Write a LoRA SFT kit: {"name","base_model","train"[, "val","epochs",...]}
  /models kits                         List generated kits

Open the web UI (Models button) for the same workflow with guided steps.
EOF
}

cmd_models() {
    local args="$1"
    local action="${args%% *}"
    local subargs="${args#* }"
    [ "$action" = "$args" ] && subargs=""

    case "${action:-library}" in
        ask)
            model_hub_cmd ask "$subargs" ;;
        tune)
            # tune <name> <json> — keep the JSON intact (it contains spaces)
            local tname="${subargs%% *}" tbody="${subargs#* }"
            [ "$tname" = "$subargs" ] && tbody=""
            model_hub_cmd tune "$tname" "$tbody" ;;
        train-kit)
            model_hub_cmd train-kit "$subargs" ;;
        switch|profile|mode)
            ui_warn "'/models switch' was removed: Blue Lodge no longer ships model-specific launch modes." 2>/dev/null \
                || echo "'/models switch' was removed."
            echo "Use /models activate <profile> for hub/library profiles, or define your own launch scripts as"
            echo "presets (config/models/presets.example.json) and run them with /models presets <id>."
            return 1 ;;
        download|pull|get|dataset|data|paths|storage)
            echo "'/models $action' (unverified downloads) was replaced:"
            echo "  models   -> /models search <q>, then /models draft / approve / install (sha256-verified)"
            echo "  datasets -> /models dataset-pull <repo> <file>"
            echo "  paths    -> /models disk"
            return 1 ;;
        help|--help|-h)
            _models_help ;;
        *)
            local -a argv=()
            read -r -a argv <<<"$subargs"
            model_hub_cmd "${action:-library}" "${argv[@]}"
            local rc=$?
            if [ "$rc" -eq 2 ]; then _models_help; return 1; fi
            return "$rc" ;;
    esac
}

[ "${BASH_SOURCE[0]}" = "$0" ] && cmd_models "$@"
