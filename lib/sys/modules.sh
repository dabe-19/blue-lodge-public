#!/usr/bin/env bash
# ── lib/sys/modules.sh: Blue Lodge Sovereign Module Manager ("Lodge Guild") ──
# Manages installable external Git modules (.george/modules/<id>/) and built-in
# first-party domain modules declaratively via .george/ecotype_manifest.json.
# Supports Hybrid 3-Mode Runtimes: shared_locked, isolated_venv, docker_sidecar.

[ -n "${_LIB_MODULES_LOADED:-}" ] && return 0; _LIB_MODULES_LOADED=1

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
MODULES_DIR="${MODULES_DIR:-$GEORGE_DIR/modules}"
MODULE_DATA_DIR="${MODULE_DATA_DIR:-$GEORGE_DIR/module_data}"
ECOTYPE_MANIFEST="${ECOTYPE_MANIFEST:-$GEORGE_DIR/ecotype_manifest.json}"
GUILD_CACHE_DIR="${GUILD_CACHE_DIR:-$GEORGE_DIR/guild_catalog}"
MERGED_TOOLS_CACHE="${MERGED_TOOLS_CACHE:-$GEORGE_DIR/cache/merged_tools.json}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
declare -f ui_ok &>/dev/null   || ui_ok()   { printf "[✓] %s\n" "$*"; }
declare -f ui_info &>/dev/null || ui_info() { printf "[i] %s\n" "$*"; }
declare -f ui_warn &>/dev/null || ui_warn() { printf "[!] %s\n" "$*" >&2; }
declare -f ui_err &>/dev/null  || ui_err()  { printf "[✗] %s\n" "$*" >&2; }

_modules_valid_id() {
    [[ "${1:-}" =~ ^[a-z0-9][a-z0-9_-]{1,48}$ ]]
}

_modules_sanitize_url() {
    printf '%s' "$1" | sed -E 's|(https?://)[^/@]+@|\1|g'
}

_modules_git() {
    git -c safe.directory='*' "$@"
}

_modules_github_org_base() {
    local ourl=""
    ourl=$(_modules_git -C "$LODGE_DIR" remote get-url origin 2>/dev/null || true)
    if [[ "$ourl" =~ ^git@github\.com:([^/]+)/blue-lodge(\.git)?$ ]]; then
        printf 'https://github.com/%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$ourl" =~ ^https?://([^/@]+@)?github\.com/([^/]+)/blue-lodge(\.git)?$ ]]; then
        printf 'https://github.com/%s' "${BASH_REMATCH[2]}"
        return 0
    fi
    printf 'https://github.com/dabe-19'
}

_modules_guild_repo_url() {
    if [ -n "${LODGE_GUILD_REPO_URL:-}" ]; then
        printf '%s' "$LODGE_GUILD_REPO_URL"
        return 0
    fi
    # Derive authenticated local Gitea base from blue-lodge's gitea remote when present
    local gurl=""
    gurl=$(_modules_git -C "$LODGE_DIR" remote get-url gitea 2>/dev/null || true)
    if [[ "$gurl" =~ ^(https?://[^/]+/[^/]+)/blue-lodge(\.git)?$ ]]; then
        printf '%s/blue-lodge-guild.git' "${BASH_REMATCH[1]}"
        return 0
    fi
    printf '%s/blue-lodge-guild.git' "$(_modules_github_org_base)"
}

_modules_gitea_base_url() {
    local gurl=""
    gurl=$(_modules_git -C "$LODGE_DIR" remote get-url gitea 2>/dev/null || true)
    if [[ "$gurl" =~ ^(https?://[^/]+/[^/]+)/blue-lodge(\.git)?$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    printf 'http://127.0.0.1:3088/george'
}

# Resolve a repo URL, injecting local Gitea auth credentials if pointing to 127.0.0.1:3088 or gitea/<repo>
_modules_resolve_git_url() {
    local raw="$1"
    if [[ "$raw" == gitea/* ]]; then
        printf '%s/%s.git' "$(_modules_gitea_base_url)" "${raw#gitea/}"
        return 0
    fi
    if [[ "$raw" =~ ^http://127\.0\.0\.1:3088/george/(.+)$ ]]; then
        printf '%s/%s' "$(_modules_gitea_base_url)" "${BASH_REMATCH[1]}"
        return 0
    fi
    printf '%s' "$raw"
}

_modules_github_https_url() {
    local raw="$1"
    local url="$raw"
    if [[ "$raw" =~ ^git@github\.com:(.+)$ ]]; then
        url="https://github.com/${BASH_REMATCH[1]}"
    fi
    local tok=""
    if [ -f "$GEORGE_DIR/configs/keys.conf" ]; then
        tok=$(grep -m1 '^GITHUB_TOKEN=' "$GEORGE_DIR/configs/keys.conf" 2>/dev/null | cut -d= -f2- | tr -d "\"'[:space:]")
    fi
    [ -z "$tok" ] && tok="${GITHUB_TOKEN:-}"
    if [ -n "$tok" ] && [[ "$url" =~ ^https://github\.com/(.+)$ ]]; then
        printf 'https://x-access-token:%s@github.com/%s' "$tok" "${BASH_REMATCH[1]}"
    else
        printf '%s' "$url"
    fi
}

modules_init() {
    mkdir -p "$MODULES_DIR" "$MODULE_DATA_DIR" "$GEORGE_DIR/cache" "$GEORGE_DIR/security" 2>/dev/null || true
    if [ ! -f "$ECOTYPE_MANIFEST" ]; then
        cat > "$ECOTYPE_MANIFEST" <<'JSON'
{
  "schema_version": 1,
  "builtins": {
    "deep-research": { "enabled": true, "pane": "research", "name": "Deep Research", "category": "research", "tagline": "Autonomous multi-domain SearXNG research dossiers & social synthesis." },
    "sovereign-dex": { "enabled": false, "pane": "dex-desk", "name": "Cardano DEX", "category": "crypto", "tagline": "Live Minswap V2 desk, walk-forward backtests, and Dolos chain ops." },
    "sovereign-fund": { "enabled": false, "pane": "finance", "name": "Fund & Lending", "category": "crypto", "tagline": "P2P microloans, live Polymarket surveillance, and tax/staking provenance." },
    "trading-sim": { "enabled": false, "pane": "trading-sim", "name": "Trading Simulator", "category": "crypto", "tagline": "Opt-in paper trading & Polymarket sandbox (disabled by default to save CPU)." },
    "sdr-radio-lab": { "enabled": false, "pane": "sdr", "name": "SDR Radio Lab", "category": "hardware", "tagline": "Local P25 trunked radio scanner & Whisper/Gemma audio decoder." },
    "the-tyler": { "enabled": false, "pane": "tyler", "name": "The Tyler", "category": "security", "tagline": "Kali Linux LAN immune defense, RF perimeter guard, and credential threat OSINT." },
    "smart-home-cast": { "enabled": false, "pane": "google-cast", "name": "Smart Home Cast", "category": "household", "tagline": "Google Home CastV2 speaker broadcasts & neural TTS." }
  },
  "modules": {}
}
JSON
    fi
}

modules_catalog_sync() {
    modules_init
    # Best-effort mirror GitHub -> local Gitea first so local Gitea forge stays fresh
    # (skipped when LODGE_GUILD_REPO_URL is explicitly pinned, e.g. in hermetic tests, or MODULES_SKIP_GITEA_MIRROR=1)
    if [ -z "${LODGE_GUILD_REPO_URL:-}" ] && [ "${MODULES_SKIP_GITEA_MIRROR:-0}" != "1" ] && \
       [ -x "$LODGE_DIR/scripts/infra/sync_guild_gitea.sh" ]; then
        bash "$LODGE_DIR/scripts/infra/sync_guild_gitea.sh" >/dev/null 2>&1 || true
    fi

    local candidates=()
    local primary
    primary="$(_modules_guild_repo_url)"
    candidates+=("$primary")
    local gh_base
    gh_base="$(_modules_github_org_base)"
    local gh_https
    gh_https="$(_modules_github_https_url "${gh_base}/blue-lodge-guild.git")"
    [ "$gh_https" != "$primary" ] && candidates+=("$gh_https")
    if [[ "$gh_base" =~ ^https://github\.com/(.+)$ ]]; then
        candidates+=("git@github.com:${BASH_REMATCH[1]}/blue-lodge-guild.git")
    fi

    local url
    for url in "${candidates[@]}"; do
        [ -z "$url" ] && continue
        if [ -d "$GUILD_CACHE_DIR/.git" ]; then
            _modules_git -C "$GUILD_CACHE_DIR" remote set-url origin "$url" 2>/dev/null || true
            if GIT_TERMINAL_PROMPT=0 _modules_git -C "$GUILD_CACHE_DIR" fetch --quiet origin 2>/dev/null; then
                _modules_git -C "$GUILD_CACHE_DIR" reset --hard --quiet origin/main 2>/dev/null || \
                    _modules_git -C "$GUILD_CACHE_DIR" reset --hard --quiet origin/master 2>/dev/null || true
                [ -f "$GUILD_CACHE_DIR/catalog.json" ] && return 0
            fi
        else
            rm -rf "$GUILD_CACHE_DIR" 2>/dev/null || true
            if GIT_TERMINAL_PROMPT=0 _modules_git clone --quiet --depth 1 "$url" "$GUILD_CACHE_DIR" 2>/dev/null; then
                [ -f "$GUILD_CACHE_DIR/catalog.json" ] && return 0
            fi
        fi
    done
    [ -f "$GUILD_CACHE_DIR/catalog.json" ]
}

_modules_catalog_json() {
    if [ -f "$GUILD_CACHE_DIR/catalog.json" ]; then
        cat "$GUILD_CACHE_DIR/catalog.json"
    else
        echo '{"schema_version":1,"modules":[]}'
    fi
}

modules_is_enabled() {
    local id="$1"
    modules_init
    _modules_valid_id "$id" || return 1
    local en
    en=$(jq -r --arg id "$id" '
        if .modules[$id] != null then (.modules[$id].enabled // false)
        elif .builtins[$id] != null then (.builtins[$id].enabled // false)
        else false end
    ' "$ECOTYPE_MANIFEST" 2>/dev/null || echo "false")
    [ "$en" = "true" ]
}

modules_list() {
    local as_json=0
    [ "${1:-}" = "--json" ] && as_json=1
    modules_init
    local cat_file="$GUILD_CACHE_DIR/catalog.json"
    local tmp_cat='{"modules":[]}'
    [ -f "$cat_file" ] && tmp_cat=$(cat "$cat_file")

    local gitea_repos_json="[]"
    local gbase
    gbase="$(_modules_gitea_base_url)"
    if [[ "$gbase" =~ ^(https?://)([^:@]+):([^@]+)@([^/]+)/([^/]+)$ ]]; then
        local _gproto="${BASH_REMATCH[1]}" _gtok="${BASH_REMATCH[3]}" _ghost="${BASH_REMATCH[4]}" _gowner="${BASH_REMATCH[5]}"
        gitea_repos_json=$(curl -sf --connect-timeout 1 --max-time 2 \
            -H "Authorization: token ${_gtok}" \
            "${_gproto}${_ghost}/api/v1/user/repos?limit=50" 2>/dev/null || echo "[]")
        echo "$gitea_repos_json" | jq -e 'type == "array"' >/dev/null 2>&1 || gitea_repos_json="[]"
    fi

    local combined
    combined=$(python3 - "$ECOTYPE_MANIFEST" "$MODULES_DIR" "$tmp_cat" "$gitea_repos_json" <<'PY'
import json, os, re, sys

manifest_path, mods_dir, cat_raw, gitea_raw = sys.argv[1:5]
with open(manifest_path, "r", encoding="utf-8") as f:
    man = json.load(f)
try:
    cat = json.loads(cat_raw)
except Exception:
    cat = {"modules": []}
try:
    gitea_repos = json.loads(gitea_raw)
    if not isinstance(gitea_repos, list):
        gitea_repos = []
except Exception:
    gitea_repos = []

def sanitize_url(u):
    return re.sub(r"(https?://)[^/@]+@", r"\1", u or "")

def classify_scope(entry, source_hint=""):
    vis = (entry.get("visibility") or "").lower()
    if vis in ("public-github", "private-github", "local-gitea", "builtin"):
        return vis
    if source_hint == "builtin":
        return "builtin"
    if source_hint == "local-gitea":
        return "local-gitea"
    gh = (entry.get("github_repo") or "").strip()
    repo = (entry.get("repo") or "").strip()
    if vis == "private":
        return "private-github" if gh or "github.com" in repo else "local-gitea"
    if gh or "github.com" in repo:
        return "public-github"
    return "local-gitea"

items = {}

# 1. Built-in first-party modules
for mid, meta in (man.get("builtins") or {}).items():
    items[mid] = {
        "id": mid,
        "name": meta.get("name", mid),
        "tagline": meta.get("tagline", ""),
        "category": meta.get("category", "core"),
        "version": "core",
        "source": "builtin",
        "origin_scope": "builtin",
        "installed": True,
        "enabled": bool(meta.get("enabled", False)),
        "pane": meta.get("pane", mid),
        "venv_mode": "builtin",
        "hardware_badges": meta.get("hardware_badges", []),
        "has_ui": True,
    }

# 2. Guild catalog entries (Public or Private GitHub)
catalog_ids = set()
for entry in cat.get("modules") or []:
    mid = entry.get("id")
    if not mid:
        continue
    catalog_ids.add(mid)
    cur = items.get(mid, {})
    scope = classify_scope(entry, "guild")
    items[mid] = {
        "id": mid,
        "name": entry.get("name", cur.get("name", mid)),
        "tagline": entry.get("tagline", cur.get("tagline", "")),
        "category": entry.get("category", cur.get("category", "community")),
        "version": entry.get("version", "0.1.0"),
        "source": "guild",
        "origin_scope": scope,
        "repo": sanitize_url(entry.get("repo", "")),
        "github_repo": entry.get("github_repo", ""),
        "commit": entry.get("commit", ""),
        "installed": os.path.isfile(os.path.join(mods_dir, mid, "module.json")),
        "enabled": bool((man.get("modules") or {}).get(mid, {}).get("enabled", False)),
        "venv_mode": entry.get("venv_mode", "shared_locked"),
        "hardware_badges": entry.get("hardware_badges", []),
        "has_ui": bool(entry.get("has_ui", True)),
        "sidecar_port": entry.get("sidecar_port"),
    }

# 2b. Discover local-only Gitea mod-* repositories not in the public Guild catalog
for gr in gitea_repos:
    if not isinstance(gr, dict):
        continue
    rname = (gr.get("name") or "").strip()
    if not rname.startswith("mod-"):
        continue
    mid = rname[4:].lower()
    if not mid or mid in catalog_ids or mid in items:
        continue
    items[mid] = {
        "id": mid,
        "name": mid.replace("-", " ").title(),
        "tagline": (gr.get("description") or "Local sovereign module hosted exclusively on your node's Gitea forge.").strip(),
        "category": "local",
        "version": "local",
        "source": "local-gitea",
        "origin_scope": "local-gitea",
        "repo": f"gitea/{rname}",
        "commit": "",
        "installed": os.path.isfile(os.path.join(mods_dir, mid, "module.json")),
        "enabled": bool((man.get("modules") or {}).get(mid, {}).get("enabled", False)),
        "venv_mode": "shared_locked",
        "hardware_badges": ["local-gitea-only"],
        "has_ui": True,
    }

# 3. Installed external modules (merge local module.json truth)
for mid, mstate in (man.get("modules") or {}).items():
    mdir = os.path.join(mods_dir, mid)
    mj_path = os.path.join(mdir, "module.json")
    mj = {}
    if os.path.isfile(mj_path):
        try:
            mj = json.load(open(mj_path, "r", encoding="utf-8"))
        except Exception:
            pass
    cur = items.get(mid, {})
    ui = (mj.get("provides") or {}).get("ui") or {}
    rt = mj.get("runtime") or {}
    wf_ids = []
    for wdir in (os.path.join(mdir, "workflows"), os.path.join(os.path.dirname(mods_dir), "module_data", mid, "workflows")):
        if os.path.isdir(wdir):
            for wf in sorted(os.listdir(wdir)):
                if wf.endswith(".loop.json"):
                    lid = wf[:-len(".loop.json")]
                    if lid not in wf_ids:
                        wf_ids.append(lid)
    src_val = mstate.get("source", cur.get("source", "git"))
    scope_val = cur.get("origin_scope") or classify_scope(mstate, src_val)
    cat_ver = cur.get("version", "") if mid in catalog_ids else ""
    cat_commit = cur.get("commit", "") if mid in catalog_ids else ""
    inst_ver = mj.get("version", cur.get("version", "0.1.0"))
    inst_commit = mstate.get("commit", "")
    # Prefer actual git HEAD inside .george/modules/<id> when available
    head_file = os.path.join(mdir, ".git", "HEAD")
    if os.path.isfile(head_file):
        try:
            import subprocess
            ghead = subprocess.check_output(["git", "-c", "safe.directory=*", "-C", mdir, "rev-parse", "HEAD"], stderr=subprocess.DEVNULL, text=True).strip()
            if ghead:
                inst_commit = ghead
        except Exception:
            pass
    update_avail = False
    if os.path.isfile(mj_path) and cat_commit:
        if inst_commit and not (inst_commit.startswith(cat_commit) or cat_commit.startswith(inst_commit)):
            update_avail = True
        elif cat_ver and inst_ver and cat_ver != inst_ver:
            update_avail = True
    items[mid] = {
        **cur,
        "id": mid,
        "name": mj.get("name", cur.get("name", mid)),
        "tagline": mj.get("tagline", cur.get("tagline", "")),
        "category": mj.get("category", cur.get("category", "community")),
        "version": inst_ver,
        "installed_version": inst_ver,
        "catalog_version": cat_ver or inst_ver,
        "source": src_val,
        "origin_scope": scope_val,
        "repo": sanitize_url(mstate.get("repo", cur.get("repo", ""))),
        "commit": inst_commit or cat_commit,
        "installed_commit": inst_commit,
        "catalog_commit": cat_commit,
        "update_available": update_avail,
        "installed": os.path.isfile(mj_path),
        "enabled": bool(mstate.get("enabled", False)),
        "venv_mode": rt.get("venv_mode", cur.get("venv_mode", "shared_locked")),
        "hardware_badges": mj.get("hardware_badges", cur.get("hardware_badges", [])),
        "has_ui": bool(ui.get("js") or ui.get("panel_json")),
        "ui": ui,
        "sidecar_port": rt.get("sidecar_port", cur.get("sidecar_port")),
        "tool_bundle": (mj.get("provides") or {}).get("tool_bundle", ""),
        "workflows": wf_ids,
        "workflows_count": len(wf_ids),
    }

out = sorted(items.values(), key=lambda x: (x["source"] == "builtin", not x["enabled"], x["id"]))
print(json.dumps({"status": "ok", "modules": out}, indent=2))
PY
)
    if [ "$as_json" -eq 1 ]; then
        printf '%s\n' "$combined"
        return 0
    fi
    ui_section "Blue Lodge Modules (Lodge Guild)"
    printf '%s' "$combined" | jq -r '.modules[] | "  [\(if .enabled then "ON " elif .installed then "OFF" else "CAT" end)] \(.id) (\(.version)\(if .update_available then " -> " + .catalog_version + " UPDATE" else "" end), \(.source)/\(.venv_mode)) — \(.tagline)"'
}

modules_rebuild_tools_cache() {
    modules_init
    python3 - "$LODGE_DIR/data/schemas/native_tools.json" "$ECOTYPE_MANIFEST" "$MODULES_DIR" "$MERGED_TOOLS_CACHE" <<'PY'
import json, os, sys

core_path, man_path, mods_dir, out_path = sys.argv[1:5]
with open(core_path, "r", encoding="utf-8") as f:
    tools = json.load(f)
seen = {t.get("function", {}).get("name") for t in tools}

with open(man_path, "r", encoding="utf-8") as f:
    man = json.load(f)

tool_map = {}
for mid, state in (man.get("modules") or {}).items():
    if not state.get("enabled"):
        continue
    mj_path = os.path.join(mods_dir, mid, "module.json")
    if not os.path.isfile(mj_path):
        continue
    mj = json.load(open(mj_path, "r", encoding="utf-8"))
    ts = (mj.get("provides") or {}).get("tools_schema")
    if not ts:
        continue
    ts_path = os.path.join(mods_dir, mid, ts)
    if not os.path.isfile(ts_path):
        continue
    try:
        mtools = json.load(open(ts_path, "r", encoding="utf-8"))
        for t in mtools:
            tname = (t.get("function") or {}).get("name")
            if not tname:
                continue
            tool_map[tname] = {
                "module_id": mid,
                "dispatcher": os.path.join(mods_dir, mid, (mj.get("provides") or {}).get("tools_dispatcher", "tools/dispatch.sh")),
                "keywords": (mj.get("provides") or {}).get("domain_keywords", ""),
                "bundle": (mj.get("provides") or {}).get("tool_bundle", f"+{mid}"),
                "core_tools": (mj.get("provides") or {}).get("core_tools", []),
            }
            if tname not in seen:
                tools.append(t)
                seen.add(tname)
    except Exception:
        continue

os.makedirs(os.path.dirname(out_path), exist_ok=True)
tmp = out_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(tools, f)
os.replace(tmp, out_path)

map_path = os.path.join(os.path.dirname(out_path), "module_tool_map.json")
tmp2 = map_path + ".tmp"
with open(tmp2, "w", encoding="utf-8") as f:
    json.dump(tool_map, f, indent=2)
os.replace(tmp2, map_path)
PY
}

_modules_sync_reactors_and_crons() {
    local id="$1" action="$2" # enable | disable
    local mdir="$MODULES_DIR/$id"
    local rfile="$GEORGE_DIR/reactors.json"

    # Handle built-in module reactors & cron jobs cleanly inside canonical {"reactors": [...]} and cron.conf!
    case "$id" in
        trading-sim|sovereign-dex|sovereign-fund|sdr-radio-lab|the-tyler|smart-home-cast)
            if [ -f "$rfile" ]; then
                python3 - "$rfile" "$id" "$action" <<'PY'
import json, os, sys
rfile, mid, action = sys.argv[1:4]
en = (action == "enable")
rx_map = {
    "trading-sim": {"rx_polymarket_active", "rx_trading_poly", "rx_trading_crypto", "rx_trading_alert"},
    "sovereign-dex": {"rx_order_placed_log", "rx_order_expired_log", "rx_order_reclaim_log"},
    "sovereign-fund": {"rx_microloan_due", "rx_fund_audit"},
    "sdr-radio-lab": {"rx_sdr_dispatch", "rx_sdr_alert", "rx_p25_transcript"},
    "the-tyler": {"rx_tyler_immune"},
    "smart-home-cast": {"rx_google_cast_alert"},
}
target_ids = rx_map.get(mid, set())
if not target_ids:
    sys.exit(0)
try:
    raw = json.load(open(rfile, "r", encoding="utf-8"))
except Exception:
    sys.exit(0)
if isinstance(raw, dict) and isinstance(raw.get("reactors"), list):
    items = raw["reactors"]
    out = raw
elif isinstance(raw, list):
    items = raw
    out = {"reactors": items}
else:
    sys.exit(0)
changed = False
for r in items:
    if isinstance(r, dict) and r.get("id") in target_ids:
        r["enabled"] = en
        changed = True
if changed:
    tmp = f"{rfile}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
    os.replace(tmp, rfile)
PY
            fi
            # Also suspend/resume built-in domain cron jobs in .george/configs/cron.conf
            local cconf="$GEORGE_DIR/configs/cron.conf"
            if [ -f "$cconf" ]; then
                local _jobs=()
                case "$id" in
                    sovereign-dex)  _jobs=(cardano_order_poll cardano_pair_ticker pool_recorder pool_backfill wallet_poll) ;;
                    sovereign-fund) _jobs=(sovereign_trading_loop api_coinbase_ada api_coinbase_btc) ;;
                    sdr-radio-lab)  _jobs=(sdr_ingest sdr_transcribe) ;;
                    the-tyler)      _jobs=(tyler_immune_patrol tyler_rf_mesh_sweep) ;;
                esac
                local _val=0; [ "$action" = "enable" ] && _val=1
                for _jb in "${_jobs[@]}"; do
                    local _key="CRON_JOB_${_jb^^}_ENABLED"
                    if grep -q "^${_key}=" "$cconf" 2>/dev/null; then
                        sed -i "s|^${_key}=.*|${_key}=${_val}|" "$cconf"
                    elif [ "$action" = "disable" ]; then
                        printf '%s=%s\n' "$_key" "$_val" >> "$cconf"
                    fi
                done
            fi
            return 0
            ;;
    esac

    [ -f "$mdir/module.json" ] || return 0

    # Sync module event_reactors into canonical {"reactors": [...]} in .george/reactors.json
    local rx_files
    rx_files=$(jq -r '.provides.event_reactors[]? // empty' "$mdir/module.json" 2>/dev/null || true)
    if [ -n "$rx_files" ] && [ -f "$rfile" ]; then
        python3 - "$rfile" "$mdir" "$id" "$action" $rx_files <<'PY'
import json, os, sys, time
rfile, mdir, mid, action = sys.argv[1:5]
rx_rel_list = sys.argv[5:]
try:
    raw = json.load(open(rfile, "r", encoding="utf-8"))
except Exception:
    raw = {"reactors": []}

# Preserve canonical {"reactors": [...]} envelope (NEVER wipe existing Heartwood/Cardano reactors!)
if isinstance(raw, dict) and isinstance(raw.get("reactors"), list):
    envelope = raw
    cur = raw["reactors"]
elif isinstance(raw, list):
    cur = raw
    envelope = {"reactors": cur}
else:
    cur = []
    envelope = {"reactors": cur}

if action == "disable":
    for r in cur:
        if isinstance(r, dict) and r.get("module_id") == mid:
            r["enabled"] = False
else:
    by_id = {r.get("id"): r for r in cur if isinstance(r, dict) and r.get("id")}
    for rel in rx_rel_list:
        p = os.path.join(mdir, rel)
        if not os.path.isfile(p):
            continue
        entries = json.load(open(p, "r", encoding="utf-8"))
        if isinstance(entries, dict):
            entries = entries.get("reactors", [entries])
        for e in entries:
            if not isinstance(e, dict):
                continue
            norm = dict(e)
            # Normalize legacy module keys (topic/command) -> canonical Event Bus keys (event_type/action)
            if "topic" in norm and not norm.get("event_type"):
                norm["event_type"] = norm.pop("topic")
            if "command" in norm and not norm.get("action"):
                norm["action"] = norm.pop("command")
            norm.setdefault("pattern", ".*")
            norm.setdefault("debounce_secs", 5)
            norm.setdefault("created_at", int(time.time()))
            norm["module_id"] = mid
            norm["enabled"] = True
            if isinstance(norm.get("action"), str):
                norm["action"] = norm["action"].replace("${MODULE_DIR}", mdir)
            rid = norm.get("id")
            if rid in by_id:
                by_id[rid].update(norm)
            else:
                cur.append(norm)
                if rid:
                    by_id[rid] = norm

tmp = f"{rfile}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(envelope, f, indent=2)
os.replace(tmp, rfile)
PY
    fi

    # Sync module cron_templates into .george/cron_jobs/mod_<id>_*.sh
    local cron_files
    cron_files=$(jq -r '.provides.cron_templates[]? // empty' "$mdir/module.json" 2>/dev/null || true)
    if [ -n "$cron_files" ]; then
        mkdir -p "$GEORGE_DIR/cron_jobs" 2>/dev/null || true
        while IFS= read -r cf; do
            [ -z "$cf" ] && continue
            local src="$mdir/$cf"
            local base; base=$(basename "$cf")
            local dst="$GEORGE_DIR/cron_jobs/mod_${id}_${base}"
            if [ "$action" = "enable" ] && [ -f "$src" ]; then
                sed "s|\${MODULE_DIR}|$mdir|g" "$src" > "$dst"
                chmod +x "$dst"
            elif [ "$action" = "disable" ] && [ -f "$dst" ]; then
                rm -f "$dst"
            fi
        done <<< "$cron_files"
    fi
}

modules_install() {
    local target="$1"
    shift || true
    local ref="" approve=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --ref) ref="$2"; shift 2 ;;
            --approve) approve=1; shift ;;
            *) shift ;;
        esac
    done
    modules_init
    [ -z "$target" ] && { ui_err "Usage: /app install <module_id|git_url> [--ref <sha>] [--approve]"; return 1; }

    local mod_id="" repo_url="" github_url="" pinned_sha="" source_kind="git"
    if _modules_valid_id "$target"; then
        mod_id="$target"
        modules_catalog_sync >/dev/null 2>&1 || true
        local entry=""
        if [ -f "$GUILD_CACHE_DIR/catalog.json" ]; then
            entry=$(jq -c --arg id "$mod_id" '.modules[] | select(.id == $id)' "$GUILD_CACHE_DIR/catalog.json" 2>/dev/null | head -n 1)
        fi
        if [ -n "$entry" ]; then
            repo_url=$(echo "$entry" | jq -r '.repo // empty')
            github_url=$(echo "$entry" | jq -r '.github_repo // empty')
            pinned_sha=$(echo "$entry" | jq -r '.commit // empty')
            source_kind="guild"
        else
            # Fallback to direct gitea repo name mod-<id>
            repo_url="gitea/mod-${mod_id}"
            source_kind="local-gitea"
        fi
    else
        repo_url="$target"
        mod_id=$(basename "${target%.git}" | sed 's/^mod-//' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
        [[ "$repo_url" == gitea/* ]] && source_kind="local-gitea"
    fi
    _modules_valid_id "$mod_id" || { ui_err "Could not derive valid module id from '$target'"; return 1; }
    [ -n "$ref" ] && pinned_sha="$ref"

    local clone_candidates=()
    local resolved_url; resolved_url="$(_modules_resolve_git_url "$repo_url")"
    [ -n "$resolved_url" ] && clone_candidates+=("$resolved_url")
    if [ -n "$github_url" ]; then
        local gh_https; gh_https="$(_modules_github_https_url "$github_url")"
        clone_candidates+=("$gh_https")
        [ "$github_url" != "$gh_https" ] && clone_candidates+=("$github_url")
    elif [[ "$repo_url" == *"github.com"* ]]; then
        local gh_https; gh_https="$(_modules_github_https_url "$repo_url")"
        [ "$gh_https" != "$resolved_url" ] && clone_candidates+=("$gh_https")
    fi

    local dest="$MODULES_DIR/$mod_id"
    local stage="${dest}.staging.$$"
    rm -rf "$stage"

    local used_url=""
    local cand
    for cand in "${clone_candidates[@]}"; do
        [ -z "$cand" ] && continue
        ui_info "Fetching module '$mod_id' from $(_modules_sanitize_url "$cand")..."
        if GIT_TERMINAL_PROMPT=0 git clone --quiet "$cand" "$stage" 2>/dev/null; then
            used_url="$(_modules_sanitize_url "$cand")"
            break
        fi
        rm -rf "$stage"
    done
    if [ -z "$used_url" ] || [ ! -d "$stage" ]; then
        rm -rf "$stage"
        ui_err "Failed to clone module repository for '$mod_id'."
        return 1
    fi
    repo_url="$used_url"
    if [ -n "$pinned_sha" ]; then
        # Attach a proper local branch (avoiding detached HEAD) so remediation & module authors
        # never collide with detached-HEAD git failures while staying pinned to the exact SHA/tag.
        if ! git -C "$stage" checkout --quiet -B main "$pinned_sha" 2>/dev/null; then
            rm -rf "$stage"
            ui_err "Failed to checkout pinned commit/ref '$pinned_sha' for $mod_id"
            return 1
        fi
    fi
    local actual_sha; actual_sha=$(git -C "$stage" rev-parse HEAD 2>/dev/null || echo "")

    # Mandatory static security & manifest audit
    local audit_out
    audit_out=$(python3 "$LODGE_DIR/lib/tools/module_audit.py" "$stage" 2>&1)
    if [ $? -ne 0 ]; then
        rm -rf "$stage"
        ui_err "Module '$mod_id' FAILED security/manifest audit:"
        printf '%s\n' "$audit_out" >&2
        return 1
    fi

    # Install declared Python packages via supply-chain guard per runtime.venv_mode
    local venv_mode pkgs_list
    venv_mode=$(jq -r '.runtime.venv_mode // "shared_locked"' "$stage/module.json" 2>/dev/null)
    mapfile -t pkgs_arr < <(jq -r '.runtime.python_packages[]? // empty' "$stage/module.json" 2>/dev/null)
    if [ "${#pkgs_arr[@]}" -gt 0 ] && [ "$venv_mode" != "docker_sidecar" ] && [ "$venv_mode" != "none" ]; then
        local g_flags=()
        [ "$approve" -eq 1 ] && g_flags+=(--approve)
        if [ "$venv_mode" = "isolated_venv" ]; then
            g_flags+=(--venv "$dest/.venv" --create-venv)
        fi
        ui_info "Verifying & installing ${#pkgs_arr[@]} wheel(s) via venv_pkg_guard ($venv_mode)..."
        local pkg_out
        pkg_out=$(python3 "$LODGE_DIR/lib/tools/venv_pkg_guard.py" install "${g_flags[@]}" "${pkgs_arr[@]}" 2>&1)
        if [ $? -ne 0 ]; then
            rm -rf "$stage"
            ui_err "Dependency supply-chain gate blocked installation of '$mod_id':"
            printf '%s\n' "$pkg_out" >&2
            return 1
        fi
    fi

    rm -rf "$dest"
    mv "$stage" "$dest"
    mkdir -p "$MODULE_DATA_DIR/$mod_id" 2>/dev/null || true

    local _tmp="${ECOTYPE_MANIFEST}.tmp.$$"
    jq --arg id "$mod_id" --arg repo "$repo_url" --arg sha "$actual_sha" --arg src "$source_kind" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .modules[$id] = {
            repo: $repo,
            commit: $sha,
            source: $src,
            enabled: true,
            installed_at: $ts
        }
    ' "$ECOTYPE_MANIFEST" > "$_tmp" && mv -f "$_tmp" "$ECOTYPE_MANIFEST"

    modules_enable "$mod_id"
    ui_ok "Installed and enabled module '$mod_id' @ ${actual_sha:0:8}"
}

modules_update() {
    local target="${1:-}"
    shift || true
    local approve_flag="--approve" force_update=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-approve) approve_flag=""; shift ;;
            --approve) approve_flag="--approve"; shift ;;
            --force|-f) force_update=1; shift ;;
            *) shift ;;
        esac
    done

    modules_init
    if [ -z "$target" ]; then
        ui_err "Usage: /app update <module_id|--all> [--force]"
        return 1
    fi

    modules_catalog_sync >/dev/null 2>&1 || true

    if [ "$target" = "--all" ] || [ "$target" = "all" ]; then
        local updatable
        updatable=$(modules_list --json | jq -r '.modules[] | select(.installed == true and .update_available == true) | .id' 2>/dev/null || true)
        if [ -z "$updatable" ]; then
            ui_ok "All installed Guild modules are already up to date."
            return 0
        fi
        local mid rc=0
        while IFS= read -r mid; do
            [ -z "$mid" ] && continue
            modules_update "$mid" ${approve_flag:+$approve_flag} $([ "$force_update" -eq 1 ] && echo "--force") || rc=1
        done <<< "$updatable"
        return "$rc"
    fi

    _modules_valid_id "$target" || { ui_err "Invalid module id: $target"; return 1; }
    if [ "$(jq -r --arg id "$target" 'if .builtins[$id] != null then "1" else "0" end' "$ECOTYPE_MANIFEST")" = "1" ]; then
        ui_info "Module '$target' is a Heartwood built-in — update via '/ecotype sync'."
        return 0
    fi
    if [ ! -f "$MODULES_DIR/$target/module.json" ]; then
        ui_err "Module '$target' is not installed. Run: /app install $target"
        return 1
    fi

    # Protect module authors from losing uncommitted local work during catalog updates
    if [ "$force_update" -ne 1 ] && [ -d "$MODULES_DIR/$target/.git" ]; then
        local _mod_dirty
        _mod_dirty=$(git -C "$MODULES_DIR/$target" -c safe.directory='*' status --porcelain --untracked-files=no 2>/dev/null || true)
        if [ -n "$_mod_dirty" ]; then
            ui_err "Module '$target' has uncommitted local changes; refusing destructive update. Commit/stash or re-run with '--force'."
            return 1
        fi
    fi

    # Snapshot any extra developer remotes (e.g. github / gitea) so they survive the atomic swap
    local _saved_remotes=""
    if [ -d "$MODULES_DIR/$target/.git" ]; then
        _saved_remotes=$(git -C "$MODULES_DIR/$target" -c safe.directory='*' remote -v 2>/dev/null | awk '$3=="(fetch)" && $1!="origin" {print $1 "\t" $2}' || true)
    fi

    local was_enabled="false"
    was_enabled=$(jq -r --arg id "$target" '.modules[$id].enabled // false' "$ECOTYPE_MANIFEST" 2>/dev/null || echo "false")
    local old_ver
    old_ver=$(jq -r '.version // "unknown"' "$MODULES_DIR/$target/module.json" 2>/dev/null || echo "unknown")

    ui_info "Updating module '$target' (currently v${old_ver}; user data in .george/module_data/${target}/ is preserved)..."
    if ! modules_install "$target" ${approve_flag:+$approve_flag}; then
        return 1
    fi
    if [ -n "$_saved_remotes" ] && [ -d "$MODULES_DIR/$target/.git" ]; then
        local _rn _ru
        while IFS=$'\t' read -r _rn _ru; do
            [ -z "$_rn" ] || [ -z "$_ru" ] && continue
            git -C "$MODULES_DIR/$target" -c safe.directory='*' remote add "$_rn" "$_ru" 2>/dev/null || true
        done <<< "$_saved_remotes"
    fi
    if [ "$was_enabled" != "true" ]; then
        modules_disable "$target" >/dev/null 2>&1 || true
    fi
    local new_ver
    new_ver=$(jq -r '.version // "unknown"' "$MODULES_DIR/$target/module.json" 2>/dev/null || echo "unknown")
    ui_ok "Updated module '$target': v${old_ver} -> v${new_ver}"
}

modules_enable() {
    local id="$1"
    modules_init
    _modules_valid_id "$id" || { ui_err "Invalid module id: $id"; return 1; }
    local is_builtin
    is_builtin=$(jq -r --arg id "$id" 'if .builtins[$id] != null then "1" else "0" end' "$ECOTYPE_MANIFEST" 2>/dev/null)
    local _tmp="${ECOTYPE_MANIFEST}.tmp.$$"
    if [ "$is_builtin" = "1" ]; then
        jq --arg id "$id" '.builtins[$id].enabled = true' "$ECOTYPE_MANIFEST" > "$_tmp" && mv -f "$_tmp" "$ECOTYPE_MANIFEST"
    elif [ -f "$MODULES_DIR/$id/module.json" ]; then
        jq --arg id "$id" '.modules[$id].enabled = true' "$ECOTYPE_MANIFEST" > "$_tmp" && mv -f "$_tmp" "$ECOTYPE_MANIFEST"
    else
        ui_err "Module '$id' is not installed. Run: /app install $id"
        return 1
    fi
    _modules_sync_reactors_and_crons "$id" "enable"
    modules_rebuild_tools_cache
    ui_ok "Enabled module '$id'"
}

modules_disable() {
    local id="$1"
    modules_init
    _modules_valid_id "$id" || { ui_err "Invalid module id: $id"; return 1; }
    local is_builtin
    is_builtin=$(jq -r --arg id "$id" 'if .builtins[$id] != null then "1" else "0" end' "$ECOTYPE_MANIFEST" 2>/dev/null)
    local _tmp="${ECOTYPE_MANIFEST}.tmp.$$"
    if [ "$is_builtin" = "1" ]; then
        jq --arg id "$id" '.builtins[$id].enabled = false' "$ECOTYPE_MANIFEST" > "$_tmp" && mv -f "$_tmp" "$ECOTYPE_MANIFEST"
    elif [ -d "$MODULES_DIR/$id" ]; then
        jq --arg id "$id" '.modules[$id].enabled = false' "$ECOTYPE_MANIFEST" > "$_tmp" && mv -f "$_tmp" "$ECOTYPE_MANIFEST"
    else
        ui_err "Module '$id' not found."
        return 1
    fi
    _modules_sync_reactors_and_crons "$id" "disable"
    modules_rebuild_tools_cache
    ui_ok "Disabled module '$id'"
}

modules_uninstall() {
    local id="$1" purge="${2:-}"
    modules_init
    _modules_valid_id "$id" || { ui_err "Invalid module id: $id"; return 1; }
    if [ "$(jq -r --arg id "$id" 'if .builtins[$id] != null then "1" else "0" end' "$ECOTYPE_MANIFEST")" = "1" ]; then
        ui_warn "Module '$id' is a built-in module; disabling instead of deleting."
        modules_disable "$id"
        return $?
    fi
    modules_disable "$id" >/dev/null 2>&1 || true
    rm -rf "${MODULES_DIR:?}/$id"
    [ "$purge" = "--purge" ] && rm -rf "${MODULE_DATA_DIR:?}/$id"
    local _tmp="${ECOTYPE_MANIFEST}.tmp.$$"
    jq --arg id "$id" 'del(.modules[$id])' "$ECOTYPE_MANIFEST" > "$_tmp" && mv -f "$_tmp" "$ECOTYPE_MANIFEST"
    modules_rebuild_tools_cache
    ui_ok "Uninstalled module '$id'"
}

modules_health() {
    local id="$1"
    _modules_valid_id "$id" || { echo '{"status":"error","reason":"invalid_id"}'; return 1; }
    local mdir="$MODULES_DIR/$id"
    if [ -f "$mdir/module.json" ]; then
        local hc; hc=$(jq -r '.healthcheck // empty' "$mdir/module.json" 2>/dev/null)
        if [ -n "$hc" ] && [ -f "$mdir/$hc" ]; then
            MODULE_DIR="$mdir" MODULE_DATA_DIR="$MODULE_DATA_DIR/$id" bash "$mdir/$hc"
            return $?
        fi
        echo '{"status":"ok","installed":true}'
        return 0
    fi
    echo '{"status":"ok","builtin":true}'
}

modules_dispatch_tool() {
    local tool_name="$1" args_json="$2" workdir="${3:-$PWD}"
    local map_path="$GEORGE_DIR/cache/module_tool_map.json"
    [ -f "$map_path" ] || modules_rebuild_tools_cache >/dev/null 2>&1
    [ -f "$map_path" ] || return 127
    local info
    info=$(jq -c --arg t "$tool_name" '.[$t] // empty' "$map_path" 2>/dev/null)
    [ -n "$info" ] || return 127
    local mid disp
    mid=$(echo "$info" | jq -r '.module_id')
    disp=$(echo "$info" | jq -r '.dispatcher')
    [ -f "$disp" ] || return 127
    MODULE_ID="$mid" MODULE_DIR="$MODULES_DIR/$mid" MODULE_DATA_DIR="$MODULE_DATA_DIR/$mid" \
        LODGE_DIR="$LODGE_DIR" GEORGE_DIR="$GEORGE_DIR" \
        bash "$disp" "$tool_name" "$args_json" "$workdir"
}

modules_context_summary() {
    modules_init
    python3 - "$ECOTYPE_MANIFEST" "$MODULES_DIR" <<'PY'
import json, os, sys
man = json.load(open(sys.argv[1], "r", encoding="utf-8"))
mods_dir = sys.argv[2]
lines = []
for mid, st in (man.get("modules") or {}).items():
    if not st.get("enabled"):
        continue
    mj_p = os.path.join(mods_dir, mid, "module.json")
    if os.path.isfile(mj_p):
        mj = json.load(open(mj_p, "r", encoding="utf-8"))
        b = (mj.get("provides") or {}).get("tool_bundle", f"+{mid}")
        lines.append(f"- Module [{mid}] ({b}): {mj.get('tagline','')}")
if lines:
    print("\n".join(lines))
PY
}

modules_context_hooks() {
    local goal="$1"
    modules_init
    local goal_low="${goal,,}"
    local mid
    for mid in $(jq -r '.modules | to_entries[] | select(.value.enabled == true) | .key' "$ECOTYPE_MANIFEST" 2>/dev/null); do
        local mdir="$MODULES_DIR/$mid"
        [ -f "$mdir/module.json" ] || continue
        local hook kws
        hook=$(jq -r '.provides.context_hook // empty' "$mdir/module.json" 2>/dev/null)
        kws=$(jq -r '.provides.domain_keywords // empty' "$mdir/module.json" 2>/dev/null)
        [ -n "$hook" ] && [ -f "$mdir/$hook" ] || continue
        local matched=0 w
        for w in $kws; do
            if [[ "$goal_low" == *"${w,,}"* ]]; then
                matched=1; break
            fi
        done
        if [ "$matched" -eq 1 ]; then
            MODULE_ID="$mid" MODULE_DIR="$mdir" MODULE_DATA_DIR="$MODULE_DATA_DIR/$mid" \
                LODGE_DIR="$LODGE_DIR" GEORGE_DIR="$GEORGE_DIR" \
                bash "$mdir/$hook" "$goal" 2>/dev/null || true
        fi
    done
}

# Scaffold a brand-new standalone Guild module repo from templates/mod-starter-template
# Usage: modules_scaffold <id> [--name "Display Name"] [--category "tools"] [--prefix "short"] [--dest <dir>] [--enable]
modules_scaffold() {
    local mod_id="${1:-}"
    shift || true
    local mod_name="" mod_cat="community" mod_prefix="" custom_dest="" auto_enable=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --name)     mod_name="${2:-}"; shift 2 ;;
            --category) mod_cat="${2:-community}"; shift 2 ;;
            --prefix)   mod_prefix="${2:-}"; shift 2 ;;
            --dest)     custom_dest="${2:-}"; shift 2 ;;
            --enable)   auto_enable=1; shift ;;
            *) shift ;;
        esac
    done

    modules_init
    if ! _modules_valid_id "$mod_id"; then
        ui_err "Usage: /app scaffold <module_id> [--name \"Display Name\"] [--category <cat>] [--prefix <short>] [--dest <dir>] [--enable]"
        return 1
    fi
    local tmpl_dir="$LODGE_DIR/templates/mod-starter-template"
    if [ ! -d "$tmpl_dir" ]; then
        ui_err "Starter template missing at $tmpl_dir"
        return 1
    fi

    [ -z "$mod_name" ] && mod_name=$(python3 -c 'import sys; print(" ".join(w.capitalize() for w in sys.argv[1].replace("_","-").split("-")))' "$mod_id")
    [ -z "$mod_prefix" ] && mod_prefix=$(printf '%s' "$mod_id" | tr '-' '_' | tr -cd 'a-z0-9_' | cut -c1-16)
    local dest="${custom_dest:-$MODULES_DIR/$mod_id}"
    if [ -e "$dest" ]; then
        ui_err "Destination already exists: $dest"
        return 1
    fi

    mkdir -p "$dest"
    cp -R "$tmpl_dir"/. "$dest"/
    python3 - "$dest" "$mod_id" "$mod_name" "$mod_prefix" "$mod_cat" <<'PY'
import os, sys
root, mid, mname, mpref, mcat = sys.argv[1:6]
reps = {
    "__MOD_ID__": mid,
    "__MOD_NAME__": mname,
    "__MOD_PREFIX__": mpref,
    "__MOD_CATEGORY__": mcat,
}
for cur, _, files in os.walk(root):
    for fn in files:
        p = os.path.join(cur, fn)
        try:
            txt = open(p, "r", encoding="utf-8").read()
        except Exception:
            continue
        for k, v in reps.items():
            txt = txt.replace(k, v)
        with open(p, "w", encoding="utf-8") as f:
            f.write(txt)
PY
    chmod +x "$dest"/tools/*.sh "$dest"/tools/*.py "$dest"/hooks/*.sh 2>/dev/null || true

    # Audit generated module immediately before registering
    local audit_out
    if ! audit_out=$(python3 "$LODGE_DIR/lib/tools/module_audit.py" "$dest" 2>&1); then
        ui_err "Scaffolded module failed audit:"
        printf '%s\n' "$audit_out" >&2
        rm -rf "$dest"
        return 1
    fi

    if command -v git >/dev/null 2>&1; then
        git -C "$dest" init -b main --quiet 2>/dev/null || git -C "$dest" init --quiet 2>/dev/null
        git -C "$dest" add -A >/dev/null 2>&1
        git -C "$dest" -c user.name="Blue Lodge Builder" -c user.email="builder@blue-lodge.local" \
            commit -m "feat(init): scaffold ${mod_id} from mod-starter-template (ALP v1)" --quiet >/dev/null 2>&1 || true
    fi

    if [ -z "$custom_dest" ]; then
        local sha; sha=$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo "")
        mkdir -p "$MODULE_DATA_DIR/$mod_id" 2>/dev/null || true
        local _tmp="${ECOTYPE_MANIFEST}.tmp.$$"
        jq --arg id "$mod_id" --arg sha "$sha" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson en "$([ "$auto_enable" -eq 1 ] && echo true || echo false)" '
            .modules[$id] = {
                repo: ("gitea/mod-" + $id),
                commit: $sha,
                source: "local-gitea",
                enabled: $en,
                installed_at: $ts
            }
        ' "$ECOTYPE_MANIFEST" > "$_tmp" && mv -f "$_tmp" "$ECOTYPE_MANIFEST"
        [ "$auto_enable" -eq 1 ] && modules_enable "$mod_id"
    fi

    ui_ok "Scaffolded audited Guild module '$mod_id' at $dest"
    ui_dim "Next: customize tools/cli.py, workflows/sample_briefing.loop.json, and ui/panel.js — then enable via '/app enable $mod_id'."
}
