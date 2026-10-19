#!/bin/bash
# ── George: Sovereign POSIX Conversational Chat Runner ────────────────
# Provides a fast, lightweight conversational chat loop (up to 5 turns)
# with safe read-only tools. Usable from both CLI (/chat) and Web UI.
#
# Usage:
#   bash lib/core/chat_loop.sh "<prompt>" [session_file] [max_turns]

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="${LODGE_DIR:-$(cd "$_SCRIPT_DIR/../.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/web.sh" 2>/dev/null || true

endpoints_init 2>/dev/null || true
LLM_URL="${ACTIVE_ENDPOINT_URL:-http://127.0.0.1:8080}"
LLM_ENDPOINT="${LLM_URL%/}/v1/chat/completions"

PROMPT="${1:-}"
SESSION_FILE="${2:-$GEORGE_DIR/workspaces/web_session.jsonl}"
MAX_TURNS="${3:-5}"

[ -z "$PROMPT" ] && { echo "Error: prompt required" >&2; exit 1; }

mkdir -p "$(dirname "$SESSION_FILE")" 2>/dev/null || true

# Execute read-only chat tools
_exec_tool() {
    local name="$1" args_json="$2"
    case "$name" in
        web_fetch)
            local url
            url=$(echo "$args_json" | jq -r '.url // empty' 2>/dev/null)
            [ -z "$url" ] && { echo "Error: URL is required"; return; }
            local content
            content=$(web_fetch "$url" 2>/dev/null || echo "")
            if [ -z "$content" ]; then
                echo "Page returned empty content or fetch failed."
            elif [ ${#content} -gt 6000 ]; then
                printf "%s...\n[Content truncated at 6000 characters]" "${content:0:6000}"
            else
                printf "%s" "$content"
            fi
            ;;
        web_search)
            local query count
            query=$(echo "$args_json" | jq -r '.query // empty' 2>/dev/null)
            count=$(echo "$args_json" | jq -r '.count // 5' 2>/dev/null)
            [ -z "$query" ] && { echo "Error: query is required"; return; }
            local results
            results=$(web_search "$query" "$count" 2>/dev/null || echo "")
            [ -z "$results" ] && echo "No search results found." || echo "$results"
            ;;
        datetime_now)
            date '+%Y-%m-%d %H:%M:%S %Z (%A)'
            ;;
        file_read)
            local path start max_lines
            path=$(echo "$args_json" | jq -r '.path // empty' 2>/dev/null)
            start=$(echo "$args_json" | jq -r '.start_line // 1' 2>/dev/null)
            max_lines=$(echo "$args_json" | jq -r '.max_lines // 100' 2>/dev/null)
            [ -z "$path" ] && { echo "Error: path is required"; return; }
            local target_path="$LODGE_DIR/$path"
            [ ! -f "$target_path" ] && { echo "File not found: $path"; return; }
            sed -n "${start},$((start + max_lines - 1))p" "$target_path" | awk -v s="$start" '{printf "%4d: %s\n", s + NR - 1, $0}'
            ;;
        file_grep)
            local pattern sub_path
            pattern=$(echo "$args_json" | jq -r '.pattern // empty' 2>/dev/null)
            sub_path=$(echo "$args_json" | jq -r '.path // "."' 2>/dev/null)
            [ -z "$pattern" ] && { echo "Error: pattern is required"; return; }
            (cd "$LODGE_DIR" && grep -rn -m 20 --exclude-dir=.git --exclude-dir=target "$pattern" "$sub_path" 2>/dev/null || echo "No matches found.")
            ;;
        dir_list)
            local rel_path
            rel_path=$(echo "$args_json" | jq -r '.path // "."' 2>/dev/null)
            (cd "$LODGE_DIR/$rel_path" && ls -F 2>/dev/null | head -50 || echo "Error listing directory")
            ;;
        recall_query)
            local q
            q=$(echo "$args_json" | jq -r '.query // empty' 2>/dev/null)
            [ -z "$q" ] && { echo "Error: query is required"; return; }
            local rdb="$GEORGE_DIR/recall.db"
            if [ -f "$rdb" ]; then
                sqlite3 -json "$rdb" "SELECT section, substr(content, 1, 300) AS snippet FROM chunks_fts WHERE chunks_fts MATCH '$(echo "$q" | sed "s/'/''/g")' LIMIT 3;" 2>/dev/null || echo "No memory recollections found."
            else
                echo "Recall database not initialized."
            fi
            ;;
        *)
            echo "Tool '$name' not recognized."
            ;;
    esac
}

SYS_PROMPT="You are George, a thoughtful and grounded digital craftsman carrying the discipline of Washington, the wit of Franklin, and the precision of Adam Smith. Respond with quiet competence, intellectual dignity, and direct clarity without sci-fi tropes or fluff. You possess safe read-only tools to browse or fetch the web (web_search, web_fetch), inspect the workspace repository (file_read, file_grep, dir_list), query historical recall memory (recall_query), and check the current date/time (datetime_now). When searching the web for news, facts, or reference material, never stop at snippet previews—always follow up by calling web_fetch on the top 1-3 URLs to read the actual content, and always cite clickable markdown links [Source Title](url)."

CHAT_TOOLS='[
  {"type":"function","function":{"name":"web_fetch","description":"Fetch and extract readable text from a URL.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
  {"type":"function","function":{"name":"web_search","description":"Search the live web for facts or events.","parameters":{"type":"object","properties":{"query":{"type":"string"},"count":{"type":"integer"}},"required":["query"]}}},
  {"type":"function","function":{"name":"datetime_now","description":"Get current local date and time.","parameters":{"type":"object","properties":{}}}},
  {"type":"function","function":{"name":"file_read","description":"Read lines from a workspace file.","parameters":{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer"},"max_lines":{"type":"integer"}},"required":["path"]}}},
  {"type":"function","function":{"name":"file_grep","description":"Search text pattern in workspace files.","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"}},"required":["pattern"]}}},
  {"type":"function","function":{"name":"dir_list","description":"List files and directories in a given path.","parameters":{"type":"object","properties":{"path":{"type":"string"}}}}},
  {"type":"function","function":{"name":"recall_query","description":"Query memory recall and knowledge base.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}}
]'

# Build messages array from recent session history + current prompt
MESSAGES=$(jq -n --arg sys "$SYS_PROMPT" '[{"role":"system","content":$sys}]')

if [ -f "$SESSION_FILE" ]; then
    HIST=$(tail -n 8 "$SESSION_FILE" 2>/dev/null | jq -s '[.[] | select(.role == "user" or .role == "assistant") | {role: .role, content: (.content // "" | if length > 2000 then .[0:2000] + "..." else . end)}]' 2>/dev/null || echo "[]")
    if [ "$HIST" != "[]" ] && [ -n "$HIST" ]; then
        MESSAGES=$(jq -c --argjson hist "$HIST" '. + $hist' <<< "$MESSAGES")
    fi
fi

MESSAGES=$(jq -c --arg user "$PROMPT" '. + [{"role":"user","content":$user}]' <<< "$MESSAGES")

FINAL_REPLY=""

for ((turn=1; turn<=MAX_TURNS; turn++)); do
    PAYLOAD=$(jq -n \
        --argjson msgs "$MESSAGES" \
        --argjson tools "$CHAT_TOOLS" \
        '{messages: $msgs, tools: $tools, temperature: 0.7, top_p: 0.95, max_tokens: 4096}')

    RESP=$(curl -s --max-time 120 "$LLM_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" 2>/dev/null || true)

    CHOICE=$(echo "$RESP" | jq -c '.choices[0] // empty' 2>/dev/null || true)
    [ -z "$CHOICE" ] && break

    CONTENT=$(echo "$CHOICE" | jq -r '.message.content // empty' 2>/dev/null || true)
    TOOL_CALLS=$(echo "$CHOICE" | jq -c '.message.tool_calls // empty' 2>/dev/null || true)

    if [ -n "$CONTENT" ]; then
        FINAL_REPLY="$CONTENT"
    fi

    # Append assistant choice to message history
    MESSAGES=$(jq -c --argjson msg "$(echo "$CHOICE" | jq '.message')" '. + [$msg]' <<< "$MESSAGES")

    if [ -z "$TOOL_CALLS" ] || [ "$TOOL_CALLS" = "null" ] || [ "$TOOL_CALLS" = "[]" ]; then
        break
    fi

    # Execute tool calls
    TOOL_COUNT=$(echo "$TOOL_CALLS" | jq 'length' 2>/dev/null || echo 0)
    for ((tc=0; tc<TOOL_COUNT; tc++)); do
        TC_OBJ=$(echo "$TOOL_CALLS" | jq -c ".[$tc]")
        TC_ID=$(echo "$TC_OBJ" | jq -r '.id')
        T_NAME=$(echo "$TC_OBJ" | jq -r '.function.name')
        T_ARGS=$(echo "$TC_OBJ" | jq -r '.function.arguments')

        T_RESULT=$(_exec_tool "$T_NAME" "$T_ARGS")

        # Append tool result to messages
        MESSAGES=$(jq -c \
            --arg id "$TC_ID" \
            --arg name "$T_NAME" \
            --arg content "$T_RESULT" \
            '. + [{"role":"tool","tool_call_id":$id,"name":$name,"content":$content}]' <<< "$MESSAGES")
    done
done

# Output final response
if [ -n "$FINAL_REPLY" ]; then
    echo "$FINAL_REPLY"

    # Append to session file
    NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    USER_REC=$(jq -n --arg p "$PROMPT" --arg ts "$NOW_TS" '{id: ("u_" + (now|tostring)), role: "user", content: $p, timestamp: $ts}')
    ASST_REC=$(jq -n --arg r "$FINAL_REPLY" --arg ts "$NOW_TS" '{id: ("a_" + (now|tostring)), role: "assistant", content: $r, timestamp: $ts}')
    echo "$USER_REC" >> "$SESSION_FILE" 2>/dev/null || true
    echo "$ASST_REC" >> "$SESSION_FILE" 2>/dev/null || true
else
    echo "I was unable to complete the conversation."
fi
