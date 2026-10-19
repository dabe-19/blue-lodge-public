#!/usr/bin/env bash
# challenge_solver.py: WAF detection + Reddit JS proof-of-work solver (curl stubbed, no network).
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR

test_start "challenge_solver (P4)"

out=$(GEORGE_DIR="$GEORGE_DIR" GEORGE_REDDIT_CHALLENGE_SOLVER=1 python3 - "$LODGE_DIR/lib/tools" <<'EOF'
import json, sys
sys.path.insert(0, sys.argv[1])
import challenge_solver as cs

r = {}
r["cf"] = cs.detect_challenge(200, "<html><title>Just a moment...</title>")
r["429"] = cs.detect_challenge(429, "")
r["ok"] = cs.detect_challenge(200, "<html>" + "real article text " * 3000 + " captcha mentioned in body</html>")
r["small_captcha"] = cs.detect_challenge(200, "<html>please solve the captcha</html>")

calls = []
CHALLENGE = ('<form><input type="hidden" name="jsc_token" value="TOK123"></form>'
             '<script>(async()=>{solution.value=await(async e=>e+e)("abc9");f.requestSubmit()})()</script> js_challenge')
state = {"solved": False}
def fake_curl(url, headers, jar, timeout=10.0):
    calls.append(url)
    if "js_challenge=1" in url:
        state["solved"] = True
        return 200, "ok"
    if state["solved"]:
        return 200, json.dumps([{"data": {"children": []}}])
    return 200, CHALLENGE
cs._curl = fake_curl
body = cs.fetch_reddit_json("https://www.reddit.com/r/test/comments/abc/x.json")
r["json_ok"] = body is not None and json.loads(body)[0]["data"]["children"] == []
solve = [c for c in calls if "js_challenge=1" in c]
r["solution"] = "solution=abc9abc9" in (solve[0] if solve else "")
r["token"] = "jsc_token=TOK123" in (solve[0] if solve else "")
r["https_only"] = all(c.startswith("https://") for c in calls)
r["non_reddit_refused"] = cs.fetch_reddit_json("https://evil.example/x.json") is None
r["http_refused"] = cs.fetch_reddit_json("http://www.reddit.com/r/x.json") is None
print(json.dumps(r))
EOF
)
j() { jq -r ".$1" <<<"$out"; }
assert_eq "HTML_CHALLENGE_OR_CAPTCHA" "$(j cf)" "cloudflare interstitial detected"
assert_eq "HTTP_429_BLOCK" "$(j '"429"')" "429 detected"
assert_eq "" "$(j ok)" "large real page with the word captcha is not blocked"
assert_eq "HTML_CHALLENGE_OR_CAPTCHA" "$(j small_captcha)" "small captcha page blocked"
assert_eq "true" "$(j json_ok)" "reddit JSON returned after solving PoW"
assert_eq "true" "$(j solution)" "solution = seed+seed"
assert_eq "true" "$(j token)" "jsc_token echoed"
assert_eq "true" "$(j https_only)" "https only"
assert_eq "true" "$(j non_reddit_refused)" "non-reddit URL refused"
assert_eq "true" "$(j http_refused)" "plain http refused"

# Feature flag: solver is OFF by default (public build) and features.conf can enable it.
flagdir=$(mktemp -d)
off=$(env -u GEORGE_REDDIT_CHALLENGE_SOLVER GEORGE_DIR="$flagdir" python3 - "$LODGE_DIR/lib/tools" <<'EOF'
import json, sys
sys.path.insert(0, sys.argv[1])
import challenge_solver as cs
calls = []
def fake_curl(url, headers, jar, timeout=10.0):
    calls.append(url)
    return 200, '<input name="jsc_token" value="T"> (async e=>e+e)("s") js_challenge'
cs._curl = fake_curl
body = cs.fetch_reddit_json("https://www.reddit.com/r/test/x.json")
print(json.dumps({"none": body is None, "solved": any("js_challenge=1" in c for c in calls),
                  "enabled": cs.solver_enabled()}))
EOF
)
assert_eq "false" "$(jq -r .enabled <<<"$off")" "solver disabled by default"
assert_eq "false" "$(jq -r .solved <<<"$off")" "no PoW submission when disabled"
assert_eq "true" "$(jq -r .none <<<"$off")" "interstitial gives up cleanly when disabled"
echo "GEORGE_REDDIT_CHALLENGE_SOLVER=1" > "$flagdir/features.conf"
on=$(env -u GEORGE_REDDIT_CHALLENGE_SOLVER GEORGE_DIR="$flagdir" python3 "$LODGE_DIR/lib/tools/feature_flags.py" get GEORGE_REDDIT_CHALLENGE_SOLVER)
assert_eq "1" "$on" "features.conf enables the solver"
off2=$(GEORGE_REDDIT_CHALLENGE_SOLVER=0 GEORGE_DIR="$flagdir" python3 "$LODGE_DIR/lib/tools/feature_flags.py" get GEORGE_REDDIT_CHALLENGE_SOLVER)
assert_eq "0" "$off2" "env overrides features.conf"
live=$(env -u GEORGE_EXECUTE_LIVE_SELL GEORGE_DIR="$(mktemp -d)" python3 "$LODGE_DIR/lib/tools/feature_flags.py" get GEORGE_EXECUTE_LIVE_SELL)
assert_eq "0" "$live" "live sell off by default"
rm -rf "$flagdir"
test_end
