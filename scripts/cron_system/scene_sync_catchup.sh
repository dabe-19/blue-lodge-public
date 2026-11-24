#!/bin/bash
# INTERVAL: 900
# ENABLED: 1
# DESC: Scene sync catch-up — the safety net for the journal->chunks->scenes
# SCOPE: system
#       materialization chain. Fully decoupled from the react loop, so it catches
#       up even if a task loop dies mid-run. Runs scene_sync journal (hash-gated,
#       incremental chunk diff -> id-stable, no destructive id-churn) + the
#       Strategy C lazy path (scene_rescue_cold: coldest-first, budgeted,
#       per-chunk drip via the lazy scene_ensure_for_chunk primitive) + a
#       threshold-gated scene_seed_bulk OVERFLOW net (full bulk sweep only while
#       the pending backlog >= SCENE_COLD_BACKLOG_SWEEP, default 100 — first run,
#       big reindex, or cron downtime) + scene_prune_orphans. Steady-state
#       materialization is the lazy drip; the bulk sweep is the overflow net.
#       Idempotent: a no-op when journal.md is byte-identical to the last sync.
#       Complements the in-loop hook (strategy A, real-time) and the daily
#       journal_decay cron (tier decay only).
# CREATED: 2026-11-15

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

command -v sqlite3 >/dev/null 2>&1 || exit 0
[ -f "$LODGE_DIR/lib/memory/scenes.sh" ] || exit 0

# recall.sh: supplies the markdown chunker (_recall_chunk_markdown) scene_sync reuses.
source "$LODGE_DIR/lib/memory/recall.sh" 2>/dev/null
# scenes.sh: supplies scene_sync, scene_seed_bulk, scene_prune_orphans, scene_stats.
source "$LODGE_DIR/lib/memory/scenes.sh" 2>/dev/null || exit 0
# Self-heal: create recall.db + scene store if they don't exist yet
# (idempotent — all schema DDL is IF NOT EXISTS).
declare -f scene_store_init >/dev/null 2>&1 && scene_store_init >/dev/null 2>&1

LOG="${CRON_JOB_LOG:-/dev/null}"

# A: reconcile journal chunks against journal.md (hash-gated, id-stable).
_sync="$(scene_sync journal)"
# C (lazy path, steady-state): drip-warm the coldest never-queried chunks one
# at a time through the lazy scene_ensure_for_chunk primitive (bounded per run).
_rescued="$(scene_rescue_cold 2>/dev/null)"
case "${_rescued:-0}" in ''|*[!0-9]*) _rescued=0 ;; esac
# B (overflow net): a full bulk sweep ONLY while a large backlog remains
# (first run / big reindex / cron downtime). Steady-state is handled by C.
_remaining="$(scene_pending_count)"
case "${_remaining:-0}" in ''|*[!0-9]*) _remaining=0 ;; esac
_sweep_th="${SCENE_COLD_BACKLOG_SWEEP:-100}"
case "${_sweep_th:-100}" in ''|*[!0-9]*) _sweep_th=100 ;; esac
_seed_total=0
if [ "$_remaining" -ge "$_sweep_th" ]; then
    _seed_total="$(scene_seed_bulk)" 2>/dev/null
fi
# Prune zombie scenes whose chunk was removed by decay.
_pruned="$(scene_prune_orphans)"

{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) scene_sync_catchup: ${_sync} rescued=${_rescued} pending=${_remaining} seed_total=${_seed_total:-0} pruned=${_pruned:-0}"
  scene_stats 2>/dev/null
} >> "$LOG" 2>&1

exit 0
