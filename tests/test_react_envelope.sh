#!/usr/bin/env bash
# Tool result envelope (refinement P2.3/2.4) — fixtures are real observations
# captured from a live Discord run (UNH outlook, 2026-10-04).
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR
unset _REACT_ENVELOPE_LOADED
source "$LODGE_DIR/lib/core/react_envelope.sh"
FX="$LODGE_DIR/tests/fixtures/envelope"

test_start "react_envelope"
assert_fn_defined react_envelope_clean
assert_fn_defined react_envelope_classify
assert_fn_defined react_envelope_build
assert_fn_defined react_envelope_render

describe "noise stripping"
out=$(react_envelope_clean "$(cat "$FX/search_debug_prefix.txt")")
assert_not_contains "$out" "[debug]" "MCP debug lines removed"
assert_not_contains "$out" "\"max_results\": 10" "multi-line debug params block removed"
assert_contains "$out" "\"title\"" "payload preserved"
first=$(printf '%s\n' "$out" | sed -n '/[^[:space:]]/{p;q}')
assert_eq "[" "$first" "payload starts at JSON array"

out=$(react_envelope_clean "$(cat "$FX/deprecation_success.txt")")
assert_not_contains "$out" "DeprecationWarning" "python warning stripped"
assert_contains "$out" "Current Price: 371.9" "data kept"

out=$(react_envelope_clean $'[CACHED OBSERVATION (0ms)]\nhello')
assert_eq "hello" "$out" "cache banner stripped"

describe "classification — successes must stay successes"
assert_eq "" "$(react_envelope_classify 0 "$(react_envelope_clean "$(cat "$FX/deprecation_success.txt")")" bash_exec)" "deprecation warning + data = ok"
assert_eq "" "$(react_envelope_classify 0 "$(react_envelope_clean "$(cat "$FX/search_debug_prefix.txt")")" web_search)" "debug-prefixed search = ok"
assert_eq "" "$(react_envelope_classify 0 "Found 3 ERROR entries in the log; parsed fine" bash_exec)" "ERROR substring mid-text is not failure"
assert_eq "" "$(react_envelope_classify 0 "" file_write)" "empty output from writer is ok"

describe "classification — failures"
assert_eq "BLOCKED"    "$(react_envelope_classify 0 "$(cat "$FX/fetch_403_greylist.txt")" web_fetch)" "403 greylist"
assert_eq "BLOCKED"    "$(react_envelope_classify 0 "$(cat "$FX/greylist_uncached.txt")" web_fetch)" "greylisted uncached URL"
assert_eq "NOT_FOUND"  "$(react_envelope_classify 0 "$(cat "$FX/fetch_404.txt")" web_fetch)" "404"
assert_eq "NOT_FOUND"  "$(react_envelope_classify 0 "ERROR: File not found: /tmp/missing.txt" file_read)" "file_read not found"
assert_eq "RATE_LIMIT" "$(react_envelope_classify 0 "$(cat "$FX/rate_limit.txt")" bash_exec)" "too many requests"
assert_eq "CRASH"      "$(react_envelope_classify 1 "$(react_envelope_clean "$(cat "$FX/deprecation_traceback.txt")")" bash_exec)" "traceback + exit 1"
assert_eq "TIMEOUT"    "$(react_envelope_classify 124 "partial" bash_exec)" "exit 124"
assert_eq "DEPENDENCY" "$(react_envelope_classify 127 "x: command not found" bash_exec)" "exit 127"
assert_eq "DEPENDENCY" "$(react_envelope_classify 1 $'Traceback (most recent call last):\nModuleNotFoundError: No module named foo' bash_exec)" "missing module"
assert_eq "SYNTAX"     "$(react_envelope_classify 2 "bash: -c: line 1: syntax error near unexpected token" bash_exec)" "shell syntax"
assert_eq "NOT_FOUND"  "$(react_envelope_classify 1 "" bash_exec)" "silent exit 1 (grep miss)"
assert_eq "EMPTY"      "$(react_envelope_classify 0 "   " web_search)" "empty search result"
assert_eq "CRASH"      "$(react_envelope_classify 0 $'Traceback (most recent call last):\n  File "x", line 1\nValueError: bad' bash_exec)" "uncaught exception with exit 0"

describe "envelope build + render"
env=$(react_envelope_build web_fetch 0 812 "$(cat "$FX/fetch_403_greylist.txt")" "/tmp/payload.txt")
assert_eq "false" "$(jq -r .ok <<<"$env")" "ok=false"
assert_eq "BLOCKED" "$(jq -r .error_class <<<"$env")" "class recorded"
assert_eq "812" "$(jq -r .duration_ms <<<"$env")" "duration recorded"
assert_eq "/tmp/payload.txt" "$(jq -r '.artifacts[0]' <<<"$env")" "artifact recorded"
r=$(react_envelope_render "$env")
assert_contains "$r" "[TOOL FAILED: web_fetch · BLOCKED]" "failure header"
assert_contains "$r" "Do NOT retry this domain" "class hint"
env=$(react_envelope_build bash_exec 0 5 "$(cat "$FX/deprecation_success.txt")")
assert_eq "true" "$(jq -r .ok <<<"$env")" "ok=true"
assert_eq "null" "$(jq -r .error_class <<<"$env")" "no class"
r=$(react_envelope_render "$env")
assert_not_contains "$r" "TOOL FAILED" "success renders raw data"
assert_contains "$r" "Symbol: UNH" "success data"

describe "failed-domain memory"
SD="$GEORGE_DIR/sess_env"; mkdir -p "$SD"
assert_eq "newswire.com" "$(react_envelope_url_domain "https://www.newswire.com/view/x?y=1")" "domain extraction"
assert_eq "" "$(react_envelope_url_domain "not a url")" "junk rejected"
react_envelope_failed_domain_check "$SD" "newswire.com" >/dev/null; assert_fail $? "unknown domain not blocked"
react_envelope_failed_domain_record "$SD" "newswire.com" BLOCKED
assert_eq "BLOCKED" "$(react_envelope_failed_domain_check "$SD" newswire.com)" "blocked after 1"
react_envelope_failed_domain_record "$SD" "cms.gov" NOT_FOUND
react_envelope_failed_domain_check "$SD" "cms.gov" >/dev/null; assert_fail $? "404 never blocks the domain"
react_envelope_failed_domain_record "$SD" "slow.com" TIMEOUT
react_envelope_failed_domain_check "$SD" "slow.com" >/dev/null; assert_fail $? "one timeout tolerated"
react_envelope_failed_domain_record "$SD" "slow.com" TIMEOUT
assert_eq "TIMEOUT" "$(react_envelope_failed_domain_check "$SD" slow.com)" "two timeouts block"
react_envelope_failed_attempt_note "$SD" web_fetch '{"url":"https://newswire.com/a"}' BLOCKED
assert_contains "$(cat "$SD/scratchpad.md")" "## Failed Attempts" "section created"
assert_contains "$(cat "$SD/scratchpad.md")" "→ BLOCKED" "entry appended"

describe "condense long observations (no 6-line nav digests)"
page=$(printf 'Help\nLog In\nSign Up\nHome\nWatchlist\nStocks\n'; for i in $(seq 1 120); do printf 'UNH closed at 371.%02d on day %d according to the exchange data feed.\n' "$i" "$i"; done)
c=$(react_envelope_condense "$page" 2000 "observations/call_x.txt")
assert_not_contains "$c" "Watchlist" "nav lines dropped"
assert_contains "$c" "UNH closed at 371.01" "substance kept"
assert_contains "$c" 'file_read path="observations/call_x.txt"' "archive pointer"
[ "${#c}" -le 2300 ] && _test_pass || _test_fail "condensed length bounded (${#c})"
assert_eq "short text" "$(react_envelope_condense "short text" 2000)" "short passes through"

test_end
