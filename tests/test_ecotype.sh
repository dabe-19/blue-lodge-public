#!/usr/bin/env bash
# ── tests/test_ecotype.sh: Software Phytology Ecotype & Foliage Firewall Tests ──

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/framework.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Set up bare upstream ("origin") and a node clone ("node_repo")
UPSTREAM_BARE="$TMP_ROOT/upstream.git"
NODE_REPO="$TMP_ROOT/node_repo"
UPSTREAM_WORK="$TMP_ROOT/upstream_work"

git init --bare "$UPSTREAM_BARE" >/dev/null 2>&1
git clone "$UPSTREAM_BARE" "$UPSTREAM_WORK" >/dev/null 2>&1
git -C "$UPSTREAM_WORK" config user.email "test@bluelodge.local"
git -C "$UPSTREAM_WORK" config user.name "Test Mason"
git -C "$UPSTREAM_WORK" checkout -b develop >/dev/null 2>&1
mkdir -p "$UPSTREAM_WORK/lib/sys" "$UPSTREAM_WORK/lib/ui" "$UPSTREAM_WORK/lib/agents" "$UPSTREAM_WORK/commands"
cp "$REPO_ROOT/.gitignore" "$UPSTREAM_WORK/.gitignore"
cp "$REPO_ROOT/lib/sys/ecotype.sh" "$UPSTREAM_WORK/lib/sys/ecotype.sh"
echo '#!/usr/bin/env bash' > "$UPSTREAM_WORK/lib/core_sample.sh"
git -C "$UPSTREAM_WORK" add -A
git -C "$UPSTREAM_WORK" commit -m "chore: initial species trunk" >/dev/null 2>&1
git -C "$UPSTREAM_WORK" push -u origin develop >/dev/null 2>&1

git clone -b develop "$UPSTREAM_BARE" "$NODE_REPO" >/dev/null 2>&1
git -C "$NODE_REPO" config user.email "nodeb@bluelodge.local"
git -C "$NODE_REPO" config user.name "NodeB Craftsman"

test_start "Software Phytology Ecotype Lifecycle & Foliage Firewall"

describe "ecotype_init & ecotype_status"
  out=$(LODGE_DIR="$NODE_REPO" GEORGE_DIR="$NODE_REPO/.george" bash -c "source '$NODE_REPO/lib/sys/ecotype.sh' && ecotype_init nodeb")
  cur_br=$(git -C "$NODE_REPO" branch --show-current)
  it "creates and switches to ecotype/nodeb" && {
    assert_eq "$cur_br" "ecotype/nodeb"
  }

  # Commit 1 Heartwood change and 1 Foliage (.george/cron_jobs) change on ecotype/nodeb
  echo 'export HEARTWOOD_V2=1' >> "$NODE_REPO/lib/core_sample.sh"
  mkdir -p "$NODE_REPO/.george/cron_jobs"
  echo '#!/bin/bash' > "$NODE_REPO/.george/cron_jobs/my_personal_alpha.sh"
  git -C "$NODE_REPO" add -f "$NODE_REPO/lib/core_sample.sh" "$NODE_REPO/.george/cron_jobs/my_personal_alpha.sh"
  git -C "$NODE_REPO" commit -m "feat: local heartwood + personal foliage" >/dev/null 2>&1

  st_json=$(LODGE_DIR="$NODE_REPO" GEORGE_DIR="$NODE_REPO/.george" bash -c "source '$NODE_REPO/lib/sys/ecotype.sh' && ecotype_status --json")
  it "accurately separates Heartwood vs Foliage divergence in status JSON" && {
    assert_eq "$(echo "$st_json" | jq -r '.on_ecotype')" "true"
    assert_eq "$(echo "$st_json" | jq -r '.ahead')" "1"
    assert_eq "$(echo "$st_json" | jq -r '.diverged_heartwood_count')" "1"
    assert_eq "$(echo "$st_json" | jq -r '.diverged_foliage_count')" "1"
  }

describe "ecotype_promote & Foliage Firewall"
  LODGE_DIR="$NODE_REPO" GEORGE_DIR="$NODE_REPO/.george" bash -c "source '$NODE_REPO/lib/sys/ecotype.sh' && ecotype_promote --title 'Leak test' .george/cron_jobs/my_personal_alpha.sh" >/dev/null 2>&1
  fw_rc=$?
  it "blocks promoting .george/* foliage files upstream" && {
    assert_neq "$fw_rc" "0"
  }

  cand_out=$(LODGE_DIR="$NODE_REPO" GEORGE_DIR="$NODE_REPO/.george" bash -c "source '$NODE_REPO/lib/sys/ecotype.sh' && ecotype_promote --title 'Clean core upgrade' --push-origin lib/core_sample.sh")
  cand_br=$(echo "$cand_out" | tail -n1)
  leaked=$(git -C "$NODE_REPO" ls-tree -r --name-only "$cand_br" | grep '^\.george/' || true)
  has_hw=$(git -C "$NODE_REPO" show "${cand_br}:lib/core_sample.sh" | grep -c 'HEARTWOOD_V2' || true)
  it "creates a clean candidate branch off develop with Heartwood changes and zero Foliage leaks" && {
    assert_eq "$leaked" ""
    assert_eq "$has_hw" "1"
  }

describe "ecotype_sync (Sandboxed Pollination)"
  # Push a non-conflicting upstream commit to origin/develop
  echo 'export UPSTREAM_FEATURE=1' > "$UPSTREAM_WORK/lib/upstream_new.sh"
  git -C "$UPSTREAM_WORK" add -A
  git -C "$UPSTREAM_WORK" commit -m "feat: upstream species improvement" >/dev/null 2>&1
  git -C "$UPSTREAM_WORK" push origin develop >/dev/null 2>&1

  LODGE_DIR="$NODE_REPO" GEORGE_DIR="$NODE_REPO/.george" bash -c "source '$NODE_REPO/lib/sys/ecotype.sh' && ecotype_sync origin develop" >/dev/null 2>&1
  sync_rc=$?
  it "pollinates clean upstream commits into ecotype/nodeb via sandbox worktree" && {
    assert_eq "$sync_rc" "0"
    assert_file_exists "$NODE_REPO/lib/upstream_new.sh"
    assert_file_exists "$NODE_REPO/.george/cron_jobs/my_personal_alpha.sh"
  }

  # Push a conflicting commit to origin/develop and verify live workspace is untouched
  echo 'export HEARTWOOD_V2=CONFLICT_UPSTREAM' > "$UPSTREAM_WORK/lib/core_sample.sh"
  git -C "$UPSTREAM_WORK" add -A
  git -C "$UPSTREAM_WORK" commit -m "feat: conflicting upstream edit" >/dev/null 2>&1
  git -C "$UPSTREAM_WORK" push origin develop >/dev/null 2>&1

  LODGE_DIR="$NODE_REPO" GEORGE_DIR="$NODE_REPO/.george" bash -c "source '$NODE_REPO/lib/sys/ecotype.sh' && ecotype_sync origin develop" >/dev/null 2>&1
  conflict_rc=$?
  dirty_after=$(git -C "$NODE_REPO" status --porcelain)
  it "aborts cleanly inside sandbox on merge conflict without dirtying live workspace" && {
    assert_eq "$conflict_rc" "2"
    assert_eq "$dirty_after" ""
  }

test_end
