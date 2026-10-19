#!/usr/bin/env bash
# Unified search router (refinement P4): provider order, quality floor, cache, budgets,
# caller gating for paid Serper, degraded-engine reporting, temporal rewrite, web_search wiring.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR

test_start "search_router (P4)"

d="$GEORGE_TEST_SANDBOX/srch"; mkdir -p "$d"
python3 "$LODGE_DIR/tests/helpers/mock_search.py" "$d/port" "$d/cfg.json" "$d/req.jsonl" &
mpid=$!
for _i in $(seq 50); do [ -s "$d/port" ] && break; sleep 0.1; done
P=$(cat "$d/port")
export SEARXNG_URL="http://127.0.0.1:$P" BRAVE_API_BASE="http://127.0.0.1:$P/brave" \
       SERPER_API_BASE="http://127.0.0.1:$P/serper" DDG_LITE_URL="http://127.0.0.1:$P/ddg/" \
       SEARCH_EMIT_EVENTS=0 BRAVE_SEARCH_API_KEY="brave-test" SERPER_API_KEY="serper-test"
unset LODGE_CRON_JOB SEARCH_CALLER
R() { python3 "$LODGE_DIR/lib/tools/search_router.py" search --no-cache "$@" 2>/dev/null; }
RC() { python3 "$LODGE_DIR/lib/tools/search_router.py" search "$@" 2>/dev/null; }
count() { grep -c "\"route\": \"$1\"" "$d/req.jsonl" 2>/dev/null || true; }

sx_good='{"results":[{"title":"A","url":"https://a.example/1","content":"a","engines":["bing","duckduckgo"]},{"title":"B","url":"https://b.example/2","content":"b","engines":["zapmeta"]},{"title":"C","url":"https://c.example/3","content":"c","engines":["bing"]}],"unresponsive_engines":[]}'
sx_thin='{"results":[{"title":"Only","url":"https://only.example/1","content":"o","engines":["bing"]}],"unresponsive_engines":[["qwant","CAPTCHA"],["google cse","Suspended: too many requests"]]}'
brave_ok='{"web":{"results":[{"title":"Brave1","url":"https://brave.example/1","description":"<b>x</b>"},{"title":"Brave2","url":"https://brave.example/2","description":"y"},{"title":"Brave3","url":"https://brave.example/3","description":"z"}]}}'
serper_ok='{"organic":[{"title":"S1","link":"https://serper.example/1","snippet":"s"},{"title":"S2","link":"https://serper.example/2","snippet":"s"},{"title":"S3","link":"https://serper.example/3","snippet":"s"}]}'
ddg_html='<table><tr><td><a rel="nofollow" href="https://ddg.example/one" class="result-link">DDG One</a></td></tr><tr><td class="result-snippet">first</td></tr><tr><td><a rel="nofollow" href="https://ddg.example/two" class="result-link">DDG Two</a></td></tr><tr><td class="result-snippet">second</td></tr><tr><td><a rel="nofollow" href="https://ddg.example/three" class="result-link">DDG Three</a></td></tr></table>'
cfg() { jq -n --argjson sx "$1" --argjson br "$2" --argjson se "$3" --arg dd "$4" --argjson sxs "${5:-200}" --argjson brs "${6:-200}" \
    '{searxng:{status:$sxs,body:$sx},brave:{status:$brs,body:$br},serper:{status:200,body:$se},ddg:{status:200,html:$dd}}' > "$d/cfg.json"; }

describe "SearXNG healthy → used alone, multi-engine consensus"
cfg "$sx_good" "$brave_ok" "$serper_ok" "$ddg_html"; : > "$d/req.jsonl"
out=$(R --query "capital of france")
assert_eq "searxng" "$(jq -r .provider <<<"$out")" "provider searxng"
assert_eq "3" "$(jq '.results|length' <<<"$out")" "3 results"
assert_eq "0" "$(count brave)" "brave not called"
eng=$(jq -r '.query' "$d/req.jsonl" 2>/dev/null | head -0; jq -r 'select(.route=="searxng")|.query.engines' "$d/req.jsonl" | head -1)
assert_contains "$eng" "zapmeta" "default engines include zapmeta"
assert_not_contains "$eng" "qwant" "CAPTCHA-prone qwant not in default set"

describe "cache: second identical call served from cache"
: > "$d/req.jsonl"
RC --query "cache me please" >/dev/null
out=$(RC --query "cache   ME please")
assert_eq "true" "$(jq -r .cached <<<"$out")" "cached=true (normalized key)"
assert_eq "1" "$(count searxng)" "only one upstream call"

describe "thin SearXNG → Brave merged; only requested engines reported DEGRADED"
cfg "$sx_thin" "$brave_ok" "$serper_ok" "$ddg_html"; : > "$d/req.jsonl"
out=$(SEARCH_SEARXNG_ENGINES="bing,qwant,duckduckgo" R --query "obscure topic")
assert_eq "searxng+brave" "$(jq -r .provider <<<"$out")" "merged provider"
assert_eq "https://only.example/1" "$(jq -r '.results[0].url' <<<"$out")" "searxng result first"
assert_eq "x" "$(jq -r '.results[1].content' <<<"$out")" "brave snippet html stripped"
assert_eq "brave-test" "$(jq -r 'select(.route=="brave")|.auth' "$d/req.jsonl" | head -1)" "brave key header"
assert_eq "qwant" "$(jq -r '[.degraded[].engine]|join(",")' <<<"$out")" "degraded=qwant only (google cse ignored)"
assert_eq "CAPTCHA" "$(jq -r '.engines.qwant.reason' "$GEORGE_DIR/state/search_health.json" 2>/dev/null)" "health file records qwant"
txt=$(SEARCH_SEARXNG_ENGINES="bing,qwant,duckduckgo" SEARCH_ENGINE_COOLDOWN=0 R --query "obscure topic" --format text)
assert_contains "$txt" "DEGRADED search engines: qwant" "text output flags DEGRADED"

describe "degraded engine cooldown: qwant skipped next time"
: > "$d/req.jsonl"
SEARCH_SEARXNG_ENGINES="bing,qwant,duckduckgo" R --query "anything else" >/dev/null
eng=$(jq -r 'select(.route=="searxng")|.query.engines' "$d/req.jsonl" | tail -1)
assert_eq "bing,duckduckgo" "$eng" "recently degraded qwant dropped"

describe "Serper is operator-only, never cron"
cfg '{"results":[]}' '{}' "$serper_ok" "$ddg_html" 200 500; : > "$d/req.jsonl"
out=$(R --query "agent query" --caller agent)
assert_eq "0" "$(count serper)" "agent: no serper"
assert_eq "ddg" "$(jq -r .provider <<<"$out")" "agent falls to ddg"
assert_eq "https://ddg.example/one" "$(jq -r '.results[0].url' <<<"$out")" "ddg parsed"
: > "$d/req.jsonl"
out=$(R --query "operator query" --caller operator)
assert_eq "1" "$(count serper)" "operator: serper used"
assert_eq "serper" "$(jq -r .provider <<<"$out")" "operator provider serper"
: > "$d/req.jsonl"
LODGE_CRON_JOB=sovereign_trading_loop R --query "cron query" --caller operator >/dev/null
assert_eq "0" "$(count serper)" "cron: serper never used even if caller=operator"
assert_eq "1" "$(jq -r ".serper_total_used" "$GEORGE_DIR/state/search_budget.json")" "serper credit charged once"

describe "budgets"
cfg '{"results":[]}' "$brave_ok" "$serper_ok" "$ddg_html"; : > "$d/req.jsonl"
SEARCH_BRAVE_DAILY_BUDGET=0 R --query "budget test" >/dev/null
assert_eq "0" "$(count brave)" "brave skipped when budget exhausted"
SEARCH_SERPER_TOTAL_BUDGET=1 R --query "budget test2" --caller operator >/dev/null
assert_eq "0" "$(count serper)" "serper total cap honored"

describe "SearXNG down → keyed fallback; no key → ddg"
cfg '{}' "$brave_ok" "$serper_ok" "$ddg_html" 500; : > "$d/req.jsonl"
out=$(BRAVE_SEARCH_API_KEY="" GEORGE_DIR="$GEORGE_TEST_SANDBOX/nokeys" R --query "down test")
assert_eq "ddg" "$(jq -r .provider <<<"$out")" "ddg when searxng down and no brave key"
assert_contains "$(jq -c .providers_tried <<<"$out")" "no_key" "brave no_key recorded"

describe "temporal rewrite"
cfg "$sx_good" "$brave_ok" "$serper_ok" "$ddg_html"; : > "$d/req.jsonl"
out=$(R --query "breaking news today on tariffs")
assert_eq "day" "$(jq -r .time_range <<<"$out")" "today → day"
assert_eq "news" "$(jq -r .category <<<"$out")" "breaking news → news category"
assert_eq "day" "$(jq -r 'select(.route=="searxng")|.query.time_range' "$d/req.jsonl" | tail -1)" "time_range sent upstream"
out=$(R --query "latest rust release")
assert_eq "week" "$(jq -r .time_range <<<"$out")" "latest → week"

describe "input hardening"
out=$(R --query "x" --engines 'bing;rm -rf /' --category bogus --time-range forever)
assert_eq "general" "$(jq -r .category <<<"$out")" "bogus category → general"
assert_eq "null" "$(jq -r .time_range <<<"$out")" "bogus time_range dropped"
assert_not_contains "$(jq -r 'select(.route=="searxng")|.query.engines' "$d/req.jsonl" | tail -1)" ";" "unsafe engines rejected"

describe "web_search (bash) is wired to the router"
cfg "$sx_good" "$brave_ok" "$serper_ok" "$ddg_html"
ws=$(bash -c 'source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null; source "$LODGE_DIR/lib/core/api.sh" 2>/dev/null; source "$LODGE_DIR/lib/comms/web.sh" 2>/dev/null; SEARCH_NO_CACHE=1 web_search "wired query" 3' </dev/null 2>&1)
assert_contains "$ws" "[1] A [bing,duckduckgo]" "formatted result line"
assert_contains "$ws" "provider=searxng" "provider footer"

kill "$mpid" 2>/dev/null
test_end
