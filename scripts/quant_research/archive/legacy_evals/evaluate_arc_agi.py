#!/usr/bin/env python3
"""
ARC-AGI Program-Synthesis & Test-Repair Evaluator for Blue Lodge:
- Evaluates N tasks from data/arc_agi/evaluation/
- Prompts model to synthesize `def transform(grid: list[list[int]]) -> list[list[int]]`
- Executes code in sandboxed Python subprocess against train demonstration pairs
- If train assertions fail, sends error/diff back for Turn 2 Self-Repair
- Validates against ground-truth test output
"""

import os
import sys
import time
import json
import glob
import re
import urllib.request
import subprocess
import tempfile
import numpy as np

DATA_DIR = "/home/wsl-ops/blue-lodge/data/arc_agi/evaluation"
RESULTS_DIR = "/home/wsl-ops/blue-lodge/benchmarks/results"
os.makedirs(RESULTS_DIR, exist_ok=True)

def query_endpoint(endpoint_url, messages, max_tokens=2048, temperature=0.0):
    req_body = json.dumps({
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "reasoning_effort": "medium",
        "stream": False
    }).encode("utf-8")

    req = urllib.request.Request(
        f"{endpoint_url}/v1/chat/completions",
        data=req_body,
        headers={"Content-Type": "application/json"}
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - t0
            timings = data.get("timings", {})
            choice = data.get("choices", [{}])[0]
            msg = choice.get("message", {})
            return {
                "success": True,
                "content": msg.get("content", ""),
                "reasoning_content": msg.get("reasoning_content", ""),
                "elapsed": elapsed,
                "decode_tok_s": timings.get("predicted_per_second", 0.0),
                "tokens": timings.get("predicted_n", 0)
            }
    except Exception as e:
        return {"success": False, "error": str(e), "elapsed": time.time() - t0}

def extract_python_code(content, reasoning=""):
    """Extract def transform Python function from LLM response."""
    sources = [content]
    if reasoning:
        sources.append(reasoning)

    for src in sources:
        if not src:
            continue
        # Look for fenced python code blocks first
        matches = re.findall(r"```(?:python)?\s*(.*?def\s+transform.*?)\s*```", src, re.DOTALL)
        if matches:
            return matches[-1].strip()

        # Look for def transform function directly
        m = re.search(r"(def\s+transform\(.*)", src, re.DOTALL)
        if m:
            code = m.group(1)
            # Truncate at end of function or next markdown header
            lines = []
            for line in code.split("\n"):
                if line.startswith("#") and not line.startswith("# "):
                    break
                lines.append(line)
            return "\n".join(lines).strip()
    return None

def test_code_in_sandbox(code_str: str, task_data: dict):
    """Executes transform(grid) against train and test pairs in isolated Python subprocess."""
    script = f"""
import sys, json

{code_str}

task = {json.dumps(task_data)}

train_pairs = task.get("train", [])
test_pairs = task.get("test", [])

# Test against training demonstration pairs
for i, pair in enumerate(train_pairs):
    inp = pair["input"]
    expected = pair["output"]
    try:
        actual = transform(inp)
    except Exception as e:
        print(json.dumps({{"status": "EXCEPTION", "example": i, "error": str(e)}}))
        sys.exit(0)
    if actual != expected:
        diff_info = f"Shape actual: ({{len(actual)}}, {{len(actual[0]) if actual else 0}}) vs expected: ({{len(expected)}}, {{len(expected[0]) if expected else 0}})"
        print(json.dumps({{"status": "TRAIN_MISMATCH", "example": i, "diff": diff_info}}))
        sys.exit(0)

# Training pairs passed! Now test against held-out test input
test_inp = test_pairs[0]["input"]
test_expected = test_pairs[0]["output"]
try:
    test_actual = transform(test_inp)
except Exception as e:
    print(json.dumps({{"status": "TEST_EXCEPTION", "error": str(e)}}))
    sys.exit(0)

if test_actual == test_expected:
    print(json.dumps({{"status": "SUCCESS"}}))
else:
    print(json.dumps({{"status": "TEST_MISMATCH"}}))
"""
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as tf:
        tf.write(script)
        tf_name = tf.name

    try:
        res = subprocess.run([sys.executable, tf_name], capture_output=True, text=True, timeout=5)
        stdout = res.stdout.strip()
        if not stdout:
            return {"status": "CRASH", "error": res.stderr}
        try:
            return json.loads(stdout.split("\n")[-1])
        except Exception:
            return {"status": "PARSE_ERROR", "raw": stdout}
    except subprocess.TimeoutExpired:
        return {"status": "TIMEOUT", "error": "Execution exceeded 5.0s"}
    except Exception as e:
        return {"status": "SUBPROCESS_ERROR", "error": str(e)}
    finally:
        if os.path.exists(tf_name):
            os.remove(tf_name)

def build_arc_prompt(task_data: dict) -> str:
    prompt = "You are an autonomous AI software engineer. You are given an ARC-AGI grid transformation puzzle.\n"
    prompt += "Analyze the visual demonstration input/output pairs and write a Python function `def transform(grid: list[list[int]]) -> list[list[int]]` that implements the exact transformation rule.\n\n"
    for i, pair in enumerate(task_data.get("train", [])):
        prompt += f"--- Example {i+1} ---\n"
        prompt += f"Input:\n{json.dumps(pair['input'])}\n"
        prompt += f"Output:\n{json.dumps(pair['output'])}\n\n"
    prompt += "Test Input to be transformed:\n"
    prompt += f"{json.dumps(task_data['test'][0]['input'])}\n\n"
    prompt += "First, reason step-by-step about grid dimensions, color patterns, coordinate shifts, and object rules.\n"
    prompt += "Then output the complete `def transform(grid)` function enclosed in ```python ... ```."
    return prompt

def evaluate_arc_agi(endpoint_url: str, n_tasks: int = 15):
    print("=" * 80, flush=True)
    print(f"  ARC-AGI Program-Synthesis & Test-Repair Evaluator on {endpoint_url}", flush=True)
    print(f"  Evaluation Tasks: {n_tasks} from {DATA_DIR}", flush=True)
    print("=" * 80, flush=True)

    task_files = sorted(glob.glob(os.path.join(DATA_DIR, "*.json")))[:n_tasks]
    if not task_files:
        print(f"[-] No ARC-AGI task files found in {DATA_DIR}", flush=True)
        return {}

    results = []
    t0 = time.time()
    train_pass_count = 0
    test_pass_count = 0
    self_repair_count = 0

    for idx, t_file in enumerate(task_files):
        t_id = os.path.splitext(os.path.basename(t_file))[0]
        with open(t_file, "r") as f:
            task_data = json.load(f)

        prompt = build_arc_prompt(task_data)
        messages = [
            {"role": "user", "content": prompt}
        ]

        # Turn 1: Initial Synthesis
        print(f"\n[{idx+1:2d}/{n_tasks}] Evaluating Task {t_id}...", flush=True)
        res1 = query_endpoint(endpoint_url, messages, max_tokens=2048)
        if not res1["success"]:
            print(f"  [Turn 1] API Query Failed: {res1.get('error')}", flush=True)
            continue

        reasoning1 = res1.get("reasoning_content", "")
        if reasoning1:
            # Print excerpt of reasoning trace
            first_line = reasoning1.strip().split("\n")[0][:100]
            print(f"  [Turn 1 Reasoning]: {first_line} ... ({len(reasoning1)} chars)", flush=True)

        code1 = extract_python_code(res1["content"], reasoning1)
        if not code1:
            print(f"  [Turn 1] No Python transform function found.", flush=True)
            results.append({"task_id": t_id, "status": "NO_CODE", "turn": 1})
            continue

        print(f"  [Turn 1 Code Synthesized]:\n{code1[:160]}...", flush=True)
        eval1 = test_code_in_sandbox(code1, task_data)
        status1 = eval1.get("status")
        print(f"  [Turn 1] Sandbox Execution: {status1}", flush=True)

        if status1 == "SUCCESS":
            train_pass_count += 1
            test_pass_count += 1
            print(f"  ✓ SOLVED on Turn 1!", flush=True)
            results.append({"task_id": t_id, "status": "SOLVED", "turn": 1, "code": code1})
            continue

        if status1 == "TEST_MISMATCH":
            train_pass_count += 1
            print(f"  ✓ Passed all training examples (Generalization discrepancy on test)", flush=True)
            results.append({"task_id": t_id, "status": "TRAIN_PASSED_ONLY", "turn": 1, "code": code1})
            continue

        # Turn 2: Self-Repair Loop
        err_msg = ""
        if status1 == "TRAIN_MISMATCH":
            err_msg = f"Your function failed on Example {eval1.get('example')+1}: {eval1.get('diff')}"
        elif status1 == "EXCEPTION":
            err_msg = f"Your function raised an exception on Example {eval1.get('example')+1}: {eval1.get('error')}"
        else:
            err_msg = f"Your function failed in execution: {eval1}"

        repair_prompt = f"Your synthesized code was tested in the Blue Lodge sandbox and failed with the following feedback:\n{err_msg}\n\nPlease inspect the error, adjust your logic, and output the corrected `def transform(grid)` function enclosed in ```python ... ```."
        assistant_content = res1["content"] if res1["content"] else f"```python\n{code1}\n```"
        messages.append({"role": "assistant", "content": assistant_content})
        messages.append({"role": "user", "content": repair_prompt})

        print(f"  [Turn 2] Attempting Self-Repair ({err_msg[:60]}...)...", flush=True)
        res2 = query_endpoint(endpoint_url, messages, max_tokens=2048)
        if not res2["success"]:
            print(f"  [Turn 2] API Query Failed: {res2.get('error')}", flush=True)
            results.append({"task_id": t_id, "status": "REPAIR_QUERY_FAILED", "turn": 2})
            continue

        reasoning2 = res2.get("reasoning_content", "")
        if reasoning2:
            print(f"  [Turn 2 Reasoning]: {reasoning2.strip().split(chr(10))[0][:100]} ...", flush=True)

        code2 = extract_python_code(res2["content"], reasoning2)
        if not code2:
            print(f"  [Turn 2] No Python code extracted in repair turn.", flush=True)
            results.append({"task_id": t_id, "status": "REPAIR_NO_CODE", "turn": 2})
            continue

        eval2 = test_code_in_sandbox(code2, task_data)
        status2 = eval2.get("status")
        print(f"  [Turn 2] Sandbox Execution: {status2}", flush=True)

        if status2 == "SUCCESS":
            train_pass_count += 1
            test_pass_count += 1
            self_repair_count += 1
            print(f"  ✓ SELF-REPAIRED & SOLVED on Turn 2!", flush=True)
            results.append({"task_id": t_id, "status": "SELF_REPAIRED", "turn": 2, "code": code2})
        elif status2 == "TEST_MISMATCH":
            train_pass_count += 1
            print(f"  ✓ Self-repair passed all training examples!", flush=True)
            results.append({"task_id": t_id, "status": "TRAIN_PASSED_ONLY", "turn": 2, "code": code2})
        else:
            print(f"  ✗ Failed after self-repair attempt.", flush=True)
            results.append({"task_id": t_id, "status": "FAILED", "turn": 2, "code": code2})

    total_tasks = len(task_files)
    train_pass_pct = (train_pass_count / total_tasks) * 100
    test_pass_pct = (test_pass_count / total_tasks) * 100

    print("=" * 80)
    print(f"  ARC-AGI Program-Synthesis Evaluation Complete in {time.time()-t0:.1f}s")
    print(f"  Tasks Evaluated:              {total_tasks}")
    print(f"  Train Example Pass Rate:      {train_pass_pct:.1f}% ({train_pass_count}/{total_tasks})")
    print(f"  Exact Test Solved Rate:       {test_pass_pct:.1f}% ({test_pass_count}/{total_tasks})")
    print(f"  Successful Self-Repairs:      {self_repair_count}")
    print("=" * 80)

    out_file = os.path.join(RESULTS_DIR, "eval_arc_agi_program_synthesis.json")
    report = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "endpoint": endpoint_url,
        "n_tasks": total_tasks,
        "train_pass_pct": train_pass_pct,
        "test_pass_pct": test_pass_pct,
        "self_repairs": self_repair_count,
        "task_results": results
    }
    with open(out_file, "w") as f:
        json.dump(report, f, indent=2)
    print(f"[✓] Results saved to {out_file}")
    return report

if __name__ == "__main__":
    ep = sys.argv[1] if len(sys.argv) > 1 else "http://172.19.0.5:18081"
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 15
    evaluate_arc_agi(ep, n_tasks=n)
