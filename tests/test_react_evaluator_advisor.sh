#!/usr/bin/env bash
# Grammar-constrained evaluator + advisor (refinement P2.5 / P2.6)
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR
unset _REACT_EVALUATOR_LOADED _REACT_ADVISOR_LOADED
source "$LODGE_DIR/lib/core/react_evaluator.sh"
source "$LODGE_DIR/lib/core/react_advisor.sh"

test_start "react_evaluator_advisor"
assert_fn_defined react_llm_json
assert_fn_defined react_eval_milestone
assert_fn_defined react_advise

d="$GEORGE_TEST_SANDBOX/evadv"; mkdir -p "$d"
cat > "$d/script.json" <<'EOF'
{"aux": "plain",
 "grammar": [
   {"verdict": "INCOMPLETE", "reason": "only navigation text", "next_action": "search a quote API"},
   {"verdict": "INCOMPLETE", "reason": "still no price", "next_action": "try stockanalysis"},
   {"verdict": "COMPLETE", "reason": "price 371.90 cited", "next_action": "synthesize"},
   {"verdict": "BLOCKED", "reason": "all sources paywalled", "next_action": "report gap"},
   {"diagnosis": "Every fetch hit paywalled finance portals.", "next_tool": "web_search", "args_hint": "query 'UNH stock price October 2026' and use snippets", "abandon_step": false}
 ]}
EOF
python3 "$LODGE_DIR/tests/helpers/mock_llm.py" "$d/port" "$d/script.json" "$d/llm.log" &
mpid=$!
for _i in $(seq 50); do [ -s "$d/port" ] && break; sleep 0.1; done
export REACT_EVAL_ENDPOINT="http://127.0.0.1:$(cat "$d/port")"
SD="$d/session"; mkdir -p "$SD"
printf '## Failed Attempts\n- [10:00:00] web_fetch({"url":"https://finance.yahoo.com/quote/UNH"}) → BLOCKED\n' > "$SD/scratchpad.md"

describe "evaluator verdicts"
o=$(react_eval_milestone "$SD" 1 "Find UNH price" "UNH outlook" "Help Log In Sign Up")
assert_eq "INCOMPLETE" "${o%%|*}" "verdict 1"
assert_eq "1" "$(react_eval_incomplete_count "$SD" 1)" "incomplete counted"
o=$(react_eval_milestone "$SD" 1 "Find UNH price" "UNH outlook" "still nothing")
assert_eq "2" "$(react_eval_incomplete_count "$SD" 1)" "second incomplete counted"
o=$(react_eval_milestone "$SD" 1 "Find UNH price" "UNH outlook" "UNH closed at 371.90")
assert_eq "COMPLETE" "${o%%|*}" "complete"
assert_contains "$o" "price 371.90 cited" "reason carried"
o=$(react_eval_milestone "$SD" 2 "Fetch analyst notes" "UNH outlook" "403")
assert_eq "BLOCKED" "${o%%|*}" "blocked"
assert_eq "4" "$(wc -l < "$SD/evaluator.jsonl" | tr -d ' ')" "verdicts journaled"

describe "requests are grammar-constrained at temperature 0.1"
assert_eq "0.1" "$(head -n 1 "$d/llm.log" | jq -r .temperature)" "temperature"
assert_contains "$(head -n 1 "$d/llm.log" | jq -r .grammar)" '"\"BLOCKED\""' "verdict enum in grammar"

describe "advisor"
a=$(react_advise "$SD" 1 "Find UNH price" "UNH outlook" "EVAL_INCOMPLETE_x2" "web_search,web_fetch,bash_exec")
assert_eq "web_search" "$(jq -r .next_tool <<<"$a")" "next tool"
g=$(tail -n 1 "$d/llm.log" | jq -r .grammar)
assert_contains "$g" '"\"web_fetch\""' "tool enum restricted to mounted tools"
assert_contains "$g" '"\"respond\""' "respond option offered"
r=$(react_advise_render "$a")
assert_contains "$r" "[ADVISOR] Diagnosis: Every fetch hit paywalled" "render diagnosis"
assert_contains "$r" "Next: call web_search" "render next"
react_advise "$SD" 1 "Find UNH price" "UNH outlook" "again" "web_search" >/dev/null
assert_fail $? "second consult on the same step refused"
echo 3 > "$SD/.advisor_count"
react_advise "$SD" 9 "Other" "UNH outlook" "again" "web_search" >/dev/null
assert_fail $? "per-run cap enforced"
assert_contains "$(react_advise_render '{"diagnosis":"x","next_tool":"respond","args_hint":"enough","abandon_step":true}')" "abandoned" "abandon rendered"

describe "evaluator degrades safely when endpoint is down"
kill "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null
REACT_EVAL_TIMEOUT=2 o=$(REACT_EVAL_TIMEOUT=2 react_eval_milestone "$SD" 3 "x" "y" "z")
assert_eq "INCOMPLETE" "${o%%|*}" "unavailable → INCOMPLETE"

describe "evaluator retries once with a longer timeout (single-slot contention)"
_calls="$d/calls"; : > "$_calls"
react_llm_json() { echo "$5" >> "$_calls"; [ "$(wc -l < "$_calls")" -ge 2 ] && echo '{"verdict":"COMPLETE","reason":"ok on retry","next_action":"go"}'; }
o=$(REACT_EVAL_TIMEOUT=45 REACT_EVAL_RETRY_TIMEOUT=150 react_eval_milestone "$SD" 4 "x" "y" "z")
assert_eq "COMPLETE" "${o%%|*}" "retry succeeds"
assert_eq "45,150" "$(paste -sd, "$_calls")" "second attempt uses the retry timeout"
: > "$_calls"
react_llm_json() { echo "$5" >> "$_calls"; return 1; }
o=$(react_eval_milestone "$SD" 5 "x" "y" "z")
assert_eq "INCOMPLETE|evaluator unavailable|continue" "$o" "both attempts fail → unavailable"
assert_eq "2" "$(wc -l < "$_calls" | tr -d ' ')" "exactly one retry"
assert_eq "0" "$(react_eval_incomplete_count "$SD" 5)" "unavailable does not count as an INCOMPLETE verdict"

test_end
