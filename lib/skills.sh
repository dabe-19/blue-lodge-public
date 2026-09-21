#!/bin/bash
# ── George: Skills Subsystem (2026) ──────────────────────────────────
# Discovers, loads, and executes skills (.agents/skills/*/SKILL.md).
# Includes native interactive implementations for grill-me, caveman, and tdd.

[ -n "${_LIB_SKILLS_LOADED:-}" ] && return 0; _LIB_SKILLS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR}/.george}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/react.sh" 2>/dev/null || true

# Session state flags
export _GEORGE_CAVEMAN_MODE="${_GEORGE_CAVEMAN_MODE:-0}"
export _GEORGE_TDD_MODE="${_GEORGE_TDD_MODE:-0}"
export _GEORGE_ACTIVE_SKILLS="${_GEORGE_ACTIVE_SKILLS:-}"

# ── Resolve Skills Directory ──────────────────────────────────────────
skills_dir() {
    local workdir="${1:-$PWD}"
    if [ -d "$workdir/.agents/skills" ]; then
        echo "$workdir/.agents/skills"
    elif [ -d "$LODGE_DIR/.agents/skills" ]; then
        echo "$LODGE_DIR/.agents/skills"
    else
        echo "$LODGE_DIR/.agents/skills"
    fi
}

# ── Normalize Skill Name ──────────────────────────────────────────────
skills_normalize_name() {
    local raw="$1"
    raw="${raw#/}"
    raw="${raw,,}"
    raw="${raw//_/-}" # replace underscores with hyphens
    echo "$raw"
}

# ── Locate Skill File ─────────────────────────────────────────────────
skills_get_file() {
    local name="$1"
    local workdir="${2:-$PWD}"
    local s_dir
    s_dir=$(skills_dir "$workdir")

    local norm
    norm=$(skills_normalize_name "$name")

    # Match directory with SKILL.md
    if [ -f "$s_dir/$norm/SKILL.md" ]; then
        echo "$s_dir/$norm/SKILL.md"
        return 0
    fi

    # Try underscore version (e.g. grill_me vs grill-me)
    local underscore_name="${norm//-/_}"
    if [ -f "$s_dir/$underscore_name/SKILL.md" ]; then
        echo "$s_dir/$underscore_name/SKILL.md"
        return 0
    fi

    # Search directory
    local candidate
    candidate=$(find "$s_dir" -maxdepth 2 -iname "SKILL.md" 2>/dev/null | grep -i "/$underscore_name/" | head -1)
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        echo "$candidate"
        return 0
    fi

    return 1
}

# ── Parse Skill Metadata ──────────────────────────────────────────────
skills_parse_meta() {
    local file="$1"
    [ -f "$file" ] || return 1

    local name="" desc=""
    name=$(basename "$(dirname "$file")")

    local fm
    fm=$(awk '/^---/{flag++; next} flag==1{print} flag>=2{exit}' "$file")
    local fm_name fm_desc
    fm_name=$(echo "$fm" | grep -i '^name:' | head -1 | sed 's/^name:[[:space:]]*//' | tr -d '"'\''')
    fm_desc=$(echo "$fm" | grep -i '^description:' | head -1 | sed 's/^description:[[:space:]]*//' | tr -d '"'\''')

    [ -n "$fm_name" ] && name="$fm_name"
    [ -z "$fm_desc" ] && fm_desc="Custom skill: $name"

    jq -n \
       --arg name "$name" \
       --arg desc "$fm_desc" \
       --arg file "$file" \
       '{name: $name, description: $desc, file: $file}'
}

# ── List All Skills ───────────────────────────────────────────────────
skills_list() {
    local workdir="${1:-$PWD}"
    local s_dir
    s_dir=$(skills_dir "$workdir")

    local items=()
    if [ -d "$s_dir" ]; then
        for s in "$s_dir"/*; do
            [ -d "$s" ] || continue
            local skill_file="$s/SKILL.md"
            [ -f "$skill_file" ] || continue
            local meta
            meta=$(skills_parse_meta "$skill_file")
            [ -n "$meta" ] && items+=("$meta")
        done
    fi

    if [ ${#items[@]} -eq 0 ]; then
        echo "[]"
        return 0
    fi

    printf '%s\n' "${items[@]}" | jq -s 'sort_by(.name)'
}

# ── Print Skills for Terminal UI ──────────────────────────────────────
skills_print_list() {
    local workdir="${1:-$PWD}"
    local json
    json=$(skills_list "$workdir")

    ui_section "Available Skills (.agents/skills)"

    local count
    count=$(echo "$json" | jq '. | length' 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        ui_dim "  No skills discovered in $(skills_dir "$workdir")."
        return 0
    fi

    echo "$json" | jq -r '.[] | "  \u001b[1;32m/" + .name + "\u001b[0m — " + .description' | while IFS= read -r line; do
        echo -e "$line"
    done
    echo ""
    ui_dim "Run /skill load <name> or invoke directly (e.g. /grill-me, /caveman, /tdd)"
}

# ── Load a Skill into Active Session ──────────────────────────────────
skills_load() {
    local name="$1"
    local workdir="${2:-$PWD}"

    local norm
    norm=$(skills_normalize_name "$name")

    case "$norm" in
        caveman)
            skills_toggle_caveman 1
            return 0
            ;;
        tdd)
            skills_toggle_tdd 1
            return 0
            ;;
        grill-me|grill-me-docs)
            skills_run_grill_me "" "$workdir"
            return 0
            ;;
        *)
            local file
            file=$(skills_get_file "$norm" "$workdir")
            if [ -z "$file" ] || [ ! -f "$file" ]; then
                ui_err "Skill '$name' not found in $(skills_dir "$workdir")"
                return 1
            fi
            if [[ " $_GEORGE_ACTIVE_SKILLS " =~ " $norm " ]]; then
                ui_info "Skill '$norm' is already active."
            else
                export _GEORGE_ACTIVE_SKILLS="$_GEORGE_ACTIVE_SKILLS $norm"
                ui_ok "Loaded skill: /$norm"
            fi
            return 0
            ;;
    esac
}

# ── Toggle Caveman Mode ───────────────────────────────────────────────
skills_toggle_caveman() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        export _GEORGE_CAVEMAN_MODE="$explicit"
    else
        if [ "${_GEORGE_CAVEMAN_MODE:-0}" -eq 1 ]; then
            export _GEORGE_CAVEMAN_MODE=0
        else
            export _GEORGE_CAVEMAN_MODE=1
        fi
    fi

    if [ "$_GEORGE_CAVEMAN_MODE" -eq 1 ]; then
        ui_ok "Caveman mode ON. Tokens cut ~75%. Dense fragments only."
    else
        ui_info "Caveman mode OFF. Standard communication restored."
    fi
}

# ── Toggle TDD Mode ───────────────────────────────────────────────────
skills_toggle_tdd() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        export _GEORGE_TDD_MODE="$explicit"
    else
        if [ "${_GEORGE_TDD_MODE:-0}" -eq 1 ]; then
            export _GEORGE_TDD_MODE=0
        else
            export _GEORGE_TDD_MODE=1
        fi
    fi

    if [ "$_GEORGE_TDD_MODE" -eq 1 ]; then
        ui_ok "TDD mode ON. Enforcing Red-Green-Refactor loop."
    else
        ui_info "TDD mode OFF."
    fi
}

# ── Interactive Grilling Session: /grill-me ────────────────────────────
skills_run_grill_me() {
    local topic="$1"
    local workdir="${2:-$PWD}"

    ui_header "Grill Me: Socratic Stress-Testing Session" "Interviews relentlessly until reaching shared architectural understanding"

    if [ -z "$topic" ]; then
        if [ -t 0 ]; then
            echo -en "${C_CYAN}Enter plan, architecture, or feature to grill:${C_RESET} "
            read -r topic
        fi
    fi

    if [ -z "$topic" ]; then
        ui_err "Grill-me requires a plan or topic to cross-examine."
        return 1
    fi

    local s_file
    s_file=$(skills_get_file "grill-me" "$workdir")
    local skill_instr=""
    [ -f "$s_file" ] && skill_instr=$(cat "$s_file")

    local grill_prompt="You are running the GRILL-ME skill on the following plan/topic:
TOPIC: $topic

Instructions:
1. Examine the project context and existing files using file_read and file_grep.
2. Break down the user's plan into an abstract decision tree.
3. Formulate precise questions focusing on hidden trade-offs, ordering constraints, fallback states, and potential failure points.
4. ISOLATION RULE: Pose exactly ONE single primary question at a time.
5. PRESUMPTIVE RECOMMENDATION: For that single question, provide an accompanying, well-reasoned recommended answer to reduce cognitive load.
6. Present the question and recommendation clearly to the user and wait for their response."

    react_run "$grill_prompt\n\n$skill_instr" "$workdir"
}
