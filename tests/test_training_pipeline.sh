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
Tool: `file_edit({"path": "scripts/training/runs.py", "target": "return True", "replacement": "return 1"})`
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

# Test 10: Progressive baseline resolution, advancement on approve_candidate, model_matches_live & Discord card
BENCH_AUTO_OUT=$("$PY" -B -c "
import json, os, sys
sys.path.insert(0, '$LODGE_DIR/scripts/training')
import runs

# 1. model_matches_live prevents benchmarking Qwen adapter on Gemma-4 server
assert runs.model_matches_live('gemma-4-31b-it', '/models/hub/unsloth/gemma-4-31B-it-GGUF/gemma-4-31B-it-UD-Q4_K_XL.gguf')
assert not runs.model_matches_live('qwen3.8-27b', '/models/hub/unsloth/gemma-4-31B-it-GGUF/gemma-4-31B-it-UD-Q4_K_XL.gguf')
assert not runs.model_matches_live('gemma-4-26b-a4b-it', '/models/hub/unsloth/gemma-4-31B-it-GGUF/gemma-4-31B-it-UD-Q4_K_XL.gguf')
assert runs.model_matches_live('qwen3.8-27b', '/models/Qwen3.8-27B-UD-Q4_K_S.gguf')

# 2. Progressive baseline advances when approve_candidate promotes a benchmarked run
rd = os.path.join(runs.runs_dir(), 'prog-test-v1')
os.makedirs(rd, exist_ok=True)
cand_dir = os.path.join(runs.role_adapter_dir('gemma-4-31b-it', 'core-agent'), 'candidates')
cand_file = os.path.join(cand_dir, 'prog-test-v1-svd32.gguf')
open(cand_file, 'wb').write(b'GGUF_MOCK')
cand_sc = os.path.join('$TMP', 'cand_prog.json')
json.dump({'model_label': 'prog-test-v1-svd32', 'overall_score': 88.5, 'early_quit_rate_pct': 0.0}, open(cand_sc, 'w'))
runs._write_json(os.path.join(rd, 'run.json'), {
    'name': 'prog-test-v1', 'role': 'core-agent', 'model_slug': 'gemma-4-31b-it', 'backend': 'colab',
    'gate_status': 'pending_approval',
    'spec': {'name': 'prog-test-v1', 'role': 'core-agent', 'model_slug': 'gemma-4-31b-it', 'base_model': 'google/gemma-4-31b-it'},
})
runs._write_json(os.path.join(rd, 'merged.json'), {'outputs': [cand_file], 'prior_weight': 0.7, 'weights': [0.55, 0.45]})
runs._write_json(os.path.join(rd, 'benchmark.json'), {
    'passed': True, 'baseline_label': 'Gemma-4-31B-Baseline', 'candidate_label': 'prog-test-v1-svd32',
    'baseline_score': 82.9, 'candidate_score': 88.5, 'composite_delta': 5.6,
    'baseline_early_quit_pct': 0.0, 'candidate_early_quit_pct': 0.0, 'early_quit_delta': 0.0,
    'candidate_scorecard_path': cand_sc,
    'pillars': {'Pillar 7: Persistence': {'baseline': 73.2, 'candidate': 90.0, 'delta': 16.8}},
})
res = runs.approve_candidate('prog-test-v1', approver='unit_test', apply_live=False)
assert res['baseline_advanced'] is True and res['version'] == 'v1'
bl = runs.resolve_baseline('gemma-4-31b-it', 'core-agent')
assert bl and bl['overall_score'] == 88.5 and bl['adapter_version'] == 'v1', bl

# 3. Discord scorecard card includes metrics and both approve/deny options
card = runs.format_benchmark_discord_card('prog-test-v1', runs._read_json(os.path.join(rd, 'benchmark.json')))
assert '82.9%' in card and '88.5%' in card and '/train approve prog-test-v1' in card and '/train deny prog-test-v1' in card
print('OK')
" | tail -n 1)
if [ "$BENCH_AUTO_OUT" = "OK" ] && grep -q 'discord_send_report.sh" "@owner"' "$LODGE_DIR/scripts/cron_system/training_watchdog.sh"; then
    pass "Progressive baseline advancement, model mismatch guard, Discord H2H card & watchdog @owner delivery work"
else
    fail "Progressive baseline / H2H automation test failed: $BENCH_AUTO_OUT"
fi

# Test 11: harness-workflows recipe & --max-discord-frac cap in forge.py
HW_OUT=$("$PY" -B "$LODGE_DIR/scripts/training/forge.py" --george-dir "$GEORGE_DIR" build \
    --focus harness-workflows,persistence --count 40 --max-discord-frac 0.0 --out "$TMP/ds_hw" 2>/dev/null | tail -n 1)
if printf '%s' "$HW_OUT" | jq -e '.produced >= 20 and (.by_recipe["harness-workflows"] // 0) >= 15 and .bench_guard.enabled == true and .schema_validation.dropped == 0' >/dev/null 2>&1; then
    pass "Dataset Forge builds harness-workflows multi-step trajectories with --max-discord-frac cap and 0 schema violations"
else
    fail "harness-workflows forge build failed: $HW_OUT"
fi

# Test 12: Live tool schema sync parity + tool pruning (<=16 tools) + zero DPO reasoning leak
SCHEMA_OUT=$("$PY" -B -c "
import json, os, sys
sys.path.insert(0, '$LODGE_DIR/scripts/training')
import sync_tool_schemas as sts, forge, harness_curriculum as hc

rep = sts.sync_schemas('$LODGE_DIR', write=False)
assert rep['in_sync'], f'native_core_tools.json out of sync: {rep}'

canon = forge.load_canonical_tools(os.path.join('$LODGE_DIR', 'data'))
wf = hc.build_workflow_harness_samples('$LODGE_DIR', 20000)
for s in wf:
    ok, err = forge.validate_tool_call_schema(s['chosen'], canon)
    assert ok, f'Curriculum schema violation ({s[\"meta\"][\"session\"]}): {err}'

# Verify _prune_tools caps huge 100+ tool lists to <= 16 and includes used tools
huge_tools = list(canon.values())
chosen_m = {'role': 'assistant', 'content': '', 'reasoning_content': 'secret thought', 'tool_calls': [{'id': 'c1', 'type': 'function', 'function': {'name': 'git_push', 'arguments': '{\"branch\":\"main\"}'}}]}
pruned = forge._prune_tools(huge_tools, [{'role': 'user', 'content': 'push'}], chosen_m, None, canon, max_tools=16)
assert len(pruned) <= 16 and any(t['function']['name'] == 'git_push' for t in pruned), len(pruned)

# Verify _clone_call strips reasoning_content by default (no DPO reasoning leak)
rej_m = forge._clone_call(chosen_m, name='file_read')
assert rej_m.get('reasoning_content') == '', rej_m
print('OK')
" | tail -n 1)
if [ "$SCHEMA_OUT" = "OK" ]; then
    pass "Live tool schema parity, <=16 tool pruning, curriculum schema compliance & DPO reasoning strip verified"
else
    fail "Tool schema / pruning / DPO reasoning check failed: $SCHEMA_OUT"
fi

# Test 13: train_lora.py exact Gemma-4 & Qwen prefix alignment (_split_prompt_completion & _split_dpo_pair)
SPLIT_OUT=$("$PY" -B -c "
import sys
sys.path.insert(0, '$LODGE_DIR/scripts/training/kit')
import train_lora as tl

class FakeGemma4Tok:
    def apply_chat_template(self, msgs, tools=None, tokenize=False, add_generation_prompt=False):
        s = '<bos><|turn>system\nSYS<turn|>\n'
        for m in msgs:
            if m['role'] == 'user':
                s += '<|turn>user\n' + m['content'] + '<turn|>\n'
            elif m['role'] == 'assistant':
                r = m.get('reasoning_content') or ''
                s += '<|turn>model\n'
                if r:
                    s += '<|channel>thought\n' + r + '\n<channel|>'
                s += m.get('content', '') + '<turn|>\n'
        if add_generation_prompt:
            s += '<|turn>model\n<|channel>thought\n<channel|>'
        return s

tok = FakeGemma4Tok()
p = [{'role': 'user', 'content': 'check'}]
c = [{'role': 'assistant', 'content': 'calling tool', 'reasoning_content': 'step by step'}]
r = [{'role': 'assistant', 'content': 'stop early', 'reasoning_content': ''}]
sp = tl._split_prompt_completion(tok, p, c)
assert sp and sp[0].endswith('<|turn>model\n') and sp[1].startswith('<|channel>thought\nstep by step'), sp
pair = tl._split_dpo_pair(tok, p, c, r)
assert pair and pair[0].endswith('<|turn>model\n') and pair[1] != pair[2] and '<|channel>thought\nstep by step' in pair[1], pair
print('OK')
" | tail -n 1)
if [ "$SPLIT_OUT" = "OK" ]; then
    pass "train_lora.py _split_prompt_completion & _split_dpo_pair align Gemma-4 empty-thought suffixes cleanly"
else
    fail "train_lora.py prefix alignment test failed: $SPLIT_OUT"
fi

# Test 14: backup_artifacts.py publish --dry-run stages Model Card, tool schema manifest, sanitized lineage & Qwen Jinja
PUB_OUT=$("$PY" -B "$LODGE_DIR/scripts/training/backup_artifacts.py" publish \
    --model qwen3.8-27b --role core-agent --hf-repo dabe-19/blue-lodge-qwen38-27b-svd32 \
    --public --dry-run --out-dir "$TMP/pub_bundle" 2>/dev/null)
if printf '%s' "$PUB_OUT" | jq -e '.status == "ok" and .visibility == "public" and (.files | index("README.md") != null) and (.files | index("tool_schema_manifest.json") != null) and (.files | index("blue_lodge_jinja_template.jinja") != null)' >/dev/null 2>&1; then
    pass "backup_artifacts.py publish --dry-run stages HF Model Card, schema manifest, lineage & Qwen Jinja"
else
    fail "backup_artifacts.py publish --dry-run failed: $PUB_OUT"
fi

# Test 15: Live provision.log fallback, metrics.jsonl analytics & phase detection in stream_logs
OBS_OUT=$("$PY" -B -c "
import json, os, sys
sys.path.insert(0, '$LODGE_DIR/scripts/training')
import runs

rd = os.path.join(runs.runs_dir(), 'obs-test-v1')
td = os.path.join(rd, 'tracks', 'dpo-harness')
os.makedirs(td, exist_ok=True)
runs._write_json(os.path.join(rd, 'run.json'), {
    'name': 'obs-test-v1', 'backend': 'colab', 'model_slug': 'gemma-4-31b-it', 'state': 'running',
    'spec': {'colab': {'auth': 'adc', 'gpu_fallback': ['H100', 'A100']}, 'tracks': [{'name': 'dpo-harness'}]},
    'plan': [{'track': 'dpo-harness', 'session': 'bl-obs', 'selected_gpu': None, 'fallback_history': [{'gpu': 'H100', 'status': 'failed', 'attempt': 1, 'reason': 'timeout'}]}],
})
open(os.path.join(td, 'state'), 'w').write('provisioning\n')
runs._append_provision_log(td, 'Requesting Colab H100 (attempt 1/1)...')
sl1 = runs.stream_logs('obs-test-v1', 'dpo-harness', live=False)
assert sl1['source'] == 'provision_log' and sl1['phase'] == 'provisioning' and 'H100' in sl1['log_tail'], sl1
assert runs._is_actively_provisioning(td) is True
col_res = runs.collect_colab('obs-test-v1')
assert col_res.get('dpo-harness') == 'still_provisioning', col_res
res_res = runs.resume_colab('obs-test-v1')
assert res_res['resumed'].get('dpo-harness') == 'still_provisioning', res_res

# Now write metrics.jsonl & train.log and verify structured telemetry + summary stats
with open(os.path.join(td, 'metrics.jsonl'), 'w') as fh:
    fh.write(json.dumps({'step': 2, 'total_steps': 20, 'loss': 0.68, 'rewards/margins': 0.12, 'rewards/accuracies': 0.6}) + '\n')
    fh.write(json.dumps({'step': 4, 'total_steps': 20, 'loss': 0.51, 'rewards/margins': 0.85, 'rewards/accuracies': 0.9, 'eval_loss': 0.55}) + '\n')
open(os.path.join(td, 'state'), 'w').write('running\n')
open(os.path.join(td, 'train.log'), 'w').write('20%|##| 4/20 [01:00<04:00, 15.0s/it]\n')
sl2 = runs.stream_logs('obs-test-v1', 'dpo-harness', live=False)
assert sl2['phase'] == 'training' and len(sl2['metrics']) == 2 and sl2['summary_stats']['final_margin'] == 0.85 and sl2['summary_stats']['final_eval_loss'] == 0.55, sl2
print('OK')
" | tail -n 1)
if [ "$OBS_OUT" = "OK" ] && grep -q "flock -n 9" "$LODGE_DIR/scripts/cron_system/training_watchdog.sh" && ! grep -vE '^[[:space:]]*#' "$LODGE_DIR/scripts/cron_system/training_watchdog.sh" | grep -qF "training_watchdog.sh"; then
    pass "Live provision.log streaming, watchdog flock + cron self-ref guard + provisioning guard, metrics.jsonl curves & phase detection work"
else
    fail "Observability / watchdog guard test failed: $OBS_OUT"
fi

# Test 16: Model Hub Opt-In Provider Security, Curator & Drive Mirror
MH_EXT_OUT=$("$PY" -B -c "
import os, sys
sys.path.insert(0, '$LODGE_DIR/lib/tools')
from model_hub import curator, drive_mirror, common, providers

# Clear any opt-in flags to test default posture
for k in ('MODEL_HUB_ENABLE_MODELSCOPE', 'MODEL_HUB_ENABLE_OPENCSG', 'MODEL_HUB_ENABLE_HF_MIRROR'):
    os.environ.pop(k, None)

# 1. Default allow-list allows HF + IPFS, and BLOCKS ModelScope (.cn/aliyuncs), OpenCSG, HF-Mirror, untrusted hosts
assert common.host_allowed('https://huggingface.co/api/models')
assert common.host_allowed('https://ipfs.io/ipfs/QmTest')
assert not common.host_allowed('https://modelscope.cn/api/v1/models')
assert not common.host_allowed('https://oss.aliyuncs.com/model.gguf')
assert not common.host_allowed('https://hub.opencsg.com/api/v1/models')
assert not common.host_allowed('https://hf-mirror.com/api/models')
assert not common.host_allowed('https://evil.example.com/model.gguf')

# ModelScope provider must refuse instantiation unless explicitly opted-in
blocked_ms = False
try:
    providers.get_provider('modelscope')
except common.HubError as e:
    blocked_ms = 'opt-in' in str(e).lower()
assert blocked_ms, 'ModelScope should be blocked by default'

# Explicit opt-in unlocks the selected host/provider
os.environ['MODEL_HUB_ENABLE_MODELSCOPE'] = '1'
os.environ['MODEL_HUB_ENABLE_OPENCSG'] = '1'
os.environ['MODEL_HUB_ENABLE_HF_MIRROR'] = '1'
assert common.host_allowed('https://modelscope.cn/api/v1/models')
assert common.host_allowed('https://hub.opencsg.com/api/v1/models')
assert common.host_allowed('https://hf-mirror.com/api/models')
assert providers.get_provider('modelscope').name == 'modelscope'

# 2. Verify Curator default chain is HF-only, and ONLY adds ModelScope when opted-in
orig_get = curator.get_provider
orig_eval = curator._evaluate_candidate
orig_probe = curator.probe
class FakeHF:
    name = 'huggingface'
    def search(self, *a, **k): raise common.HubError('HTTP 429: rate limited')
class FakeMS:
    name = 'modelscope'
    def search(self, *a, **k): return [{'provider': 'modelscope', 'repo': 'unsloth/Qwen3.8-27B-GGUF', 'downloads': 99999, 'tags': ['gguf']}]
try:
    curator.get_provider = lambda n: FakeHF() if n == 'huggingface' else FakeMS()
    curator.probe = lambda: {'gpus': [{'name': 'RTX PRO 5000', 'vram_total_mb': 24463}], 'ram_total_mb': 65536, 'gpu_backend': 'cuda'}
    curator._evaluate_candidate = lambda prov, repo, hw, ctx, kv: {
        'provider': prov.name, 'repo': repo, 'best_quant': 'UD-Q4_K_XL', 'size_gib': 16.45,
        'verdict': 'fits_gpu', 'max_ctx': 98304, 'downloads': 99999, 'draft_cmd': f'/models draft {prov.name} {repo} UD-Q4_K_XL'
    }
    os.environ.pop('MODEL_HUB_ENABLE_MODELSCOPE', None)
    res_def = curator.curate(['qwen'], provider_mode='auto', include_adapters=False)
    assert res_def['provider_chain'] == ['huggingface'] and res_def['families']['qwen']['count'] == 0, res_def

    os.environ['MODEL_HUB_ENABLE_MODELSCOPE'] = '1'
    res_opt = curator.curate(['qwen'], provider_mode='auto', include_adapters=False)
    assert res_opt['provider_chain'] == ['huggingface', 'modelscope']
    assert res_opt['families']['qwen']['provider'] == 'modelscope' and res_opt['families']['qwen']['count'] == 1, res_opt
finally:
    curator.get_provider = orig_get
    curator._evaluate_candidate = orig_eval
    curator.probe = orig_probe
    for k in ('MODEL_HUB_ENABLE_MODELSCOPE', 'MODEL_HUB_ENABLE_OPENCSG', 'MODEL_HUB_ENABLE_HF_MIRROR'):
        os.environ.pop(k, None)

# 3. Verify drive_mirror status shape & adapter slug detection
st = drive_mirror.drive_status()
assert 'ready' in st and 'drive_folder' in st
assert drive_mirror._detect_adapter_slug({'source': {'repo': 'unsloth/Qwen3.8-27B-GGUF'}}) == 'qwen3.8-27b'
assert drive_mirror._detect_adapter_slug({'source': {'repo': 'unsloth/gemma-4-31B-it-GGUF'}}) == 'gemma-4-31b-it'
print('OK')
" | tail -n 1)
if [ "$MH_EXT_OUT" = "OK" ]; then
    pass "Model Hub opt-in provider security (ModelScope/OpenCSG/HF-Mirror disabled by default), curator & Drive mirror work"
else
    fail "Model Hub opt-in / curator / Drive mirror test failed: $MH_EXT_OUT"
fi

# 18. Multi-Node Colab VM Ownership Manifest (_active_vms.json) & On-Demand SVD Adapter Compression
MN_SVD_OUT=$(TMP_ROOT="$TMP" "$PY" -c "
import json, os, sys, time
from pathlib import Path
sys.path.insert(0, 'scripts/training')
sys.path.insert(0, 'lib/tools')
import runs, backup_artifacts
from model_hub import library

tmp = Path(os.environ['TMP_ROOT'])
vm_file = tmp / '_active_vms.json'
os.environ['BLUE_LODGE_ACTIVE_VMS_FILE'] = str(vm_file)
os.environ['BLUE_LODGE_PEER_VM_TTL_SEC'] = '1800'

# 18a. Register a live VM owned by sibling node 'hiram' and verify 'george' classifies it as peer_active (stale=False)
now = int(time.time())
os.environ['LODGE_NODE_NAME'] = 'hiram'
assert runs._drive_vm_register('gpu-a100-hiram-live', session='bl-hiram-sft', run_name='gemma4-v3', track_name='sft-harness', accelerator='A100')
assert runs._drive_vm_register('gpu-a100-hiram-expired', session='bl-hiram-old', run_name='gemma4-v2', track_name='dpo', accelerator='A100')
# Backdate the second VM heartbeat past TTL
m = json.loads(vm_file.read_text())
m['vms']['gpu-a100-hiram-expired']['heartbeat_at'] = now - 7200
vm_file.write_text(json.dumps(m))

# Fake colab_cli returning both sibling VMs + one genuinely orphaned VM
import types
class FakeAssign:
    def __init__(self, ep, acc): self.endpoint, self.accelerator = ep, acc
class FakeClient:
    def list_assignments(self):
        return [FakeAssign('gpu-a100-hiram-live', 'A100'), FakeAssign('gpu-a100-hiram-expired', 'A100'), FakeAssign('gpu-t4-unowned', 'T4')]
class FakeStore:
    def list(self): return []
    def get(self, x): return None
fake_cstate = types.SimpleNamespace(auth_provider=None, client=FakeClient(), store=FakeStore())
fake_common = types.ModuleType('colab_cli.common'); fake_common.state = fake_cstate
fake_auth = types.ModuleType('colab_cli.auth'); fake_auth.AuthProvider = types.SimpleNamespace(ADC='adc')
fake_pkg = types.ModuleType('colab_cli')
sys.modules['colab_cli'] = fake_pkg
sys.modules['colab_cli.common'] = fake_common
sys.modules['colab_cli.auth'] = fake_auth

os.environ['LODGE_NODE_NAME'] = 'george'
snap = runs.inspect_colab_sessions(probe=False)
by_ep = {r['endpoint']: r for r in snap['sessions']}
assert snap['local_node'] == 'george', snap
assert snap['peer_active_count'] == 1, snap
assert snap['stale_count'] == 2, snap
assert by_ep['gpu-a100-hiram-live']['health'] == 'peer_active' and by_ep['gpu-a100-hiram-live']['stale'] is False and by_ep['gpu-a100-hiram-live']['owner_node'] == 'hiram'
assert by_ep['gpu-a100-hiram-expired']['health'] == 'peer_stale' and by_ep['gpu-a100-hiram-expired']['stale'] is True
assert by_ep['gpu-t4-unowned']['health'] == 'orphaned' and by_ep['gpu-t4-unowned']['stale'] is True

# Unregister removes cleanly
assert runs._drive_vm_unregister(['gpu-a100-hiram-live'])
assert 'gpu-a100-hiram-live' not in json.loads(vm_file.read_text())['vms']

# 18b. On-demand SVD adapter compression via library.compress_adapter() on a synthetic rank-64 LoRA GGUF
import numpy as np, gguf as gguf_lib
mdir = tmp / 'models_svd'
mdir.mkdir(parents=True, exist_ok=True)
os.environ['MODELS_DIR'] = str(mdir)
src_gguf = mdir / 'test-rank64-lora-F16.gguf'
w = gguf_lib.GGUFWriter(str(src_gguf), arch='qwen2')
w.add_string('general.type', 'adapter')
w.add_string('adapter.type', 'lora')
w.add_float32('adapter.lora.alpha', 128.0)
rng = np.random.default_rng(42)
# Rank 64 LoRA matrices (A: [64, 128], B: [128, 64])
w.add_tensor('blk.0.attn_q.weight.lora_a', rng.standard_normal((64, 128)).astype(np.float32))
w.add_tensor('blk.0.attn_q.weight.lora_b', rng.standard_normal((128, 64)).astype(np.float32))
w.write_header_to_file(); w.write_kv_data_to_file(); w.write_tensors_to_file(); w.close()

comp = library.compress_adapter('test-rank64-lora-F16.gguf', target_rank=16)
assert comp['status'] == 'ok', comp
assert comp['target_rank'] == 16 and comp['output_bytes'] < comp['source_bytes'], comp
assert (mdir / comp['output_file']).is_file() and (mdir / (comp['output_file'] + '.sha256')).is_file()

# Verify backup_artifacts slug inference + rank validation
assert backup_artifacts._infer_model_slug_from_repo('harness-hub/Qwen3.8-27B-super-adapter-GGUF') == 'qwen3.8-27b'
bad_r = backup_artifacts.pull_hf_adapter('harness-hub/Qwen3.8-27B-super-adapter-GGUF', compress_svd=999, dry_run=True)
assert bad_r['status'] == 'error', bad_r
print('OK')
" 2>&1 | tail -n 1)
if [ "$MN_SVD_OUT" = "OK" ]; then
    pass "Multi-node Colab _active_vms.json ownership (peer_active vs peer_stale vs orphaned) & on-demand SVD adapter compression work"
else
    fail "Multi-node VM ownership / SVD compression test failed: $MN_SVD_OUT"
fi

# Test 19: Colab detached launch (no silent pip -q hang, bash -n syntax valid) & llama.cpp --no-cone sparse checkout
COLAB_FIX_OUT=$("$PY" -B -c "
import ast, re, subprocess, sys
sys.path.insert(0, '$LODGE_DIR/scripts/training')
import runs

v = {
    'name': 'test-run',
    'hyper': {'use_unsloth': True},
    'colab': {'drive_checkpoints': True, 'drive_checkpoint_sync': True, 'drive_checkpoint_keep': 2, 'export_gguf_on_colab': True},
}
py_src = runs._build_colab_launch_py(v, 'bl-test-run-sft', '/content/bl-test-run-sft', 'sft', 'hf_dummy', drive_ok=False, drive_auth_remote='/content/bl-test_auth.json')
compile(py_src, 'launch.py', 'exec')
assert 'start_new_session=True' in py_src and 'stdin=subprocess.DEVNULL' in py_src and 'close_fds=True' in py_src
assert 'pip install -q' not in py_src
assert 'pip_rc' in py_src and 'uv pip install --system' in py_src
# Extract shell_cmd string literal and verify bash -n syntax
tree = ast.parse(py_src)
shell_cmd = None
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'cmd' for t in node.targets):
        shell_cmd = ast.literal_eval(node.value)
assert shell_cmd and 'train_lora.py' in shell_cmd
r = subprocess.run(['bash', '-n', '-c', shell_cmd], capture_output=True, text=True)
assert r.returncode == 0, r.stderr
kit_src = open('$LODGE_DIR/scripts/training/kit/train_lora.py', encoding='utf-8').read()
assert '\"sparse-checkout\", \"set\", \"--no-cone\"' in kit_src
print('OK')
" 2>&1 | tail -n 1)
if [ "$COLAB_FIX_OUT" = "OK" ]; then
    pass "Colab detached launch (streaming uv/pip, zero SIGPIPE, valid bash -n) & --no-cone GGUF sparse checkout verified"
else
    fail "Colab launch/sparse-checkout regression test failed: $COLAB_FIX_OUT"
fi

echo "──────────────────────────────────────"
echo "  ${PASS} passed, ${FAIL} failed ($((PASS + FAIL)) total)"
[ "$FAIL" -eq 0 ]
