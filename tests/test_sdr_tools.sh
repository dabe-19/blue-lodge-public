#!/usr/bin/env bash
# Tests: SDR Radio Lab tools (sdr_query, sdr_listen) + native_tools bundle mounting
source "$(dirname "$0")/framework.sh"
test_start "sdr_tools"

PY="$LODGE_DIR/.venv/bin/python3"; [ -x "$PY" ] || PY=python3

describe "sdr_ingest --query summary, stats, and JSON output"
q_json=$("$PY" "$LODGE_DIR/lib/tools/sdr_ingest.py" --query --hours 24 --mode stats --limit 5 --json)
assert_contains "$q_json" '"status": "ok"' "sdr_ingest --query --json returns status ok"
assert_contains "$q_json" '"window_statistics"' "sdr_ingest --query --json includes window_statistics"

q_md=$("$PY" "$LODGE_DIR/lib/tools/sdr_ingest.py" --query --hours 24 --mode summary --limit 5)
assert_contains "$q_md" "Sovereign P25 SDR Intelligence Query" "sdr_ingest --query markdown header rendered"

describe "native_tools registration and +social/+sdr bundle mounting"
source "$LODGE_DIR/lib/tools/native_tools.sh"
social_tools=$(native_tools_bundle_tools "+social")
assert_contains "$social_tools" "sdr_query" "+social bundle mounts sdr_query"
assert_contains "$social_tools" "sdr_listen" "+social bundle mounts sdr_listen"

sdr_bundle=$(native_tools_bundle_tools "+sdr")
assert_contains "$sdr_bundle" "sdr_query" "+sdr bundle mounts sdr_query"
assert_contains "$sdr_bundle" "sdr_listen" "+sdr bundle mounts sdr_listen"

assert_eq "$(jq -r '[.[] | select(.function.name=="sdr_query" or .function.name=="sdr_listen")] | length' "$LODGE_DIR/data/schemas/native_tools.json")" "2" "both SDR tools present in data/schemas/native_tools.json"

test_end

