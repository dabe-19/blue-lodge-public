#!/usr/bin/env bash
# ── George: Model Hub bridge (Phase 5) ────────────────────────────────
# Shell surface over lib/tools/model_hub_cli.py:
#   * model_hub_tool   — George's agent tools (read-only + draft-only; NO approve/install/login)
#   * model_hub_cmd    — /models hub verbs for the operator
#   * model_hub_ask    — Model Copilot: a ReAct run bound to the hub tool profile
# Arguments are always passed as argv (never through a shell string).

[ -n "${_LIB_MODEL_HUB_LOADED:-}" ] && return 0; _LIB_MODEL_HUB_LOADED=1
LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"

_mh_py() {
    local py=python3
    [ -x "$LODGE_DIR/.venv/bin/python" ] && py="$LODGE_DIR/.venv/bin/python"
    "$py" "$LODGE_DIR/lib/tools/model_hub_cli.py" "$@"
}

# Tools George may call. Mirrors data/schemas/native_tools.json entries hub_*.
MODEL_HUB_AGENT_TOOLS="hub_hw_probe,hub_library,hub_search,hub_inspect,hub_quant_fit,hub_profile_draft,hub_profiles"

_mh_s() { jq -r --arg k "$1" '.[$k] // empty | tostring' <<<"$2" 2>/dev/null; }

# model_hub_tool <tool_name> <args_json>
model_hub_tool() {
    local name="$1" a="${2:-}"
    [ -z "$a" ] && a='{}'
    local prov repo q ctx kv
    prov=$(_mh_s provider "$a"); [ -z "$prov" ] && prov="huggingface"
    repo=$(_mh_s repo "$a"); q=$(_mh_s quant "$a"); ctx=$(_mh_s ctx "$a"); kv=$(_mh_s kv_type "$a")
    [[ -n "$ctx" && ! "$ctx" =~ ^[0-9]{3,7}$ ]] && { echo '{"error":"ctx must be an integer"}'; return 1; }
    local -a extra=()
    [ -n "$ctx" ] && extra+=(--ctx "$ctx")
    [ -n "$kv" ] && extra+=(--kv "$kv")
    case "$name" in
        hub_hw_probe) _mh_py hw ;;
        hub_library)
            # What the operator already has on disk (trimmed for the LLM context; no absolute paths).
            _mh_py library | jq -c 'if .error then . else
                {count: .totals.count, by_kind: .totals.by_kind, active_profile,
                 files: [.entries[:80][] | {rel, kind, adapter_type, arch, quant, size_label, ctx_train, base_model,
                         gib: ((.size/1073741824*10|floor)/10), profiles: [.profiles[].name]}]} end' ;;
        hub_search)
            local query limit
            query=$(_mh_s query "$a"); limit=$(_mh_s limit "$a")
            [[ "$limit" =~ ^[0-9]{1,3}$ ]] || limit=10
            [ -z "$query" ] && { echo '{"error":"query required"}'; return 1; }
            _mh_py search "$query" --provider "$prov" --limit "$limit" ;;
        hub_inspect)
            [ -z "$repo" ] && { echo '{"error":"repo required"}'; return 1; }
            # Trim file list for the LLM context: quants + aux files only.
            _mh_py inspect "$prov" "$repo" | jq -c 'if .error then . else
                {provider, repo, revision, gated, license, arch, params, ctx_max, base_model, quants: (.quants | keys),
                 sizes_mb: ([.files[] | select(.kind=="model") | {(.quant // .path): ((.size/1048576)|floor)}] | add),
                 aux: [.files[] | select(.kind=="mmproj" or .kind=="draft" or .kind=="lora") | {kind, path, mb: ((.size/1048576)|floor)}]} end' ;;
        hub_quant_fit)
            [ -z "$repo" ] && { echo '{"error":"repo required"}'; return 1; }
            if [ -n "$q" ]; then
                local -a f=()
                [ "$(_mh_s with_mmproj "$a")" = "true" ] && f+=(--with-mmproj)
                [ "$(_mh_s with_draft "$a")" = "true" ] && f+=(--with-draft)
                _mh_py fit "$prov" "$repo" "$q" "${extra[@]}" "${f[@]}" | jq -c 'del(.model.dims.name)'
            else
                _mh_py quants "$prov" "$repo" "${extra[@]}"
            fi ;;
        hub_profile_draft)
            [ -z "$repo" ] || [ -z "$q" ] && { echo '{"error":"repo and quant required"}'; return 1; }
            local -a f=()
            local pname; pname=$(_mh_s name "$a")
            [ -n "$pname" ] && f+=(--name "$pname")
            [ "$(_mh_s with_mmproj "$a")" = "true" ] && f+=(--with-mmproj)
            [ "$(_mh_s with_draft "$a")" = "true" ] && f+=(--with-draft)
            _mh_py draft-from "$prov" "$repo" "$q" "${extra[@]}" "${f[@]}" ;;
        hub_profiles) _mh_py profiles ;;
        *) echo "{\"error\":\"unknown hub tool $name\"}"; return 1 ;;
    esac
}

# Model Copilot: George researches models for this machine with the hub tool profile.
model_hub_ask() {
    local question="$*"
    [ -z "$question" ] && { echo "Usage: /models ask <question>   e.g. /models ask best coding model for my GPUs"; return 1; }
    source "$LODGE_DIR/lib/core/react.sh" 2>/dev/null || { echo "react engine unavailable"; return 1; }
    local goal
    goal="You are the Model Copilot. Operator request: ${question}

Method (do not answer from memory — verify with tools):
1. hub_hw_probe to learn this machine (GPUs/VRAM, RAM, disk).
2. hub_library to see what the operator ALREADY has downloaded. If a local model already fits the request,
   say so first (name the file and its fit) before suggesting any download.
3. hub_search / web_search to find candidate GGUF repos (prefer well-known quantizers and official repos; check recency and licence).
4. hub_inspect + hub_quant_fit for each serious candidate; compare quants against the hardware (fit verdict, max context, single vs multi GPU).
5. Recommend 1-3 options with the fit numbers, trade-offs (quality vs context vs speed), licence and any gating.
6. For the top pick, call hub_profile_draft to write a draft profile. You cannot approve or download; tell the operator to
   review it in Models → Discover (or run: /models approve <name> then /models install <name>).
Never request or reveal access tokens."
    REACT_TOOL_FILTER=model_hub react_run "$goal" "$LODGE_DIR" "${MODEL_HUB_ASK_TURNS:-14}"
}

_mh_print() {
    # Pretty-print JSON results for humans when jq is available.
    if command -v jq >/dev/null 2>&1; then jq . 2>/dev/null || cat; else cat; fi
}

# Operator verbs: /models <verb> ...
model_hub_cmd() {
    local verb="$1"; shift || true
    case "$verb" in
        hw)        _mh_py hw | _mh_print ;;
        search)    _mh_py search "$@" | jq -r 'if type=="array" then .[] | "\(.provider)\t\(.repo)\t⬇ \(.downloads)\t♥ \(.likes)\(if .gated then "\t[gated]" else "" end)" else . end' ;;
        inspect)   _mh_py inspect "$@" | jq '{repo, revision, license, arch, params, ctx_max, gated, quants: (.quants|keys)}' ;;
        quants)    _mh_py quants "$@" | jq -r 'if .error then .error else
                       "\(.repo) @ \(.revision[0:10])  ctx=\(.ctx) kv=\(.kv_type)\n" +
                       ([.quants[] | "  \(.quant)\t\(.size_mb) MB\t\(.verdict)\tmax_ctx=\(.max_ctx)"] | join("\n")) +
                       "\nbest GPU fit: \(.best_gpu_fit // "none")" end' ;;
        fit)       _mh_py fit "$@" | _mh_print ;;
        draft)     _mh_py draft-from "$@" --operator | jq '{draft, status, files: .profile.files, server: .profile.server, sampling: .profile.sampling, fit: .profile.fit, next}' ;;
        profiles)  _mh_py profiles | jq -r '.[] | "\(.name)\t\(.status)\(if .approved then "" else " (unapproved)" end)\t\(.repo)\t\(((.size//0)/1073741824*10|floor)/10) GiB\tctx=\(.ctx)\t\(.verdict // "")"' ;;
        show)      _mh_py show "$@" | _mh_print ;;
        approve)
            local n="${1:-}"
            [ -z "$n" ] && { echo "Usage: /models approve <profile>"; return 1; }
            _mh_py show "$n" | jq '{name, source, files: [.files[] | {role, path, gib: ((.size/1073741824*100|floor)/100), sha256: .sha256[0:16]}], adapters: [(.adapters // [])[] | {role, path, scale, sha256: .sha256[0:16]}], server, sampling, fit: .fit.verdict}'
            if [ -t 0 ] && [ "${MODEL_HUB_ASSUME_YES:-0}" != "1" ]; then
                local ans; read -r -p "Approve this profile for download? [y/N] " ans
                [[ "$ans" =~ ^[Yy]$ ]] || { echo "Not approved."; return 1; }
            fi
            _mh_py approve "$n" | jq -r '"✓ approved \(.name) (sha \(.approved_sha[0:12]))  → /models install \(.name)"' ;;
        install)
            local n="${1:-}"
            [ -z "$n" ] && { echo "Usage: /models install <profile>"; return 1; }
            _mh_py install "$n" | _mh_print ;;
        progress)  _mh_py progress "$@" | _mh_print ;;
        cancel)    _mh_py cancel "$@" | _mh_print ;;
        remove)    _mh_py remove "$@" | _mh_print ;;
        attach)    _mh_py attach "$@" | jq -r 'if .error then "✗ \(.error)" else "✓ attached to \(.name): \([.adapters[] | "\(.role) \(.path)@\(.scale)"] | join(", "))  (now draft → /models approve \(.name))" end' ;;
        detach)    _mh_py detach "$@" | jq -r 'if .error then "✗ \(.error)" else "✓ detached; \(.name) is now a draft → /models approve \(.name)" end' ;;
        activate)  bash "$LODGE_DIR/scripts/inference/activate_profile.sh" "$@" ;;
        login)
            local p="${1:-huggingface}" tok
            echo "Paste a ${p} access token (read scope is enough). Input is hidden."
            read -r -s tok; echo
            [ -z "$tok" ] && { echo "No token entered."; return 1; }
            printf '%s\n' "$tok" | _mh_py login "$p" | jq -r 'if .error then "✗ \(.error)" else "✓ logged in as \(.logged_in.user)" end'
            tok="" ;;
        logout)    _mh_py logout "${1:-huggingface}" | _mh_print ;;
        accounts)  _mh_py accounts | jq -r '.[] | "\(.provider)\t\(if .logged_in == true then "✓ \(.user)" elif .logged_in == null then "n/a (anonymous transport)" else "not logged in\(if .error then " — \(.error)" else "" end)" end)"' ;;
        disk)      _mh_py disk | _mh_print ;;
        library|list|ls)
            _mh_py library | jq -r 'if .error then .error else
                "Models directory: \(.models_dir)\(if .exists then "" else "  (does not exist yet)" end)",
                (if .totals.count == 0 then "  No GGUF files yet. Use /models search <query> or /models ask <question> to find one." else
                 (.entries[] | "  \(.kind)\t\(.rel)\t\(((.size/1073741824*10|floor)/10)) GiB\t\(.arch // "?")\t\(.quant // "")\(if .ctx_train then "\tctx_train=\(.ctx_train)" else "" end)\(if (.profiles|length) > 0 then "\t[profile: \([.profiles[].name]|join(","))]" else "" end)") end)
                end' ;;
        fit-local) _mh_py fit-local "$@" | jq '{verdict, max_ctx, n_gpu_layers, tensor_split, kv_options, notes, model}' ;;
        import)
            [ -z "${1:-}" ] && { echo "Usage: /models import <file-relative-to-models-dir> [--name N] [--ctx N] [--kv f16|q8_0|q4_0] [--mmproj F] [--draft F] [--approve]"; return 1; }
            _mh_py import-local "$@" | _mh_print ;;
        tune)
            local n="${1:-}" body="${2:-}"
            [ -z "$n" ] || [ -z "$body" ] && { echo 'Usage: /models tune <profile> '\''{"server":{"ctx":32768},"sampling":{"temperature":0.7}}'\'''; return 1; }
            printf '%s' "$body" | _mh_py tune "$n" | jq -r 'if .error then "✗ \(.error)" else "✓ \(.name) is now \(.status): server=\(.server|tostring) sampling=\(.sampling|tostring)" end' ;;
        delete-file) _mh_py delete-file "$@" | _mh_print ;;
        jobs)      _mh_py jobs | jq -r 'if type=="array" then (if length==0 then "no jobs" else .[] | "\(.name)\t\(.kind)\t\(.state)\t\(if .total then "\((100*(.done//0)/.total)|floor)%" else "" end)\t\(.error // "")" end) else . end' ;;
        status)
            _mh_py server-status | jq -r '(.endpoints[] | "\(.tier)\t\(.url)\t\(if .ok then "● serving \(.model_rel // .model_path // "?")  ctx=\(.n_ctx // "?")\(if .modalities.vision then "  +vision" else "" end)" elif .enabled then "○ down" else "○ disabled" end)"),
                (if .active_profile then "active profile: \(.active_profile.name) (\(.active_profile.runtime)) — rollback: /models rollback" else empty end)' ;;
        rollback)  bash "$LODGE_DIR/scripts/inference/activate_profile.sh" --rollback ;;
        presets)
            if [ -n "${1:-}" ]; then _mh_py preset-run "$@" | jq -r 'if .error then "✗ \(.error)" else .output, (if .ok then "✓ preset \(.id) done" else "✗ preset \(.id) exited \(.exit_code)\n\(.stderr)" end) end'
            else _mh_py presets | jq -r 'if .configured then (.presets[] | "\(.id)\t\(.label)\t\(.description)"), (.errors[]? | "! \(.)") else "No presets. Optional: copy config/models/presets.example.json to \(.file) to add one-click launch scripts." end'; fi ;;
        datasets)  _mh_py datasets | jq -r '.datasets[] | "\(.id)\t\(((.size/1048576*10|floor)/10)) MB\t\(.rows // "?") rows\t\(.format // "")"' ;;
        dataset-pull) _mh_py dataset-pull "$@" | _mh_print ;;
        export-runs) _mh_py export-runs "$@" | _mh_print ;;
        forge-recipes) _mh_py forge-recipes | jq -r 'if .error then "✗ \(.error)" else to_entries[] | "\(.key)\t\(if .value.dpo then "SFT+DPO" else "SFT" end)\t\(.value.title)" end' ;;
        forge-pantry)  _mh_py forge-pantry | jq -r 'if .error then "✗ \(.error)" else "episodes \(.episodes) · step records \(.steps) · tools \(.tools_seen)", (.recipes_available | to_entries[] | "  \(.key)\t\(.value) unique samples") end' ;;
        forge-build)
            [ -z "${1:-}" ] && { echo "Usage: /models forge-build '{\"focus\":\"error-recovery,failure-modes\",\"count\":300}'  (optional: \"augment_llm\":true)"; return 1; }
            printf '%s' "$1" | _mh_py forge-build | jq -r 'if .error then "✗ \(.error)" else "✓ \(.produced)/\(.requested) samples → \(.out)\n  SFT \(.sft_train)+\(.sft_val)  DPO \(.dpo_train)+\(.dpo_val)  ~\(.approx_tokens) tokens\n  by recipe: \(.by_recipe|tostring)\n  provenance: \(.by_provenance|tostring)\(if .shortfall > 0 then "\n  ⚠ shortfall \(.shortfall): not enough unique material (never padded with duplicates)" else "" end)\n  preview: \(.out)/preview.md" end' ;;
        train-kit)
            [ -z "${1:-}" ] && { echo 'Usage: /models train-kit '\''{"name":"my-kit","base_model":"org/model","train":"training:active/x.jsonl"}'\'''; return 1; }
            printf '%s' "$1" | _mh_py train-kit | _mh_print ;;
        kits)      _mh_py kits | _mh_print ;;
        ask)       model_hub_ask "$@" ;;
        *) return 2 ;;
    esac
}
