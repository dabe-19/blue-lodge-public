#!/usr/bin/env python3
"""Dataset Forge — turn George's own task transcripts into focused fine-tuning datasets.

Every sample is cut from a real episode (run ledger, workspaces, markdown transcripts, step log)
that scripts/training/export_lora_dataset.py already knows how to parse and redact. Recipes then
reshape those episodes into lessons: "pick the right tool", "recover from an error", "break a loop",
"ignore stale context", "keep going on a multi-hop task", "write the final answer", "safe git/file ops".

Commands
  forge.py recipes                         list the recipes and what each one teaches
  forge.py pantry                          inventory of raw material in your transcripts
  forge.py build --focus F[,F...] --count N [options]
  forge.py audit [FILE_OR_DIR ...]         duplicate/uniqueness report for existing .jsonl datasets

build options
  --focus        recipe names, comma separated, or "mix" (all recipes, balanced)
  --count        target number of samples (the forge never pads with duplicates)
  --format       sft | dpo | both (default both). DPO rows only exist for recipes with a "rejected" side
  --val-frac     held-out fraction, split by *session* so no episode leaks into both sides (default 0.1)
  --augment-llm  use the local LLM to (a) write better "chosen" replies where only a template exists and
                 (b) paraphrase task prompts to fill --count when real material runs out
  --llm-url      OpenAI-compatible base URL (default: $FORGE_LLM_URL, then TIER2/TIER1_URL in endpoints.conf)
  --max-llm-calls  hard cap on LLM requests (default 200)
  --max-context  per-sample character budget; older tool turns are dropped first (default 24000)
  --drop-reasoning  strip reasoning_content from assistant turns
  --since YYYY-MM-DD, --seed N, --out DIR, --george-dir DIR

Output (default $GEORGE_DIR/datasets/forge_<focus>_<timestamp>/, visible in the Model Workbench):
  sft_train.jsonl / sft_val.jsonl    {"messages": [...], "tools": [...]}
  dpo_train.jsonl / dpo_val.jsonl    {"prompt": [...], "chosen": [...], "rejected": [...], "tools": [...]}
  samples_meta.jsonl                 recipe + provenance for every sample (transcript / mutation / template / llm)
  preview.md, manifest.json, README.md
The last stdout line of build/pantry/audit is a JSON summary.
"""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import glob
import hashlib
import json
import os
import random
import re
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import export_lora_dataset as ex  # noqa: E402

LODGE = os.environ.get("LODGE_DIR", os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
ERR_RX = re.compile(r"(?i)(\bERROR\b|Error:|Traceback|FETCH FAILED|not found|No such file|Permission denied|"
                    r"command failed|exit code [1-9]|HTTP [45]\d\d|invalid (json|argument)|timed out|refused)")
OPS_TOOL_RX = re.compile(r"^(file_(write|edit|append|delete|move)|git_\w+|gitea_\w+|code_validate)$")
SHELL_TOOLS = {"bash_exec", "sandbox_exec", "container_exec", "shell_exec", "run_command"}
SHELL_MUTATION_RX = re.compile(r"(\bgit\s|\brm\s|\bmv\s|sed\s+-i|\bmkdir\b|\bcp\s|\bpatch\b|\btee\b|[^2&]>\s*[\w./~])")
URL_RX = re.compile(r"^https?://[A-Za-z0-9.\-]+(:\d{1,5})?(/[A-Za-z0-9._~/\-]*)?$")
NAME_RX = re.compile(r"^[a-z][a-z0-9_-]{0,40}$")

RECIPES = {
    "tool-syntax": {
        "title": "Pick the right tool, call it correctly",
        "dpo": True,
        "lesson": "The model sees the task so far and must emit the exact tool call George made next. The "
                  "'rejected' side is the same call broken on purpose (wrong tool, malformed JSON, missing or "
                  "invented argument), so DPO learns what a *valid* call looks like, not just a plausible one.",
    },
    "error-recovery": {
        "title": "A tool failed — adapt instead of retrying blindly",
        "dpo": True,
        "lesson": "Cut right after a tool returned an error, where George then changed approach and succeeded. "
                  "Chosen = that recovery step. Rejected = re-sending the identical failing call, the single "
                  "most common way small agents burn their turn budget.",
    },
    "failure-modes": {
        "title": "Break the loop",
        "dpo": True,
        "lesson": "Taken from LOOP/STALL/MAX_TURNS episodes. Rejected = the repeat George *actually* made "
                  "(real failure data). Chosen = the step that later broke the loop when one exists, otherwise an "
                  "honest stop-and-report reply (template, or written by your local LLM with --augment-llm).",
    },
    "context-discrimination": {
        "title": "Answer the question that was asked, not the last one",
        "dpo": True,
        "lesson": "A successful episode gets an unrelated earlier conversation spliced in front of it (as prior "
                  "turns or a 'Recent Conversation Context' block, like the Discord bridge injects). Chosen = the "
                  "real first action for the current request; rejected = acting on the stale topic.",
    },
    "multi-hop": {
        "title": "Keep the thread across many tool calls",
        "dpo": True,
        "lesson": "Cut a long successful trajectory at step k>=2. Chosen = George's real next step, which depends "
                  "on what earlier observations revealed. Rejected = restarting with step 1 again (forgetting "
                  "progress), a classic long-context failure.",
    },
    "final-answer": {
        "title": "Turn observations into the final reply",
        "dpo": False,
        "lesson": "Full successful trajectory minus the last message; the model learns to synthesise a grounded "
                  "answer from the evidence it gathered. SFT only.",
    },
    "gitops": {
        "title": "Safe file and git operations",
        "dpo": True,
        "lesson": "Only file/git/shell steps. Where a git command is involved the rejected side is a destructive "
                  "variant (--force, reset --hard, clean -fdx); otherwise a broken call. Teaches the model that "
                  "the cautious command is preferred.",
    },
}


# ── helpers ────────────────────────────────────────────────────────────────────

def _call(m):
    tcs = m.get("tool_calls") or []
    return tcs[0]["function"] if tcs else None


def _sig(m):
    f = _call(m)
    if not f:
        return None
    a = f.get("arguments", "")
    try:
        a = json.dumps(json.loads(a), sort_keys=True)
    except (ValueError, TypeError):
        a = re.sub(r"\s+", " ", str(a)).strip()
    return f.get("name", ""), a


def _is_err(text):
    return bool(ERR_RX.search((text or "")[:1500]))


def _user_text(msgs):
    return next((m["content"] for m in msgs if m["role"] == "user" and m.get("content")), "")


def _final(msgs):
    if msgs and msgs[-1]["role"] == "assistant" and msgs[-1].get("content") and not msgs[-1].get("tool_calls"):
        return msgs[-1]
    return None


def _clone_call(m, name=None, args=None, cid="call_alt"):
    f = _call(m)
    return {"role": "assistant", "content": "", "reasoning_content": m.get("reasoning_content", ""),
            "tool_calls": [{"id": cid, "type": "function",
                            "function": {"name": name if name is not None else f["name"],
                                         "arguments": args if args is not None else f["arguments"]}}]}


def _first_action(msgs):
    return next((i for i, m in enumerate(msgs) if m["role"] == "assistant"), None)


def is_ops_call(m):
    f = _call(m)
    if not f:
        return False
    if OPS_TOOL_RX.match(f["name"]):
        return not re.search(r'"path"\s*:\s*"mem:', f.get("arguments") or "")  # scratch memory, not the repo
    return f["name"] in SHELL_TOOLS and bool(SHELL_MUTATION_RX.search(f.get("arguments") or ""))


def step_episodes(steps):
    """Regroup consecutive step-log records with the same instruction into pseudo-episodes
    (user → call → observation → call …) so recovery/loop recipes can mine them."""
    eps, cur, key = [], None, None
    for st in steps:
        u, a, t = st["messages"]
        k = (u["content"] or "")[:300]
        if k != key or cur is None or len(cur["messages"]) > 40:
            if cur and len(cur["messages"]) >= 5:
                eps.append(cur)
            cur = {"messages": [dict(u)], "tools": [],
                   "meta": {"session_id": "steps_" + (st["meta"].get("ts") or str(len(eps))), "source": "step_log",
                            "outcome": "STEPS"}}
            key = k
        cid = "call_%d" % (len(cur["messages"]) // 2)
        a2 = copy.deepcopy(a)
        a2["tool_calls"][0]["id"] = cid
        t2 = dict(t, tool_call_id=cid)
        cur["messages"] += [a2, t2]
    if cur and len(cur["messages"]) >= 5:
        eps.append(cur)
    return eps


def fit_context(prompt, budget):
    """Drop the oldest assistant/tool pairs after the first user turn until under budget."""
    def size(ms):
        return sum(len(m.get("content") or "") + len(m.get("reasoning_content") or "")
                   + sum(len(t["function"].get("arguments") or "") for t in m.get("tool_calls") or []) for m in ms)
    ms = list(prompt)
    head = next((i for i, m in enumerate(ms) if m["role"] == "user"), 0) + 1
    dropped = 0
    while size(ms) > budget and len(ms) > head + 2:
        del ms[head]
        while len(ms) > head + 1 and ms[head]["role"] == "tool":
            del ms[head]
        dropped += 1
    return ms


def mutate(m, vocab, rnd):
    """Return (rejected_message, mutation_kind) — a deliberately broken version of a tool call."""
    f = _call(m)
    kinds = ["broken_json", "invented_arg"]
    others = [v for v in vocab if v != f["name"]]
    if others:
        kinds.append("wrong_tool")
    try:
        args = json.loads(f["arguments"] or "{}")
    except ValueError:
        args = None
    if isinstance(args, dict) and args:
        kinds.append("missing_arg")
    k = rnd.choice(kinds)
    if k == "wrong_tool":
        return _clone_call(m, name=rnd.choice(others)), k
    if k == "missing_arg":
        a = dict(args)
        a.pop(rnd.choice(sorted(a)))
        return _clone_call(m, args=json.dumps(a)), k
    if k == "invented_arg":
        a = dict(args) if isinstance(args, dict) else {"input": f["arguments"]}
        a[rnd.choice(["force", "unsafe_mode", "skip_checks", "raw"])] = True
        return _clone_call(m, args=json.dumps(a)), k
    s = f["arguments"] or "{}"
    return _clone_call(m, args=s[:-1] if s.endswith("}") else s + "}"), "broken_json"


_DESTRUCT = [(re.compile(r"\bgit push\b(?!.*--force)"), "git push --force"),
             (re.compile(r"\bgit (checkout|restore) "), "git reset --hard HEAD && git clean -fdx; git \\1 "),
             (re.compile(r"\bgit commit\b"), "git add -A && git commit --no-verify"),
             (re.compile(r"\bgit pull\b"), "git fetch && git reset --hard origin/HEAD #"),
             (re.compile(r"\brm (?!-rf)"), "rm -rf ")]


def destructive(m):
    f = _call(m)
    a = f.get("arguments") or ""
    for rx, rep in _DESTRUCT:
        if rx.search(a):
            return _clone_call(m, args=rx.sub(rep, a, count=1)), "destructive_variant"
    return None, None


# ── local LLM (optional) ───────────────────────────────────────────────────────

def default_llm_url(george_dir):
    if os.environ.get("FORGE_LLM_URL"):
        return os.environ["FORGE_LLM_URL"]
    conf = {}
    try:
        with open(os.path.join(george_dir, "endpoints.conf"), encoding="utf-8") as fh:
            for line in fh:
                mm = re.match(r'^\s*(TIER[0-9]_URL)\s*=\s*"?([^"\s#]+)"?', line)
                if mm:
                    conf[mm.group(1)] = mm.group(2)
    except OSError:
        pass
    return os.environ.get("TIER2_URL") or conf.get("TIER2_URL") or os.environ.get("TIER1_URL") \
        or conf.get("TIER1_URL") or "http://127.0.0.1:8080"


PROGRESS = {"file": None}


def progress(**kw):
    """Merge kw into the Workbench job file (if --progress-file was given). Never raises."""
    f = PROGRESS["file"]
    if not f:
        return
    try:
        cur = json.loads(open(f, encoding="utf-8").read()) if os.path.exists(f) else {}
        cur.update(kw, ts=int(dt.datetime.now().timestamp()))
        tmp = f + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(cur, fh)
        os.replace(tmp, f)
    except (OSError, ValueError):
        pass


class LLM:
    def __init__(self, url, max_calls):
        if not URL_RX.match(url or ""):
            raise SystemExit("invalid --llm-url (expected http(s)://host[:port][/path])")
        self.url = url.rstrip("/")
        if not self.url.endswith("/v1"):
            self.url += "/v1"
        self.left = max_calls
        self.calls = 0
        self.failures = 0

    def ask(self, system, user, max_tokens=500, temperature=0.7):
        if self.left <= 0:
            return None
        self.left -= 1
        self.calls += 1
        progress(phase=f"local LLM call {self.calls}")
        body = json.dumps({"messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                           "temperature": temperature, "max_tokens": max_tokens, "stream": False}).encode()
        req = urllib.request.Request(self.url + "/chat/completions", data=body,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=180) as r:  # noqa: S310 — URL validated above
                out = json.loads(r.read().decode("utf-8", "replace"))
            txt = out["choices"][0]["message"].get("content") or ""
        except (urllib.error.URLError, OSError, ValueError, KeyError, IndexError, TimeoutError):
            self.failures += 1
            return None
        txt = re.sub(r"(?s)<think>.*?</think>", "", txt).strip()
        return txt or None


# ── recipes ────────────────────────────────────────────────────────────────────

def _sample(recipe, ep, prompt, chosen, rejected, provenance, budget, **extra):
    meta = {"recipe": recipe, "session": ep["meta"].get("session_id"), "source": ep["meta"].get("source"),
            "outcome": ep["meta"].get("outcome"), "provenance": provenance}
    meta.update(extra)
    return {"prompt": fit_context(prompt, budget), "chosen": chosen, "rejected": rejected,
            "tools": ep.get("tools") or [], "meta": meta}


def r_tool_syntax(eps, steps, vocab, rnd, budget, ops_only=False, recipe="tool-syntax"):
    out = []
    for ep in eps:
        ms = ep["messages"]
        for i, m in enumerate(ms):
            if m["role"] != "assistant" or not _call(m):
                continue
            if i + 1 < len(ms) and ms[i + 1]["role"] == "tool" and _is_err(ms[i + 1].get("content")):
                continue
            if ops_only and not is_ops_call(m):
                continue
            rej, kind = destructive(m) if ops_only else (None, None)
            if not rej:
                rej, kind = mutate(m, vocab, rnd)
            out.append(_sample(recipe, ep, ms[:i], m, rej, "transcript+mutation", budget, mutation=kind))
    for st in steps:
        if st["meta"].get("obs_error"):
            continue
        a = st["messages"][1]
        if ops_only and not is_ops_call(a):
            continue
        rej, kind = destructive(a) if ops_only else (None, None)
        if not rej:
            rej, kind = mutate(a, vocab, rnd)
        ep = {"meta": {"session_id": "step_" + (st["meta"].get("ts") or ""), "source": "step_log",
                       "outcome": "STEP"}, "tools": []}
        out.append(_sample(recipe, ep, st["messages"][:1], a, rej, "steplog+mutation", budget, mutation=kind))
    return out


def r_gitops(eps, steps, vocab, rnd, budget):
    return r_tool_syntax(eps, steps, vocab, rnd, budget, ops_only=True, recipe="gitops")


def r_error_recovery(eps, steps, vocab, rnd, budget):
    out = []
    for ep in eps + step_episodes(steps):
        ms = ep["messages"]
        for j in range(2, len(ms)):
            m, obs, prev = ms[j], ms[j - 1], ms[j - 2]
            if m["role"] != "assistant" or obs["role"] != "tool" or prev["role"] != "assistant":
                continue
            if not _is_err(obs.get("content")) or not _call(prev):
                continue
            if _call(m) and _sig(m) == _sig(prev):
                continue  # the model *did* retry blindly: that belongs to failure-modes
            if _call(m) and j + 1 < len(ms) and ms[j + 1]["role"] == "tool" and _is_err(ms[j + 1].get("content")):
                continue  # recovery attempt also failed
            out.append(_sample("error-recovery", ep, ms[:j], m, _clone_call(prev, cid="call_retry"),
                               "transcript", budget, mutation="identical_retry"))
    return out


STOP_TEMPLATE = ("I've now called `{tool}` {n} times with the same arguments and the result isn't changing, so "
                 "retrying won't help. Here's where things stand:\n\n{status}\n\nI'll stop here rather than loop. "
                 "If you'd like, I can try a different approach (another source, tool, or a narrower request).")


def r_failure_modes(eps, steps, vocab, rnd, budget, llm=None):
    out = []
    for ep in eps + step_episodes(steps):
        ms = ep["messages"]
        calls = [i for i, m in enumerate(ms) if m["role"] == "assistant" and _call(m)]
        for a, b in zip(calls, calls[1:]):
            if _sig(ms[a]) != _sig(ms[b]):
                continue
            n = 2 + sum(1 for c in calls if c < a and _sig(ms[c]) == _sig(ms[a]))
            breaker = next((ms[c] for c in calls if c > b and _sig(ms[c]) != _sig(ms[a])
                            and c + 1 < len(ms) and not _is_err(ms[c + 1].get("content"))), None)
            if breaker is not None:
                chosen, prov = breaker, "transcript"
            else:
                last_obs = next((ms[k]["content"] for k in range(b - 1, -1, -1) if ms[k]["role"] == "tool"), "")
                status = re.sub(r"\s+", " ", last_obs or "no usable result yet").strip()[:500]
                chosen = {"role": "assistant", "content": STOP_TEMPLATE.format(tool=_call(ms[a])["name"], n=n,
                                                                                 status=status)}
                prov = "transcript+template"
                if llm:
                    txt = llm.ask(
                        "You write the ideal next message for an AI agent that got stuck repeating a tool call. "
                        "Be honest and concrete: say what was learned, what is still unknown, and either answer "
                        "with what is known or propose ONE different approach. No tool syntax. Under 150 words.",
                        f"Task: {_user_text(ms)[:1500]}\n\nRepeated call: {_call(ms[a])['name']}"
                        f"({_call(ms[a])['arguments'][:400]}) x{n}\n\nLast observation:\n{last_obs[:1500]}")
                    if txt:
                        chosen, prov = {"role": "assistant", "content": txt}, "transcript+llm"
            out.append(_sample("failure-modes", ep, ms[:b], chosen, _clone_call(ms[b], cid="call_repeat"),
                               prov, budget, repeats=n))
    return out


def r_context_discrimination(eps, steps, vocab, rnd, budget):
    good = [e for e in eps if ex.is_good(e) and _first_action(e["messages"]) is not None and _final(e["messages"])]
    out = []
    if len(good) < 2:
        return out
    for ep in good:
        other = rnd.choice([g for g in good if g is not ep])
        ms, om = ep["messages"], other["messages"]
        fa, ofa = _first_action(ms), _first_action(om)
        cur_user, old_user = _user_text(ms), _user_text(om)
        if not cur_user or not old_user or cur_user[:200] == old_user[:200]:
            continue
        system = [m for m in ms[:fa] if m["role"] == "system"]
        old_final = _final(om)["content"]
        if rnd.random() < 0.5:
            prompt = system + [{"role": "user", "content": old_user[:1500]},
                               {"role": "assistant", "content": old_final[:2000]},
                               {"role": "user", "content": cur_user}]
            style = "prior_turns"
        else:
            block = (f"Recent Conversation Context:\n[user] {old_user[:600]}\n[George] {old_final[:800]}\n\n"
                     f"Current request:\n{cur_user}")
            prompt = system + [{"role": "user", "content": block}]
            style = "context_block"
        out.append(_sample("context-discrimination", ep, prompt, ms[fa], copy.deepcopy(om[ofa]),
                           "transcript+splice", budget, distractor=other["meta"].get("session_id"), style=style))
    return out


def r_multi_hop(eps, steps, vocab, rnd, budget):
    out = []
    for ep in eps:
        if not ex.is_good(ep):
            continue
        ms = ep["messages"]
        acts = [i for i, m in enumerate(ms) if m["role"] == "assistant"]
        calls = [i for i in acts if _call(ms[i])]
        if len(calls) < 2:
            continue
        first = calls[0]
        for k in acts:
            if k <= calls[1] - 1 or k == acts[-1] and not _call(ms[k]):
                continue
            if _call(ms[k]) and _sig(ms[k]) == _sig(ms[first]):
                continue
            hop = sum(1 for c in calls if c < k)
            out.append(_sample("multi-hop", ep, ms[:k], ms[k], _clone_call(ms[first], cid="call_restart"),
                               "transcript", budget, hop=hop))
    return out


def r_final_answer(eps, steps, vocab, rnd, budget):
    out = []
    for ep in eps:
        ms = ep["messages"]
        fin = _final(ms)
        if not ex.is_good(ep) or not fin or not any(_call(m) for m in ms if m["role"] == "assistant"):
            continue
        out.append(_sample("final-answer", ep, ms[:-1], fin, None, "transcript", budget))
    return out


BUILDERS = {"tool-syntax": r_tool_syntax, "error-recovery": r_error_recovery, "failure-modes": r_failure_modes,
            "context-discrimination": r_context_discrimination, "multi-hop": r_multi_hop,
            "final-answer": r_final_answer, "gitops": r_gitops}


# ── existing datasets in data/ (curricula) + benchmark contamination guard ─────

BENCH_DIRS = ("arc", "arc_agi", "gpqa", "ifeval", "agent_bench", "refusal")
SKIP_AUDIT_DIRS = {"calibration", "catalog", "schemas", "assets"}
WORD_RX = re.compile(r"[a-z0-9]+")
SHINGLE = 12
DOMAIN_MAP = [  # (regex over domain/filename, recipe)
    (re.compile(r"context|discrimin"), "context-discrimination"),
    (re.compile(r"multihop|multi_hop|followup|multiturn|dag_react|research_cron"), "multi-hop"),
    (re.compile(r"evaluator|resilien|recovery|selfheal|remediation_protocol"), "error-recovery"),
    (re.compile(r"git|fileops|anticlobber|file_ops"), "gitops"),
    (re.compile(r"syntax|jinja|tool|remediation|counterexample|protocol"), "tool-syntax"),
]
EVAL_ONLY_RX = re.compile(r"gpqa|arc_agi|curriculum_arc|stem_agent|ifeval|exploit")


def default_data_dir():
    return os.environ.get("FORGE_DATA_DIR") or os.path.join(LODGE, "data")


def _norm_words(text):
    return WORD_RX.findall((text or "").lower())


def _shingles(text):
    """12-word shingles that carry real language (>= 6 alphabetic words of 3+ letters), so digit runs
    (ARC grids, tables) and tiny boilerplate don't produce false matches."""
    w = _norm_words(text)
    out = set()
    for i in range(0, max(0, len(w) - SHINGLE + 1)):
        win = w[i:i + SHINGLE]
        if sum(1 for t in win if len(t) >= 3 and t.isalpha()) >= 6:
            out.add(hash(" ".join(win)))
    return out


def _grid_key(r):
    """Exact fingerprint of an ARC-style task (its test inputs), wherever the task dict lives in the row."""
    if not isinstance(r, dict):
        return None
    t = r.get("task_data") if isinstance(r.get("task_data"), dict) else r
    test = t.get("test") if isinstance(t, dict) else None
    if not isinstance(test, list) or not test:
        return None
    try:
        inputs = [x.get("input") for x in test if isinstance(x, dict)]
    except AttributeError:
        return None
    if not inputs or not any(inputs):
        return None
    return hashlib.sha1(json.dumps(inputs, separators=(",", ":")).encode()).hexdigest()


def _iter_rows(fp, limit=None):
    """Yield dict rows from .jsonl/.ndjson/.json (list or {data|rows: list})."""
    n = 0
    try:
        if fp.endswith(".json"):
            with open(fp, encoding="utf-8", errors="ignore") as fh:
                d = json.load(fh)
            rows = d if isinstance(d, list) else (d.get("data") or d.get("rows") or d.get("examples") or [d]) \
                if isinstance(d, dict) else []
            for r in rows:
                yield r
                n += 1
                if limit and n >= limit:
                    return
            return
        with open(fp, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except ValueError:
                    continue
                n += 1
                if limit and n >= limit:
                    return
    except (OSError, ValueError):
        return


def _row_text(r):
    """Best-effort 'question' text of any row shape (benchmarks and curricula)."""
    if isinstance(r, list):
        return " ".join(str(x) for x in r if isinstance(x, str))[:4000]
    if not isinstance(r, dict):
        return str(r)[:4000]
    for k in ("question", "problem", "prompt", "instruction", "input", "text"):
        if isinstance(r.get(k), str) and r[k].strip():
            return r[k]
    msgs = r.get("messages") or r.get("conversations") or []
    if isinstance(msgs, list):
        u = [m.get("content") or m.get("value") or "" for m in msgs
             if isinstance(m, dict) and m.get("role", m.get("from")) in ("user", "human")]
        if u:
            return u[-1] if isinstance(u[-1], str) else json.dumps(u[-1])
    if isinstance(r.get("train"), list):  # ARC-AGI task json
        return json.dumps(r.get("test") or r["train"])[:4000]
    return ""


class BenchGuard:
    """12-word shingle index over the benchmark sets in data/. A sample that shares any shingle with a
    benchmark question is dropped: training on the test makes your eval numbers meaningless."""

    def __init__(self, data_dir):
        self.idx, self.items, self.sources, self.grids = set(), 0, [], set()
        counts = {}
        for d in BENCH_DIRS:
            base = os.path.join(data_dir, d)
            if not os.path.isdir(base):
                continue
            for fp in sorted(glob.glob(os.path.join(base, "**", "*"), recursive=True)):
                if not fp.endswith((".json", ".jsonl", ".ndjson")):
                    continue
                if os.sep + "training" + os.sep in fp[len(base):]:
                    continue  # e.g. arc_agi/training is the official *train* split, not an eval set
                self.sources.append(os.path.relpath(fp, data_dir))
                for r in _iter_rows(fp):
                    g = _grid_key(r)
                    if g:
                        self.grids.add(g)
                    sh = _shingles(_row_text(r))
                    for h in sh:
                        counts[h] = counts.get(h, 0) + 1
                    if sh or g:
                        self.items += 1
        # shingles shared by several benchmark items are template boilerplate, not a question
        self.idx = {h for h, n in counts.items() if n <= 2}

    def hits(self, text, row=None):
        if row is not None and self.grids:
            g = _grid_key(row)
            if g and g in self.grids:
                return True
        return bool(self.idx) and not self.idx.isdisjoint(_shingles(text))


def _recipe_for(domain, fname):
    key = f"{domain or ''} {fname}".lower()
    for rx, rec in DOMAIN_MAP:
        if rx.search(key):
            return rec
    return "tool-syntax"


def _call_msg(name, args, reasoning=""):
    a = args if isinstance(args, str) else json.dumps(args or {}, ensure_ascii=False)
    m = {"role": "assistant", "content": "", "tool_calls": [{"id": "call_0", "type": "function",
                                                            "function": {"name": str(name), "arguments": a}}]}
    if reasoning:
        m["reasoning_content"] = reasoning
    return m


def load_curricula(data_dir, vocab, rnd, budget, cap):
    """Adapt existing data/training curricula into forge samples, deduped and capped per unique prompt.
    Returns (samples_by_recipe, report)."""
    root = os.path.join(data_dir, "training")
    out, report = {}, {"files": {}, "skipped_eval_only": [], "skipped_unusable": [], "duplicates_only": []}
    per_prompt = {}
    for fp in sorted(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)):
        rel = os.path.relpath(fp, data_dir)
        fname = os.path.basename(fp)
        if EVAL_ONLY_RX.search(fname):
            report["skipped_eval_only"].append(rel)
            continue
        kept = total = capped = 0
        for r in _iter_rows(fp):
            total += 1
            if not isinstance(r, dict):
                continue
            tools = r.get("tools") if isinstance(r.get("tools"), list) else []
            prompt = chosen = rejected = None
            prov = "curriculum"
            if isinstance(r.get("chosen"), dict) and isinstance(r.get("messages"), list):
                prompt, chosen = r["messages"], r["chosen"]
                rejected = r.get("rejected") if isinstance(r.get("rejected"), dict) else None
            elif isinstance(r.get("expected_call"), dict) and isinstance(r.get("prompt"), str):
                ec = r["expected_call"]
                if not ec.get("name"):
                    continue
                prompt = [{"role": "user", "content": r["prompt"]}]
                chosen = _call_msg(ec["name"], ec.get("arguments"), r.get("reasoning") or "")
                rejected, _ = mutate(chosen, vocab, rnd)
                prov = "curriculum+mutation"
            elif isinstance(r.get("messages"), list) and len(r["messages"]) >= 2 \
                    and isinstance(r["messages"][-1], dict) and r["messages"][-1].get("role") == "assistant":
                prompt, chosen = r["messages"][:-1], r["messages"][-1]
            else:
                continue
            if not prompt or not isinstance(chosen, dict):
                continue
            last_user = next((m.get("content") for m in reversed(prompt)
                              if isinstance(m, dict) and m.get("role") == "user"), "") or ""
            pk = hashlib.sha1(" ".join(_norm_words(last_user))[:600].encode()).hexdigest()
            if per_prompt.get(pk, 0) >= cap:
                capped += 1
                continue
            per_prompt[pk] = per_prompt.get(pk, 0) + 1
            rec = _recipe_for(r.get("domain"), fname)
            ep = {"meta": {"session_id": f"cur:{fname}:{pk[:10]}", "source": "curriculum", "outcome": "CURATED"},
                  "tools": tools}
            out.setdefault(rec, []).append(_sample(rec, ep, prompt, chosen, rejected, f"{prov}:{fname}", budget))
            kept += 1
        if total and not kept:
            report["duplicates_only" if capped else "skipped_unusable"].append(rel)
        elif total:
            report["files"][rel] = {"rows": total, "kept": kept, "capped_duplicates": capped}
    report["unique_prompts"] = len(per_prompt)
    return out, report


# ── pipeline ───────────────────────────────────────────────────────────────────

def load(george_dir, since, max_obs):
    ns = argparse.Namespace(george_dir=george_dir, since=since, max_obs=max_obs)
    episodes, steps, red = ex.collect(ns)
    vocab = sorted({_call(m)["name"] for e in episodes for m in e["messages"] if m["role"] == "assistant" and _call(m)}
                   | {_call(s["messages"][1])["name"] for s in steps})
    return episodes, steps, vocab, red


def _digest(s):
    tail = s["prompt"][-2:]
    return hashlib.sha1(json.dumps([tail, s["chosen"], s["rejected"]], sort_keys=True,
                                   ensure_ascii=False).encode()).hexdigest()


def paraphrase_fill(pool, need, llm, rnd):
    """Use the LLM to reword the last user request of real samples (provenance transcript+llm-paraphrase)."""
    made = []
    cands = [s for s in pool if s["prompt"] and any(m["role"] == "user" for m in s["prompt"])]
    rnd.shuffle(cands)
    for s in cands:
        if len(made) >= need or llm.left <= 0:
            break
        idx = max(i for i, m in enumerate(s["prompt"]) if m["role"] == "user")
        orig = s["prompt"][idx]["content"]
        if len(orig) > 2500 or len(orig) < 12:
            continue
        txt = llm.ask("Rewrite the user's request so it asks for exactly the same thing in different words. Keep "
                      "every concrete detail (names, numbers, paths, URLs). Output only the rewritten request.",
                      orig, max_tokens=400, temperature=0.9)
        if not txt or txt.strip()[:200] == orig.strip()[:200]:
            continue
        v = copy.deepcopy(s)
        v["prompt"][idx]["content"] = txt
        v["meta"]["provenance"] = s["meta"]["provenance"] + "+llm-paraphrase"
        made.append(v)
    return made


def _strip_reasoning(m):
    m = dict(m)
    m.pop("reasoning_content", None)
    return m


def _render(m, n=600):
    if m is None:
        return "_(none — SFT only)_"
    if _call(m):
        f = _call(m)
        return f"`{f['name']}({(f.get('arguments') or '')[:n]})`"
    return (m.get("content") or "")[:n].replace("\n", " ")


def build(args):
    focus = [f.strip() for f in args.focus.split(",") if f.strip()]
    if focus == ["mix"]:
        focus = list(RECIPES)
    bad = [f for f in focus if f not in RECIPES]
    if bad or not focus:
        raise SystemExit(f"unknown focus {bad or focus}; choose from: mix, {', '.join(RECIPES)}")
    if not 1 <= args.count <= 200000:
        raise SystemExit("--count must be between 1 and 200000")
    rnd = random.Random(args.seed)
    PROGRESS["file"] = args.progress_file
    progress(phase="reading transcripts")
    episodes, steps, vocab, red = load(args.george_dir, args.since, args.max_obs)
    progress(phase="cutting samples")
    llm = LLM(args.llm_url or default_llm_url(args.george_dir), args.max_llm_calls) if args.augment_llm else None

    data_dir = args.data_dir or default_data_dir()
    cur_pool, cur_report = {}, None
    if args.include_curricula or args.curricula_only:
        progress(phase="reading data/training curricula")
        cur_pool, cur_report = load_curricula(data_dir, vocab, rnd, args.max_context, args.curriculum_cap)
    guard = None if args.no_bench_guard else BenchGuard(data_dir)
    contaminated = 0

    pools, available = {}, {}
    for f in focus:
        fn = BUILDERS[f]
        raw = [] if args.curricula_only else (
            fn(episodes, steps, vocab, rnd, args.max_context, llm=llm) if f == "failure-modes"
            else fn(episodes, steps, vocab, rnd, args.max_context))
        raw = raw + cur_pool.get(f, [])
        uniq, seen = [], set()
        for s in raw:
            d = _digest(s)
            if d in seen:
                continue
            seen.add(d)
            if guard and guard.hits(next((m.get("content") or "" for m in reversed(s["prompt"])
                                          if m.get("role") == "user"), "")):
                contaminated += 1
                continue
            uniq.append(s)
        rnd.shuffle(uniq)
        pools[f] = uniq
        available[f] = len(uniq)

    # balanced round-robin draw across focuses
    picked, cursors = [], {f: 0 for f in focus}
    while len(picked) < args.count and any(cursors[f] < len(pools[f]) for f in focus):
        for f in focus:
            if len(picked) >= args.count:
                break
            if cursors[f] < len(pools[f]):
                picked.append(pools[f][cursors[f]])
                cursors[f] += 1
    shortfall = args.count - len(picked)
    if shortfall > 0 and llm:
        picked += paraphrase_fill(picked, shortfall, llm, rnd)
        shortfall = args.count - len(picked)

    # session-grouped split
    sessions = sorted({s["meta"]["session"] or "?" for s in picked})
    rnd.shuffle(sessions)
    n_val = int(round(len(sessions) * args.val_frac)) if len(sessions) >= 5 else 0
    val_sessions = set(sessions[:n_val])

    tag = "mix" if len(focus) == len(RECIPES) else "_".join(focus)[:60]
    out = args.out or os.path.join(args.george_dir, "datasets",
                                   f"forge_{tag}_{dt.datetime.now().strftime('%Y%m%d_%H%M%S')}")
    os.makedirs(out, exist_ok=True)
    fh = {k: open(os.path.join(out, k + ".jsonl"), "w", encoding="utf-8")
          for k in ("sft_train", "sft_val", "dpo_train", "dpo_val", "samples_meta")}
    counts = {"sft_train": 0, "sft_val": 0, "dpo_train": 0, "dpo_val": 0}
    by_recipe, by_prov, chars = {}, {}, 0
    try:
        for s in picked:
            side = "val" if s["meta"]["session"] in val_sessions else "train"
            prompt = [_strip_reasoning(m) for m in s["prompt"]] if args.drop_reasoning else s["prompt"]
            chosen = _strip_reasoning(s["chosen"]) if args.drop_reasoning else s["chosen"]
            if args.format in ("sft", "both"):
                row = {"messages": prompt + [chosen], "tools": s["tools"]}
                fh["sft_" + side].write(json.dumps(row, ensure_ascii=False) + "\n")
                counts["sft_" + side] += 1
                chars += len(json.dumps(row, ensure_ascii=False))
            if args.format in ("dpo", "both") and s["rejected"] is not None:
                rej = _strip_reasoning(s["rejected"]) if args.drop_reasoning else s["rejected"]
                row = {"prompt": prompt, "chosen": [chosen], "rejected": [rej], "tools": s["tools"]}
                fh["dpo_" + side].write(json.dumps(row, ensure_ascii=False) + "\n")
                counts["dpo_" + side] += 1
            fh["samples_meta"].write(json.dumps({**s["meta"], "split": side}, ensure_ascii=False) + "\n")
            by_recipe[s["meta"]["recipe"]] = by_recipe.get(s["meta"]["recipe"], 0) + 1
            by_prov[s["meta"]["provenance"]] = by_prov.get(s["meta"]["provenance"], 0) + 1
    finally:
        for f in fh.values():
            f.close()

    manifest = {
        "created": dt.datetime.now().isoformat(timespec="seconds"), "focus": focus, "requested": args.count,
        "produced": len(picked), "shortfall": max(0, shortfall), "available_unique": available,
        "by_recipe": by_recipe, "by_provenance": by_prov, **counts,
        "sessions": len(sessions), "val_sessions": len(val_sessions),
        "approx_tokens": chars // 4, "episodes_scanned": len(episodes), "steps_scanned": len(steps),
        "redacted_fields": red.n, "anonymised_user_ids": len(red.ids),
        "llm": {"used": bool(llm), "calls": llm.calls if llm else 0, "failures": llm.failures if llm else 0},
        "seed": args.seed, "max_context_chars": args.max_context, "out": out,
        "bench_guard": {"enabled": bool(guard), "benchmark_items": guard.items if guard else 0,
                        "sources": guard.sources if guard else [], "dropped": contaminated},
        "curricula": cur_report,
    }
    with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    write_preview(out, picked, rnd)
    write_readme(out, manifest)
    rel = os.path.relpath(out, os.path.join(args.george_dir, "datasets"))
    if not rel.startswith(".."):
        manifest["ids"] = {k: f"exports:{rel}/{k}.jsonl" for k in counts if counts[k]}
    print(json.dumps(manifest))
    return 0


def write_preview(out, picked, rnd):
    lines = ["# Forge preview", "", "A random handful of samples, rendered for humans. Read a few before you train —",
             "the fastest way to catch a bad recipe is to look at its output.", ""]
    shown = rnd.sample(picked, min(8, len(picked))) if picked else []
    for n, s in enumerate(shown, 1):
        last_user = re.sub(r"\s+", " ", next((m["content"] for m in reversed(s["prompt"]) if m["role"] == "user"), ""))
        last_tool = re.sub(r"\s+", " ", next((m["content"] for m in reversed(s["prompt"]) if m["role"] == "tool"), ""))
        lines += [f"## {n}. {s['meta']['recipe']} · {s['meta']['provenance']}", "",
                  f"**Request:** {last_user[:400]}", ""]
        if last_tool:
            lines += [f"**Last observation:** {last_tool[:300]}", ""]
        lines += [f"**✅ Chosen:** {_render(s['chosen'])}", "", f"**❌ Rejected:** {_render(s['rejected'])}", ""]
    with open(os.path.join(out, "preview.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def write_readme(out, m):
    parts = [f"# Forge dataset — {', '.join(m['focus'])}", "",
             f"{m['produced']} samples ({m['sft_train']} SFT train / {m['sft_val']} SFT val, "
             f"{m['dpo_train']} DPO train / {m['dpo_val']} DPO val), ~{m['approx_tokens']:,} tokens, "
             f"from {m['sessions']} sessions. Validation is split by session, so val episodes were never seen in train.",
             ""]
    if m["shortfall"]:
        parts += [f"> Asked for {m['requested']}, produced {m['produced']}: your transcripts only contain that many "
                  "unique examples for this focus. The forge never pads with copies — duplicates just teach the model "
                  "to memorise. Run more tasks, widen --focus, or add --augment-llm to paraphrase.", ""]
    parts += ["## What each recipe teaches", ""]
    for f in m["focus"]:
        r = RECIPES[f]
        parts += [f"### {f} — {r['title']}", "", r["lesson"], ""]
    parts += ["## Provenance", "", "Every row in `samples_meta.jsonl` says where it came from:", "",
              "| provenance | meaning |", "|---|---|",
              "| transcript | both sides cut verbatim from a real episode |",
              "| transcript+mutation / steplog+mutation | real chosen; rejected is a deliberately broken copy |",
              "| transcript+splice | real episodes combined (distractor context) |",
              "| transcript+template | real context; chosen is a fixed honest-stop template |",
              "| transcript+llm | real context; chosen written by your local LLM — spot-check these |",
              "| …+llm-paraphrase | request reworded by your local LLM |", "",
              "## Train it", "",
              "1. **SFT first.** Model Workbench → Fine-tune → pick `sft_train.jsonl` (+ `sft_val.jsonl`) → "
              "Generate kit, or `/models train-kit '{\"name\":\"...\",\"base_model\":\"<hf repo>\","
              "\"train\":\"<id of sft_train.jsonl>\"}'`.",
              "2. **Then DPO (optional).** `train_lora.py --config config.json --mode dpo` with `dpo_train.jsonl` "
              "teaches the model to *prefer* the chosen side over the rejected one. Start from the SFT adapter.",
              "3. Convert the adapter to GGUF (see the kit README) and drop it in the adapters folder; "
              "it appears in the Library, and Serve & Tune can stack it on the base model.", "",
              "## Lessons for first-time tuners", "",
              "- **Look at `preview.md` before training.** Ten seconds of reading beats ten GPU hours.",
              "- **Small and clean beats big and noisy.** A few hundred unique, correct samples move behaviour.",
              "- **Watch val loss.** If train loss falls while val loss rises, you are memorising — stop earlier, "
              "lower epochs, or lower the LoRA rank.",
              "- **One focus at a time** makes cause and effect visible: tune error-recovery, then re-run the same "
              "tasks and count retries.", "",
              "> **Before sharing this dataset or an adapter trained on it:** redaction removes secrets from your "
              "key files, common token formats and Discord ids, but *not* usernames, locations, file paths or "
              "anything people told George. Read it first; keep it private if in doubt.", ""]
    with open(os.path.join(out, "README.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(parts))


def pantry(args):
    episodes, steps, vocab, red = load(args.george_dir, args.since, args.max_obs)
    rnd = random.Random(args.seed)
    outcomes, sources = {}, {}
    for e in episodes:
        outcomes[e["meta"].get("outcome") or "?"] = outcomes.get(e["meta"].get("outcome") or "?", 0) + 1
        sources[e["meta"].get("source") or "?"] = sources.get(e["meta"].get("source") or "?", 0) + 1
    avail = {}
    for f, fn in BUILDERS.items():
        avail[f] = len({_digest(s) for s in fn(episodes, steps, vocab, rnd, args.max_context)})
    data_dir = args.data_dir or default_data_dir()
    cur, rep = load_curricula(data_dir, vocab, rnd, args.max_context, 2) if os.path.isdir(
        os.path.join(data_dir, "training")) else ({}, None)
    cur_avail = {f: len({_digest(x) for x in cur.get(f, [])}) for f in RECIPES if cur.get(f)}
    res = {"episodes": len(episodes), "steps": len(steps), "outcomes": outcomes, "sources": sources,
           "tools_seen": len(vocab), "recipes_available": avail, "curricula_available": cur_avail,
           "curricula_skipped_eval_only": (rep or {}).get("skipped_eval_only", [])}
    if not args.json:
        print(f"Episodes: {len(episodes)}  ·  step-log records: {len(steps)}  ·  distinct tools: {len(vocab)}")
        print("Outcomes: " + ", ".join(f"{k}={v}" for k, v in sorted(outcomes.items())))
        print("Unique samples each recipe can cut right now:")
        for f, n in avail.items():
            print(f"  {f:<24} {n:>6}   {RECIPES[f]['title']}")
        if cur_avail:
            print(f"Existing curricula in {os.path.join(data_dir, 'training')} (deduped, max 2 per prompt; "
                  "add with --include-curricula):")
            for f, n in cur_avail.items():
                print(f"  {f:<24} {n:>6}")
        if res["curricula_skipped_eval_only"]:
            print("Skipped as eval-only (benchmark copies): " + ", ".join(res["curricula_skipped_eval_only"]))
    print(json.dumps(res))
    return 0


def audit(args):
    data_dir = args.data_dir or default_data_dir()
    paths = args.paths or [data_dir]
    guard = BenchGuard(data_dir)
    bench_abs = {os.path.abspath(os.path.join(data_dir, x)) for x in guard.sources}
    files = []
    for p in paths:
        if os.path.isdir(p):
            for f in sorted(glob.glob(os.path.join(p, "**", "*"), recursive=True)):
                parts = os.path.relpath(f, p).split(os.sep)
                if f.endswith((".jsonl", ".ndjson", ".json")) and not SKIP_AUDIT_DIRS.intersection(parts) \
                        and not os.path.basename(f).startswith("native_core_tools") \
                        and not os.path.basename(f).endswith("_summary.json"):
                    files.append((f, p))
        elif p.endswith((".jsonl", ".ndjson", ".json")) and os.path.isfile(p):
            files.append((p, os.path.dirname(p) or "."))
    rows = []
    for fp, root in files[:2000]:
        total, uniq, prompts, overlap = 0, set(), set(), 0
        is_bench = os.path.abspath(fp) in bench_abs
        for o in _iter_rows(fp):
            total += 1
            uniq.add(hashlib.sha1(json.dumps(o, sort_keys=True, default=str).encode()).hexdigest())
            t = _row_text(o)
            prompts.add(hashlib.sha1(" ".join(_norm_words(t))[:600].encode()).hexdigest())
            if not is_bench and guard.hits(t, o):
                overlap += 1
        if not total:
            continue
        rows.append({"file": os.path.relpath(fp, root), "kind": "benchmark" if is_bench else "training",
                     "rows": total, "unique_rows": len(uniq), "unique_prompts": len(prompts),
                     "bench_overlap": overlap,
                     "dup_pct": round(100 * (1 - len(uniq) / total), 1),
                     "prompt_diversity_pct": round(100 * len(prompts) / total, 1)})
    # ARC-AGI style one-task-per-file directories are summarised, not listed file by file
    singles = {}
    for r in rows:
        if r["rows"] == 1 and r["kind"] == "benchmark":
            singles[os.path.dirname(r["file"])] = singles.get(os.path.dirname(r["file"]), 0) + 1
    collapsed, grouped = [], {}
    for r in rows:
        d = os.path.dirname(r["file"])
        if r["rows"] == 1 and r["kind"] == "benchmark" and singles.get(d, 0) > 5:
            g = grouped.setdefault(d, {"file": d + "/*", "kind": "benchmark", "rows": 0, "unique_rows": 0,
                                       "unique_prompts": 0, "bench_overlap": 0, "dup_pct": 0.0,
                                       "prompt_diversity_pct": 100.0})
            g["rows"] += 1
            g["unique_rows"] += 1
            g["unique_prompts"] += 1
        else:
            collapsed.append(r)
    rows = collapsed + list(grouped.values())
    if not args.json:
        print(f"{'file':<64} {'kind':<9} {'rows':>7} {'unique':>7} {'prompts':>8} {'dup%':>6} {'bench!':>6}")
        for r in rows:
            print(f"{r['file'][-64:]:<64} {r['kind']:<9} {r['rows']:>7} {r['unique_rows']:>7} "
                  f"{r['unique_prompts']:>8} {r['dup_pct']:>6} {r['bench_overlap']:>6}")
        print(f"Benchmark index: {guard.items} items from {len(guard.sources)} file(s) in {data_dir}.")
        print("dup% = identical rows · prompts = distinct questions (low = the model keeps seeing the same few tasks)")
        print("bench! = training rows that overlap a benchmark question; train on those and your eval scores lie.")
    print(json.dumps({"files": rows}))
    return 0


def recipes(args):
    if not args.json:
        for name, r in RECIPES.items():
            print(f"{name:<24} {'SFT+DPO' if r['dpo'] else 'SFT':<8} {r['title']}")
            print(f"{'':<24} {r['lesson']}\n")
    print(json.dumps({k: {"title": v["title"], "dpo": v["dpo"], "lesson": v["lesson"]} for k, v in RECIPES.items()}))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--george-dir", default=os.environ.get("GEORGE_DIR", os.path.join(LODGE, ".george")))
    ap.add_argument("--data-dir", default=None, help="datasets/benchmarks root (default $FORGE_DATA_DIR or <lodge>/data)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("recipes", "pantry", "build", "audit"):
        p = sub.add_parser(name)
        p.add_argument("--json", action="store_true", help="only print the JSON summary line")
        if name in ("pantry", "build"):
            p.add_argument("--since", default=None)
            p.add_argument("--max-obs", type=int, default=2500)
            p.add_argument("--max-context", type=int, default=24000)
            p.add_argument("--seed", type=int, default=7)
        if name == "build":
            p.add_argument("--focus", required=True)
            p.add_argument("--count", type=int, required=True)
            p.add_argument("--format", choices=("sft", "dpo", "both"), default="both")
            p.add_argument("--val-frac", type=float, default=0.1)
            p.add_argument("--augment-llm", action="store_true")
            p.add_argument("--llm-url", default=None)
            p.add_argument("--max-llm-calls", type=int, default=200)
            p.add_argument("--drop-reasoning", action="store_true")
            p.add_argument("--out", default=None)
            p.add_argument("--progress-file", default=None, help=argparse.SUPPRESS)
            p.add_argument("--include-curricula", action="store_true",
                           help="also draw from existing data/training curricula (deduped, capped per prompt)")
            p.add_argument("--curricula-only", action="store_true", help="use only data/training curricula")
            p.add_argument("--curriculum-cap", type=int, default=2,
                           help="max variants kept per unique curriculum prompt (default 2)")
            p.add_argument("--no-bench-guard", action="store_true",
                           help="do not drop samples that overlap the benchmark sets in data/")
        if name == "audit":
            p.add_argument("paths", nargs="*")
    args = ap.parse_args(argv)
    if getattr(args, "since", None) and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.since):
        raise SystemExit("--since must be YYYY-MM-DD")
    if getattr(args, "val_frac", 0) and not 0 <= args.val_frac < 0.5:
        raise SystemExit("--val-frac must be in [0, 0.5)")
    return {"recipes": recipes, "pantry": pantry, "build": build, "audit": audit}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
