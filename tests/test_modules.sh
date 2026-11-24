#!/usr/bin/env bash
# tests/test_modules.sh — Integration tests for Blue Lodge Modular Heartwood & Lodge Guild
set -euo pipefail

LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LODGE_DIR
export _LODGE_TESTING=1

PASS=0
FAIL=0
assert_ok() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf "  [PASS] %s\n" "$label"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n" "$label" >&2
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Blue Lodge Modular Heartwood & Lodge Guild Test Suite ==="

TMP_GEORGE="$(mktemp -d)"
trap 'rm -rf "$TMP_GEORGE"' EXIT
export GEORGE_DIR="$TMP_GEORGE"
export MODULES_DIR="$TMP_GEORGE/modules"
export MODULE_DATA_DIR="$TMP_GEORGE/module_data"
export ECOTYPE_MANIFEST="$TMP_GEORGE/ecotype_manifest.json"
export GUILD_CACHE_DIR="$TMP_GEORGE/guild_catalog"
export MERGED_TOOLS_CACHE="$TMP_GEORGE/cache/merged_tools.json"

# Seed canonical {"reactors": [...]} to test trading-sim gating & module reactor preservation
cat > "$TMP_GEORGE/reactors.json" <<'JSON'
{
  "reactors": [
    {"id": "rx_polymarket_active", "event_type": "polymarket_market_shift", "pattern": ".*", "action": "true", "enabled": true},
    {"id": "rx_trading_crypto", "event_type": "finance_crypto_signal", "pattern": ".*", "action": "true", "enabled": true},
    {"id": "rx_sovereign_trading", "event_type": "sovereign_trading_tick", "pattern": ".*", "action": "true", "enabled": true}
  ]
}
JSON

source "$LODGE_DIR/lib/sys/modules.sh"

# 1. Manifest initialization & trading-sim disabled by default
modules_init
assert_ok "ecotype_manifest.json initialized" test -f "$ECOTYPE_MANIFEST"
assert_ok "modules_is_enabled reports trading-sim disabled" bash -c "source '$LODGE_DIR/lib/sys/modules.sh' && ! modules_is_enabled trading-sim"
assert_ok "trading-sim is disabled in manifest" test "$(jq -r '.builtins["trading-sim"].enabled' "$ECOTYPE_MANIFEST")" = "false"
assert_ok "sovereign-dex is disabled by default on fresh manifest" test "$(jq -r '.builtins["sovereign-dex"].enabled' "$ECOTYPE_MANIFEST")" = "false"
assert_ok "deep-research is enabled by default on fresh manifest" test "$(jq -r '.builtins["deep-research"].enabled' "$ECOTYPE_MANIFEST")" = "true"

# 2. Disabling trading-sim suspends its reactors while keeping canonical object & Cardano reactors intact
modules_disable trading-sim >/dev/null
assert_ok "rx_polymarket_active suspended on disable" test "$(jq -r '.reactors[] | select(.id=="rx_polymarket_active") | .enabled' "$TMP_GEORGE/reactors.json")" = "false"
assert_ok "rx_sovereign_trading untouched on trading-sim disable" test "$(jq -r '.reactors[] | select(.id=="rx_sovereign_trading") | .enabled' "$TMP_GEORGE/reactors.json")" = "true"

# 3. module_audit.py catches path traversal & dangerous AST eval()
BAD_MOD="$TMP_GEORGE/bad_mod"
mkdir -p "$BAD_MOD/tools"
cat > "$BAD_MOD/module.json" <<'JSON'
{
  "schema_version": 1,
  "id": "evil-mod",
  "name": "Evil",
  "version": "1.0.0",
  "runtime": {"venv_mode": "shared_locked", "python_packages": []},
  "provides": {"tools_schema": "../../etc/passwd"}
}
JSON
assert_ok "module_audit rejects path traversal in module.json" bash -c "! python3 '$LODGE_DIR/lib/tools/module_audit.py' '$BAD_MOD'"

cat > "$BAD_MOD/module.json" <<'JSON'
{
  "schema_version": 1,
  "id": "evil-mod",
  "name": "Evil",
  "version": "1.0.0",
  "runtime": {"venv_mode": "shared_locked", "python_packages": []},
  "provides": {"tools_dispatcher": "tools/dispatch.sh"}
}
JSON
printf '#!/usr/bin/env bash\necho ok\n' > "$BAD_MOD/tools/dispatch.sh"
printf 'x = eval("1+1")\n' > "$BAD_MOD/tools/bad.py"
assert_ok "module_audit rejects Python eval() AST node" bash -c "! python3 '$LODGE_DIR/lib/tools/module_audit.py' '$BAD_MOD'"

# 4. Valid synthetic module passes audit, merges tools, dispatches tool, injects context & strategist hints
GOOD_MOD="$TMP_GEORGE/mod-demo-mod"
mkdir -p "$GOOD_MOD/tools" "$GOOD_MOD/hooks" "$GOOD_MOD/reactors"
cat > "$GOOD_MOD/module.json" <<'JSON'
{
  "schema_version": 1,
  "id": "demo-mod",
  "name": "Demo Module",
  "version": "1.0.0",
  "category": "test",
  "tagline": "Synthetic test module",
  "runtime": {"venv_mode": "shared_locked", "python_packages": []},
  "provides": {
    "tools_schema": "tools/schemas.json",
    "tools_dispatcher": "tools/dispatch.sh",
    "tool_bundle": "+demo",
    "domain_keywords": "frobnicator gizmo",
    "context_hook": "hooks/context.sh",
    "strategist_hook": "hooks/strategist.txt",
    "event_reactors": ["reactors/demo_rx.json"]
  }
}
JSON
cat > "$GOOD_MOD/reactors/demo_rx.json" <<'JSON'
[{"id": "rx_demo_ping", "event_type": "demo.ping", "pattern": ".*", "action": "true", "debounce_secs": 1}]
JSON
cat > "$GOOD_MOD/tools/schemas.json" <<'JSON'
[
  {
    "type": "function",
    "function": {
      "name": "demo_ping",
      "description": "Returns pong",
      "parameters": {"type": "object", "properties": {}}
    }
  }
]
JSON
printf '#!/usr/bin/env bash\necho '\''{"status":"ok","pong":true}'\''\n' > "$GOOD_MOD/tools/dispatch.sh"
printf '#!/usr/bin/env bash\necho "DEMO_CONTEXT_ACTIVE"\n' > "$GOOD_MOD/hooks/context.sh"
printf 'USE_DEMO_PING_HINT\n' > "$GOOD_MOD/hooks/strategist.txt"
chmod +x "$GOOD_MOD/tools/dispatch.sh" "$GOOD_MOD/hooks/context.sh"

assert_ok "module_audit accepts valid module" python3 "$LODGE_DIR/lib/tools/module_audit.py" "$GOOD_MOD"

# Install from local git repo via modules_install
git -C "$GOOD_MOD" init -b main >/dev/null 2>&1
git -C "$GOOD_MOD" config user.name test
git -C "$GOOD_MOD" config user.email test@local
git -C "$GOOD_MOD" add -A
git -C "$GOOD_MOD" commit -m "init" >/dev/null 2>&1

assert_ok "modules_install installs local git module" modules_install "$GOOD_MOD"
assert_ok "modules_install preserves existing Heartwood reactors in canonical object" test "$(jq -r '.reactors[] | select(.id=="rx_sovereign_trading") | .enabled' "$TMP_GEORGE/reactors.json")" = "true"
assert_ok "modules_install registers module event_reactor in canonical object" test "$(jq -r '.reactors[] | select(.id=="rx_demo_ping") | .event_type' "$TMP_GEORGE/reactors.json")" = "demo.ping"
assert_ok "merged_tools.json contains demo_ping" jq -e '.[] | select(.function.name == "demo_ping")' "$MERGED_TOOLS_CACHE"
assert_ok "modules_dispatch_tool invokes demo_ping" bash -c "out=\$(source '$LODGE_DIR/lib/sys/modules.sh' && modules_dispatch_tool demo_ping '{}'); echo \"\$out\" | jq -e '.pong == true'"
assert_ok "modules_context_hooks triggers on matching keyword" bash -c "source '$LODGE_DIR/lib/sys/modules.sh' && modules_context_hooks 'inspect the frobnicator' | grep -q DEMO_CONTEXT_ACTIVE"
assert_ok "honeydew_strategist loads module strategist hint" python3 -c "import sys; sys.path.insert(0, '$LODGE_DIR/lib/tools'); import honeydew_strategist as hs; assert 'USE_DEMO_PING_HINT' in hs._load_module_strategist_hints('check my frobnicator')"

# 5. Disable & uninstall lifecycle
assert_ok "modules_disable removes tool from merged cache" bash -c "source '$LODGE_DIR/lib/sys/modules.sh' && modules_disable demo-mod >/dev/null && ! jq -e '.[] | select(.function.name == \"demo_ping\")' '$MERGED_TOOLS_CACHE'"
assert_ok "modules_uninstall cleans up module directory" bash -c "source '$LODGE_DIR/lib/sys/modules.sh' && modules_uninstall demo-mod --purge >/dev/null && test ! -d '$MODULES_DIR/demo-mod'"

# 6. XSS safety check on Heartwood modular JS (zero innerHTML/outerHTML)
assert_ok "modules.js has zero unsafe DOM sinks" bash -c "! grep -En 'innerHTML|outerHTML|document\.write|insertAdjacentHTML' '$LODGE_DIR/web/static/js/modules.js' | grep -v '^\s*[0-9]*:\s*//'"

# 7. Multi-Repo Software Phytology — Module-Aware Remediation Router
mkdir -p "$TMP_GEORGE/cache" "$MODULES_DIR/demo-mod"
cat > "$TMP_GEORGE/cache/module_tool_map.json" <<'JSON'
{
  "demo_ping": {"module_id": "demo-mod", "dispatcher": "tools/dispatch.sh"},
  "posh_market_comps_harvest": {"module_id": "poshtracker", "dispatcher": "tools/dispatch.sh"},
  "hunt_plan": {"module_id": "hunting-buddy", "dispatcher": "tools/dispatch.sh"}
}
JSON
git -C "$MODULES_DIR/demo-mod" init -b main >/dev/null 2>&1
git -C "$MODULES_DIR/demo-mod" remote add origin "http://127.0.0.1:3001/george/mod-demo-mod.git"
assert_ok "remediation_resolve_target routes module tool to mod-<id> repo" bash -c "
    source '$LODGE_DIR/lib/agents/remediation.sh'
    out=\$(remediation_resolve_target 'Tool failure: demo_ping' 'error running demo_ping')
    echo \"\$out\" | jq -e '.target_kind == \"module\" and .module_id == \"demo-mod\" and .gitea_repo == \"mod-demo-mod\" and .base_branch == \"main\"'
"
assert_ok "remediation_resolve_target routes module path stacktrace to mod-<id> repo" bash -c "
    source '$LODGE_DIR/lib/agents/remediation.sh'
    out=\$(remediation_resolve_target 'Crash in panel' 'Traceback in .george/modules/demo-mod/tools/dispatch.sh line 12')
    echo \"\$out\" | jq -e '.target_kind == \"module\" and .module_id == \"demo-mod\" and .gitea_repo == \"mod-demo-mod\"'
"
assert_ok "remediation_resolve_target routes Heartwood subsystem to blue-lodge develop" bash -c "
    source '$LODGE_DIR/lib/agents/remediation.sh'
    out=\$(remediation_resolve_target 'Tool failure: discord_send' 'webhook timeout')
    echo \"\$out\" | jq -e '.target_kind == \"heartwood\" and .gitea_repo == \"blue-lodge\" and .base_branch == \"develop\"'
"
assert_ok "Heartwood remediation denylist blocks .george/modules/* edits" bash -c "
    source '$LODGE_DIR/lib/agents/remediation.sh'
    out=\$(printf '.george/modules/demo-mod/tools/dispatch.sh\n' | remediation_scope_violations_from_list)
    echo \"\$out\" | grep -q '\.george/modules/demo-mod/tools/dispatch\.sh'
"

echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
