#!/usr/bin/env python3
"""Export George ReAct trajectories as a Colab-ready LoRA dataset.

Output (consumed by scripts/training/forge.py and the kit in scripts/training/kit/):
  train.jsonl / val.jsonl   {"messages": [...], "tools": [...]}   (SUCCESS-quality episodes)
  episodes_all.jsonl        every episode + "meta" (outcome, labels, eval score, source)
  negatives.jsonl           failed/stalled/looping episodes (DPO / analysis, never SFT)
  steps.jsonl               step-level (instruction → thinking → tool call) samples
  manifest.json, README.md  counts, provenance, Colab snippet

Sources (all optional, read-only):
  $GEORGE_DIR/runs/<id>/{run.json,messages.json}      run ledger (P1/1.7) — preferred
  $GEORGE_DIR/workspaces/<id>/{messages.json,...}     legacy workspaces
  $GEORGE_DIR/eval/<run>/<task>/ + metrics.json       golden eval (scores → labels)
  $GEORGE_DIR/transcripts/trajectories.jsonl          step log

Redaction: literal values from keys.conf / *.env / secrets files, common token
regexes, "password: x" phrases, Discord snowflake ids → <USER_ID_n>.

Usage: export_lora_dataset.py [--george-dir DIR] [--out DIR] [--val-frac 0.1]
                              [--max-obs 6000] [--since YYYY-MM-DD]
"""
import argparse
import datetime as dt
import glob
import hashlib
import json
import gzip
import os
import random
import re
import sys

GOOD = {"SUCCESS"}
BAD = {"STALL", "LOOP", "TOOL_FAIL", "INJECTION_BLOCKED", "MISALIGNED", "ABORTED", "MAX_TURNS", "TIMEOUT"}

# (pattern, keep_group_1_as_prefix)
TOKEN_PATTERNS = [
    (re.compile(r"\bsk-[A-Za-z0-9_-]{16,}"), False),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), False),
    (re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}"), False),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{30,}"), False),
    (re.compile(r"\b[MN][A-Za-z\d]{23,25}\.[\w-]{6}\.[\w-]{27,}"), False),          # discord bot token
    (re.compile(r"(?i)\b(bearer\s+)[A-Za-z0-9._~+/-]{16,}=*"), True),
    (re.compile(r"(?i)\b((?:api[_-]?key|token|secret|passw(?:or)?d|pwd)\s*[:=]\s*)['\"]?[^\s'\",]{4,}"), True),
    (re.compile(r"(?i)\b(password\s+(?:is\s+)?)\S{4,}"), True),
]
SNOWFLAKE = re.compile(r"(?<!\d)(\d{17,20})(?!\d)")


class Redactor:
    def __init__(self, george_dir):
        self.literals = set()
        self.ids = {}
        cands = [os.path.join(george_dir, "keys.conf")] + glob.glob(os.path.join(george_dir, "*.env")) \
            + glob.glob(os.path.join(george_dir, "secrets", "*")) + [os.path.join(os.path.dirname(george_dir), ".env")]
        for p in cands:
            try:
                with open(p, encoding="utf-8", errors="ignore") as fh:
                    for line in fh:
                        if "=" not in line or line.lstrip().startswith("#"):
                            continue
                        v = line.split("=", 1)[1].strip().strip("'\"")
                        if len(v) >= 8 and not v.isdigit() and v.lower() not in ("true", "false"):
                            self.literals.add(v)
            except OSError:
                continue
        self.n = 0

    def _uid(self, m):
        k = m.group(1)
        if k not in self.ids:
            self.ids[k] = "<USER_ID_%d>" % (len(self.ids) + 1)
        return self.ids[k]

    def __call__(self, text):
        if not isinstance(text, str) or not text:
            return text
        out = text
        for lit in self.literals:
            if lit in out:
                out = out.replace(lit, "<REDACTED_SECRET>")
        for pat, keep in TOKEN_PATTERNS:
            out = pat.sub((lambda m: m.group(1) + "<REDACTED_SECRET>") if keep else "<REDACTED_SECRET>", out)
        out = SNOWFLAKE.sub(self._uid, out)
        if out != text:
            self.n += 1
        return out


def _load_json(p, default=None):
    try:
        with open(p, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def clean_messages(msgs, red, max_obs):
    """Normalise OpenAI-style messages; redact; truncate tool observations; drop empties."""
    out = []
    for m in msgs or []:
        if not isinstance(m, dict) or m.get("role") not in ("system", "user", "assistant", "tool"):
            continue
        n = {"role": m["role"]}
        c = m.get("content")
        if isinstance(c, list):
            c = "\n".join(x.get("text", "") for x in c if isinstance(x, dict))
        if isinstance(c, str):
            c = red(c)
            if m["role"] == "tool" and len(c) > max_obs:
                c = c[:max_obs] + "\n…[truncated %d chars]" % (len(c) - max_obs)
        n["content"] = c if c is not None else ""
        if m.get("reasoning_content"):
            n["reasoning_content"] = red(m["reasoning_content"])
        if m.get("tool_calls"):
            tcs = []
            for tc in m["tool_calls"]:
                f = (tc or {}).get("function") or {}
                args = f.get("arguments", "")
                tcs.append({"id": tc.get("id") or "call_%d" % len(tcs), "type": "function",
                            "function": {"name": f.get("name", ""), "arguments": red(args if isinstance(args, str) else json.dumps(args))}})
            n["tool_calls"] = tcs
        if m["role"] == "tool":
            n["tool_call_id"] = m.get("tool_call_id") or ""
            if m.get("name"):
                n["name"] = m["name"]
        if m["role"] == "assistant" and not n["content"] and not n.get("tool_calls") and not n.get("reasoning_content"):
            continue
        out.append(n)
    return out


def tools_for(ws):
    """Tool schema the model actually saw (first payload)."""
    for name in ("payload_turn_1.json", "payload_turn_2.json"):
        p = _load_json(os.path.join(ws, name)) if ws else None
        if isinstance(p, dict) and isinstance(p.get("tools"), list):
            return p["tools"]
    return []


def infer_ws_outcome(ws):
    status = (_load_json(os.path.join(ws, "macro_memory.json"), {}) or {}).get("status", "")
    has_reply = os.path.exists(os.path.join(ws, "final_reply.txt"))
    return {"COMPLETED": "SUCCESS", "CIRCUIT_BREAKER_TRIPPED": "LOOP", "CAPABILITY_EXHAUSTED": "TOOL_FAIL",
            "TURN_CEILING_PRESERVED": "MAX_TURNS"}.get(status, "SUCCESS" if has_reply else "ABORTED")


def eval_scores(george_dir):
    """session prefix → {task, score, passed} from golden eval metrics.json files."""
    scores = {}
    for mpath in glob.glob(os.path.join(george_dir, "eval", "*", "metrics.json")):
        m = _load_json(mpath, {}) or {}
        run = os.path.basename(os.path.dirname(mpath))
        for t in m.get("tasks", []) if isinstance(m.get("tasks"), list) else []:
            scores[(run, t.get("id"))] = t
    return scores


TS_EVENT = re.compile(r"^`(\d\d:\d\d:\d\d)` \*\*([a-z_ ()0-9-]+):\*\*\s*(.*)$")


def _read_text(path):
    try:
        if path.endswith(".gz"):
            with gzip.open(path, "rt", encoding="utf-8", errors="ignore") as fh:
                return fh.read()
        with open(path, encoding="utf-8", errors="ignore") as fh:
            return fh.read()
    except OSError:
        return ""


def _fence_block(lines, i):
    """lines[i] is an opening fence; return (content, index after closing fence)."""
    j = i + 1
    buf = []
    while j < len(lines):
        if lines[j].rstrip() == "```" and (j + 1 >= len(lines) or lines[j + 1].strip() == ""
                                          or lines[j + 1].startswith("`") or lines[j + 1].startswith("---")):
            return "\n".join(buf), j + 1
        buf.append(lines[j])
        j += 1
    return "\n".join(buf), j


def _first_prompt_block(prompts_text, summary):
    m = re.search(r"<summary>" + re.escape(summary) + r"</summary>\s*\n\s*```[a-z]*\n", prompts_text)
    if not m:
        return ""
    rest = prompts_text[m.end():]
    end = re.search(r"\n```\s*\n\s*</details>", rest)
    return rest[:end.start()] if end else ""


def parse_transcript(path):
    """Rebuild an OpenAI-style episode from a George markdown transcript
    (+ sibling *_prompts.md for the exact turn-1 system/user prompt).
    Returns (messages, outcome) or (None, None)."""
    text = _read_text(path)
    if "# Task Transcript" not in text[:200]:
        return None, None
    base = re.sub(r"\.md(\.gz)?$", "", path)
    prompts = _read_text(base + "_prompts.md") or _read_text(base + "_prompts.md.gz")
    system = _first_prompt_block(prompts, "System Prompt") if prompts else ""
    user = _first_prompt_block(prompts, "User Prompt") if prompts else ""
    if not user:
        m = re.search(r"\*\*Task:\*\* (.*?)\n\*\*Started:\*\*", text, re.S)
        user = m.group(1).replace("\\n", "\n").strip() if m else ""
    if not user:
        return None, None
    msgs = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": user}]
    lines = text.split("\n")
    thoughts, final, i, n_calls = [], None, 0, 0
    while i < len(lines):
        ln = lines[i]
        ev = TS_EVENT.match(ln)
        if ev and ev.group(2) in ("thought", "final_response") and i + 1 < len(lines) and lines[i + 1].startswith("```"):
            body, i = _fence_block(lines, i + 1)
            if ev.group(2) == "thought":
                thoughts.append(body.strip())
            else:
                final = body.strip()
            continue
        if ln.strip() == "<details>" and i + 1 < len(lines) and "Tool Execution:" in lines[i + 1]:
            card_end = i + 1
            while card_end < len(lines) and lines[card_end].strip() != "</details>":
                card_end += 1
            card = lines[i:card_end]
            name_m = re.search(r"<code>([^<]+)</code>", card[1])
            cid_m = next((re.search(r"`([^`]+)`", c) for c in card if c.startswith("**Call ID:**")), None)
            args, obs = "{}", ""
            for k, c in enumerate(card):
                if c.startswith("**Arguments:**") and k + 1 < len(card) and card[k + 1].startswith("```"):
                    a_end = k + 2
                    while a_end < len(card) and card[a_end].rstrip() != "```":
                        a_end += 1
                    args = "\n".join(card[k + 2:a_end]).strip() or "{}"
                if c.startswith("**Observation:**") and k + 1 < len(card) and card[k + 1].startswith("```"):
                    last = max((x for x in range(k + 2, len(card)) if card[x].rstrip() == "```"), default=len(card))
                    obs = "\n".join(card[k + 2:last])
            if name_m:
                cid = (cid_m.group(1) if cid_m else "call_%d" % n_calls)
                n_calls += 1
                msgs.append({"role": "assistant", "content": "", "reasoning_content": "\n\n".join(thoughts),
                             "tool_calls": [{"id": cid, "type": "function",
                                             "function": {"name": name_m.group(1), "arguments": args}}]})
                msgs.append({"role": "tool", "tool_call_id": cid, "name": name_m.group(1), "content": obs})
                thoughts = []
            i = card_end + 1
            continue
        i += 1
    if final:
        msgs.append({"role": "assistant", "content": final, "reasoning_content": "\n\n".join(thoughts)})
        outcome = "SUCCESS"
    elif "CIRCUIT BREAKER TRIPPED" in text or "CIRCUIT_BREAKER_TRIPPED" in text:
        outcome = "LOOP"
    elif "Hard capability ceiling" in text:
        outcome = "TOOL_FAIL"
    elif "**Ended:**" in text:
        outcome = "MAX_TURNS" if re.search(r"Turn (\d+) / \1\b", text) else "ABORTED"
    else:
        outcome = "ABORTED"
    return msgs, outcome


def collect(args):
    gd = args.george_dir
    red = Redactor(gd)
    since = dt.datetime.strptime(args.since, "%Y-%m-%d").timestamp() if args.since else 0
    episodes, seen = [], set()

    def add(sid, msgs, tools, meta):
        msgs = clean_messages(msgs, red, args.max_obs)
        if sum(1 for m in msgs if m["role"] == "assistant") == 0:
            return
        digest = hashlib.sha1(json.dumps(msgs[:6], sort_keys=True).encode()).hexdigest()
        if sid in seen or digest in seen:
            return
        seen.update((sid, digest))
        meta["session_id"] = sid
        meta["n_turns"] = sum(1 for m in msgs if m["role"] == "assistant")
        episodes.append({"messages": msgs, "tools": tools, "meta": meta})

    # 1. Run ledger
    for rj in sorted(glob.glob(os.path.join(gd, "runs", "*", "run.json"))):
        run = _load_json(rj, {}) or {}
        d = os.path.dirname(rj)
        if run.get("started_epoch", 0) < since:
            continue
        msgs = _load_json(os.path.join(d, "messages.json"))
        if not msgs:
            continue
        labels = [l.get("label") for l in run.get("labels", []) if isinstance(l, dict)]
        add(run.get("session_id") or os.path.basename(d), msgs, tools_for(run.get("workspace")),
            {"source": "run_ledger", "outcome": run.get("outcome"), "labels": labels, "type": run.get("type"),
             "model": run.get("model"), "ts": run.get("started_at")})

    # 2. Legacy workspaces
    for ws in sorted(glob.glob(os.path.join(gd, "workspaces", "*", ""))):
        ws = ws.rstrip("/")
        mp = os.path.join(ws, "messages.json")
        if not os.path.exists(mp) or os.path.getmtime(mp) < since:
            continue
        sid = os.path.basename(ws)
        meta = {"source": "workspace", "outcome": infer_ws_outcome(ws), "labels": [],
                "type": (_load_json(os.path.join(ws, "task_meta.json"), {}) or {}).get("type"),
                "ts": dt.datetime.fromtimestamp(os.path.getmtime(mp), dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
        if sid.startswith("discord_000000000000000001_"):
            meta["source"] = "golden_eval"
        add(sid, _load_json(mp), tools_for(ws), meta)

    # 2b. Markdown transcripts (+ *_prompts.md) — survives workspace culling
    finals = {(next((m["content"] for m in reversed(e["messages"]) if m["role"] == "assistant" and m["content"]), "") or "")[:200]
              for e in episodes}
    for tp in sorted(glob.glob(os.path.join(gd, "transcripts", "*.md")) + glob.glob(os.path.join(gd, "transcripts", "*.md.gz"))):
        if "_prompts.md" in tp or os.path.getmtime(tp) < since:
            continue
        msgs, outcome = parse_transcript(tp)
        if not msgs:
            continue
        fin = next((m["content"] for m in reversed(msgs) if m["role"] == "assistant" and m["content"]), "")
        if fin and fin[:200] in finals:
            continue
        finals.add(fin[:200])
        sid = "transcript_" + re.sub(r"\.md(\.gz)?$", "", os.path.basename(tp))
        add(sid, msgs, [], {"source": "transcript", "outcome": outcome, "labels": [],
                            "ts": dt.datetime.fromtimestamp(os.path.getmtime(tp), dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})

    # 3. Golden eval scores → labels (joined on reply text when session ids are unknown)
    scores = eval_scores(gd)
    for (run, tid), t in scores.items():
        reply = os.path.join(gd, "eval", run, tid, "reply.txt")
        try:
            rtxt = red(open(reply, encoding="utf-8").read().strip())[:200]
        except OSError:
            continue
        for ep in episodes:
            last = next((m["content"] for m in reversed(ep["messages"]) if m["role"] == "assistant" and m["content"]), "")
            if rtxt and rtxt[:120] in (last or ""):
                ep["meta"].update({"eval_run": run, "eval_task": tid, "eval_outcome": t.get("outcome"),
                                   "eval_pass": t.get("outcome") in ("SUCCESS", "INJECTION_BLOCKED")})

    # 4. Step log
    steps = []
    tj = os.path.join(gd, "transcripts", "trajectories.jsonl")
    if os.path.exists(tj):
        with open(tj, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                ts = r.get("timestamp", "")
                try:
                    if since and dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").timestamp() < since:
                        continue
                except ValueError:
                    pass
                act = r.get("action") or ""
                mm = re.match(r"^([a-z_]+)\((.*)\)$", act, re.S)
                if not mm:
                    continue
                obs = red(r.get("observation") or "")
                steps.append({"messages": [
                    {"role": "user", "content": red(r.get("instruction") or "")},
                    {"role": "assistant", "content": "", "reasoning_content": red(r.get("thinking") or ""),
                     "tool_calls": [{"id": "call_0", "type": "function",
                                     "function": {"name": mm.group(1), "arguments": red(mm.group(2))}}]},
                    {"role": "tool", "tool_call_id": "call_0", "name": mm.group(1),
                     "content": obs[:args.max_obs]}],
                    "meta": {"source": "step_log", "ts": ts, "tool": mm.group(1),
                             "obs_error": bool(re.search(r"ERROR|Traceback|FETCH FAILED|not found", obs[:2000]))}})
    return episodes, steps, red


def is_good(ep):
    m = ep["meta"]
    if "bad" in (m.get("labels") or []) or "wrong" in (m.get("labels") or []) or "unsafe" in (m.get("labels") or []):
        return False
    if m.get("eval_pass") is False:
        return False
    if m.get("eval_pass") is True:
        return True
    return m.get("outcome") in GOOD


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    lodge = os.environ.get("LODGE_DIR", os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
    ap.add_argument("--george-dir", default=os.environ.get("GEORGE_DIR", os.path.join(lodge, ".george")))
    ap.add_argument("--out", default=None)
    ap.add_argument("--val-frac", type=float, default=0.1)
    ap.add_argument("--max-obs", type=int, default=6000)
    ap.add_argument("--since", default=None)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    out = args.out or os.path.join(args.george_dir, "datasets", "lora_" + dt.datetime.now().strftime("%Y%m%d_%H%M%S"))
    os.makedirs(out, exist_ok=True)

    episodes, steps, red = collect(args)
    good = [e for e in episodes if is_good(e)]
    bad = [e for e in episodes if not is_good(e)]
    rnd = random.Random(args.seed)
    rnd.shuffle(good)
    # golden-eval episodes go to validation first so val measures the benchmark tasks
    good.sort(key=lambda e: 0 if e["meta"].get("source") == "golden_eval" else 1)
    n_val = max(1, int(round(len(good) * args.val_frac))) if len(good) >= 2 else 0
    val, train = good[:n_val], good[n_val:]

    def dump(name, rows, with_meta):
        with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
            for r in rows:
                o = {"messages": r["messages"], "tools": r.get("tools", [])}
                if with_meta:
                    o["meta"] = r["meta"]
                fh.write(json.dumps(o, ensure_ascii=False) + "\n")

    dump("train.jsonl", train, False)
    dump("val.jsonl", val, False)
    dump("episodes_all.jsonl", episodes, True)
    dump("negatives.jsonl", bad, True)
    dump("steps.jsonl", steps, True)

    outcomes = {}
    for e in episodes:
        outcomes[e["meta"].get("outcome") or "?"] = outcomes.get(e["meta"].get("outcome") or "?", 0) + 1
    manifest = {"created": dt.datetime.now().isoformat(timespec="seconds"), "george_dir": args.george_dir,
                "episodes": len(episodes), "train": len(train), "val": len(val), "negatives": len(bad),
                "steps": len(steps), "outcomes": outcomes, "redacted_fields": red.n,
                "anonymised_user_ids": len(red.ids), "max_obs_chars": args.max_obs}
    with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)
    with open(os.path.join(out, "README.md"), "w", encoding="utf-8") as fh:
        fh.write(README.format(**manifest))
    print(json.dumps({"out": out, **manifest}))
    return 0


README = """# George LoRA dataset

Created {created}. Episodes: {episodes} (train {train}, val {val}, negatives {negatives}); step samples: {steps}.
Outcomes: `{outcomes}`. Redacted fields: {redacted_fields}; anonymised Discord ids: {anonymised_user_ids}.

| File | Use |
|------|-----|
| `train.jsonl`, `val.jsonl` | SFT on successful episodes (`{{"messages", "tools"}}`, OpenAI tool-call format) |
| `negatives.jsonl` | Failed/stalled/looping runs with `meta` — rejected side for DPO/KTO, or failure analysis. **Do not SFT.** |
| `steps.jsonl` | Single tool-call steps (instruction → reasoning → call → observation) for tool-selection drills |
| `episodes_all.jsonl` | Everything plus `meta` (outcome, labels, eval score, source) |

Review before uploading: redaction is pattern-based. Grep for anything sensitive:
`grep -iE 'passw|token|secret|@gmail' *.jsonl`.

## Colab (Unsloth + TRL SFT)

```python
!pip -q install unsloth trl datasets
from unsloth import FastLanguageModel
from datasets import load_dataset
from trl import SFTTrainer, SFTConfig

BASE_MODEL = "<hf-repo-of-the-model-you-serve>"  # e.g. an Unsloth bnb-4bit repo of your base model
model, tok = FastLanguageModel.from_pretrained(BASE_MODEL, max_seq_length=16384, load_in_4bit=True)
model = FastLanguageModel.get_peft_model(model, r=32, lora_alpha=64, lora_dropout=0.0,
    target_modules=["q_proj","k_proj","v_proj","o_proj","gate_proj","up_proj","down_proj"])
ds = load_dataset("json", data_files={{"train": "train.jsonl", "validation": "val.jsonl"}})

def fmt(ex):
    return {{"text": tok.apply_chat_template(ex["messages"], tools=ex["tools"] or None, tokenize=False)}}
ds = ds.map(fmt, remove_columns=["messages", "tools"])
trainer = SFTTrainer(model=model, tokenizer=tok, train_dataset=ds["train"], eval_dataset=ds["validation"],
    args=SFTConfig(per_device_train_batch_size=1, gradient_accumulation_steps=8, num_train_epochs=2,
                   learning_rate=1e-4, max_seq_length=16384, dataset_text_field="text",
                   assistant_only_loss=True, output_dir="george_lora", logging_steps=5))
trainer.train()
model.save_pretrained("george_lora")
```

Set BASE_MODEL to the base of the model you serve (or generate a ready-made kit with
`/models train-kit` / Models -> Fine-tune). For managed multi-track runs (local GPUs or Colab, merged
to one GGUF) use scripts/training/runs.py (`/train template`, `/train run spec.json`).
"""

if __name__ == "__main__":
    sys.exit(main())
