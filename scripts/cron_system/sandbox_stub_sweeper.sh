#!/bin/bash
# INTERVAL: 21600
# DESC: Prunes empty .sandboxes/research_* stub dirs (no files, >10min old) so research worktrees stop accumulating as litter. Empty-only + age-guarded + research_*-scoped: can never touch live state or an in-progress sandbox.
# SCOPE: system
# CREATED: 2026-11-15
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SBX="$ROOT/.sandboxes"
[ -d "$SBX" ] || { echo "[$(date -Is)] sandbox_stub_sweeper: no .sandboxes dir; nothing to do"; exit 0; }
PRUNED=0
while IFS= read -r -d '' d; do
    rm -rf "$d" 2>/dev/null && PRUNED=$((PRUNED+1))
done < <(find "$SBX" -maxdepth 1 -type d -name 'research_*' -empty -mmin +10 -print0 2>/dev/null)
echo "[$(date -Is)] sandbox_stub_sweeper: pruned_empty_research_stubs=$PRUNED"
