#!/bin/bash
# ── Tests: Instrument Rack probe (lib/sys/rack_probe.py) ───────────────
# Hermetic: a fake llama.cpp endpoint on a random localhost port, fake
# endpoints.conf / remote.conf in a temp GEORGE_DIR.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/framework.sh"

PROBE="$LODGE_DIR/lib/sys/rack_probe.py"
TMP=$(mktemp -d /tmp/george-rack-test-XXXXXX)
GD="$TMP/.george"
mkdir -p "$GD/heartbeats" "$GD/discord_sessions" "$TMP/srv"

# Fake llama.cpp: /health, /props, /slots
cat > "$TMP/srv/fake.py" << 'EOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
R = {
    "/health": {"status": "ok"},
    "/props": {"model_path": "/models/qwen-test-q4.gguf", "default_generation_settings": {"n_ctx": 32768}},
    "/slots": [{"id": 0, "is_processing": True}, {"id": 1, "is_processing": False}],
}
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = R.get(self.path)
        if body is None:
            self.send_response(404); self.end_headers(); return
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
s = HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
EOF
python3 "$TMP/srv/fake.py" > "$TMP/srv/port" 2>/dev/null &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/srv/port" ] && break; sleep 0.1; done
PORT=$(head -n1 "$TMP/srv/port")
DEAD_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

cleanup() { kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

cat > "$GD/endpoints.conf" << EOF
TIER1_NAME="primary-test"
TIER1_URL="http://127.0.0.1:${PORT}"
TIER1_MODEL="qwen-test"
TIER1_CONTEXT=65536
TIER1_ROLES="planning,coding"
TIER1_ENABLED=1
TIER2_NAME="tunnel-worker"
TIER2_URL="http://127.0.0.1:${DEAD_PORT}"
TIER2_ROLES="vision"
TIER2_ENABLED=1
TIER3_NAME="lan-box"
TIER3_URL="http://192.168.1.50:8080"
TIER3_ENABLED=0
TIER0_NAME="secret-test"
TIER0_URL="http://user:hunter2@127.0.0.1:${DEAD_PORT}/"
TIER0_API_KEY="sk-should-never-appear"
TIER0_ENABLED=0
EOF
cat > "$GD/remote.conf" << EOF
REMOTE_SSH_TARGET=ops@10.0.0.5
REMOTE_JUMP_HOST=ops@10.0.0.1
REMOTE_LOCAL_LLAMACPP_PORT=${DEAD_PORT}
REMOTE_SSH_KEY=/home/ops/.ssh/id_secret
EOF
printf '{"name":"cron","ts":%s}\n' "$(( $(date +%s) - 4000 ))" > "$GD/heartbeats/cron.json"

OUT=$(python3 "$PROBE" --george-dir "$GD" --timeout 1 2>&1)
q() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))" "$OUT" "$1" 2>&1; }

test_start "Instrument Rack Probe"

describe "output shape"
it "emits valid JSON with control, nodes, roles and findings" && {
    assert_eq "$(q "sorted(k for k in d if k in ('control','nodes','roles','findings'))")" "['control', 'findings', 'nodes', 'roles']"
    assert_not_empty "$(q "d['control']['hostname']")"
}

describe "compute nodes"
it "probes a live llama.cpp node: model, ctx and slot usage" && {
    assert_eq "$(q "[n for n in d['nodes'] if n['tier']==1][0]['status']")" "online"
    assert_eq "$(q "[n for n in d['nodes'] if n['tier']==1][0]['live_model']")" "qwen-test-q4"
    assert_eq "$(q "[n for n in d['nodes'] if n['tier']==1][0]['live_ctx']")" "32768"
    assert_eq "$(q "[n for n in d['nodes'] if n['tier']==1][0]['slots_busy']")" "1"
}

it "classifies network paths (local / tunnel / lan)" && {
    assert_eq "$(q "[n for n in d['nodes'] if n['tier']==1][0]['path']")" "local"
    assert_eq "$(q "[n for n in d['nodes'] if n['tier']==2][0]['path']")" "tunnel"
    assert_eq "$(q "[n for n in d['nodes'] if n['tier']==3][0]['path']")" "lan"
    assert_contains "$(q "[n for n in d['nodes'] if n['tier']==2][0]['via']")" "jump ops@10.0.0.1"
}

it "reports disabled nodes without probing them" && {
    assert_eq "$(q "[n for n in d['nodes'] if n['tier']==3][0]['status']")" "disabled"
}

describe "findings"
it "flags the dead tunnel node, configured ctx above n_ctx, uncovered role, stale heartbeat" && {
    f=$(q "' | '.join(x['msg'] for x in d['findings'])")
    assert_contains "$f" "SSH tunnel"
    assert_contains "$f" "exceeds the server's n_ctx 32768"
    assert_contains "$f" "Role 'vision' has no online node"
    assert_contains "$f" "Heartbeat 'cron' is stale"
}

describe "secrets"
it "never outputs API keys, URL credentials or SSH key paths" && {
    assert_not_contains "$OUT" "sk-should-never-appear"
    assert_not_contains "$OUT" "hunter2"
    assert_not_contains "$OUT" "id_secret"
    assert_eq "$(q "d['tunnel']['key']")" "set"
}

it "handles a missing GEORGE_DIR config gracefully" && {
    out2=$(python3 "$PROBE" --george-dir "$TMP/empty" --timeout 1 2>&1); rc=$?
    assert_eq "$rc" 0
    assert_contains "$out2" "No compute nodes configured"
}

test_end
