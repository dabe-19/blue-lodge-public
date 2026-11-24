#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  Tests: Sovereign Stock Quote (pure POSIX: bash + curl + jq)
#  Regression for issue 1758e72ef72b (incident inc_op_bash_exec_1792502181):
#  a fragile improvised inline-Python loop in a bash_exec hard-crashed with
#  FileNotFoundError (exit 1) on missing /tmp/yf_<TICKER>.json.
#
#  Invariants under test:
#    1. Correctness  – parses Yahoo v8 chart payloads (last/chg/prev/closes,
#                       null closes filtered).
#    2. Gracefulness – missing / error / corrupt / absent tickers yield
#                       UNAVAILABLE and the tool ALWAYS exits 0 (the bug fix).
#    3. Purity       – host-pure: no python/node, no python heredocs, passes
#                       the bash -n syntax gate.
#  All tests are OFFLINE (STOCK_QUOTE_FIXTURE) – no network dependency.
# ═══════════════════════════════════════════════════════════════════════

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
if [ ! -f "$LODGE_DIR/.george/tools/stock_quote.sh" ]; then
    echo "SKIP: node-local .george/tools/stock_quote.sh not present in this checkout"
    exit 0
fi
# Sourcing defines sq_parse / sq_record / sq_main (main-guard prevents auto-run).
source "$LODGE_DIR/.george/tools/stock_quote.sh"

# Offline fixture sandbox (no network).
TEST_TMP=$(mktemp -d /tmp/george-stock-quote-test-XXXXXX)
FX="$TEST_TMP/fixtures"
mkdir -p "$FX"
export STOCK_QUOTE_FIXTURE="$FX"
export STOCK_QUOTE_MAX_TIME=2

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

# write_ok <ticker> <last> <prev> <closes-csv>
# Emits a canonical, valid Yahoo v8 chart fixture for <ticker>.
write_ok() {
    cat > "$FX/$1.json" <<JSON
{"chart":{"result":[{"meta":{"regularMarketPrice":$2,"previousClose":$3,"symbol":"$1"},"indicators":{"quote":[{"close":[$4]}]}}],"error":null}}
JSON
}

test_start "Sovereign Stock Quote (bash+curl+jq)"

describe "sq_parse: Yahoo v8 chart reduction"
it "extracts last/prev/closes and filters null closes" && {
    write_ok ELV 430.23 427.91 "425.27,428.09,428.43,null,430.23"
    out=$(sq_parse "$(cat "$FX/ELV.json")")
    assert_contains "$out" "430.23"
    assert_contains "$out" "427.91"
    closes_field=$(printf '%s' "$out" | awk -F'	' '{print $4}')
    # 4 real closes (null filtered) -> exactly 3 commas
    assert_eq "$(printf '%s' "$closes_field" | grep -o ',' | wc -l | tr -d ' ')" "3"
}

it "emits a fully-NA record (never errors) on invalid JSON" && {
    out=$(sq_parse "this is not valid json {")
    assert_contains "$out" "NA"
}

describe "sq_record: graceful per-ticker handling"
it "returns a valid record for a present ticker" && {
    write_ok HUM 414.98 417.18 "420.38,427.4,432.2,414.98"
    out=$(sq_record HUM)
    assert_contains "$out" "HUM"
    assert_contains "$out" "414.98"
}

it "returns UNAVAILABLE (not a crash) for a missing ticker" && {
    out=$(sq_record UNH)
    assert_contains "$out" "UNH"
    assert_contains "$out" "UNAVAILABLE"
}

it "returns UNAVAILABLE for an error payload (chart.result == null)" && {
    cat > "$FX/CI.json" <<'JSON'
{"chart":{"error":{"code":"Not Found","description":"CI not found"},"result":null}}
JSON
    out=$(sq_record CI)
    assert_contains "$out" "UNAVAILABLE"
}

describe "stock_quote end-to-end (fixture mode, exit-code contract)"
it "exits 0 even when most tickers are unavailable (the exact regression)" && {
    out=$(bash "$LODGE_DIR/.george/tools/stock_quote.sh" ELV HUM CI CVS UNH 2>/dev/null)
    rc=$?
    assert_eq "$rc" "0"
    assert_contains "$out" "ELV"
    assert_contains "$out" "UNAVAILABLE"
    # Must NOT leak a Python traceback / missing-file crash.
    assert_not_contains "$out" "Traceback"
    assert_not_contains "$out" "FileNotFoundError"
    assert_not_contains "$out" "No such file or directory"
}

it "markdown --table mode renders header + rows and exits 0" && {
    out=$(bash "$LODGE_DIR/.george/tools/stock_quote.sh" --table ELV UNH 2>/dev/null)
    rc=$?
    assert_eq "$rc" "0"
    assert_contains "$out" "| Ticker |"
    assert_contains "$out" "**ELV**"
    assert_contains "$out" "UNAVAILABLE"
}

it "--json mode emits exactly one valid JSON object per ticker and exits 0" && {
    out=$(bash "$LODGE_DIR/.george/tools/stock_quote.sh" --json ELV UNH 2>/dev/null)
    rc=$?
    assert_eq "$rc" "0"
    n=$(printf '%s
' "$out" | jq -s 'length' 2>/dev/null || echo 0)
    assert_eq "$n" "2"
}

describe "architectural purity (host POSIX, no inline interpreter)"
it "non-comment code contains no python/node invocation" && {
    code=$(grep -vE '^[[:space:]]*#' "$LODGE_DIR/.george/tools/stock_quote.sh")
    assert_not_contains "$code" "python"
    assert_not_contains "$code" "node "
}

it "passes the bash -n syntax gate" && {
    bash -n "$LODGE_DIR/.george/tools/stock_quote.sh"
    assert_ok $?
}

# Framework emits its own summary and exit status.
test_end
