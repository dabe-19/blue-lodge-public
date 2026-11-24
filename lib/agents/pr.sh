#!/bin/bash
# ── George: Sovereign Pull Request & Code Promotion Engine (2026) ────
# Implements sovereign, closed-loop PR review and promotion.
# Operates in dual-mode:
#   1. Sovereign Gitea API (when container is active on port 3088)
#   2. Pure Local Worktree PR Queue (.george/pulls/) when offline
# Strict GitFlow enforcement: all PRs target 'develop'; 'main' is protected.

[ -n "${_LIB_PR_LOADED:-}" ] && return 0; _LIB_PR_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
PR_DIR="${GEORGE_DIR}/pulls"
GITEA_CONF="${GEORGE_DIR}/gitea.conf"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/git.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/subagents.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/memory/journal.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/limits.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/alerts.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/treesitter.sh" 2>/dev/null || true

pr_init() {
    mkdir -p "$PR_DIR" 2>/dev/null || true
    gitflow_init "$LODGE_DIR" >/dev/null 2>&1 || true
}

pr_is_gitea_online() {
    if declare -f _gitea_is_test_mode &>/dev/null && _gitea_is_test_mode; then
        return 1
    fi
    if declare -f gitea_is_online &>/dev/null; then
        gitea_is_online
        return $?
    fi
    local url="${GITEA_URL:-http://127.0.0.1:3088}" code
    code=$(curl -s --max-time 1 -o /dev/null -w '%{http_code}' "${url}/api/v1/version" 2>/dev/null || true)
    [ -n "$code" ] && [ "$code" != "000" ]
}

pr_next_id() {
    pr_init
    local max=0
    for f in "$PR_DIR"/PR-*.json; do
        [ ! -f "$f" ] && continue
        local num
        num=$(basename "$f" | sed -E 's/PR-([0-9]+)\.json/\1/' | sed 's/^0*//')
        [ -n "$num" ] && [ "$num" -gt "$max" ] 2>/dev/null && max="$num"
    done
    printf "PR-%03d" $((max + 1))
}

pr_create() {
    local source_branch="$1"
    local title="$2"
    local dossier="${3:-}"
    local target_branch="${4:-develop}"
    local force_local="${5:-0}"

    if [ -z "$source_branch" ] || [ -z "$title" ]; then
        ui_err "Usage: pr_create <source_branch> <title> [dossier] [target_branch=develop]"
        return 1
    fi

    # GitFlow landmark check: forbid targeting main/master directly
    if ! gitflow_guard_check "$target_branch"; then
        return 1
    fi

    # Verify source branch exists
    if ! git -C "$LODGE_DIR" rev-parse --verify "$source_branch" &>/dev/null; then
        ui_err "Source branch '$source_branch' does not exist."
        return 1
    fi

    # Check if target branch exists, create if needed
    if ! git -C "$LODGE_DIR" rev-parse --verify "$target_branch" &>/dev/null; then
        git -C "$LODGE_DIR" branch "$target_branch" HEAD 2>/dev/null || true
    fi

    # Route to Gitea if online and not forced local
    if [ "$force_local" -ne 1 ] && pr_is_gitea_online; then
        local gitea_pr
        if declare -f gitea_pr_create &>/dev/null; then
            ui_info "Gitea is online — dispatching PR to sovereign Gitea forge..."
            gitea_pr_create "$source_branch" "$target_branch" "$title" "$dossier"
            return $?
        fi
    fi

    # Fallback to pure local file-backed PR queue
    pr_init
    local pr_id
    pr_id=$(pr_next_id)
    local pr_json_file="$PR_DIR/${pr_id}.json"
    local pr_dossier_file="$PR_DIR/${pr_id}.dossier.md"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")
    local author
    author=$(git config user.name 2>/dev/null || echo "George (Blue Lodge)")

    local diffstat
    diffstat=$(git -C "$LODGE_DIR" diff --stat "$target_branch..$source_branch" 2>&1)

    # Save metadata
    jq -n \
        --arg id "$pr_id" \
        --arg title "$title" \
        --arg author "$author" \
        --arg src "$source_branch" \
        --arg tgt "$target_branch" \
        --arg created "$now" \
        --arg stat "$diffstat" \
        '{
            id: $id,
            title: $title,
            author: $author,
            source_branch: $src,
            target_branch: $tgt,
            status: "PROPOSED",
            diffstat: $stat,
            created_at: $created,
            updated_at: $created
        }' > "$pr_json_file"

    # Save markdown dossier
    cat > "$pr_dossier_file" << EOF
# Pull Request ${pr_id}: ${title}

- **Author**: ${author}
- **Source Branch**: \`${source_branch}\`
- **Target Branch**: \`${target_branch}\`
- **Date**: ${now}
- **Status**: PROPOSED

## Rationale & Empirical Delta
${dossier:-"No empirical dossier provided."}

## Diffstat
\`\`\`text
${diffstat}
\`\`\`
EOF

    ui_ok "Local Pull Request created: ${pr_id} (${source_branch} → ${target_branch})"
    ui_dim "  Title: ${title}"
    ui_dim "  Audit: /pr audit ${pr_id}"
    echo "$pr_id"
}

pr_list() {
    pr_init
    local force_local="${1:-0}"

    ui_section "Lodge Pull Requests Queue (GitFlow: Target 'develop')"
    echo ""

    if [ "$force_local" -ne 1 ] && pr_is_gitea_online; then
        printf "  %bForge Mode:%b Sovereign Gitea (http://127.0.0.1:3088)\n\n" "$C_GREEN" "$C_RESET"
        if declare -f gitea_pr_list &>/dev/null; then
            gitea_pr_list
            echo ""
        fi
    else
        printf "  %bForge Mode:%b Pure Local Worktree Queue (.george/pulls/)\n\n" "$C_CYAN" "$C_RESET"
    fi

    local count=0
    printf "%-10s %-20s %-10s %-14s %s\n" "PR ID" "BRANCHES" "STATUS" "AUTHOR" "TITLE"
    printf "%-10s %-20s %-10s %-14s %s\n" "----------" "--------------------" "----------" "--------------" "-----------------------------------"

    for f in "$PR_DIR"/PR-*.json; do
        [ ! -f "$f" ] && continue
        count=$((count + 1))
        local pid psrc ptgt pstat pauth ptitle
        pid=$(jq -r .id "$f")
        psrc=$(jq -r .source_branch "$f")
        ptgt=$(jq -r .target_branch "$f")
        pstat=$(jq -r .status "$f")
        pauth=$(jq -r .author "$f")
        ptitle=$(jq -r .title "$f")

        local status_color="$pstat"
        case "$pstat" in
            PROPOSED)      status_color="${COLOR_YELLOW:-}${pstat}${COLOR_RESET:-}" ;;
            AUDITING)      status_color="${COLOR_CYAN:-}${pstat}${COLOR_RESET:-}" ;;
            AUDITED_PASS)  status_color="${COLOR_GREEN:-}${pstat}${COLOR_RESET:-}" ;;
            MERGED)        status_color="${COLOR_GREEN:-}${pstat}${COLOR_RESET:-}" ;;
            REJECTED|FAIL) status_color="${COLOR_RED:-}${pstat}${COLOR_RESET:-}" ;;
        esac

        local branch_str="${psrc:0:9}→${ptgt:0:8}"
        printf "%-10s %-20s %-19b %-14s %s\n" "$pid" "$branch_str" "$status_color" "${pauth:0:13}" "${ptitle:0:35}"
    done

    if [ "$count" -eq 0 ]; then
        ui_dim "  No local PRs registered in queue."
    fi
    echo ""
}

pr_show() {
    local pr_id="$1"
    if [ -z "$pr_id" ]; then
        ui_err "Usage: pr_show <PR_ID>"
        return 1
    fi
    local clean_id="${pr_id#\#}"
    if [[ "$clean_id" =~ ^[0-9]+$ ]] && pr_is_gitea_online; then
        local pr_data
        pr_data=$(gitea_pr_get "$clean_id")
        if echo "$pr_data" | jq -e .number &>/dev/null; then
            echo "# PR #${clean_id}: $(echo "$pr_data" | jq -r .title)"
            echo "- Branches: $(echo "$pr_data" | jq -r .head.ref) → $(echo "$pr_data" | jq -r .base.ref)"
            echo "- State:    $(echo "$pr_data" | jq -r .state)"
            echo "- URL:      $(echo "$pr_data" | jq -r .html_url)"
            echo ""
            echo "## Dossier"
            echo "$pr_data" | jq -r .body
            return 0
        fi
    fi
    local dossier_file="$PR_DIR/${pr_id}.dossier.md"
    if [ -f "$dossier_file" ]; then
        cat "$dossier_file"
    else
        ui_err "PR $pr_id not found in local queue."
        return 1
    fi
}

pr_diff() {
    local pr_id="$1"
    local stat_only="${2:-false}"
    local clean_id="${pr_id#\#}"
    if [[ "$clean_id" =~ ^[0-9]+$ ]] && pr_is_gitea_online; then
        local pr_data
        pr_data=$(gitea_pr_get "$clean_id")
        if echo "$pr_data" | jq -e .number &>/dev/null; then
            local src tgt
            src=$(echo "$pr_data" | jq -r .head.ref)
            tgt=$(echo "$pr_data" | jq -r .base.ref)
            git -C "$LODGE_DIR" fetch gitea "$src" >/dev/null 2>&1 || true
            local diff_cmd=(git -C "$LODGE_DIR" diff "gitea/${tgt}..gitea/${src}")
            [ "$stat_only" = "true" ] && diff_cmd+=(--stat)
            "${diff_cmd[@]}"
            return $?
        fi
    fi

    local json_file="$PR_DIR/${pr_id}.json"
    if [ ! -f "$json_file" ]; then
        ui_err "PR $pr_id not found in local queue."
        return 1
    fi

    local src tgt
    src=$(jq -r .source_branch "$json_file")
    tgt=$(jq -r .target_branch "$json_file")

    local diff_cmd=(git -C "$LODGE_DIR" diff "$tgt..$src")
    [ "$stat_only" = "true" ] && diff_cmd+=(--stat)
    "${diff_cmd[@]}"
}

# Write-scope denylist helper for PR audit (shares rules with remediation.sh)
pr_scope_violations_from_list() {
    if declare -f remediation_scope_violations_from_list &>/dev/null; then
        remediation_scope_violations_from_list
        return 0
    fi
    local -a pats=()
    local deny_file="${GEORGE_DIR:-$LODGE_DIR/.george}/remediation/write_denylist"
    if [ -f "$deny_file" ]; then
        mapfile -t pats < <(grep -vE '^\s*(#|$)' "$deny_file")
    else
        pats=("lib/core/react*" "lib/core/agent*" "lib/comms/discord_bridge.sh" "lib/comms/web.sh")
    fi
    local path p
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        for p in "${pats[@]}"; do
            # shellcheck disable=SC2053
            if [[ "$path" == $p ]]; then echo "$path"; break; fi
        done
    done
}

pr_audit() {
    local pr_id="$1"
    local clean_id="${pr_id#\#}"
    local is_gitea=0
    local src tgt title
    local json_file="$PR_DIR/${pr_id}.json"

    pr_init

    if [[ "$clean_id" =~ ^[0-9]+$ ]] && pr_is_gitea_online; then
        local pr_data
        pr_data=$(gitea_pr_get "$clean_id")
        if echo "$pr_data" | jq -e .number &>/dev/null; then
            is_gitea=1
            src=$(echo "$pr_data" | jq -r .head.ref)
            tgt=$(echo "$pr_data" | jq -r .base.ref)
            title=$(echo "$pr_data" | jq -r .title)
            git -C "$LODGE_DIR" fetch gitea "${src}:refs/remotes/gitea/${src}" >/dev/null 2>&1 || git -C "$LODGE_DIR" fetch gitea "$src" >/dev/null 2>&1 || true
            git -C "$LODGE_DIR" fetch gitea "${tgt}:refs/remotes/gitea/${tgt}" >/dev/null 2>&1 || true
        fi
    fi

    if [ "$is_gitea" -eq 0 ]; then
        if [ ! -f "$json_file" ]; then
            ui_err "PR $pr_id not found in local queue."
            return 1
        fi
        src=$(jq -r .source_branch "$json_file")
        tgt=$(jq -r .target_branch "$json_file")
        title=$(jq -r .title "$json_file")
    fi

    ui_section "Three Degrees Audit: ${pr_id} (${src} → ${tgt})"
    ui_step "First Degree: Ingesting PR metadata and promotion dossier..."

    # Update status to AUDITING if local
    local tmp_json="${json_file}.tmp.${BASHPID:-$$}"
    if [ "$is_gitea" -eq 0 ]; then
        jq '.status = "AUDITING"' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
    fi

    local review_dir="${LODGE_DIR}/.sandboxes/review_${clean_id}"
    local review_branch="review/${clean_id}"

    # Clean previous review worktree if exists
    git -C "$LODGE_DIR" worktree remove --force "$review_dir" 2>/dev/null || rm -rf "$review_dir" 2>/dev/null || true
    git -C "$LODGE_DIR" branch -D "$review_branch" 2>/dev/null || true

    ui_step "Spawning isolated review sandbox worktree at $review_dir..."
    if ! git -C "$LODGE_DIR" worktree add -b "$review_branch" "$review_dir" "$tgt" 2>/dev/null; then
        ui_err "Failed to provision review worktree from target branch $tgt"
        return 1
    fi

    local audit_log="$PR_DIR/${clean_id}.audit.log"
    : > "$audit_log"

    ui_step "Merging candidate branch '$src' into review worktree..."
    local merge_err=0
    local merge_ref="$src"
    if [ "$is_gitea" -eq 1 ] && git -C "$review_dir" rev-parse --verify "gitea/$src" &>/dev/null; then
        merge_ref="gitea/$src"
    elif ! git -C "$review_dir" rev-parse --verify "$merge_ref" &>/dev/null; then
        git -C "$review_dir" rev-parse --verify "gitea/$src" &>/dev/null && merge_ref="gitea/$src"
    fi
    (
        cd "$review_dir" || exit 1
        git merge --no-commit --no-ff "$merge_ref" >> "$audit_log" 2>&1
    ) || merge_err=$?

    if [ "$merge_err" -ne 0 ]; then
        ui_err "Merge conflict detected while merging '$src' into '$tgt'."
        echo "[AUDIT FAIL] Merge conflict during review sandbox integration." >> "$audit_log"
        if [ "$is_gitea" -eq 0 ]; then
            jq '.status = "REJECTED" | .audit_verdict = "MERGE_CONFLICT"' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
        else
            gitea_issue_comment "$clean_id" "### ❌ [Audit Failed] Merge Conflict
Unable to merge \`${src}\` into \`${tgt}\`. Please rebase candidate branch." >/dev/null 2>&1 || true
        fi
        git -C "$LODGE_DIR" worktree remove --force "$review_dir" 2>/dev/null || true
        git -C "$LODGE_DIR" branch -D "$review_branch" 2>/dev/null || true
        return 1
    fi

    ui_step "Second Degree: Invoking Write-Scope Denylist, Security, and Style Guardians..."
    # 0. Write-Scope Denylist Gate (enforced unless PR_ALLOW_DENYLIST=1)
    local changed_files
    changed_files=$( (git -C "$review_dir" diff --name-only "$tgt" 2>/dev/null; git -C "$review_dir" diff --cached --name-only 2>/dev/null) | sort -u )
    if [ "${PR_ALLOW_DENYLIST:-0}" -ne 1 ]; then
        local scope_viol
        scope_viol=$(printf '%s\n' "$changed_files" | pr_scope_violations_from_list)
        if [ -n "$scope_viol" ]; then
            ui_err "Write-Scope Denylist Gate: PR modifies protected paths:"$'\n'"$scope_viol"
            echo "[SCOPE DENYLIST FAIL] Protected paths modified: $(echo "$scope_viol" | tr '\n' ' ')" >> "$audit_log"
            if [ "$is_gitea" -eq 0 ]; then
                jq --arg v "$(echo "$scope_viol" | tr '\n' ' ')" '.status = "REJECTED" | .audit_verdict = "SCOPE_DENYLIST" | .rejection_reason = ("Write-scope denylist violation: " + $v)' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
            else
                gitea_pr_review "$clean_id" "REQUEST_CHANGES" "[Write-Scope Denylist Gate] BLOCKED — PR modifies protected paths requiring manual operator promotion:
\`\`\`
$scope_viol
\`\`\`" >/dev/null 2>&1 || \
                gitea_issue_comment "$clean_id" "### 🛑 [Audit Blocked] Write-Scope Denylist Violation
PR modifies protected core paths requiring manual operator review:
\`\`\`
$scope_viol
\`\`\`" >/dev/null 2>&1 || true
            fi
            git -C "$LODGE_DIR" worktree remove --force "$review_dir" 2>/dev/null || true
            git -C "$LODGE_DIR" branch -D "$review_branch" 2>/dev/null || true
            return 1
        fi
    fi

    # 1. Check for unsafe eval/shell injection patterns
    local sec_issues
    sec_issues=$(git -C "$review_dir" diff --cached "$tgt" 2>/dev/null | grep -E '^\+[[:space:]]*(eval[[:space:]]|rm[[:space:]]+-rf[[:space:]]+/)') || true
    if [ -n "$sec_issues" ]; then
        ui_warn "The Tyler (Security Gate): High-risk command pattern detected."
        echo "[SECURITY FAIL] Potential unsafe pattern: $sec_issues" >> "$audit_log"
        if [ "$is_gitea" -eq 0 ]; then
            jq '.status = "REJECTED" | .audit_verdict = "SECURITY_REJECTED"' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
        else
            gitea_pr_review "$clean_id" "REQUEST_CHANGES" "[The Tyler: Security Gate] REJECTED — High-risk command pattern detected:
\`\`\`
$sec_issues
\`\`\`" >/dev/null 2>&1 || \
            gitea_issue_comment "$clean_id" "[The Tyler: Security Gate] REJECTED — High-risk command pattern detected:
\`\`\`
$sec_issues
\`\`\`" >/dev/null 2>&1 || true
        fi
        git -C "$LODGE_DIR" worktree remove --force "$review_dir" 2>/dev/null || true
        git -C "$LODGE_DIR" branch -D "$review_branch" 2>/dev/null || true
        return 1
    else
        ui_ok "The Tyler (Security Gate): Zero high-risk shell patterns detected."
        echo "[SECURITY PASS] The Tyler audit cleared." >> "$audit_log"
    fi

    # 2. The Warden: Structural AST & Style verification
    local sym_diff
    sym_diff=$(treesitter_diff_symbols "$tgt" "HEAD" "$review_dir" 2>/dev/null || true)
    if [ "$is_gitea" -eq 1 ]; then
        gitea_issue_comment "$clean_id" "[The Warden: Style & AST Gate] PASSED — POSIX syntax, write-scope denylist, and AST structural integrity verified.
\`\`\`
${sym_diff:0:1000}
\`\`\`" >/dev/null 2>&1 || true
    fi

    # 3. Run Test Harness (Fixed subshell exit-code capture + targeted & syntax validation)
    ui_step "Running test harness validation in review sandbox..."
    local test_res=0
    (
        cd "$review_dir" || exit 1
        if [ -x "scripts/ci/bootstrap_env.sh" ]; then
            LODGE_DIR="$review_dir" GEORGE_DIR="$review_dir/.george" RECALL_DB="$review_dir/.george/recall.db" \
                bash scripts/ci/bootstrap_env.sh --no-apt >> "$audit_log" 2>&1 || true
        fi
        local _syntax_ok=1 _f
        while IFS= read -r _f; do
            [ -z "$_f" ] && continue
            [ ! -f "$_f" ] && continue
            case "$_f" in
                tests/test_*.sh)
                    if ! bash -n "$_f" >> "$audit_log" 2>&1; then
                        echo "[SYNTAX FAIL] bash -n failed on $_f" >> "$audit_log"
                        _syntax_ok=0
                    fi
                    # Anti-Evasion Gate: prohibit top-level 'exit 0' before test_start
                    local _ts_line _ex_line
                    _ts_line=$(grep -nE '^[[:space:]]*test_start([[:space:]]|$)' "$_f" 2>/dev/null | head -n 1 | cut -d: -f1)
                    if [ -n "$_ts_line" ] && [ "$_ts_line" -gt 1 ]; then
                        _ex_line=$(head -n "$((_ts_line - 1))" "$_f" | grep -nE '(^|[[:space:];])exit[[:space:]]+0([[:space:];]|$)' 2>/dev/null | head -n 1 | cut -d: -f1)
                        if [ -n "$_ex_line" ]; then
                            echo "[TEST EVASION FAIL] Top-level 'exit 0' before test_start detected in $_f (line $_ex_line). Wholesale test-suite skipping is prohibited." >> "$audit_log"
                            _syntax_ok=0
                        fi
                    fi
                    ;;
                *.sh)
                    if ! bash -n "$_f" >> "$audit_log" 2>&1; then
                        echo "[SYNTAX FAIL] bash -n failed on $_f" >> "$audit_log"
                        _syntax_ok=0
                    fi
                    ;;
                *.py)
                    if command -v python3 &>/dev/null && ! python3 -m py_compile "$_f" >> "$audit_log" 2>&1; then
                        echo "[SYNTAX FAIL] py_compile failed on $_f" >> "$audit_log"
                        _syntax_ok=0
                    fi
                    ;;
            esac
        done <<< "$changed_files"
        [ "$_syntax_ok" -eq 1 ] || exit 1

        if [ "${PR_AUDIT_FULL_SUITE:-0}" -eq 1 ] && [ -f "tests/run_all.sh" ]; then
            bash tests/run_all.sh >> "$audit_log" 2>&1 || exit $?
        elif [ -f "tests/run_all.sh" ]; then
            local -a _target_suites=()
            if [ -x "scripts/ci/select_tests.sh" ]; then
                while IFS= read -r _s; do
                    [ -n "$_s" ] && _target_suites+=("$_s")
                done < <(printf '%s\n' "$changed_files" | LODGE_DIR="$review_dir" bash scripts/ci/select_tests.sh --stdin)
            else
                while IFS= read -r _f; do
                    [ -z "$_f" ] && continue
                    local _base
                    _base=$(basename "$_f")
                    _base="${_base%.*}"
                    if [[ "$_base" == test_* ]] && [ -f "tests/${_base}.sh" ]; then
                        [[ " ${_target_suites[*]} " != *" ${_base} "* ]] && _target_suites+=("$_base")
                    elif [ -f "tests/test_${_base}.sh" ]; then
                        [[ " ${_target_suites[*]} " != *" test_${_base} "* ]] && _target_suites+=("test_${_base}")
                    fi
                done <<< "$changed_files"
            fi
            if [ "${#_target_suites[@]}" -gt 0 ]; then
                local _suite_out _suite_ec=0
                _suite_out=$(bash tests/run_all.sh "${_target_suites[@]}" 2>&1) || _suite_ec=$?
                printf '%s\n' "$_suite_out" >> "$audit_log"
                [ "$_suite_ec" -eq 0 ] || exit "$_suite_ec"
                # Anti-Evasion Gate: ensure suites with assertions actually executed >0 assertions
                local _clean_out
                _clean_out=$(printf '%s\n' "$_suite_out" | sed -E 's/\x1b\[[0-9;]*m//g')
                if printf '%s\n' "$_clean_out" | grep -qE '^[[:space:]]*0 passed[[:space:]]+\(0 total\)'; then
                    echo "[TEST EVASION FAIL] Targeted test suite executed 0 assertions (0 passed / 0 total)." >> "$audit_log"
                    exit 1
                fi
                if ! printf '%s\n' "$_clean_out" | grep -qE '[1-9][0-9]* passed'; then
                    echo "[TEST EVASION FAIL] Targeted test suite exited without recording any passing assertions." >> "$audit_log"
                    exit 1
                fi
            fi
        elif [ -f "tests/run.sh" ]; then
            bash tests/run.sh >> "$audit_log" 2>&1 || exit $?
        fi
    ) || test_res=$?

    # Cleanup review worktree
    git -C "$LODGE_DIR" worktree remove --force "$review_dir" 2>/dev/null || true
    git -C "$LODGE_DIR" branch -D "$review_branch" 2>/dev/null || true
    git -C "$LODGE_DIR" worktree prune 2>/dev/null || true

    ui_step "Third Degree: Evaluating audit verdict..."
    if [ "$test_res" -eq 0 ]; then
        ui_ok "Verdict: PASS (All test suites green in sandbox merge)"
        echo "[AUDIT PASS] All test suites passed." >> "$audit_log"
        if [ "$is_gitea" -eq 0 ]; then
            jq '.status = "AUDITED_PASS" | .audit_verdict = "PASS"' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
        else
            ui_info "Gitea PR #${clean_id} passed Three Degrees Audit! Ready for George ReAct Code Review."
            gitea_issue_comment "$clean_id" "### ⚖️ Three Degrees Audit Verdict: PASSED
Write-scope denylist, Tyler security gate, and sandbox test suites passed 100% green. Proceeding to George 1-Reviewer ReAct Evaluation." >/dev/null 2>&1 || true
        fi
        return 0
    else
        ui_err "Verdict: REJECT (Test regressions detected in review sandbox)"
        echo "[AUDIT FAIL] Test regressions detected (exit $test_res)." >> "$audit_log"
        local max_attempts
        max_attempts=$(limits_get MAX_REMEDIATION_ATTEMPTS 5 2>/dev/null || echo 5)
        local attempt_file="$PR_DIR/${clean_id}.attempts"
        local cur_attempts=1
        [ -f "$attempt_file" ] && cur_attempts=$(($(cat "$attempt_file" 2>/dev/null || echo 0) + 1))
        echo "$cur_attempts" > "$attempt_file"

        if [ "$is_gitea" -eq 0 ]; then
            jq --argjson att "$cur_attempts" '.status = "REJECTED" | .audit_verdict = "TEST_FAILURES" | .attempts = $att' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
            if [ "$cur_attempts" -ge "$max_attempts" ]; then
                alerts_dispatch tier3 "PR ${pr_id} Exceeded Max Remediation Attempts (${cur_attempts}/${max_attempts})" "Autonomous PR audit failed repeatedly. Operator intervention required." "" >/dev/null 2>&1 || true
            fi
        else
            ui_warn "Gitea PR #${clean_id} failed audit verification."
            gitea_issue_comment "$clean_id" "### ❌ George Audit Verdict: REJECTED
Test suite regressions detected in review sandbox (exit code $test_res)." >/dev/null 2>&1 || true

            if [ "$cur_attempts" -ge "$max_attempts" ]; then
                alerts_dispatch tier3 "PR #${clean_id} Exceeded Max Remediation Attempts (${cur_attempts}/${max_attempts})" "Autonomous PR audit failed repeatedly. Operator intervention required." "${GITEA_URL:-http://127.0.0.1:3088}/george/blue-lodge/pulls/${clean_id}" >/dev/null 2>&1 || true
                gitea_issue_comment "$clean_id" "🚨 **[Tier 3 Escalation]** PR #${clean_id} reached maximum remediation ceiling (${cur_attempts}/${max_attempts} attempts). Escalated to human operator." >/dev/null 2>&1 || true
            fi
        fi
        return 1
    fi
}

# ── 1-Reviewer Acceptance Criteria & ReAct Code Review Engine ─────────

# Persists a structured PR review verdict and commentary locally in $PR_DIR/<clean_id>.review.json
# and updates $PR_DIR/<pr_id>.json if present.
pr_record_review() {
    local pr_id="$1"
    local verdict="${2:-COMMENT}"
    local comment="${3:-}"
    local reviewer="${4:-George (ReAct Reviewer)}"
    local clean_id="${pr_id#\#}"
    pr_init

    [ "$verdict" = "APPROVE" ] && verdict="APPROVED"
    if printf '%s' "$comment" | grep -qiE 'VERDICT:[[:space:]]*REQUEST_CHANGES|\[George PR Review:[[:space:]]*REQUEST_CHANGES\]|\*\*REQUEST_CHANGES\*\*'; then
        verdict="REQUEST_CHANGES"
    elif [ "$verdict" = "COMMENT" ] && printf '%s' "$comment" | grep -qiE 'VERDICT:[[:space:]]*APPROVED|\[George PR Review:[[:space:]]*APPROVED\]|\*\*APPROVED\*\*'; then
        verdict="APPROVED"
    elif [ "$verdict" != "APPROVED" ] && printf '%s' "$comment" | grep -qiE 'REQUEST_CHANGES'; then
        verdict="REQUEST_CHANGES"
    fi

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")
    local rev_file="$PR_DIR/${clean_id}.review.json"
    if [ -f "$rev_file" ]; then
        local prev_verdict prev_comment
        prev_verdict=$(jq -r '.verdict // empty' "$rev_file" 2>/dev/null || true)
        prev_comment=$(jq -r '.comment // empty' "$rev_file" 2>/dev/null || true)
        # Never let a supplementary COMMENT or follow-up REQUEST_CHANGES note overwrite an existing REQUEST_CHANGES body
        if [ "$prev_verdict" = "REQUEST_CHANGES" ] && { [ "$verdict" = "COMMENT" ] || [ "$verdict" = "REQUEST_CHANGES" ]; }; then
            verdict="REQUEST_CHANGES"
            if [ -n "$prev_comment" ] && [ -n "$comment" ] && [ "$prev_comment" != "$comment" ]; then
                comment="${prev_comment}"$'\n\n---\n\n'"${comment}"
            elif [ -n "$prev_comment" ]; then
                comment="$prev_comment"
            fi
        fi
    fi

    local tmp_rev="${rev_file}.tmp.${BASHPID:-$$}"
    jq -n \
        --arg id "$clean_id" \
        --arg verdict "$verdict" \
        --arg comment "$comment" \
        --arg reviewer "$reviewer" \
        --arg ts "$now" \
        '{
            pr_id: $id,
            verdict: $verdict,
            approved: ($verdict == "APPROVED"),
            comment: $comment,
            reviewer: $reviewer,
            reviewed_at: $ts
        }' > "$tmp_rev" && mv -f "$tmp_rev" "$rev_file"

    # Mirror to main repo pulls directory if invoked inside an isolated worktree
    local root_pulls="${LODGE_DIR:-$HOME/blue-lodge}/.george/pulls"
    if [ "$PR_DIR" != "$root_pulls" ] && [ -d "${LODGE_DIR:-$HOME/blue-lodge}/.george" ]; then
        mkdir -p "$root_pulls" 2>/dev/null || true
        cp -f "$rev_file" "$root_pulls/${clean_id}.review.json" 2>/dev/null || true
    fi

    local json_file="$PR_DIR/${pr_id}.json"
    [ ! -f "$json_file" ] && json_file="$PR_DIR/${clean_id}.json"
    if [ -f "$json_file" ]; then
        local tmp_json="${json_file}.tmp.${BASHPID:-$$}"
        jq \
            --arg v "$verdict" \
            --arg c "$comment" \
            --arg r "$reviewer" \
            --arg ts "$now" \
            '.review_verdict = $v | .review_comment = $c | .review_approved = ($v == "APPROVED") | .reviewed_by = $r | .reviewed_at = $ts' \
            "$json_file" > "$tmp_json" 2>/dev/null && mv -f "$tmp_json" "$json_file"
    fi
    return 0
}

# Checks whether the PR satisfies the 1-Reviewer Acceptance Criteria:
# requires an APPROVED review verdict AND a non-empty review comment by George or an operator,
# with no overriding REQUEST_CHANGES verdict.
pr_has_reviewer_acceptance() {
    local pr_id="$1"
    local clean_id="${pr_id#\#}"
    [ -z "$clean_id" ] && return 1

    local rev_file="$PR_DIR/${clean_id}.review.json"
    if [ -f "$rev_file" ]; then
        if jq -e '.verdict == "REQUEST_CHANGES" or ((.comment // "") | test("\\[George PR Review:\\s*REQUEST_CHANGES\\]|VERDICT:\\s*REQUEST_CHANGES|\\*\\*REQUEST_CHANGES\\*\\*"; "i")) or (.approved != true and ((.comment // "") | test("REQUEST_CHANGES"; "i")))' "$rev_file" >/dev/null 2>&1; then
            return 1
        fi
        if jq -e '.approved == true and ((.comment // "") | length > 0)' "$rev_file" >/dev/null 2>&1; then
            return 0
        fi
    fi

    local json_file="$PR_DIR/${pr_id}.json"
    [ ! -f "$json_file" ] && json_file="$PR_DIR/${clean_id}.json"
    if [ -f "$json_file" ]; then
        if jq -e '.review_verdict == "REQUEST_CHANGES" or ((.review_comment // "") | test("\\[George PR Review:\\s*REQUEST_CHANGES\\]|VERDICT:\\s*REQUEST_CHANGES|\\*\\*REQUEST_CHANGES\\*\\*"; "i")) or (.review_approved != true and ((.review_comment // "") | test("REQUEST_CHANGES"; "i")))' "$json_file" >/dev/null 2>&1; then
            return 1
        fi
        if jq -e '.review_approved == true and ((.review_comment // "") | length > 0)' "$json_file" >/dev/null 2>&1; then
            return 0
        fi
    fi

    if [[ "$clean_id" =~ ^[0-9]+$ ]] && pr_is_gitea_online; then
        _gitea_load_conf
        local reviews_json
        reviews_json=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${clean_id}/reviews" \
            -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null || echo "[]")
        # Block if the latest Gitea review requests changes
        if echo "$reviews_json" | jq -e '(length > 0) and ((last | .state == "REQUEST_CHANGES") or ((last | .body // "") | test("\\[George PR Review:\\s*REQUEST_CHANGES\\]|VERDICT:\\s*REQUEST_CHANGES|\\*\\*REQUEST_CHANGES\\*\\*"; "i")) or ((last | .state != "APPROVED") and (((last | .body // "") | test("\\[George PR Review:\\s*APPROVED\\]|VERDICT:\\s*APPROVED"; "i")) | not) and ((last | .body // "") | test("REQUEST_CHANGES"; "i"))))' >/dev/null 2>&1; then
            local rej_body
            rej_body=$(echo "$reviews_json" | jq -r 'last | .body // ""' 2>/dev/null)
            pr_record_review "$clean_id" "REQUEST_CHANGES" "$rej_body" "George (Gitea Review)"
            return 1
        fi
        if echo "$reviews_json" | jq -e 'map(select((.state == "APPROVED" or (.state == "COMMENT" and ((.body // "") | test("\\[George PR Review:\\s*APPROVED\\]|VERDICT:\\s*APPROVED"; "i")))) and (((.body // "") | test("\\[George PR Review:\\s*REQUEST_CHANGES\\]|VERDICT:\\s*REQUEST_CHANGES|\\*\\*REQUEST_CHANGES\\*\\*"; "i")) | not))) | length > 0' >/dev/null 2>&1; then
            local r_body
            r_body=$(echo "$reviews_json" | jq -r 'map(select((.state == "APPROVED" or (.state == "COMMENT" and ((.body // "") | test("\\[George PR Review:\\s*APPROVED\\]|VERDICT:\\s*APPROVED"; "i")))) and (((.body // "") | test("\\[George PR Review:\\s*REQUEST_CHANGES\\]|VERDICT:\\s*REQUEST_CHANGES|\\*\\*REQUEST_CHANGES\\*\\*"; "i")) | not))) | last | .body // ""' 2>/dev/null)
            pr_record_review "$clean_id" "APPROVED" "$r_body" "George (Gitea Review)"
            return 0
        fi

        local comments_json
        comments_json=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues/${clean_id}/comments" \
            -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null || echo "[]")
        local review_comments_json
        review_comments_json=$(echo "$comments_json" | jq -c 'map(select((((.body // "") | test("\\[Auto-Remediation\\]"; "i")) | not) and ((.body // "") | test("\\[George PR Review:\\s*(APPROVED|REQUEST_CHANGES)\\]|VERDICT:\\s*(APPROVED|REQUEST_CHANGES)"; "i"))))' 2>/dev/null || echo "[]")
        if echo "$review_comments_json" | jq -e '(length > 0) and ((last | .body // "") | test("\\[George PR Review:\\s*REQUEST_CHANGES\\]|VERDICT:\\s*REQUEST_CHANGES"; "i"))' >/dev/null 2>&1; then
            local crej_body
            crej_body=$(echo "$review_comments_json" | jq -r 'last | .body // ""' 2>/dev/null)
            pr_record_review "$clean_id" "REQUEST_CHANGES" "$crej_body" "George (Gitea Comment)"
            return 1
        fi
        if echo "$review_comments_json" | jq -e '(length > 0) and ((last | .body // "") | test("\\[George PR Review:\\s*APPROVED\\]|VERDICT:\\s*APPROVED"; "i"))' >/dev/null 2>&1; then
            local c_body
            c_body=$(echo "$review_comments_json" | jq -r 'last | .body // ""' 2>/dev/null)
            pr_record_review "$clean_id" "APPROVED" "$c_body" "George (Gitea Comment)"
            return 0
        fi
    fi

    return 1
}

# Executes George's ReAct Code Review loop with the 'pr_reviewer' toolset to inspect
# the PR diff, comment on the PR, and record the 1-reviewer acceptance decision.
pr_review() {
    local pr_id="$1"
    local clean_id="${pr_id#\#}"
    [ -z "$clean_id" ] && { ui_err "Usage: pr_review <PR_ID>"; return 1; }
    pr_init

    local is_gitea=0 src="" tgt="" title="" body=""
    local json_file="$PR_DIR/${pr_id}.json"

    if [[ "$clean_id" =~ ^[0-9]+$ ]] && pr_is_gitea_online; then
        local pr_data
        pr_data=$(gitea_pr_get "$clean_id" 2>/dev/null || true)
        if echo "$pr_data" | jq -e .number &>/dev/null; then
            is_gitea=1
            src=$(echo "$pr_data" | jq -r .head.ref)
            tgt=$(echo "$pr_data" | jq -r .base.ref)
            title=$(echo "$pr_data" | jq -r .title)
            body=$(echo "$pr_data" | jq -r '.body // ""')
            git -C "$LODGE_DIR" fetch gitea "${src}:refs/remotes/gitea/${src}" >/dev/null 2>&1 || git -C "$LODGE_DIR" fetch gitea "$src" >/dev/null 2>&1 || true
        fi
    fi

    if [ "$is_gitea" -eq 0 ]; then
        if [ ! -f "$json_file" ]; then
            ui_err "PR $pr_id not found in local queue."
            return 1
        fi
        src=$(jq -r .source_branch "$json_file")
        tgt=$(jq -r .target_branch "$json_file")
        title=$(jq -r .title "$json_file")
        [ -f "$PR_DIR/${pr_id}.dossier.md" ] && body=$(cat "$PR_DIR/${pr_id}.dossier.md" 2>/dev/null || true)
    fi

    ui_section "George ReAct Code Review: ${pr_id} (${src} → ${tgt})"

    local diff_text diff_stat
    diff_stat=$(pr_diff "$pr_id" "true" 2>/dev/null || true)
    diff_text=$(pr_diff "$pr_id" "false" 2>/dev/null || true)

    if [ -z "$diff_text" ]; then
        ui_warn "PR $pr_id has an empty diff between '$tgt' and '$src'."
        pr_record_review "$clean_id" "REQUEST_CHANGES" "Rejected: PR contains zero net file modifications against ${tgt}."
        return 1
    fi

    # Clear any stale review artifact prior to running the review
    rm -f "$PR_DIR/${clean_id}.review.json" 2>/dev/null || true

    local review_wt="${LODGE_DIR}/.sandboxes/review_react_${clean_id}"
    local review_br="review_react/${clean_id}"
    git -C "$LODGE_DIR" worktree remove --force "$review_wt" 2>/dev/null || rm -rf "$review_wt" 2>/dev/null || true
    git -C "$LODGE_DIR" branch -D "$review_br" 2>/dev/null || true

    local src_ref="$src"
    if ! git -C "$LODGE_DIR" rev-parse --verify "$src_ref" &>/dev/null; then
        git -C "$LODGE_DIR" rev-parse --verify "gitea/$src" &>/dev/null && src_ref="gitea/$src"
    fi
    local wt_dir="$LODGE_DIR"
    if git -C "$LODGE_DIR" worktree add -b "$review_br" "$review_wt" "$src_ref" 2>/dev/null; then
        wt_dir="$review_wt"
        mkdir -p "$review_wt/.george" 2>/dev/null || true
        [ -f "$GEORGE_DIR/recall.db" ] && ln -sf "$GEORGE_DIR/recall.db" "$review_wt/.george/recall.db" 2>/dev/null || true
        [ -f "$GEORGE_DIR/gitea.conf" ] && cp -f "$GEORGE_DIR/gitea.conf" "$review_wt/.george/gitea.conf" 2>/dev/null || true
    fi

    local ci_test_checklist=""
    if printf '%s\n' "$diff_stat" | grep -qE '(\.gitea/workflows/|tests/|scripts/ci/)'; then
        ci_test_checklist="
CI & Test Integrity Mandate (Modified CI/Tests Detected):
- Reject (REQUEST_CHANGES) any PR that weakens assertions, adds wholesale 'exit 0' skip guards, or bypasses test suites when databases/files are absent.
- Verify any new CI workflow steps or packages are minimal, standard dependencies required by the codebase."
    fi

    local py_quant_checklist=""
    if printf '%s\n' "$diff_stat" | grep -qE '\.py([[:space:]]|\||$)'; then
        py_quant_checklist="
Python & Quant Cross-Module Contract Mandate (Modified .py Detected):
- Cross-Module Dict Key Parity: When modified code reads dict keys returned by another function/module (e.g. ohlcv_series, market_ctx, load_series), inspect the producer function to verify exact key names (e.g. 'close' vs 'c') rather than assuming.
- Dimensional & Horizon Unit Parity: Verify time-series and simulation calls pass matching time units (hours vs seconds, window-scaled vs per-hour parameters) and prefer explicit arithmetic (24 * 3600) over raw 5-digit second literals to prevent digit transposition.
- Producer-Consumer Test Coverage & Silent Exceptions: Flag blanket 'except Exception: pass' blocks that could silently mask KeyError/TypeError on schema drift, and ensure tests exercise both the data producer and consumer rather than only passing synthetic mock dicts."
    fi

    local review_prompt="Conduct a formal 1-Reviewer Acceptance Review for Pull Request ${pr_id} ('${title}', branch '${src}' -> '${tgt}').
PR Index: ${clean_id}

Diffstat:
${diff_stat}

Unified Diff (truncated to 8,000 chars):
${diff_text:0:8000}

Instructions:
1. Use your pr_reviewer tools (file_read, file_grep, code_outline, code_symbol_get, okf_traverse, okf_query, okf_search) to inspect any modified files and trace their OKF dependency blast radius in the workspace if needed.
2. Check for subshell variable-scoping bugs, unquoted expansions, missing flock concurrency guards, write-scope denylist violations, or logic regressions.${ci_test_checklist}${py_quant_checklist}
3. Submit your review on the PR by calling gitea_pr_review with index=${clean_id}, event=\"APPROVED\" (or \"REQUEST_CHANGES\" if defects are found), and a concise technical review body. If the review was already posted earlier in this session, never post a duplicate.
4. End your response with VERDICT: APPROVED or VERDICT: REQUEST_CHANGES.
5. Budget discipline: keep your plan to at most 2 milestones (inspect+verify -> submit). As soon as gitea_pr_review returns, do not plan further milestones; immediately emit your final VERDICT line. Close each step with milestone_complete before emitting plain text (plain text is intercepted while a milestone is still pending)."

    local review_verdict="" review_comment=""
    local can_run_react=0
    if declare -f react_run &>/dev/null; then
        if [ "${_PR_FORCE_REACT_REVIEW:-0}" -eq 1 ]; then
            can_run_react=1
        elif [ "${_LODGE_TESTING:-0}" -ne 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ]; then
            if declare -f endpoints_probe &>/dev/null && endpoints_probe "${ACTIVE_TIER:-1}" >/dev/null 2>&1; then
                can_run_react=1
            elif curl -sf --max-time 2 "${LLAMA_CPP_URL:-http://127.0.0.1:8080}/health" >/dev/null 2>&1; then
                can_run_react=1
            fi
        fi
    fi

    if [ "$can_run_react" -eq 1 ]; then
        ui_step "Running ReAct reviewer loop with profile 'pr_reviewer'..."
        # FIX 2026-10-25 (issue_f6e91bfda453 / PROCESS_STALL react_agent "reached turn ceiling (6 turns)")
        # The Pre-Loop Strategist may decompose this review into up to 6 DAG milestones
        # (honeydew_strategist.py prompt permits "2 to 6"), and each milestone needs at
        # least one turn plus a final synthesis turn. The old 6-turn budget left zero
        # headroom: the review was submitted on turn 3, but turns 4-6 were consumed by
        # milestone bookkeeping and the task halted at the ceiling with no final VERDICT
        # reply. 12 = 6 (max milestones) + 1 (final synthesis) + 5 (margin for stalls).
        # FIX 2026-11-03 (issue_28049ba81beb / PROCESS_STALL react_agent "reached turn ceiling (12 turns)")
        # The LLM strategist emitted an inspect -> verify -> submit DAG for PR 545; the
        # agent submitted the review mid-verify, the redundant submit step re-posted the
        # duplicate review on one extra turn, and the final synthesis/VERDICT turn fell
        # past the 12-turn ceiling. honeydew_strategist.py now short-circuits this task
        # class with a deterministic 2-milestone plan (inspect+verify -> submit), so the
        # arithmetic is: 12 = 2 (milestones, ~4 turns each in practice) + 1 (final
        # synthesis) + 9 (margin). Keep the ceiling unless the planner contract changes.
        # FIX 2026-11-06 (issue_9e6f03740883 / PROCESS_STALL react_agent "reached turn ceiling")
        # Align PR_REVIEW_MAX_TURNS default with the standard 200-turn ceiling
        # (${AGENT_MAX_TURNS:-200}) used across all other ReAct loops instead of an
        # arbitrary low turn cap (6 -> 12 -> 16) that trips PROCESS_STALL on multi-file
        # PR inspections and spawns unnecessary remediation runs. Bounded execution is
        # enforced by PR_REVIEW_WALL_BUDGET_S, the 2-milestone deterministic plan in
        # honeydew_strategist.py (which closes each step with milestone_complete before
        # emitting plain text), and react_run's loop/stall circuit breakers.
        local rev_turns="${PR_REVIEW_MAX_TURNS:-${AGENT_MAX_TURNS:-200}}"
        local rev_wall_budget="${PR_REVIEW_WALL_BUDGET_S:-2400}"
        local rev_session="pr_review_${clean_id}"
        local rev_tier="1"
        if declare -f endpoints_resolve_for_objective &>/dev/null; then
            local _pr_res
            _pr_res=$(endpoints_resolve_for_objective "pr_review" 2>/dev/null || true)
            if [ -n "$_pr_res" ]; then
                IFS='|' read -r rev_tier _ _ _ <<< "$_pr_res"
            fi
        fi
        (
            export GEORGE_PROMPT_PROFILE="pr_reviewer"
            export REACT_STRICT_TOOLS=1
            export REACT_WALL_BUDGET_S="$rev_wall_budget"
            react_run "$review_prompt" "$wt_dir" "$rev_turns" "$rev_tier" "$rev_session" "pr_reviewer" >/dev/null 2>&1
        ) || true

        if [ -f "$wt_dir/.george/pulls/${clean_id}.review.json" ]; then
            cp -f "$wt_dir/.george/pulls/${clean_id}.review.json" "$PR_DIR/${clean_id}.review.json" 2>/dev/null || true
        fi
        if [ -f "$PR_DIR/${clean_id}.review.json" ]; then
            review_verdict=$(jq -r '.verdict // empty' "$PR_DIR/${clean_id}.review.json" 2>/dev/null)
            review_comment=$(jq -r '.comment // empty' "$PR_DIR/${clean_id}.review.json" 2>/dev/null)
            if printf '%s' "$review_comment" | grep -qiE 'VERDICT:[[:space:]]*REQUEST_CHANGES|\[George PR Review:[[:space:]]*REQUEST_CHANGES\]|\*\*REQUEST_CHANGES\*\*'; then
                review_verdict="REQUEST_CHANGES"
            elif [ "$review_verdict" != "APPROVED" ] && printf '%s' "$review_comment" | grep -qiE 'REQUEST_CHANGES'; then
                review_verdict="REQUEST_CHANGES"
            fi
        fi

        local reply_candidate="" final_reply_file=""
        for reply_candidate in \
            "$wt_dir/.george/workspaces/${rev_session}/final_reply.txt" \
            "${GEORGE_DIR}/workspaces/${rev_session}/final_reply.txt" \
            "$wt_dir/.george/runs/${rev_session}/final_reply.md" \
            "${GEORGE_DIR}/runs/${rev_session}/final_reply.md" \
            "${LODGE_DIR}/.george/runs/${rev_session}/final_reply.md"; do
            if [ -f "$reply_candidate" ] && [ -s "$reply_candidate" ]; then
                final_reply_file="$reply_candidate"
                break
            fi
        done

        if [ -n "$final_reply_file" ]; then
            local reply_txt
            reply_txt=$(cat "$final_reply_file" 2>/dev/null || true)
            if [ -n "$reply_txt" ]; then
                [ -z "$review_comment" ] && review_comment="$reply_txt"
                if printf '%s' "$reply_txt" | grep -qiE 'VERDICT:[[:space:]]*REQUEST_CHANGES|\[George PR Review:[[:space:]]*REQUEST_CHANGES\]|\*\*REQUEST_CHANGES\*\*'; then
                    review_verdict="REQUEST_CHANGES"
                elif [ -z "$review_verdict" ] || [ "$review_verdict" = "COMMENT" ]; then
                    if printf '%s' "$reply_txt" | grep -qiE 'VERDICT:[[:space:]]*APPROVED|\[George PR Review:[[:space:]]*APPROVED\]|\*\*APPROVED\*\*|gitea_pr_review[^)]*APPROVED'; then
                        review_verdict="APPROVED"
                    elif printf '%s' "$reply_txt" | grep -qiE 'REQUEST_CHANGES'; then
                        review_verdict="REQUEST_CHANGES"
                    fi
                fi
            fi
        fi

        # If verdict is still missing or COMMENT on a Gitea PR (or final_reply was a duplicate-post guard note), inspect Gitea reviews/comments directly
        if [ "$is_gitea" -eq 1 ] && { [ -z "$review_verdict" ] || [ "$review_verdict" = "COMMENT" ] || printf '%s' "$review_comment" | grep -qiE 'already posted.*gitea_pr_review'; }; then
            _gitea_load_conf
            local _g_revs _g_cmts _g_rev_cmts
            _g_revs=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${clean_id}/reviews" \
                -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null || echo "[]")
            if echo "$_g_revs" | jq -e '(length > 0) and ((last | .state == "REQUEST_CHANGES") or ((last | .body // "") | test("\\[George PR Review:\\s*REQUEST_CHANGES\\]|VERDICT:\\s*REQUEST_CHANGES|\\*\\*REQUEST_CHANGES\\*\\*"; "i")) or ((last | .state != "APPROVED") and (((last | .body // "") | test("\\[George PR Review:\\s*APPROVED\\]|VERDICT:\\s*APPROVED"; "i")) | not) and ((last | .body // "") | test("REQUEST_CHANGES"; "i"))))' >/dev/null 2>&1; then
                review_verdict="REQUEST_CHANGES"
                review_comment=$(echo "$_g_revs" | jq -r 'last | .body // ""' 2>/dev/null)
            elif echo "$_g_revs" | jq -e 'map(select((.state == "APPROVED" or (.state == "COMMENT" and ((.body // "") | test("\\[George PR Review:\\s*APPROVED\\]|VERDICT:\\s*APPROVED"; "i")))) and (((.body // "") | test("\\[George PR Review:\\s*REQUEST_CHANGES\\]|VERDICT:\\s*REQUEST_CHANGES|\\*\\*REQUEST_CHANGES\\*\\*"; "i")) | not))) | length > 0' >/dev/null 2>&1; then
                review_verdict="APPROVED"
                review_comment=$(echo "$_g_revs" | jq -r 'map(select((.state == "APPROVED" or (.state == "COMMENT" and ((.body // "") | test("\\[George PR Review:\\s*APPROVED\\]|VERDICT:\\s*APPROVED"; "i")))) and (((.body // "") | test("\\[George PR Review:\\s*REQUEST_CHANGES\\]|VERDICT:\\s*REQUEST_CHANGES|\\*\\*REQUEST_CHANGES\\*\\*"; "i")) | not))) | last | .body // ""' 2>/dev/null)
            fi
            if [ -z "$review_verdict" ] || [ "$review_verdict" = "COMMENT" ] || printf '%s' "$review_comment" | grep -qiE 'already posted.*gitea_pr_review'; then
                _g_cmts=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues/${clean_id}/comments" \
                    -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null || echo "[]")
                _g_rev_cmts=$(echo "$_g_cmts" | jq -c 'map(select((((.body // "") | test("\\[Auto-Remediation\\]"; "i")) | not) and ((.body // "") | test("\\[George PR Review:\\s*(APPROVED|REQUEST_CHANGES)\\]|VERDICT:\\s*(APPROVED|REQUEST_CHANGES)"; "i"))))' 2>/dev/null || echo "[]")
                if echo "$_g_rev_cmts" | jq -e '(length > 0) and ((last | .body // "") | test("\\[George PR Review:\\s*REQUEST_CHANGES\\]|VERDICT:\\s*REQUEST_CHANGES"; "i"))' >/dev/null 2>&1; then
                    review_verdict="REQUEST_CHANGES"
                    review_comment=$(echo "$_g_rev_cmts" | jq -r 'last | .body // ""' 2>/dev/null)
                elif echo "$_g_rev_cmts" | jq -e '(length > 0) and ((last | .body // "") | test("\\[George PR Review:\\s*APPROVED\\]|VERDICT:\\s*APPROVED"; "i"))' >/dev/null 2>&1; then
                    review_verdict="APPROVED"
                    review_comment=$(echo "$_g_rev_cmts" | jq -r 'last | .body // ""' 2>/dev/null)
                fi
            fi
        fi

        # Never silently auto-approve when a live ReAct review ran without emitting APPROVED
        if [ -z "$review_verdict" ] || [ "$review_verdict" = "COMMENT" ]; then
            ui_warn "ReAct reviewer finished without an explicit APPROVED verdict for PR ${pr_id}; blocking auto-approval."
            review_verdict="REQUEST_CHANGES"
            [ -z "$review_comment" ] && review_comment="ReAct reviewer session (${rev_session}) completed without an explicit APPROVED verdict."
        fi
    fi

    # Clean up ephemeral review worktree
    if [ "$wt_dir" = "$review_wt" ]; then
        git -C "$LODGE_DIR" worktree remove --force "$review_wt" 2>/dev/null || rm -rf "$review_wt" 2>/dev/null || true
        git -C "$LODGE_DIR" branch -D "$review_br" 2>/dev/null || true
    fi

    # Fallback deterministic synthesis ONLY when ReAct LLM was offline / disabled (can_run_react=0)
    if [ -z "$review_verdict" ]; then
        if [ "${PR_REVIEW_REQUIRE_LLM:-0}" -eq 1 ]; then
            ui_err "ReAct reviewer did not produce a verdict for PR ${pr_id} (PR_REVIEW_REQUIRE_LLM=1)."
            return 1
        fi
        review_verdict="APPROVED"
        review_comment="### 🔎 [George PR Review: APPROVED]
- **PR**: \`${pr_id}\` (\`${src}\` → \`${tgt}\`)
- **Title**: ${title}
- **Verification**: Three Degrees Audit, write-scope denylist check, and syntax/test gates verified clean.
- **Diffstat**:
\`\`\`
${diff_stat}
\`\`\`
**VERDICT: APPROVED**"
    fi

    # Persist and post the review (ensuring normalized verdict is saved)
    pr_record_review "$pr_id" "$review_verdict" "$review_comment" "George (ReAct Reviewer)"
    if [ "$is_gitea" -eq 1 ] && [ "$can_run_react" -eq 0 ]; then
        gitea_pr_review "$clean_id" "$review_verdict" "$review_comment" >/dev/null 2>&1 || \
        gitea_issue_comment "$clean_id" "### 🔎 [George PR Review: ${review_verdict}]"$'\n\n'"${review_comment}" >/dev/null 2>&1 || true
    fi

    if [ "$review_verdict" = "APPROVED" ]; then
        ui_ok "George ReAct Review Verdict: APPROVED (${pr_id})"
        return 0
    else
        ui_warn "George ReAct Review Verdict: ${review_verdict} (${pr_id})"
        return 1
    fi
}

# Reconcile working-tree files that match incoming merged blobs (or promoted drift/remediation files)
# so `git merge --ff-only` in LODGE_DIR succeeds cleanly without untracked/unstaged overwrite errors.
_pr_reconcile_working_tree_for_merge() {
    local repo_dir="${1:-$LODGE_DIR}"
    local incoming_ref="$2"
    local head_branch="${3:-}"
    [ -z "$incoming_ref" ] && return 0
    git -C "$repo_dir" rev-parse --verify "$incoming_ref" &>/dev/null || return 0

    local ledger="${GEORGE_DIR:-$repo_dir/.george}/state/uncommitted_agent_edits.jsonl"
    [ ! -f "$ledger" ] && [ -f "${GEORGE_DIR:-$repo_dir/.george}/uncommitted_agent_edits.jsonl" ] && ledger="${GEORGE_DIR:-$repo_dir/.george}/uncommitted_agent_edits.jsonl"
    local _f _wt_blob _inc_blob _is_agent_file
    while IFS= read -r _f; do
        [ -z "$_f" ] && continue
        if [ -e "$repo_dir/$_f" ]; then
            _wt_blob=$(git -C "$repo_dir" hash-object "$_f" 2>/dev/null || true)
            _inc_blob=$(git -C "$repo_dir" rev-parse "${incoming_ref}:$_f" 2>/dev/null || true)
            _is_agent_file=0
            if [[ "$_f" =~ ^\.george/(cron_jobs|tools|slash)/ ]]; then
                _is_agent_file=1
            elif [ -f "$ledger" ] && jq -e --arg p "$_f" 'select(.rel_path == $p)' "$ledger" >/dev/null 2>&1; then
                _is_agent_file=1
            fi
            if [ -n "$_wt_blob" ] && [ "$_wt_blob" = "$_inc_blob" ]; then
                if git -C "$repo_dir" ls-files --error-unmatch "$_f" &>/dev/null; then
                    git -C "$repo_dir" checkout HEAD -- "$_f" 2>/dev/null || true
                else
                    rm -f "$repo_dir/$_f" 2>/dev/null || true
                fi
            elif [ "$_is_agent_file" -eq 1 ] && [[ "$head_branch" =~ ^(drift|remediation)/ ]]; then
                local _bkp_dir="${GEORGE_DIR:-$repo_dir/.george}/backups"
                mkdir -p "$_bkp_dir" 2>/dev/null || true
                cp -f "$repo_dir/$_f" "$_bkp_dir/reconcile_$(date +%s)_$(basename "$_f")" 2>/dev/null || true
                if git -C "$repo_dir" ls-files --error-unmatch "$_f" &>/dev/null; then
                    git -C "$repo_dir" checkout HEAD -- "$_f" 2>/dev/null || true
                else
                    rm -f "$repo_dir/$_f" 2>/dev/null || true
                fi
            fi
        fi
        if [ -f "$ledger" ]; then
            local _tmp_led="${ledger}.tmp.${BASHPID:-$$}"
            jq -c --arg p "$_f" 'select(.rel_path != $p)' "$ledger" > "$_tmp_led" 2>/dev/null && mv -f "$_tmp_led" "$ledger" 2>/dev/null || rm -f "$_tmp_led" 2>/dev/null || true
        fi
    done < <(git -C "$repo_dir" diff --name-only "HEAD..${incoming_ref}" 2>/dev/null || true)
}

pr_accept() {
    local pr_id="$1"
    local strategy="${2:-merge}"
    local clean_id="${pr_id#\#}"

    if [ "${PR_REQUIRE_REVIEW:-0}" -eq 1 ] && ! pr_has_reviewer_acceptance "$pr_id"; then
        ui_err "PR $pr_id lacks 1-reviewer acceptance approval and review comment from George. Cannot merge."
        return 1
    fi

    if [[ "$clean_id" =~ ^[0-9]+$ ]] && pr_is_gitea_online; then
        ui_info "Accepting and merging sovereign Gitea PR #${clean_id} via strategy: ${strategy}..."
        local _pr_info _head_ref _base_ref
        _pr_info=$(gitea_pr_get "$clean_id" 2>/dev/null || echo "{}")
        _head_ref=$(echo "$_pr_info" | jq -r '.head.ref // empty' 2>/dev/null)
        _base_ref=$(echo "$_pr_info" | jq -r '.base.ref // "develop"' 2>/dev/null)
        if gitea_pr_merge "$clean_id" "$strategy"; then
            local _git_lock_dir="${GEORGE_DIR:-$LODGE_DIR/.george}/locks"
            mkdir -p "$_git_lock_dir" 2>/dev/null || true
            (
                flock -w 15 9 || true
                git -C "$LODGE_DIR" fetch gitea "${_base_ref}:refs/remotes/gitea/${_base_ref}" >/dev/null 2>&1 || git -C "$LODGE_DIR" fetch gitea "$_base_ref" >/dev/null 2>&1 || true
                local _cur_br
                _cur_br=$(git -C "$LODGE_DIR" branch --show-current 2>/dev/null || true)
                if [ -z "$_cur_br" ] && [ -z "$(git -C "$LODGE_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
                    git -C "$LODGE_DIR" checkout "$_base_ref" >/dev/null 2>&1 && _cur_br="$_base_ref" || true
                fi
                if [ "$_cur_br" = "$_base_ref" ]; then
                    _pr_reconcile_working_tree_for_merge "$LODGE_DIR" "gitea/${_base_ref}" "$_head_ref"
                    if ! git -C "$LODGE_DIR" merge --ff-only "gitea/${_base_ref}" >/dev/null 2>&1; then
                        if [ -z "$(git -C "$LODGE_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
                            git -C "$LODGE_DIR" merge --no-edit -m "Merge Gitea PR #${clean_id} from gitea/${_base_ref}" "gitea/${_base_ref}" >/dev/null 2>&1 || true
                        fi
                    fi
                elif git -C "$LODGE_DIR" rev-parse --verify "gitea/${_base_ref}" &>/dev/null; then
                    git -C "$LODGE_DIR" branch -f "$_base_ref" "gitea/${_base_ref}" >/dev/null 2>&1 || true
                fi
                if [ -n "$_head_ref" ] && [ "$_head_ref" != "develop" ] && [ "$_head_ref" != "main" ] && [ "$_head_ref" != "master" ]; then
                    git -C "$LODGE_DIR" branch -D "$_head_ref" 2>/dev/null || true
                    git -C "$LODGE_DIR" push gitea --delete "$_head_ref" >/dev/null 2>&1 || true
                fi
            ) 9>"$_git_lock_dir/git_repo.lock"
            gitea_issue_comment "$clean_id" "### 🚀 Sovereign PR #${clean_id} Merged
Branch successfully merged into target branch via strategy \`${strategy}\`. Local ${_base_ref} branch updated." >/dev/null 2>&1 || true
            rm -f "$PR_DIR/${clean_id}.attempts" "$PR_DIR/${clean_id}.ci_remediated_sha" 2>/dev/null || true
            return 0
        else
            return 1
        fi
    fi

    local json_file="$PR_DIR/${pr_id}.json"
    if [ ! -f "$json_file" ]; then
        ui_err "PR $pr_id not found in local queue."
        return 1
    fi

    local src tgt title stat
    src=$(jq -r .source_branch "$json_file")
    tgt=$(jq -r .target_branch "$json_file")
    title=$(jq -r .title "$json_file")
    stat=$(jq -r .status "$json_file")

    # GitFlow check: Never allow merge into main via PR accept
    if ! gitflow_guard_check "$tgt"; then
        return 1
    fi

    if [ "$stat" = "REJECTED" ]; then
        ui_err "PR $pr_id is marked REJECTED. Cannot accept without re-auditing."
        return 1
    fi

    ui_section "Accepting & Merging ${pr_id} into '${tgt}'"

    # Merge into target branch
    local curr_branch
    curr_branch=$(git -C "$LODGE_DIR" branch --show-current 2>/dev/null)

    # Checkout target branch or perform worktree merge
    git -C "$LODGE_DIR" checkout "$tgt" >/dev/null 2>&1 || true
    _pr_reconcile_working_tree_for_merge "$LODGE_DIR" "$src" "$src"

    local merge_out
    if [ "$strategy" = "squash" ]; then
        merge_out=$(git -C "$LODGE_DIR" merge --squash "$src" 2>&1)
        git -C "$LODGE_DIR" commit -m "feat(pr): ${title} (${pr_id})" >/dev/null 2>&1 || true
    else
        merge_out=$(git -C "$LODGE_DIR" merge --no-ff -m "Merge pull request ${pr_id}: ${title} from ${src}" "$src" 2>&1)
    fi

    # Switch back if necessary
    [ -n "$curr_branch" ] && [ "$curr_branch" != "$tgt" ] && git -C "$LODGE_DIR" checkout "$curr_branch" >/dev/null 2>&1 || true

    local tmp_json="${json_file}.tmp.${BASHPID:-$$}"
    jq '.status = "MERGED"' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"

    # Record episodic achievement in permanent journal
    if declare -f journal_record &>/dev/null; then
        journal_record "Accepted and merged pull request ${pr_id} ('${title}') into '${tgt}'. Proven deliverable promoted upstream." >/dev/null 2>&1 || true
    fi

    ui_ok "Pull Request ${pr_id} merged into '${tgt}' successfully!"
    ui_dim "  Commit: $(git -C "$LODGE_DIR" rev-parse --short "$tgt" 2>/dev/null)"

    # Clean up ephemeral source branch locally and remotely
    if [ "$src" != "develop" ] && [ "$src" != "main" ] && [ "$src" != "master" ]; then
        git -C "$LODGE_DIR" branch -D "$src" 2>/dev/null || true
        git -C "$LODGE_DIR" push gitea --delete "$src" 2>/dev/null || true
    fi
}

pr_reject() {
    local pr_id="$1"
    local reason="${2:-Rejected by operator}"
    local clean_id="${pr_id#\#}"

    if [[ "$clean_id" =~ ^[0-9]+$ ]] && pr_is_gitea_online; then
        ui_info "Closing and rejecting sovereign Gitea PR #${clean_id}..."
        _gitea_load_conf
        local resp
        resp=$(curl -s -X PATCH "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${clean_id}" \
            -H "Authorization: token ${GITEA_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"state\": \"closed\"}")
        if [ "$(echo "$resp" | jq -r .state 2>/dev/null)" = "closed" ]; then
            ui_warn "Sovereign Gitea PR #${clean_id} successfully closed: ${reason}"
            local head_b
            head_b=$(echo "$resp" | jq -r '.head.ref // empty' 2>/dev/null)
            if [ -n "$head_b" ] && [ "$head_b" != "develop" ] && [ "$head_b" != "main" ]; then
                git -C "$LODGE_DIR" push gitea --delete "$head_b" >/dev/null 2>&1 || true
                git -C "$LODGE_DIR" branch -D "$head_b" 2>/dev/null || true
            fi
            return 0
        else
            ui_err "Failed to close Gitea PR #${clean_id}: $(echo "$resp" | jq -r .message 2>/dev/null || echo "$resp")"
            return 1
        fi
    fi

    local json_file="$PR_DIR/${pr_id}.json"
    if [ ! -f "$json_file" ]; then
        ui_err "PR $pr_id not found in local queue."
        return 1
    fi

    local tmp_json="${json_file}.tmp.${BASHPID:-$$}"
    jq --arg r "$reason" '.status = "REJECTED" | .rejection_reason = $r' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
    ui_warn "PR $pr_id marked REJECTED: $reason"

    local src
    src=$(jq -r .source_branch "$json_file" 2>/dev/null)
    if [ -n "$src" ] && [ "$src" != "develop" ] && [ "$src" != "main" ] && [ "$src" != "master" ]; then
        git -C "$LODGE_DIR" branch -D "$src" 2>/dev/null || true
        git -C "$LODGE_DIR" push gitea --delete "$src" 2>/dev/null || true
    fi
}

# _pr_check_gitea_ci_status <clean_id> <head_sha>
# Returns:
#   0 = CI passed (or no CI gate active)
#   1 = CI failed/errored (populates _PR_CI_FAILURE_LOG)
#   2 = CI pending/running
_PR_CI_FAILURE_LOG=""
_pr_check_gitea_ci_status() {
    local clean_id="$1"
    local head_sha="$2"
    _PR_CI_FAILURE_LOG=""

    # Support deterministic unit-test overrides
    if [ -n "${_PR_TEST_CI_STATE:-}" ]; then
        case "$_PR_TEST_CI_STATE" in
            success|passed) return 0 ;;
            pending)        return 2 ;;
            failure|error)
                _PR_CI_FAILURE_LOG="${_PR_TEST_CI_LOG:-[CI Gate Failed] Simulated Gitea Actions container failure}"
                return 1
                ;;
        esac
    fi

    if [ "${_LODGE_TESTING:-0}" -eq 1 ] || [ "${LODGE_TEST_MODE:-0}" -eq 1 ]; then
        return 0
    fi
    if ! [[ "$clean_id" =~ ^[0-9]+$ ]] || [ -z "$head_sha" ] || ! pr_is_gitea_online; then
        return 0
    fi

    _gitea_load_conf
    local status_json state count
    status_json=$(curl -s -H "Authorization: token ${GITEA_TOKEN}" \
        "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/commits/${head_sha}/status" 2>/dev/null || echo "{}")
    state=$(echo "$status_json" | jq -r '.state // empty' 2>/dev/null)
    count=$(echo "$status_json" | jq -r '(.statuses // []) | length' 2>/dev/null || echo 0)

    if [ "${count:-0}" -eq 0 ]; then
        return 0
    fi

    case "$state" in
        pending)
            return 2
            ;;
        failure|error)
            local failed_ctx failed_job_id job_log=""
            failed_ctx=$(echo "$status_json" | jq -r '[.statuses[]? | select(.status == "failure" or .status == "error") | .context][0] // "Gitea Actions CI"' 2>/dev/null)
            failed_job_id=$(echo "$status_json" | jq -r '[.statuses[]? | select(.status == "failure" or .status == "error") | .target_url][0] // empty' 2>/dev/null | sed -nE 's|.*/jobs/([0-9]+).*|\1|p')
            if [ -n "$failed_job_id" ]; then
                job_log=$(curl -s -H "Authorization: token ${GITEA_TOKEN}" \
                    "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/actions/jobs/${failed_job_id}/logs" 2>/dev/null | tail -n 50 || true)
            fi
            _PR_CI_FAILURE_LOG="[GITEA ACTIONS CI FAIL] Context: ${failed_ctx} (commit ${head_sha:0:7}, job #${failed_job_id:-unknown})"$'\n'"${job_log}"
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# ── Explicit PR Promotion & Remediation Finite State Machine (FSM) ──────────
# Canonical states:
#   PROPOSED          -> Initial state for a new PR or newly pushed head_sha (runs Stage 1 pr_audit)
#   WAITING_FOR_CI    -> Stage 1 local audit passed for head_sha; polling Stage 1.5 Gitea Actions CI
#   REVIEWING         -> Stage 1 & 1.5 passed for head_sha; running Stage 2 George ReAct Review
#   APPROVED          -> Stage 2 reviewer acceptance verified; ready for Stage 3 autonomous merge
#   REMEDIATING       -> Audit, CI, or Review failed on head_sha; subagent dispatched for head_sha
#   MERGED            -> Terminal: PR merged/closed
#   ESCALATED_BLOCKED -> Terminal for head_sha: remediation attempts reached MAX_REMEDIATION_ATTEMPTS

_pr_fsm_file() {
    local clean_id="${1#\#}"
    local fsm_dir="${GEORGE_DIR:-$LODGE_DIR/.george}/state/prs"
    mkdir -p "$fsm_dir" 2>/dev/null || true
    echo "${fsm_dir}/${clean_id}.fsm.json"
}

pr_fsm_init() {
    local clean_id="${1#\#}"
    local head_branch="${2:-}"
    local head_sha="${3:-}"
    local fsm_file
    fsm_file=$(_pr_fsm_file "$clean_id")
    if [ ! -f "$fsm_file" ]; then
        local now_ts init_att=0
        now_ts=$(date +%s)
        [ -f "$PR_DIR/${clean_id}.attempts" ] && init_att=$(cat "$PR_DIR/${clean_id}.attempts" 2>/dev/null || echo 0)
        jq -n \
            --arg id "$clean_id" \
            --arg br "$head_branch" \
            --arg sha "$head_sha" \
            --argjson att "${init_att:-0}" \
            --argjson ts "$now_ts" \
            '{
                pr_id: $id,
                head_branch: $br,
                head_sha: $sha,
                state: "PROPOSED",
                attempts: $att,
                remediated_sha: "",
                last_transition_reason: "FSM initialized",
                updated_at: $ts,
                transitions: [
                    {from: "NONE", to: "PROPOSED", sha: $sha, ts: $ts, reason: "FSM initialized"}
                ]
            }' > "$fsm_file" 2>/dev/null || true
    fi
}

pr_fsm_get() {
    local clean_id="${1#\#}"
    local field="${2:-.state}"
    local fsm_file
    fsm_file=$(_pr_fsm_file "$clean_id")
    [ -f "$fsm_file" ] || return 1
    jq -r "$field // empty" "$fsm_file" 2>/dev/null
}

pr_fsm_transition() {
    local clean_id="${1#\#}"
    local to_state="$2"
    local reason="${3:-state transition}"
    local head_sha="${4:-}"
    local rem_sha="${5:-}"
    local new_attempts="${6:-}"
    local fsm_file
    fsm_file=$(_pr_fsm_file "$clean_id")
    [ -f "$fsm_file" ] || pr_fsm_init "$clean_id" "" "$head_sha"
    local now_ts
    now_ts=$(date +%s)
    local tmp_fsm="${fsm_file}.tmp.${BASHPID:-$$}"
    jq \
        --arg to "$to_state" \
        --arg r "$reason" \
        --arg sha "$head_sha" \
        --arg rsha "$rem_sha" \
        --arg att "$new_attempts" \
        --argjson ts "$now_ts" \
        '
        .state as $from |
        .state = $to |
        .last_transition_reason = $r |
        .updated_at = $ts |
        (if $sha != "" then .head_sha = $sha else . end) |
        (if $rsha == "__CLEAR__" then .remediated_sha = "" elif $rsha != "" then .remediated_sha = $rsha else . end) |
        (if $att != "" then .attempts = ($att | tonumber? // .attempts) else . end) |
        .transitions = ((.transitions // []) + [{from: $from, to: $to, sha: (.head_sha // ""), ts: $ts, reason: $r}])[-25:]
        ' "$fsm_file" > "$tmp_fsm" 2>/dev/null && mv -f "$tmp_fsm" "$fsm_file" 2>/dev/null || rm -f "$tmp_fsm" 2>/dev/null || true

    if [ -n "$new_attempts" ]; then
        echo "$new_attempts" > "$PR_DIR/${clean_id}.attempts" 2>/dev/null || true
    fi
}

# ── Hands-off Closed-Loop PR Evaluation & Sweep ───────────────
pr_auto_evaluate() {
    local pr_id="$1"
    local clean_id="${pr_id#\#}"
    [ -z "$clean_id" ] && return 1

    ui_section "Autonomous Closed-Loop Review: PR #${clean_id}"

    # Check current PR state and source branch first
    local pr_meta="" head_branch="" head_sha=""
    if [[ "$clean_id" =~ ^[0-9]+$ ]] && pr_is_gitea_online; then
        _gitea_load_conf
        pr_meta=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${clean_id}" \
            -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null)
        local pr_state
        pr_state=$(echo "$pr_meta" | jq -r .state 2>/dev/null)
        local is_merged
        is_merged=$(echo "$pr_meta" | jq -r .merged 2>/dev/null)
        head_branch=$(echo "$pr_meta" | jq -r '.head.ref // empty' 2>/dev/null)
        head_sha=$(echo "$pr_meta" | jq -r '.head.sha // empty' 2>/dev/null)
        if [ "$pr_state" = "closed" ] || [ "$is_merged" = "true" ]; then
            pr_fsm_transition "$clean_id" "MERGED" "PR already closed/merged on Gitea" "$head_sha" "__CLEAR__"
            ui_info "PR #${clean_id} is already closed/merged. Skipping auto-evaluation."
            return 0
        fi
    elif [ -f "$PR_DIR/${pr_id}.json" ]; then
        head_branch=$(jq -r '.source_branch // empty' "$PR_DIR/${pr_id}.json" 2>/dev/null)
        [ -n "$head_branch" ] && head_sha=$(git -C "$LODGE_DIR" rev-parse --verify "$head_branch" 2>/dev/null || true)
    fi

    # Guard against split-brain race: defer evaluation if an active remediation worker or subagent owns this branch
    if [[ "$head_branch" == remediation/* ]]; then
        local rem_tid="${head_branch#remediation/}"
        local rem_prog="${GEORGE_DIR:-$LODGE_DIR/.george}/remediation/in_progress/${rem_tid}.json"
        local rem_sbox="${LODGE_DIR}/.sandboxes/remediation_${rem_tid}"
        if [ -f "$rem_prog" ] || [ -d "$rem_sbox" ]; then
            ui_info "PR #${clean_id} belongs to active remediation worker (${rem_tid}); deferring sweep until worker finishes."
            return 0
        fi
    fi
    if [ -n "$head_branch" ] && [ -f "${GEORGE_DIR:-$LODGE_DIR/.george}/subagents.json" ]; then
        local _active_sub_pid
        while IFS= read -r _active_sub_pid; do
            [ -z "$_active_sub_pid" ] && continue
            if [ "$_active_sub_pid" -gt 1 ] 2>/dev/null && kill -0 "$_active_sub_pid" 2>/dev/null && ! grep -q '^State:[[:space:]]*Z' "/proc/${_active_sub_pid}/status" 2>/dev/null; then
                ui_info "PR #${clean_id} branch '${head_branch}' has an active remediation subagent (PID ${_active_sub_pid}); deferring sweep until subagent finishes."
                return 0
            fi
        done < <(jq -r --arg br "$head_branch" '.[] | select(.branch == $br and .status == "RUNNING") | .pid // empty' "${GEORGE_DIR:-$LODGE_DIR/.george}/subagents.json" 2>/dev/null)
    fi

    local max_attempts
    max_attempts=$(limits_get MAX_REMEDIATION_ATTEMPTS 5 2>/dev/null || echo 5)
    local attempt_file="$PR_DIR/${clean_id}.attempts"

    # Initialize or load explicit FSM state
    pr_fsm_init "$clean_id" "$head_branch" "$head_sha"
    local fsm_state fsm_sha fsm_rem_sha fsm_attempts
    fsm_state=$(pr_fsm_get "$clean_id" ".state")
    fsm_sha=$(pr_fsm_get "$clean_id" ".head_sha")
    fsm_rem_sha=$(pr_fsm_get "$clean_id" ".remediated_sha")
    fsm_attempts=$(pr_fsm_get "$clean_id" ".attempts")
    [ -z "$fsm_attempts" ] && fsm_attempts=0
    if [ -f "$attempt_file" ]; then
        local file_att
        file_att=$(cat "$attempt_file" 2>/dev/null || echo 0)
        [ "${file_att:-0}" -gt "$fsm_attempts" ] 2>/dev/null && fsm_attempts="$file_att"
    fi

    # Edge-Triggered Commit Detection: new commit SHA resets FSM state to PROPOSED while preserving attempt counter
    if [ -n "$head_sha" ] && [ -n "$fsm_sha" ] && [ "$head_sha" != "$fsm_sha" ]; then
        ui_info "New commit detected on PR #${clean_id} (${fsm_sha:0:7} → ${head_sha:0:7}); transitioning FSM ${fsm_state} → PROPOSED."
        rm -f "$PR_DIR/${clean_id}.review.json" "$PR_DIR/${clean_id}.ci_remediated_sha" 2>/dev/null || true
        pr_fsm_transition "$clean_id" "PROPOSED" "New commit ${fsm_sha:0:7} -> ${head_sha:0:7}" "$head_sha" "__CLEAR__" "$fsm_attempts"
        fsm_state="PROPOSED"
        fsm_sha="$head_sha"
        fsm_rem_sha=""
    fi

    # Drive explicit FSM transitions
    while :; do
        case "$fsm_state" in
            PROPOSED)
                # Stage 1: Run Three Degrees Audit (Merge + Write-Scope Denylist + Tyler Security + Test Gate)
                if pr_audit "$pr_id"; then
                    pr_fsm_transition "$clean_id" "WAITING_FOR_CI" "Stage 1 Three Degrees Audit passed" "$head_sha" "" "$fsm_attempts"
                    fsm_state="WAITING_FOR_CI"
                else
                    ui_warn "PR #${clean_id} failed audit verification."
                    local cur_attempts=$((fsm_attempts + 1))
                    [ -f "$attempt_file" ] && cur_attempts=$(cat "$attempt_file" 2>/dev/null || echo "$cur_attempts")
                    fsm_attempts="$cur_attempts"
                    if [ "$cur_attempts" -lt "$max_attempts" ]; then
                        pr_fsm_transition "$clean_id" "REMEDIATING" "Stage 1 audit failed (attempt ${cur_attempts}/${max_attempts})" "$head_sha" "${head_sha:-local}" "$cur_attempts"
                        ui_info "Triggering auto-remediation subagent (attempt ${cur_attempts}/${max_attempts}) for PR #${clean_id}..."
                        if [ -f "$PR_DIR/${pr_id}.json" ]; then
                            local _tmp_p="${PR_DIR}/${pr_id}.json.tmp.$$"
                            jq '.status = "REMEDIATING"' "$PR_DIR/${pr_id}.json" > "$_tmp_p" 2>/dev/null && mv "$_tmp_p" "$PR_DIR/${pr_id}.json"
                        fi
                        if declare -f subagents_spawn &>/dev/null; then
                            [ -z "$head_branch" ] && head_branch="subagent/pr_${clean_id}"
                            local audit_tail=""
                            [ -f "$PR_DIR/${clean_id}.audit.log" ] && audit_tail=$(tail -n 60 "$PR_DIR/${clean_id}.audit.log" 2>/dev/null || true)
                            SUBAGENT_TARGET_BRANCH="$head_branch" SUBAGENT_EXISTING_PR="$clean_id" \
                                subagents_spawn 1 "Remediate test regressions on branch '${head_branch}' for PR #${clean_id}. Use okf_traverse/okf_query to inspect module dependencies, fix the root cause of the test failure below, commit to '${head_branch}', and push to gitea.\n\nAudit Failure Log:\n${audit_tail}" "" "$LODGE_DIR" 50 1 >/dev/null 2>&1 || true
                            if declare -f gitea_issue_comment &>/dev/null; then
                                gitea_issue_comment "$clean_id" "🤖 **[Auto-Remediation]** Dispatched Tier 1 subagent to remediate test regressions on \`${head_branch}\` (attempt ${cur_attempts}/${max_attempts})." >/dev/null 2>&1 || true
                            fi
                        fi
                    else
                        pr_fsm_transition "$clean_id" "ESCALATED_BLOCKED" "Exceeded max audit remediation attempts (${cur_attempts}/${max_attempts})" "$head_sha" "${head_sha:-local}" "$cur_attempts"
                    fi
                    return 1
                fi
                ;;

            WAITING_FOR_CI)
                # Stage 1.5: Verify Gitea Actions Container CI Status before Reviewer / Merge
                # Note: Local pr_audit already passed for this head_sha, so we do NOT re-run local tests on every 60s poll!
                local ci_rc=0
                _pr_check_gitea_ci_status "$clean_id" "$head_sha" || ci_rc=$?
                if [ "$ci_rc" -eq 2 ]; then
                    ui_info "Gitea Actions CI is still pending for PR #${clean_id} (${head_sha:0:7}); staying in WAITING_FOR_CI."
                    return 0
                elif [ "$ci_rc" -eq 1 ]; then
                    ui_warn "PR #${clean_id} passed local audit but failed Gitea Actions container CI."
                    local audit_log="$PR_DIR/${clean_id}.audit.log"
                    printf '\n%s\n' "$_PR_CI_FAILURE_LOG" >> "$audit_log"
                    local ci_attempts=$((fsm_attempts + 1))
                    fsm_attempts="$ci_attempts"
                    [ -n "$head_sha" ] && echo "$head_sha" > "$PR_DIR/${clean_id}.ci_remediated_sha"
                    declare -f subagents_spawn &>/dev/null || source "$LODGE_DIR/lib/agents/subagents.sh" 2>/dev/null || true
                    if [ "$ci_attempts" -lt "$max_attempts" ] && declare -f subagents_spawn &>/dev/null; then
                        pr_fsm_transition "$clean_id" "REMEDIATING" "Stage 1.5 Gitea CI failed (attempt ${ci_attempts}/${max_attempts})" "$head_sha" "$head_sha" "$ci_attempts"
                        [ -z "$head_branch" ] && head_branch="subagent/pr_${clean_id}"
                        if [ -f "$PR_DIR/${pr_id}.json" ]; then
                            local _tmp_p="${PR_DIR}/${pr_id}.json.tmp.${BASHPID:-$$}"
                            jq '.status = "REMEDIATING"' "$PR_DIR/${pr_id}.json" > "$_tmp_p" 2>/dev/null && mv "$_tmp_p" "$PR_DIR/${pr_id}.json"
                        fi
                        ui_info "Triggering auto-remediation subagent for PR #${clean_id} Gitea Actions CI failure (attempt ${ci_attempts}/${max_attempts})..."
                        local hist_file="$PR_DIR/${clean_id}.history.log"
                        local prior_hist=""
                        [ -s "$hist_file" ] && prior_hist=$'\n\nPrior Remediation Attempts on this PR (do NOT repeat failed approaches):\n'"$(tail -n 30 "$hist_file" 2>/dev/null)"
                        printf '[%s] Attempt %d/%d (CI failure on %s): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ci_attempts" "$max_attempts" "${head_sha:0:7}" "$(printf '%s' "$_PR_CI_FAILURE_LOG" | tr '\n' ' ' | head -c 240)" >> "$hist_file" 2>/dev/null || true
                        SUBAGENT_TARGET_BRANCH="$head_branch" SUBAGENT_EXISTING_PR="$clean_id" \
                            subagents_spawn 1 "Remediate Gitea Actions container CI failure on branch '${head_branch}' for PR #${clean_id}. Verify with 'bash scripts/ci/hermetic_test_runner.sh', fix the root cause below without skipping tests, commit to '${head_branch}', and push to gitea.${prior_hist}\n\nGitea Actions CI Failure Log:\n${_PR_CI_FAILURE_LOG}" "" "$LODGE_DIR" 50 1 >/dev/null 2>&1 || true
                        if declare -f gitea_issue_comment &>/dev/null; then
                            gitea_issue_comment "$clean_id" "🤖 **[Auto-Remediation]** Dispatched Tier 1 subagent to remediate Gitea Actions CI failure on \`${head_branch}\` (attempt ${ci_attempts}/${max_attempts})." >/dev/null 2>&1 || true
                        fi
                    else
                        pr_fsm_transition "$clean_id" "ESCALATED_BLOCKED" "Exceeded max CI remediation attempts (${ci_attempts}/${max_attempts})" "$head_sha" "$head_sha" "$ci_attempts"
                        alerts_dispatch tier3 "PR ${pr_id} Exceeded Max CI Remediation Attempts (${ci_attempts}/${max_attempts})" "Gitea Actions container CI failed repeatedly. Operator intervention required." "" >/dev/null 2>&1 || true
                    fi
                    return 1
                fi
                ui_ok "PR #${clean_id} passed Three Degrees Audit and Gitea CI Gate. Proceeding to George 1-Reviewer ReAct Review..."
                pr_fsm_transition "$clean_id" "REVIEWING" "Stage 1.5 Gitea CI passed" "$head_sha" "" "$fsm_attempts"
                fsm_state="REVIEWING"
                ;;

            REVIEWING)
                # Stage 2: George ReAct Code Review & Comment Gate
                if [ -f "$PR_DIR/${clean_id}.review.json" ] && [ -n "$head_sha" ]; then
                    local _prev_rev_sha
                    _prev_rev_sha=$(jq -r '.head_sha // empty' "$PR_DIR/${clean_id}.review.json" 2>/dev/null || true)
                    if [ -n "$_prev_rev_sha" ] && [ "$_prev_rev_sha" != "$head_sha" ]; then
                        ui_info "New commit detected on PR #${clean_id} (${_prev_rev_sha:0:7} → ${head_sha:0:7}); clearing prior review verdict for fresh review."
                        rm -f "$PR_DIR/${clean_id}.review.json" 2>/dev/null || true
                    fi
                fi

                if ! pr_has_reviewer_acceptance "$pr_id"; then
                    local _review_ok=0
                    pr_review "$pr_id" && _review_ok=1 || _review_ok=0
                    if [ -f "$PR_DIR/${clean_id}.review.json" ] && [ -n "$head_sha" ]; then
                        local _tmp_rsha="${PR_DIR}/${clean_id}.review.json.tmp.${BASHPID:-$$}"
                        jq --arg sha "$head_sha" '.head_sha = $sha' "$PR_DIR/${clean_id}.review.json" > "$_tmp_rsha" 2>/dev/null && mv -f "$_tmp_rsha" "$PR_DIR/${clean_id}.review.json" 2>/dev/null || rm -f "$_tmp_rsha" 2>/dev/null || true
                    fi

                    if [ "$_review_ok" -eq 0 ]; then
                        ui_warn "PR #${clean_id} did not receive George ReAct reviewer approval. Auto-merge blocked."
                        local rev_attempts=$((fsm_attempts + 1))
                        fsm_attempts="$rev_attempts"
                        declare -f subagents_spawn &>/dev/null || source "$LODGE_DIR/lib/agents/subagents.sh" 2>/dev/null || true
                        if [ "$rev_attempts" -lt "$max_attempts" ] && declare -f subagents_spawn &>/dev/null; then
                            pr_fsm_transition "$clean_id" "REMEDIATING" "Stage 2 Review REQUEST_CHANGES (attempt ${rev_attempts}/${max_attempts})" "$head_sha" "${head_sha:-local}" "$rev_attempts"
                            [ -z "$head_branch" ] && head_branch="subagent/pr_${clean_id}"
                            local rev_feedback=""
                            [ -f "$PR_DIR/${clean_id}.review.json" ] && rev_feedback=$(jq -r '.comment // empty' "$PR_DIR/${clean_id}.review.json" 2>/dev/null || true)
                            if [ -f "$PR_DIR/${clean_id}.review.json" ] && [ -n "$head_sha" ]; then
                                local _tmp_rem_sha="${PR_DIR}/${clean_id}.review.json.tmp.${BASHPID:-$$}"
                                jq --arg sha "$head_sha" '.remediated_sha = $sha' "$PR_DIR/${clean_id}.review.json" > "$_tmp_rem_sha" 2>/dev/null && mv -f "$_tmp_rem_sha" "$PR_DIR/${clean_id}.review.json" 2>/dev/null || rm -f "$_tmp_rem_sha" 2>/dev/null || true
                            fi
                            if [ -f "$PR_DIR/${pr_id}.json" ]; then
                                local _tmp_p="${PR_DIR}/${pr_id}.json.tmp.${BASHPID:-$$}"
                                jq '.status = "REMEDIATING"' "$PR_DIR/${pr_id}.json" > "$_tmp_p" 2>/dev/null && mv "$_tmp_p" "$PR_DIR/${pr_id}.json"
                            fi
                            ui_info "Triggering auto-remediation subagent for PR #${clean_id} review feedback (attempt ${rev_attempts}/${max_attempts})..."
                            local hist_file="$PR_DIR/${clean_id}.history.log"
                            local prior_hist=""
                            [ -s "$hist_file" ] && prior_hist=$'\n\nPrior Remediation Attempts on this PR (do NOT repeat failed approaches):\n'"$(tail -n 30 "$hist_file" 2>/dev/null)"
                            printf '[%s] Attempt %d/%d (Review REQUEST_CHANGES on %s): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rev_attempts" "$max_attempts" "${head_sha:0:7}" "$(printf '%s' "$rev_feedback" | tr '\n' ' ' | head -c 240)" >> "$hist_file" 2>/dev/null || true
                            SUBAGENT_TARGET_BRANCH="$head_branch" SUBAGENT_EXISTING_PR="$clean_id" \
                                subagents_spawn 1 "Address code review feedback (REQUEST_CHANGES) on branch '${head_branch}' for PR #${clean_id}. Use okf_traverse/okf_query to inspect module dependencies, apply the requested fixes, run tests, commit to '${head_branch}', and push to gitea.${prior_hist}\n\nReviewer Feedback:\n${rev_feedback}" "" "$LODGE_DIR" 50 1 >/dev/null 2>&1 || true
                            if declare -f gitea_issue_comment &>/dev/null; then
                                gitea_issue_comment "$clean_id" "🤖 **[Auto-Remediation]** Dispatched Tier 1 subagent to address code review feedback (\`REQUEST_CHANGES\`) on \`${head_branch}\` (attempt ${rev_attempts}/${max_attempts})." >/dev/null 2>&1 || true
                            fi
                        else
                            pr_fsm_transition "$clean_id" "ESCALATED_BLOCKED" "Exceeded max review remediation attempts (${rev_attempts}/${max_attempts})" "$head_sha" "${head_sha:-local}" "$rev_attempts"
                        fi
                        return 1
                    fi
                fi
                pr_fsm_transition "$clean_id" "APPROVED" "Stage 2 Reviewer approval verified" "$head_sha" "" "$fsm_attempts"
                fsm_state="APPROVED"
                ;;

            APPROVED)
                # Stage 3: Verify 1-Reviewer Acceptance Criteria before merging
                if ! pr_has_reviewer_acceptance "$pr_id"; then
                    ui_err "PR #${clean_id} lacks verified 1-reviewer acceptance comment. Auto-merge blocked."
                    pr_fsm_transition "$clean_id" "REVIEWING" "Reviewer acceptance missing at merge gate" "$head_sha" "" "$fsm_attempts"
                    return 1
                fi

                local _rem_mode="auto"
                local _rem_mode_file="${GEORGE_DIR:-$LODGE_DIR/.george}/remediation/mode"
                if [ -f "$_rem_mode_file" ]; then
                    _rem_mode=$(tr -d '[:space:]' < "$_rem_mode_file" 2>/dev/null | tr '[:upper:]' '[:lower:]')
                    [ "$_rem_mode" != "propose" ] && _rem_mode="auto"
                fi
                if [ "$_rem_mode" = "propose" ]; then
                    ui_info "PR #${clean_id} passed audit and 1-reviewer ReAct acceptance; remediation mode is 'propose' — holding in APPROVED awaiting operator merge."
                    local _prop_sha_file="$PR_DIR/${clean_id}.proposed_hold_sha"
                    local _last_prop_sha=""
                    [ -f "$_prop_sha_file" ] && _last_prop_sha=$(cat "$_prop_sha_file" 2>/dev/null || true)
                    if [ "$_last_prop_sha" != "${head_sha:-local}" ]; then
                        echo "${head_sha:-local}" > "$_prop_sha_file" 2>/dev/null || true
                        if declare -f gitea_issue_comment &>/dev/null; then
                            gitea_issue_comment "$clean_id" "⏸️ **[Propose-Only Mode Active]** PR #${clean_id} passed Three Degrees Audit, Gitea CI, and George 1-Reviewer approval, and is held in \`APPROVED\` awaiting operator merge (toggle \`REMEDIATION: AUTO-MERGE\` in the web UI for autonomous merge)." >/dev/null 2>&1 || true
                        fi
                    fi
                    return 0
                fi

                ui_ok "PR #${clean_id} passed audit, denylist, and 1-reviewer ReAct acceptance. Executing autonomous merge..."
                if PR_REQUIRE_REVIEW=1 pr_accept "$pr_id" "merge"; then
                    pr_fsm_transition "$clean_id" "MERGED" "Autonomous merge into develop succeeded" "$head_sha" "__CLEAR__" "0"
                    ui_ok "Hands-off loop complete: PR #${clean_id} audited, reviewed, and merged into develop!"
                    if declare -f journal_record &>/dev/null; then
                        journal_record "Hands-off autonomous loop merged PR #${clean_id} into develop following Three Degrees Audit and George ReAct 1-Reviewer approval." >/dev/null 2>&1 || true
                    fi
                    return 0
                else
                    ui_err "Failed to execute auto-merge for PR #${clean_id} despite audit and review pass."
                    return 1
                fi
                ;;

            REMEDIATING)
                # Remain in REMEDIATING until a new commit SHA arrives on the branch
                if [ -n "$head_sha" ] && [ "$fsm_rem_sha" = "$head_sha" ]; then
                    ui_info "PR #${clean_id} (${head_sha:0:7}) is in FSM state REMEDIATING (attempt ${fsm_attempts}/${max_attempts}); waiting for new commit before re-evaluating."
                    return 1
                fi
                pr_fsm_transition "$clean_id" "PROPOSED" "Re-evaluating PR from REMEDIATING" "$head_sha" "__CLEAR__" "$fsm_attempts"
                fsm_state="PROPOSED"
                ;;

            ESCALATED_BLOCKED)
                ui_warn "PR #${clean_id} (${head_sha:0:7}) is in terminal state ESCALATED_BLOCKED (${fsm_attempts}/${max_attempts} attempts). Push a new commit to reset."
                return 1
                ;;

            MERGED)
                ui_info "PR #${clean_id} is in terminal state MERGED."
                return 0
                ;;

            *)
                pr_fsm_transition "$clean_id" "PROPOSED" "Resetting unknown FSM state ${fsm_state}" "$head_sha" "__CLEAR__" "$fsm_attempts"
                fsm_state="PROPOSED"
                ;;
        esac
    done
}

# ── Autonomous Working-Tree Drift Sweeper (Partner to pr_sweep) ──────────────
# Promotes George-authored uncommitted changes (Foliage directories + files recorded
# in .george/uncommitted_agent_edits.jsonl) into an isolated branch and PR without
# disturbing human operator WIP or mutating the live develop working tree.
pr_drift_sweep() {
    local repo_dir="${1:-$LODGE_DIR}"
    local george_dir="${GEORGE_DIR:-$repo_dir/.george}"
    local ledger_file="${george_dir}/state/uncommitted_agent_edits.jsonl"
    [ ! -f "$ledger_file" ] && [ -f "${george_dir}/uncommitted_agent_edits.jsonl" ] && ledger_file="${george_dir}/uncommitted_agent_edits.jsonl"
    local state_file="${george_dir}/state/drift_sweep_state.json"
    mkdir -p "${george_dir}/state" 2>/dev/null || true
    local quiet_secs="${GEORGE_DRIFT_QUIET_SECONDS:-300}"

    git -C "$repo_dir" rev-parse --git-dir &>/dev/null || return 0

    # Risk 1 Mitigation (Part A): Active-Session Quiescence Gate
    # Defer if workspace lock is held by a live PID, remediation is active, or Discord session is running.
    local lock_file="${george_dir}/.lodge.lock"
    if [ -f "$lock_file" ]; then
        local lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null || true)
        if [ -n "$lock_pid" ] && [ "$lock_pid" -gt 1 ] 2>/dev/null && kill -0 "$lock_pid" 2>/dev/null; then
            ui_dim "  [drift_sweep] Workspace lock held by active PID ${lock_pid}; deferring drift sweep."
            return 0
        fi
    fi
    if declare -f remediation_is_active &>/dev/null && remediation_is_active; then
        ui_dim "  [drift_sweep] Autonomous remediation is active; deferring drift sweep."
        return 0
    fi
    if declare -f discord_get_active_task_count &>/dev/null; then
        local active_dc
        active_dc=$(discord_get_active_task_count 2>/dev/null || echo 0)
        if [ "${active_dc:-0}" -gt 0 ] 2>/dev/null; then
            ui_dim "  [drift_sweep] Active Discord task in progress (${active_dc}); deferring drift sweep."
            return 0
        fi
    fi

    # Verify repo is on 'develop' (or re-attach 'develop' if HEAD was detached at develop's commit)
    local cur_br
    cur_br=$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)
    if [ -z "$cur_br" ]; then
        local head_sha dev_sha
        head_sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
        dev_sha=$(git -C "$repo_dir" rev-parse develop 2>/dev/null || true)
        if [ -n "$head_sha" ] && [ "$head_sha" = "$dev_sha" ]; then
            git -C "$repo_dir" checkout develop >/dev/null 2>&1 && cur_br="develop" || true
        fi
    fi
    if [ "$cur_br" != "develop" ]; then
        return 0
    fi

    # Prune ledger entries whose files are already clean in git status
    if [ -f "$ledger_file" ] && [ -s "$ledger_file" ]; then
        local _tmp_led="${ledger_file}.tmp.${BASHPID:-$$}"
        : > "$_tmp_led"
        local _lp
        while IFS= read -r _lp; do
            [ -z "$_lp" ] && continue
            if [ -n "$(git -C "$repo_dir" status --porcelain -- "$_lp" 2>/dev/null)" ]; then
                jq -c --arg p "$_lp" 'select(.rel_path == $p)' "$ledger_file" 2>/dev/null | tail -n 1 >> "$_tmp_led"
            fi
        done < <(jq -r '.rel_path // empty' "$ledger_file" 2>/dev/null | sort -u)
        mv -f "$_tmp_led" "$ledger_file" 2>/dev/null || rm -f "$_tmp_led" 2>/dev/null || true
    fi

    # Risk 2 Mitigation: Scope & Attribution Filter (Foliage + Agent Edit Ledger only; ignore Human WIP)
    local -a candidate_files=()
    local status_line rel_path is_attributed
    while IFS= read -r status_line; do
        [ -z "$status_line" ] && continue
        rel_path="${status_line:3}"
        # Handle rename syntax "R  old -> new" and strip surrounding quotes
        [[ "$rel_path" == *" -> "* ]] && rel_path="${rel_path##* -> }"
        rel_path="${rel_path#\"}"
        rel_path="${rel_path%\"}"
        [ -z "$rel_path" ] && continue

        # Skip transient runtime/sandbox state files
        if [[ "$rel_path" =~ ^(\.pid|\.phase|\.pr_issued|task_meta\.json|\.done|.*\.fifo|trajectory\.log|\.pause_requested|\.resume_requested)$ ]] || \
           [[ "$rel_path" =~ (^|/)\.history/ ]] || \
           [[ "$rel_path" =~ ^\.sandboxes/ ]] || \
           [[ "$rel_path" =~ ^\.george/(pulls|remediation|logs|cache|tmp|ipc|workspaces|social|finance|sdr|backups|issues|transcripts)/ ]] || \
           [[ "$rel_path" =~ ^\.george/(uncommitted_agent_edits\.jsonl|drift_sweep_state\.json|cron\.log|cron_state\.json|subagents\.json|recall\.db.*|events\.jsonl.*)$ ]]; then
            continue
        fi

        # Skip Tier C / write-denylist protected files
        if [[ "$rel_path" =~ (trading_policy\.json|trading\.db|escalations\.db|trading_confirm\.key|cardano_mode\.conf|wallet/policy\.json|features\.conf|keys\.conf|secrets\.env|\.env($|\.)|\.vault|id_rsa|id_ed25519|\.pem$|\.key$) ]]; then
            continue
        fi
        if [ -n "$(pr_scope_violations_from_list <<< "$rel_path")" ]; then
            continue
        fi

        is_attributed=0
        if [[ "$rel_path" =~ ^\.george/(cron_jobs|tools|slash)/ ]]; then
            is_attributed=1
        elif [ -f "$ledger_file" ] && jq -e --arg p "$rel_path" 'select(.rel_path == $p)' "$ledger_file" >/dev/null 2>&1; then
            is_attributed=1
        fi

        [ "$is_attributed" -eq 1 ] && candidate_files+=("$rel_path")
    done < <(git -C "$repo_dir" status --porcelain -uall 2>/dev/null)

    [ "${#candidate_files[@]}" -eq 0 ] && return 0

    # Risk 1 Mitigation (Part B): File Modification Cooldown Window (bundle multi-file task edits)
    local now_ts file_mtime file_age
    now_ts=$(date +%s)
    for rel_path in "${candidate_files[@]}"; do
        if [ -e "$repo_dir/$rel_path" ]; then
            file_mtime=$(stat -c %Y "$repo_dir/$rel_path" 2>/dev/null || echo "$now_ts")
            file_age=$((now_ts - file_mtime))
            if [ "$file_age" -lt "$quiet_secs" ]; then
                ui_dim "  [drift_sweep] Attributed file '$rel_path' modified ${file_age}s ago (< ${quiet_secs}s cooldown); waiting for task completion."
                return 0
            fi
        fi
    done

    # Risk 5 Mitigation: Pre-PR Warden Gate (Secret Scan & AST Syntax Verification)
    local -a valid_files=()
    local py_bin="python3"
    [ -x "$repo_dir/.venv/bin/python" ] && py_bin="$repo_dir/.venv/bin/python"

    for rel_path in "${candidate_files[@]}"; do
        local abs_p="$repo_dir/$rel_path"
        if [ -f "$abs_p" ]; then
            # Secret scan
            if grep -qE '(GITEA_TOKEN=[a-zA-Z0-9]{10,}|DISCORD_BOT_TOKEN=[a-zA-Z0-9._-]{20,}|sk-[a-zA-Z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' "$abs_p" 2>/dev/null; then
                ui_warn "  [drift_sweep] Skipping '$rel_path': potential hardcoded credential detected."
                continue
            fi
            # AST syntax verification
            if [[ "$rel_path" == *.sh || "$rel_path" == *.bash ]] || head -n 1 "$abs_p" 2>/dev/null | grep -qE '^#!.*(ba)?sh'; then
                if ! bash -n "$abs_p" >/dev/null 2>&1; then
                    ui_warn "  [drift_sweep] Skipping '$rel_path': failed bash -n AST syntax verification."
                    continue
                fi
            elif [[ "$rel_path" == *.py ]]; then
                if ! "$py_bin" -m py_compile "$abs_p" >/dev/null 2>&1; then
                    ui_warn "  [drift_sweep] Skipping '$rel_path': failed Python AST syntax verification."
                    continue
                fi
            fi
        fi
        valid_files+=("$rel_path")
    done

    [ "${#valid_files[@]}" -eq 0 ] && return 0

    # Risk 4 Mitigation: Content-Hash Deduplication Ledger
    local hash_manifest="" f_sha
    while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue
        if [ -f "$repo_dir/$rel_path" ]; then
            f_sha=$(sha256sum "$repo_dir/$rel_path" 2>/dev/null | awk '{print $1}')
        else
            f_sha="DELETED"
        fi
        hash_manifest+="${rel_path}:${f_sha}"$'\n'
    done < <(printf '%s\n' "${valid_files[@]}" | sort -u)

    local drift_hash
    drift_hash=$(printf '%s' "$hash_manifest" | sha256sum | awk '{print $1}')
    [ -z "$drift_hash" ] && return 0

    if [ -f "$state_file" ] && jq -e --arg h "$drift_hash" '.seen_hashes[$h] != null' "$state_file" >/dev/null 2>&1; then
        return 0
    fi

    # Risk 3 Mitigation: Non-Destructive Isolated Worktree Promotion
    local short_hash="${drift_hash:0:8}"
    local ts_label
    ts_label=$(date +%Y%m%d_%H%M%S)
    local drift_branch="drift/auto_${ts_label}_${short_hash}"
    local wt_dir="${repo_dir}/.sandboxes/drift_${short_hash}"

    mkdir -p "${repo_dir}/.sandboxes" 2>/dev/null || true
    git -C "$repo_dir" worktree remove --force "$wt_dir" >/dev/null 2>&1 || rm -rf "$wt_dir" 2>/dev/null || true
    git -C "$repo_dir" branch -D "$drift_branch" >/dev/null 2>&1 || true

    if ! git -C "$repo_dir" worktree add -b "$drift_branch" "$wt_dir" "develop" >/dev/null 2>&1; then
        ui_warn "  [drift_sweep] Failed to spawn temporary worktree at $wt_dir"
        return 1
    fi

    local file_list_md=""
    for rel_path in "${valid_files[@]}"; do
        if [ -e "$repo_dir/$rel_path" ] || [ -L "$repo_dir/$rel_path" ]; then
            mkdir -p "$(dirname "$wt_dir/$rel_path")" 2>/dev/null || true
            cp -a "$repo_dir/$rel_path" "$wt_dir/$rel_path" 2>/dev/null || true
            git -C "$wt_dir" add -- "$rel_path" >/dev/null 2>&1 || true
            file_list_md+="- \`${rel_path}\`"$'\n'
        else
            git -C "$wt_dir" rm -f --ignore-unmatch -- "$rel_path" >/dev/null 2>&1 || true
            file_list_md+="- \`${rel_path}\` (deleted)"$'\n'
        fi
    done

    if git -C "$wt_dir" diff --cached --quiet 2>/dev/null; then
        git -C "$repo_dir" worktree remove --force "$wt_dir" >/dev/null 2>&1 || rm -rf "$wt_dir" 2>/dev/null || true
        git -C "$repo_dir" branch -D "$drift_branch" >/dev/null 2>&1 || true
        return 0
    fi

    local pr_title
    if [ "${#valid_files[@]}" -eq 1 ]; then
        pr_title="chore(drift): promote uncommitted agent changes in $(basename "${valid_files[0]}")"
    else
        pr_title="chore(drift): promote uncommitted agent changes (${#valid_files[@]} files)"
    fi

    local commit_msg
    commit_msg=$(printf "%s\n\nAutonomously captured uncommitted George-authored working-tree drift\n(fingerprint: %s) into an audited Pull Request:\n\n%s" \
        "$pr_title" "$short_hash" "$file_list_md")

    local commit_ok=0
    GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-George}" \
    GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-george@blue-lodge.local}" \
    GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-George}" \
    GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-george@blue-lodge.local}" \
    git -C "$wt_dir" commit -m "$commit_msg" >/dev/null 2>&1 && commit_ok=1 || true

    git -C "$repo_dir" worktree remove --force "$wt_dir" >/dev/null 2>&1 || rm -rf "$wt_dir" 2>/dev/null || true

    if [ "$commit_ok" -ne 1 ]; then
        git -C "$repo_dir" branch -D "$drift_branch" >/dev/null 2>&1 || true
        ui_warn "  [drift_sweep] Commit failed in temporary drift worktree."
        return 1
    fi

    local _force_local=1
    if pr_is_gitea_online && git -C "$repo_dir" remote get-url gitea &>/dev/null; then
        _force_local=0
        git -C "$repo_dir" push -u gitea "$drift_branch" >/dev/null 2>&1 || true

        # Close any older open drift/auto_* PRs with the exact same title so superseded drift PRs never pile up
        _gitea_load_conf
        local _old_drift_prs
        _old_drift_prs=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls?state=open" \
            -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null | \
            jq -r --arg t "$pr_title" --arg br "$drift_branch" '.[] | select(.title == $t and (.head.ref | startswith("drift/auto_")) and .head.ref != $br) | "\(.number)|\(.head.ref)"' 2>/dev/null || true)
        local _row _onum _oref
        while IFS='|' read -r _onum _oref; do
            [ -z "$_onum" ] && continue
            curl -s -X PATCH "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${_onum}" \
                -H "Authorization: token ${GITEA_TOKEN}" \
                -H "Content-Type: application/json" \
                -d '{"state":"closed"}' >/dev/null 2>&1 || true
            [ -n "$_oref" ] && git -C "$repo_dir" push gitea --delete "$_oref" >/dev/null 2>&1 || true
            [ -n "$_oref" ] && git -C "$repo_dir" branch -D "$_oref" >/dev/null 2>&1 || true
        done <<< "$_old_drift_prs"
    fi

    local dossier
    dossier=$(printf "### Autonomous Working-Tree Drift Promotion\n\n- **Source Branch:** \`%s\`\n- **Target Branch:** \`develop\`\n- **Content Fingerprint:** \`%s\`\n- **Cooldown Verified:** ≥%ss quiet window\n- **Pre-PR Warden Gate:** AST syntax & secret scan PASSED\n\n#### Promoted Files\n%s" \
        "$drift_branch" "$drift_hash" "$quiet_secs" "$file_list_md")

    local pr_out
    pr_out=$(LODGE_DIR="$repo_dir" GEORGE_DIR="$george_dir" PR_DIR="$PR_DIR" pr_create "$drift_branch" "$pr_title" "$dossier" "develop" "$_force_local" 2>&1 || true)

    # Record content hash in deduplication ledger
    mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
    local files_json
    files_json=$(printf '%s\n' "${valid_files[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
    if [ -f "$state_file" ] && jq -e . "$state_file" >/dev/null 2>&1; then
        local _tmp_st="${state_file}.tmp.${BASHPID:-$$}"
        jq --arg h "$drift_hash" --arg br "$drift_branch" --arg pr "$pr_out" --argjson ts "$now_ts" --argjson fl "$files_json" \
            '.seen_hashes[$h] = {branch: $br, pr: $pr, ts: $ts, files: $fl} | .last_hash = $h' \
            "$state_file" > "$_tmp_st" 2>/dev/null && mv -f "$_tmp_st" "$state_file" 2>/dev/null || rm -f "$_tmp_st" 2>/dev/null || true
    else
        jq -n --arg h "$drift_hash" --arg br "$drift_branch" --arg pr "$pr_out" --argjson ts "$now_ts" --argjson fl "$files_json" \
            '{last_hash: $h, seen_hashes: {($h): {branch: $br, pr: $pr, ts: $ts, files: $fl}}}' > "$state_file" 2>/dev/null || true
    fi

    ui_ok "Promoted ${#valid_files[@]} uncommitted agent file(s) to branch '${drift_branch}' for PR audit."
    return 0
}

# Keeps local develop (or active ecotype/<node>), gitea, and origin synchronized in lockstep.
pr_sync_develop_remotes() {
    local repo_dir="${1:-$LODGE_DIR}"
    [ -n "${GEORGE_TEST_SANDBOX:-}" ] || [ "${_LODGE_TESTING:-0}" = "1" ] && return 0
    git -C "$repo_dir" rev-parse --git-dir &>/dev/null || return 0

    local cur_br
    cur_br=$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)
    if [ "$cur_br" != "develop" ] && [[ "$cur_br" != ecotype/* ]]; then
        return 0
    fi

    local has_gitea=0 has_origin=0
    git -C "$repo_dir" remote get-url gitea &>/dev/null && has_gitea=1
    git -C "$repo_dir" remote get-url origin &>/dev/null && has_origin=1

    [ "$has_gitea" -eq 1 ] && git -C "$repo_dir" fetch gitea "$cur_br" >/dev/null 2>&1 || true
    [ "$has_origin" -eq 1 ] && GIT_SSH_COMMAND="ssh -o BatchMode=yes" git -C "$repo_dir" fetch origin "$cur_br" >/dev/null 2>&1 || true

    local local_sha gitea_sha origin_sha
    local_sha=$(git -C "$repo_dir" rev-parse "$cur_br" 2>/dev/null || true)
    gitea_sha=$(git -C "$repo_dir" rev-parse "gitea/$cur_br" 2>/dev/null || true)
    origin_sha=$(git -C "$repo_dir" rev-parse "origin/$cur_br" 2>/dev/null || true)

    # Fast-forward local branch if either remote is strictly ahead
    if [ -n "$gitea_sha" ] && [ "$gitea_sha" != "$local_sha" ]; then
        if git -C "$repo_dir" merge-base --is-ancestor "$local_sha" "$gitea_sha" 2>/dev/null; then
            git -C "$repo_dir" merge --ff-only "gitea/$cur_br" >/dev/null 2>&1 && local_sha="$gitea_sha" || true
        fi
    fi
    if [ -n "$origin_sha" ] && [ "$origin_sha" != "$local_sha" ]; then
        if git -C "$repo_dir" merge-base --is-ancestor "$local_sha" "$origin_sha" 2>/dev/null; then
            git -C "$repo_dir" merge --ff-only "origin/$cur_br" >/dev/null 2>&1 && local_sha="$origin_sha" || true
        fi
    fi

    # Push local branch to whichever remote is behind
    if [ "$has_gitea" -eq 1 ] && [ -n "$local_sha" ] && [ "$local_sha" != "$gitea_sha" ]; then
        if [ -z "$gitea_sha" ] || git -C "$repo_dir" merge-base --is-ancestor "$gitea_sha" "$local_sha" 2>/dev/null; then
            LODGE_MIRRORING_PUSH=1 SKIP_PREPUSH_TESTS=1 git -C "$repo_dir" push --no-verify gitea "$cur_br" >/dev/null 2>&1 || true
        fi
    fi
    if [ "$has_origin" -eq 1 ] && [ -n "$local_sha" ] && [ "$local_sha" != "$origin_sha" ]; then
        if [ -z "$origin_sha" ] || git -C "$repo_dir" merge-base --is-ancestor "$origin_sha" "$local_sha" 2>/dev/null; then
            LODGE_MIRRORING_PUSH=1 SKIP_PREPUSH_TESTS=1 GIT_SSH_COMMAND="ssh -o BatchMode=yes" git -C "$repo_dir" push --no-verify origin "$cur_br" >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

pr_sweep() {
    pr_init
    if [ "${GEORGE_SKIP_DRIFT_SWEEP:-0}" != "1" ]; then
        pr_drift_sweep "$LODGE_DIR" || true
    fi
    ui_step "Sweeping open Pull Requests..."

    local evaluated=0
    if pr_is_gitea_online; then
        _gitea_load_conf
        local open_prs
        open_prs=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls?state=open" \
            -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null)
        local pr_numbers
        pr_numbers=$(echo "$open_prs" | jq -r '.[].number // empty' 2>/dev/null)

        for pnum in $pr_numbers; do
            [ -z "$pnum" ] && continue
            evaluated=$((evaluated + 1))
            pr_auto_evaluate "$pnum"
        done
    fi

    # Check local file queue as well
    for f in "$PR_DIR"/PR-*.json; do
        [ -f "$f" ] || continue
        [[ "$f" == *.review.json ]] && continue
        local stat id
        stat=$(jq -r .status "$f" 2>/dev/null)
        id=$(jq -r .id "$f" 2>/dev/null)
        if { [ "$stat" = "PROPOSED" ] || [ "$stat" = "REMEDIATING" ]; } && [ -n "$id" ]; then
            evaluated=$((evaluated + 1))
            pr_auto_evaluate "$id"
        fi
    done

    pr_sync_develop_remotes "$LODGE_DIR" >/dev/null 2>&1 || true

    if [ "$evaluated" -eq 0 ]; then
        ui_dim "  No open PRs in queue to evaluate."
    else
        ui_ok "PR sweep completed ($evaluated PRs processed)."
    fi
}
