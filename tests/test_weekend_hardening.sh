#!/usr/bin/env bash
# ── Tests: Weekend Audit P0/P1 Hardening Suite ───────────────────────
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/tests/framework.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/george-weekend-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

export LODGE_DIR="$REPO_ROOT"
export GEORGE_DIR="$TEST_TMP/.george"
mkdir -p "$GEORGE_DIR/state" "$GEORGE_DIR/configs" "$GEORGE_DIR/discord_sessions" "$GEORGE_DIR/tools"

describe "P0.1: Recall ID-stable reindex & chunk index"

it "creates idx_chunks_source_section and preserves chunk IDs without pre-sourcing scenes.sh" && {
    (
        export RECALL_DB="$TEST_TMP/recall.db"
        export RECALL_MTIME_FILE="$TEST_TMP/.recall_mtimes"
        export GEORGE_TEST_MODE=0
        export SCENE_HOOKS_ENABLED=1
        export LODGE_DIR="$TEST_TMP/repo"
        mkdir -p "$LODGE_DIR/docs" "$LODGE_DIR/lib/memory"
        ln -sf "$REPO_ROOT/data" "$LODGE_DIR/data"
        ln -sf "$REPO_ROOT/lib/ui" "$LODGE_DIR/lib/ui"
        ln -sf "$REPO_ROOT/lib/memory/scenes.sh" "$LODGE_DIR/lib/memory/scenes.sh"
        printf '# Ref\n\n## Alpha\nAlpha body content with several meaningful words.\n' > "$LODGE_DIR/docs/RECALL_INDEX.md"
        printf '# Journal\n\n## 2026-11-21 08:00 — reflection\nHunting wind northwest over Marinette county ridge.\n' > "$LODGE_DIR/journal.md"
        source "$REPO_ROOT/lib/memory/recall.sh"
        # Intentionally do NOT source scenes.sh first
        recall_reindex >/dev/null 2>&1
        idx_exists=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_chunks_source_section';")
        id1=$(sqlite3 "$RECALL_DB" "SELECT id FROM chunks WHERE source='journal' AND section LIKE '2026-11-21%';")
        tag_cnt=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scene_tags;")
        # Append a new journal section and reindex
        printf '\n## 2026-11-22 09:00 — reflection\nHandsaw creek thermal drainage analysis complete.\n' >> "$LODGE_DIR/journal.md"
        sed -i 's/^journal=.*/journal=0/' "$RECALL_MTIME_FILE"
        recall_reindex >/dev/null 2>&1
        id2=$(sqlite3 "$RECALL_DB" "SELECT id FROM chunks WHERE source='journal' AND section LIKE '2026-11-21%';")
        [ "$idx_exists" -ge 1 ] && [ -n "$id1" ] && [ "$id1" = "$id2" ] && [ "${tag_cnt:-0}" -gt 0 ]
    )
    assert_ok $?
}

describe "P0.2: discord_user_resolve safety & discord_send_file active channel routing"

it "blocks 'here' and middle-substring matches from resolving to therealcheese_test" && {
    (
        export _DISCORD_USER_RESOLVE_RETRY=1
        source "$REPO_ROOT/lib/comms/social.sh"
        DISCORD_USERS_DB="$TEST_TMP/users.db"
        DISCORD_CHANNELS_DB="$TEST_TMP/channels.db"
        discord_user_add "therealcheese_test" "100000000000000002" "TheRealCheese" >/dev/null 2>&1
        discord_user_add "operator_user" "100000000000000001" "Dave" >/dev/null 2>&1
        r_here=$(discord_user_resolve "here" 2>/dev/null || true)
        r_mid=$(discord_user_resolve "cheese" 2>/dev/null || true)
        r_exact=$(discord_user_resolve "therealcheese_test" 2>/dev/null || true)
        [ -z "$r_here" ] && [ -z "$r_mid" ] && [ "$r_exact" = "100000000000000002" ]
    )
    assert_ok $?
}

it "routes discord_send_file(target='here') to active channel and auto-splits >1950-char captions" && {
    (
        export DISCORD_USERS_DB="$TEST_TMP/users2.db"
        export DISCORD_CHANNELS_DB="$TEST_TMP/channels2.db"
        export _DISCORD_IN_SESSION=1
        export _DISCORD_CURRENT_CHANNEL="200000000000000001"
        export _DISCORD_CURRENT_CHANNEL_NAME="blue-lodge"
        export _DISCORD_CURRENT_AUTHOR="operator_user"
        export _DISCORD_CURRENT_AUTHOR_ID="100000000000000001"
        export DISCORD_RUN_OUTBOX="$TEST_TMP/outbox.jsonl"
        source "$REPO_ROOT/lib/comms/social.sh"
        source "$REPO_ROOT/lib/comms/discord_bridge.sh"
        source "$REPO_ROOT/lib/tools/native_tools.sh"
        discord_user_add "therealcheese_test" "100000000000000002" "TheRealCheese" >/dev/null 2>&1
        api_get_key() { echo "mock-token"; }
        api_require_key() { echo "mock-token"; }
        curl() {
            echo "CURL:$*" >> "$TEST_TMP/upload_calls.log"
            echo '{"id":"555000111","content":"ok"}'
            echo "200"
        }
        discord_send() {
            echo "FOLLOWUP:$1:${#2}" >> "$TEST_TMP/upload_calls.log"
            return 0
        }
        dummy="$TEST_TMP/map.png"
        printf '\x89PNG\r\n\x1a\nMOCKDATA' > "$dummy"
        long_msg=$(python3 -c 'print("\n".join(f"Line {i}: Detailed scent plume corridor analysis for parcel 32-3752." for i in range(45)))')
        args=$(jq -nc --arg f "$dummy" --arg m "$long_msg" '{"target":"here","file_path":$f,"message":$m}')
        out=$(native_tools_dispatch "c1" "discord_send_file" "$args" "$TEST_TMP")
        grep -q "channels/200000000000000001/messages" "$TEST_TMP/upload_calls.log" &&
        ! grep -q "100000000000000002" "$TEST_TMP/upload_calls.log" &&
        grep -q "FOLLOWUP:200000000000000001:" "$TEST_TMP/upload_calls.log"
    )
    assert_ok $?
}

describe "P0.3: Discord Markdown Table Auto-Resolver & Fence-Aware Auto-Splitter"

it "converts 2-col and wide 3-col Markdown tables cleanly while preserving fenced code blocks" && {
    python3 - <<'PY'
import sys
sys.path.insert(0, "lib/tools")
import discord_format as df

sample = """Summary:
| Item | Detail |
|---|---|
| **Problem** | Resting NIGHT buy corridor sits 2.06σ below spot. |
| **Recommendation** | Supersede with fresh 72h corridor. |

| Stand | Wind | Verdict | Notes |
|---|---|---|---|
| **SW Edge** | NW 10 mph | **Primary** | Pushes scent off property toward Ranch Road corridor |
| **Confluence** | SE 5 mph | Fallback | Holds thermal heat late afternoon |

```markdown
| Keep | Untouched |
|---|---|
| raw | table |
```
"""
res = df.format_discord_tables(sample)
assert "- **Problem:** Resting NIGHT buy corridor" in res, res
assert "- **Recommendation:** Supersede with fresh 72h corridor." in res, res
assert "**SW Edge**" in res and "**Wind:** NW 10 mph" in res, res
assert "| Keep | Untouched |" in res, "Fenced code block was altered!"
assert "| **Problem** |" not in res, "Raw pipe table was not converted!"

# Compact plain 3-col matrix -> aligned monospace code block
compact = "| Day | Low | High |\n|---|---|---|\n| Sat | 22F | 36F |\n| Sun | 18F | 29F |\n"
c_res = df.format_discord_tables(compact)
assert "```text" in c_res and "Sat" in c_res, c_res

# Fence-aware splitting preserves ALL content and balances fences
big_code = "Intro line\n```python\n" + "\n".join(f"x_{i} = {i} * 123456789" for i in range(150)) + "\n```\nOutro line\n"
chunks = df.split_discord_message(big_code, limit=1990)
assert len(chunks) >= 2
assert all(len(c) <= 1990 for c in chunks)
assert all(c.count("```") % 2 == 0 for c in chunks), "Unbalanced code fence across split!"
assert "Intro line" in chunks[0] and "Outro line" in chunks[-1]
PY
    assert_ok $?
}

describe "P1.1: Honeydew Strategist Context Extraction"

it "strips static Discord boilerplate so conversation history & artifact pantry reach the strategist" && {
    python3 - <<'PY'
import sys
sys.path.insert(0, "lib/tools")
import honeydew_strategist as hs

raw = (
    "<conversation_history>\n"
    "[Author Authorization: @operator_user is the Sovereign Operator.]\n\n"
    "[Recent Channel Messages]\n"
    "operator_user: Please redraw the Marinette parcel scent map v3.2\n"
    "George: Rendered monday_layout_v3_2.png\n\n"
    "[Discord context: you are in channel #blue-lodge. " + ("PROTOCOL BOILERPLATE " * 100) + "]\n\n"
    "[Channel Artifact Pantry (.george/artifacts/channel_200000000000000001):\n"
    "  outputs/monday_layout_v3_2.png\n"
    "  scripts/scent_map.py]\n"
    "</conversation_history>"
)
ctx = hs._extract_strategist_context(raw, max_chars=2200)
assert "monday_layout_v3_2.png" in ctx, ctx
assert "Marinette parcel scent map" in ctx, ctx
assert "PROTOCOL BOILERPLATE" not in ctx, ctx
PY
    assert_ok $?
}

describe "P1.2: artifact_publish integrity check & persistent channel archive"

it "archives valid PNG + script to channel pantry and rejects corrupt PNG headers" && {
    (
        export _DISCORD_IN_SESSION=0
        export _DISCORD_CURRENT_CHANNEL="200000000000000001"
        source "$REPO_ROOT/lib/tools/native_tools.sh"
        api_get_key() { echo ""; }
        good_png="$TEST_TMP/good_map.png"
        bad_png="$TEST_TMP/corrupt.png"
        script_py="$TEST_TMP/gen_map.py"
        printf '\x89PNG\r\n\x1a\nVALIDPNGPAYLOAD' > "$good_png"
        printf 'NOT_A_PNG_HEADER' > "$bad_png"
        printf 'print("map")\n' > "$script_py"

        r_bad=$(native_tools_dispatch "c_bad" "artifact_publish" "$(jq -nc --arg f "$bad_png" '{file_path:$f}')" "$TEST_TMP")
        echo "$r_bad" | grep -q "integrity check failed" || exit 1

        r_good=$(native_tools_dispatch "c_good" "artifact_publish" "$(jq -nc --arg f "$good_png" --arg s "$script_py" '{file_path:$f, script_path:$s, label:"v4"}')" "$TEST_TMP")
        echo "$r_good" | grep -q "Archived locally to:" &&
        [ -f "$GEORGE_DIR/artifacts/channel_200000000000000001/outputs/good_map.png" ] &&
        [ -f "$GEORGE_DIR/artifacts/channel_200000000000000001/outputs/v4_good_map.png" ] &&
        [ -f "$GEORGE_DIR/artifacts/channel_200000000000000001/scripts/gen_map.py" ] &&
        [ -s "$GEORGE_DIR/artifacts/channel_200000000000000001/manifest.jsonl" ]
    )
    assert_ok $?
}

describe "P1.3: Sovereign .venv Supply-Chain Guard (venv_pkg_guard.py)"

it "blocks typosquats and unsafe URLs as Tier C" && {
    python3 - <<'PY'
import sys
sys.path.insert(0, "lib/tools")
import venv_pkg_guard as g

r1 = g.audit_package("matplotlb")
assert r1["tier"] == "C" and "TYPOSQUAT" in r1["reason"], r1

r2 = g.audit_package("https://evil.example/pkg.whl")
assert r2["tier"] == "C" and "unsafe package specifier" in r2["reason"], r2

r3 = g.audit_package("git+https://github.com/evil/repo.git")
assert r3["tier"] == "C", r3
PY
    assert_ok $?
}

describe "P1.4: Craftsman Tool Forger (tool_forge.py)"

it "rejects unsafe AST patterns and forges + runs verified .venv Python tools" && {
    python3 - <<'PY'
import json, os, subprocess, sys
env = os.environ.copy()
env["GEORGE_DIR"] = os.environ["GEORGE_DIR"]

# 1. Unsafe eval() must be rejected
bad = subprocess.run(
    [sys.executable, "lib/tools/tool_forge.py", "forge",
     "--name", "bad_eval", "--lang", "python", "--description", "unsafe",
     "--code", "eval('1+1')"],
    capture_output=True, text=True, env=env
)
assert bad.returncode != 0 and "REJECTED_SAFETY_AUDIT" in bad.stdout, bad.stdout

# 2. Reading keys.conf must be rejected
bad2 = subprocess.run(
    [sys.executable, "lib/tools/tool_forge.py", "forge",
     "--name", "bad_keys", "--lang", "python", "--description", "steal",
     "--code", "print(open('.george/keys.conf').read())"],
    capture_output=True, text=True, env=env
)
assert bad2.returncode != 0 and "REJECTED_SAFETY_AUDIT" in bad2.stdout, bad2.stdout

# 3. Safe GIS polygon area tool using .venv shapely passes smoke test and runs!
good_code = """import json, sys
from shapely.geometry import box
args = json.loads(sys.stdin.read() or "{}")
w = float(args.get("w", 10))
h = float(args.get("h", 4))
print(json.dumps({"area": box(0, 0, w, h).area}))
"""
good = subprocess.run(
    [sys.executable, "lib/tools/tool_forge.py", "forge",
     "--name", "parcel_box_area", "--lang", "python",
     "--description", "Compute rectangular parcel area via shapely",
     "--code", good_code, "--smoke-args", '{"w": 5, "h": 8}'],
    capture_output=True, text=True, env=env
)
assert good.returncode == 0 and "FORGED_AND_VERIFIED" in good.stdout, good.stdout + good.stderr

run = subprocess.run(
    [sys.executable, "lib/tools/tool_forge.py", "run",
     "--name", "parcel_box_area", "--args", '{"w": 12, "h": 10}'],
    capture_output=True, text=True, env=env
)
assert run.returncode == 0, run.stdout + run.stderr
outer = json.loads(run.stdout)
inner = json.loads(outer["stdout"])
assert outer["status"] == "OK" and inner["area"] == 120.0, outer
PY
    assert_ok $?
}

describe "P0.4: Multi-Bot Mention Stripping Hygiene"

it "preserves mid-sentence bot name and prevents duplicate @PeerBot@PeerBot tags" && {
    (
        source "$REPO_ROOT/lib/comms/social.sh"
        DISCORD_USERS_DB="$TEST_TMP/mention_users.db"
        discord_user_add "PeerBot" "100000000000000003" "PeerBot" >/dev/null 2>&1
        bot_id="999888777"
        LODGE_NODE_CALLSIGN="george"
        _node_cap="${LODGE_NODE_CALLSIGN^}"

        clean_msg() {
            local m="$1"
            m=$(printf '%s' "$m" \
                | sed -E "s/^[[:space:]]*<@!?${bot_id}>[,:]?[[:space:]]*//; s/^[[:space:]]*@(${LODGE_NODE_CALLSIGN:-george}|lodge|swarm)\b[,:]?[[:space:]]*//I; s/<@!?${bot_id}>/${_node_cap}/g; s/<@&[0-9]+>//g" \
                | sed 's/^[[:space:]]*//')
            for _muid in $( printf '%s' "$m" | grep -oE '<@!?[0-9]+>' | tr -cd '0-9\n' | sort -u ); do
                _mname=$(sqlite3 "$DISCORD_USERS_DB" "SELECT username FROM users WHERE user_id = '$_muid' LIMIT 1;" 2>/dev/null || true)
                if [ -n "$_mname" ]; then
                    local _mname_esc; _mname_esc=$(printf '%s' "$_mname" | sed 's/[.[\*^$()+?{|}\\]/\\&/g')
                    m=$(printf '%s' "$m" | sed -E "s/@?${_mname_esc}[[:space:]]*<@!?${_muid}>/@${_mname} (<@${_muid}>)/Ig; s/(^|[^(])<@!?${_muid}>/\1@${_mname} (<@${_muid}>)/g")
                fi
            done
            printf '%s' "$m"
        }

        r1=$(clean_msg "Brother <@999888777>, let's square the stone")
        r2=$(clean_msg "<@999888777>, Re-cut the map please")
        r3=$(clean_msg "George and PeerBot <@100000000000000003>, check this out")
        [ "$r1" = "Brother George, let's square the stone" ] &&
        [ "$r2" = "Re-cut the map please" ] &&
        [ "$r3" = "George and @PeerBot (<@100000000000000003>), check this out" ]
    )
    assert_ok $?
}

test_end
