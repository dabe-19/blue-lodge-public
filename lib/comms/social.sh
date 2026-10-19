#!/bin/bash
# ── George: Social Media Integration ───────────────────────────
[ -n "${_LIB_SOCIAL_LOADED:-}" ] && return 0; _LIB_SOCIAL_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/core/api.sh"
source "$LODGE_DIR/lib/sys/pgp.sh"
[ -f "$LODGE_DIR/lib/comms/social_blog.sh" ] && source "$LODGE_DIR/lib/comms/social_blog.sh"
[ -f "$LODGE_DIR/lib/comms/discord_outbox.sh" ] && source "$LODGE_DIR/lib/comms/discord_outbox.sh"

social_is_platform_allowed() {
    local platform="${1:-all}"
    local conf_file="${GEORGE_CONFIG_DIR:-${LODGE_DIR}/.george}/social/social.conf"
    if [ "${LODGE_TEST_MODE:-0}" -eq 1 ] && [ -n "${TEST_TMP:-}" ] && [ "${TEST_SOCIAL_GATE_ENFORCE:-0}" -ne 1 ]; then
        return 0
    fi
    local global_val="${GLOBAL_SOCIAL_ENABLED:-}"
    [ -z "$global_val" ] && global_val="${AUTONOMIC_PUBLISH_SOCIAL:-}"
    if [ -z "$global_val" ] && [ -f "$conf_file" ]; then
        global_val=$(grep -m1 '^GLOBAL_SOCIAL_ENABLED=' "$conf_file" 2>/dev/null | cut -d'=' -f2 | tr -d ' "\r')
    fi
    [ "${global_val:-0}" != "1" ] && return 1
    [ "$platform" = "all" ] && return 0

    local plat_var plat_key
    case "${platform,,}" in
        x|twitter) plat_var="${AUTONOMIC_PUBLISH_X:-${X_ENABLED:-}}"; plat_key="X_ENABLED" ;;
        masto|mastodon) plat_var="${AUTONOMIC_PUBLISH_MASTODON:-${MASTODON_ENABLED:-}}"; plat_key="MASTODON_ENABLED" ;;
        bsky|bluesky) plat_var="${AUTONOMIC_PUBLISH_BLUESKY:-${BLUESKY_ENABLED:-}}"; plat_key="BLUESKY_ENABLED" ;;
        *) return 0 ;;
    esac
    if [ -z "$plat_var" ] && [ -f "$conf_file" ]; then
        plat_var=$(grep -m1 "^${plat_key}=" "$conf_file" 2>/dev/null | cut -d'=' -f2 | tr -d ' "\r')
    fi
    [ "${plat_var:-0}" != "1" ] && return 1
    return 0
}

_x_percent_encode() {
    local string="$1"
    if command -v jq &>/dev/null; then
        printf '%s' "$string" | jq -sRr @uri
    elif command -v "${GEORGE_PYTHON:-python3}" &>/dev/null; then
        "${GEORGE_PYTHON:-python3}" -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''), end='')" "$string"
    else
        local strlen=${#string} encoded="" pos c o
        for (( pos=0 ; pos<strlen ; pos++ )); do
            c=${string:$pos:1}
            case "$c" in [-_.~a-zA-Z0-9] ) o="${c}" ;; * ) printf -v o '%%%02X' "'$c" ;; esac
            encoded+="${o}"
        done
        printf '%s' "${encoded}"
    fi
}

_x_oauth1_header() {
    local method="$1" url="$2" consumer_key="$3" consumer_secret="$4" token="$5" token_secret="$6"
    local nonce timestamp enc_ckey enc_nonce enc_token params encoded_method encoded_url encoded_params base_string signing_key signature encoded_sig
    nonce=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'); timestamp=$(date +%s)
    enc_ckey=$(_x_percent_encode "$consumer_key"); enc_nonce=$(_x_percent_encode "$nonce"); enc_token=$(_x_percent_encode "$token")
    params="oauth_consumer_key=${enc_ckey}&oauth_nonce=${enc_nonce}&oauth_signature_method=HMAC-SHA1&oauth_timestamp=${timestamp}&oauth_token=${enc_token}&oauth_version=1.0"
    encoded_method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
    encoded_url=$(_x_percent_encode "$url"); encoded_params=$(_x_percent_encode "$params")
    base_string="${encoded_method}&${encoded_url}&${encoded_params}"
    signing_key="$(_x_percent_encode "$consumer_secret")&$(_x_percent_encode "$token_secret")"
    signature=$(printf '%s' "$base_string" | openssl dgst -sha1 -hmac "$signing_key" -binary | base64 | tr -d '\n')
    encoded_sig=$(_x_percent_encode "$signature")
    echo "Authorization: OAuth oauth_consumer_key=\"$consumer_key\", oauth_nonce=\"$nonce\", oauth_signature=\"$encoded_sig\", oauth_signature_method=\"HMAC-SHA1\", oauth_timestamp=\"$timestamp\", oauth_token=\"$token\", oauth_version=\"1.0\""
}

_x_auth_header() {
    local method="${1:-POST}" url="${2:-https://api.x.com/2/tweets}" ckey csec atok atoksec bearer
    ckey=$(api_get_key "X_CONSUMER_KEY" 2>/dev/null || api_get_key "X_API_KEY" 2>/dev/null || echo "")
    csec=$(api_get_key "X_CONSUMER_SECRET" 2>/dev/null || api_get_key "X_API_SECRET" 2>/dev/null || echo "")
    atok=$(api_get_key "X_ACCESS_TOKEN" 2>/dev/null || echo "")
    atoksec=$(api_get_key "X_ACCESS_TOKEN_SECRET" 2>/dev/null || echo "")
    bearer=$(api_get_key "X_BEARER_TOKEN" 2>/dev/null || echo "")
    if [ -n "$ckey" ] && [ -n "$csec" ] && [ -n "$atok" ] && [ -n "$atoksec" ]; then
        _x_oauth1_header "$method" "$url" "$ckey" "$csec" "$atok" "$atoksec"; return 0
    elif [ -n "$bearer" ]; then
        echo "Authorization: Bearer $bearer"; return 0
    fi
    return 1
}

_x_cookie_auth_available() {
    local auth_token ct0
    auth_token=$(api_get_key "X_AUTH_TOKEN" 2>/dev/null || echo "")
    ct0=$(api_get_key "X_CT0" 2>/dev/null || echo "")
    [ -n "$auth_token" ] && [ -n "$ct0" ]
}

_x_cookie_post() {
    local text="$1" reply_to_id="${2:-}" auth_token ct0 resp status
    auth_token=$(api_get_key "X_AUTH_TOKEN" 2>/dev/null || echo "")
    ct0=$(api_get_key "X_CT0" 2>/dev/null || echo "")
    [ -z "$auth_token" ] || [ -z "$ct0" ] && return 1
    resp=$(X_AUTH_TOKEN="$auth_token" X_CT0="$ct0" python3 "$LODGE_DIR/lib/comms/social_cookie.py" post "$text" "$reply_to_id" 2>/dev/null)
    status=$(echo "$resp" | jq -r '.status // empty' 2>/dev/null)
    if [ "$status" = "ok" ]; then
        local tweet_id; tweet_id=$(echo "$resp" | jq -r '.tweet_id // empty' 2>/dev/null)
        ui_ok "Posted to X via Web Session (ID: ${tweet_id:-posted})" >&2
        echo "$resp"; return 0
    else
        local detail; detail=$(echo "$resp" | jq -r '.detail // "unknown error"' 2>/dev/null)
        ui_err "X Web Session post failed: $detail" >&2; return 1
    fi
}

social_sanitize_text() {
    local raw="$1"
    if command -v python3 &>/dev/null; then
        printf '%s' "$raw" | python3 -c '
import sys, re

text = sys.stdin.read()

replacements = [
    # Greek lowercase
    (r"\\alpha(?![a-zA-Z])", "α"), (r"\\beta(?![a-zA-Z])", "β"), (r"\\gamma(?![a-zA-Z])", "γ"),
    (r"\\delta(?![a-zA-Z])", "δ"), (r"\\epsilon(?![a-zA-Z])", "ε"), (r"\\varepsilon(?![a-zA-Z])", "ε"),
    (r"\\zeta(?![a-zA-Z])", "ζ"), (r"\\eta(?![a-zA-Z])", "η"), (r"\\theta(?![a-zA-Z])", "θ"),
    (r"\\vartheta(?![a-zA-Z])", "θ"), (r"\\iota(?![a-zA-Z])", "ι"), (r"\\kappa(?![a-zA-Z])", "κ"),
    (r"\\lambda(?![a-zA-Z])", "λ"), (r"\\mu(?![a-zA-Z])", "μ"), (r"\\nu(?![a-zA-Z])", "ν"),
    (r"\\xi(?![a-zA-Z])", "ξ"), (r"\\pi(?![a-zA-Z])", "π"), (r"\\varpi(?![a-zA-Z])", "ϖ"),
    (r"\\rho(?![a-zA-Z])", "ρ"), (r"\\varrho(?![a-zA-Z])", "ϱ"), (r"\\sigma(?![a-zA-Z])", "σ"),
    (r"\\varsigma(?![a-zA-Z])", "ς"), (r"\\tau(?![a-zA-Z])", "τ"), (r"\\upsilon(?![a-zA-Z])", "υ"),
    (r"\\phi(?![a-zA-Z])", "ϕ"), (r"\\varphi(?![a-zA-Z])", "φ"), (r"\\chi(?![a-zA-Z])", "χ"),
    (r"\\psi(?![a-zA-Z])", "ψ"), (r"\\omega(?![a-zA-Z])", "ω"),
    # Greek uppercase
    (r"\\Gamma(?![a-zA-Z])", "Γ"), (r"\\Delta(?![a-zA-Z])", "Δ"), (r"\\Theta(?![a-zA-Z])", "Θ"),
    (r"\\Lambda(?![a-zA-Z])", "Λ"), (r"\\Xi(?![a-zA-Z])", "Ξ"), (r"\\Pi(?![a-zA-Z])", "Π"),
    (r"\\Sigma(?![a-zA-Z])", "Σ"), (r"\\Upsilon(?![a-zA-Z])", "Υ"), (r"\\Phi(?![a-zA-Z])", "Φ"),
    (r"\\Psi(?![a-zA-Z])", "Ψ"), (r"\\Omega(?![a-zA-Z])", "Ω"),
    # Relations & comparisons
    (r"\\geq(?![a-zA-Z])", "≥"), (r"\\ge(?![a-zA-Z])", "≥"),
    (r"\\leq(?![a-zA-Z])", "≤"), (r"\\le(?![a-zA-Z])", "≤"),
    (r"\\neq(?![a-zA-Z])", "≠"), (r"\\ne(?![a-zA-Z])", "≠"),
    (r"\\approx(?![a-zA-Z])", "≈"), (r"\\sim(?![a-zA-Z])", "∼"),
    (r"\\equiv(?![a-zA-Z])", "≡"), (r"\\ll(?![a-zA-Z])", "≪"), (r"\\gg(?![a-zA-Z])", "≫"),
    (r"\\pm(?![a-zA-Z])", "±"), (r"\\mp(?![a-zA-Z])", "∓"),
    (r"\\times(?![a-zA-Z])", "×"), (r"\\cdot(?![a-zA-Z])", "·"),
    # Arrows
    (r"\\longrightarrow(?![a-zA-Z])", "→"), (r"\\rightarrow(?![a-zA-Z])", "→"), (r"\\to(?![a-zA-Z])", "→"),
    (r"\\longleftarrow(?![a-zA-Z])", "←"), (r"\\leftarrow(?![a-zA-Z])", "←"),
    (r"\\longleftrightarrow(?![a-zA-Z])", "↔"), (r"\\leftrightarrow(?![a-zA-Z])", "↔"),
    (r"\\Longrightarrow(?![a-zA-Z])", "⇒"), (r"\\Rightarrow(?![a-zA-Z])", "⇒"), (r"\\implies(?![a-zA-Z])", "⇒"),
    (r"\\Longleftarrow(?![a-zA-Z])", "⇐"), (r"\\Leftarrow(?![a-zA-Z])", "⇐"),
    (r"\\Longleftrightarrow(?![a-zA-Z])", "⇔"), (r"\\Leftrightarrow(?![a-zA-Z])", "⇔"), (r"\\iff(?![a-zA-Z])", "⇔"),
    (r"\\mapsto(?![a-zA-Z])", "↦"),
    # Operators & calculus
    (r"\\sum(?![a-zA-Z])", "∑"), (r"\\prod(?![a-zA-Z])", "∏"),
    (r"\\int(?![a-zA-Z])", "∫"), (r"\\partial(?![a-zA-Z])", "∂"),
    (r"\\nabla(?![a-zA-Z])", "∇"), (r"\\infty(?![a-zA-Z])", "∞"),
    (r"\\in(?![a-zA-Z])", "∈"), (r"\\notin(?![a-zA-Z])", "∉"),
    (r"\\subset(?![a-zA-Z])", "⊂"), (r"\\subseteq(?![a-zA-Z])", "⊆"),
    (r"\\supset(?![a-zA-Z])", "⊃"), (r"\\supseteq(?![a-zA-Z])", "⊇"),
    (r"\\cap(?![a-zA-Z])", "∩"), (r"\\cup(?![a-zA-Z])", "∪"),
    (r"\\forall(?![a-zA-Z])", "∀"), (r"\\exists(?![a-zA-Z])", "∃"),
    (r"\\neg(?![a-zA-Z])", "¬"), (r"\\land(?![a-zA-Z])", "∧"), (r"\\lor(?![a-zA-Z])", "∨"),
    (r"\\emptyset(?![a-zA-Z])", "∅"),
    (r"\\max(?![a-zA-Z])", "max"), (r"\\min(?![a-zA-Z])", "min"),
    (r"\\log(?![a-zA-Z])", "log"), (r"\\exp(?![a-zA-Z])", "exp"),
    (r"\\dots(?![a-zA-Z])", "..."), (r"\\cdots(?![a-zA-Z])", "..."), (r"\\ldots(?![a-zA-Z])", "..."),
    # Structures, fonts & accents
    (r"\\mathbb\{Z\}_?(\d*)", r"Z\1"), (r"\\mathbb\{R\}_?(\d*)", r"R\1"),
    (r"\\mathbb\{N\}", "N"), (r"\\mathbb\{C\}", "C"), (r"\\mathbb\{Q\}", "Q"),
    (r"\\mathbb\{F\}_?(\w*)", r"F\1"), (r"\\mathcal\{([A-Za-z])\}", r"\1"),
    (r"\\hat\{([^\}]+)\}", r"\1"), (r"\\bar\{([^\}]+)\}", r"\1"), (r"\\tilde\{([^\}]+)\}", r"\1"),
    (r"\\vec\{([^\}]+)\}", r"\1"),
    (r"\\text\{([^\}]+)\}", r"\1"), (r"\\mathbf\{([^\}]+)\}", r"\1"),
    (r"\\mathrm\{([^\}]+)\}", r"\1"), (r"\\mathit\{([^\}]+)\}", r"\1"),
    (r"\\math[a-z]+\{([^\}]+)\}", r"\1"),
    (r"\\frac\{([^\}]+)\}\{([^\}]+)\}", r"(\1)/(\2)"),
    (r"\\sqrt\{([^\}]+)\}", r"√(\1)"),
    (r"\\prime", "\x27"),
    (r"\\\|", "||"),
]

for pattern, repl in replacements:
    text = re.sub(pattern, repl, text)

# Subscripts & superscripts
text = re.sub(r"_\{([^\}]+)\}", r"_\1", text)
text = re.sub(r"\^\{([^\}]+)\}", r"^\1", text)

# LaTeX display math brackets \[ ... \] and \( ... \)
text = re.sub(r"\\\[(.*?)\\\]", r"\1", text, flags=re.DOTALL)
text = re.sub(r"\\\((.*?)\\\)", r"\1", text)

# Strip LaTeX math delimiters $$...$$ and $...$
text = re.sub(r"\$\$([^\$]+)\$\$", r"\1", text)
text = re.sub(r"(?<!\\)\$(?!\s)([^\$\n]+?)(?<!\s)\$", r"\1", text)

# Strip dollar signs from single-letter variables and lowercase identifiers ($f, $C, $x, $y, $tx)
# Never allow single letters to remain as cashtags, as X parses them as stock tickers ($F=Ford, $C=Citigroup)
text = re.sub(r"(?<!\w)\$([a-z][A-Za-z0-9_]*)\b", r"\1", text)
text = re.sub(r"(?<!\w)\$([A-Z])(?=\b|[_\s\(\),.:;])", r"\1", text)

# Enforce X cashtag limit on valid financial tickers (e.g. $ADA, $BTC: 2-6 UPPERCASE chars)
# Currency like $10, $40B, $1.5M are preserved because they start with a digit.
cashtags_seen = 0
def cashtag_sub(m):
    global cashtags_seen
    cashtags_seen += 1
    if cashtags_seen <= 2:
        return m.group(0)
    return m.group(1)

text = re.sub(r"(?<!\w)\$([A-Z]{2,6})\b", cashtag_sub, text)
sys.stdout.write(text)
' 2>/dev/null || printf '%s' "$raw"
    else
        printf '%s' "$raw"
    fi
}

_x_sanitize_text() {
    social_sanitize_text "$@"
}

x_post() {
    if ! social_is_platform_allowed "x"; then
        ui_warn "X broadcast aborted: Social gate is locked (GLOBAL_SOCIAL_ENABLED or X_ENABLED is disabled)."
        return 1
    fi
    local text="$1"
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        text=$(tools_expand_file_refs "$text")
    fi
    text=$(ui_expand_escapes "$text")
    text=$(_x_sanitize_text "$text")
    if [ "${SOCIAL_GPG_SIGN:-0}" -eq 1 ] && [ "${_IN_THREAD:-0}" -ne 1 ]; then
        [ -f "$LODGE_DIR/lib/sys/pgp.sh" ] && source "$LODGE_DIR/lib/sys/pgp.sh"
        declare -f pgp_sign_social &>/dev/null && text=$(pgp_sign_social "$text")
    fi
    if _x_cookie_auth_available && [ "${SOCIAL_PREFER_API:-0}" -ne 1 ]; then
        _x_cookie_post "$text" && return 0
    fi
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_result; _mcp_result=$(mcp_x_post "$text" 2>/dev/null)
        # Guard: MCP servers may return 0 with an error string (e.g. "Error: X_BEARER_TOKEN not set").
        # Only accept results that contain a real tweet ID; otherwise fall through to direct API.
        local _mcp_tweet_id; _mcp_tweet_id=$(echo "$_mcp_result" | grep -oE '"id"[[:space:]]*:[[:space:]]*"?[0-9]+' | head -n 1 | grep -oE '[0-9]+' || echo "")
        if [ -n "$_mcp_tweet_id" ] && ! echo "$_mcp_result" | head -c 6 | grep -q "Error"; then
            echo "$_mcp_result"; return 0
        fi
        [ -n "$_mcp_result" ] && ui_warn "MCP x_post unusable ("$(printf '%s' "$_mcp_result" | cut -c1-80)") — falling back to direct API" >&2
    fi
    local auth_header; auth_header=$(_x_auth_header "POST" "https://api.x.com/2/tweets")
    [ -z "$auth_header" ] && { ui_err "No X credentials configured"; return 1; }
    local data resp status; data=$(jq -n --arg t "$text" '{"text": $t}')
    resp=$(api_post "https://api.x.com/2/tweets" "$data" -H "$auth_header"); status=$?
    if [ $status -eq 0 ]; then
        local tweet_id; tweet_id=$(api_json_get "$resp" '.data.id')
        ui_ok "Posted to X (ID: $tweet_id)" >&2; echo "$resp"
    else
        local err_msg; err_msg=$(api_json_get "$resp" '.detail // .title // "unknown error"')
        ui_err "X post failed: $err_msg" >&2; return 1
    fi
}

x_timeline() {
    local count="${1:-10}"
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_result; _mcp_result=$(mcp_x_timeline "$count" 2>/dev/null)
        if [ -n "$_mcp_result" ] && ! echo "$_mcp_result" | head -c 6 | grep -q "Error"; then
            echo "$_mcp_result"; return 0
        fi
    fi
    local auth_header; auth_header=$(_x_auth_header "GET" "https://api.x.com/2/tweets/search/recent")
    [ -z "$auth_header" ] && { ui_err "No X credentials configured"; return 1; }
    local resp; resp=$(api_get "https://api.x.com/2/tweets/search/recent?max_results=$count&query=from:me" -H "$auth_header")
    [ $? -eq 0 ] && echo "$resp" | jq -r '.data[]? | "[\(.id)] \(.text)"' 2>/dev/null || { ui_err "Failed to fetch X timeline"; return 1; }
}

x_reply() {
    local tweet_id="$1" text="$2"
    text=$(_x_sanitize_text "$text")
    if [ "${SOCIAL_GPG_SIGN:-0}" -eq 1 ] && [ "${_IN_THREAD:-0}" -ne 1 ]; then
        [ -f "$LODGE_DIR/lib/sys/pgp.sh" ] && source "$LODGE_DIR/lib/sys/pgp.sh"
        declare -f pgp_sign_social &>/dev/null && text=$(pgp_sign_social "$text")
    fi
    if _x_cookie_auth_available && [ "${SOCIAL_PREFER_API:-0}" -ne 1 ]; then
        _x_cookie_post "$text" "$tweet_id" && return 0
    fi
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_result; _mcp_result=$(mcp_x_reply "$tweet_id" "$text" 2>/dev/null)
        local _mcp_rep_id; _mcp_rep_id=$(echo "$_mcp_result" | grep -oE '"id"[[:space:]]*:[[:space:]]*"?[0-9]+' | head -n 1 | grep -oE '[0-9]+' || echo "")
        if [ -n "$_mcp_rep_id" ] && ! echo "$_mcp_result" | head -c 6 | grep -q "Error"; then
            echo "$_mcp_result"; return 0
        fi
        [ -n "$_mcp_result" ] && ui_warn "MCP x_reply unusable — falling back to direct API" >&2
    fi
    local auth_header; auth_header=$(_x_auth_header "POST" "https://api.x.com/2/tweets")
    [ -z "$auth_header" ] && { ui_err "No X credentials configured"; return 1; }
    local data resp status
    data=$(jq -n --arg t "$text" --arg id "$tweet_id" '{"text": $t, "reply": {"in_reply_to_tweet_id": $id}}')
    resp=$(api_post "https://api.x.com/2/tweets" "$data" -H "$auth_header"); status=$?
    if [ $status -eq 0 ]; then
        local reply_id; reply_id=$(echo "$resp" | jq -r '.data.id // .id // empty' 2>/dev/null)
        ui_ok "Replied to X (ID: ${reply_id:-posted})" >&2; echo "$resp"; return 0
    else
        local err_msg; err_msg=$(echo "$resp" | jq -r '.detail // .title // "unknown error"' 2>/dev/null)
        ui_err "X reply failed: $err_msg" >&2; return 1
    fi
}

x_thread() {
    local full_text="$1" delay="${2:-2}"
    [ -z "$full_text" ] && { ui_err "Usage: x_thread <text>"; return 1; }
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        full_text=$(tools_expand_file_refs "$full_text")
    fi
    full_text=$(ui_expand_escapes "$full_text")
    full_text=$(_x_sanitize_text "$full_text")
    full_text=$(echo "$full_text" | sed -E 's/^\[George[^]]*\][[:space:]]*//; s/🔏 Signed:.*//')

    local x_premium="${X_PREMIUM:-}"
    if [ -z "$x_premium" ] && [ -f "${GEORGE_CONFIG_DIR:-${LODGE_DIR}/.george}/social/social.conf" ]; then
        x_premium=$(grep -m1 '^X_PREMIUM=' "${GEORGE_CONFIG_DIR:-${LODGE_DIR}/.george}/social/social.conf" 2>/dev/null | cut -d'=' -f2 | tr -d ' "\r')
    fi
    x_premium="${x_premium:-0}"
    local max_len=${X_MAX_CHARS:-500}
    if [ "$x_premium" = "1" ]; then
        max_len=${X_PREMIUM_MAX_CHARS:-2800}
    fi

    local chunks_json
    chunks_json=$(python3 -c '
import sys, re, json
text = sys.argv[1].strip()
max_len = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 4000
if "---POST---" in text:
    raw_posts = [p.strip() for p in text.split("---POST---") if p.strip()]
elif "===POST===" in text:
    raw_posts = [p.strip() for p in text.split("===POST===") if p.strip()]
else:
    raw_posts = [p.strip() for p in text.split("\n\n") if p.strip()]

def chunk_text(t, max_len=4000):
    if len(t) <= max_len:
        return [t]
    paragraphs = [sp.strip() for sp in t.split("\n\n") if sp.strip()]
    res = []
    for par in paragraphs:
        if len(par) <= max_len:
            res.append(par)
        else:
            sentences = re.split(r"(?<=[.?!])\s+", par)
            curr = ""
            for s in sentences:
                if len(s) > max_len:
                    clauses = re.split(r"(?<=[;—:])\s+|(?<=,\s)", s)
                    for c in clauses:
                        if len(c) > max_len:
                            words = c.split(" ")
                            for w in words:
                                if len(curr) + len(w) + 1 <= max_len:
                                    curr = (curr + " " + w).strip() if curr else w
                                else:
                                    if curr: res.append(curr)
                                    curr = w
                        else:
                            if len(curr) + len(c) + 1 <= max_len:
                                curr = (curr + " " + c).strip() if curr else c
                            else:
                                if curr: res.append(curr)
                                curr = c
                else:
                    if len(curr) + len(s) + 1 <= max_len:
                        curr = (curr + " " + s).strip() if curr else s
                    else:
                        if curr: res.append(curr)
                        curr = s
            if curr:
                res.append(curr)
    return res

chunks = []
for p in raw_posts:
    chunks.extend(chunk_text(p, max_len))
print(json.dumps(chunks))
' "$full_text" "$max_len" 2>/dev/null)

    local count; count=$(echo "$chunks_json" | jq '. | length' 2>/dev/null)
    if [ -z "$count" ] || [ "$count" -le 1 ]; then
        local single_resp
        single_resp=$(X_MEDIA_FILE="${SOCIAL_MEDIA_FILE:-}" x_post "$full_text") || return $?
        export LAST_X_ROOT_ID=$(echo "$single_resp" | jq -r '.data.id // .tweet_id // .id // empty' 2>/dev/null)
        echo "$single_resp"
        return 0
    fi

    ui_info "Publishing X thread (${count} tweets)..."
    export _IN_THREAD=1
    local prev_id="" root_id="" idx=0
    while [ "$idx" -lt "$count" ]; do
        local chunk num=$((idx + 1)) post_content resp
        chunk=$(echo "$chunks_json" | jq -r ".[$idx]" | sed -E 's/^\[[0-9]+\/[0-9]+\][[:space:]]*//; s/^[0-9]+\/[0-9]+[[:space:]]*//')
        if [ "$idx" -eq 0 ]; then post_content="$chunk"$'\n\n'"🧵 1/$count"
        else post_content="$chunk"$'\n\n'"$num/$count"; fi

        if [ -z "$prev_id" ]; then
            resp=$(X_MEDIA_FILE="${SOCIAL_MEDIA_FILE:-}" x_post "$post_content")
        else
            resp=$(X_MEDIA_FILE="" SOCIAL_MEDIA_FILE="" x_reply "$prev_id" "$post_content")
        fi

        prev_id=$(echo "$resp" | jq -r '.data.id // .tweet_id // .id // empty' 2>/dev/null)
        [ -z "$prev_id" ] && prev_id=$(echo "$resp" | grep -oE '"id"[[:space:]]*:[[:space:]]*"?[0-9]+' | head -n 1 | grep -oE '[0-9]+' || echo "")
        if [ -z "$prev_id" ]; then
            ui_err "Thread failed at tweet $num/$count (could not extract tweet ID from response)"
            unset _IN_THREAD; return 1
        fi
        [ -z "$root_id" ] && root_id="$prev_id"
        ui_info "  Part $num/$count: https://x.com/i/web/status/$prev_id"
        idx=$((idx + 1))
        [ "$idx" -lt "$count" ] && sleep "$delay"
    done
    unset _IN_THREAD
    export LAST_X_ROOT_ID="${root_id:-$prev_id}"
    ui_ok "Thread published successfully ($count tweets, root ID: ${root_id:-$prev_id})"
    return 0
}

x_search() {
    local query="$1" count="${2:-10}"
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_result; _mcp_result=$(mcp_x_search "$query" "$count" 2>/dev/null)
        if [ -n "$_mcp_result" ] && ! echo "$_mcp_result" | head -c 6 | grep -q "Error"; then
            echo "$_mcp_result"; return 0
        fi
    fi
    local auth_header; auth_header=$(_x_auth_header "GET" "https://api.x.com/2/tweets/search/recent")
    [ -z "$auth_header" ] && { ui_err "No X credentials configured"; return 1; }
    local encoded; encoded=$(_x_percent_encode "$query")
    local resp; resp=$(api_get "https://api.x.com/2/tweets/search/recent?query=$encoded&max_results=$count" -H "$auth_header")
    [ $? -eq 0 ] && echo "$resp" | jq -r '.data[]? | "[\(.id)] \(.text)"' 2>/dev/null || { ui_err "X search failed"; return 1; }
}

x_delete() {
    local tweet_id="$1"
    [ -z "$tweet_id" ] && { ui_err "Usage: x_delete <tweet_id>"; return 1; }
    local auth_header; auth_header=$(_x_auth_header "DELETE" "https://api.x.com/2/tweets/$tweet_id")
    [ -z "$auth_header" ] && { ui_err "No X credentials configured"; return 1; }
    local resp status; resp=$(api_delete "https://api.x.com/2/tweets/$tweet_id" -H "$auth_header"); status=$?
    if [ $status -eq 0 ]; then ui_ok "Deleted tweet $tweet_id"; return 0
    else ui_err "Delete failed: $(api_json_get "$resp" '.detail // "unknown error"')\n"; return 1; fi
}

x_validate() {
    ui_section "X (Twitter) Credentials Validation"
    local has_keys=0
    if api_get_key "X_CONSUMER_KEY" &>/dev/null && api_get_key "X_ACCESS_TOKEN" &>/dev/null; then
        ui_ok "OAuth 1.0a User Context keys present"; has_keys=1
    fi
    if _x_cookie_auth_available; then ui_ok "Web Session Cookies present (X_AUTH_TOKEN, X_CT0)"; has_keys=1; fi
    if api_get_key "X_BEARER_TOKEN" &>/dev/null; then ui_ok "Bearer Token present"; has_keys=1; fi
    [ $has_keys -eq 0 ] && { ui_err "No X credentials found in secrets vault or keys.conf"; return 1; }
    return 0
}

MASTODON_INSTANCES_DB="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/mastodon_instances.db"

_mastodon_instances_init() {
    command -v sqlite3 &>/dev/null || { ui_err "sqlite3 required for Mastodon instance registry"; return 1; }
    mkdir -p "$(dirname "$MASTODON_INSTANCES_DB")"
    sqlite3 "$MASTODON_INSTANCES_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS instances (
    instance_url TEXT NOT NULL UNIQUE COLLATE NOCASE,
    access_token TEXT NOT NULL,
    display_name TEXT DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
SQL
}

mastodon_instance_add() {
    local instance_url="$1" access_token="$2" display_name="${3:-}"
    [[ "$instance_url" != https://* ]] && [[ "$instance_url" != http://* ]] && instance_url="https://$instance_url"
    instance_url="${instance_url%/}"
    _mastodon_instances_init || return 1
    sqlite3 "$MASTODON_INSTANCES_DB" "INSERT OR REPLACE INTO instances(instance_url, access_token, display_name) VALUES ('${instance_url//\'/\'\'}', '${access_token//\'/\'\'}', '${display_name//\'/\'\'}');"
    ui_ok "Registered Mastodon instance: $instance_url${display_name:+ ($display_name)}"
}

mastodon_instance_remove() {
    local instance_url="$1"
    [[ "$instance_url" != https://* ]] && [[ "$instance_url" != http://* ]] && instance_url="https://$instance_url"
    instance_url="${instance_url%/}"
    _mastodon_instances_init || return 1
    sqlite3 "$MASTODON_INSTANCES_DB" "DELETE FROM instances WHERE instance_url = '${instance_url//\'/\'\'}' COLLATE NOCASE;"
    ui_ok "Removed Mastodon instance: $instance_url"
}

mastodon_instance_list() {
    _mastodon_instances_init || return 1
    local count; count=$(sqlite3 "$MASTODON_INSTANCES_DB" "SELECT COUNT(*) FROM instances;" 2>/dev/null)
    if [ "${count:-0}" -eq 0 ]; then
        if api_get_key "MASTODON_ACCESS_TOKEN" &>/dev/null; then
            printf "  %b●%b %s (legacy key)\n" "$C_GREEN" "$C_RESET" "$(_mastodon_base)"
        else ui_dim "No Mastodon instances registered"; fi
        return
    fi
    ui_section "Mastodon Instances ($count)"
    sqlite3 -separator ' | ' "$MASTODON_INSTANCES_DB" "SELECT instance_url, COALESCE(NULLIF(display_name,''), '(unnamed)') FROM instances ORDER BY instance_url;" 2>/dev/null | while IFS= read -r line; do
        printf "  %b●%b %s\n" "$C_GREEN" "$C_RESET" "$line"
    done
}

_mastodon_instance_token() {
    local instance_url="${1:-}"
    if [ -n "$instance_url" ]; then
        [[ "$instance_url" != https://* ]] && [[ "$instance_url" != http://* ]] && instance_url="https://$instance_url"
        instance_url="${instance_url%/}"
        _mastodon_instances_init 2>/dev/null
        local token; token=$(sqlite3 "$MASTODON_INSTANCES_DB" "SELECT access_token FROM instances WHERE instance_url = '${instance_url//\'/\'\'}' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
        [ -n "$token" ] && { echo "$token"; return 0; }
    fi
    _mastodon_instances_init 2>/dev/null
    local first_token; first_token=$(sqlite3 "$MASTODON_INSTANCES_DB" "SELECT access_token FROM instances LIMIT 1;" 2>/dev/null)
    [ -n "$first_token" ] && { echo "$first_token"; return 0; }
    api_get_key "MASTODON_ACCESS_TOKEN"
}

_mastodon_instance_url() {
    local instance_url="${1:-}"
    if [ -n "$instance_url" ]; then
        [[ "$instance_url" != https://* ]] && [[ "$instance_url" != http://* ]] && instance_url="https://$instance_url"
        echo "${instance_url%/}"; return
    fi
    _mastodon_instances_init 2>/dev/null
    local first_url; first_url=$(sqlite3 "$MASTODON_INSTANCES_DB" "SELECT instance_url FROM instances LIMIT 1;" 2>/dev/null)
    [ -n "$first_url" ] && { echo "$first_url"; return; }
    _mastodon_base
}

_mastodon_base() {
    local instance; instance=$(api_get_key "MASTODON_INSTANCE")
    echo "${instance:-https://mastodon.social}"
}

_mastodon_upload_media() {
    local base="$1" token="$2" media_file="$3"
    [ -z "$media_file" ] || [ ! -f "$media_file" ] && return 1
    [ "${_LODGE_TESTING:-0}" -eq 1 ] && return 1
    local resp media_id
    resp=$(curl -sf --max-time 25 -X POST "${base}/api/v2/media" \
        -H "Authorization: Bearer $token" \
        -F "file=@${media_file}" \
        -F "description=Blue Lodge Sovereign Research Monograph Plate" 2>/dev/null || \
        curl -sf --max-time 25 -X POST "${base}/api/v1/media" \
        -H "Authorization: Bearer $token" \
        -F "file=@${media_file}" 2>/dev/null || echo "")
    media_id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)
    if [ -n "$media_id" ]; then
        echo "$media_id"
        return 0
    fi
    return 1
}

mastodon_post() {
    if ! social_is_platform_allowed "mastodon"; then
        ui_warn "Mastodon broadcast aborted: Social gate is locked (GLOBAL_SOCIAL_ENABLED or MASTODON_ENABLED is disabled)."
        return 1
    fi
    local text="$1" visibility="${2:-public}" instance="${3:-}"
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        text=$(tools_expand_file_refs "$text")
    fi
    text=$(ui_expand_escapes "$text")
    text=$(social_sanitize_text "$text")
    ([ "${#text}" -gt 480 ] || [[ "$text" =~ (---POST---|===POST===) ]]) && { mastodon_thread "$text" "$visibility" "$instance"; return $?; }

    local token base data resp url
    token=$(_mastodon_instance_token "$instance")
    [ -z "$token" ] && { ui_err "Mastodon: No access token configured"; return 1; }
    base=$(_mastodon_instance_url "$instance")
    data=$(jq -n --arg s "$text" --arg v "$visibility" '{"status": $s, "visibility": $v}')
    resp=$(api_post "$base/api/v1/statuses" "$data" -H "Authorization: Bearer $token")
    if [ $? -eq 0 ]; then
        url=$(api_json_get "$resp" '.url')
        export LAST_MASTODON_ROOT_URL="$url"
        export LAST_MASTODON_ROOT_ID=$(api_json_get "$resp" '.id')
        ui_ok "Posted to Mastodon: $url"; echo "$resp"
    else ui_err "Mastodon post failed"; return 1; fi
}

mastodon_thread() {
    local full_text="$1" visibility="${2:-public}" instance="${3:-}" delay="${4:-3}"
    [ -z "$full_text" ] && { ui_err "Usage: mastodon_thread <text> [visibility] [instance]"; return 1; }
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        full_text=$(tools_expand_file_refs "$full_text")
    fi
    full_text=$(ui_expand_escapes "$full_text")
    full_text=$(social_sanitize_text "$full_text")
    full_text=$(echo "$full_text" | sed -E 's/^\[George[^]]*\][[:space:]]*//; s/🔏 Signed:.*//')

    local token base; token=$(_mastodon_instance_token "$instance")
    [ -z "$token" ] && { ui_err "Mastodon: No access token configured"; return 1; }
    base=$(_mastodon_instance_url "$instance")

    local chunks_json total_chunks
    local masto_max=${MASTODON_MAX_CHARS:-475}
    chunks_json=$(python3 -c '
import sys, re, json
text = sys.argv[1].strip()
max_len = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 475
domain_tags = sys.argv[3].strip() if len(sys.argv) > 3 else ""

if "---POST---" in text:
    raw_posts = [p.strip() for p in text.split("---POST---") if p.strip()]
elif "===POST===" in text:
    raw_posts = [p.strip() for p in text.split("===POST===") if p.strip()]
else:
    raw_posts = [p.strip() for p in text.split("\n\n") if p.strip()]

def split_sentences_packed(text_block, limit):
    sents = re.split(r"(?<=[.?!])\s+", text_block.strip())
    out = []
    curr = ""
    for s in sents:
        s = s.strip()
        if not s:
            continue
        if len(s) > limit:
            if curr:
                out.append(curr)
                curr = ""
            words = s.split(" ")
            w_curr = ""
            for w in words:
                if len(w_curr) + len(w) + 1 <= limit:
                    w_curr = (w_curr + " " + w).strip() if w_curr else w
                else:
                    if w_curr:
                        out.append(w_curr)
                    w_curr = w
            if w_curr:
                curr = w_curr
        elif len(curr) + len(s) + 1 <= limit:
            curr = (curr + " " + s).strip() if curr else s
        else:
            if curr:
                out.append(curr)
            curr = s
    if curr:
        out.append(curr)
    return out

def pair_split_post(p, max_len=475):
    """
    Cleanly pairs a rich magazine post (600-1100 chars) into at most 2 balanced Mastodon posts
    preserving paragraph breaks (\n\n) and bullet callouts (▸) whenever possible.
    """
    p = p.strip()
    if len(p) <= max_len:
        return [p]

    paras = [sp.strip() for sp in p.split("\n\n") if sp.strip()]
    # Try to split paras into 2 balanced halves (first_half, second_half) each <= max_len
    if len(paras) >= 2:
        best_pair = None
        best_diff = 999999
        for k in range(1, len(paras)):
            left = "\n\n".join(paras[:k])
            right = "\n\n".join(paras[k:])
            if len(left) <= max_len and len(right) <= max_len:
                diff = abs(len(left) - len(right))
                if diff < best_diff:
                    best_diff = diff
                    best_pair = [left, right]
        if best_pair:
            return best_pair

    # Try sentence-level balanced split into 2 halves if total length <= max_len * 2
    sents = re.split(r"(?<=[.?!])\s+(?=[A-Z0-9▸🏛\"'\''(])", p)
    if len(sents) >= 2 and len(p) <= max_len * 2:
        best_pair = None
        best_diff = 999999
        for k in range(1, len(sents)):
            left = " ".join(sents[:k]).strip()
            right = " ".join(sents[k:]).strip()
            if len(left) <= max_len and len(right) <= max_len:
                diff = abs(len(left) - len(right))
                if diff < best_diff:
                    best_diff = diff
                    best_pair = [left, right]
        if best_pair:
            return best_pair

    # Greedy paragraph packing (keeps consecutive short paragraphs together up to max_len)
    res = []
    curr_par = ""
    for par in paras:
        if len(par) <= max_len:
            cand = (curr_par + "\n\n" + par).strip() if curr_par else par
            if len(cand) <= max_len:
                curr_par = cand
            else:
                if curr_par:
                    res.append(curr_par)
                curr_par = par
        else:
            if curr_par:
                res.append(curr_par)
                curr_par = ""
            res.extend(split_sentences_packed(par, max_len))
    if curr_par:
        res.append(curr_par)
    return res

chunks = []
for p in raw_posts:
    chunks.extend(pair_split_post(p, max_len))

if domain_tags and chunks:
    last = chunks[-1]
    if "#" not in last and len(last) + len(domain_tags) + 2 <= max_len:
        chunks[-1] = last + "\n\n" + domain_tags

print(json.dumps(chunks))
' "$full_text" "$masto_max" "${SOCIAL_DOMAIN_HASHTAGS:-}" 2>/dev/null)
    total_chunks=$(echo "$chunks_json" | jq -r '. | length' 2>/dev/null)
    total_chunks="${total_chunks:-0}"

    if [ "$total_chunks" -le 0 ]; then
        ui_err "Mastodon: failed to chunk thread text"
        return 1
    fi

    local first_media_id=""
    if [ -n "${SOCIAL_MEDIA_FILE:-}" ] && [ -f "${SOCIAL_MEDIA_FILE:-}" ]; then
        first_media_id=$(_mastodon_upload_media "$base" "$token" "$SOCIAL_MEDIA_FILE" 2>/dev/null || echo "")
    fi

    if [ "$total_chunks" -eq 1 ]; then
        local data resp url
        if [ -n "$first_media_id" ]; then
            data=$(jq -n --arg s "$full_text" --arg v "$visibility" --arg mid "$first_media_id" '{"status": $s, "visibility": $v, "media_ids": [$mid]}')
        else
            data=$(jq -n --arg s "$full_text" --arg v "$visibility" '{"status": $s, "visibility": $v}')
        fi
        resp=$(api_post "$base/api/v1/statuses" "$data" -H "Authorization: Bearer $token")
        if [ $? -eq 0 ]; then
            url=$(api_json_get "$resp" '.url')
            export LAST_MASTODON_ROOT_URL="$url"
            export LAST_MASTODON_ROOT_ID=$(api_json_get "$resp" '.id')
            ui_ok "Posted to Mastodon: $url"; return 0
        else ui_err "Mastodon post failed"; return 1; fi
    fi

    ui_step "Posting $total_chunks-part thread to Mastodon ($base)..."
    local prev_id="" first_url="" first_id="" i
    for (( i=0; i<total_chunks; i++ )); do
        local chunk part_num=$((i + 1)) post_content post_data resp status
        chunk=$(echo "$chunks_json" | jq -r ".[$i]" | sed -E 's/^\[[0-9]+\/[0-9]+\][[:space:]]*//; s/^[0-9]+\/[0-9]+[[:space:]]*//')
        post_content="[${part_num}/${total_chunks}] ${chunk}"
        if [ -z "$prev_id" ]; then
            if [ -n "$first_media_id" ]; then
                post_data=$(jq -n --arg s "$post_content" --arg v "$visibility" --arg mid "$first_media_id" '{"status": $s, "visibility": $v, "media_ids": [$mid]}')
            else
                post_data=$(jq -n --arg s "$post_content" --arg v "$visibility" '{"status": $s, "visibility": $v}')
            fi
        else
            post_data=$(jq -n --arg s "$post_content" --arg v "$visibility" --arg id "$prev_id" '{"status": $s, "visibility": $v, "in_reply_to_id": $id}')
        fi
        resp=$(api_post "$base/api/v1/statuses" "$post_data" -H "Authorization: Bearer $token"); status=$?
        if [ $status -eq 0 ]; then
            prev_id=$(api_json_get "$resp" '.id')
            local status_url; status_url=$(api_json_get "$resp" '.url')
            if [ -z "$first_url" ]; then
                first_url="$status_url"
                first_id="$prev_id"
            fi
            ui_info "  Part ${part_num}/${total_chunks}: $status_url"
            [ "$part_num" -lt "$total_chunks" ] && sleep "$delay"
        else
            ui_err "Failed at part ${part_num}/${total_chunks}"; return 1
        fi
    done
    if [ -z "$first_url" ]; then
        ui_err "Failed to publish thread to Mastodon (no URL returned)"; return 1
    fi
    export LAST_MASTODON_ROOT_URL="$first_url"
    export LAST_MASTODON_ROOT_ID="$first_id"
    ui_ok "Published full thread to Mastodon: $first_url"; return 0
}

mastodon_validate() {
    local instance_name="${1:-}"
    local base; base=$(_mastodon_base "$instance_name")
    local token; token=$(_mastodon_instance_token "$instance_name")
    [ -z "$base" ] && { ui_err "No Mastodon instance configured"; return 1; }
    [ -z "$token" ] && { ui_err "No access token found for Mastodon instance"; return 1; }
    ui_step "Validating Mastodon credentials ($base)..."
    local resp; resp=$(curl -sf -H "Authorization: Bearer $token" "${base}/api/v1/accounts/verify_credentials" 2>/dev/null)
    local uname; uname=$(echo "$resp" | jq -r '.username // empty' 2>/dev/null)
    if [ -n "$uname" ]; then
        ui_ok "Mastodon credentials valid: @${uname}@$(echo "$base" | sed 's|https\?://||')"; return 0
    fi
    ui_err "Mastodon validation failed for $base"; return 1
}

mastodon_timeline() {
    local count="${1:-20}" instance="${2:-}" token base
    token=$(_mastodon_instance_token "$instance") || return 1
    base=$(_mastodon_instance_url "$instance")
    api_get "$base/api/v1/timelines/home?limit=$count" -H "Authorization: Bearer $token" | jq -r '.[]? | "[\(.account.acct)] \(.content | gsub("<[^>]+>"; ""))"' 2>/dev/null
}

mastodon_reply() {
    local status_id="$1" text="$2" instance="${3:-}" token base data
    token=$(_mastodon_instance_token "$instance") || return 1
    base=$(_mastodon_instance_url "$instance")
    data=$(jq -n --arg s "$text" --arg id "$status_id" '{"status": $s, "in_reply_to_id": $id}')
    api_post "$base/api/v1/statuses" "$data" -H "Authorization: Bearer $token"
}

mastodon_search() {
    local query="$1" instance="${2:-}" token base encoded
    token=$(_mastodon_instance_token "$instance") || return 1
    base=$(_mastodon_instance_url "$instance")
    encoded=$(printf '%s' "$query" | jq -sRr @uri)
    api_get "$base/api/v2/search?q=$encoded&type=statuses&limit=10" -H "Authorization: Bearer $token" | jq -r '.statuses[]? | "[\(.account.acct)] \(.content | gsub("<[^>]+>"; ""))"' 2>/dev/null
}

mastodon_notifications() {
    local count="${1:-10}" instance="${2:-}" token base
    token=$(_mastodon_instance_token "$instance") || return 1
    base=$(_mastodon_instance_url "$instance")
    api_get "$base/api/v1/notifications?limit=$count" -H "Authorization: Bearer $token" | jq -r '.[]? | "\(.type): @\(.account.acct) — \(.status.content // "" | gsub("<[^>]+>"; "") | .[0:100])"' 2>/dev/null
}

_BLUESKY_SESSION=""

_bluesky_login() {
    local handle password data resp
    handle=$(api_require_key "BLUESKY_HANDLE" "Bluesky") || return 1
    password=$(api_require_key "BLUESKY_APP_PASSWORD" "Bluesky") || return 1
    data=$(jq -n --arg h "$handle" --arg p "$password" '{"identifier": $h, "password": $p}')
    resp=$(api_post "https://bsky.social/xrpc/com.atproto.server.createSession" "$data")
    if [ $? -eq 0 ]; then _BLUESKY_SESSION="$resp"; return 0; fi
    ui_err "Bluesky login failed"; return 1
}

_bluesky_token() {
    [ -z "$_BLUESKY_SESSION" ] && { _bluesky_login || return 1; }
    api_json_get "$_BLUESKY_SESSION" '.accessJwt'
}

_bluesky_did() {
    [ -z "$_BLUESKY_SESSION" ] && { _bluesky_login || return 1; }
    api_json_get "$_BLUESKY_SESSION" '.did'
}

_bluesky_build_facets_json() {
    local text="$1"
    python3 -c '
import sys, re, json
text = sys.argv[1]
facets = []
# Match https:// URLs
for m in re.finditer(r"https?://[^\s\)\]>\"'\'']+", text):
    url = m.group(0).rstrip(".,;:!?")
    start_char = m.start()
    end_char = start_char + len(url)
    b_start = len(text[:start_char].encode("utf-8"))
    b_end = len(text[:end_char].encode("utf-8"))
    facets.append({
        "index": {"byteStart": b_start, "byteEnd": b_end},
        "features": [{"$type": "app.bsky.richtext.facet#link", "uri": url}]
    })
# Match #hashtags
for m in re.finditer(r"(?<!\w)#([A-Za-z][A-Za-z0-9_]{1,35})", text):
    tag = m.group(1)
    b_start = len(text[:m.start()].encode("utf-8"))
    b_end = len(text[:m.end()].encode("utf-8"))
    facets.append({
        "index": {"byteStart": b_start, "byteEnd": b_end},
        "features": [{"$type": "app.bsky.richtext.facet#tag", "tag": tag}]
    })
print(json.dumps(facets))
' "$text" 2>/dev/null || echo "[]"
}

_bluesky_upload_blob() {
    local token="$1" media_file="$2"
    [ -z "$media_file" ] || [ ! -f "$media_file" ] && return 1
    [ "${_LODGE_TESTING:-0}" -eq 1 ] && return 1
    local resp blob_json
    resp=$(curl -sf --max-time 25 -X POST "https://bsky.social/xrpc/com.atproto.repo.uploadBlob" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: image/png" \
        --data-binary "@${media_file}" 2>/dev/null || echo "")
    blob_json=$(echo "$resp" | jq -c '.blob // empty' 2>/dev/null)
    if [ -n "$blob_json" ] && [ "$blob_json" != "null" ]; then
        echo "$blob_json"
        return 0
    fi
    return 1
}

bluesky_post() {
    if ! social_is_platform_allowed "bluesky"; then
        ui_warn "Bluesky broadcast aborted: Social gate is locked (GLOBAL_SOCIAL_ENABLED or BLUESKY_ENABLED is disabled)."
        return 1
    fi
    local text="$1"
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        text=$(tools_expand_file_refs "$text")
    fi
    text=$(ui_expand_escapes "$text")
    text=$(social_sanitize_text "$text")
    if [ "${#text}" -gt 295 ] || [[ "$text" =~ (---POST---|===POST===) ]]; then
        bluesky_thread "$text"
        return $?
    fi
    local token did now data resp facets_json
    [ -z "$_BLUESKY_SESSION" ] && { _bluesky_login || return 1; }
    token=$(_bluesky_token) || return 1
    did=$(_bluesky_did) || return 1
    now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    facets_json=$(_bluesky_build_facets_json "$text")
    if [ -n "$facets_json" ] && [ "$facets_json" != "[]" ]; then
        data=$(jq -n --arg did "$did" --arg text "$text" --arg now "$now" --argjson facets "$facets_json" \
            '{"repo": $did, "collection": "app.bsky.feed.post", "record": {"$type": "app.bsky.feed.post", "text": $text, "createdAt": $now, "facets": $facets}}')
    else
        data=$(jq -n --arg did "$did" --arg text "$text" --arg now "$now" \
            '{"repo": $did, "collection": "app.bsky.feed.post", "record": {"$type": "app.bsky.feed.post", "text": $text, "createdAt": $now}}')
    fi
    resp=$(api_post "https://bsky.social/xrpc/com.atproto.repo.createRecord" "$data" -H "Authorization: Bearer $token")
    if [ $? -eq 0 ]; then
        local uri; uri=$(api_json_get "$resp" '.uri')
        export LAST_BLUESKY_ROOT_URI="$uri"
        ui_ok "Posted to Bluesky ($uri)"; echo "$resp"
    else ui_err "Bluesky post failed"; return 1; fi
}

bluesky_thread() {
    if ! social_is_platform_allowed "bluesky"; then
        ui_warn "Bluesky broadcast aborted: Social gate is locked (GLOBAL_SOCIAL_ENABLED or BLUESKY_ENABLED is disabled)."
        return 1
    fi
    local full_text="$1" delay="${2:-2}"
    [ -z "$full_text" ] && { ui_err "Usage: bluesky_thread <text>"; return 1; }
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        full_text=$(tools_expand_file_refs "$full_text")
    fi
    full_text=$(ui_expand_escapes "$full_text")
    full_text=$(social_sanitize_text "$full_text")
    full_text=$(echo "$full_text" | sed -E 's/^\[George[^]]*\][[:space:]]*//; s/🔏 Signed:.*//')

    local token did
    [ -z "$_BLUESKY_SESSION" ] && { _bluesky_login || return 1; }
    token=$(_bluesky_token) || return 1
    did=$(_bluesky_did) || return 1

    local bsky_max=${BLUESKY_MAX_CHARS:-278}
    local chunks_json total_chunks
    chunks_json=$(python3 -c '
import sys, re, json
text = sys.argv[1].strip()
max_len = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 278

if "---POST---" in text:
    raw_posts = [p.strip() for p in text.split("---POST---") if p.strip()]
elif "===POST===" in text:
    raw_posts = [p.strip() for p in text.split("===POST===") if p.strip()]
else:
    raw_posts = [p.strip() for p in text.split("\n\n") if p.strip()]

def chunk_bsky(p, limit):
    p = re.sub(r"\n{2,}", "\n", p.strip())
    if len(p) <= limit:
        return [p]
    sents = re.split(r"(?<=[.?!])\s+", p)
    out = []
    curr = ""
    for s in sents:
        s = s.strip()
        if not s:
            continue
        if len(s) > limit:
            if curr:
                out.append(curr)
                curr = ""
            words = s.split(" ")
            w_curr = ""
            for w in words:
                if len(w_curr) + len(w) + 1 <= limit:
                    w_curr = (w_curr + " " + w).strip() if w_curr else w
                else:
                    if w_curr:
                        out.append(w_curr)
                    w_curr = w[:limit]
            if w_curr:
                curr = w_curr
        elif len(curr) + len(s) + 1 <= limit:
            curr = (curr + " " + s).strip() if curr else s
        else:
            if curr:
                out.append(curr)
            curr = s
    if curr:
        out.append(curr)
    return out

chunks = []
for p in raw_posts:
    chunks.extend(chunk_bsky(p, max_len))
print(json.dumps(chunks))
' "$full_text" "$bsky_max" 2>/dev/null)

    total_chunks=$(echo "$chunks_json" | jq -r '. | length' 2>/dev/null)
    total_chunks="${total_chunks:-0}"
    if [ "$total_chunks" -le 0 ]; then
        ui_err "Bluesky: failed to chunk thread text"
        return 1
    fi

    local first_blob=""
    if [ -n "${SOCIAL_MEDIA_FILE:-}" ] && [ -f "${SOCIAL_MEDIA_FILE:-}" ]; then
        first_blob=$(_bluesky_upload_blob "$token" "$SOCIAL_MEDIA_FILE" 2>/dev/null || echo "")
    fi

    ui_step "Posting $total_chunks-part thread to Bluesky..."
    local root_uri="" root_cid="" parent_uri="" parent_cid="" i
    for (( i=0; i<total_chunks; i++ )); do
        local chunk part_num=$((i + 1)) post_content now facets_json record_json post_data resp status
        chunk=$(echo "$chunks_json" | jq -r ".[$i]" | sed -E 's/^\[[0-9]+\/[0-9]+\][[:space:]]*//; s/^[0-9]+\/[0-9]+[[:space:]]*//')
        if [ "$total_chunks" -gt 1 ]; then
            post_content="[${part_num}/${total_chunks}] ${chunk}"
        else
            post_content="${chunk}"
        fi
        now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
        facets_json=$(_bluesky_build_facets_json "$post_content")

        record_json=$(jq -n --arg text "$post_content" --arg now "$now" \
            '{"$type": "app.bsky.feed.post", "text": $text, "createdAt": $now}')

        if [ -n "$facets_json" ] && [ "$facets_json" != "[]" ]; then
            record_json=$(echo "$record_json" | jq --argjson f "$facets_json" '. + {facets: $f}')
        fi

        if [ -z "$root_uri" ]; then
            if [ -n "$first_blob" ]; then
                record_json=$(echo "$record_json" | jq --argjson b "$first_blob" \
                    '. + {embed: {"$type": "app.bsky.embed.images", images: [{alt: "Blue Lodge Sovereign Research Monograph Plate", image: $b}]}}')
            fi
        else
            record_json=$(echo "$record_json" | jq --arg r_uri "$root_uri" --arg r_cid "$root_cid" --arg p_uri "$parent_uri" --arg p_cid "$parent_cid" \
                '. + {reply: {root: {uri: $r_uri, cid: $r_cid}, parent: {uri: $p_uri, cid: $p_cid}}}')
        fi

        post_data=$(jq -n --arg did "$did" --argjson rec "$record_json" \
            '{"repo": $did, "collection": "app.bsky.feed.post", "record": $rec}')

        resp=$(api_post "https://bsky.social/xrpc/com.atproto.repo.createRecord" "$post_data" -H "Authorization: Bearer $token"); status=$?
        if [ $status -eq 0 ]; then
            parent_uri=$(api_json_get "$resp" '.uri')
            parent_cid=$(api_json_get "$resp" '.cid')
            [ -z "$parent_cid" ] && parent_cid="cid-${part_num}"
            if [ -z "$root_uri" ]; then
                root_uri="$parent_uri"
                root_cid="$parent_cid"
            fi
            ui_info "  Part ${part_num}/${total_chunks}: $parent_uri"
            [ "$part_num" -lt "$total_chunks" ] && sleep "$delay"
        else
            ui_err "Bluesky thread failed at part ${part_num}/${total_chunks}"
            return 1
        fi
    done
    export LAST_BLUESKY_ROOT_URI="$root_uri"
    ui_ok "Published full thread to Bluesky ($root_uri)"
    return 0
}

bluesky_timeline() {
    local count="${1:-20}" token; token=$(_bluesky_token) || return 1
    api_get "https://bsky.social/xrpc/app.bsky.feed.getTimeline?limit=$count" -H "Authorization: Bearer $token" | jq -r '.feed[]? | "[\(.post.author.handle)] \(.post.record.text)"' 2>/dev/null
}

bluesky_search() {
    local query="$1" count="${2:-10}" token encoded
    token=$(_bluesky_token) || return 1
    encoded=$(printf '%s' "$query" | jq -sRr @uri)
    api_get "https://bsky.social/xrpc/app.bsky.feed.searchPosts?q=$encoded&limit=$count" -H "Authorization: Bearer $token" | jq -r '.posts[]? | "[\(.author.handle)] \(.record.text)"' 2>/dev/null
}


DISCORD_CHANNELS_DB="${DISCORD_CHANNELS_DB:-${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/discord_channels.db}"

discord_webhook() {
    local message="$1"
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        message=$(tools_expand_file_refs "$message")
    fi
    message=$(ui_expand_escapes "$message")
    local webhook_url; webhook_url=$(api_require_key "DISCORD_WEBHOOK_URL" "Discord Webhook") || return 1
    local data; data=$(jq -n --arg c "$message" --arg u "${2:-George}" '{"content": $c, "username": $u}')
    api_post "$webhook_url" "$data" > /dev/null
    if [ $? -eq 0 ] || [ "${_API_LAST_STATUS:-}" = "204" ]; then
        ui_ok "Sent to Discord"
    else
        local err_msg; err_msg=$(api_json_get "${_API_LAST_BODY:-}" '.message // .error // "unknown error"')
        ui_err "Discord webhook failed (HTTP ${_API_LAST_STATUS:-unknown}): $err_msg"
        return 1
    fi
}

discord_send() {
    local channel_id="$1" message="$2"
    channel_id=$(echo "$channel_id" | sed "s/^[\"']//; s/[\"']$//")
    message=$(echo "$message" | sed "s/^[\"']//; s/[\"']$//")

    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        message=$(tools_expand_file_refs "$message")
    fi
    message=$(ui_expand_escapes "$message")

    local _preview_len="${AGENT_SOCIAL_RECEIPT_MAX_CHARS:-4000}" _preview="$message"
    [ ${#_preview} -gt "$_preview_len" ] && _preview="${_preview:0:$_preview_len} ... (truncated: total ${#message} chars)"

    if [ "${_DISCORD_IN_DM:-0}" -ne 1 ]; then
        if [[ "$channel_id" == dm:* ]]; then
            _DISCORD_IN_DM=1 discord_dm "${channel_id#dm:}" "$message"; return $?
        fi
        if [[ "$channel_id" =~ ^[0-9]+$ ]]; then
            _discord_users_init 2>/dev/null || true; _discord_channels_init 2>/dev/null || true
            local is_chan is_usr
            is_chan=$(sqlite3 "$DISCORD_CHANNELS_DB" "SELECT 1 FROM channels WHERE channel_id = '$channel_id' LIMIT 1;" 2>/dev/null || true)
            if [ -z "$is_chan" ]; then
                is_usr=$(sqlite3 "$DISCORD_USERS_DB" "SELECT 1 FROM users WHERE user_id = '$channel_id' LIMIT 1;" 2>/dev/null || true)
                [ -n "$is_usr" ] && { _DISCORD_IN_DM=1 discord_dm "$channel_id" "$message"; return $?; }
            fi
        else
            local resolved; resolved=$(discord_channel_resolve "$channel_id")
            if [ -z "$resolved" ]; then
                local usr_resolved; usr_resolved=$(discord_user_resolve "$channel_id" 2>/dev/null || true)
                [ -n "$usr_resolved" ] && { _DISCORD_IN_DM=1 discord_dm "$usr_resolved" "$message"; return $?; }
                ui_err "Unknown channel or user: $channel_id"; return 1
            fi
            channel_id="$resolved"
        fi
    fi

    if [[ "$message" == *"@"* ]] && declare -f discord_resolve_mentions &>/dev/null; then
        message=$(discord_resolve_mentions "$message")
    fi

    local token; token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1

    if [ ${#message} -gt 2000 ]; then
        local _chunks=() _chunk="" _line
        while IFS= read -r _line || [ -n "$_line" ]; do
            if [ -n "$_chunk" ] && [ $(( ${#_chunk} + ${#_line} + 1 )) -gt 2000 ]; then
                _chunks+=("$_chunk"); _chunk=""
            fi
            if [ ${#_line} -gt 2000 ]; then
                [ -n "$_chunk" ] && { _chunks+=("$_chunk"); _chunk=""; }
                while [ ${#_line} -gt 2000 ]; do _chunks+=("${_line:0:2000}"); _line="${_line:2000}"; done
                [ -n "$_line" ] && _chunk="$_line"
            else
                [ -n "$_chunk" ] && _chunk+=$'\n'
                _chunk+="$_line"
            fi
        done <<< "$message"
        [ -n "$_chunk" ] && _chunks+=("$_chunk")

        local _chunk_count=${#_chunks[@]} _chunk_i=0 _chunk_ok=0
        for _ci in "${_chunks[@]}"; do
            _chunk_i=$((_chunk_i + 1))
            local data; data=$(jq -n --arg c "$_ci" '{"content": $c}')
            api_post "https://discord.com/api/v10/channels/$channel_id/messages" "$data" -H "Authorization: Bot $token" > /dev/null
            if [ $? -eq 0 ]; then
                _chunk_ok=$((_chunk_ok + 1))
                declare -f discord_outbox_record &>/dev/null && \
                    discord_outbox_record "$channel_id" "$(jq -r '.id // empty' <<<"${_API_LAST_BODY:-}" 2>/dev/null)" "$_ci" "send"
            fi
            [ $_chunk_i -lt $_chunk_count ] && sleep 0.5
        done
        if [ "$_chunk_ok" -eq "$_chunk_count" ]; then
            if [[ "$message" =~ [Pp]-[0-9A-Fa-f]{6} ]]; then
                local _py_tp="${LODGE_DIR:-$HOME/blue-lodge}/.venv/bin/python"
                [ -x "$_py_tp" ] || _py_tp="python3"
                "$_py_tp" "${LODGE_DIR:-$HOME/blue-lodge}/lib/tools/trading/agent_tools.py" touch-plans --text "$message" >/dev/null 2>&1 || true
            fi
            ui_ok "Sent to Discord (channel: $channel_id) — ${_chunk_count} parts"; sleep 1
            echo "--- Transmission Receipt ---"
            echo "Payload transmitted successfully (chunked)."
            echo "Content sent:"
            echo "$_preview"
            echo "----------------------------"
        else ui_warn "Discord: ${_chunk_ok}/${_chunk_count} message parts sent (channel: $channel_id)"; fi
        return 0
    fi

    local data resp status; data=$(jq -n --arg c "$message" '{"content": $c}')
    api_post "https://discord.com/api/v10/channels/$channel_id/messages" "$data" -H "Authorization: Bot $token" > /dev/null
    status=$?
    if [ $status -eq 0 ]; then
        declare -f discord_outbox_record &>/dev/null && \
            discord_outbox_record "$channel_id" "$(jq -r '.id // empty' <<<"${_API_LAST_BODY:-}" 2>/dev/null)" "$message" "send"
        if [[ "$message" =~ [Pp]-[0-9A-Fa-f]{6} ]]; then
            local _py_tp="${LODGE_DIR:-$HOME/blue-lodge}/.venv/bin/python"
            [ -x "$_py_tp" ] || _py_tp="python3"
            "$_py_tp" "${LODGE_DIR:-$HOME/blue-lodge}/lib/tools/trading/agent_tools.py" touch-plans --text "$message" >/dev/null 2>&1 || true
        fi
        ui_ok "Sent to Discord (channel: $channel_id)"; sleep 1
        echo "--- Transmission Receipt ---"
        echo "Payload transmitted successfully."
        echo "Content sent:"
        echo "$_preview"
        echo "----------------------------"
    else
        local err_msg err_code
        err_msg=$(api_json_get "${_API_LAST_BODY:-}" '.message // .error // "unknown error"')
        err_code=$(api_json_get "${_API_LAST_BODY:-}" '.code // empty')
        ui_err "Discord send failed (HTTP ${_API_LAST_STATUS:-unknown}): $err_msg${err_code:+ (code: $err_code)}"
        ui_dim "Channel: $channel_id"
        return 1
    fi
}

discord_read() {
    local channel_id="$1" count="${2:-10}"
    if ! [[ "$channel_id" =~ ^[0-9]+$ ]]; then
        local resolved; resolved=$(discord_channel_resolve "$channel_id")
        [ -z "$resolved" ] && { ui_err "Unknown channel: $channel_id"; return 1; }
        channel_id="$resolved"
    fi
    local token; token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1
    api_get "https://discord.com/api/v10/channels/$channel_id/messages?limit=$count" -H "Authorization: Bot $token" | jq -r '.[]? | "[\(.author.username)] \(.content)"' 2>/dev/null
}

discord_validate() {
    local token resp
    token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1
    ui_info "Validating Discord bot token..."
    resp=$(api_get "https://discord.com/api/v10/users/@me" -H "Authorization: Bot $token")
    [ $? -ne 0 ] && { ui_err "Token validation FAILED: $(api_json_get "${_API_LAST_BODY:-}" '.message // "unknown error"')\n"; return 1; }
    local bot_name bot_id guilds
    bot_name=$(api_json_get "$resp" '.username'); bot_id=$(api_json_get "$resp" '.id')
    ui_ok "Token valid — Bot: ${bot_name} (ID: ${bot_id})"
    guilds=$(api_get "https://discord.com/api/v10/users/@me/guilds" -H "Authorization: Bot $token" 2>/dev/null)
    [ -n "$guilds" ] && echo "$guilds" | jq -r '.[]? | "  \(.name) (ID: \(.id))"' 2>/dev/null
}

_discord_channels_init() {
    command -v sqlite3 &>/dev/null || { ui_err "sqlite3 required for channel registry"; return 1; }
    mkdir -p "$(dirname "$DISCORD_CHANNELS_DB")"
    sqlite3 "$DISCORD_CHANNELS_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS channels (
    name TEXT NOT NULL COLLATE NOCASE,
    channel_id TEXT NOT NULL UNIQUE,
    guild_name TEXT DEFAULT '',
    guild_id TEXT DEFAULT '',
    type TEXT DEFAULT 'text',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_channels_name_guild ON channels(name, guild_id);
SQL
}

discord_channel_resolve() {
    local name="$1"
    name="${name#\#}"
    name=$(echo "$name" | sed 's/^["'\''"'\'']*//; s/["'\''"'\'']*$//')
    name="${name#\#}"
    _discord_channels_init 2>/dev/null || return 1
    local cid
    cid=$(sqlite3 "$DISCORD_CHANNELS_DB" "SELECT channel_id FROM channels WHERE name = '${name//\'/\'\'}' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    [ -n "$cid" ] && { echo "$cid"; return 0; }
    sqlite3 "$DISCORD_CHANNELS_DB" "SELECT channel_id FROM channels WHERE guild_name = '${name//\'/\'\'}' COLLATE NOCASE ORDER BY CASE WHEN name = 'general' THEN 0 ELSE 1 END LIMIT 1;" 2>/dev/null
}

discord_channel_add() {
    local name="$1" channel_id="$2" guild_name="${3:-}" guild_id="${4:-}"
    name="${name#\#}"
    _discord_channels_init || return 1
    sqlite3 "$DISCORD_CHANNELS_DB" "INSERT OR REPLACE INTO channels(name, channel_id, guild_name, guild_id) VALUES ('${name//\'/\'\'}', '${channel_id//\'/\'\'}', '${guild_name//\'/\'\'}', '${guild_id//\'/\'\'}');"
    ui_ok "Registered channel #${name} → ${channel_id}${guild_name:+ (${guild_name})}"
}

discord_channel_remove() {
    local name="$1"
    name="${name#\#}"
    _discord_channels_init || return 1
    sqlite3 "$DISCORD_CHANNELS_DB" "DELETE FROM channels WHERE name = '${name//\'/\'\'}' COLLATE NOCASE;"
    ui_ok "Removed channel #${name}"
}

discord_channel_list() {
    _discord_channels_init || return 1
    local count; count=$(sqlite3 "$DISCORD_CHANNELS_DB" "SELECT COUNT(*) FROM channels;" 2>/dev/null)
    [ "${count:-0}" -eq 0 ] && { ui_dim "No channels registered"; return; }
    ui_section "Discord Channels ($count)"
    sqlite3 -separator ' | ' "$DISCORD_CHANNELS_DB" "SELECT '#' || name, channel_id, COALESCE(NULLIF(guild_name,''), '(no guild)') FROM channels ORDER BY guild_name, name;" 2>/dev/null | while IFS= read -r line; do
        printf "  %s\n" "$line"
    done
}

social_context_compact() {
    local _out=""
    if [ -n "${DISCORD_CHANNELS_DB:-}" ] && [ -f "$DISCORD_CHANNELS_DB" ] && command -v sqlite3 &>/dev/null; then
        local _ch_count; _ch_count=$(sqlite3 "$DISCORD_CHANNELS_DB" "SELECT COUNT(*) FROM channels;" 2>/dev/null || echo 0)
        if [ "${_ch_count:-0}" -gt 0 ]; then
            local _ch_list; _ch_list=$(sqlite3 "$DISCORD_CHANNELS_DB" "SELECT name || ' (' || COALESCE(NULLIF(guild_name,''), '?') || ')' FROM channels ORDER BY guild_name, name;" 2>/dev/null)
            _out="Discord channels: ${_ch_list//$'\n'/, }"
        fi
    fi
    if [ -n "${MASTODON_INSTANCES_DB:-}" ] && [ -f "$MASTODON_INSTANCES_DB" ] && command -v sqlite3 &>/dev/null; then
        local _mi_count; _mi_count=$(sqlite3 "$MASTODON_INSTANCES_DB" "SELECT COUNT(*) FROM instances;" 2>/dev/null || echo 0)
        if [ "${_mi_count:-0}" -gt 0 ]; then
            local _mi_list; _mi_list=$(sqlite3 "$MASTODON_INSTANCES_DB" "SELECT COALESCE(NULLIF(display_name,''), instance_url) FROM instances ORDER BY instance_url;" 2>/dev/null)
            [ -n "$_out" ] && _out="${_out}\n"
            _out="${_out}Mastodon instances: ${_mi_list//$'\n'/, }"
        fi
    fi
    echo -e "$_out"
}

discord_channels_sync() {
    local token; token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1
    _discord_channels_init || return 1
    ui_info "Fetching guilds..."
    local guilds; guilds=$(api_get "https://discord.com/api/v10/users/@me/guilds" -H "Authorization: Bot $token")
    [ $? -ne 0 ] && { ui_err "Failed to fetch guilds"; return 1; }
    local guild_count; guild_count=$(echo "$guilds" | jq 'length' 2>/dev/null)
    [ "${guild_count:-0}" -eq 0 ] && { ui_warn "Bot is not in any servers"; return 1; }
    local total_added=0
    echo "$guilds" | jq -r '.[]? | "\(.id) \(.name)"' 2>/dev/null | while IFS=' ' read -r gid gname; do
        ui_dim "  Syncing: $gname ($gid)..."
        local channels; channels=$(api_get "https://discord.com/api/v10/guilds/$gid/channels" -H "Authorization: Bot $token")
        [ $? -ne 0 ] && continue
        echo "$channels" | jq -r '.[]? | select(.type == 0 or .type == 5) | "\(.id) \(.name)"' 2>/dev/null | while IFS=' ' read -r cid cname; do
            sqlite3 "$DISCORD_CHANNELS_DB" "INSERT OR REPLACE INTO channels(name, channel_id, guild_name, guild_id, type) VALUES ('${cname//\'/\'\'}', '${cid//\'/\'\'}', '${gname//\'/\'\'}', '${gid//\'/\'\'}', 'text');" 2>/dev/null
            total_added=$((total_added + 1))
        done
    done
    local final_count; final_count=$(sqlite3 "$DISCORD_CHANNELS_DB" "SELECT COUNT(*) FROM channels;" 2>/dev/null)
    ui_ok "Channel registry synced — $final_count channels total"
}

discord_default_channel() {
    local explicit; explicit=$(api_get_key "DISCORD_DEFAULT_CHANNEL" 2>/dev/null)
    if [ -n "$explicit" ]; then
        if [[ "$explicit" =~ ^[0-9]+$ ]]; then echo "$explicit"; else discord_channel_resolve "$explicit"; fi
        return
    fi
    _discord_channels_init 2>/dev/null || return 1
    local cid; cid=$(sqlite3 "$DISCORD_CHANNELS_DB" "SELECT channel_id FROM channels WHERE name = 'general' LIMIT 1;" 2>/dev/null)
    [ -n "$cid" ] && { echo "$cid"; return; }
    sqlite3 "$DISCORD_CHANNELS_DB" "SELECT channel_id FROM channels LIMIT 1;" 2>/dev/null
}

DISCORD_USERS_DB="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/discord_users.db"
if [ ! -f "$DISCORD_USERS_DB" ]; then
    for _alt_db in "${LODGE_DIR:-}/.george/discord_users.db" "$HOME/.george/discord_users.db" "$HOME/blue-lodge/.george/discord_users.db"; do
        if [ -n "$_alt_db" ] && [ -f "$_alt_db" ]; then
            DISCORD_USERS_DB="$_alt_db"
            break
        fi
    done
fi

_discord_users_init() {
    command -v sqlite3 &>/dev/null || { ui_err "sqlite3 required for user registry"; return 1; }
    mkdir -p "$(dirname "$DISCORD_USERS_DB")"
    sqlite3 "$DISCORD_USERS_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS users (
    username TEXT NOT NULL COLLATE NOCASE,
    display_name TEXT DEFAULT '',
    user_id TEXT NOT NULL UNIQUE,
    guild_name TEXT DEFAULT '',
    guild_id TEXT DEFAULT '',
    is_bot INTEGER DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username COLLATE NOCASE);
SQL
}

discord_user_resolve() {
    local name="$1"
    name="${name#@}"
    name=$(echo "$name" | sed 's/^["'\'']*//; s/["'\'']*$//')
    name="${name#@}"
    if [[ "$name" == *@* ]]; then
        local _clean_name="" _part
        IFS='@' read -ra _parts <<< "$name"
        for _part in "${_parts[@]}"; do
            [ -z "$_part" ] && continue
            [[ "$_part" == *.* ]] && continue
            _clean_name="$_part"; break
        done
        [ -n "$_clean_name" ] && name="$_clean_name"
    fi
    name=$(echo "$name" | sed 's/[,;:!?.]*$//')
    [ -z "$name" ] && return 1
    _discord_users_init 2>/dev/null || return 1
    local _safe="${name//\'/\'\'}" _lower; _lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    local _cfg_owner_u; _cfg_owner_u="$(api_get_key "DISCORD_OWNER_USERNAMES" 2>/dev/null || api_get_key "DISCORD_OWNER_USERNAME" 2>/dev/null || api_get_key "DISCORD_DEFAULT_USER" 2>/dev/null || api_get_key "OPERATOR_DISCORD_HANDLE" 2>/dev/null || api_get_key "OPERATOR_HANDLE" 2>/dev/null || true)"
    local _owner_candidates="${DISCORD_OWNER_USERNAMES:-${DISCORD_OWNER_USERNAME:-${DISCORD_DEFAULT_USER:-${OPERATOR_DISCORD_HANDLE:-${OPERATOR_HANDLE:-${_cfg_owner_u:-operator}}}}}}"
    local _is_owner_alias=0
    if [ "$_lower" = "me" ] || [ "$_lower" = "operator" ] || [ "$_lower" = "owner" ] || [ "$_lower" = "self" ]; then
        _is_owner_alias=1
    else
        IFS=',' read -ra _oc_list <<< "$_owner_candidates"
        for _oc in "${_oc_list[@]}"; do
            local _oc_clean; _oc_clean=$(echo "$_oc" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            [ -z "$_oc_clean" ] && continue
            local _oc_clean_no_us="${_oc_clean%_}"
            local _lower_no_us="${_lower%_}"
            if [ "$_lower" = "$_oc_clean" ] || [ "$_lower_no_us" = "$_oc_clean_no_us" ]; then
                _is_owner_alias=1
                break
            fi
        done
    fi
    if [ "$_is_owner_alias" -eq 1 ]; then
        local _def_user="${DISCORD_DEFAULT_USER:-${DISCORD_OWNER_USERNAME:-${OPERATOR_DISCORD_HANDLE:-${OPERATOR_HANDLE:-${_cfg_owner_u:-operator}}}}}" _uid
        _uid=$(sqlite3 "$DISCORD_USERS_DB" "SELECT user_id FROM users WHERE username = '${_def_user//\'/\'\'}' OR display_name = '${_def_user//\'/\'\'}' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
        [ -n "$_uid" ] && { echo "$_uid"; return 0; }
        if [[ "$_def_user" == *_ ]]; then
            local _no_us="${_def_user%_}"
            _uid=$(sqlite3 "$DISCORD_USERS_DB" "SELECT user_id FROM users WHERE username = '${_no_us//\'/\'\'}' OR display_name = '${_no_us//\'/\'\'}' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
        else
            local _with_us="${_def_user}_"
            _uid=$(sqlite3 "$DISCORD_USERS_DB" "SELECT user_id FROM users WHERE username = '${_with_us//\'/\'\'}' OR display_name = '${_with_us//\'/\'\'}' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
        fi
        [ -n "$_uid" ] && { echo "$_uid"; return 0; }
    fi
    local uid
    uid=$(sqlite3 "$DISCORD_USERS_DB" "SELECT user_id FROM users WHERE username = '$_safe' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    [ -n "$uid" ] && { echo "$uid"; return 0; }
    # Try with/without trailing underscore (e.g. handle <-> handle_)
    local _alt_safe
    if [[ "$_safe" == *_ ]]; then
        _alt_safe="${_safe%_}"
    else
        _alt_safe="${_safe}_"
    fi
    uid=$(sqlite3 "$DISCORD_USERS_DB" "SELECT user_id FROM users WHERE username = '$_alt_safe' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    [ -n "$uid" ] && { echo "$uid"; return 0; }
    uid=$(sqlite3 "$DISCORD_USERS_DB" "SELECT user_id FROM users WHERE display_name = '$_safe' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    [ -n "$uid" ] && { echo "$uid"; return 0; }
    uid=$(sqlite3 "$DISCORD_USERS_DB" "SELECT user_id FROM users WHERE username LIKE '$_safe%' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    [ -n "$uid" ] && { echo "$uid"; return 0; }
    uid=$(sqlite3 "$DISCORD_USERS_DB" "SELECT user_id FROM users WHERE display_name LIKE '$_safe%' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    [ -n "$uid" ] && { echo "$uid"; return 0; }
    uid=$(sqlite3 "$DISCORD_USERS_DB" "SELECT user_id FROM users WHERE username LIKE '%$_safe%' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    [ -n "$uid" ] && { echo "$uid"; return 0; }
    uid=$(sqlite3 "$DISCORD_USERS_DB" "SELECT user_id FROM users WHERE display_name LIKE '%$_safe%' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    [ -n "$uid" ] && echo "$uid"
}

discord_dm_parse_recipients() {
    local text="$1" scan_chars="${2:-${AGENT_DM_SCAN_CHARS:-80}}"
    _DM_RESOLVED_IDS=(); _DM_MESSAGE=""
    local _consumed=0 _words_consumed=0 _pending_connectors=0 _word
    for _word in $text; do
        [ $_consumed -ge "$scan_chars" ] && break
        _consumed=$(( _consumed + ${#_word} + 1 ))
        case "${_word,,}" in
            and|"&"|","|"+") _pending_connectors=$((_pending_connectors + 1)); continue ;;
        esac
        local _clean_word; _clean_word=$(echo "${_word,,}" | tr -d '"@,;:!?.' | tr -d "'")
        case "$_clean_word" in
            the|a|an|to|for|of|in|on|at|with|by|as|from|into|about|like|this|that|it|its|they|them|he|him|she|her|you|your|me|my|we|us|our|is|am|are|was|were|be|been|have|has|had|do|does|did|will|would|shall|should|can|could|may|might|must|send|write|report|contents|file|message|text|here)
                break ;;
        esac
        local _uid; _uid=$(discord_user_resolve "$_word" 2>/dev/null)
        if [ -n "$_uid" ]; then
            _words_consumed=$((_words_consumed + _pending_connectors + 1))
            _pending_connectors=0
            local _dup=0 _ex
            for _ex in "${_DM_RESOLVED_IDS[@]}"; do [ "$_ex" == "$_uid" ] && { _dup=1; break; }; done
            [ "$_dup" -eq 0 ] && _DM_RESOLVED_IDS+=("$_uid")
        else break; fi
    done
    _DM_MESSAGE="$text"
    local _i=0 _w
    for _w in $text; do
        [ $_i -ge $_words_consumed ] && break
        _DM_MESSAGE="${_DM_MESSAGE#"${_DM_MESSAGE%%[![:space:]]*}"}"
        _DM_MESSAGE="${_DM_MESSAGE#"$_w"}"
        _i=$((_i + 1))
    done
    _DM_MESSAGE="${_DM_MESSAGE#"${_DM_MESSAGE%%[![:space:]]*}"}"
}

discord_user_add() {
    local username="$1" user_id="$2" display_name="${3:-}" guild_name="${4:-}" guild_id="${5:-}" is_bot="${6:-0}"
    username="${username#@}"
    _discord_users_init || return 1
    sqlite3 "$DISCORD_USERS_DB" "INSERT OR REPLACE INTO users(username, user_id, display_name, guild_name, guild_id, is_bot) VALUES ('${username//\'/\'\'}', '${user_id//\'/\'\'}', '${display_name//\'/\'\'}', '${guild_name//\'/\'\'}', '${guild_id//\'/\'\'}', $is_bot);"
    ui_ok "Registered user @${username} → ${user_id}${display_name:+ (${display_name})}"
}

discord_user_remove() {
    local username="$1"; username="${username#@}"
    _discord_users_init || return 1
    sqlite3 "$DISCORD_USERS_DB" "DELETE FROM users WHERE username = '${username//\'/\'\'}' COLLATE NOCASE;"
    ui_ok "Removed user @${username}"
}

discord_user_list() {
    _discord_users_init || return 1
    local count; count=$(sqlite3 "$DISCORD_USERS_DB" "SELECT COUNT(*) FROM users;" 2>/dev/null)
    [ "${count:-0}" -eq 0 ] && { ui_dim "No users registered"; return; }
    ui_section "Discord Users ($count)"
    sqlite3 -separator ' | ' "$DISCORD_USERS_DB" "SELECT '@' || username, user_id, COALESCE(NULLIF(display_name,''), '(no display name)'), COALESCE(NULLIF(guild_name,''), '(no guild)') FROM users WHERE is_bot = 0 ORDER BY guild_name, username;" 2>/dev/null | while IFS= read -r line; do
        printf "  %s\n" "$line"
    done
}

discord_users_sync() {
    local token; token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1
    _discord_users_init || return 1
    ui_info "Fetching guilds..."
    local guilds; guilds=$(api_get "https://discord.com/api/v10/users/@me/guilds" -H "Authorization: Bot $token")
    [ $? -ne 0 ] && { ui_err "Failed to fetch guilds"; return 1; }
    local guild_count; guild_count=$(echo "$guilds" | jq 'length' 2>/dev/null)
    [ "${guild_count:-0}" -eq 0 ] && { ui_warn "Bot is not in any servers"; return 1; }
    local total_added=0
    echo "$guilds" | jq -r '.[]? | "\(.id) \(.name)"' 2>/dev/null | while IFS=' ' read -r gid gname; do
        ui_dim "  Syncing members: $gname ($gid)..."
        local after="" batch_size=1000
        while true; do
            local url="https://discord.com/api/v10/guilds/$gid/members?limit=$batch_size"
            [ -n "$after" ] && url="${url}&after=${after}"
            local batch; batch=$(api_get "$url" -H "Authorization: Bot $token")
            [ $? -ne 0 ] && break
            local batch_count; batch_count=$(echo "$batch" | jq 'length' 2>/dev/null)
            [ "${batch_count:-0}" -eq 0 ] && break
            echo "$batch" | jq -r '.[]? | "\(.user.id) \(.user.username) \(.user.global_name // "") \(.user.bot // false)"' 2>/dev/null | while IFS=' ' read -r uid uname dname is_bot; do
                local bot_flag=0; [ "$is_bot" = "true" ] && bot_flag=1
                sqlite3 "$DISCORD_USERS_DB" "INSERT OR REPLACE INTO users(username, user_id, display_name, guild_name, guild_id, is_bot) VALUES ('${uname//\'/\'\'}', '${uid//\'/\'\'}', '${dname//\'/\'\'}', '${gname//\'/\'\'}', '${gid//\'/\'\'}', $bot_flag);" 2>/dev/null
                total_added=$((total_added + 1))
            done
            [ "$batch_count" -lt "$batch_size" ] && break
            after=$(echo "$batch" | jq -r '.[-1].user.id' 2>/dev/null)
            [ -z "$after" ] && break
        done
    done
    local final_count; final_count=$(sqlite3 "$DISCORD_USERS_DB" "SELECT COUNT(*) FROM users WHERE is_bot = 0;" 2>/dev/null)
    ui_ok "User registry synced — $final_count users total (excluding bots)"
}

discord_resolve_mentions() {
    local text="$1"
    _discord_users_init 2>/dev/null || { echo "$text"; return; }
    local result="$text" mentions mention
    mentions=$(echo "$text" | grep -oE '@[a-zA-Z0-9_.-]+' | sort -u)
    while IFS= read -r mention; do
        [ -z "$mention" ] && continue
        local username="${mention#@}" user_id
        user_id=$(discord_user_resolve "$username")
        [ -n "$user_id" ] && result=$(echo "$result" | sed "s|@${username}|<@${user_id}>|g")
    done <<< "$mentions"
    echo "$result"
}

discord_dm() {
    local user_id="$1" message="$2"
    if ! [[ "$user_id" =~ ^[0-9]+$ ]]; then
        local resolved; resolved=$(discord_user_resolve "$user_id")
        [ -z "$resolved" ] && { ui_err "Unknown user: $user_id"; return 1; }
        user_id="$resolved"
    fi
    local token; token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1
    local dm_data dm_resp dm_channel_id
    dm_data=$(jq -n --arg r "$user_id" '{"recipient_id": $r}')
    dm_resp=$(api_post "https://discord.com/api/v10/users/@me/channels" "$dm_data" -H "Authorization: Bot $token")
    [ $? -ne 0 ] && { ui_err "Failed to create DM channel: $(api_json_get "${_API_LAST_BODY:-}" '.message // "unknown error"')\n"; return 1; }
    dm_channel_id=$(api_json_get "$dm_resp" '.id')
    [ -z "$dm_channel_id" ] && { ui_err "Failed to get DM channel ID"; return 1; }
    local known_dms="${DISCORD_KNOWN_DMS_FILE:-${GEORGE_DIR:-$LODGE_DIR/.george}/discord_sessions/known_dms.json}"
    mkdir -p "$(dirname "$known_dms")" 2>/dev/null || true
    [ -f "$known_dms" ] || echo '{}' > "$known_dms"
    jq --arg u "$user_id" --arg cid "$dm_channel_id" '.[$u] = $cid' "$known_dms" > "${known_dms}.tmp.${BASHPID:-$$}" 2>/dev/null \
        && mv -f "${known_dms}.tmp.${BASHPID:-$$}" "$known_dms" 2>/dev/null || true
    _DISCORD_IN_DM=1 discord_send "$dm_channel_id" "$message"
}

_telegram_api() {
    local method="$1"; shift
    local token; token=$(api_require_key "TELEGRAM_BOT_TOKEN" "Telegram Bot") || return 1
    api_post "https://api.telegram.org/bot${token}/${method}" "$@"
}

telegram_send() {
    local text="$1"
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        text=$(tools_expand_file_refs "$text")
    fi
    text=$(ui_expand_escapes "$text")
    local chat_id="${2:-}"
    [ -z "$chat_id" ] && { chat_id=$(api_require_key "TELEGRAM_CHAT_ID" "Telegram") || return 1; }
    local token; token=$(api_get_key "TELEGRAM_BOT_TOKEN") || return 1
    local data resp; data=$(jq -n --arg t "$text" --arg c "$chat_id" '{"chat_id": $c, "text": $t, "parse_mode": "Markdown"}')
    resp=$(api_post "https://api.telegram.org/bot${token}/sendMessage" "$data")
    if [ $? -eq 0 ]; then ui_ok "Sent to Telegram"; echo "$resp"
    else ui_err "Telegram send failed"; return 1; fi
}

telegram_get_updates() {
    local count="${1:-10}" token; token=$(api_require_key "TELEGRAM_BOT_TOKEN" "Telegram Bot") || return 1
    api_get "https://api.telegram.org/bot${token}/getUpdates?limit=$count" | jq -r '.result[]? | "[\(.message.from.username // "unknown")] \(.message.text // "[media]")"' 2>/dev/null
}

telegram_reply() {
    local chat_id="$1" message_id="$2" text="$3" token data
    token=$(api_get_key "TELEGRAM_BOT_TOKEN") || return 1
    data=$(jq -n --arg t "$text" --arg c "$chat_id" --arg m "$message_id" '{"chat_id": $c, "text": $t, "reply_to_message_id": ($m | tonumber), "parse_mode": "Markdown"}')
    api_post "https://api.telegram.org/bot${token}/sendMessage" "$data"
}

telegram_get_me() {
    local token; token=$(api_require_key "TELEGRAM_BOT_TOKEN" "Telegram Bot") || return 1
    api_get "https://api.telegram.org/bot${token}/getMe" | jq '.' 2>/dev/null
}

SOCIAL_UNIFIED_POST="${SOCIAL_UNIFIED_POST:-0}"

social_post() {
    local text="$1"; shift
    local platforms=("$@")
    if [ ${#platforms[@]} -eq 0 ]; then
        if [ "${SOCIAL_UNIFIED_POST:-0}" -eq 1 ]; then platforms=("all")
        else ui_err "No platform specified. Use: /social post <platform> [channel] <text>"; return 1; fi
    fi
    local results=() platform
    for platform in "${platforms[@]}"; do
        case "$platform" in
            x|twitter) x_post "$text" && results+=("X: ✓") || results+=("X: ✗") ;;
            mastodon|masto) mastodon_post "$text" && results+=("Mastodon: ✓") || results+=("Mastodon: ✗") ;;
            bluesky|bsky) bluesky_post "$text" && results+=("Bluesky: ✓") || results+=("Bluesky: ✗") ;;
            discord)
                if api_get_key "DISCORD_WEBHOOK_URL" &>/dev/null; then
                    discord_webhook "$text" && results+=("Discord: ✓") || results+=("Discord: ✗")
                elif api_get_key "DISCORD_BOT_TOKEN" &>/dev/null; then
                    local _def_chan; _def_chan=$(discord_default_channel)
                    if [ -n "$_def_chan" ]; then discord_send "$_def_chan" "$text" && results+=("Discord: ✓") || results+=("Discord: ✗")
                    else results+=("Discord: ✗ (no default channel)"); fi
                else results+=("Discord: ✗"); fi ;;
            telegram|tg) telegram_send "$text" && results+=("Telegram: ✓") || results+=("Telegram: ✗") ;;
            all)
                api_get_key "X_BEARER_TOKEN" &>/dev/null && { x_post "$text" && results+=("X: ✓") || results+=("X: ✗"); }
                local _masto_token; _masto_token=$(_mastodon_instance_token "" 2>/dev/null)
                [ -n "$_masto_token" ] && { mastodon_post "$text" && results+=("Mastodon: ✓") || results+=("Mastodon: ✗"); }
                api_get_key "BLUESKY_APP_PASSWORD" &>/dev/null && { bluesky_post "$text" && results+=("Bluesky: ✓") || results+=("Bluesky: ✗"); }
                if api_get_key "DISCORD_WEBHOOK_URL" &>/dev/null; then
                    discord_webhook "$text" && results+=("Discord: ✓") || results+=("Discord: ✗")
                elif api_get_key "DISCORD_BOT_TOKEN" &>/dev/null; then
                    local _def_chan; _def_chan=$(discord_default_channel)
                    [ -n "$_def_chan" ] && { discord_send "$_def_chan" "$text" && results+=("Discord: ✓") || results+=("Discord: ✗"); } || results+=("Discord: ✗ (no default channel)")
                fi
                api_get_key "TELEGRAM_BOT_TOKEN" &>/dev/null && { telegram_send "$text" && results+=("Telegram: ✓") || results+=("Telegram: ✗"); }
                ;;
            *) ui_warn "Unknown platform: $platform" ;;
        esac
    done
    if [ ${#results[@]} -gt 0 ]; then
        echo ""; ui_section "Post Results"
        for r in "${results[@]}"; do printf "  %s\n" "$r"; done
    fi
}

social_provider_configured() {
    local platform="$1"
    case "$platform" in
        x|twitter) api_get_key "X_BEARER_TOKEN" &>/dev/null ;;
        mastodon|masto)
            local _masto_token; _masto_token=$(_mastodon_instance_token "" 2>/dev/null)
            [ -n "$_masto_token" ] || api_get_key "MASTODON_ACCESS_TOKEN" &>/dev/null ;;
        bluesky|bsky) api_get_key "BLUESKY_APP_PASSWORD" &>/dev/null && api_get_key "BLUESKY_HANDLE" &>/dev/null ;;
        discord) api_get_key "DISCORD_WEBHOOK_URL" &>/dev/null || api_get_key "DISCORD_BOT_TOKEN" &>/dev/null ;;
        telegram|tg) api_get_key "TELEGRAM_BOT_TOKEN" &>/dev/null && api_get_key "TELEGRAM_CHAT_ID" &>/dev/null ;;
        *) return 1 ;;
    esac
}

social_provider_reachable() {
    local platform="$1"
    social_provider_configured "$platform" || return 1
    api_network_reachable 3 || return 1
    case "$platform" in
        x|twitter) api_endpoint_reachable "https://api.x.com/2/tweets" 4 ;;
        mastodon|masto)
            local _base; _base=$(_mastodon_base 2>/dev/null)
            [ -n "$_base" ] || return 1
            api_endpoint_reachable "${_base}/api/v1/instance" 4 ;;
        bluesky|bsky) api_endpoint_reachable "https://bsky.social/xrpc/com.atproto.server.describeServer" 4 ;;
        discord) api_endpoint_reachable "https://discord.com/api/v10/users/@me" 4 ;;
        telegram|tg) api_endpoint_reachable "https://api.telegram.org" 4 ;;
        *) return 1 ;;
    esac
}

social_availability_summary() {
    local enabled="yes" configured=() reachable=() p
    for p in x mastodon bluesky discord telegram; do
        if social_provider_configured "$p"; then
            configured+=("$p")
            social_provider_reachable "$p" && reachable+=("$p")
        fi
    done
    echo "SOCIAL_ENABLED: $enabled"
    echo "SOCIAL_CONFIGURED: ${configured[*]:-none}" | sed 's/ /,/g'
    echo "SOCIAL_REACHABLE: ${reachable[*]:-none}" | sed 's/ /,/g'
    echo "SOCIAL_NETWORK: $(api_network_state 3)"
}

social_status() {
    ui_section "Social Integrations"
    local configured=0
    if api_get_key "X_BEARER_TOKEN" &>/dev/null; then
        printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "X"; configured=$((configured + 1))
    else printf "  %b○%b %-15s not configured  %b%s%b\n" "$C_DIM" "$C_RESET" "X" "$C_DIM" "X_BEARER_TOKEN" "$C_RESET"; fi

    local _masto_instances=0
    if command -v sqlite3 &>/dev/null && [ -f "${MASTODON_INSTANCES_DB:-}" ]; then
        _masto_instances=$(sqlite3 "$MASTODON_INSTANCES_DB" "SELECT COUNT(*) FROM instances;" 2>/dev/null || echo 0)
    fi
    if [ "${_masto_instances:-0}" -gt 0 ]; then
        printf "  %b●%b %-15s configured (%s instance%s)\n" "$C_GREEN" "$C_RESET" "MASTODON" "$_masto_instances" "$([ "$_masto_instances" -ne 1 ] && echo 's')"
        configured=$((configured + 1))
    elif api_get_key "MASTODON_ACCESS_TOKEN" &>/dev/null; then
        printf "  %b●%b %-15s configured (legacy key)\n" "$C_GREEN" "$C_RESET" "MASTODON"; configured=$((configured + 1))
    else printf "  %b○%b %-15s not configured  %b%s%b\n" "$C_DIM" "$C_RESET" "MASTODON" "$C_DIM" "MASTODON_ACCESS_TOKEN" "$C_RESET"; fi

    if api_get_key "BLUESKY_APP_PASSWORD" &>/dev/null; then
        printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "BLUESKY"; configured=$((configured + 1))
    else printf "  %b○%b %-15s not configured  %b%s + %s%b\n" "$C_DIM" "$C_RESET" "BLUESKY" "$C_DIM" "BLUESKY_HANDLE" "BLUESKY_APP_PASSWORD" "$C_RESET"; fi

    if api_get_key "DISCORD_BOT_TOKEN" &>/dev/null; then
        local _user_count=0
        if command -v sqlite3 &>/dev/null && [ -f "${DISCORD_USERS_DB:-}" ]; then
            _user_count=$(sqlite3 "$DISCORD_USERS_DB" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo 0)
        fi
        printf "  %b●%b %-15s configured (bot" "$C_GREEN" "$C_RESET" "DISCORD"
        [ "${_user_count:-0}" -gt 0 ] && printf ", %s users" "$_user_count"
        printf ")\n"; configured=$((configured + 1))
    elif api_get_key "DISCORD_WEBHOOK_URL" &>/dev/null; then
        printf "  %b●%b %-15s configured (webhook)\n" "$C_GREEN" "$C_RESET" "DISCORD"; configured=$((configured + 1))
    else printf "  %b○%b %-15s not configured  %b%s%b\n" "$C_DIM" "$C_RESET" "DISCORD" "$C_DIM" "DISCORD_BOT_TOKEN or DISCORD_WEBHOOK_URL" "$C_RESET"; fi

    if api_get_key "TELEGRAM_BOT_TOKEN" &>/dev/null; then
        printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "TELEGRAM"; configured=$((configured + 1))
    else printf "  %b○%b %-15s not configured  %b%s + %s%b\n" "$C_DIM" "$C_RESET" "TELEGRAM" "$C_DIM" "TELEGRAM_BOT_TOKEN" "TELEGRAM_CHAT_ID" "$C_RESET"; fi

    echo ""
    [ "${SOCIAL_UNIFIED_POST:-0}" -eq 1 ] && ui_dim "  Unified posting: ON (posts broadcast to all platforms)" || ui_dim "  Unified posting: OFF (posts require explicit platform)"
}

discord_mentions_poll() {
    local token; token=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null)
    [ -z "$token" ] && { ui_dim "  Discord sweep: DISCORD_BOT_TOKEN not configured."; return 0; }
    local me_resp; me_resp=$(curl -s "https://discord.com/api/v10/users/@me" -H "Authorization: Bot $token" 2>/dev/null)
    local bot_id bot_name
    bot_id=$(echo "$me_resp" | jq -r .id 2>/dev/null); bot_name=$(echo "$me_resp" | jq -r .username 2>/dev/null)
    [ -z "$bot_id" ] || [ "$bot_id" = "null" ] && { ui_dim "  Discord sweep: Could not authenticate bot token."; return 0; }

    ui_step "Sweeping Discord channels for mentions of bot @${bot_name} (${bot_id})..."
    local channels_db="${DISCORD_CHANNELS_DB:-${GEORGE_DIR:-$PWD/.george}/discord_channels.db}"
    [ ! -f "$channels_db" ] && { ui_dim "  Discord sweep: No discord_channels.db found."; return 0; }

    local ch_list; ch_list=$(sqlite3 "$channels_db" "SELECT name, channel_id FROM channels LIMIT 20;" 2>/dev/null || true)
    local mentions_found=0
    while IFS='|' read -r ch_name ch_id; do
        [ -z "$ch_id" ] && continue
        local msgs; msgs=$(curl -s "https://discord.com/api/v10/channels/$ch_id/messages?limit=5" -H "Authorization: Bot $token" 2>/dev/null)
        local mentions; mentions=$(echo "$msgs" | jq -c --arg bid "$bot_id" '.[]? | select(.author.id != $bid and (.content | contains("<@" + $bid + ">") or contains("<@!" + $bid + ">")))' 2>/dev/null || true)
        if [ -n "$mentions" ]; then
            while IFS= read -r m; do
                [ -z "$m" ] && continue
                local mid mauthor mcontent
                mid=$(echo "$m" | jq -r .id); mauthor=$(echo "$m" | jq -r .author.username); mcontent=$(echo "$m" | jq -r .content)
                ui_info "Discord mention in #$ch_name by @$mauthor: $mcontent"
                mkdir -p "${GEORGE_DIR:-$PWD/.george}/events" 2>/dev/null
                echo "{\"platform\":\"discord\",\"type\":\"mention\",\"channel_id\":\"$ch_id\",\"channel_name\":\"$ch_name\",\"message_id\":\"$mid\",\"author\":\"$mauthor\",\"content\":\"$mcontent\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "${GEORGE_DIR:-$PWD/.george}/events/comms_events.jsonl"
                mentions_found=$((mentions_found + 1))
            done <<< "$mentions"
        fi
    done <<< "$ch_list"
    [ "$mentions_found" -eq 0 ] && ui_dim "  No new Discord mentions found across registered channels." || ui_ok "Discord sweep found $mentions_found new mention(s)."
}

x_social_sweep() {
    ui_step "Sweeping X (Twitter) & Mastodon social queue..."
    if ! declare -f x_blog_sweep &>/dev/null; then
        [ -f "${LODGE_DIR:-$HOME/blue-lodge}/lib/comms/social_blog.sh" ] && source "${LODGE_DIR:-$HOME/blue-lodge}/lib/comms/social_blog.sh"
    fi
    if declare -f x_blog_sweep &>/dev/null; then
        x_blog_sweep
        return $?
    fi

    ui_warn "x_blog_sweep unavailable; skipping uncoordinated queue processing to prevent duplicates."
    return 1
}

mastodon_social_sweep() {
    ui_step "Sweeping Mastodon notifications & mentions..."
    local token base; token=$(_mastodon_instance_token "" 2>/dev/null); base=$(_mastodon_instance_url "" 2>/dev/null)
    [ -z "$token" ] && { ui_dim "  Mastodon sweep: No Mastodon token configured."; return 0; }
    local notifs; notifs=$(curl -s -X GET "$base/api/v1/notifications?limit=10" -H "Authorization: Bearer $token" -H "User-Agent: George-BlueLodge/1.0" --connect-timeout 10 --max-time 15 2>/dev/null)
    local notif_count; notif_count=$(echo "$notifs" | jq '. | length' 2>/dev/null || echo 0)
    if [ "$notif_count" -gt 0 ]; then
        mkdir -p "${GEORGE_DIR:-$PWD/.george}/events" 2>/dev/null
        local mentions_processed=0 i
        for (( i=0; i<notif_count; i++ )); do
            local item ntype; item=$(echo "$notifs" | jq -c ".[$i]" 2>/dev/null)
            [ -z "$item" ] && continue
            ntype=$(echo "$item" | jq -r .type 2>/dev/null)
            [ "$ntype" != "mention" ] && continue
            local nid acct content status_id
            nid=$(echo "$item" | jq -r .id); acct=$(echo "$item" | jq -r .account.acct); status_id=$(echo "$item" | jq -r '.status.id // empty')
            content=$(echo "$item" | jq -r '.status.content // ""' | sed 's/<[^>]*>//g')
            ui_info "Mastodon mention from @$acct (ID: $status_id): ${content:0:60}..."
            echo "{\"platform\":\"mastodon\",\"type\":\"mention\",\"notification_id\":\"$nid\",\"author\":\"$acct\",\"status_id\":\"$status_id\",\"content\":\"$content\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "${GEORGE_DIR:-$PWD/.george}/events/comms_events.jsonl"
            mentions_processed=$((mentions_processed + 1))
        done
        [ "$mentions_processed" -gt 0 ] && ui_ok "Mastodon sweep recorded $mentions_processed mention(s) to event log." || ui_dim "  No new Mastodon mentions."
    else ui_dim "  No new Mastodon notifications."; fi
}
