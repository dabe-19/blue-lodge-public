#!/bin/bash
# ── George: Software Phytology Groundwork ─────────────────────────────
# Manages the living tissue of George's self-modifying codebase.
#
# Tissue Hierarchy:
#   - Cambium (Core Architecture): $LODGE_DIR/lib/, lodge, web/src/
#     Protected tissue: strict immutable boundaries, vetted via conventional commits.
#   - Foliage (Operator Customizations): .george/cron_jobs/, .george/tools/
#     Living peripheral tissue: dynamically grafted, pruned, and evolved by George.
#   - Genetic Memory (Snapshots): .george/snapshots/
#     Local shadow versioning with zero Git tree pollution on develop/main.
#
# Safety Invariants:
#   1. Zero Side-Effect AST Check: bash -n or py_compile before any file overwrite.
#   2. Atomic Grafts: write to temporary buffer -> verify -> atomic mv.
#   3. Instant Rollback: automatic pre-graft snapshot retention (last 10 versions).

[ -n "${_LIB_PHYTOLOGY_LOADED:-}" ] && return 0; _LIB_PHYTOLOGY_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
CAMBIUM_ROOT="${LODGE_DIR}/lib"
FOLIAGE_ROOT="${GEORGE_DIR}/cron_jobs"
FOLIAGE_TOOLS_ROOT="${GEORGE_DIR}/tools"
PHYTOLOGY_SNAPSHOTS_DIR="${GEORGE_DIR}/snapshots"

# ── Initialization ────────────────────────────────────────────────────
phytology_init() {
    mkdir -p "$PHYTOLOGY_SNAPSHOTS_DIR" "$FOLIAGE_ROOT" "$FOLIAGE_TOOLS_ROOT" "${GEORGE_DIR}/tmp" 2>/dev/null || true
}

# ── 1. Static AST & Syntax Validation ─────────────────────────────────
phytology_verify_syntax() {
    local file_path="$1"
    [ ! -f "$file_path" ] && return 1

    local ext="${file_path##*.}"
    case "$ext" in
        sh|bash)
            local err_out
            if ! err_out=$(bash -n "$file_path" 2>&1); then
                echo "SYNTAX_ERROR: Bash AST validation failed: $err_out" >&2
                return 1
            fi
            ;;
        py)
            if command -v python3 &>/dev/null; then
                local err_out
                if ! err_out=$(python3 -m py_compile "$file_path" 2>&1); then
                    echo "SYNTAX_ERROR: Python AST validation failed: $err_out" >&2
                    return 1
                fi
            fi
            ;;
        json)
            if command -v jq &>/dev/null; then
                if ! jq empty "$file_path" 2>&1; then
                    echo "SYNTAX_ERROR: JSON parse failed" >&2
                    return 1
                fi
            fi
            ;;
        *)
            # Non-script files (markdown, text, etc.) pass syntax validation
            return 0
            ;;
    esac
    return 0
}

# ── 2. Local Genetic Snapshot Versioning ───────────────────────────────
phytology_snapshot() {
    local file_path="$1"
    [ ! -f "$file_path" ] && return 0

    phytology_init
    local fname
    fname="$(basename "$file_path")"
    local now
    now="$(date +%s)"
    local snap_file="${PHYTOLOGY_SNAPSHOTS_DIR}/${fname}.${now}.bak"

    cp "$file_path" "$snap_file" 2>/dev/null || true

    # Keep at most 10 recent snapshots for this file
    local count
    count=$(find "$PHYTOLOGY_SNAPSHOTS_DIR" -maxdepth 1 -name "${fname}.*.bak" 2>/dev/null | wc -l)
    if [ "$count" -gt 10 ]; then
        find "$PHYTOLOGY_SNAPSHOTS_DIR" -maxdepth 1 -name "${fname}.*.bak" 2>/dev/null | sort -V | head -n -10 | xargs rm -f 2>/dev/null || true
    fi
    echo "$snap_file"
}

# ── 3. Safe Atomic Grafting ────────────────────────────────────────────
# Usage: phytology_graft <target_file> <candidate_file_or_content>
phytology_graft() {
    local target_file="$1"
    local source_input="$2"

    if [ -z "$target_file" ] || [ -z "$source_input" ]; then
        echo "ERROR: Target file and source content/path required" >&2
        return 1
    fi

    phytology_init
    local tmp_target="${GEORGE_DIR}/tmp/graft_$$.$(basename "$target_file")"

    # Populate temporary file from file path or raw string
    if [ -f "$source_input" ]; then
        cp "$source_input" "$tmp_target"
    else
        printf '%s\n' "$source_input" > "$tmp_target"
    fi

    # Step 1: Zero-side-effect AST syntax validation
    if ! phytology_verify_syntax "$tmp_target"; then
        echo "GRAFT_REJECTED: Candidate failed AST validation. Target remains untouched." >&2
        rm -f "$tmp_target"
        return 1
    fi

    # Step 2: Genetic Memory Checkpoint (Snapshot existing target if present)
    if [ -f "$target_file" ]; then
        local snap
        snap=$(phytology_snapshot "$target_file")
        [ -n "$snap" ] && [ "${LODGE_DEBUG:-0}" -eq 1 ] && echo "Snapshot preserved: $snap" >&2
    fi

    # Step 3: Atomic Replacement
    mkdir -p "$(dirname "$target_file")" 2>/dev/null || true
    if ! mv -f "$tmp_target" "$target_file"; then
        echo "ERROR: Failed to move graft into destination: $target_file" >&2
        rm -f "$tmp_target"
        return 1
    fi

    # Ensure executable permissions for scripts in foliage
    if [[ "$target_file" == *.sh ]] || [[ "$target_file" == *.py ]]; then
        chmod +x "$target_file" 2>/dev/null || true
    fi

    # Step 4: Audit logging
    if declare -f transcript_log &>/dev/null; then
        transcript_log "phytology" "Grafted tissue: $target_file (AST verified)"
    fi

    echo "GRAFT_SUCCESS: $target_file grafted and verified."
    return 0
}

# ── 4. Rollback to Genetic Snapshot ───────────────────────────────────
phytology_rollback() {
    local target_file="$1"
    local fname
    fname="$(basename "$target_file")"

    local latest_snap
    latest_snap=$(find "$PHYTOLOGY_SNAPSHOTS_DIR" -maxdepth 1 -name "${fname}.*.bak" 2>/dev/null | sort -V | tail -n 1)

    if [ -z "$latest_snap" ] || [ ! -f "$latest_snap" ]; then
        echo "ERROR: No snapshot available for $target_file" >&2
        return 1
    fi

    cp "$latest_snap" "$target_file"
    echo "ROLLBACK_SUCCESS: $target_file restored from snapshot $(basename "$latest_snap")"
    return 0
}

# ── 5. Tissue Introspection ───────────────────────────────────────────
phytology_introspect() {
    phytology_init
    local cambium_count foliage_count tool_count snap_count
    cambium_count=$(find "$CAMBIUM_ROOT" -maxdepth 1 -name "*.sh" 2>/dev/null | wc -l)
    foliage_count=$(find "$FOLIAGE_ROOT" -maxdepth 1 -name "*.sh" 2>/dev/null | wc -l)
    tool_count=$(find "$FOLIAGE_TOOLS_ROOT" -maxdepth 1 -type f 2>/dev/null | wc -l)
    snap_count=$(find "$PHYTOLOGY_SNAPSHOTS_DIR" -maxdepth 1 -name "*.bak" 2>/dev/null | wc -l)

    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║ 🌿 GEORGE LIVING TISSUE & PHYTOLOGY MANIFEST                  ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo "  • Cambium Root (Immutable Architecture): $cambium_count core modules ($CAMBIUM_ROOT)"
    echo "  • Foliage (Autonomic Cron Sweeps):       $foliage_count operator scripts ($FOLIAGE_ROOT)"
    echo "  • Tool Crib Foliage (Dynamic Tools):     $tool_count custom tools ($FOLIAGE_TOOLS_ROOT)"
    echo "  • Genetic Snapshots (Local Versioning):  $snap_count shadow snapshots ($PHYTOLOGY_SNAPSHOTS_DIR)"
    echo ""
}

# ── 6. Autonomic Pruning ──────────────────────────────────────────────
phytology_prune() {
    local job_name="$1"
    [ -z "$job_name" ] && return 1

    local script="$FOLIAGE_ROOT/${job_name}.sh"
    if [ -f "$script" ]; then
        # Check if already disabled
        if grep -q "^# ENABLED: 0" "$script" 2>/dev/null; then
            echo "PRUNE_SKIPPED: $job_name is already pruned/disabled."
            return 0
        fi

        # Pre-graft snapshot before pruning
        phytology_snapshot "$script"

        # Mark disabled
        sed -i 's/^# ENABLED: 1/# ENABLED: 0/' "$script" 2>/dev/null || {
            sed -i '1a # ENABLED: 0' "$script" 2>/dev/null
        }

        echo "PRUNE_SUCCESS: De-activated failing foliage job '$job_name' (# ENABLED: 0)."
        return 0
    fi
    return 1
}
