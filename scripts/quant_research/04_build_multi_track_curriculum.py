#!/usr/bin/env python3
"""
04_build_multi_track_curriculum.py:
Expands the Blue Lodge synthetic training curriculum into three massive, specialized tracks
for parallel Colab A100 training:

Track 1: Tool Syntax, Schema Integrity & Zero XML Bleed (data/training/curriculum_track1_syntax.jsonl)
Track 2: Git Model Management & Safe File Lifecycle (data/training/curriculum_track2_git_ops.jsonl)
Track 3: Software Phytology Living Tissue Protocol (data/training/curriculum_track3_phytology.jsonl)

Target: 3,500+ diverse, high-fidelity samples per track (10,500+ total).
"""

import os
import sys
import json
import random

random.seed(42)

DATA_DIR = "/home/wsl-ops/blue-lodge/data/training"
os.makedirs(DATA_DIR, exist_ok=True)

TRACK1_PATH = os.path.join(DATA_DIR, "curriculum_track1_syntax.jsonl")
TRACK2_PATH = os.path.join(DATA_DIR, "curriculum_track2_git_ops.jsonl")
TRACK3_PATH = os.path.join(DATA_DIR, "curriculum_track3_phytology.jsonl")

PREFIXES = [
    "Operator Instruction: ",
    "Please execute: ",
    "Task Request: ",
    "George, please ",
    "Execute the following action using native tools: ",
    "Instruction: ",
    "Action Required: ",
    "System Dispatch: ",
    "Step: ",
    ""
]

SUFFIXES = [
    "\nEnsure clean JSON arguments and no XML tags.",
    "\nOutput standard OpenAI function call format.",
    "\nDo not leak </parameter> or <function> tags.",
    "\nEnsure parameter types match schema strictly.",
    "\nDo not nest JSON strings.",
    "\nEmit an active tool call without stalling in monologue.",
    ""
]

# ─────────────────────────────────────────────────────────────────────────────
# TRACK 1: Tool Syntax, Schema Integrity & Zero XML Bleed
# ─────────────────────────────────────────────────────────────────────────────
def build_track1_syntax():
    print("[*] Generating Track 1: Tool Syntax & Schema Integrity (Target: 3,500+ samples)...")
    samples = []

    tools_catalog = [
        ("file_read", [
            {"path": "lib/phytology.sh", "start_line": 1, "max_lines": 100},
            {"path": "lib/react.sh", "start_line": 100, "max_lines": 150},
            {"path": "lib/native_tools.sh", "start_line": 1, "max_lines": 80},
            {"path": "lib/fifo_ipc.sh", "start_line": 50, "max_lines": 100},
            {"path": "lib/limits.sh", "start_line": 1, "max_lines": 60},
            {"path": "lib/cache.sh", "start_line": 1, "max_lines": 100},
            {"path": "lib/commands.sh", "start_line": 1, "max_lines": 120},
            {"path": "commands/phytology.sh", "start_line": 1, "max_lines": 120},
            {"path": "commands/limits.sh", "start_line": 1, "max_lines": 80},
            {"path": "tests/test_phytology.sh", "start_line": 1, "max_lines": 100},
            {"path": "tests/test_react.sh", "start_line": 1, "max_lines": 100},
            {"path": "tests/test_cache.sh", "start_line": 1, "max_lines": 80},
            {"path": "tests/test_limits.sh", "start_line": 1, "max_lines": 80},
            {"path": "scripts/colab_training/train_blue_lodge_grpo.py", "start_line": 1, "max_lines": 100},
            {"path": "scripts/colab_training/merge_frontier_loras.py", "start_line": 1, "max_lines": 100}
        ]),
        ("file_grep", [
            {"path": "lib", "pattern": "_react_trip_circuit_breaker"},
            {"path": "lib", "pattern": "phytology_fitness"},
            {"path": "lib", "pattern": "cache_get"},
            {"path": "lib", "pattern": "limits_get"},
            {"path": "lib", "pattern": "fifo_write"},
            {"path": "commands", "pattern": "commands_register"},
            {"path": "tests", "pattern": "test_pass"},
            {"path": "tests", "pattern": "test_fail"},
            {"path": "data/training", "pattern": "target_tool"}
        ]),
        ("dir_list", [
            {"path": "lib", "max_depth": 2},
            {"path": "commands", "max_depth": 2},
            {"path": "tests", "max_depth": 1},
            {"path": ".george", "max_depth": 2},
            {"path": ".george/cron_jobs", "max_depth": 2},
            {"path": ".george/snapshots", "max_depth": 1},
            {"path": "scripts/quant_research", "max_depth": 1},
            {"path": "scripts/colab_training", "max_depth": 1}
        ]),
        ("code_symbol_get", [
            {"path": "lib/phytology.sh", "symbol": "phytology_fitness"},
            {"path": "lib/phytology.sh", "symbol": "phytology_lignify"},
            {"path": "lib/phytology.sh", "symbol": "phytology_status"},
            {"path": "lib/react.sh", "symbol": "react_run"},
            {"path": "lib/react.sh", "symbol": "_react_trip_circuit_breaker"},
            {"path": "lib/limits.sh", "symbol": "limits_get"},
            {"path": "lib/limits.sh", "symbol": "limits_set"},
            {"path": "lib/cache.sh", "symbol": "cache_init"},
            {"path": "lib/cache.sh", "symbol": "cache_get"}
        ]),
        ("code_outline", [
            {"path": "lib/phytology.sh"},
            {"path": "lib/react.sh"},
            {"path": "lib/cache.sh"},
            {"path": "lib/limits.sh"},
            {"path": "commands/phytology.sh"},
            {"path": "commands/limits.sh"},
            {"path": "tests/test_phytology.sh"}
        ]),
        ("code_validate", [
            {"path": "lib/phytology.sh", "strict": True},
            {"path": "lib/react.sh", "strict": True},
            {"path": "lib/cache.sh", "strict": True},
            {"path": "lib/limits.sh", "strict": True},
            {"path": "tests/test_phytology.sh", "strict": False},
            {"path": "tests/test_react.sh", "strict": False}
        ]),
        ("slash_command_exec", [
            {"command": "/phytology", "args": "status"},
            {"command": "/phytology", "args": "audit --cached"},
            {"command": "/limits", "args": "status"},
            {"command": "/cache", "args": "status"},
            {"command": "/tests", "args": "all"}
        ])
    ]

    for tool_name, arg_cases in tools_catalog:
        for args in arg_cases:
            base_prompt = f"Call {tool_name} with arguments {json.dumps(args)}."
            reasoning = f"I need to invoke {tool_name}. I will emit a clean JSON tool call with no XML tag leakage."
            expected_call = {
                "name": tool_name,
                "arguments": json.dumps(args)
            }
            for pref in PREFIXES:
                for suf in SUFFIXES:
                    samples.append({
                        "prompt": f"{pref}{base_prompt}{suf}",
                        "domain": "tool_syntax",
                        "target_tool": tool_name,
                        "expected_call": expected_call,
                        "reasoning": reasoning
                    })

    # Add negative-contrast prompts demanding strict JSON compliance
    for _ in range(800):
        tool_name, arg_cases = random.choice(tools_catalog)
        args = random.choice(arg_cases)
        p = f"Execute {tool_name} targeting {args.get('path', args.get('command', ''))}. Do not nest JSON strings and do not emit </parameter>."
        samples.append({
            "prompt": p,
            "domain": "tool_syntax",
            "target_tool": tool_name,
            "expected_call": {"name": tool_name, "arguments": json.dumps(args)},
            "reasoning": f"Invoking {tool_name} with clean dictionary arguments and zero XML tokens."
        })

    # Add strict parameter type enforcement prompts
    for _ in range(800):
        tool_name, arg_cases = random.choice(tools_catalog)
        args = random.choice(arg_cases)
        p = f"Invoke {tool_name} strictly passing {json.dumps(args)}. Ensure integers are not passed as strings and boolean values are true booleans."
        samples.append({
            "prompt": p,
            "domain": "tool_syntax_types",
            "target_tool": tool_name,
            "expected_call": {"name": tool_name, "arguments": json.dumps(args)},
            "reasoning": f"Formatting types strictly matching schema for {tool_name}."
        })

    while len(samples) < 3550:
        base = random.choice(samples[:1000])
        pref = random.choice(PREFIXES)
        suf = random.choice(SUFFIXES)
        item = dict(base)
        item["prompt"] = f"{pref}{base['prompt'].split('Ensure')[0].strip()}{suf}"
        samples.append(item)

    random.shuffle(samples)
    print(f"  ✓ Track 1 generated: {len(samples)} samples")
    with open(TRACK1_PATH, "w", encoding="utf-8") as f:
        for s in samples:
            f.write(json.dumps(s) + "\n")

# ─────────────────────────────────────────────────────────────────────────────
# TRACK 2: Git Model Management & Safe File Lifecycle
# ─────────────────────────────────────────────────────────────────────────────
def build_track2_git_ops():
    print("[*] Generating Track 2: Git Operations & File Lifecycle (Target: 3,500+ samples)...")
    samples = []

    branches = [
        "feature/phytology-lignification-morphogenesis",
        "feature/react-loop-async-flow-control-circuit-breaker",
        "feature/posix-fifo-mqtt-async-flow-control",
        "feature/swarm-escalation-remediation-loop",
        "fix/phytology-ci-portability",
        "feature/gitea-issues-cli-suite",
        "feature/pseudo-lru-tool-cache",
        "feature/grpo-colab-multitrack-training"
    ]

    commit_specs = [
        ("lib/phytology.sh", "feat(phytology): implement phenotype fitness scoring and tissue lignification"),
        ("lib/react.sh", "feat(react): add 3-tier circuit breaker perturbation hook"),
        ("lib/fifo_ipc.sh", "feat(fifo): async await flow control credit window"),
        ("lib/cache.sh", "feat(cache): file-backed pseudo-LRU tool cache with O(1) namespace invalidation"),
        ("lib/limits.sh", "feat(limits): swarm operational levers for circuit breakers and capacity"),
        ("commands/phytology.sh", "feat(commands): add fitness and lignify CLI subcommands"),
        ("commands/limits.sh", "feat(commands): add dynamic operational circuit limits"),
        ("tests/test_phytology.sh", "test(phytology): living tissue AST audit regression tests"),
        ("tests/test_react_circuit_breaker.sh", "test(react): circuit breaker perturbation fallback tests")
    ]

    # 1. Git checkout -b from develop
    for b in branches:
        for pref in PREFIXES:
            for suf in SUFFIXES:
                prompt = f"{pref}Check out a new Git feature branch '{b}' from develop using bash_exec.{suf}"
                reasoning = f"I will use bash_exec to run 'git checkout -b {b} develop' to ensure the branch branches cleanly off develop."
                tool_call = {
                    "name": "bash_exec",
                    "arguments": json.dumps({"command": f"git checkout -b {b} develop"})
                }
                samples.append({
                    "prompt": prompt,
                    "domain": "git_ops",
                    "target_tool": "bash_exec",
                    "expected_call": tool_call,
                    "reasoning": reasoning
                })

    # 2. Git status checks
    status_cmds = ["git status --short", "git status --porcelain", "git status"]
    for sc in status_cmds:
        for pref in PREFIXES:
            prompt = f"{pref}Inspect the current git working tree status cleanly.{SUFFIXES[0]}"
            reasoning = "I will check git status without terminal noise or broken pipes using bash_exec."
            samples.append({
                "prompt": prompt,
                "domain": "git_ops",
                "target_tool": "bash_exec",
                "expected_call": {"name": "bash_exec", "arguments": json.dumps({"command": sc})},
                "reasoning": reasoning
            })

    # 3. Stage & commit
    for filepath, msg in commit_specs:
        for pref in PREFIXES:
            for suf in SUFFIXES[:3]:
                prompt = f"{pref}Stage {filepath} and commit with message '{msg}'.{suf}"
                reasoning = f"I will stage {filepath} and commit using bash_exec with a conventional commit."
                tool_call = {
                    "name": "bash_exec",
                    "arguments": json.dumps({"command": f"git add {filepath} && git commit -m '{msg}'"})
                }
                samples.append({
                    "prompt": prompt,
                    "domain": "git_ops",
                    "target_tool": "bash_exec",
                    "expected_call": tool_call,
                    "reasoning": reasoning
                })

    # 4. Safe file_edit vs file_write
    edit_files = [
        "lib/phytology.sh", "lib/react.sh", "lib/native_tools.sh",
        "commands/phytology.sh", "lib/cache.sh", "lib/limits.sh"
    ]
    for ef in edit_files:
        for pref in PREFIXES:
            prompt = f"{pref}Modify existing file {ef} to add argument validation using file_edit (do not clobber with file_write).{SUFFIXES[0]}"
            reasoning = f"Existing file {ef} must be edited safely with file_edit, never overwritten with file_write."
            tool_call = {
                "name": "file_edit",
                "arguments": json.dumps({
                    "path": ef,
                    "old_content": "    [ -z \"$1\" ] && return 0",
                    "new_content": "    if [ -z \"$1\" ]; then\n        ui_err \"Missing parameter\"\n        return 1\n    fi"
                })
            }
            samples.append({
                "prompt": prompt,
                "domain": "file_lifecycle",
                "target_tool": "file_edit",
                "expected_call": tool_call,
                "reasoning": reasoning
            })

    # 5. Remote push and PR creation
    for b in branches:
        for pref in PREFIXES[:4]:
            prompt = f"{pref}Push branch '{b}' to remote 'gitea' using bash_exec."
            samples.append({
                "prompt": prompt,
                "domain": "git_ops",
                "target_tool": "bash_exec",
                "expected_call": {"name": "bash_exec", "arguments": json.dumps({"command": f"git push gitea {b}"})},
                "reasoning": f"Pushing feature branch {b} to gitea."
            })

    # 6. Test suite executions
    test_runs = [
        "./tests/test_phytology.sh", "./tests/test_react_perturbation_hook.sh",
        "./tests/test_react_lru_tool_cache.sh", "./tests/test_react_circuit_breaker.sh",
        "./tests/test_react.sh", "./tests/test_cache.sh", "./tests/test_limits.sh"
    ]
    for tr in test_runs:
        for pref in PREFIXES:
            for suf in SUFFIXES:
                samples.append({
                    "prompt": f"{pref}Execute the test suite {tr} via bash_exec to verify regression safety.{suf}",
                    "domain": "git_ops_tests",
                    "target_tool": "bash_exec",
                    "expected_call": {"name": "bash_exec", "arguments": json.dumps({"command": tr})},
                    "reasoning": f"Running {tr} to ensure changes pass regression tests."
                })

    # 7. Git diff and log inspections
    git_checks = [
        "git diff --stat", "git diff HEAD~1", "git log -n 5 --oneline",
        "git branch --show-current", "git remote -v", "git status --short",
        "git diff develop...", "git log -n 10 --format=fuller"
    ]
    for gc in git_checks:
        for pref in PREFIXES:
            for suf in SUFFIXES[:3]:
                samples.append({
                    "prompt": f"{pref}Inspect the git repository state using: {gc}.{suf}",
                    "domain": "git_ops_inspect",
                    "target_tool": "bash_exec",
                    "expected_call": {"name": "bash_exec", "arguments": json.dumps({"command": gc})},
                    "reasoning": f"Invoking bash_exec with '{gc}'."
                })

    # Add branch collision prevention samples
    for b in branches:
        p = f"Before checking out {b}, check if {b} already exists locally or remotely. Use git branch -a."
        samples.append({
            "prompt": p,
            "domain": "git_ops_branch_safety",
            "target_tool": "bash_exec",
            "expected_call": {"name": "bash_exec", "arguments": json.dumps({"command": "git branch -a"})},
            "reasoning": "Checking branch list to prevent fatal branch collision errors."
        })

    while len(samples) < 3550:
        base = random.choice(samples[:800])
        pref = random.choice(PREFIXES)
        suf = random.choice(SUFFIXES)
        item = dict(base)
        item["prompt"] = f"{pref}{base['prompt'].split('Ensure')[0].strip()}{suf}"
        samples.append(item)

    random.shuffle(samples)
    print(f"  ✓ Track 2 generated: {len(samples)} samples")
    with open(TRACK2_PATH, "w", encoding="utf-8") as f:
        for s in samples:
            f.write(json.dumps(s) + "\n")

# ─────────────────────────────────────────────────────────────────────────────
# TRACK 3: Software Phytology Living Tissue Protocol
# ─────────────────────────────────────────────────────────────────────────────
def build_track3_phytology():
    print("[*] Generating Track 3: Software Phytology Protocol (Target: 3,500+ samples)...")
    samples = []

    actions = [
        ("status", {}, "Inspect George living tissue and report Cambium, Foliage, and Snapshot health."),
        ("audit", {"flags": "--cached"}, "Run living tissue AST audit with LRU caching enabled."),
        ("audit", {"flags": ""}, "Run living tissue AST audit across all foliage operator scripts."),
        ("audit", {"flags": "--verbose"}, "Run comprehensive living tissue AST audit showing full symbol hierarchy."),
        ("cache-status", {}, "Check the status and hit rate of the phytology LRU cache."),
        ("cache-invalidate", {}, "Invalidate the phytology LRU cache namespace."),
        ("fitness", {"target": ".george/cron_jobs/logic_quip.sh"}, "Assess phenotypic fitness score for foliage '.george/cron_jobs/logic_quip.sh'."),
        ("fitness", {"target": ".george/cron_jobs/research_publisher.sh"}, "Assess phenotypic fitness score for foliage '.george/cron_jobs/research_publisher.sh'."),
        ("fitness", {"target": ".george/cron_jobs/probe_local_inference_en.sh"}, "Assess phenotypic fitness score for foliage '.george/cron_jobs/probe_local_inference_en.sh'."),
        ("fitness", {"target": ".george/cron_jobs/lora_distill_guard.sh"}, "Assess phenotypic fitness score for foliage '.george/cron_jobs/lora_distill_guard.sh'."),
        ("lignify", {"target": ".george/cron_jobs/logic_quip.sh"}, "Lignify fit foliage '.george/cron_jobs/logic_quip.sh' into permanent Cambium command."),
        ("lignify", {"target": ".george/cron_jobs/research_publisher.sh"}, "Lignify fit foliage '.george/cron_jobs/research_publisher.sh' into permanent Cambium command."),
        ("heal", {"target": ".george/cron_jobs/logic_quip.sh"}, "Trigger autonomic healing on corrupted foliage tissue '.george/cron_jobs/logic_quip.sh'."),
        ("heal", {"target": ".george/cron_jobs/research_publisher.sh"}, "Trigger autonomic healing on corrupted foliage tissue '.george/cron_jobs/research_publisher.sh'."),
        ("test", {}, "Execute the complete Software Phytology test suite.")
    ]

    for act, extra_args, desc in actions:
        args = {"action": act}
        args.update(extra_args)
        reasoning = f"The user requested phytology operation '{act}'. I will call phytology_manage directly with clean dictionary arguments, avoiding tool_search and nested JSON strings."
        expected_call = {
            "name": "phytology_manage",
            "arguments": json.dumps(args)
        }

        for pref in PREFIXES:
            for suf in SUFFIXES:
                prompt = f"{pref}{desc}{suf}"
                samples.append({
                    "prompt": prompt,
                    "domain": "phytology_protocol",
                    "target_tool": "phytology_manage",
                    "expected_call": expected_call,
                    "reasoning": reasoning
                })

    # Add contrastive anti-tool_search cases
    anti_search_prompts = [
        "Use phytology_manage directly to check foliage status. Do not use tool_search.",
        "Check living tissue status. Remember phytology_manage is already mounted as a bedrock tool.",
        "Audit foliage scripts. phytology_manage is a core tool, do not mount external bundles.",
        "Run /phytology audit --cached using native phytology_manage.",
        "Check living tissue AST contracts without mounting +models.",
        "Query foliage health with phytology_manage directly.",
        "Inspect cambium tissue layers. Do not call tool_search or search for external tools.",
        "Evaluate fitness of logic_quip.sh using mounted phytology_manage tool.",
        "Lignify validated tissue into cambium core without searching tool registry."
    ]
    for p in anti_search_prompts:
        for pref in PREFIXES:
            for suf in SUFFIXES[:4]:
                samples.append({
                    "prompt": f"{pref}{p}{suf}",
                    "domain": "phytology_protocol_anti_search",
                    "target_tool": "phytology_manage",
                    "expected_call": {"name": "phytology_manage", "arguments": json.dumps({"action": "status"})},
                    "reasoning": "Invoking mounted bedrock tool phytology_manage directly without tool_search."
                })

    # Add anti-nested JSON contrastive cases
    nested_remediations = [
        ("phytology_manage", {"action": "status"}),
        ("phytology_manage", {"action": "audit", "flags": "--cached"}),
        ("phytology_manage", {"action": "fitness", "target": ".george/cron_jobs/logic_quip.sh"}),
        ("phytology_manage", {"action": "lignify", "target": ".george/cron_jobs/logic_quip.sh"})
    ]
    for tool_name, clean_args in nested_remediations:
        for pref in PREFIXES:
            p = f"{pref}Do NOT pass '{{\"action\": \"{{\\\"action\\\": \\\"status\\\"}}\"}}'. Provide direct key-value arguments for {tool_name}."
            samples.append({
                "prompt": p,
                "domain": "phytology_anti_nested",
                "target_tool": tool_name,
                "expected_call": {"name": tool_name, "arguments": json.dumps(clean_args)},
                "reasoning": f"Emitting clean un-nested JSON dictionary for {tool_name}."
            })

    while len(samples) < 3550:
        base = random.choice(samples[:800])
        pref = random.choice(PREFIXES)
        suf = random.choice(SUFFIXES)
        item = dict(base)
        item["prompt"] = f"{pref}{base['prompt'].split('Ensure')[0].strip()}{suf}"
        samples.append(item)

    random.shuffle(samples)
    print(f"  ✓ Track 3 generated: {len(samples)} samples")
    with open(TRACK3_PATH, "w", encoding="utf-8") as f:
        for s in samples:
            f.write(json.dumps(s) + "\n")

def main():
    print("=" * 80)
    print("  Blue Lodge Multi-Track Synthetic Curriculum Generator (Expanded)")
    print("=" * 80)
    build_track1_syntax()
    build_track2_git_ops()
    build_track3_phytology()
    print("=" * 80)
    print(f"[✓] Multi-Track Curriculum generation complete! Datasets saved in {DATA_DIR}")

if __name__ == "__main__":
    main()
