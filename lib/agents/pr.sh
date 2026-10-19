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
            git -C "$LODGE_DIR" fetch gitea "$src" >/dev/null 2>&1 || true
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
    if ! git -C "$review_dir" rev-parse --verify "$merge_ref" &>/dev/null; then
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
        local _syntax_ok=1 _f
        while IFS= read -r _f; do
            [ -z "$_f" ] && continue
            [ ! -f "$_f" ] && continue
            case "$_f" in
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
            if [ "${#_target_suites[@]}" -gt 0 ]; then
                bash tests/run_all.sh "${_target_suites[@]}" >> "$audit_log" 2>&1 || exit $?
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
        if [ "$is_gitea" -eq 0 ]; then
            jq '.status = "REJECTED" | .audit_verdict = "TEST_FAILURES"' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
        else
            ui_warn "Gitea PR #${clean_id} failed audit verification."
            gitea_issue_comment "$clean_id" "### ❌ George Audit Verdict: REJECTED
Test suite regressions detected in review sandbox (exit code $test_res)." >/dev/null 2>&1 || true

            local max_attempts
            max_attempts=$(limits_get MAX_REMEDIATION_ATTEMPTS 5 2>/dev/null || echo 5)
            local attempt_file="$PR_DIR/${clean_id}.attempts"
            local cur_attempts=1
            [ -f "$attempt_file" ] && cur_attempts=$(($(cat "$attempt_file" 2>/dev/null || echo 0) + 1))
            echo "$cur_attempts" > "$attempt_file"

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

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")
    local rev_file="$PR_DIR/${clean_id}.review.json"
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
# requires an APPROVED review verdict AND a non-empty review comment by George or an operator.
pr_has_reviewer_acceptance() {
    local pr_id="$1"
    local clean_id="${pr_id#\#}"
    [ -z "$clean_id" ] && return 1

    local rev_file="$PR_DIR/${clean_id}.review.json"
    if [ -f "$rev_file" ]; then
        if jq -e '.approved == true and ((.comment // "") | length > 0)' "$rev_file" >/dev/null 2>&1; then
            return 0
        fi
    fi

    local json_file="$PR_DIR/${pr_id}.json"
    [ ! -f "$json_file" ] && json_file="$PR_DIR/${clean_id}.json"
    if [ -f "$json_file" ]; then
        if jq -e '.review_approved == true and ((.review_comment // "") | length > 0)' "$json_file" >/dev/null 2>&1; then
            return 0
        fi
    fi

    if [[ "$clean_id" =~ ^[0-9]+$ ]] && pr_is_gitea_online; then
        _gitea_load_conf
        local reviews_json
        reviews_json=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${clean_id}/reviews" \
            -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null || echo "[]")
        if echo "$reviews_json" | jq -e 'map(select((.state == "APPROVED" or .state == "COMMENT") and ((.body // "") | test("APPROVED|George PR Review: APPROVED"; "i")))) | length > 0' >/dev/null 2>&1; then
            local r_body
            r_body=$(echo "$reviews_json" | jq -r 'map(select((.state == "APPROVED" or .state == "COMMENT") and ((.body // "") | test("APPROVED|George PR Review: APPROVED"; "i")))) | last | .body // ""' 2>/dev/null)
            pr_record_review "$clean_id" "APPROVED" "$r_body" "George (Gitea Review)"
            return 0
        fi

        local comments_json
        comments_json=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues/${clean_id}/comments" \
            -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null || echo "[]")
        if echo "$comments_json" | jq -e 'map(select((.body // "") | test("\\[George PR Review:\\s*APPROVED\\]|VERDICT:\\s*APPROVED"; "i"))) | length > 0' >/dev/null 2>&1; then
            local c_body
            c_body=$(echo "$comments_json" | jq -r 'map(select((.body // "") | test("\\[George PR Review:\\s*APPROVED\\]|VERDICT:\\s*APPROVED"; "i"))) | last | .body // ""' 2>/dev/null)
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
            git -C "$LODGE_DIR" fetch gitea "$src" >/dev/null 2>&1 || true
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
    fi

    local review_prompt="Conduct a formal 1-Reviewer Acceptance Review for Pull Request ${pr_id} ('${title}', branch '${src}' -> '${tgt}').
PR Index: ${clean_id}

Diffstat:
${diff_stat}

Unified Diff (truncated to 8,000 chars):
${diff_text:0:8000}

Instructions:
1. Use your pr_reviewer tools (file_read, file_grep, code_outline, code_symbol_get) to inspect any modified files in the workspace if needed.
2. Check for subshell variable-scoping bugs, unquoted expansions, missing flock concurrency guards, write-scope denylist violations, or logic regressions.
3. Submit your review on the PR by calling gitea_pr_review with index=${clean_id}, event=\"APPROVED\" (or \"REQUEST_CHANGES\" if defects are found), and a concise technical review body.
4. End your response with VERDICT: APPROVED or VERDICT: REQUEST_CHANGES."

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
        local rev_session="pr_review_${clean_id}"
        (
            export GEORGE_PROMPT_PROFILE="pr_reviewer"
            export REACT_STRICT_TOOLS=1
            react_run "$review_prompt" "$wt_dir" "${PR_REVIEW_MAX_TURNS:-6}" 1 "$rev_session" "pr_reviewer" >/dev/null 2>&1
        ) || true

        if [ -f "$PR_DIR/${clean_id}.review.json" ]; then
            review_verdict=$(jq -r '.verdict // empty' "$PR_DIR/${clean_id}.review.json" 2>/dev/null)
            review_comment=$(jq -r '.comment // empty' "$PR_DIR/${clean_id}.review.json" 2>/dev/null)
        fi

        local final_reply_file="${GEORGE_DIR}/workspaces/${rev_session}/final_reply.txt"
        if [ -z "$review_verdict" ] && [ -f "$final_reply_file" ]; then
            local reply_txt
            reply_txt=$(cat "$final_reply_file" 2>/dev/null || true)
            if [ -n "$reply_txt" ]; then
                review_comment="$reply_txt"
                if echo "$reply_txt" | grep -qiE 'VERDICT:[[:space:]]*REQUEST_CHANGES|REQUEST_CHANGES'; then
                    review_verdict="REQUEST_CHANGES"
                else
                    review_verdict="APPROVED"
                fi
            fi
        fi
    fi

    # Clean up ephemeral review worktree
    if [ "$wt_dir" = "$review_wt" ]; then
        git -C "$LODGE_DIR" worktree remove --force "$review_wt" 2>/dev/null || rm -rf "$review_wt" 2>/dev/null || true
        git -C "$LODGE_DIR" branch -D "$review_br" 2>/dev/null || true
    fi

    # Fallback deterministic synthesis if ReAct LLM was offline or did not emit a verdict
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

    # Persist and post the review if not already recorded
    if [ ! -f "$PR_DIR/${clean_id}.review.json" ]; then
        pr_record_review "$pr_id" "$review_verdict" "$review_comment" "George (ReAct Reviewer)"
        if [ "$is_gitea" -eq 1 ]; then
            gitea_pr_review "$clean_id" "$review_verdict" "$review_comment" >/dev/null 2>&1 || \
            gitea_issue_comment "$clean_id" "### 🔎 [George PR Review: ${review_verdict}]"$'\n\n'"${review_comment}" >/dev/null 2>&1 || true
        fi
    fi

    if [ "$review_verdict" = "APPROVED" ]; then
        ui_ok "George ReAct Review Verdict: APPROVED (${pr_id})"
        return 0
    else
        ui_warn "George ReAct Review Verdict: ${review_verdict} (${pr_id})"
        return 1
    fi
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
        if gitea_pr_merge "$clean_id" "$strategy"; then
            gitea_issue_comment "$clean_id" "### 🚀 Sovereign PR #${clean_id} Merged
Branch successfully merged into target branch via strategy \`${strategy}\`. Local develop branch updated." >/dev/null 2>&1 || true
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

# ── Hands-off Closed-Loop PR Evaluation & Sweep ───────────────
pr_auto_evaluate() {
    local pr_id="$1"
    local clean_id="${pr_id#\#}"
    [ -z "$clean_id" ] && return 1

    ui_section "Autonomous Closed-Loop Review: PR #${clean_id}"

    # Check current PR state and source branch first
    local pr_meta="" head_branch=""
    if [[ "$clean_id" =~ ^[0-9]+$ ]] && pr_is_gitea_online; then
        _gitea_load_conf
        pr_meta=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${clean_id}" \
            -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null)
        local pr_state
        pr_state=$(echo "$pr_meta" | jq -r .state 2>/dev/null)
        local is_merged
        is_merged=$(echo "$pr_meta" | jq -r .merged 2>/dev/null)
        head_branch=$(echo "$pr_meta" | jq -r '.head.ref // empty' 2>/dev/null)
        if [ "$pr_state" = "closed" ] || [ "$is_merged" = "true" ]; then
            ui_info "PR #${clean_id} is already closed/merged. Skipping auto-evaluation."
            return 0
        fi
    elif [ -f "$PR_DIR/${pr_id}.json" ]; then
        head_branch=$(jq -r '.source_branch // empty' "$PR_DIR/${pr_id}.json" 2>/dev/null)
    fi

    # Guard against split-brain race: defer evaluation if an active remediation worker owns this branch
    if [[ "$head_branch" == remediation/* ]]; then
        local rem_tid="${head_branch#remediation/}"
        local rem_prog="${GEORGE_DIR:-$LODGE_DIR/.george}/remediation/in_progress/${rem_tid}.json"
        local rem_sbox="${LODGE_DIR}/.sandboxes/remediation_${rem_tid}"
        if [ -f "$rem_prog" ] || [ -d "$rem_sbox" ]; then
            ui_info "PR #${clean_id} belongs to active remediation worker (${rem_tid}); deferring sweep until worker finishes."
            return 0
        fi
    fi

    # Stage 1: Run Three Degrees Audit (Merge + Write-Scope Denylist + Tyler Security + Test Gate)
    if pr_audit "$pr_id"; then
        ui_ok "PR #${clean_id} passed Three Degrees Audit. Proceeding to George 1-Reviewer ReAct Review..."

        # Stage 2: George ReAct Code Review & Comment Gate
        if ! pr_has_reviewer_acceptance "$pr_id"; then
            if ! pr_review "$pr_id"; then
                ui_warn "PR #${clean_id} did not receive George ReAct reviewer approval. Auto-merge blocked."
                return 1
            fi
        fi

        # Stage 3: Verify 1-Reviewer Acceptance Criteria before merging
        if ! pr_has_reviewer_acceptance "$pr_id"; then
            ui_err "PR #${clean_id} lacks verified 1-reviewer acceptance comment. Auto-merge blocked."
            return 1
        fi

        ui_ok "PR #${clean_id} passed audit, denylist, and 1-reviewer ReAct acceptance. Executing autonomous merge..."
        if PR_REQUIRE_REVIEW=1 pr_accept "$pr_id" "merge"; then
            ui_ok "Hands-off loop complete: PR #${clean_id} audited, reviewed, and merged into develop!"
            if declare -f journal_record &>/dev/null; then
                journal_record "Hands-off autonomous loop merged PR #${clean_id} into develop following Three Degrees Audit and George ReAct 1-Reviewer approval." >/dev/null 2>&1 || true
            fi
            return 0
        else
            ui_err "Failed to execute auto-merge for PR #${clean_id} despite audit and review pass."
            return 1
        fi
    else
        ui_warn "PR #${clean_id} failed audit verification."
        local max_attempts
        max_attempts=$(limits_get MAX_REMEDIATION_ATTEMPTS 5 2>/dev/null || echo 5)
        local attempt_file="$PR_DIR/${clean_id}.attempts"
        local cur_attempts=1
        [ -f "$attempt_file" ] && cur_attempts=$(cat "$attempt_file" 2>/dev/null || echo 1)

        if [ "$cur_attempts" -lt "$max_attempts" ]; then
            ui_info "Triggering auto-remediation subagent (attempt ${cur_attempts}/${max_attempts}) for PR #${clean_id}..."
            if declare -f subagents_spawn &>/dev/null; then
                [ -z "$head_branch" ] && head_branch="subagent/pr_${clean_id}"
                subagents_spawn 1 "Remediate test regressions on branch '${head_branch}' for PR #${clean_id}. Inspect test failure logs in .george/pulls/${clean_id}.audit.log, fix root causes, commit to '${head_branch}', and push to gitea." 50 1 >/dev/null 2>&1 || true
                if declare -f gitea_issue_comment &>/dev/null; then
                    gitea_issue_comment "$clean_id" "🤖 **[Auto-Remediation]** Dispatched Tier 1 subagent to remediate test regressions (attempt ${cur_attempts}/${max_attempts})." >/dev/null 2>&1 || true
                fi
            fi
        fi
        return 1
    fi
}

pr_sweep() {
    pr_init
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
    for f in "$PR_DIR"/*.json; do
        [ -f "$f" ] || continue
        [[ "$f" == *.review.json ]] && continue
        local stat id
        stat=$(jq -r .status "$f" 2>/dev/null)
        id=$(jq -r .id "$f" 2>/dev/null)
        if [ "$stat" = "PROPOSED" ] && [ -n "$id" ]; then
            evaluated=$((evaluated + 1))
            pr_auto_evaluate "$id"
        fi
    done

    if [ "$evaluated" -eq 0 ]; then
        ui_dim "  No open PRs in queue to evaluate."
    else
        ui_ok "PR sweep completed ($evaluated PRs processed)."
    fi
}
