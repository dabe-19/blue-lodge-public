#!/bin/bash
# ── George: Rules & Instructions Subsystem (2026) ───────────────────
# Recursively discovers, queries, and injects workspace rules
# and architectural instructions (.agents/rules/**/*.md).

[ -n "${_LIB_RULES_LOADED:-}" ] && return 0; _LIB_RULES_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true

# ── Resolve Rules Directory ───────────────────────────────────────────
rules_dir() {
    local workdir="${1:-$PWD}"
    if [ -d "$workdir/.agents/rules" ]; then
        echo "$workdir/.agents/rules"
    elif [ -d "$LODGE_DIR/.agents/rules" ]; then
        echo "$LODGE_DIR/.agents/rules"
    else
        echo "$LODGE_DIR/.agents/rules"
    fi
}

# ── List All Rules Recursively ────────────────────────────────────────
rules_list() {
    local workdir="${1:-$PWD}"
    local r_dir
    r_dir=$(rules_dir "$workdir")

    local items=()
    if [ -d "$r_dir" ]; then
        while IFS= read -r f; do
            [ -f "$f" ] || continue
            local rel_path
            rel_path="${f#"$r_dir"/}"
            local r_name
            r_name=$(basename "$f" | sed -E 's/\.(instructions\.)?md$//')
            local category
            category=$(dirname "$rel_path")
            [ "$category" = "." ] && category="general"

            local summary
            summary=$(awk '/^---/{c++; next} c>=2{print} c==0{print}' "$f" 2>/dev/null | grep -v '^#' | grep -v '^[[:space:]]*$' | head -2 | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            [ -z "$summary" ] && summary="Standard instructions for $r_name"

            local json_entry
            json_entry=$(jq -n \
               --arg name "$r_name" \
               --arg category "$category" \
               --arg rel "$rel_path" \
               --arg file "$f" \
               --arg summary "$summary" \
               '{name: $name, category: $category, rel_path: $rel, file: $file, summary: $summary}')
            items+=("$json_entry")
        done < <(find "$r_dir" -type f -name "*.md" 2>/dev/null | sort)
    fi

    if [ ${#items[@]} -eq 0 ]; then
        echo "[]"
        return 0
    fi

    printf '%s\n' "${items[@]}" | jq -s 'sort_by(.category, .name)'
}

# ── Print Rules for Terminal UI ───────────────────────────────────────
rules_print_list() {
    local workdir="${1:-$PWD}"
    local json
    json=$(rules_list "$workdir")

    ui_section "Workspace Rules & Coding Standards (.agents/rules)"

    local count
    count=$(echo "$json" | jq '. | length' 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        ui_dim "  No rules discovered in $(rules_dir "$workdir")."
        return 0
    fi

    local current_cat=""
    echo "$json" | jq -r '.[] | .category + "|" + .name + "|" + .summary' | while IFS='|' read -r cat name summary; do
        if [ "$cat" != "$current_cat" ]; then
            current_cat="$cat"
            echo ""
            echo -e "${C_BOLD}  [$cat]${C_RESET}"
        fi
        printf "    %b%-24s%b %s\n" "$C_CYAN" "$name" "$C_RESET" "${summary:0:65}..."
    done
    echo ""
    ui_dim "Run /rules show <name> to view full instructions."
}

# ── Locate Rule File ──────────────────────────────────────────────────
rules_get_file() {
    local query="$1"
    local workdir="${2:-$PWD}"
    local r_dir
    r_dir=$(rules_dir "$workdir")

    # Exact relative path
    if [ -f "$r_dir/$query" ]; then
        echo "$r_dir/$query"
        return 0
    fi

    # Try .md or .instructions.md
    if [ -f "$r_dir/${query}.md" ]; then
        echo "$r_dir/${query}.md"
        return 0
    elif [ -f "$r_dir/${query}.instructions.md" ]; then
        echo "$r_dir/${query}.instructions.md"
        return 0
    fi

    # Case-insensitive filename search
    local found
    found=$(find "$r_dir" -type f \( -iname "*${query}*.md" -o -iname "*${query}*.instructions.md" \) 2>/dev/null | head -1)
    if [ -n "$found" ] && [ -f "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

# ── Read Full Rule Content ────────────────────────────────────────────
rules_content() {
    local query="$1"
    local workdir="${2:-$PWD}"
    local f
    f=$(rules_get_file "$query" "$workdir")
    if [ -n "$f" ] && [ -f "$f" ]; then
        cat "$f"
        return 0
    fi
    return 1
}

# ── Summary Block for Context Engine ──────────────────────────────────
rules_summary_for_context() {
    local workdir="${1:-$PWD}"
    local json
    json=$(rules_list "$workdir")

    local count
    count=$(echo "$json" | jq '. | length' 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        echo "(no custom workspace rules detected)"
        return 0
    fi

    echo "$json" | jq -r '.[] | "- Rule [" + .category + "/" + .name + "]: " + (.summary | .[0:120])'
}
