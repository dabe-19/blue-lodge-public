#!/bin/bash
# ── Tests: lib/memory/scenes.sh — Layer 1 Persistent Scene Store ─────────
# Framework API: assert_eq actual expected [msg]; assert_ok/fail exit_code [msg];
# assert_contains haystack needle [msg]; assert_not_empty value [msg].
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/memory/scenes.sh"

test_start "lib/memory/scenes.sh — Layer 1 Scene Store"

# Pre-check: sqlite3 + FTS5
_HAS_SQLITE=0
if command -v sqlite3 &>/dev/null; then
    _tdb="/tmp/.scenes_fts5_check_$$.db"
    if sqlite3 "$_tdb" "CREATE VIRTUAL TABLE _t USING fts5(c); DROP TABLE _t;" 2>/dev/null; then
        _HAS_SQLITE=1
    fi
    rm -f "$_tdb"
fi
if [ "$_HAS_SQLITE" != "1" ]; then
    skip "sqlite3/FTS5 not available"
    test_end
    exit 0
fi

_SCENES_TMP=$(mktemp -d /tmp/george-scenes-test-XXXXXX)
cleanup() { rm -rf "$_SCENES_TMP" 2>/dev/null || true; }
trap cleanup EXIT

export GEORGE_DIR="$_SCENES_TMP/.george"
export RECALL_DB="$GEORGE_DIR/recall.db"
export LODGE_DIR  # schema lives in the repo tree (worktree)
mkdir -p "$GEORGE_DIR"

# ── Arrange ────────────────────────────────────────────────────────────
scene_store_init
assert_ok $? "scene_store_init applies schema to fresh DB"

sqlite3 "$RECALL_DB" <<SQL
INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES
    ('journal', 'Decision', 'We chose the FIFO protocol for IPC', '.george/journal.md', '$(date -u +%Y-%m-%dT%H:%M:%SZ)'),
    ('george',  'Notes',     'Pipes | and quotes '' in content', 'GEORGE.md', '$(date -u +%Y-%m-%dT%H:%M:%SZ)'),
    ('doc:spec','Flow',      'Specious present assembly', 'docs/spec.md', '$(date -u +%Y-%m-%dT%H:%M:%SZ)');
SQL

_chunks_before=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks;")
_chunks_fts_before=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks_fts;")
_chunk_hashes_before=$(sqlite3 "$RECALL_DB" "SELECT source || char(31) || content FROM chunks WHERE id <= 3 ORDER BY id;" | cksum)

# ── Act / Assert ───────────────────────────────────────────────────────

# 1. Lazy materialization: one chunk -> one scene
_sid=$(scene_ensure_for_chunk 1)
assert_not_empty "$_sid" "scene_ensure_for_chunk(1) returns scene_id"

# 2. Provenance + defaults
_meta=$(scene_get_meta "$_sid")
assert_contains "$_meta" "vivid" "scene meta has vivid tier"
assert_contains "$_meta" "journal" "scene meta has journal tool provenance"
_content=$(scene_get_content "$_sid")
assert_contains "$_content" "FIFO protocol" "scene content matches chunk content"

# 3. Idempotency: second call returns same id, still exactly 1 scene
_sid2=$(scene_ensure_for_chunk 1)
assert_eq "$_sid2" "$_sid" "re-ensure returns same scene_id"
_scenes_count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes;")
assert_eq "$_scenes_count" "1" "exactly 1 scene for chunk 1"

# 4. Content with pipes and quotes survives verbatim
_sid_q=$(scene_ensure_for_chunk 2)
_content_q=$(scene_get_content "$_sid_q")
assert_contains "$_content_q" "Pipes | and quotes ' in content" "pipe + quote content preserved verbatim"

# 5. Tags: add, list, idempotent re-add, invalid class rejected
scene_tag_add "$_sid" "ipc" "topic"
scene_tag_add "$_sid" "fifo-ipc" "topic"
_tags=$(scene_tags_list "$_sid")
assert_contains "$_tags" "ipc" "tag list includes ipc"
assert_contains "$_tags" "fifo-ipc" "tag list includes fifo-ipc"
scene_tag_add "$_sid" "ipc" "topic"  # duplicate
_tag_count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scene_tags WHERE scene_id = $_sid AND tag = 'ipc';")
assert_eq "$_tag_count" "1" "duplicate tag ignored"
scene_tag_add "$_sid" "bad" "not_a_class" 2>/dev/null
assert_fail $? "invalid tag_class rejected"
_tag_bad=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scene_tags WHERE tag = 'bad';")
assert_eq "$_tag_bad" "0" "invalid tag not stored"

# 6. Tier transitions: valid accepted, invalid rejected
scene_set_tier "$_sid" "fading"
assert_contains "$(scene_get_meta "$_sid")" "fading" "tier updated to fading"
scene_set_tier "$_sid" "bogus" 2>/dev/null
assert_fail $? "invalid tier rejected"

# 7. Scene FTS search works independently of chunks_fts
#    (chunk 3 must be materialized first — scenes are lazy by design).
#    Snippet output decorates matches with >>>/<<<, so assert on the id.
_sid3=$(scene_ensure_for_chunk 3)
_res=$(scene_search "specious present" 3)
_hit_id=$(printf '%s' "$_res" | head -1 | cut -f1)
assert_eq "$_hit_id" "$_sid3" "scene search returns the matching scene_id"

# 8. Backfill is opt-in and idempotent: new chunk 4 stays unmapped until
#    the explicit opt-in call, then second run creates 0
sqlite3 "$RECALL_DB" "INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES ('journal', 'Late', 'Late-night sediment entry', '.george/journal.md', '$(date -u +%Y-%m-%dT%H:%M:%SZ)');"
_created=$(scene_backfill_all)
assert_eq "$_created" "1" "backfill creates the single unmapped scene"
_created2=$(scene_backfill_all)
assert_eq "$_created2" "0" "second backfill creates 0"

# 9. Blast-radius guard: original chunks (id <= 3) and chunks_fts untouched
#    (chunk 4 was intentionally added; scene layer must not mutate chunks)
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE id <= 3;")" \
    "$_chunks_before" "original chunk count unchanged"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks_fts WHERE rowid <= 3;")" \
    "$_chunks_fts_before" "original chunks_fts row count unchanged"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT source || char(31) || content FROM chunks WHERE id <= 3 ORDER BY id;" | cksum)" \
    "$_chunk_hashes_before" "original chunk content untouched (hash match)"

# 10. Input validation: non-numeric / injection ids rejected
scene_ensure_for_chunk "abc" 2>/dev/null
assert_fail $? "non-numeric chunk_id rejected"
scene_ensure_for_chunk "1;DROP TABLE chunks" 2>/dev/null
assert_fail $? "injection-style chunk_id rejected"

# 11. Re-init idempotent: schema re-apply is a no-op on live data
scene_store_init
_scenes_still=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes;")
assert_eq "$_scenes_still" "4" "re-init preserves existing scenes"

# 12. Stats line shape (live counts: chunk 4 was added mid-suite by design)
_stats=$(scene_stats)
assert_contains "$_stats" "total_chunks=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks;")" "stats reports chunk totals"
assert_contains "$_stats" "scenes_materialized=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes;")" "stats reports materialized scenes"

# 13. scene_search_hooks (Strategy A real-time + C cold rescue)
assert_ok "$(declare -f scene_search_hooks >/dev/null 2>&1; echo $?)" "scene_search_hooks defined"
_chunks_pre_hook=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks;")
_scenes_pre_hook=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes;")
sqlite3 "$RECALL_DB" "
INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES
  ('journal', '2026-01-02 03:04 — note', 'A marmot digs a fresh burrow beneath the stone.', 'journal.md', '2026-01-02T03:04:00'),
  ('george', 'Cold quokka chunk', 'Dormant quokka note, never surfaced by a query.', 'notes.md', '2026-01-02T03:04:00');
"

# 13a. Disabled modes: zero side effects
SCENE_HOOKS_ENABLED=0 scene_search_hooks "marmot" 5
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes WHERE chunk_id > $_chunks_pre_hook;")" "0" "hook disabled: no scenes seeded"
GEORGE_TEST_MODE=1 scene_search_hooks "marmot" 5
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes WHERE chunk_id > $_chunks_pre_hook;")" "0" "test-mode: no scenes seeded"

# 13b. Enabled: Strategy A materializes + stamps the query hit (entry event ts)
#      and Strategy C rescues the never-queried cold chunk (linked=0).
#      GEORGE_TEST_MODE=0 pinned so outer env can't silently disable the hook.
GEORGE_TEST_MODE=0 SCENE_HOOKS_ENABLED=1 scene_search_hooks "marmot" 5
assert_eq $? 0 "hook returns 0"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes WHERE chunk_id > $_chunks_pre_hook;")" "2" "query hit + cold chunk both materialized"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT SUM(link_count) FROM scenes WHERE chunk_id = $_chunks_pre_hook + 1;")" "1" "query hit stamped once (link_count)"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT link_count FROM scenes WHERE chunk_id = $_chunks_pre_hook + 2;")" "0" "cold-rescued chunk unlinked"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT ts FROM scenes WHERE chunk_id = $_chunks_pre_hook + 1;")" "2026-01-02 03:04:00" "journal scene ts = entry event time"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes_fts WHERE scenes_fts MATCH 'marmot';")" "1" "scenes_fts auto-indexed via trigger"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks;")" "$((_chunks_pre_hook + 2))" "hooks never touch chunks"

# 13c. Idempotency: re-run seeds nothing new, stamps again
GEORGE_TEST_MODE=0 SCENE_HOOKS_ENABLED=1 scene_search_hooks "marmot" 5
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes WHERE chunk_id > $_chunks_pre_hook;")" "2" "re-run: no duplicate scenes"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT SUM(link_count) FROM scenes WHERE chunk_id = $_chunks_pre_hook + 1;")" "2" "re-run: link_count incremented to 2"

# 13d. No-hit query: only bounded cold-seed may act (none pending -> no-op)
GEORGE_TEST_MODE=0 SCENE_HOOKS_ENABLED=1 scene_search_hooks "zebra" 5
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes;")" "$((_scenes_pre_hook + 2))" "no-hit query: scene count stable"

# ── 14. Strategy B: id-stable catch-up reconciliation ──────────────────

# 14a. scene_reconcile_source: 3-way diff on a scratch source
_recon_src="doc:reconcile-test"
_recon_tsv="$_SCENES_TMP/recon-tsv.tsv"
printf 'SecA\talpha one.\nSecB\tbeta two.\n' > "$_recon_tsv"
_r1=$(scene_reconcile_source "$_recon_src" "$_recon_tsv" "$_SCENES_TMP/j.md")
assert_eq "$_r1" "+2 ~0 -0" "reconcile fresh source: +2 ~0 -0"
_id_a=$(sqlite3 "$RECALL_DB" "SELECT id FROM chunks WHERE source='$_recon_src' AND section='SecA';")

# modify SecB in place + add SecC; SecA untouched
printf 'SecA\talpha one.\nSecB\tbeta two REVISED.\nSecC\tgamma three.\n' > "$_recon_tsv"
_r2=$(scene_reconcile_source "$_recon_src" "$_recon_tsv" "$_SCENES_TMP/j.md")
assert_eq "$_r2" "+1 ~1 -0" "reconcile: +1 insert, ~1 update"
_id_a2=$(sqlite3 "$RECALL_DB" "SELECT id FROM chunks WHERE source='$_recon_src' AND section='SecA';")
assert_eq "$_id_a2" "$_id_a" "unchanged section keeps its chunk id (id-stable)"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT content FROM chunks WHERE source='$_recon_src' AND section='SecB';")" \
    "beta two REVISED." "changed section updated in place"

# delete SecC: reported as -1
printf 'SecA\talpha one.\nSecB\tbeta two REVISED.\n' > "$_recon_tsv"
_r3=$(scene_reconcile_source "$_recon_src" "$_recon_tsv" "$_SCENES_TMP/j.md")
assert_eq "$_r3" "+0 ~0 -1" "reconcile: -1 delete of vanished section"

# duplicate section headings: first occurrence wins (no chunk dup)
printf 'SecA\tdup one.\nSecA\tdup two.\n' > "$_recon_tsv"
scene_reconcile_source "$_recon_src" "$_recon_tsv" "$_SCENES_TMP/j.md" >/dev/null
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='$_recon_src';")" "1" "duplicate sections dedupe to first occurrence"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT content FROM chunks WHERE source='$_recon_src' AND section='SecA';")" "dup one." "first occurrence content wins"

# invalid source labels rejected
scene_reconcile_source "bad src" "$_recon_tsv" "$_SCENES_TMP/j.md" >/dev/null 2>&1
assert_eq $? 1 "reconcile rejects whitespace in source label"
scene_reconcile_source "" "$_recon_tsv" "$_SCENES_TMP/j.md" >/dev/null 2>&1
assert_eq $? 1 "reconcile rejects empty source label"
rm -f "$_recon_tsv"

# 14b. scene_sync: hash-gated, id-stable; embedded chunker (recall.sh not
#      sourced in this file -> exercises the standalone fallback)
_jfile="$_SCENES_TMP/journal-test.md"
printf '# J\n\n## 2026-01-01 00:00 — reflection\n\nFirst entry about the wolverine.\n\n## 2026-01-02 00:00 — reflection\n\nSecond entry about the badger.\n' > "$_jfile"
_s1=$(scene_sync "doc:sync-test" "$_jfile")
assert_contains "$_s1" "+3 ~0 -0" "scene_sync initial: preamble + 2 sections"
_id_w=$(sqlite3 "$RECALL_DB" "SELECT id FROM chunks WHERE source='doc:sync-test' AND section='2026-01-01 00:00 — reflection';")
assert_not_empty "$_id_w" "scene_sync created the wolverine chunk"
scene_ensure_for_chunk "$_id_w" >/dev/null

# add a third section
printf '\n## 2026-01-03 00:00 — reflection\n\nThird entry about the gnu.\n' >> "$_jfile"
_s2=$(scene_sync "doc:sync-test" "$_jfile")
assert_contains "$_s2" "+1 ~0 -0" "scene_sync incremental: +1 only"
_id_w2=$(sqlite3 "$RECALL_DB" "SELECT id FROM chunks WHERE source='doc:sync-test' AND section='2026-01-01 00:00 — reflection';")
assert_eq "$_id_w2" "$_id_w" "scene_sync preserves chunk id across runs"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes WHERE chunk_id=$_id_w;")" "1" "scene survived sync (no id churn)"

# hash gate: byte-identical file -> pure no-op
_s3=$(scene_sync "doc:sync-test" "$_jfile")
assert_contains "$_s3" "unchanged" "hash gate: unchanged file is a no-op"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='doc:sync-test';")" "4" "hash-gated no-op leaves chunk count intact"
assert_not_empty "$(sqlite3 "$RECALL_DB" "SELECT value FROM scene_meta WHERE key='scene_sync_hash:doc:sync-test';")" "gate hash persisted in scene_meta"

# missing file: clean skip, not an error
assert_contains "$(scene_sync "doc:sync-test" "$_SCENES_TMP/does-not-exist.md")" "file missing" "scene_sync skips missing file"

# 14c. scene_prune_orphans: FK cascade + idempotent
scene_ensure_for_chunk "$_id_w" >/dev/null   # no-op (exists); ensure tag exists too
scene_tag_add "$(sqlite3 "$RECALL_DB" "SELECT scene_id FROM scenes WHERE chunk_id=$_id_w;")" "wolverine" "topic" >/dev/null
sqlite3 "$RECALL_DB" "DELETE FROM chunks WHERE id=$_id_w;"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes s WHERE s.chunk_id NOT IN (SELECT id FROM chunks);")" "1" "chunk removal leaves 1 orphan scene"
_p1=$(scene_prune_orphans)
assert_eq "$_p1" "1" "prune removes the orphan scene"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scene_tags t WHERE t.scene_id NOT IN (SELECT scene_id FROM scenes);")" "0" "orphan tag cascade-deleted (no danglers)"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes_fts;")" "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes;")" "scenes_fts consistent after prune"
_p2=$(scene_prune_orphans)
assert_eq "$_p2" "0" "prune is idempotent (second run removes nothing)"

# 14d. recall_index_file takes the stable path when scenes.sh is in scope
_id_badger_before=$(sqlite3 "$RECALL_DB" "SELECT id FROM chunks WHERE source='doc:sync-test' AND section='2026-01-02 00:00 — reflection';")
( source "$LODGE_DIR/lib/memory/recall.sh" 2>/dev/null; recall_index_file "doc:sync-test" "$_jfile" >/dev/null 2>&1 )
_id_badger_after=$(sqlite3 "$RECALL_DB" "SELECT id FROM chunks WHERE source='doc:sync-test' AND section='2026-01-02 00:00 — reflection';")
assert_eq "$_id_badger_after" "$_id_badger_before" "recall_index_file stable path: chunk id preserved across reindex"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='doc:sync-test';")" "4" "recall_index_file stable path: chunk count intact"

rm -f "$_jfile"

# ── 15. Strategy C: scene_rescue_cold — the dormant lazy path, rescued ─────

# 15a. Defined. First drain any pre-existing pending chunks left by earlier
#      suite sections so this section reasons about a CLEAN cold backlog of
#      exactly the 5 chunks added next. Backfill only touches the scene layer.
assert_ok "$(declare -f scene_rescue_cold >/dev/null 2>&1; echo $?)" "scene_rescue_cold defined"
scene_backfill_all >/dev/null 2>&1
assert_eq "$(scene_pending_count)" "0" "pre-cold backlog drained (clean slate)"

# Fresh cold backlog with DISTINCT indexed_at (2025 — older than any suite
# chunk) so coldest-first ordering is unambiguous. Insert order D,E,F,G,H
# => ids _cold_lo.._cold_hi map to 05:00,04:00,03:00,02:00,01:00 respectively;
# the coldest (01:00) is _cold_hi.
sqlite3 "$RECALL_DB" "INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES
  ('journal', 'ColdR D', 'Cold rescue chunk D.', 'j.md', '2025-03-05T05:00:00'),
  ('journal', 'ColdR E', 'Cold rescue chunk E.', 'j.md', '2025-03-05T04:00:00'),
  ('journal', 'ColdR F', 'Cold rescue chunk F.', 'j.md', '2025-03-05T03:00:00'),
  ('journal', 'ColdR G', 'Cold rescue chunk G.', 'j.md', '2025-03-05T02:00:00'),
  ('journal', 'ColdR H', 'Cold rescue chunk H.', 'j.md', '2025-03-05T01:00:00');"
_cold_lo=$(sqlite3 "$RECALL_DB" "SELECT MIN(id) FROM chunks WHERE section LIKE 'ColdR %';")
_cold_hi=$(sqlite3 "$RECALL_DB" "SELECT MAX(id) FROM chunks WHERE section LIKE 'ColdR %';")
assert_eq "$((_cold_hi - _cold_lo + 1))" "5" "the 5 cold chunks occupy 5 consecutive ids"
assert_eq "$(scene_pending_count)" "5" "pending backlog is exactly the 5 fresh cold chunks"

# 15b. Bounded + coldest-first: budget 2 rescues exactly the two coldest
#      (01:00 then 02:00) and reports 2.
_rc1=$(scene_rescue_cold 2)
assert_eq "$_rc1" "2" "rescue budget=2 rescues exactly 2"
_rescued_ids=$(sqlite3 "$RECALL_DB" "SELECT chunk_id FROM scenes WHERE chunk_id BETWEEN $_cold_lo AND $_cold_hi ORDER BY chunk_id;" | tr '\n' ' ' | sed 's/ $//')
assert_eq "$_rescued_ids" "$((_cold_hi - 1)) $_cold_hi" "rescued ids = the two coldest (01:00 then 02:00)"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT ts FROM scenes WHERE chunk_id = $_cold_hi;")" "2025-03-05T01:00:00" "coldest scene ts = chunk indexed_at (01:00)"
assert_eq "$(scene_pending_count)" "3" "pending count drops by exactly the budget"

# 15c. Resumable: second rescue drains the NEXT coldest pair (03:00, 04:00);
#      third drains the last (05:00); backlog then empty.
_rc2=$(scene_rescue_cold 2)
assert_eq "$_rc2" "2" "second rescue drains the next 2 (frontier advances)"
_rescued_ids2=$(sqlite3 "$RECALL_DB" "SELECT chunk_id FROM scenes WHERE chunk_id BETWEEN $_cold_lo AND $_cold_hi ORDER BY chunk_id;" | tr '\n' ' ' | sed 's/ $//')
assert_eq "$_rescued_ids2" "$((_cold_hi - 3)) $((_cold_hi - 2)) $((_cold_hi - 1)) $_cold_hi" "four coldest now materialized, frontier advanced"
_rc3=$(scene_rescue_cold 2)
assert_eq "$_rc3" "1" "third rescue drains the last 1 (budget > pending clamps)"
assert_eq "$(scene_pending_count)" "0" "backlog fully drained via lazy path"

# 15d. Idempotent + input-safe: empty backlog -> 0; non-numeric/zero budgets no-op.
_rc4=$(scene_rescue_cold 999)
assert_eq "$_rc4" "0" "oversized budget on empty backlog -> 0"
scene_rescue_cold "abc" >/dev/null 2>&1
_rc5=$(scene_rescue_cold 0)
assert_eq "$_rc5" "0" "zero budget -> safe no-op printing 0"

# 15e. Semantics: rescued cold scenes are UNLINKED (never queried), vivid, 0.5,
#      content verbatim, and the lazy path never touched the chunks table.
_ci=$((_cold_hi - 1))   # ColdR G (02:00)
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT link_count FROM scenes WHERE chunk_id=$_ci;")" "0" "rescued cold scene unlinked (never queried)"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT tier FROM scenes WHERE chunk_id=$_ci;")" "vivid" "rescued cold scene tier vivid"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT salience FROM scenes WHERE chunk_id=$_ci;")" "0.5" "rescued cold scene salience 0.5"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT content FROM scenes WHERE chunk_id=$_ci;")" \
    "$(sqlite3 "$RECALL_DB" "SELECT content FROM chunks WHERE id=$_ci;")" "rescued scene content verbatim (matches chunk)"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM scenes s JOIN chunks c ON c.id = s.chunk_id WHERE c.section LIKE 'ColdR %';")" \
    "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE section LIKE 'ColdR %';")" "every cold chunk has exactly one scene (1:1)"
assert_eq "$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE section LIKE 'ColdR %';")" "5" "rescue never mutates chunks (5 cold rows intact)"

test_end
