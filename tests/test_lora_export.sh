#!/usr/bin/env bash
# LoRA dataset export: format, split, redaction (refinement ops task)
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR
PY="$LODGE_DIR/.venv/bin/python"; [ -x "$PY" ] || PY=python3
EXP="$LODGE_DIR/scripts/training/export_lora_dataset.py"

test_start "lora_export"
assert_file_exists "$EXP"

G="$GEORGE_DIR"
echo 'SERPER_API_KEY=supersecretvalue123456' > "$G/keys.conf"
# good ledger run
mkdir -p "$G/runs/session_good" "$G/workspaces/session_good"
cat > "$G/runs/session_good/run.json" <<EOF
{"session_id":"session_good","status":"FINISHED","outcome":"SUCCESS","labels":[],"type":"discord","started_epoch":$(date +%s),"workspace":"$G/workspaces/session_good"}
EOF
cat > "$G/runs/session_good/messages.json" <<'EOF'
[{"role":"system","content":"You ARE George."},
 {"role":"user","content":"Look up X. my password is hunter22 and key supersecretvalue123456, user 100000000000000004"},
 {"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"X\"}"}}]},
 {"role":"tool","tool_call_id":"c1","content":"result about X"},
 {"role":"assistant","content":"X is a thing."}]
EOF
echo '{"tools":[{"type":"function","function":{"name":"web_search","parameters":{}}}]}' > "$G/workspaces/session_good/payload_turn_1.json"
# second good run so the split has both sides
mkdir -p "$G/runs/session_good2"
echo "{\"session_id\":\"session_good2\",\"status\":\"FINISHED\",\"outcome\":\"SUCCESS\",\"labels\":[],\"started_epoch\":$(date +%s)}" > "$G/runs/session_good2/run.json"
echo '[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]' > "$G/runs/session_good2/messages.json"
# failed run + labelled-bad run
mkdir -p "$G/runs/session_loop" "$G/runs/session_badlabel"
echo "{\"session_id\":\"session_loop\",\"status\":\"FINISHED\",\"outcome\":\"LOOP\",\"labels\":[],\"started_epoch\":$(date +%s)}" > "$G/runs/session_loop/run.json"
echo '[{"role":"user","content":"loop"},{"role":"assistant","content":"again"}]' > "$G/runs/session_loop/messages.json"
echo "{\"session_id\":\"session_badlabel\",\"status\":\"FINISHED\",\"outcome\":\"SUCCESS\",\"labels\":[{\"label\":\"wrong\"}],\"started_epoch\":$(date +%s)}" > "$G/runs/session_badlabel/run.json"
echo '[{"role":"user","content":"q"},{"role":"assistant","content":"wrong answer"}]' > "$G/runs/session_badlabel/messages.json"
# step log
mkdir -p "$G/transcripts"
echo '{"timestamp":"2026-10-01T00:00:00Z","instruction":"weather?","thinking":"search it","action":"web_search({\"query\":\"weather\"})","observation":"sunny"}' > "$G/transcripts/trajectories.jsonl"
# markdown transcript + prompts log (survives workspace culling)
cat > "$G/transcripts/2026-10-04_10-00-00.md" <<'EOF'
# Task Transcript

**Task:** What is UNH trading at?
**Started:** 2026-10-04 10:00:00 CDT

---

`10:00:05` **thought:**
```
I should fetch a quote.
```

`10:00:06` **tool_call:** web_fetch: {"url": "https://example.com/unh"}
<details>
<summary>`10:00:07` ⚡ <b>Tool Execution:</b> <code>web_fetch</code> — SUCCESS (12ms,1 KB)</summary>

**Call ID:** `tcall_1`

**Arguments:**
```json
{"url": "https://example.com/unh"}
```

**Observation:**
```markdown
UNH closed at 371.90
```
inner fence above must not end the block
```

</details>

`10:00:09` **final_response:**
```
UNH last closed at **371.90**.
```

**Ended:** 2026-10-04 10:00:10 CDT
EOF
cat > "$G/transcripts/2026-10-04_10-00-00_prompts.md" <<'EOF'
# Task Prompts Log

`10:00:01` **prompt-injection (react-turn-1):**
<details>
<summary>System Prompt</summary>

```
You ARE George (transcript system prompt).
```
</details>
<details>
<summary>User Prompt</summary>

```
What is UNH trading at? (full user prompt)
```
</details>
EOF
OUT="$GEORGE_TEST_SANDBOX/ds"
res=$("$PY" "$EXP" --george-dir "$G" --out "$OUT" --val-frac 0.5 2>&1)
assert_eq "$?" "0" "exporter exits 0"

describe "files + split"
for f in train.jsonl val.jsonl negatives.jsonl steps.jsonl episodes_all.jsonl manifest.json README.md; do assert_file_exists "$OUT/$f"; done
assert_eq "$(jq -r '.episodes' "$OUT/manifest.json")" "5"
assert_eq "$(( $(wc -l < "$OUT/train.jsonl") + $(wc -l < "$OUT/val.jsonl") ))" "3" "only SUCCESS w/o bad labels in SFT"
assert_eq "$(wc -l < "$OUT/negatives.jsonl" | tr -d ' ')" "2" "LOOP + wrong-labelled go to negatives"
assert_eq "$(wc -l < "$OUT/steps.jsonl" | tr -d ' ')" "1"
assert_eq "$(jq -r '.messages[1].tool_calls[0].function.name' "$OUT/steps.jsonl")" "web_search"

describe "transcript source"
tr_row=$(cat "$OUT/train.jsonl" "$OUT/val.jsonl" | grep -F 'transcript system prompt')
assert_eq "$(printf '%s' "$tr_row" | jq -r '[.messages[].role] | join(",")')" "system,user,assistant,tool,assistant" "episode shape"
assert_eq "$(printf '%s' "$tr_row" | jq -r '.messages[1].content')" "What is UNH trading at? (full user prompt)" "user prompt from prompts log"
assert_eq "$(printf '%s' "$tr_row" | jq -r '.messages[2].tool_calls[0].function.name')" "web_fetch"
assert_eq "$(printf '%s' "$tr_row" | jq -r '.messages[2].reasoning_content')" "I should fetch a quote."
assert_contains "$(printf '%s' "$tr_row" | jq -r '.messages[3].content')" "inner fence above must not end the block" "observation keeps nested fences"
assert_eq "$(printf '%s' "$tr_row" | jq -r '.messages[4].content')" "UNH last closed at **371.90**."

describe "format"
row=$(cat "$OUT/train.jsonl" "$OUT/val.jsonl" | grep -F 'X is a thing')
assert_eq "$(printf '%s' "$row" | jq -r 'keys | join(",")')" "messages,tools"
assert_eq "$(printf '%s' "$row" | jq -r '.tools[0].function.name')" "web_search"
assert_eq "$(printf '%s' "$row" | jq -r '.messages[2].tool_calls[0].function.arguments')" '{"query":"X"}'

describe "redaction"
all=$(cat "$OUT"/*.jsonl)
assert_not_contains "$all" "supersecretvalue123456"
assert_not_contains "$all" "hunter22"
assert_not_contains "$all" "100000000000000004"
assert_contains "$all" "<USER_ID_1>"
assert_contains "$all" "<REDACTED_SECRET>"

test_end
