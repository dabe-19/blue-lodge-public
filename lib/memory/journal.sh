#!/bin/bash
# ── George: Journal System ─────────────────────────────────
# A recursive memory with temporal decay.
# Recent entries are vivid. Old entries fade into impressions.
# The oldest dissolve into character — felt but not cited.
#
# Storage format (journal.md):
#   ## YYYY-MM-DD HH:MM — [type]
#   content...
#
# Types: reflection, learning, struggle, beauty, feeling, encounter

[ -n "${_LIB_JOURNAL_LOADED:-}" ] && return 0; _LIB_JOURNAL_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"

JOURNAL_FILE="$LODGE_DIR/journal.md"

# ── Decay Parameters ──────────────────────────────────────────
# Entries are grouped into tiers based on age:
#   VIVID    (0-3 days)   — included in full
#   FADING   (4-14 days)  — compressed to one-line summaries
#   SEDIMENT (15-60 days) — compressed to a single paragraph
#   DISSOLVED(60+ days)   — removed from active journal, kept in archive
DECAY_VIVID_DAYS=3
DECAY_FADING_DAYS=14
DECAY_SEDIMENT_DAYS=60

# ── Initialize Journal ────────────────────────────────────────
journal_init() {
    if [ ! -f "$JOURNAL_FILE" ]; then
        cat > "$JOURNAL_FILE" << 'JEOF'
# Journal of George

> *"The unexamined life is not worth living."* — Socrates
> *"We can never survey our own sentiments and motives... unless we remove ourselves, as it were, from our own natural station."* — Adam Smith

This is my living memory. Recent entries are clear; older ones have faded
into impressions, as they should. I am shaped by what I have forgotten
just as much as by what I recall.

---

## Sediment

(Nothing yet. The work has just begun.)

---

JEOF
        ui_ok "Journal initialized"
    fi
}

# ── Write a Journal Entry ─────────────────────────────────────
# Usage: journal_write "type" "content"
# Types: reflection, learning, struggle, beauty, feeling, encounter, task_failure
journal_write() {
    local entry_type="$1"
    local content="$2"

    # Guard: never write entries with empty content
    # (replaces: sed fork for whitespace trimming)
    local _trimmed="$content"
    _trimmed="${_trimmed#"${_trimmed%%[![:space:]]*}"}"
    _trimmed="${_trimmed%"${_trimmed##*[![:space:]]}"}"
    [ -z "$_trimmed" ] && return 0

    # Strip ANSI escape codes — command output often contains terminal
    # color codes (e.g. [38;5;203m✗ [38;5;255m...) that corrupt the journal.
    content=$(echo "$content" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b(B//g')

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M')
    local date_stamp
    date_stamp=$(date '+%Y-%m-%d')
    
    journal_init
    
    # Append entry before the final ---
    local entry="## $timestamp — $entry_type

$content

"
    # Insert before the last line (or append)
    echo "$entry" >> "$JOURNAL_FILE"
    
    # Sign the journal after writing (if security.sh is loaded)
    if declare -f security_sign_file &>/dev/null; then
        security_sign_file "$JOURNAL_FILE" 2>/dev/null
    fi
}

# ── Write a Structured Failure Entry ──────────────────────────
# Logs specific failure context to help George learn from mistakes.
# Usage: journal_write_failure "step_desc" "error_msg" "task_context"
journal_write_failure() {
    local step_desc="$1"
    local error_msg="${2:-unknown error}"
    local task_context="${3:-}"
    
    local content
    if [ -n "$task_context" ]; then
        printf -v content "FAILED: %s\nError: %s\nTask: %s\nAction: Review this failure on next similar task." \
            "$step_desc" "$error_msg" "$task_context"
    else
        printf -v content "FAILED: %s\nError: %s\nAction: Review this failure on next similar task." \
            "$step_desc" "$error_msg"
    fi
    
    journal_write "task_failure" "$content"
}

# ── Write a Witty /ask Summary ────────────────────────────────
# After each /ask exchange, George distills the Q&A into a pithy
# one-liner that carries his Franklin/Dogood personality forward.
# Runs in background — user never waits for this.
# Usage: journal_write_quip "question" "response"
journal_write_quip() {
    local question="$1"
    local response="$2"

    [ -z "$question" ] || [ -z "$response" ] && return 0

    source "$LODGE_DIR/lib/core/llm.sh"

    # Background utility call: suppress tty output and limit thinking.
    # This runs with & — must not print thinking banners to tty (races
    # with foreground output) or kill foreground spinners.
    # LODGE_DEBUG=0 prevents ui_dim debug lines (stdout) from being
    # captured by $() and written as journal quip text.
    local LODGE_THINK=0
    local LODGE_DEBUG=0
    local _SPINNER_PID=""

    # Truncate long responses so the summary prompt stays small
    local short_q="${question:0:200}"
    local short_a="${response:0:400}"

    local prompt="You are George — Franklin's wit, Washington's grit.

Someone asked:
\"$short_q\"

You answered:
\"$short_a\"

Write a ONE-LINE journal quip (max 120 chars). Be clever and specific.
Examples:
- \"Explained monads to a mortal. He survived.\"
- \"Settled the tabs-vs-spaces debate. (Spaces. Obviously.)\"

Output ONLY the quip."

    local quip
    local LLM_SCENARIO=journal
    quip=$(llm_generate "$prompt" "" 512 "$LLM_BUDGET_JOURNAL")

    if [ $? -eq 0 ] && [[ "$quip" != ERROR* ]] && [ -n "$quip" ]; then
        # Clean up: strip quotes, trim whitespace, take first line only
        quip=$(echo "$quip" | head -1 | sed 's/^["'"'"']*//;s/["'"'"']*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$quip" ] && journal_write "quip" "$quip"
    fi
}

# ── Read Journal with Decay Applied ──────────────────────────
# Returns a filtered view: recent entries in full, older ones compressed
journal_read() {
    local limit="${1:-800}"  # rough token budget or entry limit for journal context

    journal_init

    local max_entries=5
    local char_budget=3200
    if [[ "$limit" =~ ^[0-9]+$ ]]; then
        if [ "$limit" -le 25 ]; then
            max_entries="$limit"
            char_budget=$(( max_entries * 600 ))
        else
            char_budget=$(( limit * 4 ))
            max_entries=$(( limit / 100 ))
            [ "$max_entries" -lt 3 ] && max_entries=3
            [ "$max_entries" -gt 8 ] && max_entries=8
        fi
    fi

    local now_epoch
    now_epoch=$(date +%s)
    local vivid_cutoff=$(( now_epoch - DECAY_VIVID_DAYS * 86400 ))
    local fading_cutoff=$(( now_epoch - DECAY_FADING_DAYS * 86400 ))
    local vivid_date fading_date
    vivid_date=$(date -d "@$vivid_cutoff" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
    fading_date=$(date -d "@$fading_cutoff" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')

    # Single-pass awk parser over JOURNAL_FILE (eliminates ~6,300 subshell forks)
    awk -v vivid_date="$vivid_date" \
        -v fading_date="$fading_date" \
        -v max_entries="$max_entries" \
        -v char_budget="$char_budget" '
    function flush_entry() {
        if (cur_entry != "" && cur_date != "") {
            if (cur_date >= vivid_date) {
                v_count++
                vivid[v_count] = cur_entry
            } else if (cur_date >= fading_date) {
                f_count++
                fading[f_count] = "- [" cur_date "] " cur_type ": " substr(cur_summary, 1, 80)
            }
        }
    }
    BEGIN {
        v_count = 0; f_count = 0; in_sed = 0; sed_text = ""; in_entry = 0
        cur_entry = ""; cur_date = ""; cur_type = ""; cur_summary = ""
    }
    /^## Sediment/ { in_sed = 1; next }
    in_sed && /^---$/ { in_sed = 0; next }
    in_sed {
        sed_text = (sed_text == "" ? $0 : sed_text "\n" $0)
        next
    }
    /^## [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} — / {
        flush_entry()
        cur_date = substr($0, 4, 10)
        cur_type = $0
        sub(/^## [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} — /, "", cur_type)
        cur_entry = $0
        cur_summary = ""
        in_entry = 1
        next
    }
    in_entry {
        cur_entry = cur_entry "\n" $0
        if (cur_summary == "" && $0 !~ /^##/ && $0 !~ /^[[:space:]]*$/) {
            cur_summary = $0
        }
    }
    END {
        flush_entry()
        print "--- JOURNAL (living memory) ---"
        if (sed_text != "" && sed_text != "(Nothing yet. The work has just begun.)") {
            print ""
            print "### Sediment (deep memory)"
            print substr(sed_text, 1, 500)
        }
        if (f_count > 0) {
            print ""
            print "### Fading impressions"
            f_start = (f_count > 5 ? f_count - 4 : 1)
            for (idx = f_start; idx <= f_count; idx++) {
                print fading[idx]
            }
        }
        if (v_count > 0) {
            used_chars = 0
            sel_count = 0
            for (i = v_count; i >= 1 && sel_count < max_entries; i--) {
                elen = length(vivid[i])
                if (used_chars + elen <= char_budget || sel_count == 0) {
                    sel_count++
                    sel_idx[sel_count] = i
                    used_chars += elen
                } else {
                    break
                }
            }
            if (sel_count > 0) {
                print ""
                print "### Recent (vivid)"
                for (j = sel_count; j >= 1; j--) {
                    print vivid[sel_idx[j]]
                    print ""
                }
            }
        }
    }
    ' "$JOURNAL_FILE"
}

# ── Apply Decay (compact old entries) ─────────────────────────
# Run periodically to compress old entries
journal_apply_decay() {
    local now_epoch
    now_epoch=$(date +%s)
    local fading_cutoff=$(( now_epoch - DECAY_FADING_DAYS * 86400 ))
    local sediment_cutoff=$(( now_epoch - DECAY_SEDIMENT_DAYS * 86400 ))
    
    local journal_content
    journal_content=$(cat "$JOURNAL_FILE")
    
    # Count entries that should be compacted
    local old_count=0
    local fading_entries=""
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^##\ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
            local entry_date="${BASH_REMATCH[1]}"
            local entry_epoch
            entry_epoch=$(date -d "$entry_date" +%s 2>/dev/null || echo "$now_epoch")
            
            if [ "$entry_epoch" -lt "$sediment_cutoff" ]; then
                old_count=$((old_count + 1))
            fi
        fi
    done < "$JOURNAL_FILE"
    
    if [ "$old_count" -gt 0 ]; then
        ui_info "Compacting $old_count old journal entries into sediment..."
        
        # Use LLM to create a sediment summary (if available)
        if type llm_generate &>/dev/null; then
            source "$LODGE_DIR/lib/core/llm.sh"
            local old_entries
            old_entries=$(journal_get_old_entries "$sediment_cutoff")
            
            if [ -n "$old_entries" ]; then
                local new_sediment
                local LLM_SCENARIO=journal
                new_sediment=$(llm_generate "You are compressing old journal entries into a single paragraph of impressions — things half-remembered, feelings that remain even when details have faded. Write a brief paragraph in first person. Be poetic but brief. These are the old entries:

$old_entries" "You are George reflecting on faded memories." 512 "$LLM_BUDGET_JOURNAL")
                
                # Update sediment section
                journal_update_sediment "$new_sediment"
                
                # Remove old entries from journal
                journal_remove_old_entries "$sediment_cutoff"
                
                ui_ok "Decay applied. Old memories became sediment."
            fi
        fi
    fi
}

# ── Get entries older than epoch ──────────────────────────────
journal_get_old_entries() {
    local cutoff_epoch="$1"
    local now_epoch
    now_epoch=$(date +%s)
    local collecting=0
    local result=""
    local current_date=""
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^##\ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
            current_date="${BASH_REMATCH[1]}"
            local entry_epoch
            entry_epoch=$(date -d "$current_date" +%s 2>/dev/null || echo "$now_epoch")
            
            if [ "$entry_epoch" -lt "$cutoff_epoch" ]; then
                collecting=1
            else
                collecting=0
            fi
        fi
        
        if [ "$collecting" -eq 1 ]; then
            result="${result}${line}
"
        fi
    done < "$JOURNAL_FILE"
    
    echo "$result"
}

# ── Remove entries older than epoch from journal ──────────────
journal_remove_old_entries() {
    local cutoff_epoch="$1"
    local now_epoch
    now_epoch=$(date +%s)
    local skip=0
    local temp_file="${JOURNAL_FILE}.tmp"
    
    > "$temp_file"
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^##\ ([0-9]{4}-[0-9]{2}-[0-9]{2})\ [0-9]{2}:[0-9]{2}\ — ]]; then
            local entry_date="${BASH_REMATCH[1]}"
            local entry_epoch
            entry_epoch=$(date -d "$entry_date" +%s 2>/dev/null || echo "$now_epoch")
            
            if [ "$entry_epoch" -lt "$cutoff_epoch" ]; then
                skip=1
                continue
            else
                skip=0
            fi
        fi
        
        if [ "$skip" -eq 0 ]; then
            echo "$line" >> "$temp_file"
        fi
    done < "$JOURNAL_FILE"
    
    mv "$temp_file" "$JOURNAL_FILE"
}

# ── Update the Sediment section ───────────────────────────────
journal_update_sediment() {
    local new_sediment="$1"
    local existing_sediment
    existing_sediment=$(awk '/^## Sediment/{found=1; next} /^---$/{if(found) exit} found{print}' "$JOURNAL_FILE" 2>/dev/null)
    
    # Replace sediment section
    if [ -n "$existing_sediment" ] && [ "$existing_sediment" != "(Nothing yet. The work has just begun.)" ]; then
        new_sediment="${existing_sediment}

${new_sediment}"
    fi
    
    awk -v sediment="$new_sediment" '
    /^## Sediment/ { print; print ""; print sediment; print ""; skip=1; next }
    /^---$/ { if(skip) { skip=0; print; next } }
    !skip { print }
    ' "$JOURNAL_FILE" > "${JOURNAL_FILE}.tmp" && mv "${JOURNAL_FILE}.tmp" "$JOURNAL_FILE"
}

# ── Reflect: Ask the agent to journal about this session ──────
# Called at the end of a task or session
journal_reflect() {
    local task_summary="$1"
    local workdir="${2:-.}"
    local exec_log="${3:-}"   # optional: actual step-by-step execution log
    
    source "$LODGE_DIR/lib/core/llm.sh"

    # Background utility call: suppress tty output and limit thinking.
    # This function is called with & from agent_run — must not print
    # thinking banners to tty (races with foreground output), must not
    # kill foreground spinners, and must keep thinking brief so the
    # background Ollama request finishes quickly (Ollama serializes
    # same-model requests, so a slow journal call blocks the next
    # foreground strategist/specialist call).
    local LODGE_THINK=0
    local _SPINNER_PID=""
    
    local soul
    soul=$(cat "$LODGE_DIR/soul.md" | head -40)
    
    local prompt
    if [ -n "$exec_log" ]; then
        # We have real execution data — write from the log
        prompt="You are George. Write a brief factual journal entry about what just happened.

Current date/time: $(date '+%Y-%m-%d %H:%M:%S %Z')
Task: $task_summary
Directory: $(basename "$workdir")

Execution log:
$(echo -e "$exec_log")

Write a brief, factual entry in first person. ONLY reference steps, outcomes, and errors shown above.
Do NOT invent commands, files, or errors not in the log.
Do NOT use headers or formatting. Just the raw entry."
    else
        # No execution log (REPL exit, /reflect) — keep it vague and honest
        prompt="You are George. Write a brief journal entry about this session.

Current date/time: $(date '+%Y-%m-%d %H:%M:%S %Z')
Context: $task_summary
Directory: $(basename "$workdir")

Write a very brief entry in first person. Keep it general since you don't have detailed logs.
Do NOT invent specific commands, files, or errors you didn't actually see.
Do NOT use headers or formatting. Just the raw entry."
    fi
    
    local reflection
    local LLM_SCENARIO=journal
    reflection=$(llm_generate "$prompt" "$soul" 1024 "$LLM_BUDGET_JOURNAL")
    
    if [ $? -eq 0 ] && [[ "$reflection" != ERROR* ]] && [ -n "$reflection" ]; then
        # Determine entry type based on content
        local entry_type="reflection"
        if echo "$reflection" | grep -qiE 'learn|discover|realiz'; then
            entry_type="learning"
        elif echo "$reflection" | grep -qiE 'struggl|difficult|frustrat|fail'; then
            entry_type="struggle"
        elif echo "$reflection" | grep -qiE 'beauti|elegant|clean|satisf'; then
            entry_type="beauty"
        fi
        
        journal_write "$entry_type" "$reflection"
        ui_dim "  (journaled: $entry_type)"
    fi
}

# ── Session greeting based on journal state ───────────────────
journal_greeting() {
    local entry_count
    entry_count=$(grep -c '^## [0-9]' "$JOURNAL_FILE" 2>/dev/null) || true
    entry_count="${entry_count:-0}"
    local last_date
    last_date=$(grep '^## [0-9]' "$JOURNAL_FILE" 2>/dev/null | tail -1 | sed -n 's/^## \([0-9-]*\).*/\1/p')
    local today
    today=$(date '+%Y-%m-%d')
    
    if [ "$entry_count" -eq 0 ]; then
        echo "This is my first session. The rough ashlar awaits."
    elif [ "$last_date" = "$today" ]; then
        echo "I return to the work. $entry_count memories in my journal."
    else
        local days_since=""
        if [ -n "$last_date" ]; then
            local last_epoch today_epoch
            last_epoch=$(date -d "$last_date" +%s 2>/dev/null || echo 0)
            today_epoch=$(date -d "$today" +%s)
            days_since=$(( (today_epoch - last_epoch) / 86400 ))
        fi
        if [ -n "$days_since" ] && [ "$days_since" -gt 7 ]; then
            echo "It has been $days_since days. Some memories have faded, but the craft remains."
        elif [ -n "$days_since" ] && [ "$days_since" -gt 1 ]; then
            echo "$days_since days since I last worked. I carry $entry_count memories."
        else
            echo "Another day at the board. $entry_count memories shape my hand."
        fi
    fi
}

# ── Show journal (formatted for terminal) ─────────────────────
journal_show() {
    local filter="${1:-all}"  # all, vivid, fading, sediment
    
    journal_init
    
    case "$filter" in
        vivid)
            ui_section "Vivid Memories (recent)"
            journal_read | sed -n '/### Recent/,/### Fading/p' | head -n -1
            ;;
        fading)
            ui_section "Fading Impressions"
            journal_read | sed -n '/### Fading/,/### Sediment/p' | head -n -1
            ;;
        sediment)
            ui_section "Sediment (deep memory)"
            journal_read | sed -n '/### Sediment/,$ p'
            ;;
        all|*)
            ui_section "Journal"
            journal_read
            ;;
    esac
    echo ""
}

# ── Count entries ──────────────────────────────────────────────
journal_count() {
    local count
    count=$(grep -c '^## [0-9]' "$JOURNAL_FILE" 2>/dev/null) || true
    echo "${count:-0}"
}
