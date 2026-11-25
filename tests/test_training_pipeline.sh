#!/usr/bin/env bash
# ── Hermetic Unit Tests: Sleep-Cycle Training, Forge Persistence, Colab Fallback, SVD-32 Lineage & 7-Pillar Gate ──
set -uo pipefail

LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$LODGE_DIR/.venv/bin/python3"
[ ! -x "$PY" ] && PY="python3"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf "    ✓ %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "    ✗ %s\n" "$1" >&2; }

echo ""
echo "━━ Sovereign Training Forge, Colab Fallback & SVD-32 Lineage Suite ━━"

TMP=$(mktemp -d /tmp/test_train_pipe.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export GEORGE_DIR="$TMP/george"
export MODELS_DIR="$TMP/models"
mkdir -p "$GEORGE_DIR/transcripts" "$GEORGE_DIR/configs" "$MODELS_DIR/adapters"

# 1. Create synthetic multi-step episode & journal entry to verify persistence recipe + dream replay
cat > "$GEORGE_DIR/transcripts/ep1.md" <<'EOF'
# Task: Fix build error and verify tests

## User
Check scripts/training/runs.py, fix any syntax errors, and verify with tests.

## Step 1
Tool: `file_read({"path": "scripts/training/runs.py"})`
Observation: `Line 42: def ok(): return True`

## Step 2
Tool: `file_edit({"path": "scripts/training/runs.py", "old": "return True", "new": "return 1"})`
Observation: `Edited successfully.`

## Step 3
Tool: `bash_exec({"command": "python3 -m py_compile scripts/training/runs.py"})`
Observation: `OK (exit 0)`

## Step 4
Tool: `bash_exec({"command": "bash tests/test_training_pipeline.sh"})`
Observation: `All tests passed.`

## Final Answer
Fixed scripts/training/runs.py and verified both compilation and the test suite passed.
EOF
mkdir -p "$GEORGE_DIR/journal"
cat > "$GEORGE_DIR/journal/2026-11-25.md" <<'EOF'
Always run bash -n and python3 -m py_compile after editing scripts, and verify rendered K8s manifests have no /home/user placeholders before applying.
EOF

# Test 1: Forge recipes include persistence and sdr-p25
if "$PY" -B "$LODGE_DIR/scripts/training/forge.py" recipes --json | tail -n 1 | jq -e 'has("persistence") and has("sdr-p25")' >/dev/null 2>&1; then
    pass "Dataset Forge registers persistence and sdr-p25 recipes"
else
    fail "Dataset Forge missing persistence or sdr-p25 recipe"
fi

# Test 2: Forge build with persistence + include-journal produces both SFT and DPO outputs cleanly
BUILD_OUT=$("$PY" -B "$LODGE_DIR/scripts/training/forge.py" --george-dir "$GEORGE_DIR" build \
    --focus persistence,final-answer --count 20 --include-journal --out "$TMP/ds_out" 2>/dev/null | tail -n 1)
if printf '%s' "$BUILD_OUT" | jq -e '.produced >= 1 and .sft_train >= 1 and .bench_guard.enabled == true' >/dev/null 2>&1; then
    pass "Dataset Forge builds persistence + journal replay dataset with BenchGuard enabled"
else
    fail "Dataset Forge build failed: $BUILD_OUT"
fi

# Test 3: check_credits.py returns structured prerequisites checklist even when ADC is unconfigured
CRED_OUT=$("$PY" -B "$LODGE_DIR/scripts/training/check_credits.py" --json 2>/dev/null)
if printf '%s' "$CRED_OUT" | jq -e '.prerequisites | has("colab_cli") and has("gcloud_cli") and has("adc_credentials") and has("hf_token") and has("local_train_env")' >/dev/null 2>&1; then
    pass "check_credits.py returns full structured prerequisites checklist"
else
    fail "check_credits.py missing prerequisite fields"
fi

# Test 4: runs.py GPU fallback ladder validation & VRAM filtering (H100->G4->A100->L4->T4)
LADDER_OUT=$("$PY" -B -c "
import sys, json
sys.path.insert(0, '$LODGE_DIR/scripts/training')
import runs
l24 = runs.build_gpu_ladder('A100', ['H100','G4','A100','L4','T4'], 24)
l16 = runs.build_gpu_ladder('L4', ['H100','G4','A100','L4','T4'], 16)
assert l24 == ['A100', 'H100', 'G4', 'L4'], l24
assert l16 == ['L4', 'H100', 'G4', 'A100', 'T4'], l16
try:
    runs.build_gpu_ladder('A80', None, 24)
    raise AssertionError('A80 should be rejected')
except runs.SpecError:
    pass
print('OK')
")
if [ "$LADDER_OUT" = "OK" ]; then
    pass "runs.py validates exact colab-cli GPUs (H100/G4/A100/L4/T4), filters VRAM floor, and rejects invalid SKUs"
else
    fail "runs.py GPU fallback ladder validation failed: $LADDER_OUT"
fi

# Test 5: runs.py policy persistence (Tier B <-> Tier A)
POL_OUT=$("$PY" -B "$LODGE_DIR/scripts/training/runs.py" policy --set '{"autonomy_tier":"tier_a","sleep_enabled":true}' 2>/dev/null)
if printf '%s' "$POL_OUT" | jq -e '.autonomy_tier == "tier_a" and .sleep_enabled == true' >/dev/null 2>&1; then
    pass "runs.py policy toggles Tier B <-> Tier A and Sleep Cycle cleanly"
else
    fail "runs.py policy update failed: $POL_OUT"
fi

# Test 6: runs.py plan & local dry-run generates contention-safe driver with inference pause/restore trap
mkdir -p "$GEORGE_DIR/datasets/unit_ds"
printf '{"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"ok"}]}\n' > "$GEORGE_DIR/datasets/unit_ds/sft.jsonl"
cat > "$TMP/spec.json" <<'EOF'
{
  "name": "unit-sleep-v1",
  "role": "core-agent",
  "model_slug": "gemma-4-31b-it",
  "backend": "local",
  "base_model": "google/gemma-4-31b-it",
  "tracks": [{"name": "sft", "method": "sft", "train": "exports:unit_ds/sft.jsonl", "gpu": 0}],
  "local": {"pause_inference": true}
}
EOF
DRY_OUT=$("$PY" -B "$LODGE_DIR/scripts/training/runs.py" start "$TMP/spec.json" --dry-run 2>/dev/null)
if [ -f "$GEORGE_DIR/training/runs/unit-sleep-v1/driver.sh" ] && grep -q "restore_inference" "$GEORGE_DIR/training/runs/unit-sleep-v1/driver.sh"; then
    pass "runs.py local dry-run generates contention-safe driver with inference pause/restore trap"
else
    fail "runs.py local dry-run driver check failed: $DRY_OUT"
fi

# Test 7: multiturn_bench.py --compare PASS/FAIL gate logic & early-quit regression guard
cat > "$TMP/base_sc.json" <<'EOF'
{"model_label":"gemma4-base","overall_score":80.0,"early_quit_rate_pct":15.0,"pillars":{"Pillar 7: Persistence":{"score_pct":60.0}}}
EOF
cat > "$TMP/cand_good.json" <<'EOF'
{"model_label":"gemma4-svd32","overall_score":91.5,"early_quit_rate_pct":4.0,"pillars":{"Pillar 7: Persistence":{"score_pct":92.0}}}
EOF
cat > "$TMP/cand_bad.json" <<'EOF'
{"model_label":"gemma4-regressed","overall_score":78.0,"early_quit_rate_pct":22.0,"pillars":{"Pillar 7: Persistence":{"score_pct":50.0}}}
EOF
if "$PY" -B "$LODGE_DIR/scripts/eval/multiturn_bench.py" --compare "$TMP/base_sc.json" "$TMP/cand_good.json" --min-delta 3.0 | jq -e '.passed == true and .composite_delta == 11.5 and .early_quit_delta == -11.0' >/dev/null 2>&1; then
    pass "multiturn_bench.py --compare passes improved candidate (+11.5% composite, -11.0% early-quit)"
else
    fail "multiturn_bench.py --compare failed on good candidate"
fi
if ! "$PY" -B "$LODGE_DIR/scripts/eval/multiturn_bench.py" --compare "$TMP/base_sc.json" "$TMP/cand_bad.json" --min-delta 0.0 >/dev/null 2>&1; then
    pass "multiturn_bench.py --compare rejects regressed candidate"
else
    fail "multiturn_bench.py --compare should reject regressed candidate"
fi

# Test 8: All 4 playbooks & ALP v1 sleep-cycle loop are valid JSON
if jq empty "$LODGE_DIR"/configs/playbooks/*.json "$LODGE_DIR/data/workflows/loops/sleep-cycle-svd.loop.json" "$LODGE_DIR/data/schemas/native_tools.json" >/dev/null 2>&1; then
    pass "All JSON playbooks, sleep-cycle-svd.loop.json, and native_tools.json are valid JSON"
else
    fail "Invalid JSON found in playbooks, sleep-cycle loop, or native_tools.json"
fi

# Test 9: train_lora.py headless Drive OAuth2 refresh + checkpoint sync/restore & runs.py bundle refresh
DRV_OUT=$("$PY" -B -c "
import io, json, os, sys, tarfile, tempfile, time
sys.path.insert(0, '$LODGE_DIR/scripts/training/kit')
sys.path.insert(0, '$LODGE_DIR/scripts/training')
import train_lora as tl, runs

with tempfile.TemporaryDirectory() as td:
    # 1. Verify _DriveClient loads auth file & refreshes expired access tokens
    af = os.path.join(td, 'auth.json')
    json.dump({'access_token': 'old', 'expires_at': time.time() - 10, 'refresh_token': 'rt', 'client_id': 'cid', 'client_secret': 'cs', 'quota_project_id': 'qp1'}, open(af, 'w'))
    os.environ['GOOGLE_DRIVE_AUTH_FILE'] = af
    dc = tl._DriveClient()
    assert dc.configured and dc.can_refresh and dc.quota_project == 'qp1'
    refreshed = {'n': 0}
    def fake_refresh():
        refreshed['n'] += 1
        dc.access_token = 'fresh_tok'
        dc.expires_at = time.time() + 3600
        return dc.access_token
    dc.refresh_access_token = fake_refresh
    assert dc.get_token() == 'fresh_tok' and refreshed['n'] == 1
    assert dc.get_token() == 'fresh_tok' and refreshed['n'] == 1  # cached until near expiry
    assert dc.get_token(force_refresh=True) == 'fresh_tok' and refreshed['n'] == 2

    # 2. Verify checkpoint sync + restore round-trip via mocked Drive storage
    mem_store = {}
    dc.ensure_folder = lambda p: 'fid_ckpts'
    def fake_upload(local_path, folder_id, remote_name, overwrite=True):
        mem_store[remote_name] = open(local_path, 'rb').read()
        return True
    def fake_list(folder_id):
        return [{'id': k, 'name': k} for k in mem_store]
    def fake_dl(fid, dest):
        open(dest, 'wb').write(mem_store[fid])
        return True
    dc.upload_file = fake_upload
    dc.list_files = fake_list
    dc.download_file = fake_dl
    dc.delete_file = lambda fid: bool(mem_store.pop(fid, None))

    src_ckpt = os.path.join(td, 'src', 'checkpoint-80')
    os.makedirs(src_ckpt)
    open(os.path.join(src_ckpt, 'trainer_state.json'), 'w').write('{\"global_step\":80}')
    assert tl._sync_checkpoint_to_drive(dc, 'BlueLodge/training/r1/t1', src_ckpt, keep=2)
    assert 'checkpoint-80.tar.gz' in mem_store

    dst_dir = os.path.join(td, 'dst')
    restored = tl._restore_latest_drive_checkpoint(dc, 'BlueLodge/training/r1/t1', dst_dir)
    assert restored and os.path.isfile(os.path.join(restored, 'trainer_state.json'))

    # 3. Verify _refresh_bundle_kit updates train_lora.py inside an older bundle.tar.gz
    old_bundle = os.path.join(td, 'bundle.tar.gz')
    with tarfile.open(old_bundle, 'w:gz') as tf:
        b = b'# stale old kit\n'
        ti = tarfile.TarInfo('train_lora.py'); ti.size = len(b)
        tf.addfile(ti, io.BytesIO(b))
    runs._refresh_bundle_kit(old_bundle)
    with tarfile.open(old_bundle, 'r:gz') as tf:
        mem = next(m for m in tf.getmembers() if m.name.endswith('train_lora.py'))
        txt = tf.extractfile(mem).read().decode()
    assert '--drive-checkpoint-sync' in txt and '_DriveClient' in txt
    del os.environ['GOOGLE_DRIVE_AUTH_FILE']
print('OK')
" | tail -n 1)
if [ "$DRV_OUT" = "OK" ]; then
    pass "Headless Drive OAuth2 refresh, checkpoint sync/restore round-trip, and bundle kit auto-refresh work"
else
    fail "Headless Drive checkpoint sync / token refresh test failed: $DRV_OUT"
fi

echo "──────────────────────────────────────"
echo "  ${PASS} passed, ${FAIL} failed ($((PASS + FAIL)) total)"
[ "$FAIL" -eq 0 ]
