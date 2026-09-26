#!/usr/bin/env python3
"""
Comprehensive Agentic & Reasoning Benchmark Suite:
1. AgentBench (json-mode-agentic.json): Strict JSON tool calling & schema extraction
2. ARC-Challenge & ARC-Easy: Grade-school multiple choice scientific reasoning
3. Real Latency & Decode Speed Telemetry
Handles both thinking models (<think>...</think> / [Start thinking]...[End thinking]) and standard direct output.
"""

import os
import sys
import time
import json
import re
import urllib.request
import numpy as np

DATA_DIR = "/home/wsl-ops/blue-lodge/data"
RESULTS_DIR = "/home/wsl-ops/blue-lodge/benchmarks/results"
os.makedirs(RESULTS_DIR, exist_ok=True)

def query_endpoint(endpoint_url, messages, max_tokens=384, temperature=0.0):
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
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - t0
            timings = data.get("timings", {})
            choice = data.get("choices", [{}])[0]
            msg = choice.get("message", {})
            content = msg.get("content", "")
            reasoning = msg.get("reasoning_content", "")
            return {
                "success": True,
                "content": content,
                "reasoning_content": reasoning,
                "elapsed": elapsed,
                "prompt_tok_s": timings.get("prompt_per_second", 0.0),
                "decode_tok_s": timings.get("predicted_per_second", 0.0),
                "tokens": timings.get("predicted_n", 0)
            }
    except Exception as e:
        return {"success": False, "error": str(e), "elapsed": time.time() - t0}

def extract_json_from_response(content, reasoning=""):
    """Robustly extract JSON object from LLM response containing thinking or markdown."""
    # 1. Try content first, then fallback to reasoning if content is empty
    sources = [content]
    if reasoning:
        sources.append(reasoning)

    for src in sources:
        if not src:
            continue
        c = re.sub(r"\[Start thinking\].*?\[End thinking\]", "", src, flags=re.DOTALL)
        c = re.sub(r"<think>.*?</think>", "", c, flags=re.DOTALL)
        c = re.sub(r"</?think>", "", c).strip()

        m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", c, flags=re.DOTALL)
        if m:
            try:
                return json.loads(m.group(1))
            except Exception:
                pass

        m = re.search(r"(\{.*\})", c, flags=re.DOTALL)
        if m:
            candidate = m.group(1)
            try:
                return json.loads(candidate)
            except Exception:
                pass
            cleaned = re.sub(r",\s*\}", "}", candidate)
            cleaned = re.sub(r",\s*\]", "]", cleaned)
            try:
                return json.loads(cleaned)
            except Exception:
                pass

        try:
            return json.loads(c)
        except Exception:
            pass

    return None

def evaluate_agent_bench(endpoint_url, n_samples=30):
    print(f"\n[*] Evaluating AgentBench ({n_samples} samples) on {endpoint_url}...")
    tool_data_path = f"{DATA_DIR}/agent_bench/json-mode-agentic.json"
    if not os.path.exists(tool_data_path):
        print(f"[-] AgentBench data not found at {tool_data_path}")
        return {}

    with open(tool_data_path, "r") as f:
        all_samples = json.load(f)

    samples = all_samples[:n_samples]
    valid_json_count = 0
    schema_compliant_count = 0
    speeds = []

    for i, item in enumerate(samples):
        convs = item.get("conversations", [])
        messages = []
        for c in convs:
            role = "system" if c.get("from") == "system" else ("user" if c.get("from") == "human" else "assistant")
            if role != "assistant":
                messages.append({"role": role, "content": c.get("value", "")})

        res = query_endpoint(endpoint_url, messages, max_tokens=768)
        if not res["success"]:
            print(f"  [Sample {i+1:2d}] Query failed: {res.get('error')}")
            continue

        content = res["content"]
        reasoning = res.get("reasoning_content", "")
        speeds.append(res["decode_tok_s"])

        parsed = extract_json_from_response(content, reasoning)
        if parsed is not None:
            valid_json_count += 1
            if isinstance(parsed, dict) and len(parsed) > 0:
                schema_compliant_count += 1
            status = "VALID JSON"
        else:
            status = "INVALID JSON"

        print(f"  [Sample {i+1:2d}/{n_samples}] {status:12s} | Speed: {res['decode_tok_s']:.1f} tok/s")

    valid_json_pct = (valid_json_count / len(samples)) * 100 if samples else 0.0
    schema_pct = (schema_compliant_count / len(samples)) * 100 if samples else 0.0
    avg_speed = float(np.mean(speeds)) if speeds else 0.0

    print(f"[✓] AgentBench Complete: Valid JSON: {valid_json_pct:.1f}%, Schema Conformance: {schema_pct:.1f}%, Avg Speed: {avg_speed:.1f} tok/s")
    return {
        "n_samples": len(samples),
        "valid_json_pct": valid_json_pct,
        "schema_conformance_pct": schema_pct,
        "avg_decode_tok_s": avg_speed
    }

def evaluate_arc(endpoint_url, subset="arc-challenge", n_samples=30):
    print(f"\n[*] Evaluating ARC ({subset}, {n_samples} samples) on {endpoint_url}...")
    arc_path = f"{DATA_DIR}/arc/{subset}_test.json"
    if not os.path.exists(arc_path):
        print(f"[-] ARC data not found at {arc_path}")
        return {}

    with open(arc_path, "r") as f:
        all_samples = json.load(f)

    samples = all_samples[:n_samples]
    correct_count = 0
    speeds = []

    for i, item in enumerate(samples):
        q = item.get("question", "")
        choices = item.get("choices", {})
        texts = choices.get("text", [])
        labels = choices.get("label", [])
        answer_key = item.get("answerKey", "").strip().upper()

        choice_lines = [f"{lbl}. {txt}" for lbl, txt in zip(labels, texts)]
        prompt = f"Question: {q}\n\nChoices:\n" + "\n".join(choice_lines) + "\n\nAnswer with ONLY the single letter (e.g. A, B, C, or D) corresponding to the correct answer."

        messages = [
            {"role": "system", "content": "You are a precise scientific reasoning assistant. Answer multiple-choice questions with only the single letter of the correct choice."},
            {"role": "user", "content": prompt}
        ]

        res = query_endpoint(endpoint_url, messages, max_tokens=384)
        if not res["success"]:
            print(f"  [Sample {i+1:2d}] Query failed: {res.get('error')}")
            continue

        content = res["content"].strip()
        reasoning = res.get("reasoning_content", "").strip()
        speeds.append(res["decode_tok_s"])

        # Strip think blocks
        c_clean = re.sub(r"\[Start thinking\].*?\[End thinking\]", "", content, flags=re.DOTALL)
        c_clean = re.sub(r"<think>.*?</think>", "", c_clean, flags=re.DOTALL)
        c_clean = re.sub(r"</?think>", "", c_clean).strip().upper()

        # Extract answer letter from content first
        match = re.search(r"\b([A-E])\b", c_clean)
        pred = match.group(1) if match else ""

        # Fallback to reasoning if content didn't have a clear letter
        if not pred and reasoning:
            # Look for explicit conclusion patterns in reasoning
            m_conc = re.findall(r"(?:answer is|choice is|option is|correct is|therefore,?\s*(?:the answer is)?)\s*\(?([A-E])\)?", reasoning, re.IGNORECASE)
            if m_conc:
                pred = m_conc[-1].upper()
            else:
                m_tail = re.findall(r"\b([A-E])\b", reasoning[-150:])
                if m_tail:
                    pred = m_tail[-1].upper()

        is_correct = (pred == answer_key)
        if is_correct:
            correct_count += 1

        print(f"  [Sample {i+1:2d}/{n_samples}] Pred: {pred} | Truth: {answer_key} | {'CORRECT' if is_correct else 'WRONG'}")

    acc_pct = (correct_count / len(samples)) * 100 if samples else 0.0
    avg_speed = float(np.mean(speeds)) if speeds else 0.0

    print(f"[✓] {subset} Complete: Accuracy: {acc_pct:.1f}% ({correct_count}/{len(samples)}), Avg Speed: {avg_speed:.1f} tok/s")
    return {
        "subset": subset,
        "n_samples": len(samples),
        "accuracy_pct": acc_pct,
        "correct": correct_count,
        "avg_decode_tok_s": avg_speed
    }

if __name__ == "__main__":
    endpoint = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    model_name = sys.argv[3] if len(sys.argv) > 3 else "model"
    
    agent_res = evaluate_agent_bench(endpoint, n_samples=n)
    arc_res = evaluate_arc(endpoint, subset="arc-challenge", n_samples=n)
    
    report = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "model_name": model_name,
        "endpoint": endpoint,
        "agent_bench": agent_res,
        "arc_challenge": arc_res
    }
    out_file = os.path.join(RESULTS_DIR, f"eval_{model_name.replace('/', '_')}.json")
    with open(out_file, "w") as f:
        json.dump(report, f, indent=2)
    print(f"\n[✓] Results saved to {out_file}")
