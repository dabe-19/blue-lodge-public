#!/usr/bin/env bash
# Tests: scripts/release/export_public.py — allow-list export + leak gate (hermetic synthetic repo)
source "$(dirname "$0")/framework.sh"
test_start "export_public"

EXP="$LODGE_DIR/scripts/release/export_public.py"
S="$GEORGE_TEST_SANDBOX/export"; R="$S/src"; L="$S/lodge"
mkdir -p "$R/lib" "$R/docs" "$R/dossiers" "$R/data/training" "$R/scripts" "$L/.george/release"
git -C "$R" init -q -b main
git -C "$R" config user.email t@example.com; git -C "$R" config user.name t
cat > "$S/manifest.txt" <<'EOF'
+ lib/*
+ docs/*
+ scripts/*
- dossiers/*
- data/training/*
EOF
: > "$S/allow.txt"
echo 'echo hello' > "$R/lib/ok.sh"; chmod +x "$R/lib/ok.sh"
echo 'LODGE_DIR=/home/user/blue-lodge' > "$R/scripts/path.sh"
echo 'my holdings' > "$R/dossiers/private.md"
echo '{"chat":"private transcript"}' > "$R/data/training/t.jsonl"
echo 'Top secret notes' > "$R/NOTES.md"
git -C "$R" add -A; git -C "$R" commit -qm init
GL=(); command -v gitleaks >/dev/null 2>&1 || GL=(--skip-gitleaks)
RUN() { python3 "$EXP" --repo "$R" --manifest "$S/manifest.txt" --allow "$S/allow.txt" --lodge-dir "$L" "${GL[@]}" "$@"; }

describe "clean repo: allow-list applied, paths normalized, single commit, never pushed"
out=$(RUN --out "$S/pub1" 2>&1); rc=$?
assert_eq "$rc" "0" "clean export passes"
assert_file_exists "$S/pub1/lib/ok.sh"
assert_eq "$([ -x "$S/pub1/lib/ok.sh" ] && echo x)" "x" "exec bit preserved"
assert_eq "$([ -e "$S/pub1/dossiers/private.md" ] && echo leak || echo absent)" "absent" "excluded dir not exported"
assert_eq "$([ -e "$S/pub1/data/training/t.jsonl" ] && echo leak || echo absent)" "absent" "training data not exported"
assert_eq "$([ -e "$S/pub1/NOTES.md" ] && echo leak || echo absent)" "absent" "unlisted file not exported (allow-list)"
assert_contains "$(cat "$S/pub1/scripts/path.sh")" "/home/user/blue-lodge" "home path normalized"
assert_eq "$(git -C "$S/pub1" rev-list --count HEAD)" "1" "fresh single-commit history"
assert_eq "$(git -C "$S/pub1" remote | wc -l | tr -d ' ')" "0" "no remote configured"
assert_file_exists "$S/pub1.report.json"

describe "denylist value planted in code: gate fails, no commit, value never printed"
echo 'addr1qyfakeoperatoraddressvalue' > "$L/.george/release/denylist.txt"
echo 'W=addr1qyfakeoperatoraddressvalue' > "$R/lib/wallet.sh"; git -C "$R" add -A; git -C "$R" commit -qm leak
out=$(RUN --out "$S/pub2" 2>&1); rc=$?
assert_eq "$rc" "1" "gate fails on denylist hit"
assert_contains "$out" "DENY entry#0 lib/wallet.sh:1" "hit reported by index and location"
assert_not_contains "$out" "addr1qyfakeoperatoraddressvalue" "denylisted value never printed"
assert_eq "$([ -d "$S/pub2/.git" ] && echo committed || echo none)" "none" "failed export is not committed"

describe "secret values from .george/keys.conf are checked automatically"
: > "$L/.george/release/denylist.txt"; git -C "$R" rm -q lib/wallet.sh; git -C "$R" commit -qm unleak
echo 'BRAVE_SEARCH_API_KEY="BSAzzzzRealLookingKey123"' > "$L/.george/keys.conf"
echo 'curl -H "X-Token: BSAzzzzRealLookingKey123"' > "$R/lib/api.sh"; git -C "$R" add -A; git -C "$R" commit -qm key
out=$(RUN --out "$S/pub3" --no-commit 2>&1); rc=$?
assert_eq "$rc" "1" "gate fails on key value"
assert_not_contains "$out" "BSAzzzzRealLookingKey123" "key never printed"

describe "high-severity regex rules gate (wallet address) with reviewed allow-list"
rm -f "$L/.george/keys.conf"; git -C "$R" rm -q lib/api.sh
echo 'A="addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x"' > "$R/lib/addr.sh"
git -C "$R" add -A; git -C "$R" commit -qm addr
out=$(RUN --out "$S/pub4" --no-commit 2>&1); rc=$?
assert_eq "$rc" "1" "unreviewed wallet address fails"
assert_contains "$out" "GATE cardano_addr lib/addr.sh:1"
echo 'cardano_addr lib/addr.sh   # reviewed' > "$S/allow.txt"
out=$(RUN --out "$S/pub5" --no-commit 2>&1); rc=$?
assert_eq "$(echo "$out" | grep -c 'GATE cardano_addr')" "0" "allow-listed address no longer gates"

describe "refuses to export inside the source repo"
out=$(RUN --out "$R/public" 2>&1); rc=$?
assert_eq "$rc" "2" "refuses in-repo output"

test_end
