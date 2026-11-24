#!/bin/bash
# INTERVAL: 86400
# DESC: Daily memory decay — Layer 0 (journal.md): compacts entries older than
# SCOPE: system
#       DECAY_SEDIMENT_DAYS (60) into the Sediment section via LLM. PASSIVE BY
#       DESIGN: journal entries are still written only on awareness (task
#       completion / journal_write); this job never force-writes a new entry
#       and is a no-op while no entry has aged past the cutoff. Layer 1
#       (scenes): idempotent age-based tier demotion vivid->fading (14d) ->
#       sediment (60d), link-activity aware, never deletes nouns. Respects the
#       lazy materialization pattern: NO forced scene backfill from this job;
#       scenes still materialize on first access (scene_ensure_for_chunk).
# CREATED: 2026-11-15

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

command -v sqlite3 >/dev/null 2>&1 || exit 0
[ -f "$LODGE_DIR/lib/memory/journal.sh" ] || exit 0

source "$LODGE_DIR/lib/memory/journal.sh"
source "$LODGE_DIR/lib/memory/scenes.sh"
source "$LODGE_DIR/lib/core/llm.sh"

LOG="${CRON_JOB_LOG:-/dev/null}"

# ── Layer 0: journal.md — passive, age-gated compaction ──────────────────
# journal_apply_decay counts qualifying entries first and does nothing when
# old_count=0, so the LLM is only invoked when real sedimentation is due.
journal_apply_decay >>"$LOG" 2>&1

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) journal_decay: layer-0 pass complete" >> "$LOG"

# ── Layer 1: scenes — tier decay only (no forced materialization) ───────
scene_store_init >> "$LOG" 2>&1
_DECAY_OUT="$(scene_tier_decay)"

{ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) journal_decay: layer-1 ${_DECAY_OUT}"; scene_stats; } >> "$LOG" 2>&1

# Quiet on success (cron hygiene).
exit 0
