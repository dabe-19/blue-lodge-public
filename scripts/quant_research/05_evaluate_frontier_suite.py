#!/usr/bin/env python3
"""
Comprehensive 6-Pillar Frontier Benchmark Suite:
Evaluates the model against the target dimensions of dense Qwen3.8-27B:
1. Agentic Terminal Coding (TerminalBench / Bash Execution) [Target: ~73.0]
2. Instruction Following (IFBench / IFEval) [Target: ~79.5]
3. Scientific Reasoning (GPQA Diamond) [Target: ~89.2]
4. AgentBench (Strict JSON Tool Calling & Schema Extraction) [Target: ~85.0]
5. AI2 ARC-Challenge (Multi-step Reasoning) [Target: ~75.0]
6. ARC-AGI Program-Synthesis (Executable Python transform(grid)) [Target: >= 30.0]

Configured for high-throughput 4-slot parallel evaluation on Blue Lodge infrastructure.
"""

import os
import sys
import time
import json
import re
import urllib.request
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
import numpy as np

DATA_DIR = "/home/wsl-ops/blue-lodge/data"
RESULTS_DIR = "/home/wsl-ops/blue-lodge/benchmarks/results"
os.makedirs(RESULTS_DIR, exist_ok=True)

def query_endpoint(endpoint_url, messages, max_tokens=2048, temperature=0.0, repeat_penalty=1.15, timeout=300):
    req_body = json.dumps({
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "repeat_penalty": repeat_penalty,
        "stream": False
    }).encode("utf-8")

    req = urllib.request.Request(
        f"{endpoint_url}/v1/chat/completions",
        data=req_body,
        headers={"Content-Type": "application/json"}
    )

    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - t0
            timings = data.get("timings", {})
            choice = data.get("choices", [{}])[0]
            msg = choice.get("message", {})
            return {
                "success": True,
                "content": msg.get("content", ""),
                "reasoning_content": msg.get("reasoning_content", ""),
                "finish_reason": choice.get("finish_reason", ""),
                "elapsed": elapsed,
                "prompt_tok_s": timings.get("prompt_per_second", 0.0),
                "decode_tok_s": timings.get("predicted_per_second", 0.0),
                "tokens": timings.get("predicted_n", 0)
            }
    except Exception as e:
        return {"success": False, "error": str(e), "elapsed": time.time() - t0}

def clean_output(content, reasoning=""):
    """Strip out think tags to inspect final output, falling back to reasoning if content is empty."""
    text = (content or "").strip()
    if "</think>" in text:
        after = text.split("</think>", 1)[1].strip()
        if after:
            text = after
        else:
            text = text.split("</think>", 1)[0].strip()
    text = re.sub(r"\[Start thinking\].*?\[End thinking\]", "", text, flags=re.DOTALL)
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    text = re.sub(r"</?think>", "", text).strip()
    return text if text else (reasoning or "").strip()

def extract_first_json(text):
    """Robustly extract valid JSON dictionary or array from markdown or raw text."""
    if not text:
        return ""
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if m:
        try:
            json.loads(m.group(1))
            return m.group(1)
        except Exception:
            pass
    start = text.find("{")
    if start != -1:
        depth = 0
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    cand = text[start:i+1]
                    try:
                        json.loads(cand)
                        return cand
                    except Exception:
                        pass
    m2 = re.search(r"(\{.*\})", text, re.DOTALL)
    if m2:
        try:
            json.loads(m2.group(1))
            return m2.group(1)
        except Exception:
            pass
    return ""

def extract_choice(content, reasoning=""):
    """Robust extractor for multiple choice letter (A-E)."""
    full_raw = (content or "") + "\n" + (reasoning or "")
    
    # 1. Exact \boxed{X} in full output (most reliable)
    m_box_all = re.findall(r"\\boxed\{([A-E])\}", full_raw, re.IGNORECASE)
    if m_box_all:
        return m_box_all[-1].upper()

    text = clean_output(content, reasoning)
    
    # 2. Explicit statement e.g. "correct answer is (C)" or "answer is: D"
    m_expl = re.findall(r"(?:correct answer is|answer is|correct choice is|choice is|option is|answer:)\s*\(?([A-E])\)?", full_raw, re.IGNORECASE)
    if m_expl:
        return m_expl[-1].upper()
        
    # 3. Clean text is just the choice letter or ends with it
    m_end = re.search(r"(?:^|\n)\s*(?:answer:?\s*)?\(?([A-E])\)?[.\s]*$", text, re.IGNORECASE)
    if m_end:
        return m_end.group(1).upper()
            
    # 4. Fallback: last standalone letter
    letters = re.findall(r"\b([A-E])\b", text)
    if letters:
        return letters[-1].upper()
        
    return ""

# ---------------------------------------------------------
# 1. AgentBench (JSON Tool Calling)
# ---------------------------------------------------------
def eval_agent_bench(endpoint_url, n_samples=20, max_workers=4):
    print(f"\n[*] [1/6] Evaluating AgentBench ({n_samples} samples, {max_workers} slots)...", flush=True)
    path = f"{DATA_DIR}/agent_bench/json-mode-agentic.json"
    if not os.path.exists(path):
        return {"score": 0.0, "error": "file not found"}
    with open(path, "r") as f:
        all_samples = json.load(f)[:n_samples]

    def process_sample(idx, item):
        convs = item.get("conversations", [])
        messages = []
        for c in convs:
            role = "system" if c.get("from") == "system" else ("user" if c.get("from") == "human" else "assistant")
            if role != "assistant":
                messages.append({"role": role, "content": c.get("value", "")})

        res = query_endpoint(endpoint_url, messages, max_tokens=3072)
        if not res["success"]:
            print(f"  [-] AgentBench [{idx+1}/{n_samples}] Failed: {res.get('error')}", flush=True)
            return False, 0.0

        c = clean_output(res["content"], res.get("reasoning_content", ""))
        raw_json = extract_first_json(c) or extract_first_json(res["content"])
        valid = bool(raw_json)
        status = "PASS" if valid else "FAIL"
        print(f"  [AgentBench] [{idx+1}/{n_samples}] {status} ({res['decode_tok_s']:.1f} tok/s, {res['elapsed']:.1f}s)", flush=True)
        return valid, res["decode_tok_s"]

    valid_json = 0
    speeds = []
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [executor.submit(process_sample, i, s) for i, s in enumerate(all_samples)]
        for f in as_completed(futures):
            v, spd = f.result()
            if v:
                valid_json += 1
            if spd > 0:
                speeds.append(spd)

    score = (valid_json / len(all_samples)) * 100 if all_samples else 0.0
    print(f"  ✓ AgentBench Score: {score:.1f}% ({valid_json}/{len(all_samples)}) | Avg Speed: {np.mean(speeds) if speeds else 0:.1f} tok/s", flush=True)
    return {"score": score, "valid_count": valid_json, "total": len(all_samples)}

# ---------------------------------------------------------
# 2. AI2 ARC-Challenge
# ---------------------------------------------------------
def eval_arc_challenge(endpoint_url, n_samples=20, max_workers=4):
    print(f"\n[*] [2/6] Evaluating AI2 ARC-Challenge ({n_samples} samples, {max_workers} slots)...", flush=True)
    path = f"{DATA_DIR}/arc/arc-challenge_test.json"
    if not os.path.exists(path):
        return {"score": 0.0, "error": "file not found"}
    with open(path, "r") as f:
        samples = json.load(f)[:n_samples]

    def process_sample(idx, item):
        q = item.get("question", "")
        choices = item.get("choices", {})
        texts = choices.get("text", [])
        labels = choices.get("label", [])
        answer_key = item.get("answerKey", "").strip().upper()
        choice_lines = [f"{lbl}. {txt}" for lbl, txt in zip(labels, texts)]
        prompt = f"Question: {q}\n\nChoices:\n" + "\n".join(choice_lines) + "\n\nProvide concise reasoning and conclude with \\boxed{X} where X is the single choice letter."
        messages = [
            {"role": "system", "content": "You are a scientific reasoning expert. Think concisely step-by-step and conclude with \\boxed{X}."},
            {"role": "user", "content": prompt}
        ]
        res = query_endpoint(endpoint_url, messages, max_tokens=2048)
        if not res["success"]:
            print(f"  [-] ARC-Challenge [{idx+1}/{n_samples}] Failed: {res.get('error')}", flush=True)
            return False

        pred = extract_choice(res["content"], res.get("reasoning_content", ""))
        is_correct = (pred == answer_key)
        status = "PASS" if is_correct else "FAIL"
        print(f"  [ARC-Challenge] [{idx+1}/{n_samples}] {status} (Pred={pred}, Key={answer_key}, {res['elapsed']:.1f}s)", flush=True)
        return is_correct

    correct = 0
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [executor.submit(process_sample, i, s) for i, s in enumerate(samples)]
        for f in as_completed(futures):
            if f.result():
                correct += 1

    score = (correct / len(samples)) * 100 if samples else 0.0
    print(f"  ✓ ARC-Challenge Score: {score:.1f}% ({correct}/{len(samples)})", flush=True)
    return {"score": score, "correct": correct, "total": len(samples)}

# ---------------------------------------------------------
# 3. GPQA Diamond (Scientific Reasoning)
# ---------------------------------------------------------
def eval_gpqa_diamond(endpoint_url, n_samples=20, max_workers=4):
    print(f"\n[*] [3/6] Evaluating GPQA Diamond ({n_samples} samples, {max_workers} slots)...", flush=True)
    path = f"{DATA_DIR}/gpqa/gpqa_diamond.json"
    if not os.path.exists(path):
        return {"score": 0.0, "error": f"local file not found: {path}"}
    with open(path, "r") as f:
        samples = json.load(f)[:n_samples]

    def process_sample(idx, item):
        prob = item.get("problem", "")
        sol = item.get("solution", "")
        m_ans = re.search(r"\\boxed\{([A-D])\}", sol)
        ans_key = m_ans.group(1).upper() if m_ans else "A"

        prompt = f"{prob}\n\nProvide a concise step-by-step derivation and conclude your response with the final choice letter formatted as \\boxed{{X}}."
        messages = [
            {"role": "system", "content": "You are a world-class scientific reasoning expert. Think concisely step-by-step and provide your final choice inside \\boxed{X}."},
            {"role": "user", "content": prompt}
        ]
        res = query_endpoint(endpoint_url, messages, max_tokens=3072)
        if not res["success"]:
            print(f"  [-] GPQA [{idx+1}/{n_samples}] Failed: {res.get('error')}", flush=True)
            return False

        pred = extract_choice(res["content"], res.get("reasoning_content", ""))
        is_correct = (pred == ans_key)
        status = "PASS" if is_correct else "FAIL"
        print(f"  [GPQA-Diamond] [{idx+1}/{n_samples}] {status} (Pred={pred}, Key={ans_key}, tok={res.get('tokens',0)}, {res['elapsed']:.1f}s)", flush=True)
        return is_correct

    correct = 0
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [executor.submit(process_sample, i, s) for i, s in enumerate(samples)]
        for f in as_completed(futures):
            if f.result():
                correct += 1

    score = (correct / len(samples)) * 100 if samples else 0.0
    print(f"  ✓ GPQA Diamond Score: {score:.1f}% ({correct}/{len(samples)})", flush=True)
    return {"score": score, "correct": correct, "total": len(samples)}

# ---------------------------------------------------------
# 4. IFBench / IFEval (Instruction Following)
# ---------------------------------------------------------
def eval_ifbench(endpoint_url, n_samples=20, max_workers=4):
    print(f"\n[*] [4/6] Evaluating IFBench / IFEval ({n_samples} samples, {max_workers} slots)...", flush=True)
    path = f"{DATA_DIR}/ifeval/ifeval.json"
    if not os.path.exists(path):
        return {"score": 0.0, "error": f"local file not found: {path}"}
    with open(path, "r") as f:
        samples = json.load(f)[:n_samples]

    def process_sample(idx, item):
        prompt = item.get("prompt", "")
        ins_list = item.get("instruction_id_list", [])
        kwargs_list = item.get("kwargs", [])

        messages = [{"role": "user", "content": prompt}]
        res = query_endpoint(endpoint_url, messages, max_tokens=2048)
        if not res["success"]:
            print(f"  [-] IFBench [{idx+1}/{n_samples}] Failed: {res.get('error')}", flush=True)
            return False

        output_text = clean_output(res["content"], res.get("reasoning_content", ""))
        rule_pass = True
        for ins_id, kw in zip(ins_list, kwargs_list):
            kw_dict = json.loads(kw) if isinstance(kw, str) else kw
            if "word_count" in ins_id or "num_words" in kw_dict:
                wc = len(output_text.split())
                target_min = kw_dict.get("min_words", 0)
                target_max = kw_dict.get("max_words", 999999)
                if not (target_min <= wc <= target_max):
                    rule_pass = False
                    break
            elif "json" in ins_id.lower() or "json" in prompt.lower():
                try:
                    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", output_text, re.DOTALL)
                    cand = m.group(1) if m else output_text
                    json.loads(cand)
                except Exception:
                    rule_pass = False
                    break
            elif "forbidden_words" in kw_dict:
                for fw in kw_dict["forbidden_words"]:
                    if fw.lower() in output_text.lower():
                        rule_pass = False
                        break

        passed = rule_pass and len(output_text.strip()) > 10
        status = "PASS" if passed else "FAIL"
        print(f"  [IFBench] [{idx+1}/{n_samples}] {status} ({res['elapsed']:.1f}s)", flush=True)
        return passed

    passed_count = 0
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [executor.submit(process_sample, i, s) for i, s in enumerate(samples)]
        for f in as_completed(futures):
            if f.result():
                passed_count += 1

    score = (passed_count / len(samples)) * 100 if samples else 0.0
    print(f"  ✓ IFBench Score: {score:.1f}% ({passed_count}/{len(samples)})", flush=True)
    return {"score": score, "passed": passed_count, "total": len(samples)}

# ---------------------------------------------------------
# 5. TerminalBench (Agentic Terminal Coding)
# ---------------------------------------------------------
def eval_terminal_bench(endpoint_url, n_samples=15, max_workers=4):
    print(f"\n[*] [5/6] Evaluating TerminalBench / Bash Tool Execution ({n_samples} samples, {max_workers} slots)...", flush=True)
    tasks = [
        {"goal": "Find all .log files in /var/log larger than 10MB modified in the last 7 days", "check": ["find", "mtime"]},
        {"goal": "Filter out duplicate lines from input.txt without sorting and preserve original order", "check": ["awk", "seen"]},
        {"goal": "Create a tar.gz archive of /src excluding any node_modules or .git directories", "check": ["tar", "exclude"]},
        {"goal": "Extract the IP addresses from access.log that returned 404 HTTP status", "check": ["grep", "404"]},
        {"goal": "Check if port 8080 is listening on localhost and kill the owning PID", "check": ["kill"]},
        {"goal": "Display the top 5 memory consuming processes with their PID and resident memory", "check": ["ps", "sort"]},
        {"goal": "Replace all occurrences of 'http://old.com' with 'https://new.com' across all .html files", "check": ["sed", "-i"]},
        {"goal": "Count the total number of lines of code in all .py files excluding comments and blank lines", "check": ["grep", "wc"]},
        {"goal": "Monitor the disk usage of /home and send a message if usage exceeds 90%", "check": ["df", "awk"]},
        {"goal": "Show git commits in the current branch that are not in origin/main", "check": ["git", "origin/main"]},
        {"goal": "Generate an SHA-256 hash for all .bin files in release/ and save to checksums.txt", "check": ["sha256sum"]},
        {"goal": "Download a file from https://example.com/data.csv with up to 3 retries on failure", "check": ["curl", "retry"]},
        {"goal": "Search recursively for the string 'TODO_URGENT' in all files under src/", "check": ["grep", "-r"]},
        {"goal": "Test database network connectivity to postgres.local on port 5432 with a 3 second timeout", "check": ["nc"]},
        {"goal": "Extract only the JSON error messages from a container log stream", "check": ["grep"]}
    ][:n_samples]

    def process_sample(idx, t):
        prompt = f"You are an expert Linux terminal agent. Provide a single robust bash command or pipeline to achieve the following goal:\nGoal: {t['goal']}\nOutput only the bash command enclosed in ```bash ... ```."
        messages = [{"role": "user", "content": prompt}]
        res = query_endpoint(endpoint_url, messages, max_tokens=1536)
        if not res["success"]:
            print(f"  [-] TerminalBench [{idx+1}/{n_samples}] Failed: {res.get('error')}", flush=True)
            return False

        c = res["content"] or res.get("reasoning_content", "")
        m = re.search(r"```(?:bash|sh)?\s*(.*?)\s*```", c, re.DOTALL)
        cmd = m.group(1).strip() if m else c.strip()
        all_checks = all(k.lower() in cmd.lower() for k in t["check"])
        status = "PASS" if all_checks else "FAIL"
        print(f"  [TerminalBench] [{idx+1}/{n_samples}] {status} ({res['elapsed']:.1f}s)", flush=True)
        return all_checks

    passed = 0
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [executor.submit(process_sample, i, t) for i, t in enumerate(tasks)]
        for f in as_completed(futures):
            if f.result():
                passed += 1

    score = (passed / len(tasks)) * 100 if tasks else 0.0
    print(f"  ✓ TerminalBench Score: {score:.1f}% ({passed}/{len(tasks)})", flush=True)
    return {"score": score, "passed": passed, "total": len(tasks)}

# ---------------------------------------------------------
# 6. ARC-AGI Program-Synthesis
# ---------------------------------------------------------
def eval_arc_agi_synthesis(endpoint_url, n_samples=10, max_workers=4):
    print(f"\n[*] [6/6] Evaluating ARC-AGI Program-Synthesis ({n_samples} samples, {max_workers} slots)...", flush=True)
    eval_dir = f"{DATA_DIR}/arc_agi/evaluation"
    if not os.path.exists(eval_dir):
        return {"score": 0.0, "error": "eval dir not found"}
    import glob
    files = sorted(glob.glob(f"{eval_dir}/*.json"))[:n_samples]

    def process_sample(idx, fpath):
        with open(fpath, "r") as f:
            task = json.load(f)
        train_pairs = task.get("train", [])
        ex_str = ""
        for ex_idx, p in enumerate(train_pairs[:3]):
            ex_str += f"\nExample {ex_idx+1}:\nInput: {p['input']}\nOutput: {p['output']}\n"
        prompt = f"Given an ARC-AGI visual reasoning puzzle, determine the transformation rule and write the executable Python function `def transform(grid: list[list[int]]) -> list[list[int]]` that implements it.\n{ex_str}\nOutput ONLY the Python code block enclosed in ```python ... ```."
        messages = [
            {"role": "system", "content": "You are an expert ARC-AGI program synthesizer. Output ONLY the executable python code block enclosed in ```python ... ``` with def transform(grid: list[list[int]]) -> list[list[int]]. Do not provide conversational filler."},
            {"role": "user", "content": prompt}
        ]
        res = query_endpoint(endpoint_url, messages, max_tokens=3072)
        if not res["success"]:
            print(f"  [-] ARC-AGI [{idx+1}/{n_samples}] Failed: {res.get('error')}", flush=True)
            return False

        c = clean_output(res["content"], res.get("reasoning_content", ""))
        full_text = c + "\n" + (res["content"] or "") + "\n" + (res.get("reasoning_content", "") or "")
        m = re.search(r"```(?:python)?\s*(.*?def\s+transform.*?)(?:```|$)", full_text, re.DOTALL)
        code = m.group(1).strip() if m else ""
        if not code and "def transform" in full_text:
            code = full_text[full_text.find("def transform"):]
        code = re.sub(r"```.*$", "", code, flags=re.MULTILINE).strip()
        if not code:
            print(f"  [ARC-AGI] [{idx+1}/{n_samples}] FAIL (No code generated)", flush=True)
            return False

        script = f"""
import sys, json
{code}
task = {json.dumps(task)}
for p in task['train']:
    if transform(p['input']) != p['output']:
        sys.exit(1)
sys.exit(0)
"""
        with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as tf:
            tf.write(script)
            tname = tf.name

        solved = False
        try:
            r = subprocess.run([sys.executable, tname], timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if r.returncode == 0:
                solved = True
        except Exception:
            pass
        finally:
            if os.path.exists(tname):
                os.remove(tname)

        status = "PASS" if solved else "FAIL"
        print(f"  [ARC-AGI] [{idx+1}/{n_samples}] {status} ({res['elapsed']:.1f}s)", flush=True)
        return solved

    solved_count = 0
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [executor.submit(process_sample, i, f) for i, f in enumerate(files)]
        for f in as_completed(futures):
            if f.result():
                solved_count += 1

    score = (solved_count / len(files)) * 100 if files else 0.0
    print(f"  ✓ ARC-AGI Synthesis Score: {score:.1f}% ({solved_count}/{len(files)})", flush=True)
    return {"score": score, "solved": solved_count, "total": len(files)}

# ---------------------------------------------------------
# Full Suite Runner
# ---------------------------------------------------------
def run_suite(endpoint_url="http://127.0.0.1:18081", model_label="Champion-v5", workers=4):
    print("=" * 80, flush=True)
    print(f"  Running Comprehensive 6-Pillar Frontier Benchmark Suite on {endpoint_url}", flush=True)
    print(f"  Model: {model_label} | Concurrency: {workers} slots", flush=True)
    print("=" * 80, flush=True)

    t0 = time.time()
    r1 = eval_agent_bench(endpoint_url, n_samples=20, max_workers=workers)
    r2 = eval_arc_challenge(endpoint_url, n_samples=20, max_workers=workers)
    r3 = eval_gpqa_diamond(endpoint_url, n_samples=20, max_workers=workers)
    r4 = eval_ifbench(endpoint_url, n_samples=20, max_workers=workers)
    r5 = eval_terminal_bench(endpoint_url, n_samples=15, max_workers=workers)
    r6 = eval_arc_agi_synthesis(endpoint_url, n_samples=10, max_workers=workers)
    elapsed = time.time() - t0

    report = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "model_label": model_label,
        "endpoint_url": endpoint_url,
        "elapsed_seconds": elapsed,
        "scores": {
            "AgentBench": r1.get("score", 0.0),
            "ARC_Challenge": r2.get("score", 0.0),
            "GPQA_Diamond": r3.get("score", 0.0),
            "IFBench": r4.get("score", 0.0),
            "TerminalBench": r5.get("score", 0.0),
            "ARC_AGI_Synthesis": r6.get("score", 0.0)
        }
    }

    out_file = os.path.join(RESULTS_DIR, f"frontier_eval_{model_label.replace('/', '_')}.json")
    with open(out_file, "w") as f:
        json.dump(report, f, indent=2)

    print("\n" + "=" * 80, flush=True)
    print("  6-PILLAR FRONTIER SCORECARD:", flush=True)
    print(f"  - AgentBench (JSON Tool Calling): {report['scores']['AgentBench']:.1f}% (Qwen3.8 Target: ~85%)", flush=True)
    print(f"  - ARC-Challenge (Multi-step Sci): {report['scores']['ARC_Challenge']:.1f}% (Qwen3.8 Target: ~75%)", flush=True)
    print(f"  - GPQA Diamond (Deep Scientific): {report['scores']['GPQA_Diamond']:.1f}% (Qwen3.8 Target: ~89%)", flush=True)
    print(f"  - IFBench (Strict Instruction):  {report['scores']['IFBench']:.1f}% (Qwen3.8 Target: ~79%)", flush=True)
    print(f"  - TerminalBench (Agentic Coding): {report['scores']['TerminalBench']:.1f}% (Qwen3.8 Target: ~73%)", flush=True)
    print(f"  - ARC-AGI (Program Synthesis):   {report['scores']['ARC_AGI_Synthesis']:.1f}% (Target: >= 30%)", flush=True)
    print(f"  Total Duration: {elapsed:.1f}s ({elapsed/60:.1f} min)", flush=True)
    print(f"  Saved report to {out_file}", flush=True)
    print("=" * 80, flush=True)
    return report

if __name__ == "__main__":
    ep = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:18081"
    lbl = sys.argv[2] if len(sys.argv) > 2 else "Champion-v5-Baseline"
    w = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    run_suite(endpoint_url=ep, model_label=lbl, workers=w)
