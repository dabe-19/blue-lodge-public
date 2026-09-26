#!/usr/bin/env python3
"""
ARC-AGI Stage 2 Curriculum Generator & Self-Repair Miner:
- Runs across tasks from data/arc_agi/training/
- Executes candidate transform(grid) functions in sandbox
- Performs Turn 2 self-repair on failed assertions
- Formats winning trajectories, self-repairs, and negative samples into:
  data/training/arc_agi_stage2_curriculum.jsonl
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

TRAIN_DIR = "/home/wsl-ops/blue-lodge/data/arc_agi/training"
OUTPUT_CURRICULUM = "/home/wsl-ops/blue-lodge/data/training/arc_agi_stage2_curriculum.jsonl"
os.makedirs(os.path.dirname(OUTPUT_CURRICULUM), exist_ok=True)

def query_endpoint(endpoint_url, messages, max_tokens=1024, temperature=0.2):
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
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            msg = data.get("choices", [{}])[0].get("message", {})
            return {
                "success": True,
                "content": msg.get("content", ""),
                "reasoning_content": msg.get("reasoning_content", "")
            }
    except Exception as e:
        return {"success": False, "error": str(e)}

def extract_python_code(content, reasoning=""):
    sources = [content]
    if reasoning:
        sources.append(reasoning)
    for src in sources:
        if not src:
            continue
        matches = re.findall(r"```(?:python)?\s*(.*?def\s+transform.*?)\s*```", src, re.DOTALL)
        if matches:
            return matches[-1]
        m = re.search(r"(def\s+transform\(.*)", src, re.DOTALL)
        if m:
            code = m.group(1)
            lines = [l for l in code.split("\n") if not (l.startswith("#") and not l.startswith("# "))]
            return "\n".join(lines)
    return None

def test_code_in_sandbox(code_str: str, task_data: dict):
    script = f"""
import sys, json
{code_str}
task = {json.dumps(task_data)}
train_pairs = task.get("train", [])
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
print(json.dumps({{"status": "SUCCESS"}}))
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
    except Exception as e:
        return {"status": "TIMEOUT", "error": str(e)}
    finally:
        if os.path.exists(tf_name):
            os.remove(tf_name)

def build_prompt(task_data: dict) -> str:
    prompt = "You are an autonomous AI software engineer. You are given an ARC-AGI grid transformation puzzle.\n"
    prompt += "Analyze the visual demonstration input/output pairs and write a Python function `def transform(grid: list[list[int]]) -> list[list[int]]` that implements the exact transformation rule.\n\n"
    for i, pair in enumerate(task_data.get("train", [])):
        prompt += f"--- Example {i+1} ---\nInput:\n{json.dumps(pair['input'])}\nOutput:\n{json.dumps(pair['output'])}\n\n"
    prompt += "First, reason step-by-step about dimensions, colors, coordinate shifts, and object rules.\n"
    prompt += "Then write the complete `def transform(grid)` function enclosed in ```python ... ```."
    return prompt

def mine_curriculum(endpoint_url: str, n_tasks: int = 35):
    print("=" * 80)
    print(f"  Mining ARC-AGI Empirical Trajectories & Self-Repairs from {endpoint_url}")
    print(f"  Task Pool: {n_tasks} tasks from {TRAIN_DIR}")
    print("=" * 80)

    task_files = sorted(glob.glob(os.path.join(TRAIN_DIR, "*.json")))[:n_tasks]
    records = []
    t0 = time.time()
    success_count = 0
    repair_count = 0

    for idx, t_file in enumerate(task_files):
        t_id = os.path.splitext(os.path.basename(t_file))[0]
        with open(t_file, "r") as f:
            task_data = json.load(f)

        prompt1 = build_prompt(task_data)
        messages = [{"role": "user", "content": prompt1}]

        print(f"[{idx+1:2d}/{n_tasks}] Task {t_id}...")
        res1 = query_endpoint(endpoint_url, messages)
        if not res1["success"]:
            continue

        code1 = extract_python_code(res1["content"], res1.get("reasoning_content", ""))
        if not code1:
            records.append({
                "task_id": t_id,
                "prompt": prompt1,
                "completion": res1["content"],
                "reasoning": res1.get("reasoning_content", ""),
                "status": "NO_CODE",
                "reward": -1.0,
                "turn": 1
            })
            continue

        eval1 = test_code_in_sandbox(code1, task_data)
        if eval1.get("status") == "SUCCESS":
            print(f"  ✓ Turn 1 Direct Pass!")
            success_count += 1
            records.append({
                "task_id": t_id,
                "prompt": prompt1,
                "completion": res1["content"],
                "reasoning": res1.get("reasoning_content", ""),
                "code": code1,
                "status": "DIRECT_PASS",
                "reward": 3.0,
                "turn": 1
            })
            continue

        # Turn 2: Self-repair
        err = eval1.get("diff") or eval1.get("error") or "Assertion mismatch"
        repair_user_msg = f"Your code was tested in the Blue Lodge sandbox and failed with:\n{err}\nPlease inspect the error, adjust your logic, and output the corrected `def transform(grid)` function enclosed in ```python ... ```."
        
        messages.append({"role": "assistant", "content": res1["content"]})
        messages.append({"role": "user", "content": repair_user_msg})

        res2 = query_endpoint(endpoint_url, messages)
        if not res2["success"]:
            continue

        code2 = extract_python_code(res2["content"], res2.get("reasoning_content", ""))
        if code2:
            eval2 = test_code_in_sandbox(code2, task_data)
            if eval2.get("status") == "SUCCESS":
                print(f"  ✓ Turn 2 Self-Repair Success!")
                repair_count += 1
                records.append({
                    "task_id": t_id,
                    "prompt": repair_user_msg,
                    "completion": res2["content"],
                    "reasoning": res2.get("reasoning_content", ""),
                    "code": code2,
                    "status": "SELF_REPAIR_SUCCESS",
                    "reward": 2.5,
                    "turn": 2
                })
            else:
                records.append({
                    "task_id": t_id,
                    "prompt": repair_user_msg,
                    "completion": res2["content"],
                    "reasoning": res2.get("reasoning_content", ""),
                    "code": code2,
                    "status": "SELF_REPAIR_FAILED",
                    "reward": -0.5,
                    "turn": 2
                })

    with open(OUTPUT_CURRICULUM, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")

    print("=" * 80)
    print(f"  [✓] Mined {len(records)} Stage 2 Trajectories in {time.time()-t0:.1f}s")
    print(f"      Direct Passes:       {success_count}")
    print(f"      Self-Repairs:        {repair_count}")
    print(f"      Curriculum Saved:    {OUTPUT_CURRICULUM} ({os.path.getsize(OUTPUT_CURRICULUM)/(1024):.1f} KB)")
    print("=" * 80)

if __name__ == "__main__":
    ep = sys.argv[1] if len(sys.argv) > 1 else "http://172.19.0.5:18081"
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 25
    mine_curriculum(ep, n_tasks=n)
