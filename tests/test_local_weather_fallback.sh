#!/usr/bin/env bash
# ── Tests: local_weather multi-provider fallback & graceful degradation ──
# Remediation for failure fingerprint job_fail_local_weather (issue #463).
# Contract:
#   1. Job script is pure bash/curl/jq (no python/node runtime dependency).
#   2. Condition-code mappers (WMO for Open-Meteo, WWO for wttr.in) are correct.
#   3. E2E via disposable local stubs (python3 test fixture ONLY — never a
#      dependency of the job script itself; no live Discord is contacted):
#      a. happy path (Tier 1 Open-Meteo) exits 0
#      b. Tier 1 down -> Tier 2 wttr.in fallback exits 0
#      c. ALL providers down -> degraded notice, exit 0 (previously exit 1)
#      d. missing bot token -> genuine defect still exits non-zero
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"

JOB="$GEORGE_TEST_REPO/.george/cron_jobs/local_weather.sh"
[ -f "$JOB" ] || { echo "SKIP: $JOB not found"; exit 0; }

test_start "local_weather fallback ladder (job_fail_local_weather remediation)"

# 1. Syntax
bash -n "$JOB"
assert_ok $? "job script must parse"

# 2. Architectural purity: no python/node runtime in the job artifact
grep -nE 'python[0-9]?|node |npx |pip install|npm i' "$JOB" > /dev/null 2>&1
assert_fail $? "job script must not depend on python/node runtimes"

# 3. Condition-code mappers (extract + eval, avoids executing the full job)
eval "$(sed -n '/^wmo_condition()/,/^}/p' "$JOB")"
assert_eq "$(wmo_condition 0)"  "Clear sky"
assert_eq "$(wmo_condition 2)"  "Mainly clear / Overcast"
assert_eq "$(wmo_condition 63)" "Rain"
assert_eq "$(wmo_condition 99)" "Thunderstorm"
assert_eq "$(wmo_condition 77)" "Unknown"
eval "$(sed -n '/^wwo_condition()/,/^}/p' "$JOB")"
assert_eq "$(wwo_condition 113)" "Clear / Sunny"
assert_eq "$(wwo_condition 176)" "Rain"
assert_eq "$(wwo_condition 329)" "Snow"
assert_eq "$(wwo_condition 555)" "Unknown"

# 4. End-to-end with disposable local stubs (python3 as test fixture only)
PORT=18973
if command -v python3 > /dev/null 2>&1; then
    STUB="$(mktemp /tmp/weather_stub.XXXXXX.py)"
    cat > "$STUB" <<'PYEOF'
import http.server, json, sys
port = int(sys.argv[1])
OM = {"current": {"temperature_2m": 42.5, "relative_humidity_2m": 55,
                 "wind_speed_10m": 8.0, "weather_code": 1}}
WT = {"current_condition": [{"temp_F": "61", "humidity": "40",
                             "windspeedMiles": "5", "weatherCode": "116"}]}
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if "forecast" in self.path: self._send(OM)
        elif "j1" in self.path: self._send(WT)
        else: self._send({"id": "none"})
    def do_POST(self):
        ln = int(self.headers.get("Content-Length", 0) or 0)
        if ln: self.rfile.read(ln)
        if "messages" in self.path: self._send({"id": "stub-msg-1"})
        elif "channels" in self.path: self._send({"id": "stub-chan-1"})
        else: self._send({"id": "none"})
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
    python3 "$STUB" "$PORT" > /dev/null 2>&1 &
    STUB_PID=$!
    trap 'kill $STUB_PID 2>/dev/null; rm -f "$STUB"' EXIT
    sleep 1

    FAKE_KEYS="$(mktemp)"; echo 'DISCORD_BOT_TOKEN=stub-token' > "$FAKE_KEYS"

    # 4a. Happy path: Tier 1 (Open-Meteo shape) + stub Discord
    out=$(METEO_URL="http://127.0.0.1:$PORT/v1/forecast" \
           WTTR_URL="http://127.0.0.1:$PORT/wttr?format=j1" \
           API_URL="http://127.0.0.1:$PORT" KEYS_FILE="$FAKE_KEYS" \
           bash "$JOB" 2>&1); rc=$?
    assert_ok $rc "happy path must exit 0: $out"
    assert_contains "$out" "Successfully delivered"
    assert_contains "$out" "stub-msg-1"

    # 4b. Fallback ladder: Tier 1 down -> Tier 2 (wttr.in shape) must deliver
    out=$(METEO_URL="http://127.0.0.1:1/dead" \
           WTTR_URL="http://127.0.0.1:$PORT/wttr?format=j1" \
           API_URL="http://127.0.0.1:$PORT" KEYS_FILE="$FAKE_KEYS" \
           bash "$JOB" 2>&1); rc=$?
    assert_ok $rc "fallback to wttr.in tier must exit 0: $out"
    assert_contains "$out" "Successfully delivered"
    assert_not_contains "$out" "WARNING"

    # 4c. ORIGINAL INCIDENT SCENARIO: all weather providers down.
    #     Must degrade gracefully (notice + exit 0), not hard-fail (exit 1).
    out=$(METEO_URL="http://127.0.0.1:1/dead" \
           WTTR_URL="http://127.0.0.1:1/dead" \
           API_URL="http://127.0.0.1:$PORT" KEYS_FILE="$FAKE_KEYS" \
           bash "$JOB" 2>&1); rc=$?
    assert_ok $rc "total weather outage must exit 0 (graceful degradation): $out"
    assert_contains "$out" "WARNING: all weather providers unavailable"
    assert_contains "$out" "Successfully delivered"

    # 4d. Genuine job defect: missing bot token still hard-fails
    EMPTY_KEYS="$(mktemp)"
    out=$(METEO_URL="http://127.0.0.1:$PORT/v1/forecast" \
           WTTR_URL="http://127.0.0.1:$PORT/wttr?format=j1" \
           API_URL="http://127.0.0.1:$PORT" KEYS_FILE="$EMPTY_KEYS" \
           bash "$JOB" 2>&1); rc=$?
    assert_fail $rc "missing DISCORD_BOT_TOKEN must still exit non-zero"
    assert_contains "$out" "DISCORD_BOT_TOKEN missing"

    kill "$STUB_PID" 2>/dev/null
    rm -f "$STUB" "$FAKE_KEYS" "$EMPTY_KEYS"
else
    echo "SKIP: python3 stub fixture unavailable; skipped e2e cases 4a-4d"
fi

test_end
