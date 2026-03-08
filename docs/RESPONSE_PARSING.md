# Response Parsing Engine

> How raw LLM output is parsed, sanitized, and transformed into executable commands, code blocks, file writes, and displayable text.

---

## Table of Contents

- [Design Philosophy](#design-philosophy)
- [The Parsing Pipeline](#the-parsing-pipeline)
- [LLM Spacing Artifact Repair](#llm-spacing-artifact-repair)
- [Code Block Extraction](#code-block-extraction)
- [Slash Command Extraction](#slash-command-extraction)
- [File Extraction and Writing](#file-extraction-and-writing)
- [Response Processing Orchestrator](#response-processing-orchestrator)
- [Agent-Specific Parsing](#agent-specific-parsing)
- [Thinking Tag Stripping](#thinking-tag-stripping)
- [Troubleshooting](#troubleshooting)
- [Key Functions Reference](#key-functions-reference)

---

## Design Philosophy

LLMs produce messy output. They hallucinate formatting, merge words with file extensions, add phantom shell quotes, and generate URLs that don't exist. The parsing engine is a multi-pass cleanup pipeline that transforms raw model output into structured, executable artifacts.

The core principle is **tolerance over rejection** — the parser fixes what it can rather than failing on malformed output. This is essential when running small (4B parameter) models that frequently produce imperfect formatting.

---

## The Parsing Pipeline

Raw LLM output flows through these stages:

```
Raw LLM Response
     │
     ├─ Strip <think>...</think> blocks (if present)
     │
     ├─ Fix spacing artifacts (5 passes)
     │  ├─ Extension spacing     (.mdContent → .md Content)
     │  ├─ Dash separators       (.md---# → .md #)
     │  ├─ Fence spacing         (text```code → text ```code)
     │  ├─ Asterisk spacing      (text**bold**text → text **bold** text)
     │  └─ URL protection        (preserve URLs during all passes)
     │
     ├─ Extract artifacts
     │  ├─ Code blocks           (```bash ... ```)
     │  ├─ Slash commands        (/web search, /save, etc.)
     │  └─ File definitions      (```lang\n# filepath: path\n...)
     │
     └─ Dispatch
        ├─ Execute bash blocks   (with allowlist + confirmation)
        ├─ Dispatch commands      (through commands_dispatch)
        └─ Write files            (with diff preview + confirmation)
```

---

## LLM Spacing Artifact Repair

### The Problem

Small models frequently merge tokens where spaces should exist. Common artifacts:

```
.mdThis is content          →  .md This is content
.txtContent here            →  .txt Content here
text```bash                 →  text ```bash
word**bold**word            →  word **bold** word
result.md---# Section       →  result.md # Section
```

### `tools_fix_llm_spacing()` — The Master Fixer

Applies all sub-fixers in sequence:

```bash
tools_fix_llm_spacing() {
    local text="$1"
    text=$(tools_fix_ext_spacing "$text")
    text=$(tools_fix_dash_separator "$text")
    text=$(tools_fix_fence_spacing "$text")
    text=$(tools_fix_asterisk_spacing "$text")
    printf '%s' "$text"
}
```

### Extension Spacing (`tools_fix_ext_spacing`)

This is the most complex fixer because it must handle 150+ file extensions without false positives.

**The URL Protection Pattern**: URLs contain dots followed by TLDs (`.com`, `.org`) that look like file extensions. To prevent `.comContent` from being "fixed" when it's actually `example.com/Content`:

```bash
# Step 1: Extract and replace URLs with placeholders
local -a urls=()
local i=0
while [[ "$text" =~ (https?://[^[:space:]]+) ]]; do
    urls+=("${BASH_REMATCH[1]}")
    text="${text//${BASH_REMATCH[1]}/__LODGE_URL_${i}__}"
    ((i++))
done

# Step 2: Apply extension fixes safely
# ... fix spacing around .md, .txt, .py, etc ...

# Step 3: Restore URLs
for ((j=0; j<${#urls[@]}; j++)); do
    text="${text//__LODGE_URL_${j}__/${urls[j]}}"
done
```

**Bash Technique — Array-Based Placeholders**: The URL protection uses a numbered array (`__LODGE_URL_0__`, `__LODGE_URL_1__`, etc.) rather than a single placeholder. This correctly handles responses containing multiple URLs.

**Longest-Match-First Ordering**: Extensions are tested in length order (`.jsonl` before `.json`, `.yaml` before `.ya`) to prevent partial matches. If `.json` were tested first, `.jsonlContent` would become `.json lContent` instead of `.jsonl Content`.

### Fence Spacing (`tools_fix_fence_spacing`)

Detects missing whitespace before and after code fences:

```bash
# Before: word```bash → word ```bash
# After:  ```word → ``` word (only outside code blocks)
```

Uses an **awk state machine** to track whether we're inside a code block, because fences inside code blocks are literal content and must not be modified:

```bash
tools_fix_fence_spacing() {
    echo "$1" | awk '
    /^```/ { in_block = !in_block }
    !in_block {
        # Fix pre-fence: non-space before ```
        gsub(/([^ \t\n])```/, "\\1 ```")
        # Fix post-fence: ``` followed by non-space non-newline
        gsub(/```([^ \t\n`])/, "``` \\1")
    }
    { print }
    '
}
```

### Asterisk Spacing (`tools_fix_asterisk_spacing`)

The trickiest fixer — must distinguish between:
- `**bold text**` (valid markdown, preserve)
- `word**bold**word` (missing spaces, fix)
- `**` inside code blocks (literal, don't touch)

Uses **pair counting** to find matched bold markers:

```bash
# Count ** occurrences to determine if they're paired
# Odd count = unterminated bold (don't touch)
# Even count = paired markers (fix spacing around pairs)
```

---

## Code Block Extraction

### `tools_extract_bash()`

Extracts executable bash/shell code blocks from LLM responses:

```bash
tools_extract_bash() {
    local text="$1"
    echo "$text" | awk '
    /^```(bash|sh|shell)?[[:space:]]*$/ {
        in_block = 1
        next
    }
    /^```[[:space:]]*$/ && in_block {
        in_block = 0
        next
    }
    in_block { print }
    '
}
```

**Tolerance features**:
- Accepts ```` ```bash ````, ```` ```sh ````, ```` ```shell ````, or bare ```` ``` ```` as block openers
- Handles unterminated blocks (no closing ```` ``` ````) by treating EOF as block end
- Ignores non-bash blocks (```` ```python ````, ```` ```json ````) — those go through file extraction instead
- Strips trailing whitespace from the language tag

### Context-Aware Extraction

The extractor is context-aware — it skips code blocks that are inside explanatory text:

```
Here's how to do it:
```bash
echo "hello"        ← Extracted (standalone code block)
```

The command `echo "hello"` prints...  ← NOT extracted (inline code)
```

The heuristic: if a ```` ``` ```` block is preceded by prose and followed by more prose on the same line, it's inline and skipped.

---

## Slash Command Extraction

### `tools_extract_slash_commands()`

Extracts lines starting with `/` that are outside code blocks:

```bash
tools_extract_slash_commands() {
    local text="$1"
    echo "$text" | awk '
    /^```/ { in_block = !in_block; next }
    !in_block && /^\/[a-z]/ { print }
    '
}
```

**Why exclude code blocks?** An LLM response explaining how to use commands will contain `/save example.txt` inside a code block as documentation, not as an instruction to execute. Only top-level `/commands` are actionable.

### Agent-Specific: Multi-Command Splitting

During agent execution, the specialist sometimes returns multiple commands on one line:

```
/web search "rust async" /save results.md
```

The agent loop splits on the first space-slash boundary:

```bash
# Keep only the first command
cmd=$(echo "$specialist_output" | head -1 | sed 's/ \/.*//')
```

This prevents the agent from executing a chain of commands blindly — each command gets its own evaluation cycle.

---

## File Extraction and Writing

### `tools_extract_files()`

Parses the common LLM pattern of defining files inside code blocks:

````
```rust
// filepath: src/main.rs
fn main() {
    println!("Hello!");
}
```
````

The parser recognizes these filepath markers:
- `// filepath: path` (C-style comments)
- `# filepath: path` (Shell/Python comments)
- `<!-- filepath: path -->` (HTML comments)
- `// file: path` (alternate form)

```bash
tools_extract_files() {
    local text="$1"
    echo "$text" | awk '
    /^```/ {
        if (in_block && filepath != "") {
            print "FILE:" filepath
            print content
            print "ENDFILE"
        }
        in_block = !in_block
        filepath = ""
        content = ""
        next
    }
    in_block && /^(\/\/|#|<!--)\s*(file|filepath):/ {
        # Extract path from comment
        gsub(/^[^:]+:\s*/, "")
        gsub(/\s*-->.*/, "")
        filepath = $0
        next
    }
    in_block {
        content = content $0 "\n"
    }
    '
}
```

### `tools_write_file()` — Safe File Writing

Before writing, the function applies multiple safety checks:

```
1. Sanitize filename (tools_sanitize_filename)
   - Strip quotes: "file.txt" → file.txt
   - Spaces to hyphens: my file.txt → my-file.txt
   - Remove special chars: file@#$.txt → file.txt

2. Normalize path (realpath -m)
   - Resolve ../../ traversals
   - Check result stays within workdir (prevents path traversal attacks)

3. Permission check
   - LODGE_PERMISSION=0: always ask
   - LODGE_PERMISSION=1: ask if overwriting existing file
   - LODGE_PERMISSION=2: auto-approve all writes

4. Diff preview (if file exists)
   - Show unified diff between existing and new content
   - User confirms before overwriting

5. Create parent directories (mkdir -p)

6. Write file (printf '%s' "$content" > "$path")
```

**Security Note**: The `realpath -m` check prevents an LLM from writing to `/etc/passwd` or `../../.bashrc` by resolving the path and verifying it starts with the current working directory.

---

## Response Processing Orchestrator

### `tools_process_response()`

The master function that coordinates all extraction and execution:

```bash
tools_process_response() {
    local response="$1"

    # Phase 1: Fix spacing artifacts
    response=$(tools_fix_llm_spacing "$response")

    # Phase 2: Extract and execute bash blocks
    local bash_code
    bash_code=$(tools_extract_bash "$response")
    if [[ -n "$bash_code" ]]; then
        tools_exec_bash "$bash_code"
    fi

    # Phase 3: Extract and write files
    local files
    files=$(tools_extract_files "$response")
    while IFS= read -r line; do
        if [[ "$line" == FILE:* ]]; then
            filepath="${line#FILE:}"
            # Read content until ENDFILE marker
            content=""
            while IFS= read -r fline && [[ "$fline" != "ENDFILE" ]]; do
                content+="$fline"$'\n'
            done
            tools_write_file "$filepath" "$content"
        fi
    done <<< "$files"

    # Phase 4: Extract and dispatch slash commands
    local commands
    commands=$(tools_extract_slash_commands "$response")
    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        commands_dispatch "$cmd"
    done <<< "$commands"
}
```

---

## Agent-Specific Parsing

The agent loop (`lib/agent.sh`) applies additional parsing on top of the standard pipeline.

### Quote Normalization

The specialist LLM sometimes adds shell quotes around arguments that confuse the command dispatcher:

```
/web search "how to install rust"    ← Good
/web search 'how to install rust'    ← Also good
/web search \"how to install rust\"  ← Bad: escaped quotes from JSON context
/save "my-file.txt" "content"        ← Bad: quotes around filename
```

The agent strips problematic quotes before dispatch:

```bash
# Remove escaped quotes (JSON artifacts)
cmd="${cmd//\\\"/}"

# Remove quotes around filenames (first argument after command)
cmd=$(echo "$cmd" | sed 's/^\(\/[a-z]* \)"\([^"]*\)"/\1\2/')
```

### Web Search Trimming

LLM-generated search queries are often too verbose:

```
/web search "how do I install the Rust programming language on Ubuntu Linux"
```

The agent has two trimming modes:

**Loose mode** (preserves search operators):
```bash
# Remove filler words but keep site:, -exclude, "exact phrase"
query=$(echo "$query" | sed '
    s/\bhow\b//gi
    s/\bdo I\b//gi
    s/\bthe\b//gi
    s/\bprogramming language\b//gi
')
# Result: "install Rust Ubuntu Linux"
```

**Tight mode** (aggressive — for retry after empty results):
```bash
# Strip everything except nouns and proper names
# Keep: Rust, Ubuntu, install
# Remove: how, do, I, the, on, programming, language
```

### URL Sanitization

The agent enforces single-URL for commands that fetch pages:

```bash
# LLM generated: /web fetch https://rust-lang.org https://docs.rs
# Agent keeps:   /web fetch https://rust-lang.org
cmd=$(echo "$cmd" | sed 's/\(https\?:\/\/[^ ]*\).*/\1/')
```

### Smart Routing (`_agent_smart_route`)

Pre-execution heuristic that fixes common LLM routing errors without another LLM call:

```
LLM says:                        Smart route corrects:
─────────────────────────────    ────────────────────────
/read https://example.com     →  /web fetch https://example.com
/web fetch ./local-file.txt   →  /read ./local-file.txt
/read image.png               →  /vision image.png
```

The detection logic:

```bash
_agent_smart_route() {
    local cmd="$1"

    # URL used with /read? Reroute to /web
    if [[ "$cmd" =~ ^/read\ +https?:// ]]; then
        local url="${cmd#/read }"
        echo "/web fetch $url"
        return
    fi

    # Local file used with /web? Reroute to /read
    if [[ "$cmd" =~ ^/web\ +fetch\ + ]] && [[ ! "$cmd" =~ https?:// ]]; then
        local path="${cmd#/web fetch }"
        if [[ -f "$path" ]]; then
            echo "/read $path"
            return
        fi
    fi

    # Image file used with /read? Reroute to /vision
    if [[ "$cmd" =~ ^/read\ +.*\.(png|jpg|jpeg|gif|webp)$ ]]; then
        local path="${cmd#/read }"
        echo "/vision $path"
        return
    fi

    echo "$cmd"  # No correction needed
}
```

**Bash Technique — Regex with `=~`**: The `[[ "$cmd" =~ pattern ]]` operator performs regex matching in-place. Combined with `${cmd#prefix}` parameter expansion to extract the matched portion, this avoids spawning `grep` or `sed` subprocesses for simple pattern detection.

---

## Thinking Tag Stripping

### Post-Response Cleanup

After the streaming loop captures the full response, thinking tags are stripped from the captured text:

```bash
# Recursive sed: remove <think>...</think> including multi-line content
response=$(echo "$response" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
```

**Bash Technique — Recursive Sed**: This single-line sed command is deceptively powerful:

```
:a        — Define label 'a'
N         — Append next line to pattern space (now holds 2+ lines)
$!ba      — If not last line, branch to 'a' (loop: accumulate ALL lines)
s/...//g  — Now pattern space holds the entire file; do global replace
```

Without the `:a;N;$!ba` preamble, sed operates line-by-line and can't match multi-line `<think>...</think>` blocks. This technique loads the entire file into the pattern space first.

**Warning**: This approach has O(n²) behavior on very large inputs because sed accumulates the entire content. For typical LLM responses (< 10KB), it's fine. For huge responses, an awk-based approach would be better.

---

## Troubleshooting

### Commands Not Being Extracted

1. **Code block wrapping**: If a `/command` is inside ```` ```bash ... ``` ````, it's treated as code, not a command. The LLM should put executable commands outside code blocks.
2. **Leading whitespace**: `/web search` with leading spaces isn't detected. Trim before parsing.
3. **Non-ASCII slash**: Some models output a Unicode fraction slash (⁄) instead of ASCII `/`. The parser only matches ASCII.

### File Extensions Not Being Split

1. **Unknown extension**: The extension list has 150+ entries but custom extensions might be missing. Add to `_TOOLS_EXTENSIONS`.
2. **URL false positive**: Check if the URL protection is correctly saving and restoring URLs.
3. **Code block context**: Extension splitting is disabled inside code blocks (correct behavior).

### Shell Quotes Breaking Commands

1. **Double-escaped quotes**: `\"` appearing in commands usually means the response was JSON-escaped. The quote normalizer should strip these.
2. **Single quotes in search queries**: `/web search 'query'` — some dispatchers don't handle single quotes. The agent pre-strips them.

### Smart Route Mis-Correcting

Smart routing can be wrong when:
- A URL-like string is actually a local file (`./http-server.conf`)
- A `.png` file should be read as text (e.g., examining PNG headers)

The `_SMART_ROUTE_REROUTED=1` flag is set when a correction occurs, allowing downstream code to detect and undo if the routed command fails.

---

## Key Functions Reference

| Function | File | Purpose |
|----------|------|---------|
| `tools_fix_llm_spacing()` | lib/tools.sh | Master spacing fixer (all 5 passes) |
| `tools_fix_ext_spacing()` | lib/tools.sh | Fix extension-word merging |
| `tools_fix_fence_spacing()` | lib/tools.sh | Fix code fence spacing |
| `tools_fix_asterisk_spacing()` | lib/tools.sh | Fix bold/italic marker spacing |
| `tools_fix_dash_separator()` | lib/tools.sh | Fix `.md---#` artifacts |
| `tools_extract_bash()` | lib/tools.sh | Extract bash code blocks |
| `tools_extract_slash_commands()` | lib/tools.sh | Extract actionable /commands |
| `tools_extract_files()` | lib/tools.sh | Extract file definitions from code blocks |
| `tools_write_file()` | lib/tools.sh | Safe file writing with diff + confirmation |
| `tools_exec_bash()` | lib/tools.sh | Execute bash with allowlist + permission |
| `tools_process_response()` | lib/tools.sh | Master: extract + execute all artifacts |
| `tools_sanitize_filename()` | lib/tools.sh | Clean filenames for safe writing |
| `tools_read_file()` | lib/tools.sh | Read file with line limit |
| `tools_expand_inline_read()` | lib/tools.sh | Expand `/read path` to file contents |
| `_agent_smart_route()` | lib/agent.sh | Fix LLM routing errors pre-execution |

---

*Previous: [Streaming Pipeline](STREAMING_PIPELINE.md) | Next: [API Layer & Cloud Providers](API_AND_PROVIDERS.md)*
