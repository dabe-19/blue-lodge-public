#!/bin/bash
# ── George: Modular Git, Gitea, Copilot & Ops Tool Dispatcher ────────
# Extracted from lib/tools/native_tools.sh to modularize native_tools_dispatch.
# Expects caller (native_tools_dispatch) to provide _arg, _call_sim, LODGE_DIR,
# args_json, and populates `output` and `exit_code` in caller scope.

[ -n "${_LIB_DISPATCH_GIT_CODE_LOADED:-}" ] && return 0
_LIB_DISPATCH_GIT_CODE_LOADED=1

_native_dispatch_git_code() {
    local name="$1"
    local args_json="$2"
    local workdir="${3:-$PWD}"

    case "$name" in
        copilot_patch)
            if ! copilot_engine_available; then
                output="ERROR: Co-Pilot engine dependencies not available."
                exit_code=1
            else
                local fpath patch instr
                fpath=$(echo "$args_json" | jq -r '.file_path // empty')
                patch=$(echo "$args_json" | jq -r '.proposed_patch // empty')
                instr=$(echo "$args_json" | jq -r '.instruction // "Surgical patch applied via copilot"')
                local target="$workdir/$fpath"
                [ -f "$fpath" ] && target="$fpath"
                if [ ! -f "$target" ]; then
                    output="ERROR: Target file not found: $fpath"
                    exit_code=1
                else
                    local tmp_patch="/tmp/copilot_patch_$$.tmp"
                    printf '%s\n' "$patch" > "$tmp_patch"
                    local py_bin="python3"
                    [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
                    output=$("$py_bin" "$LODGE_DIR/lib/tools/copilot_engine.py" resolve-patch \
                        --original-file "$target" \
                        --proposed-file "$tmp_patch" \
                        --instruction "$instr" \
                        --output-file "$target" 2>&1)
                    exit_code=$?
                    rm -f "$tmp_patch"
                fi
            fi
            ;;
        copilot_safe_comment)
            if ! copilot_engine_available; then
                output="ERROR: Co-Pilot engine dependencies not available."
                exit_code=1
            else
                local fpath instr
                fpath=$(echo "$args_json" | jq -r '.file_path // empty')
                instr=$(echo "$args_json" | jq -r '.instruction // "Add comments and docstrings"')
                local target="$workdir/$fpath"
                [ -f "$fpath" ] && target="$fpath"
                if [ ! -f "$target" ]; then
                    output="ERROR: Target file not found: $fpath"
                    exit_code=1
                else
                    local py_bin="python3"
                    [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
                    local commented
                    commented=$("$py_bin" "$LODGE_DIR/lib/tools/copilot_engine.py" safe-comment \
                        --file "$target" \
                        --instruction "$instr" 2>&1)
                    exit_code=$?
                    if [ $exit_code -eq 0 ] && [ -n "$commented" ]; then
                        printf '%s\n' "$commented" > "$target"
                        output="Successfully applied safe comments to $fpath with 0 lines deleted."
                    else
                        output="ERROR: Safe comment failed: $commented"
                        exit_code=1
                    fi
                fi
            fi
            ;;
        copilot_tool_forge)
            if ! copilot_engine_available; then
                output="ERROR: Co-Pilot engine dependencies not available."
                exit_code=1
            else
                local t_name t_lang t_subsys t_desc t_code t_args
                t_name=$(echo "$args_json" | jq -r '.name // empty')
                t_lang=$(echo "$args_json" | jq -r '.language // "bash"')
                t_subsys=$(echo "$args_json" | jq -r '.subsystem // "tools"')
                t_desc=$(echo "$args_json" | jq -r '.description // "Custom tool"')
                t_code=$(echo "$args_json" | jq -r '.code // empty')
                t_args=$(echo "$args_json" | jq -c '.test_args // []')
                local py_bin="python3"
                [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
                output=$("$py_bin" "$LODGE_DIR/lib/tools/copilot_engine.py" build-tool \
                    --name "$t_name" \
                    --lang "$t_lang" \
                    --subsystem "$t_subsys" \
                    --desc "$t_desc" \
                    --code "$t_code" 2>&1)
                exit_code=$?
                if [ $exit_code -eq 0 ] && [ "$t_args" != "[]" ] && [ -n "$t_args" ]; then
                    local test_out
                    test_out=$("$py_bin" "$LODGE_DIR/lib/tools/copilot_engine.py" test-tool \
                        --name "$t_name" \
                        --args-json "$t_args" 2>&1)
                    output="{\"build\": $output, \"test\": $test_out}"
                fi
            fi
            ;;
        git_clone) output=$(cmd_clone "$(_arg .url) $(_arg .destination)" "$workdir" 2>&1); exit_code=$? ;;
        git_commit)
            local _gc_msg _gc_files _gc_path _gc_dir
            _gc_msg="$(_arg .message)"
            _gc_files="$(_arg .files)"
            _gc_path="$(_arg .path)"
            _gc_dir="${workdir:-${GEORGE_WORKDIR:-$PWD}}"
            if [ -n "$_gc_path" ] && [ "$_gc_path" != "." ]; then
                if [[ "$_gc_path" == /* ]]; then _gc_dir="$_gc_path"; else _gc_dir="$_gc_dir/$_gc_path"; fi
            fi
            if [ -z "$_gc_msg" ]; then
                output="Error: message parameter is required"
                exit_code=1
            elif ! git -C "$_gc_dir" rev-parse --git-dir &>/dev/null; then
                output="Error: Not a git repository: $_gc_dir"
                exit_code=1
            else
                if [ -n "$_gc_files" ]; then
                    git -C "$_gc_dir" add -- $_gc_files 2>&1
                else
                    git -C "$_gc_dir" add -A 2>&1
                fi
                output=$(git -C "$_gc_dir" commit -m "$_gc_msg" 2>&1)
                exit_code=$?
            fi
            ;;
        git_push)
            local _gp_remote _gp_branch _gp_path _gp_dir
            _gp_remote="$(_arg .remote origin)"
            _gp_branch="$(_arg .branch)"
            _gp_path="$(_arg .path)"
            _gp_dir="${workdir:-${GEORGE_WORKDIR:-$PWD}}"
            if [ -n "$_gp_path" ] && [ "$_gp_path" != "." ]; then
                if [[ "$_gp_path" == /* ]]; then _gp_dir="$_gp_path"; else _gp_dir="$_gp_dir/$_gp_path"; fi
            fi
            [ -z "$_gp_branch" ] && _gp_branch=$(git -C "$_gp_dir" branch --show-current 2>/dev/null)
            output=$(git -C "$_gp_dir" push "$_gp_remote" "$_gp_branch" 2>&1)
            exit_code=$?
            ;;
        gitea_status) output=$(gitea_status 2>&1); exit_code=$? ;;
        gitea_set_endpoint) local _ep="$(_arg .url)"; if [ -n "$_ep" ]; then output=$(gitea_set_endpoint "$_ep" 2>&1 && echo "Gitea endpoint updated to $_ep"); exit_code=$?; else output="Error: url parameter required"; exit_code=1; fi ;;
        gitea_repo_sync) output=$(gitea_repo_sync "$(_arg .branch develop)" 2>&1); exit_code=$? ;;
        gitea_pr_create) output=$(gitea_pr_create "$(_arg .head)" "$(_arg .base develop)" "$(_arg .title)" "$(_arg .body)" 2>&1); exit_code=$? ;;
        gitea_pr_list) output=$(gitea_pr_list "$(_arg .state open)" 2>&1); exit_code=$? ;;
        gitea_pr_get)
            local _idx="$(_arg .index)"
            if [[ "$_idx" =~ ^PR-[0-9]+$ ]] || ! pr_is_gitea_online; then
                output=$(pr_show "$_idx" 2>&1); exit_code=$?
            else
                output=$(gitea_pr_get "$_idx" 2>&1); exit_code=$?
            fi
            ;;
        gitea_pr_review)
            local _idx="$(_arg .index)" _evt="$(_arg .event COMMENT)" _bdy="$(_arg .body)"
            if declare -f pr_record_review &>/dev/null; then
                pr_record_review "$_idx" "$_evt" "$_bdy" >/dev/null 2>&1 || true
            fi
            if [[ "$_idx" =~ ^PR-[0-9]+$ ]] || ! pr_is_gitea_online; then
                output=$(jq -nc --arg idx "$_idx" --arg state "$_evt" --arg body "$_bdy" '{id: $idx, state: $state, body: $body}')
                exit_code=0
            else
                output=$(gitea_pr_review "$_idx" "$_evt" "$_bdy" 2>&1); exit_code=$?
                if [ "$exit_code" -ne 0 ] && declare -f gitea_issue_comment &>/dev/null; then
                    output=$(gitea_issue_comment "$_idx" "### 🔎 [George PR Review: ${_evt}]"$'\n\n'"${_bdy}" 2>&1)
                    exit_code=$?
                fi
            fi
            ;;
        gitea_pr_merge) local _idx="$(_arg .index)" _strat="$(_arg .strategy merge)"; if [[ "$_idx" =~ ^PR-[0-9]+$ ]] || ! pr_is_gitea_online; then output=$(pr_accept "$_idx" "$_strat" 2>&1); else output=$(gitea_pr_merge "$_idx" "$_strat" 2>&1); fi; exit_code=$? ;;
        gitea_issue_create) output=$(gitea_issue_create "$(_arg .title)" "$(_arg .body)" "$(_arg .labels)" 2>&1); exit_code=$? ;;
        gitea_issue_list) output=$(gitea_issue_list "$(_arg .state open)" "json" 2>&1); exit_code=$? ;;
        gitea_issue_get) output=$(gitea_issue_get "$(_arg .index)" 2>&1); exit_code=$? ;;
        gitea_issue_comment) output=$(gitea_issue_comment "$(_arg .index)" "$(_arg .body)" 2>&1); exit_code=$? ;;
        gitea_issue_close) output=$(gitea_issue_close "$(_arg .index)" "$(_arg .comment)" 2>&1); exit_code=$? ;;
        gitea_branch_create) output=$(gitea_branch_create "$(_arg .branch_name)" "$(_arg .base develop)" 2>&1); exit_code=$? ;;
        pr_audit) output=$(pr_audit "$(_arg .pr_id)" 2>&1); exit_code=$? ;;
        project_fix) output=$(cmd_fix "$(_arg .error_context)" "$workdir" 2>&1); exit_code=$? ;;
        project_init) output=$(cmd_init "$(_arg .name project) $(_arg .type General)" "$workdir" 2>&1); exit_code=$? ;;
        backup_create) _call_sim backup_local "Backup created in .george/backups" ;;
        backup_list) _call_sim backup_list "(no backups found)" ;;
        backup_restore) _call_sim backup_restore "Restored backup $(_arg .timestamp)" "$(_arg .timestamp)" ;;
        pgp_sign) _call_sim pgp_sign "PGP signature generated" "$(_arg .text)" ;;
        pgp_verify) _call_sim pgp_verify "PGP signature valid" "$(_arg .signed_text)" ;;
        gsuite_search)
            local svc qry
            svc=$(echo "$args_json" | jq -r '.service // "gmail"')
            qry=$(echo "$args_json" | jq -r '.query // empty')
            if [ "$svc" = "drive" ] && declare -f gsuite_drive_list &>/dev/null; then
                output=$(gsuite_drive_list "$qry" 2>&1)
            elif declare -f gsuite_gmail_list &>/dev/null; then
                output=$(gsuite_gmail_list "$qry" 2>&1)
            else
                output="GSuite is not configured or authenticated. Run /gsuite to connect."
            fi
            exit_code=$?
            ;;
        phytology_manage)
            local act tgt flg
            act=$(echo "$args_json" | jq -r '.action // "status"')
            tgt=$(echo "$args_json" | jq -r '.target // empty')
            flg=$(echo "$args_json" | jq -r '.flags // empty')

            if [[ "$act" == \{* ]]; then
                [ -z "$tgt" ] && tgt=$(echo "$act" | jq -r '.target // empty' 2>/dev/null)
                [ -z "$flg" ] && flg=$(echo "$act" | jq -r '.flags // empty' 2>/dev/null)
                local inner_act
                inner_act=$(echo "$act" | jq -r '.action // .cmd // .subcommand // empty' 2>/dev/null)
                [ -n "$inner_act" ] && act="$inner_act"
            fi
            act=$(echo "$act" | tr -d '"{}\\\n\r' | awk '{print $1}')
            [ -z "$act" ] && act="status"

            local cmd_str="$act"
            [ -n "$tgt" ] && cmd_str="$cmd_str $tgt"
            [ -n "$flg" ] && cmd_str="$cmd_str $flg"
            output=$(commands_dispatch "/phytology $cmd_str" "$workdir" 2>&1)
            exit_code=$?
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}
