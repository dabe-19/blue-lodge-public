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

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/git.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/subagents.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/journal.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mcp_server_gitea.sh" 2>/dev/null || true

pr_init() {
    mkdir -p "$PR_DIR" 2>/dev/null || true
    gitflow_init "$LODGE_DIR" >/dev/null 2>&1 || true
}

pr_is_gitea_online() {
    local url="${GITEA_URL:-http://127.0.0.1:3088}"
    curl -sf --max-time 1 "${url}/api/v1/version" &>/dev/null
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

pr_audit() {
    local pr_id="$1"
    local clean_id="${pr_id#\#}"
    local is_gitea=0
    local src tgt title
    local json_file="$PR_DIR/${pr_id}.json"

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
    local tmp_json="${json_file}.tmp.$$"
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
    (
        cd "$review_dir" || exit 1
        git merge --no-commit --no-ff "$src" >> "$audit_log" 2>&1 || merge_err=$?
    )

    if [ "$merge_err" -ne 0 ]; then
        ui_err "Merge conflict detected while merging '$src' into '$tgt'."
        echo "[AUDIT FAIL] Merge conflict during review sandbox integration." >> "$audit_log"
        if [ "$is_gitea" -eq 0 ]; then
            jq '.status = "REJECTED" | .audit_verdict = "MERGE_CONFLICT"' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
        fi
        git -C "$LODGE_DIR" worktree remove --force "$review_dir" 2>/dev/null || true
        git -C "$LODGE_DIR" branch -D "$review_branch" 2>/dev/null || true
        return 1
    fi

    ui_step "Second Degree: Invoking Security and Style Guardians..."
    # 1. Check for unsafe eval/shell injection patterns
    local sec_issues
    sec_issues=$(git -C "$review_dir" diff "$tgt..HEAD" | grep -E '^\+[[:space:]]*(eval[[:space:]]|rm[[:space:]]+-rf[[:space:]]+/)') || true
    if [ -n "$sec_issues" ]; then
        ui_warn "The Tyler (Security Gate): High-risk command pattern detected."
        echo "[SECURITY WARNING] Potential unsafe pattern: $sec_issues" >> "$audit_log"
    else
        ui_ok "The Tyler (Security Gate): Zero high-risk shell patterns detected."
        echo "[SECURITY PASS] The Tyler audit cleared." >> "$audit_log"
    fi

    # 2. Run Test Harness
    ui_step "Running test harness validation in review sandbox..."
    local test_res=0
    (
        cd "$review_dir" || exit 1
        bash tests/run_all.sh >> "$audit_log" 2>&1 || test_res=$?
    )

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
            ui_info "Gitea PR #${clean_id} verified ready for merge!"
        fi
        return 0
    else
        ui_err "Verdict: REJECT (Test regressions detected in review sandbox)"
        echo "[AUDIT FAIL] Test regressions detected (exit $test_res)." >> "$audit_log"
        if [ "$is_gitea" -eq 0 ]; then
            jq '.status = "REJECTED" | .audit_verdict = "TEST_FAILURES"' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
        else
            ui_warn "Gitea PR #${clean_id} failed audit verification."
        fi
        return 1
    fi
}

pr_accept() {
    local pr_id="$1"
    local strategy="${2:-merge}"
    local clean_id="${pr_id#\#}"

    if [[ "$clean_id" =~ ^[0-9]+$ ]] && pr_is_gitea_online; then
        ui_info "Accepting and merging sovereign Gitea PR #${clean_id} via strategy: ${strategy}..."
        gitea_pr_merge "$clean_id" "$strategy"
        return $?
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

    local tmp_json="${json_file}.tmp.$$"
    jq '.status = "MERGED"' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"

    # Record episodic achievement in permanent journal
    if declare -f journal_record &>/dev/null; then
        journal_record "Accepted and merged pull request ${pr_id} ('${title}') into '${tgt}'. Proven deliverable promoted upstream." >/dev/null 2>&1 || true
    fi

    ui_ok "Pull Request ${pr_id} merged into '${tgt}' successfully!"
    ui_dim "  Commit: $(git -C "$LODGE_DIR" rev-parse --short "$tgt" 2>/dev/null)"
}

pr_reject() {
    local pr_id="$1"
    local reason="${2:-Rejected by operator}"
    local json_file="$PR_DIR/${pr_id}.json"
    if [ ! -f "$json_file" ]; then
        ui_err "PR $pr_id not found in local queue."
        return 1
    fi

    local tmp_json="${json_file}.tmp.$$"
    jq --arg r "$reason" '.status = "REJECTED" | .rejection_reason = $r' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
    ui_warn "PR $pr_id marked REJECTED: $reason"
}
