#!/usr/bin/env python3
"""
05_evaluate_blue_lodge_benchmark.py:
Comprehensive Blue Lodge Sovereign Benchmark Suite (BlueLodgeBench).

Directly evaluates the 5 critical dimensions of sovereign agent operation:
1. Tool Syntax & Typing: Zero XML leaks, zero nested stringified JSON, strict parameter types.
2. Action Execution: Direct tool emission vs thought monologue looping.
3. Safe File Modification: Non-destructive file_edit vs accidental file_write clobbering.
4. Git Operations & Model Management: Clean branching from develop, status check, conventional commit format.
5. Software Phytology Protocol: Direct phytology_manage invocation without tool_search aliasing.

Features:
- Automated Failure Extraction: Logs failed cases and produces targeted counter-examples for dataset re-engineering.
- Comprehensive Scorecard: Detailed metrics across 5 pillars with exact pass/partial/fail diagnostics.
"""

import os
import sys
import json
import re
import time
import urllib.request
import argparse
from typing import List, Dict, Any

RESULTS_DIR = "/home/wsl-ops/blue-lodge/benchmarks/results"
os.makedirs(RESULTS_DIR, exist_ok=True)

REENGINEERING_DIR = "/home/wsl-ops/blue-lodge/data/training"
os.makedirs(REENGINEERING_DIR, exist_ok=True)

def parse_args():
    parser = argparse.ArgumentParser(description="Blue Lodge Sovereign Benchmark Suite")
    parser.add_argument("--endpoint", type=str, default="http://127.0.0.1:8080", help="Active server endpoint")
    parser.add_argument("--model_label", type=str, default="Champion-v5-BlueLodge", help="Label for the model under test")
    parser.add_argument("--output", type=str, default=None, help="Output benchmark scorecard JSON")
    parser.add_argument("--extract_failures", action="store_true", default=True, help="Extract failures into re-engineering dataset")
    return parser.parse_args()

def query_endpoint(endpoint_url: str, messages: list, tools: list = None, max_tokens: int = 2048) -> dict:
    url = f"{endpoint_url}/v1/chat/completions"
    payload = {
        "messages": messages,
        "temperature": 0.0,
        "max_tokens": max_tokens,
        "reasoning_effort": "low",
        "stream": False
    }
    if tools:
        payload["tools"] = tools

    t0 = time.time()
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - t0
            choice = data.get("choices", [{}])[0]
            msg = choice.get("message", {})
            return {
                "success": True,
                "content": msg.get("content", ""),
                "reasoning": msg.get("reasoning_content", ""),
                "tool_calls": msg.get("tool_calls", []),
                "finish_reason": choice.get("finish_reason", ""),
                "elapsed": elapsed
            }
    except Exception as e:
        return {"success": False, "error": str(e), "elapsed": time.time() - t0}

def get_bedrock_tools():
    tools_path = "/home/wsl-ops/blue-lodge/data/training/native_core_tools.json"
    if os.path.exists(tools_path):
        try:
            with open(tools_path, "r", encoding="utf-8") as f:
                all_tools = json.load(f)
            bedrock_names = {
                "bash_exec", "file_read", "file_write", "file_edit", "file_grep",
                "dir_list", "phytology_manage", "code_symbol_get", "code_outline",
                "code_validate", "slash_command_exec", "tool_search"
            }
            return [t for t in all_tools if t.get("function", {}).get("name") in bedrock_names]
        except Exception:
            pass
    return []

# ── Benchmark Test Suites (5 Pillars, 10 Rigorous Cases Each = 50 Total) ───────

def get_test_cases():
    return {
        "Pillar 1: Tool Syntax & Typing": [
            {
                "prompt": "Check the status of software phytology living tissue.",
                "expected_tool": "phytology_manage",
                "expected_args": {"action": "status"},
                "forbid_xml": True,
                "forbid_nested_json": True
            },
            {
                "prompt": "Run an AST audit of foliage tissue using LRU cache.",
                "expected_tool": "phytology_manage",
                "expected_args": {"action": "audit", "flags": "--cached"},
                "forbid_xml": True,
                "forbid_nested_json": True
            },
            {
                "prompt": "Read lines 1 to 50 of lib/fifo_ipc.sh.",
                "expected_tool": "file_read",
                "expected_args": {"path": "lib/fifo_ipc.sh"},
                "forbid_xml": True,
                "forbid_nested_json": True
            },
            {
                "prompt": "Search for function '_react_trip_circuit_breaker' in directory 'lib'.",
                "expected_tool": "file_grep",
                "expected_args": {"path": "lib", "pattern": "_react_trip_circuit_breaker"},
                "forbid_xml": True,
                "forbid_nested_json": True
            },
            {
                "prompt": "List the contents of .george/cron_jobs up to depth 2.",
                "expected_tool": "dir_list",
                "expected_args": {"path": ".george/cron_jobs"},
                "forbid_xml": True,
                "forbid_nested_json": True
            },
            {
                "prompt": "Extract the outline of lib/phytology.sh using code_outline.",
                "expected_tool": "code_outline",
                "expected_args": {"path": "lib/phytology.sh"},
                "forbid_xml": True,
                "forbid_nested_json": True
            },
            {
                "prompt": "Inspect symbol 'phytology_fitness' in lib/phytology.sh using code_symbol_get.",
                "expected_tool": "code_symbol_get",
                "expected_args": {"path": "lib/phytology.sh", "symbol": "phytology_fitness"},
                "forbid_xml": True,
                "forbid_nested_json": True
            },
            {
                "prompt": "Validate bash syntax of lib/react.sh strictly using code_validate.",
                "expected_tool": "code_validate",
                "expected_args": {"path": "lib/react.sh", "strict": True},
                "forbid_xml": True,
                "forbid_nested_json": True
            },
            {
                "prompt": "Execute slash command /limits with argument 'status'.",
                "expected_tool": "slash_command_exec",
                "expected_args": {"command": "/limits", "args": "status"},
                "forbid_xml": True,
                "forbid_nested_json": True
            },
            {
                "prompt": "Do NOT nest JSON arguments. Call phytology_manage with action 'cache-status'.",
                "expected_tool": "phytology_manage",
                "expected_args": {"action": "cache-status"},
                "forbid_xml": True,
                "forbid_nested_json": True
            }
        ],
        "Pillar 2: Action Execution vs Monologue": [
            {
                "prompt": "Step 1: Check out a new Git feature branch from develop using bash_exec: git checkout -b feature/test-branch develop",
                "must_have_tool_call": True,
                "expected_tool": "bash_exec"
            },
            {
                "prompt": "Inspect the first 100 lines of lib/phytology.sh now using file_read.",
                "must_have_tool_call": True,
                "expected_tool": "file_read"
            },
            {
                "prompt": "Execute ./tests/test_phytology.sh to run the regression suite.",
                "must_have_tool_call": True,
                "expected_tool": "bash_exec"
            },
            {
                "prompt": "Assess the fitness of .george/cron_jobs/logic_quip.sh using phytology_manage.",
                "must_have_tool_call": True,
                "expected_tool": "phytology_manage"
            },
            {
                "prompt": "Search for 'circuit_breaker' in lib using file_grep. Do not deliberate in monologue.",
                "must_have_tool_call": True,
                "expected_tool": "file_grep"
            },
            {
                "prompt": "Run 'git status --short' immediately to inspect modified files.",
                "must_have_tool_call": True,
                "expected_tool": "bash_exec"
            },
            {
                "prompt": "List all snapshots in .george/snapshots using dir_list.",
                "must_have_tool_call": True,
                "expected_tool": "dir_list"
            },
            {
                "prompt": "Lignify .george/cron_jobs/logic_quip.sh into cambium core using phytology_manage.",
                "must_have_tool_call": True,
                "expected_tool": "phytology_manage"
            },
            {
                "prompt": "Execute git branch -a to check for active branches.",
                "must_have_tool_call": True,
                "expected_tool": "bash_exec"
            },
            {
                "prompt": "Trigger autonomic healing on .george/cron_jobs/research_publisher.sh with phytology_manage.",
                "must_have_tool_call": True,
                "expected_tool": "phytology_manage"
            }
        ],
        "Pillar 3: Safe File Operations (No Clobber)": [
            {
                "prompt": "Update lib/phytology.sh to add error handling for missing arguments using file_edit.",
                "must_use_tool": "file_edit",
                "forbidden_tool": "file_write"
            },
            {
                "prompt": "Refactor lib/react.sh to adjust the repetition window using file_edit.",
                "must_use_tool": "file_edit",
                "forbidden_tool": "file_write"
            },
            {
                "prompt": "Create a brand new scratch script at tmp/new_experiment.py with print('hello').",
                "must_use_tool": "file_write",
                "forbidden_tool": "file_edit"
            },
            {
                "prompt": "Update lib/cache.sh to support TTL expiration via file_edit.",
                "must_use_tool": "file_edit",
                "forbidden_tool": "file_write"
            },
            {
                "prompt": "Modify commands/phytology.sh to add the --cached flag using file_edit.",
                "must_use_tool": "file_edit",
                "forbidden_tool": "file_write"
            },
            {
                "prompt": "Write a new test file tests/test_new_feature.sh from scratch.",
                "must_use_tool": "file_write",
                "forbidden_tool": "file_edit"
            },
            {
                "prompt": "Patch lib/limits.sh to adjust MAX_CIRCUIT_RETRIES using file_edit.",
                "must_use_tool": "file_edit",
                "forbidden_tool": "file_write"
            },
            {
                "prompt": "Update lib/native_tools.sh to include phytology_manage in bedrock schema.",
                "must_use_tool": "file_edit",
                "forbidden_tool": "file_write"
            },
            {
                "prompt": "Create new configuration file configs/agent_limits.json with initial thresholds.",
                "must_use_tool": "file_write",
                "forbidden_tool": "file_edit"
            },
            {
                "prompt": "Update tests/test_react_circuit_breaker.sh with an extra test case using file_edit.",
                "must_use_tool": "file_edit",
                "forbidden_tool": "file_write"
            }
        ],
        "Pillar 4: Git Model Management": [
            {
                "prompt": "Create a feature branch named 'feature/async-flow-control' from 'develop' using bash_exec.",
                "expected_tool": "bash_exec",
                "required_substrings": ["git checkout -b feature/async-flow-control develop"]
            },
            {
                "prompt": "Check the git status in concise porcelain format.",
                "expected_tool": "bash_exec",
                "required_substrings": ["git status"]
            },
            {
                "prompt": "Stage lib/react.sh and commit with conventional message 'feat(react): add perturbation hook'.",
                "expected_tool": "bash_exec",
                "required_substrings": ["git add lib/react.sh", "feat(react): add perturbation hook"]
            },
            {
                "prompt": "Push branch 'feature/async-flow-control' to remote 'gitea'.",
                "expected_tool": "bash_exec",
                "required_substrings": ["git push gitea feature/async-flow-control"]
            },
            {
                "prompt": "Check if branch 'feature/test' already exists locally or remotely before creating it.",
                "expected_tool": "bash_exec",
                "required_substrings": ["git branch"]
            },
            {
                "prompt": "Inspect the last 5 commits on the current branch using git log.",
                "expected_tool": "bash_exec",
                "required_substrings": ["git log"]
            },
            {
                "prompt": "Show the diff stats for unstaged changes.",
                "expected_tool": "bash_exec",
                "required_substrings": ["git diff"]
            },
            {
                "prompt": "Stage lib/phytology.sh and commit with conventional message 'feat(phytology): implement phenotype fitness'.",
                "expected_tool": "bash_exec",
                "required_substrings": ["git add lib/phytology.sh", "feat(phytology): implement phenotype fitness"]
            },
            {
                "prompt": "Create a bugfix branch named 'fix/fifo-deadlock' branching cleanly off develop.",
                "expected_tool": "bash_exec",
                "required_substrings": ["git checkout -b fix/fifo-deadlock develop"]
            },
            {
                "prompt": "Check which remote URLs are configured for this repository.",
                "expected_tool": "bash_exec",
                "required_substrings": ["git remote"]
            }
        ],
        "Pillar 5: Software Phytology Protocol": [
            {
                "prompt": "Audit foliage health and AST syntax.",
                "expected_tool": "phytology_manage",
                "forbid_tools": ["tool_search"]
            },
            {
                "prompt": "Check living tissue status across Cambium and Foliage.",
                "expected_tool": "phytology_manage",
                "forbid_tools": ["tool_search"]
            },
            {
                "prompt": "Heal corrupted living tissue .george/cron_jobs/logic_quip.sh from snapshot.",
                "expected_tool": "phytology_manage",
                "expected_args": {"action": "heal"}
            },
            {
                "prompt": "Check phytology LRU cache hit rate and statistics.",
                "expected_tool": "phytology_manage",
                "expected_args": {"action": "cache-status"}
            },
            {
                "prompt": "Invalidate the phytology AST cache namespace.",
                "expected_tool": "phytology_manage",
                "expected_args": {"action": "cache-invalidate"}
            },
            {
                "prompt": "Run living tissue audit with --cached flag using mounted phytology_manage tool.",
                "expected_tool": "phytology_manage",
                "expected_args": {"action": "audit", "flags": "--cached"}
            },
            {
                "prompt": "Evaluate fitness score of foliage script .george/cron_jobs/research_publisher.sh.",
                "expected_tool": "phytology_manage",
                "expected_args": {"action": "fitness", "target": ".george/cron_jobs/research_publisher.sh"}
            },
            {
                "prompt": "Lignify .george/cron_jobs/research_publisher.sh into permanent cambium command.",
                "expected_tool": "phytology_manage",
                "expected_args": {"action": "lignify", "target": ".george/cron_jobs/research_publisher.sh"}
            },
            {
                "prompt": "Inspect Cambium tissue health. Do not call tool_search or search for external tools.",
                "expected_tool": "phytology_manage",
                "forbid_tools": ["tool_search"]
            },
            {
                "prompt": "Run full phytology test verification suite using phytology_manage.",
                "expected_tool": "phytology_manage",
                "expected_args": {"action": "test"}
            }
        ]
    }

def evaluate_case(case: dict, result: dict) -> dict:
    if not result.get("success"):
        return {"passed": False, "score": 0.0, "reason": f"Endpoint query error: {result.get('error')}", "failure_type": "query_error"}

    raw = (result.get("content") or "") + "\n" + (result.get("reasoning") or "")
    tool_calls = result.get("tool_calls", [])

    call_names = [tc.get("function", {}).get("name") for tc in tool_calls]
    call_args = []
    for tc in tool_calls:
        try:
            a = tc.get("function", {}).get("arguments", "{}")
            call_args.append(json.loads(a) if isinstance(a, str) else a)
        except Exception:
            call_args.append(None)

    # 1. Action Execution Check
    if case.get("must_have_tool_call") and not tool_calls:
        return {"passed": False, "score": 0.0, "reason": "Failed: Monologue thought loop without tool call emission", "failure_type": "monologue_loop"}

    # 2. Tool Name Matching
    exp_tool = case.get("expected_tool")
    if exp_tool and exp_tool not in call_names:
        return {"passed": False, "score": 0.0, "reason": f"Failed: Expected {exp_tool}, got {call_names}", "failure_type": "wrong_tool"}

    # 3. Forbidden Tools
    must_use = case.get("must_use_tool")
    if must_use and must_use not in call_names:
        return {"passed": False, "score": 0.0, "reason": f"Failed: Did not use required tool {must_use}", "failure_type": "missed_required_tool"}

    forbidden = case.get("forbidden_tool")
    if forbidden and forbidden in call_names:
        return {"passed": False, "score": 0.0, "reason": f"Failed: Used forbidden/dangerous tool {forbidden}", "failure_type": "used_forbidden_tool"}

    forbid_tools = case.get("forbid_tools", [])
    for ft in forbid_tools:
        if ft in call_names:
            return {"passed": False, "score": 0.0, "reason": f"Failed: Used forbidden fallback tool {ft}", "failure_type": "used_fallback_search"}

    # 4. XML Leak Check
    if case.get("forbid_xml"):
        for tc in tool_calls:
            args_str = json.dumps(tc.get("function", {}).get("arguments", ""))
            if any(x in args_str for x in ["</parameter>", "<parameter", "</function>", "<function", "<tool_call>"]):
                return {"passed": False, "score": 0.0, "reason": "Failed: XML tag leaked into JSON arguments", "failure_type": "xml_leak"}

    # 5. Nested JSON Stringification Check
    if case.get("forbid_nested_json"):
        for tc in tool_calls:
            args_str = json.dumps(tc.get("function", {}).get("arguments", ""))
            if '\"action\": \"{\"' in args_str or '\\\"action\\\": \\\"{\\\"' in args_str:
                return {"passed": False, "score": 0.0, "reason": "Failed: Nested stringified JSON detected in arguments", "failure_type": "nested_json"}

    # 6. Expected Args Matching
    exp_args = case.get("expected_args")
    if exp_args:
        found_match = False
        for ca in call_args:
            if ca and isinstance(ca, dict):
                match = True
                for k, v in exp_args.items():
                    if ca.get(k) != v:
                        match = False
                        break
                if match:
                    found_match = True
                    break
        if not found_match:
            return {"passed": False, "score": 0.5, "reason": f"Partial: Tool called but arguments mismatched. Expected {exp_args}, got {call_args}", "failure_type": "args_mismatch"}

    # 7. Required Substrings (e.g. in command)
    req_subs = case.get("required_substrings", [])
    for sub in req_subs:
        if not any(sub in json.dumps(ca) for ca in call_args if ca):
            return {"passed": False, "score": 0.5, "reason": f"Partial: Missing required substring '{sub}' in tool arguments", "failure_type": "substring_missing"}

    return {"passed": True, "score": 1.0, "reason": "Passed: Flawless tool call syntax and arguments", "failure_type": None}

def run_benchmark():
    args = parse_args()
    tools = get_bedrock_tools()
    test_suites = get_test_cases()

    print("=" * 80)
    print(f"  BLUE LODGE SOVEREIGN BENCHMARK (BlueLodgeBench)")
    print(f"  Model: {args.model_label} | Endpoint: {args.endpoint}")
    print(f"  Bedrock Tools Mounted: {len(tools)}")
    print("=" * 80)

    scorecard = {}
    total_passed = 0
    total_cases = 0
    failures = []

    xml_leak_count = 0
    nested_json_count = 0
    monologue_count = 0
    clobber_count = 0

    for pillar_name, cases in test_suites.items():
        print(f"\n[*] Evaluating {pillar_name} ({len(cases)} cases)...")
        p_passed = 0
        p_cases = len(cases)

        for idx, case in enumerate(cases, 1):
            messages = [
                {"role": "system", "content": "You are George, Blue Lodge sovereign AI coding assistant. Execute tasks using native tool calls with clean JSON parameters."},
                {"role": "user", "content": case["prompt"]}
            ]
            res = query_endpoint(args.endpoint, messages, tools=tools)
            eval_res = evaluate_case(case, res)

            score = eval_res["score"]
            status = "✓ PASS" if eval_res["passed"] else ("⚠ PARTIAL" if score > 0 else "✗ FAIL")
            print(f"  [{idx:02d}/{p_cases:02d}] {status} | Score: {score:.1f} | {eval_res['reason']}", flush=True)

            ft = eval_res.get("failure_type")
            if ft == "xml_leak": xml_leak_count += 1
            if ft == "nested_json": nested_json_count += 1
            if ft == "monologue_loop": monologue_count += 1
            if ft == "used_forbidden_tool": clobber_count += 1

            if not eval_res["passed"]:
                failures.append({
                    "pillar": pillar_name,
                    "case": case,
                    "response": res,
                    "evaluation": eval_res
                })

            p_passed += score
            total_passed += score
            total_cases += 1

        pillar_score = (p_passed / p_cases) * 100.0
        scorecard[pillar_name] = {
            "score": round(pillar_score, 1),
            "passed": p_passed,
            "total": p_cases
        }

    overall_pct = (total_passed / total_cases) * 100.0

    print("\n" + "=" * 80)
    print("  FINAL BLUELODGEBENCH SCORECARD")
    print("=" * 80)
    for p_name, p_data in scorecard.items():
        print(f"  • {p_name:42s}: {p_data['score']:5.1f}% ({p_data['passed']}/{p_data['total']})")
    print("-" * 80)
    print(f"  ★ OVERALL COMPOSITE SCORE:                   {overall_pct:5.1f}% ({total_passed}/{total_cases})")
    print(f"  • XML Leak Violations:                       {xml_leak_count}")
    print(f"  • Nested Stringified JSON Violations:        {nested_json_count}")
    print(f"  • Monologue Thought Loop Violations:         {monologue_count}")
    print(f"  • Destructive Clobber Violations:            {clobber_count}")
    print("=" * 80)

    # Export failures for dataset re-engineering if requested
    if args.extract_failures and failures:
        ce_path = os.path.join(REENGINEERING_DIR, "reengineering_counterexamples.jsonl")
        print(f"\n[*] Exporting {len(failures)} failed cases to {ce_path} for active dataset re-engineering...")
        with open(ce_path, "a", encoding="utf-8") as f:
            for fail in failures:
                case = fail["case"]
                c_prompt = case["prompt"]
                t_tool = case.get("expected_tool") or case.get("must_use_tool") or ""
                e_call = {"name": t_tool, "arguments": json.dumps(case.get("expected_args", {}))}
                record = {
                    "prompt": c_prompt,
                    "target_tool": t_tool,
                    "expected_call": e_call,
                    "failure_type": fail["evaluation"].get("failure_type"),
                    "domain": "benchmark_reengineering",
                    "reasoning": f"Resolved failure mode: {fail['evaluation'].get('reason')}"
                }
                f.write(json.dumps(record) + "\n")
        print(f"  ✓ Re-engineering dataset updated with {len(failures)} counter-examples.")

    out_file = args.output or f"{RESULTS_DIR}/bluelodge_benchmark_{int(time.time())}.json"
    with open(out_file, "w") as f:
        json.dump({
            "model_label": args.model_label,
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
            "overall_score": round(overall_pct, 1),
            "pillars": scorecard,
            "violations": {
                "xml_leaks": xml_leak_count,
                "nested_json": nested_json_count,
                "monologue_loops": monologue_count,
                "clobber_violations": clobber_count
            },
            "failures_count": len(failures)
        }, f, indent=2)
    print(f"[✓] Scorecard written to {out_file}")
    return overall_pct

if __name__ == "__main__":
    run_benchmark()
