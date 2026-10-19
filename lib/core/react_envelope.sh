#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  lib/core/react_envelope.sh — Tool Result Envelope (Refinement P2.3)
# ═══════════════════════════════════════════════════════════════════════
#  Every tool observation is normalised into one envelope before the
#  ReAct loop reasons about it:
#
#    {ok, exit, error_class, duration_ms, data, artifacts}
#
#  Success/failure is decided by the exit code plus a small set of
#  *strong* signals. A stray "ERROR" substring or a Python
#  DeprecationWarning on stderr must never flip a successful call into a
#  failure (observed in live Discord runs).
#
#  error_class ∈ TIMEOUT BLOCKED NOT_FOUND RATE_LIMIT SYNTAX DEPENDENCY
#                CRASH EMPTY   ("" when ok)
#
#  Public API:
#    react_envelope_clean     <text>                     → cleaned text
#    react_envelope_classify  <exit> <text> [tool]       → class or ""
#    react_envelope_build     <tool> <exit> <dur_ms> <text> [artifact...]
#    react_envelope_render    <envelope_json>            → model-facing text
#    react_envelope_url_domain <url>                     → host w/o www.
#    react_envelope_failed_domain_record <session_dir> <domain> <class>
#    react_envelope_failed_domain_check  <session_dir> <domain>  → class|""
# ═══════════════════════════════════════════════════════════════════════

[ -n "${_REACT_ENVELOPE_LOADED:-}" ] && return 0
_REACT_ENVELOPE_LOADED=1

# ── Noise stripping ───────────────────────────────────────────────────
# Removes:
#   * "[debug] MCP tool_call: ... params={" blocks (multi-line JSON)
#   * any other "[debug] ..." single lines (optionally "[HH:MM:SS]"-prefixed)
#   * Python warnings ("<file>:<n>: XxxWarning: ...") + their source line
#   * the "[CACHED OBSERVATION (0ms)]" banner (cache state is metadata)
react_envelope_clean() {
    local text="${1:-}"
    [ -z "$text" ] && return 0
    printf '%s\n' "$text" | awk '
        BEGIN { skip_json = 0; skip_warn_src = 0 }
        skip_json {
            if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) { skip_json = 0 }
            next
        }
        skip_warn_src {
            skip_warn_src = 0
            if ($0 ~ /^[[:space:]]+[^[:space:]]/) next
        }
        /^[[:space:]]*(\[[0-9:]+\][[:space:]]*)?\[debug\]/ {
            if ($0 ~ /params=\{[[:space:]]*$/) skip_json = 1
            next
        }
        /^[^[:space:]].*:[0-9]+: [A-Za-z]*Warning: / { skip_warn_src = 1; next }
        /^[[:space:]]*warnings\.warn\(/ { next }
        /^\[CACHED OBSERVATION \([0-9]+ms\)\][[:space:]]*$/ { next }
        { print }
    ' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

# ── Classification ────────────────────────────────────────────────────
# Strong signals only. Order matters: specific causes before generic.
_react_envelope_signal_class() {
    local text="$1"
    local head="${text:0:4000}"
    local tail_txt="$text"
    [ "${#text}" -gt 1500 ] && tail_txt="${text: -1500}"
    # Fetch/HTTP-layer outcomes reported by web tooling
    if [[ "$head" =~ (BLOCKED_GREYLIST|HTTP_403|HTTP[[:space:]]403|403[[:space:]]Forbidden|grey-listed|CAPTCHA|captcha[[:space:]]challenge|Access[[:space:]]Denied|paywall) ]]; then
        echo "BLOCKED"; return
    fi
    if [[ "$head" =~ (HTTP[[:space:]]429|HTTP_429|Too[[:space:]]Many[[:space:]]Requests|[Rr]ate[[:space:]]limit(ed)?[[:space:]]exceeded|RATE_LIMIT) ]]; then
        echo "RATE_LIMIT"; return
    fi
    if [[ "$head" =~ (HTTP[[:space:]]404|HTTP_404|404[[:space:]]Not[[:space:]]Found|No[[:space:]]such[[:space:]]file[[:space:]]or[[:space:]]directory|File[[:space:]]not[[:space:]]found|NXDOMAIN|Could[[:space:]]not[[:space:]]resolve[[:space:]]host) ]]; then
        echo "NOT_FOUND"; return
    fi
    if [[ "$text" =~ (timed[[:space:]]out|Operation[[:space:]]timed[[:space:]]out|TimeoutError|ReadTimeout) ]] && [[ "$head" =~ (FETCH[[:space:]]FAILED|ERROR|Error|Failed|failed) ]]; then
        echo "TIMEOUT"; return
    fi
    if [[ "$tail_txt" =~ (ModuleNotFoundError|ImportError|command[[:space:]]not[[:space:]]found|not[[:space:]]installed|pdftotext:[[:space:]]not[[:space:]]found) ]]; then
        echo "DEPENDENCY"; return
    fi
    if [[ "$text" =~ (SyntaxError:|syntax[[:space:]]error|unexpected[[:space:]]token|Invalid[[:space:]]JSON|parse[[:space:]]error|JSONDecodeError) ]]; then
        echo "SYNTAX"; return
    fi
    echo ""
}

# Does exit-0 text nonetheless carry an unambiguous failure verdict?
_react_envelope_exit0_failure() {
    local text="$1"
    local first_line
    first_line=$(printf '%s\n' "$text" | sed -n '/[^[:space:]]/{p;q}')
    # Tool-reported failure banners (first meaningful line only)
    [[ "$first_line" =~ ^[[:space:]]*(ERROR:|Error:|FAILED|FATAL|✗|⚠[[:space:]]URL[[:space:]]is[[:space:]]grey-listed) ]] && return 0
    [[ "$text" =~ \[FETCH[[:space:]]FAILED ]] && return 0
    [[ "$text" =~ SCRIPT_EXIT=[1-9] ]] && return 0
    [[ "$text" =~ failed[[:space:]]\(exit[[:space:]][1-9] ]] && return 0
    # Uncaught Python exception: traceback whose final non-blank line is the exception
    if [[ "$text" =~ Traceback[[:space:]]\(most[[:space:]]recent[[:space:]]call[[:space:]]last\) ]]; then
        local last
        last=$(printf '%s\n' "$text" | sed '/^[[:space:]]*$/d' | tail -n 1)
        [[ "$last" =~ ^[A-Za-z_.]*(Error|Exception|Interrupt)(:|$) ]] && return 0
    fi
    # Short, error-only responses ("Edge: Too Many Requests")
    if [ "${#text}" -lt 240 ] && [[ "$text" =~ (Too[[:space:]]Many[[:space:]]Requests|Forbidden|Not[[:space:]]Found|Service[[:space:]]Unavailable|Bad[[:space:]]Gateway) ]]; then
        return 0
    fi
    return 1
}

_react_envelope_expects_payload() {
    case "${1:-}" in
        web_*|*search*|*fetch*|research_*|pdf_read|file_read|okf_query|arxiv_*|hn_*) return 0 ;;
    esac
    return 1
}

react_envelope_classify() {
    local exit_code="${1:-0}" text="${2:-}" tool="${3:-}"
    [[ "$exit_code" =~ ^-?[0-9]+$ ]] || exit_code=1

    case "$exit_code" in
        124|137) echo "TIMEOUT"; return 0 ;;
        127) echo "DEPENDENCY"; return 0 ;;
    esac

    local trimmed="${text//[[:space:]]/}"
    if [ "$exit_code" -eq 0 ]; then
        if [ -z "$trimmed" ]; then
            _react_envelope_expects_payload "$tool" && { echo "EMPTY"; return 0; }
            echo ""; return 0
        fi
        if _react_envelope_exit0_failure "$text"; then
            local cls; cls=$(_react_envelope_signal_class "$text")
            echo "${cls:-CRASH}"; return 0
        fi
        echo ""; return 0
    fi

    # Non-zero exit: refine the class from strong signals; default CRASH.
    # grep/test-style probes (exit 1, no output) are NOT_FOUND, not crashes.
    if [ -z "$trimmed" ]; then
        [ "$exit_code" -eq 1 ] && { echo "NOT_FOUND"; return 0; }
        echo "CRASH"; return 0
    fi
    local cls; cls=$(_react_envelope_signal_class "$text")
    echo "${cls:-CRASH}"
}

# ── Envelope build / render ───────────────────────────────────────────
react_envelope_build() {
    local tool="${1:-tool}" exit_code="${2:-0}" dur="${3:-0}" raw="${4:-}"
    shift 4 2>/dev/null || shift $#
    [[ "$exit_code" =~ ^-?[0-9]+$ ]] || exit_code=1
    [[ "$dur" =~ ^[0-9]+$ ]] || dur=0
    local data cls ok=true
    data=$(react_envelope_clean "$raw")
    cls=$(react_envelope_classify "$exit_code" "$data" "$tool")
    [ -n "$cls" ] && ok=false
    local arts="[]"
    if [ $# -gt 0 ]; then
        arts=$(printf '%s\n' "$@" | sed '/^$/d' | jq -R . | jq -sc .)
    fi
    jq -nc --arg tool "$tool" --argjson ok "$ok" --argjson exit "$exit_code" \
        --arg cls "$cls" --argjson dur "$dur" --arg data "$data" --argjson arts "$arts" \
        '{tool: $tool, ok: $ok, exit: $exit, error_class: (if $cls == "" then null else $cls end),
          duration_ms: $dur, data: $data, artifacts: $arts}'
}

_react_envelope_hint() {
    case "${1:-}" in
        TIMEOUT)    echo "The call timed out. Narrow the request or try a different source; do not repeat it unchanged." ;;
        BLOCKED)    echo "This source is blocked (paywall/CAPTCHA/403). Do NOT retry this domain; use a different source from search results." ;;
        NOT_FOUND)  echo "The target does not exist. Do NOT retry the same path/URL; search for a current one." ;;
        RATE_LIMIT) echo "Rate limited. Switch to a different tool or source instead of retrying." ;;
        SYNTAX)     echo "Malformed command or arguments. Fix the syntax (prefer single-quoted heredocs for scripts) before retrying." ;;
        DEPENDENCY) echo "A required program/module is missing. Use a different tool; do not retry." ;;
        EMPTY)      echo "The call returned nothing. Change the query or tool rather than repeating it." ;;
        *)          echo "The tool failed. Read the error, change your approach, and do not repeat the identical call." ;;
    esac
}

react_envelope_render() {
    local env="${1:-}"
    local ok tool cls data
    ok=$(jq -r '.ok' <<<"$env" 2>/dev/null)
    data=$(jq -r '.data // ""' <<<"$env" 2>/dev/null)
    if [ "$ok" = "true" ]; then
        printf '%s' "$data"
        return 0
    fi
    tool=$(jq -r '.tool // "tool"' <<<"$env" 2>/dev/null)
    cls=$(jq -r '.error_class // "CRASH"' <<<"$env" 2>/dev/null)
    local excerpt
    if [[ "$data" =~ Traceback ]]; then
        excerpt=$(printf '%s\n' "$data" | grep -A3 -E '^[A-Za-z_.]*(Error|Exception)' | head -n 4)
        [ -z "$excerpt" ] && excerpt=$(printf '%s\n' "$data" | tail -n 5)
    else
        excerpt="${data:0:400}"
    fi
    printf '[TOOL FAILED: %s · %s]\n%s\n[HINT: %s]' "$tool" "$cls" "$excerpt" "$(_react_envelope_hint "$cls")"
}

# ── Failed-domain memory (P2.4) ───────────────────────────────────────
react_envelope_url_domain() {
    local url="${1:-}"
    url="${url#*://}"; url="${url%%/*}"; url="${url%%\?*}"; url="${url%%:*}"
    url="${url,,}"; url="${url#www.}"
    [[ "$url" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] && echo "$url"
}

react_envelope_failed_domain_record() {
    local sdir="${1:-}" domain="${2:-}" cls="${3:-CRASH}"
    [ -z "$sdir" ] || [ -z "$domain" ] && return 0
    case "$cls" in BLOCKED|RATE_LIMIT|TIMEOUT|NOT_FOUND) ;; *) return 0 ;; esac
    mkdir -p "$sdir" 2>/dev/null || return 0
    printf '%s\t%s\t%s\n' "$domain" "$cls" "$(date +%s)" >> "$sdir/failed_domains.tsv" 2>/dev/null || true
}

# Prints the blocking class when a domain should be short-circuited:
#   BLOCKED / RATE_LIMIT → after 1 failure; TIMEOUT → after 2.
#   NOT_FOUND is per-URL, so domains are never blocked for it.
react_envelope_failed_domain_check() {
    local sdir="${1:-}" domain="${2:-}"
    local f="$sdir/failed_domains.tsv"
    [ -z "$domain" ] || [ ! -f "$f" ] && return 1
    local hit
    hit=$(awk -F'\t' -v d="$domain" '
        $1 == d { c[$2]++ }
        END {
            if (c["BLOCKED"] >= 1) print "BLOCKED"
            else if (c["RATE_LIMIT"] >= 1) print "RATE_LIMIT"
            else if (c["TIMEOUT"] >= 2) print "TIMEOUT"
        }' "$f" 2>/dev/null)
    [ -n "$hit" ] && { echo "$hit"; return 0; }
    return 1
}

# Appends to the session scratchpad's "## Failed Attempts" section.
react_envelope_failed_attempt_note() {
    local sdir="${1:-}" tool="${2:-tool}" args="${3:-}" cls="${4:-CRASH}"
    [ -z "$sdir" ] && return 0
    local sp="$sdir/scratchpad.md"
    grep -q '^## Failed Attempts' "$sp" 2>/dev/null || printf '\n## Failed Attempts\n' >> "$sp" 2>/dev/null
    printf -- '- [%s] %s(%s) → %s\n' "$(date +%H:%M:%S)" "$tool" "${args:0:160}" "$cls" >> "$sp" 2>/dev/null || true
}

# ── Observation condensing ────────────────────────────────────────────
# Long observations (web pages) used to be replaced by a 6-line head
# "digest" — usually site navigation — which made the model refetch the
# same page. Instead: keep the substance, drop boilerplate menu lines
# (≤3 words and no digits) and cap at <limit> chars, pointing at the
# archived full text.
react_envelope_condense() {
    local text="${1:-}" limit="${2:-6000}" archive="${3:-}"
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=6000
    if [ "${#text}" -le "$limit" ]; then printf '%s' "$text"; return 0; fi
    local body
    body=$(printf '%s\n' "$text" | awk '
        {
            line = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line == "") { if (!blank) print ""; blank = 1; next }
            n = split(line, w, /[[:space:]]+/)
            # drop short nav crumbs: <=3 words, no digits, no URL, no sentence end
            if (n <= 3 && !(line ~ /[0-9]/) && !(line ~ /https?:\/\//) && !(line ~ /[.:!?]$/)) next
            blank = 0; print $0
        }')
    local note
    if [ "${#body}" -gt "$limit" ]; then
        body="${body:0:$limit}"
        note="[Observation condensed to ${limit} of ${#text} chars"
    else
        note="[Observation condensed: navigation/boilerplate removed (${#text} → ${#body} chars)"
    fi
    [ -n "$archive" ] && note+="; full text: file_read path=\"${archive}\""
    printf '%s\n\n%s]' "$body" "$note"
}
