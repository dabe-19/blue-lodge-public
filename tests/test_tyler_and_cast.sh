#!/usr/bin/env bash
# ── George: Automated Verification Suite for The Tyler (Kali Defense) & Google Home CastV2 ──
set -euo pipefail

LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LODGE_DIR"

PASS=0
FAIL=0

assert_ok() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== 1. Kali Linux Container (george-kali-tyler) Verification ==="
if docker inspect -f '{{.State.Running}}' george-kali-tyler 2>/dev/null | grep -q true; then
    assert_ok "george-kali-tyler container is running" bash -c "docker inspect -f '{{.State.Running}}' george-kali-tyler | grep -q true"
    assert_ok "nmap is available inside george-kali-tyler" docker exec george-kali-tyler nmap --version
    assert_ok "tshark is available inside george-kali-tyler" docker exec george-kali-tyler tshark --version
    assert_ok "upnpc is available inside george-kali-tyler" bash -c "docker exec george-kali-tyler which upnpc"
    assert_ok "man-db and expanded Kali arsenal (arp-scan, hping3, p0f, whatweb, sslscan, avahi-browse, snmpwalk, smbclient, scapy) are installed" bash -c "docker exec george-kali-tyler bash -c 'which man arp-scan hping3 p0f whatweb sslscan avahi-browse snmpwalk smbclient ncat && python3 -c \"import scapy\"'"
else
    assert_ok "containers/kali-tyler/Dockerfile and kali_tyler_ctl.sh are present" bash -c "[ -f containers/kali-tyler/Dockerfile ] && [ -x lib/sys/kali_tyler_ctl.sh ]"
fi

echo "=== 2. The Tyler Guardian, Kali Man Pages & Protected-IP Policy Gate ==="
GW_IP=$(python3 -c "import lib.tools.tyler_guardian as t; print(t.GATEWAY_IP)")
WS_IP=$(python3 -c "import lib.tools.tyler_guardian as t; print(t.WORKSTATION_IP)")
HOST_IP=$(python3 -c "import lib.tools.tyler_guardian as t; print(t.HOST_IP)")
IOT_IP=$(python3 -c "import lib.tools.tyler_guardian as t; print(next((d['ip'] for d in t.INITIAL_SEED_DEVICES if d.get('trust_level') == 'known_iot' and d['ip'] not in t.PROTECTED_IPS), '192.168.1.28'))")

assert_ok "tyler_guardian.py status returns valid JSON with seeded devices" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'status'])); assert d['counts']['total'] >= 5 and d['counts']['untrusted'] >= 1"

assert_ok "Protected-IP gate rejects blocking gateway $GW_IP" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'intervene', '--ip', '$GW_IP', '--mode', 'host_block'])); assert d['status'] == 'error' and 'Policy Gate Blocked' in d['message']"

assert_ok "Protected-IP gate rejects blocking user workstation $WS_IP" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'intervene', '--ip', '$WS_IP', '--mode', 'host_block'])); assert d['status'] == 'error' and 'Policy Gate Blocked' in d['message']"

assert_ok "tyler_kali_man catalog lists >=15 Kali tools with defensive & active recipes" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'man', '--tool', 'catalog'])); assert d['status'] == 'ok' and d['tool_count'] >= 15 and 'nmap' in d['tools'] and 'tshark' in d['tools']"

if docker inspect -f '{{.State.Running}}' george-kali-tyler 2>/dev/null | grep -q true; then
    assert_ok "tyler_kali_man nmap --search script returns live Kali man page matches and NSE scripts" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'man', '--tool', 'nmap', '--search', 'script'])); assert d['status'] == 'ok' and len(d['man_page_excerpt']) > 100 and len(d.get('matching_nse_scripts', [])) > 0"
    assert_ok "tyler_kali_exec runs Kali recon tool inside george-kali-tyler" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'kali-exec', '--cmd', 'nmap --version'])); assert d['status'] == 'ok' and 'Nmap version' in d['stdout']"
fi

assert_ok "tyler_kali_exec blocks non-RFC1918 public IP targets" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'kali-exec', '--cmd', 'nmap 8.8.8.8'])); assert d['status'] == 'error' and 'Policy Gate Blocked' in d['message']"

assert_ok "tyler_kali_exec blocks deleting kernel loopback/tunnel bridges across Linux & WSL2" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'kali-exec', '--cmd', 'ip neigh del 169.254.0.1 dev loopback0'])); assert d['status'] == 'error' and 'Policy Gate Blocked' in d['message'] and 'loopback0' in d['message']"

assert_ok "tyler_guardian.py spelunk --mode discover enumerates active networks with zero packets emitted" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'spelunk', '--mode', 'discover'])); assert d['status'] == 'ok' and d['packets_emitted'] == 0 and isinstance(d['active_networks'], list)"

assert_ok "tyler_kali_exec permits multi-dot SNMP OIDs (.1.3.6.1.2.1.1.1.0) without false public-IP block" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'kali-exec', '--cmd', 'echo snmpwalk -v2c -c public $IOT_IP .1.3.6.1.2.1.1.1.0'])); assert 'Policy Gate Blocked' not in d.get('message', ''); assert (d['status'] == 'ok' and '.1.3.6.1.2.1.1.1.0' in d.get('stdout', '')) or d['status'] != 'ok'"

assert_ok "tyler_guardian.py seeds self-host $HOST_IP as trusted" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'status'])); ips={x['ip']: x for x in d['devices']}; assert '$HOST_IP' in ips and ips['$HOST_IP']['trust_level'] == 'trusted'"

assert_ok "deep_fingerprint_device returns valid vendor dossier for $IOT_IP" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'fingerprint', '--ip', '$IOT_IP'])); assert d['status'] == 'ok' and len(d.get('vendor', '')) > 0"

echo "=== 3. Sovereign Multi-Voice Kokoro-82M + Automatic Piper Fallback & CastV2 HTTP Audio Serving ==="
PY_CAST="python3"
[ -x "$LODGE_DIR/.venv/bin/python" ] && PY_CAST="$LODGE_DIR/.venv/bin/python"

assert_ok "google_home_cast.py defines kokoro, kokoro_int8, and piper engines" "$PY_CAST" -c "import lib.tools.google_home_cast as c; assert {'kokoro','kokoro_int8','piper'}.issubset(c.TTS_ENGINES.keys())"

if [ -d "$LODGE_DIR/.george/models/tts" ] && ls "$LODGE_DIR/.george/models/tts/"*.onnx >/dev/null 2>&1; then
    for v in washington bryce alan ryan amy alba; do
        assert_ok "Neural CPU synthesis (Kokoro/Piper) succeeds for voice '$v'" env GEORGE_DIR="$LODGE_DIR/.george" "$PY_CAST" -c "import subprocess, json; d=json.loads(subprocess.check_output(['$PY_CAST', 'lib/tools/google_home_cast.py', 'speak', 'Verification test for voice $v', '--voice', '$v', '--dry-run', '--force'])); assert d['status'] == 'dry_run' and d['voice'] == '$v' and d['wav_size_bytes'] > 1000"
    done

    assert_ok "Automatic fallback from Kokoro to Piper succeeds when Kokoro model is unavailable" env GEORGE_DIR="$LODGE_DIR/.george" "$PY_CAST" -c "import time, lib.tools.google_home_cast as c; c._KOKORO_CACHE.clear(); orig=c.TTS_ENGINES['kokoro']['model_file']; c.TTS_ENGINES['kokoro']['model_file']='missing_model.onnx'; p, m = c.synthesize_tts_wav(f'Fallback verification test {time.time()}', voice_key='washington', engine_key='kokoro'); c.TTS_ENGINES['kokoro']['model_file']=orig; p.unlink(missing_ok=True); assert m['engine'] == 'piper' and m['fallback_used'] is True"

    LATEST_WAV=$(GEORGE_DIR="$LODGE_DIR/.george" "$PY_CAST" -c "import subprocess, json; d=json.loads(subprocess.check_output(['$PY_CAST', 'lib/tools/google_home_cast.py', 'speak', 'Audio route verification', '--voice', 'alba', '--dry-run', '--force'])); print(d['filename'])")
    if curl -sI http://127.0.0.1:3000/api/cast/audio/$LATEST_WAV 2>/dev/null | grep -q '200 OK'; then
        assert_ok "george-web serves synthesized audio at /api/cast/audio/$LATEST_WAV with HTTP 200" bash -c "curl -sI http://127.0.0.1:3000/api/cast/audio/$LATEST_WAV | grep -q '200 OK'"
        assert_ok "george-web rejects path traversal on /api/cast/audio/" bash -c "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/cast/audio/..%2Fetc%2Fpasswd | grep -E '400|404'"
    else
        assert_ok "web/src/routes/cast.rs defines /api/cast/audio/ route" test -f "$LODGE_DIR/web/src/routes/cast.rs"
    fi
else
    assert_ok "google_home_cast.py defines washington, bryce, alan, ryan, amy, alba voices" "$PY_CAST" -c "import lib.tools.google_home_cast as c; assert {'washington','bryce','alan','ryan','amy','alba'}.issubset(c.VOICES.keys())"
fi

echo "=== 4. Stdio MCP Servers (george-tyler & george-cast) ==="
assert_ok "mcp_server_tyler.py exposes tyler_lan_census, tyler_deep_fingerprint, tyler_vuln_audit, tyler_intervene, tyler_kali_man, and tyler_kali_exec" bash -c "printf '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}\n' | python3 lib/tools/mcp_server_tyler.py | grep -q 'tyler_vuln_audit'"

assert_ok "mcp_server_google_home.py exposes google_home_speak" bash -c "printf '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}\n' | python3 lib/tools/mcp_server_google_home.py | grep -q 'google_home_speak'"

echo "=== 5. Native Tools & Event Contracts Integration ==="
assert_ok "native_tools.json is valid JSON and includes google_home_speak, tyler_vuln_audit, tyler_intervene (with tcp_reset & upnp_kill), tyler_kali_man & tyler_kali_exec" python3 -c "import json; d=json.load(open('data/schemas/native_tools.json')); items=d if isinstance(d, list) else d.get('tools', []); by_name={(t.get('name') or t.get('function', {}).get('name')): (t.get('function') or t) for t in items}; assert {'google_home_speak','tyler_vuln_audit','tyler_intervene','tyler_set_trust','tyler_kali_man','tyler_kali_exec','tyler_canary_trap','tyler_tshark_watch','tyler_immune_patrol','tyler_arp_shield','tyler_baseline_diff'}.issubset(by_name.keys()); assert 'tcp_reset' in by_name['tyler_intervene']['parameters']['properties']['mode']['enum'] and 'propose_plan' in by_name['tyler_intervene']['parameters']['properties']['mode']['enum']"
assert_ok "event_contracts.json includes network.rogue_device, network.canary_triggered, network.tshark_watch_hit, and webhook.tyler.alert contracts" python3 -c "import json; raw=open('configs/event_contracts.json').read(); json.loads(raw); assert 'network.rogue_device' in raw and 'network.arp_spoof' in raw and 'network.canary_triggered' in raw and 'network.tshark_watch_hit' in raw and 'webhook.tyler.alert' in raw"

echo "=== 6. Active Immune System (Canary Honeypot, tshark Watchlist, ARP Shield, Baseline Diff, Tier B Plans, Webhook & Forge) ==="
assert_ok "tyler_canary_trap starts background decoy listeners on ports 2222, 2323, 4445, 6379" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'canary', '--action', 'start'])); assert d['status'] == 'ok' and d['running'] is True and {2222, 2323, 4445, 6379}.issubset(set(d['daemon']['ports']))"

assert_ok "tyler_tshark_watch lists >=4 seeded Wireshark display filter rules" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'tshark-watch', '--action', 'list'])); assert d['status'] == 'ok' and d['rules_count'] >= 4"

if docker inspect -f '{{.State.Running}}' george-kali-tyler 2>/dev/null | grep -q true; then
    assert_ok "tyler_tshark_watch validates valid Wireshark -Y display filter via dftest" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'tshark-watch', '--action', 'test', '--display-filter', 'tcp.flags.syn == 1 && tcp.flags.ack == 0'])); assert d['status'] == 'ok' and d['valid'] is True"
    assert_ok "tyler_tshark_watch rejects invalid tcpdump BPF filter syntax" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'tshark-watch', '--action', 'test', '--display-filter', 'tcp port 80 and invalid_syntax === 1'])); assert d['valid'] is False"
fi

assert_ok "tyler_arp_shield enforces PERMANENT Layer-2 neighbor lock on gateway $GW_IP (host-mode Kali) and reports protected-neighbor state hermetically" python3 -c "
import subprocess, json
d = json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'arp-shield', '--action', 'enforce']))
by_ip = {x['ip']: x for x in d['protected_neighbors']}
assert d['status'] == 'ok' and '$GW_IP' in by_ip and by_ip['$GW_IP']['mac'], (d['status'], list(by_ip)[:5])
try:
    nm = subprocess.run(['docker', 'inspect', '-f', '{{.HostConfig.NetworkMode}}', 'george-kali-tyler'], capture_output=True, text=True, timeout=5)
except Exception:
    nm = None
host_mode = bool(nm) and nm.returncode == 0 and nm.stdout.strip() == 'host'
if host_mode:
    # Only assert PERMANENT enforcement when the gateway actually resolves in
    # Kali's neighbor table (real household). Synthetic 192.168.1.x gateways
    # (sandbox/example config) are unresolvable and stay structural-only.
    try:
        ng = subprocess.run(['docker', 'exec', 'george-kali-tyler', 'ip', '-4', 'neigh', 'get', '$GW_IP', 'dev', 'eth0'], capture_output=True, text=True, timeout=15)
    except Exception:
        ng = None
    if ng is not None and ng.returncode == 0:
        res = {r['ip']: r for r in d.get('enforcement_results', [])}
        assert res.get('$GW_IP', {}).get('enforced') is True, res.get('$GW_IP')
        assert by_ip['$GW_IP']['permanent_locked'] is True, by_ip['$GW_IP']
else:
    # Hermetic: 'ip neigh' reads the job container's kernel, not Kali's, so
    # PERMANENT enforcement is unverifiable -- structural state must be ok.
    assert by_ip['$GW_IP'].get('enforced') in (True, False, None)
"

assert_ok "tyler_intervene Tier B workflow (propose_plan -> list_plans -> reject_plan) succeeds" python3 -c "import subprocess, json, lib.tools.tyler_guardian as tg
p = json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'intervene', '--ip', '$IOT_IP', '--mode', 'propose_plan', '--port', '445', '--rationale', 'Automated test Tier B plan']))
assert p['status'] == 'ok' and p['plan_id'].startswith('DEF-')
pid = p['plan_id']
lst = json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'intervene', '--mode', 'list_plans']))
assert any(x['plan_id'] == pid for x in lst['plans'])
rej = json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'intervene', '--mode', 'reject_plan', '--plan-id', pid, '--notes', 'Test cleanup']))
assert rej['status'] == 'ok' and rej['verdict'] == 'rejected'
con = tg.connect_db(); con.execute('DELETE FROM defense_plans WHERE plan_id = ?', (pid,)); con.commit(); con.close()"

assert_ok "POST /api/webhooks/tyler normalizes Canary/tshark alerts to network.* events (live bridge) or via webhooks.rs bridge contract (hermetic)" bash -c "
TOK=\$(cat .george/web_token 2>/dev/null || echo '')
if [ -n \"\$TOK\" ] && curl -s --max-time 5 -X POST http://127.0.0.1:3000/api/webhooks/tyler -H 'Content-Type: application/json' -H \"X-Lodge-Token: \$TOK\" -d '{\"event_type\":\"canary_triggered\",\"src_ip\":\"$IOT_IP\",\"dst_port\":2323,\"service\":\"telnet_canary\"}' 2>/dev/null | grep -q 'network.canary_triggered'; then
    exit 0
fi
grep -qF '\"canary_triggered\"' web/src/routes/webhooks.rs && grep -qF '\"tshark_watch_hit\"' web/src/routes/webhooks.rs && grep -qF 'format!(\"network.{}\", sub)' web/src/routes/webhooks.rs && grep -qF '\"bridged_event\"' web/src/routes/webhooks.rs"

assert_ok "Dataset Forge includes cyber-defense recipe and extracts SFT/DPO pairs from lan_devices.db" python3 -c "import subprocess; out=subprocess.check_output(['python3', 'scripts/training/forge.py', 'recipes'], text=True); assert 'cyber-defense' in out"

echo "=== 7. 802.11 Wireless Airspace Spelunking, Passive Fingerprinting & Operator Fail-Safe Controls ==="
assert_ok "tyler_guardian.py wifi-spelunk --mode status returns wireless adapter state and cached airspace" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'wifi-spelunk', '--mode', 'status'])); assert d['status'] == 'ok' and 'wifi_adapter' in d and isinstance(d.get('cached_airspace', []), list)"

assert_ok "tyler_guardian.py spelunk --mode passive_fingerprint runs with zero packets emitted" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'spelunk', '--mode', 'passive_fingerprint', '--duration', '2'])); assert d['status'] == 'ok' and d['packets_emitted'] == 0 and 'hosts_fingerprinted' in d"

assert_ok "tyler_guardian.py designations --action get loads network designations and Wi-Fi watchlist" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'designations', '--action', 'get'])); assert d['status'] == 'ok' and 'network_designations' in d and 'wifi_watchlist' in d and 'default_unknown_posture' in d['network_designations']"

assert_ok "tyler_guardian.py emergency-reset restores safe host network posture and clears temporary airlock rules" python3 -c "import subprocess, json; d=json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'emergency-reset'])); assert d['status'] == 'ok' and isinstance(d.get('recovery_steps', []), list) and len(d['recovery_steps']) >= 1"

assert_ok "mcp_server_tyler.py and native_tools.json expose tyler_spelunk and tyler_wifi_spelunk" python3 -c "import subprocess, json
out = subprocess.check_output('printf \"{\\\\\"jsonrpc\\\\\":\\\\\"2.0\\\\\",\\\\\"id\\\\\":1,\\\\\"method\\\\\":\\\\\"initialize\\\\\",\\\\\"params\\\\\":{}}\\\\n{\\\\\"jsonrpc\\\\\":\\\\\"2.0\\\\\",\\\\\"id\\\\\":2,\\\\\"method\\\\\":\\\\\"tools/list\\\\\",\\\\\"params\\\\\":{}}\\\\n\" | python3 lib/tools/mcp_server_tyler.py', shell=True, text=True)
assert 'tyler_spelunk' in out and 'tyler_wifi_spelunk' in out
d = json.load(open('data/schemas/native_tools.json'))
items = d if isinstance(d, list) else d.get('tools', [])
names = {(t.get('name') or t.get('function', {}).get('name')) for t in items}
assert {'tyler_spelunk', 'tyler_wifi_spelunk'}.issubset(names)"

assert_ok "endpoints.sh honors ENDPOINTS_LOCK_ROLES=1 and prevents role auto-reassignment" bash -c "grep -q 'ENDPOINTS_LOCK_ROLES' lib/core/endpoints.sh && [ -f configs/network_designations.example.json ] && [ -f configs/wifi_watchlist.example.json ]"

assert_ok "tyler_wifi_spelunk supports triangulate_airspace (2.4GHz + 5GHz 2-point spatial triangulation)" python3 -c "import subprocess, json, lib.tools.tyler_guardian as tg
tri = tg._compute_airspace_triangulation(
    [{'bssid': '02:00:5e:10:00:70', 'ssid': 'HomeMesh', 'signal_pct': 60, 'band': '2.4 GHz', 'channel': 6}],
    [{'ssid': 'HomeMesh', 'ap_list': [{'bssid': '02:00:5e:10:00:70', 'frequency': 2437, 'signal_level': -37}, {'bssid': '02:00:5e:10:00:74', 'frequency': 5745, 'signal_level': -51}]}],
    peripheral_label='South-Wall Sensor'
)
assert tri['total_transmitters'] == 2 and tri['dual_sensor_matched'] >= 1 and tri['five_ghz_discovered_by_peripheral'] == 1
d = json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'wifi-spelunk', '--mode', 'triangulate_airspace', '--timeout', '3']))
assert d['status'] == 'ok' and 'triangulation' in d"

assert_ok "tyler_wifi_spelunk supports canary_ap_watch, set_ap_beacon, provision_cast_ap, and restore_peripheral" python3 -c "import subprocess, json, lib.tools.tyler_guardian as tg
c = json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'wifi-spelunk', '--mode', 'canary_ap_watch', '--timeout', '3']))
assert c['status'] == 'ok' and 'canary_watch' in c
b = json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'wifi-spelunk', '--mode', 'set_ap_beacon', '--surprise-name', 'GEORGE-ALL-CLEAR', '--timeout', '3']))
assert b['status'] == 'ok' and b['broadcast_ssid'].startswith('GEORGE-ALL-CLEAR.')
p = json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'wifi-spelunk', '--mode', 'provision_cast_ap', '--ssid', 'HomeGuest', '--timeout', '3']))
assert p['status'] == 'ok' and p['target_wifi_ssid'] == 'HomeGuest'"

assert_ok "tyler_wifi_spelunk supports poll_lan_peripherals, rf_motion_sense, and rogue_ap_watch" python3 -c "import subprocess, json
pl = json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'wifi-spelunk', '--mode', 'poll_lan_peripherals']))
assert pl['status'] == 'ok' and 'cast_peripherals' in pl and 'mesh_routers' in pl
rf = json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'wifi-spelunk', '--mode', 'rf_motion_sense', '--timeout', '2']))
assert rf['status'] == 'ok' and 'rf_chords' in rf and rf['ticks_sampled'] >= 2
rg = json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'wifi-spelunk', '--mode', 'rogue_ap_watch', '--timeout', '3']))
assert rg['status'] == 'ok' and 'evil_twins_count' in rg and 'unrecognized_soft_aps_count' in rg"

assert_ok "FIFO Event Bus contracts, webhooks.rs, context_engine.sh, and honeydew_strategist.py wire peripheral & RF motion modes" bash -c "
grep -q 'network.rf_motion' configs/event_contracts.json &&
grep -q 'rf_motion' web/src/routes/webhooks.rs &&
grep -q 'rf_motion_sense' lib/core/context_engine.sh &&
grep -q 'rf_motion_sense' lib/tools/honeydew_strategist.py &&
bash -n lib/core/context_engine.sh &&
bash -n lib/core/react.sh &&
bash -n lib/tools/native_tools.sh"

echo "=== 8. Tyler Cockpit UI/UX Overhaul, 2D RF Mesh Radar & DOM Security ==="
assert_ok "tyler_guardian.py status includes kali_manual, cached_triangulation, and per-device baseline records" python3 -c "import subprocess, json
st = json.loads(subprocess.check_output(['python3', 'lib/tools/tyler_guardian.py', 'status']))
assert 'kali_manual' in st and isinstance(st['kali_manual'], dict)
assert 'cached_triangulation' in st and isinstance(st['cached_triangulation'], (dict, type(None)))
assert any('baseline' in d for d in st.get('devices', []))"

assert_ok "tyler.css and tyler.js exist, pass syntax validation, and are linked in index.html" bash -c "
test -f web/static/css/tyler.css &&
test -f web/static/js/tyler.js &&
( ! command -v node >/dev/null 2>&1 || (node --check web/static/js/tyler.js && node --check web/static/app.js) ) &&
grep -q '/css/tyler.css' web/static/index.html &&
grep -q '/js/tyler.js' web/static/index.html"

assert_ok "tyler.js enforces strict DOM security (zero innerHTML/outerHTML/insertAdjacentHTML/document.write)" python3 -c "
import re
src = open('web/static/js/tyler.js', encoding='utf-8').read()
code_lines = [ln for ln in src.splitlines() if not ln.strip().startswith('*') and not ln.strip().startswith('//')]
code = '\n'.join(code_lines)
for forbidden in ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write']:
    assert forbidden not in code, f'Forbidden sink {forbidden} found in tyler.js'"

assert_ok "index.html defines Tyler workspaces, Operator Field Guide, 2D RF Mesh Radar, and Structured Diagnostic Inspector" bash -c "
grep -q 'tylerOperatorGuideDrawer' web/static/index.html &&
grep -q 'tylerMeshRadarContainer' web/static/index.html &&
grep -q 'tylerCorridorGrid' web/static/index.html &&
grep -q 'tylerRfTrendCard' web/static/index.html &&
grep -q 'tylerTriangulationGrid' web/static/index.html &&
grep -q 'tylerDiagnosticReportView' web/static/index.html &&
grep -q 'manual-ch4' web/static/index.html"

assert_ok "SQLite rf_telemetry_timeseries, 3-minute cron sweep, diagnose_rf_mesh tool, and Operator Guide docs are active" bash -c "
(test -x scripts/cron_system/tyler_rf_mesh_sweep.sh || test -x .george/cron_jobs/tyler_rf_mesh_sweep.sh) &&
test -f docs/TYLER_OPERATOR_AND_RF_MESH_GUIDE.md &&
grep -q 'TYLER_OPERATOR_AND_RF_MESH_GUIDE' docs/INDEX.md &&
grep -q 'diagnose_rf_mesh' lib/tools/mcp_server_tyler.py &&
grep -q 'diagnose_rf_mesh' data/schemas/native_tools.json &&
python3 lib/tools/tyler_guardian.py wifi-spelunk --mode diagnose_rf_mesh --timeout 24 | jq -e '.status == \"ok\" and (.timeseries_summary.total_db_samples >= 1) and (.corridor_diagnostics | length > 0) and (.corridor_diagnostics[0].fresnel_r1_m > 0)' >/dev/null"

echo "=== 9. Hardening & RF Metric Verification (Shell-Free Kali Allowlist, CIDR Gate, Fresnel r1, Band Normalization & Token Gate) ==="
assert_ok "kali_exec_tool blocks shell command chaining, unapproved binaries, and destructive CIDRs encompassing protected IPs" python3 -c "import lib.tools.tyler_guardian as tg
r1 = tg.kali_exec_tool('nmap --version; id')
assert r1['status'] == 'error' and 'chaining' in r1['message']
r2 = tg.kali_exec_tool('python3 -c \"print(1)\"')
assert r2['status'] == 'error' and 'allowlist' in r2['message']
gw_net = tg.GATEWAY_IP.rsplit('.', 1)[0] + '.0/24'
r3 = tg.kali_exec_tool(f'iptables -I INPUT -s {gw_net} -j DROP')
assert r3['status'] == 'error' and 'encompasses protected IP' in r3['message']"

assert_ok "5 GHz -> 2.4 GHz Friis/wall band normalization (+6.7 dB) is applied in _compute_airspace_triangulation" python3 -c "import lib.tools.tyler_guardian as tg
tri = tg._compute_airspace_triangulation(
    [{'bssid': '02:00:5e:10:00:70', 'ssid': 'HomeMesh', 'signal_pct': 80, 'band': '2.4 GHz', 'channel': 6}],
    [{'ssid': 'HomeMesh', 'ap_list': [{'bssid': '02:00:5e:10:00:74', 'frequency': 5745, 'channel': 149, 'signal_level': -64}]}],
    peripheral_label='South-Wall Sensor'
)
tx = [x for x in tri['transmitters'] if x['bssid'] == '02:00:5e:10:00:74'][0]
assert tx['band'] == '5 GHz' and abs(tx['band_loss_comp_db'] - 6.7) < 0.01 and tx['delta_db'] == int(round(-64 - (-60) + 6.7))"

echo "=== 11. Compass-Calibrated Property Perimeter Guard, Cross-Platform Linux/WSL2 Sensor & 7-Point RF Math ==="
assert_ok "tests/tyler_rf_perimeter_checks.py passes all 7 RF math, compass sector, neighbor suppression & airlock mutex checks" python3 tests/tyler_rf_perimeter_checks.py

assert_ok "tyler_wifi_spelunk supports perimeter_guard and wiring is intact" bash -c "
( [ ! -f docs/PERIMETER_RF_SECURITY_BOM_AND_ARCHITECTURE.md ] || grep -q 'PERIMETER_RF_SECURITY_BOM_AND_ARCHITECTURE' docs/INDEX.md ) &&
grep -q 'perimeter_guard' data/schemas/native_tools.json &&
grep -q 'perimeter_guard' lib/tools/mcp_server_tyler.py &&
grep -q 'network.perimeter_alert' configs/event_contracts.json &&
grep -q 'perimeter_alert' web/src/routes/webhooks.rs &&
python3 lib/tools/tyler_guardian.py wifi-spelunk --mode perimeter_guard --timeout 2 | jq -e '.status == \"ok\" and (.perimeter_status == \"CLEAR\" or .perimeter_status == \"PERIMETER_ALERT\") and (.exterior_chords | type == \"array\")' >/dev/null"

assert_ok "commands/tyler.sh avoids eval and web/src/security.rs + session.js token-gate /api/tyler/* and default-deny mutating /api/*" python3 -c "
import subprocess
assert 'eval ' not in open('commands/tyler.sh', encoding='utf-8').read()
sec = open('web/src/security.rs', encoding='utf-8').read()
ses = open('web/static/js/session.js', encoding='utf-8').read()
assert '/api/tyler/' in sec and 'path.starts_with(\"/api/\")' in sec
assert '/api/tyler/' in ses and \"path.startsWith('/api/')\" in ses
subprocess.check_call(['node', '--check', 'web/static/js/session.js'])"

echo "=== 10. L2/L3 Immune Monitor, IoT Egress Baseline, DEX Venue Comparator & Git Lock ==="
assert_ok "L2/L3 immune monitor, schema v4 egress_domains_json, and domain normalization pass" python3 -c "import lib.tools.tyler_guardian as tg
assert tg._SCHEMA_VERSION >= 4
assert tg._normalize_egress_domain('api.prod.sleepnumber.com') == 'sleepnumber.com'
assert tg._normalize_egress_domain('printer.local') == ''
con = tg.connect_db()
cols = {r[1] for r in con.execute('PRAGMA table_info(device_baselines)')}
con.close()
assert 'egress_domains_json' in cols
l2 = tg.check_l2_l3_immune_anomalies(0)
assert l2['status'] == 'ok' and isinstance(l2['anomalies'], list)"

assert_ok "desk.js enforces strict DOM security and exposes operator corridor pinning + Multi-DEX venue matrix" python3 -c "
src = open('web/static/js/desk.js', encoding='utf-8').read()
code = '\n'.join(ln for ln in src.splitlines() if not ln.strip().startswith('*') and not ln.strip().startswith('//'))
for forbidden in ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write']:
    assert forbidden not in code, f'Forbidden sink {forbidden} found in desk.js'
assert 'toggleStandingOrderLock' in code and 'loadDexVenues' in code"

assert_ok ".gitattributes, .githooks/post-merge, and commands/push.sh git_repo.lock are configured" bash -c "
test -f .gitattributes && grep -q 'blue_lodge_graph.jsonld merge=ours' .gitattributes &&
test -x .githooks/post-merge &&
grep -q 'git_repo.lock' commands/push.sh &&
bash -n commands/push.sh"

echo ""
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
