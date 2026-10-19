#!/usr/bin/env bash
# Dataset Forge: recipes over real-shaped episodes, curricula intake, benchmark contamination guard,
# no-duplicate padding, session-disjoint split, hub validation. Hermetic (no LLM, no network).
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR

test_start "dataset forge"

S="$GEORGE_TEST_SANDBOX/forge"; G="$S/g"; D="$S/data"
mkdir -p "$G/runs" "$D/training/active" "$D/gpqa"
python3 - "$G" "$D" <<'EOF'
import json, os, sys
g, d = sys.argv[1], sys.argv[2]
def call(cid, name, args):
    return {"role": "assistant", "content": "", "tool_calls": [{"id": cid, "type": "function",
            "function": {"name": name, "arguments": json.dumps(args)}}]}
def tool(cid, name, out):
    return {"role": "tool", "tool_call_id": cid, "name": name, "content": out}
for i in range(6):
    msgs = [{"role": "system", "content": "You are George."},
            {"role": "user", "content": f"Task number {i}: summarise the release notes for project alpha{i}"},
            call("c1", "web_fetch", {"url": f"https://example.org/{i}"}),
            tool("c1", "web_fetch", "ERROR: FETCH FAILED 404"),
            call("c2", "web_search", {"query": f"alpha{i} release notes"}),
            tool("c2", "web_search", "1. alpha release notes ..."),
            call("c3", "file_read", {"path": f"notes{i}.md"}),
            tool("c3", "file_read", "notes body"),
            call("c4", "file_read", {"path": f"notes{i}.md"}),
            tool("c4", "file_read", "notes body"),
            call("c5", "bash_exec", {"command": f"git commit -m 'notes {i}'"}),
            tool("c5", "bash_exec", "[main abc] notes"),
            {"role": "assistant", "content": f"Alpha{i} release notes: faster, smaller."}]
    rd = os.path.join(g, "runs", f"r{i}")
    os.makedirs(rd, exist_ok=True)
    json.dump({"session_id": f"sess_{i}", "outcome": "SUCCESS", "started_epoch": 1, "labels": []},
              open(os.path.join(rd, "run.json"), "w"))
    json.dump(msgs, open(os.path.join(rd, "messages.json"), "w"))
bench_q = ("Two quantum states with energies E1 and E2 have a lifetime of ten to the minus nine seconds and "
           "ten to the minus eight seconds respectively which energy difference lets us resolve them clearly")
json.dump([{"problem": bench_q, "solution": "D"}], open(os.path.join(d, "gpqa", "gpqa_diamond.json"), "w"))
with open(os.path.join(d, "training", "curriculum_fileops.jsonl"), "w") as f:
    for k in range(5):  # same prompt five times -> capped at 2
        f.write(json.dumps({"prompt": "Append a line to the changelog file safely", "domain": "fileops",
                            "expected_call": {"name": "file_append", "arguments": {"path": "CHANGELOG.md", "content": f"v{k}"}}}) + "\n")
    f.write(json.dumps({"prompt": "Please answer: " + bench_q, "domain": "fileops",
                        "expected_call": {"name": "file_read", "arguments": {"path": "x"}}}) + "\n")
with open(os.path.join(d, "training", "curriculum_gpqa_diamond.jsonl"), "w") as f:
    f.write(json.dumps({"prompt": bench_q, "answer_key": "D"}) + "\n")
EOF

F() { env -u GEORGE_DIR timeout 120 python3 "$LODGE_DIR/scripts/training/forge.py" --george-dir "$G" --data-dir "$D" "$@" 2>"$S/err.log" | tail -1; }

describe "pantry and recipes"
p=$(F pantry --json)
assert_gt "$(jq '.recipes_available["error-recovery"]' <<<"$p")" 0 "error-recovery samples found"
assert_gt "$(jq '.recipes_available["failure-modes"]' <<<"$p")" 0 "loop samples found"
assert_gt "$(jq '.recipes_available["gitops"]' <<<"$p")" 0 "git step counted as ops"
assert_contains "$(jq -c '.curricula_skipped_eval_only' <<<"$p")" "curriculum_gpqa_diamond" "benchmark copy marked eval-only"
assert_eq "$(F recipes --json | jq -r 'keys | length')" "7" "seven recipes"

describe "build: focus, provenance, no padding, session split"
b=$(F build --focus error-recovery,failure-modes --count 500 --out "$S/o1" --json)
assert_eq "$(jq -r '.produced + .shortfall' <<<"$b")" "500" "shortfall reported instead of padding"
assert_gt "$(jq -r '.shortfall' <<<"$b")" 0
n_rows=$(wc -l < "$S/o1/dpo_train.jsonl"); n_uniq=$(sort -u "$S/o1/dpo_train.jsonl" | wc -l)
assert_eq "$n_rows" "$n_uniq" "no duplicate rows"
assert_eq "$(jq -s '[.[] | select((.chosen|tojson) == (.rejected|tojson))] | length' "$S/o1/dpo_train.jsonl")" "0" "chosen != rejected"
rej=$(jq -r 'select(.prompt[-1].role=="tool" and (.prompt[-1].content|test("FETCH FAILED"))) | .rejected[0].tool_calls[0].function.name' "$S/o1/dpo_train.jsonl" | head -1)
assert_eq "$rej" "web_fetch" "error-recovery rejects the identical failing retry"
assert_file_exists "$S/o1/preview.md"
assert_file_exists "$S/o1/README.md"
assert_contains "$(cat "$S/o1/README.md")" "error-recovery" "README carries the lesson"
tr=$(jq -r 'select(.split=="train") | .session' "$S/o1/samples_meta.jsonl" | sort -u)
va=$(jq -r 'select(.split=="val") | .session' "$S/o1/samples_meta.jsonl" | sort -u)
assert_eq "$(comm -12 <(echo "$tr") <(echo "$va") | grep -c .)" "0" "train/val sessions are disjoint"

describe "curricula from data/ + benchmark guard"
b2=$(F build --focus gitops,tool-syntax --count 200 --curricula-only --out "$S/o2" --json)
assert_eq "$(jq -r '.curricula.unique_prompts' <<<"$b2")" "2" "curriculum prompts deduped"
assert_eq "$(jq -r '[.curricula.files[]] | map(.kept) | add' <<<"$b2")" "3" "per-prompt cap (2) applied"
assert_eq "$(jq -r '.bench_guard.dropped' <<<"$b2")" "1" "benchmark-overlapping row dropped"
assert_not_contains "$(cat "$S/o2"/*.jsonl)" "quantum states" "benchmark text never reaches the dataset"
a=$(env -u GEORGE_DIR python3 "$LODGE_DIR/scripts/training/forge.py" --data-dir "$D" audit --json | tail -1)
assert_eq "$(jq -r '.files[] | select(.file=="training/curriculum_gpqa_diamond.jsonl") | .bench_overlap' <<<"$a")" "1" "audit flags contamination"
assert_eq "$(jq -r '.files[] | select(.file=="gpqa/gpqa_diamond.json") | .kind' <<<"$a")" "benchmark"

describe "hub wrapper validation"
MH() { GEORGE_DIR="$G" timeout 60 python3 "$LODGE_DIR/lib/tools/model_hub_cli.py" "$@" 2>>"$S/err.log"; }
assert_contains "$(MH forge-build <<<'{"focus":"../etc","count":5}')" "focus" "focus validated"
assert_contains "$(MH forge-build <<<'{"focus":"mix","count":0}')" "count" "count validated"
assert_contains "$(MH forge-build <<<'{"focus":"mix","count":5,"format":"x"}')" "format" "format validated"

test_end
