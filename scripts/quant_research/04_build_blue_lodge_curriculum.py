#!/usr/bin/env python3
"""
04_build_blue_lodge_curriculum.py:
Generates a comprehensive, high-volume synthetic training curriculum for Blue Lodge tool calling.
Incorporate empirical lessons and pristine trajectories extracted from real transcripts:
- Clean OpenAI-compatible JSON tool call signatures with NO XML leakage (no </parameter>, <function>).
- Strict JSON dictionary types with NO nested stringified JSON (e.g. action="status", NOT action="{\"action\": \"status\"}").
- Mandatory tool execution (zero thought loops when an operational task is requested).
- Non-destructive file edits (file_edit for modifications, file_write only for new files).
- Clean Git operations (branching from develop, status check, atomic commit, remote push, Gitea PR).
- Phytology protocol mastery (status, audit with --cached, fitness scoring, lignification, autonomic healing).
"""

import os
import sys
import json
import random

OUTPUT_PATH = "/home/wsl-ops/blue-lodge/data/training/blue_lodge_tool_curriculum.jsonl"
SUMMARY_PATH = "/home/wsl-ops/blue-lodge/data/training/transcript_interrogation_summary.json"

random.seed(42)

def generate_git_samples():
    branches = [
        "feature/phytology-lignification-morphogenesis",
        "feature/react-loop-async-flow-control-circuit-breaker",
        "feature/posix-fifo-mqtt-async-flow-control",
        "feature/phytology-audit-pipeline",
        "feature/swarm-escalation-remediation-loop",
        "feature/gitea-issues-cli-suite",
        "fix/phytology-ci-portability",
        "feature/multi-gpu-remediation-pipeline"
    ]
    modules = [
        ("lib/phytology.sh", "feat(phytology): implement tissue lignification and phenotype fitness scoring"),
        ("lib/react.sh", "feat(react): prompt perturbation hook and secondary node escalation"),
        ("lib/fifo_ipc.sh", "feat(fifo): non-blocking async await channel flow control"),
        ("lib/cache.sh", "feat(cache): pseudo-LRU tool cache with O(1) namespace invalidation"),
        ("lib/limits.sh", "feat(limits): swarm operational levers for circuit breakers and capacities"),
        ("commands/phytology.sh", "feat(commands): add fitness and lignify subcommands to phytology CLI"),
        ("tests/test_phytology.sh", "test(phytology): companion regression suite for living tissue AST audits")
    ]

    samples = []

    # 1. Checkout feature branch
    for b in branches:
        prompt = f"Step 1: Check out a new Git feature branch from develop using bash_exec: git checkout -b {b} develop"
        reasoning = f"The user instruction asks me to create and check out a new feature branch '{b}' from 'develop'. I will execute bash_exec with the exact git checkout command."
        tool_call = {
            "name": "bash_exec",
            "arguments": json.dumps({"command": f"git checkout -b {b} develop"})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_git",
            "target_tool": "bash_exec",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    # 2. Check git status cleanly
    for _ in range(15):
        prompt = "Check the git working tree status to verify if there are any uncommitted changes or untracked files."
        reasoning = "To inspect git working tree status cleanly without terminal noise or broken pipes, I will call bash_exec with 'git status --short'."
        tool_call = {
            "name": "bash_exec",
            "arguments": json.dumps({"command": "git status --short"})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_git",
            "target_tool": "bash_exec",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    # 3. Stage and commit
    for filepath, commit_msg in modules:
        prompt = f"Stage the modified file {filepath} and commit the changes with conventional commit message '{commit_msg}'."
        reasoning = f"I need to stage {filepath} and commit using git commit with the message '{commit_msg}'. I will invoke bash_exec with the clean chained command."
        tool_call = {
            "name": "bash_exec",
            "arguments": json.dumps({"command": f"git add {filepath} && git commit -m '{commit_msg}'"})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_git",
            "target_tool": "bash_exec",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    # 4. Push to remote Gitea
    for b in branches:
        prompt = f"Push the current feature branch '{b}' to remote 'gitea' using bash_exec."
        reasoning = f"To publish the branch to the local sovereign Gitea repository, I will run git push gitea {b} via bash_exec."
        tool_call = {
            "name": "bash_exec",
            "arguments": json.dumps({"command": f"git push gitea {b}"})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_git",
            "target_tool": "bash_exec",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    # 5. Create Pull Request and Merge via Gitea API
    for b in branches:
        prompt = f"Open a Pull Request on Gitea for branch '{b}' targeting 'develop' and merge it."
        reasoning = f"I will use bash_exec to issue a clean curl API call to Gitea at http://127.0.0.1:3088 to create and merge the PR."
        cmd = f"curl -s -X POST -H 'Content-Type: application/json' -d '{{\"title\": \"{b}\", \"head\": \"{b}\", \"base\": \"develop\"}}' http://127.0.0.1:3088/api/v1/repos/george/blue-lodge/pulls"
        tool_call = {
            "name": "bash_exec",
            "arguments": json.dumps({"command": cmd})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_git",
            "target_tool": "bash_exec",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    return samples

def generate_phytology_samples():
    samples = []
    
    # 1. phytology_manage status
    prompts_status = [
        "Check phytology living tissue status and foliage health.",
        "Inspect George's living tissue and report current Cambium, Foliage, and Snapshot status.",
        "Run phytology status inspection.",
        "What is the current software phytology health of the blue-lodge codebase?",
        "Use phytology_manage to query the living tissue manifest."
    ]
    for p in prompts_status:
        reasoning = "The user wants to check the Software Phytology living tissue status. I should call the bedrock tool phytology_manage directly with action='status'. Note: I must pass a clean dictionary, never a nested stringified JSON."
        tool_call = {
            "name": "phytology_manage",
            "arguments": json.dumps({"action": "status"})
        }
        samples.append({
            "prompt": p,
            "domain": "blue_lodge_phytology",
            "target_tool": "phytology_manage",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    # 2. phytology_manage audit with cached flags
    prompts_audit = [
        "Audit the software phytology living tissue and verify foliage AST contracts.",
        "Run a living tissue audit with LRU caching enabled using phytology_manage.",
        "Check foliage health and AST syntax across all operator scripts.",
        "Execute /phytology audit --cached using the native phytology tool."
    ]
    for p in prompts_audit:
        reasoning = "To audit the foliage scripts with caching, I invoke phytology_manage with action='audit' and flags='--cached'."
        tool_call = {
            "name": "phytology_manage",
            "arguments": json.dumps({"action": "audit", "flags": "--cached"})
        }
        samples.append({
            "prompt": p,
            "domain": "blue_lodge_phytology",
            "target_tool": "phytology_manage",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    # 3. phytology_manage cache status and invalidation
    samples.append({
        "prompt": "Check the status of the phytology LRU cache.",
        "domain": "blue_lodge_phytology",
        "target_tool": "phytology_manage",
        "expected_call": {"name": "phytology_manage", "arguments": json.dumps({"action": "cache-status"})},
        "reasoning": "I will invoke phytology_manage with action='cache-status' to view cache hits, misses, and namespaces."
    })
    samples.append({
        "prompt": "Invalidate the phytology LRU cache namespace after recent grafts.",
        "domain": "blue_lodge_phytology",
        "target_tool": "phytology_manage",
        "expected_call": {"name": "phytology_manage", "arguments": json.dumps({"action": "cache-invalidate"})},
        "reasoning": "I will call phytology_manage with action='cache-invalidate' to advance the generation counter."
    })

    # 4. phytology_manage fitness scoring
    targets = [
        ".george/cron_jobs/logic_quip.sh",
        ".george/cron_jobs/research_publisher.sh",
        ".george/cron_jobs/probe_local_inference_en.sh",
        ".george/tools/custom_analyzer.sh",
        "commands/phytology.sh"
    ]
    for tgt in targets:
        prompt = f"Assess the phenotypic fitness score of living tissue candidate '{tgt}' using phytology_manage."
        reasoning = f"To score the phenotypic fitness of '{tgt}', I invoke phytology_manage with action='fitness' and target='{tgt}'."
        tool_call = {
            "name": "phytology_manage",
            "arguments": json.dumps({"action": "fitness", "target": tgt})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_phytology",
            "target_tool": "phytology_manage",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    # 5. phytology_manage lignification
    for tgt in targets[:3]:
        cmd_name = tgt.split("/")[-1].replace(".sh", "")
        prompt = f"Lignify the fit foliage candidate '{tgt}' into permanent Cambium command '{cmd_name}'."
        reasoning = f"To lignify foliage '{tgt}' into a verified Cambium command, I call phytology_manage with action='lignify' and target='{tgt}'."
        tool_call = {
            "name": "phytology_manage",
            "arguments": json.dumps({"action": "lignify", "target": tgt})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_phytology",
            "target_tool": "phytology_manage",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    # 6. phytology_manage autonomic healing and tests
    samples.append({
        "prompt": "Run the automated phytology test suite using phytology_manage.",
        "domain": "blue_lodge_phytology",
        "target_tool": "phytology_manage",
        "expected_call": {"name": "phytology_manage", "arguments": json.dumps({"action": "test"})},
        "reasoning": "To execute the complete Software Phytology test suite, I invoke phytology_manage with action='test'."
    })
    samples.append({
        "prompt": "Trigger autonomic healing on corrupted foliage tissue '.george/cron_jobs/logic_quip.sh'.",
        "domain": "blue_lodge_phytology",
        "target_tool": "phytology_manage",
        "expected_call": {"name": "phytology_manage", "arguments": json.dumps({"action": "heal", "target": ".george/cron_jobs/logic_quip.sh"})},
        "reasoning": "I call phytology_manage with action='heal' to roll back from the last genetic snapshot and restore tissue health."
    })

    return samples

def generate_file_operation_samples():
    files = [
        "lib/phytology.sh", "lib/react.sh", "lib/native_tools.sh", "lib/fifo_ipc.sh",
        "lib/cache.sh", "lib/limits.sh", "lib/commands.sh", "lib/task_sync.sh",
        "commands/phytology.sh", "commands/limits.sh", "tests/test_phytology.sh",
        "tests/test_react.sh", "tests/test_cache.sh", "tests/test_limits.sh"
    ]
    samples = []

    # 1. file_read
    for f in files:
        prompt = f"Read the first 100 lines of {f} to inspect its implementation."
        reasoning = f"I need to inspect {f}. I will invoke file_read with path='{f}', start_line=1, max_lines=100. I must never append XML tags to the path."
        tool_call = {
            "name": "file_read",
            "arguments": json.dumps({"path": f, "start_line": 1, "max_lines": 100})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_file_ops",
            "target_tool": "file_read",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    # 2. file_edit (non-destructive)
    for f in files[:8]:
        prompt = f"Update {f} to add error handling for missing arguments using file_edit."
        reasoning = f"To modify existing file {f} safely without wiping its content, I MUST use file_edit with exact old_content and new_content blocks, NOT file_write."
        tool_call = {
            "name": "file_edit",
            "arguments": json.dumps({
                "path": f,
                "old_content": "    [ -z \"$1\" ] && return 0",
                "new_content": "    if [ -z \"$1\" ]; then\n        ui_err \"Missing required parameter\"\n        return 1\n    fi"
            })
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_file_ops",
            "target_tool": "file_edit",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    # 3. dir_list
    directories = [
        "lib", "commands", "tests", ".george", ".george/cron_jobs", ".george/snapshots"
    ]
    for d in directories:
        prompt = f"List the directory structure of '{d}' to understand available files."
        reasoning = f"I will call dir_list on '{d}' with max_depth=2 to get an indented tree view."
        tool_call = {
            "name": "dir_list",
            "arguments": json.dumps({"path": d, "max_depth": 2})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_file_ops",
            "target_tool": "dir_list",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    # 4. file_grep
    queries = [
        ("lib", "phytology_fitness"),
        ("lib", "cache_get"),
        ("lib", "fifo_async"),
        ("lib", "_react_trip_circuit_breaker"),
        ("commands", "commands_register")
    ]
    for path, pat in queries:
        prompt = f"Search for pattern '{pat}' across directory '{path}' using file_grep."
        reasoning = f"I will invoke file_grep with path='{path}' and pattern='{pat}' to locate occurrences."
        tool_call = {
            "name": "file_grep",
            "arguments": json.dumps({"path": path, "pattern": pat})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_file_ops",
            "target_tool": "file_grep",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    return samples

def generate_bash_test_samples():
    tests = [
        "./tests/test_phytology.sh",
        "./tests/test_react_perturbation_hook.sh",
        "./tests/test_react_lru_tool_cache.sh",
        "./tests/test_react_circuit_breaker.sh",
        "./tests/test_react.sh",
        "./tests/test_cache.sh",
        "./tests/test_limits.sh"
    ]
    samples = []
    for t in tests:
        prompt = f"Execute the test suite {t} to verify regression safety."
        reasoning = f"I will run {t} via bash_exec and inspect the test summary results."
        tool_call = {
            "name": "bash_exec",
            "arguments": json.dumps({"command": t})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_bash_tests",
            "target_tool": "bash_exec",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    syntax_checks = [
        "bash -n lib/phytology.sh",
        "bash -n lib/react.sh",
        "bash -n lib/native_tools.sh",
        "bash -n lib/cache.sh",
        "bash -n lib/limits.sh"
    ]
    for cmd in syntax_checks:
        prompt = f"Verify bash syntax of script: {cmd}"
        reasoning = f"I will invoke bash_exec with '{cmd}' to check for shell syntax errors."
        tool_call = {
            "name": "bash_exec",
            "arguments": json.dumps({"command": cmd})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_bash_tests",
            "target_tool": "bash_exec",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

    return samples

def generate_swarm_limits_samples():
    levers = [
        ("CIRCUIT_BREAKER_MAX_REPEATS", "4"),
        ("CACHE_LRU_CAPACITY", "128"),
        ("ASYNC_TOOL_WATCHDOG_TIMEOUT", "180"),
        ("FLOW_CONTROL_DEFAULT_CREDITS", "10"),
        ("MAX_RESEARCH_TURNS", "250")
    ]
    samples = []
    for lever, val in levers:
        prompt = f"Update the swarm operational lever '{lever}' to {val} using bash_exec."
        reasoning = f"To set the operational lever '{lever}', I run './lodge limits set {lever} {val}' via bash_exec."
        tool_call = {
            "name": "bash_exec",
            "arguments": json.dumps({"command": f"./lodge limits set {lever} {val}"})
        }
        samples.append({
            "prompt": prompt,
            "domain": "blue_lodge_limits",
            "target_tool": "bash_exec",
            "expected_call": tool_call,
            "reasoning": reasoning
        })

        prompt_get = f"Query the current value of swarm operational lever '{lever}'."
        reasoning_get = f"I will query '{lever}' via './lodge limits get {lever}'."
        samples.append({
            "prompt": prompt_get,
            "domain": "blue_lodge_limits",
            "target_tool": "bash_exec",
            "expected_call": {"name": "bash_exec", "arguments": json.dumps({"command": f"./lodge limits get {lever}"})},
            "reasoning": reasoning_get
        })

    return samples

def main():
    print("[*] Generating synthetic Blue Lodge tool calling curriculum...")
    all_samples = []

    git_s = generate_git_samples()
    phy_s = generate_phytology_samples()
    file_s = generate_file_operation_samples()
    bash_s = generate_bash_test_samples()
    lim_s = generate_swarm_limits_samples()

    base_samples = git_s + phy_s + file_s + bash_s + lim_s
    print(f"[*] Base seed sample count: {len(base_samples)}")

    # Expand to 1,200+ samples via phrasing permutations, context variations, and combinations
    phrasing_prefixes = [
        "Operator Instruction: ",
        "Please execute: ",
        "Task Request: ",
        "George, please ",
        "Execute the following action using native tools: ",
        ""
    ]

    expanded_samples = []
    for s in base_samples:
        for prefix in phrasing_prefixes:
            item = dict(s)
            item["prompt"] = prefix + s["prompt"]
            expanded_samples.append(item)

    # Add multi-step operational chains
    for _ in range(300):
        pick = random.choice(base_samples)
        prefix = random.choice(phrasing_prefixes)
        item = dict(pick)
        item["prompt"] = f"{prefix}{pick['prompt']}\nEnsure clean JSON arguments and no XML tags."
        expanded_samples.append(item)

    random.shuffle(expanded_samples)
    print(f"[+] Total curriculum samples generated: {len(expanded_samples)}")

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        for s in expanded_samples:
            f.write(json.dumps(s) + "\n")

    print(f"[✓] Saved curriculum dataset to {OUTPUT_PATH} ({os.path.getsize(OUTPUT_PATH)/1024:.1f} KB)")

if __name__ == "__main__":
    main()
