#!/usr/bin/env bash
# research_sandbox must search for what it was asked (refinement P4 / user bug report)
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR
export RESEARCH_SANDBOX_ROOT="$GEORGE_TEST_SANDBOX/sandboxes"
source "$LODGE_DIR/lib/comms/web.sh" 2>/dev/null

test_start "research_sandbox"

assert_fn_defined research_sandbox
assert_fn_defined _research_classify_domain
assert_fn_defined _research_vectors

describe "domain classification uses whole words"
assert_eq "$(_research_classify_domain "Benjamin Franklin witty quotes from Poor Richard's Almanack")" "general" "'from' must not match 'rom'"
assert_eq "$(_research_classify_domain "trending meme coins this week")" "finance"
assert_eq "$(_research_classify_domain "UNH stock outlook this week")" "finance"
assert_eq "$(_research_classify_domain "PS2 emulator JIT recompiler design")" "gaming"
assert_eq "$(_research_classify_domain "Travis Kelce engagement rumor fact check")" "general"
assert_eq "$(_research_classify_domain "transformer attention arxiv paper")" "academic"
assert_eq "$(_research_classify_domain "linux kernel io_uring security CVE")" "engineering"
assert_eq "$(_research_classify_domain "systematic review of sleep studies")" "general" "'system' must not match 'systematic'"

describe "vectors always lead with the topic itself"
for t in "Benjamin Franklin quotes" "Cigna earnings guidance" "PS2 emulator" "Kelce engagement" "attention arxiv paper"; do
    d=$(_research_classify_domain "$t")
    first=$(_research_vectors "$t" "$d" | head -1)
    assert_eq "$first" "$t" "first vector for '$t'"
    bad=$(_research_vectors "$t" "$d" | grep -viF "$t" | head -1)
    assert_eq "$bad" "" "every vector keeps the topic for '$t'"
done
assert_not_contains "$(_research_vectors "Cigna earnings guidance" finance)" "UnitedHealth" "no hard-coded insurer vectors"
assert_not_contains "$(_research_vectors "Benjamin Franklin quotes" general)" "arxiv" "general topics get no academic qualifiers"

describe "sandbox queries contain the input terms and builds a dossier"
QLOG="$GEORGE_TEST_SANDBOX/queries.log"; : > "$QLOG"
web_search() {
    printf '%s\n' "$1" >> "$QLOG"
    printf '[1] Franklin result one\n    https://example.org/a\n    Snippet about thrift\n\n[2] Franklin result two\n    https://example.com/b\n    Another snippet\n\n'
}
web_fetch() { echo "Early to bed and early to rise makes a man healthy, wealthy and wise. This is long enough to count as content."; }
out="$GEORGE_TEST_SANDBOX/dossier.md"
research_sandbox "Benjamin Franklin witty quotes from Poor Richard's Almanack" 2 "$out" >/dev/null 2>&1
assert_file_exists "$out"
assert_match "$(head -1 "$QLOG")" "Franklin"
nonmatch=$(grep -vic "franklin" "$QLOG")
assert_eq "$nonmatch" "0" "every issued query mentions Franklin"
assert_not_contains "$(cat "$QLOG")" "emulation"
assert_contains "$(cat "$out")" "Franklin result one"
assert_contains "$(cat "$out")" "Early to bed"
unset -f web_search web_fetch

test_end
