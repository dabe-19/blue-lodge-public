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

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

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

# ── Read Journal with Decay Applied ──────────────────────────
# Returns a filtered view: recent entries in full, older ones compressed
journal_read() {
    local max_tokens="${1:-800}"  # rough token budget for journal context
    
    journal_init
    
    local now_epoch
    now_epoch=$(date +%s)
    local vivid_cutoff=$(( now_epoch - DECAY_VIVID_DAYS * 86400 ))
    local fading_cutoff=$(( now_epoch - DECAY_FADING_DAYS * 86400 ))
    local sediment_cutoff=$(( now_epoch - DECAY_SEDIMENT_DAYS * 86400 ))
    
    local output=""
    local vivid_entries=""
    local fading_summaries=""
    local current_entry=""
    local current_date=""
    local current_type=""
    local in_entry=0
    local in_header=1  # skip the header section
    
    while IFS= read -r line; do
        # Detect entry headers: ## YYYY-MM-DD HH:MM — type
        if [[ "$line" =~ ^##\ ([0-9]{4}-[0-9]{2}-[0-9]{2})\ [0-9]{2}:[0-9]{2}\ —\ (.+)$ ]]; then
            # Process previous entry if any
            if [ -n "$current_entry" ] && [ -n "$current_date" ]; then
                local entry_epoch
                entry_epoch=$(date -d "$current_date" +%s 2>/dev/null || echo "$now_epoch")
                
                if [ "$entry_epoch" -ge "$vivid_cutoff" ]; then
                    vivid_entries="${vivid_entries}${current_entry}
"
                elif [ "$entry_epoch" -ge "$fading_cutoff" ]; then
                    # Compress to one line
                    local summary
                    summary=$(echo "$current_entry" | grep -v '^##' | grep -v '^$' | head -1)
                    fading_summaries="${fading_summaries}- [$current_date] $current_type: ${summary:0:80}
"
                fi
                # Older than fading: skip (it's sediment)
            fi
            
            # Start new entry
            current_date="${BASH_REMATCH[1]}"
            current_type="${BASH_REMATCH[2]}"
            current_entry="$line"
            in_entry=1
            in_header=0
        elif [ "$in_entry" -eq 1 ]; then
            current_entry="${current_entry}
$line"
        fi
    done < "$JOURNAL_FILE"
    
    # Process final entry
    if [ -n "$current_entry" ] && [ -n "$current_date" ]; then
        local entry_epoch
        entry_epoch=$(date -d "$current_date" +%s 2>/dev/null || echo "$now_epoch")
        
        if [ "$entry_epoch" -ge "$vivid_cutoff" ]; then
            vivid_entries="${vivid_entries}${current_entry}
"
        elif [ "$entry_epoch" -ge "$fading_cutoff" ]; then
            local summary
            summary=$(echo "$current_entry" | grep -v '^##' | grep -v '^$' | head -1)
            fading_summaries="${fading_summaries}- [$current_date] $current_type: ${summary:0:80}
"
        fi
    fi
    
    # Build output with decay layers
    output="--- JOURNAL (living memory) ---"
    
    if [ -n "$vivid_entries" ]; then
        output="$output

### Recent (vivid)
$vivid_entries"
    fi
    
    if [ -n "$fading_summaries" ]; then
        output="$output

### Fading impressions
$fading_summaries"
    fi
    
    # Read sediment section from file
    local sediment
    sediment=$(awk '/^## Sediment/{found=1; next} /^---$/{if(found) exit} found{print}' "$JOURNAL_FILE" 2>/dev/null)
    if [ -n "$sediment" ] && [ "$sediment" != "(Nothing yet. The work has just begun.)" ]; then
        output="$output

### Sediment (deep memory)
$sediment"
    fi
    
    echo "$output"
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
            source "$LODGE_DIR/lib/llm.sh"
            local old_entries
            old_entries=$(journal_get_old_entries "$sediment_cutoff")
            
            if [ -n "$old_entries" ]; then
                local new_sediment
                new_sediment=$(llm_generate "You are compressing old journal entries into a single paragraph of impressions — things half-remembered, feelings that remain even when details have faded. Write in first person. Be poetic but brief (3-5 sentences). These are the old entries:

$old_entries" "You are George reflecting on faded memories." 256)
                
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
    
    source "$LODGE_DIR/lib/llm.sh"
    
    local soul
    soul=$(cat "$LODGE_DIR/soul.md" | head -40)
    
    local prompt="You are George. You just completed some work. Write a specific, factual journal entry.

What you did: $task_summary
Working directory: $workdir

Write a journal entry in first person (2-5 sentences). Focus on:
- What specific steps you completed and which ones failed
- What exact commands or tools you used and their outcomes
- What specific errors you encountered and why they happened
- What you would do differently next time

Be SPECIFIC and FACTUAL. Name the exact commands, files, and errors.
Do NOT write poetry or philosophy. This journal helps you avoid repeating mistakes.
Do NOT use headers or formatting. Just the raw entry."
    
    local reflection
    reflection=$(llm_generate "$prompt" "$soul" 256)
    
    if [ $? -eq 0 ] && [[ "$reflection" != ERROR* ]]; then
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
    last_date=$(grep '^## [0-9]' "$JOURNAL_FILE" 2>/dev/null | tail -1 | grep -oP '^## \K[0-9-]+' || echo "")
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
