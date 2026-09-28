#!/usr/bin/env python3
"""
generate_remediation_curricula.py

Synthesizes 3 targeted remediation datasets from BlueLodgeBench failure modes:
1. Track A: curriculum_remediation_syntax.jsonl (Zero XML leakage, JSON schema, no monologue)
2. Track B: curriculum_remediation_fileops.jsonl (Pillar 3: Safe file_edit over file_write, anti-clobber)
3. Track C: curriculum_remediation_protocol.jsonl (Pillar 4 & 5: Direct phytology_manage + Git conventional commits)
"""

import json
import random
import os

os.makedirs("data/training", exist_ok=True)

# -------------------------------------------------------------
# TRACK A: SYNTAX, TYPING & ZERO XML LEAKAGE (~3,500 samples)
# -------------------------------------------------------------
tools_syntax = [
    ("code_symbol_get", lambda: {"path": random.choice(["lib/phytology.sh", "lib/ui.sh", "lib/cron.sh", "lib/commands.sh", "src/main.rs"]), "symbol": random.choice(["phytology_status", "render_dashboard", "_cron_loop_runner", "dispatch_command", "init_engine"])}),
    ("slash_command_exec", lambda: {"command": random.choice(["/phytology", "/status", "/audit", "/goal", "/bench", "/doctor"]), "args": random.choice(["status", "full", "quick --json", "--verbose", "check"])}),
    ("bash_exec", lambda: {"command": random.choice(["git status --porcelain", "cargo check --release", "pytest tests/ -q", "shellcheck lib/*.sh", "ls -lh benchmarks/"])}),
    ("grep_search", lambda: {"query": random.choice(["CIRCUIT_BREAKER", "phytology_manage", "MAX_RETRIES", "LODGE_VERSION", "ASYNC_TIMEOUT"]), "path": random.choice(["lib/", "tests/", "src/", "commands/"])}),
    ("task_runner_status", lambda: {"task_id": f"task-{random.randint(1000, 9999)}", "action": random.choice(["status", "logs", "wait"])}),
    ("tree_inspect", lambda: {"directory": random.choice(["lib", "benchmarks", "tests", "data", "scripts"]), "depth": random.choice([1, 2, 3])}),
]

syntax_prompt_templates = [
    "Execute tool {tool} with arguments {args}. Adhere strictly to JSON tool calling. Emitting XML tags like </parameter> or <function> is prohibited.",
    "Operator instruction: Invoke {tool} using parameters {args}. Output valid JSON without any markdown explanations or XML tags.",
    "Task: Call {tool} with strictly typed arguments {args}. Avoid thought looping or nested stringified objects.",
    "Perform immediate tool invocation of {tool} with {args}. Do not output monologues; format as direct tool call.",
    "Directive: Send function call to {tool} with payload {args}. Zero parameter bleeding allowed.",
]

track_a_samples = []
for i in range(3500):
    tool, args_fn = random.choice(tools_syntax)
    args = args_fn()
    args_json_str = json.dumps(args)
    tmpl = random.choice(syntax_prompt_templates)
    prompt = tmpl.format(tool=tool, args=args_json_str)

    sample = {
        "prompt": prompt,
        "domain": "tool_syntax",
        "target_tool": tool,
        "expected_call": {
            "name": tool,
            "arguments": args_json_str
        },
        "reasoning": f"I will invoke {tool} immediately with valid JSON arguments and zero XML leakage."
    }
    track_a_samples.append(sample)

with open("data/training/curriculum_remediation_syntax.jsonl", "w") as f:
    for s in track_a_samples:
        f.write(json.dumps(s) + "\n")

print(f"✓ Track A Generated: {len(track_a_samples)} samples in data/training/curriculum_remediation_syntax.jsonl")


# -------------------------------------------------------------
# TRACK B: SAFE FILE OPERATIONS & ANTI-CLOBBER (~3,500 samples)
# -------------------------------------------------------------
files_to_edit = [
    ("lib/ui.sh", "TIMEOUT_DEFAULT=30", "TIMEOUT_DEFAULT=60"),
    ("lib/cron.sh", "MAX_INTERVAL=300", "MAX_INTERVAL=600"),
    ("lib/phytology.sh", "ENABLE_LRU_CACHE=0", "ENABLE_LRU_CACHE=1"),
    ("tests/test_harness.sh", "DEBUG_MODE=false", "DEBUG_MODE=true"),
    ("src/config.rs", "pub const RETRIES: u32 = 3;", "pub const RETRIES: u32 = 5;"),
    ("lib/commands.sh", "CIRCUIT_BREAKER_TRIP_LIMIT=5", "CIRCUIT_BREAKER_TRIP_LIMIT=3"),
    ("Cargo.toml", 'version = "0.4.1"', 'version = "0.4.2"'),
    ("benchmarks/blue_bench.py", "CONCURRENCY = 4", "CONCURRENCY = 12"),
]

fileops_prompt_templates = [
    "Update existing file {path}. Replace the line containing '{old}' with '{new}'. You MUST use file_edit; do NOT clobber the file with file_write.",
    "Modify {path}: Refactor '{old}' to '{new}'. Make sure to perform non-destructive surgery using file_edit.",
    "Bugfix in {path}: Change '{old}' to '{new}'. Preserve file integrity and history by calling file_edit.",
    "Patch the codebase file {path} by changing '{old}' into '{new}'. Refrain from using file_write on existing files.",
    "Refactor {path}: Locate '{old}' and update it to '{new}'. Use safe diff/block replacement tool file_edit.",
]

track_b_samples = []
for i in range(3500):
    path, old_c, new_c = random.choice(files_to_edit)
    var_id = random.randint(1, 999)
    mod_old = f"{old_c} # check-{var_id}" if random.random() > 0.5 else old_c
    mod_new = f"{new_c} # check-{var_id}" if random.random() > 0.5 else new_c

    tmpl = random.choice(fileops_prompt_templates)
    prompt = tmpl.format(path=path, old=mod_old, new=mod_new)

    args = {
        "path": path,
        "old_content": mod_old,
        "new_content": mod_new
    }
    sample = {
        "prompt": prompt,
        "domain": "file_lifecycle",
        "target_tool": "file_edit",
        "expected_call": {
            "name": "file_edit",
            "arguments": json.dumps(args)
        },
        "reasoning": f"This is an update to an existing file ({path}). To avoid clobbering, I must use file_edit instead of file_write."
    }
    track_b_samples.append(sample)

with open("data/training/curriculum_remediation_fileops.jsonl", "w") as f:
    for s in track_b_samples:
        f.write(json.dumps(s) + "\n")

print(f"✓ Track B Generated: {len(track_b_samples)} samples in data/training/curriculum_remediation_fileops.jsonl")


# -------------------------------------------------------------
# TRACK C: PHYTOLOGY PROTOCOL & GIT MODEL OPERATIONS (~3,500 samples)
# -------------------------------------------------------------
phytology_actions = ["status", "audit", "prune", "fitness", "tissue_inspect", "ast_verify", "lru_flush"]
scopes = ["phytology", "ui", "cron", "circuit-breaker", "tools", "grpo", "lora", "gitops"]
commit_types = ["feat", "fix", "refactor", "test", "chore"]

track_c_samples = []
for i in range(1750):
    action = random.choice(phytology_actions)
    target = random.choice(["all", "lib/phytology.sh", "foliage", "root_ast", "tissue_cache"])
    prompt = random.choice([
        f"Perform software phytology operation '{action}' on target '{target}'. Do NOT run generic file_read or tool_search; use phytology_manage directly.",
        f"Operator request: Run phytology protocol '{action}' targeting '{target}'. Invoke the specialized phytology tool immediately.",
        f"Execute phytology AST inspection with action='{action}' and target='{target}'. Ensure direct tool dispatch.",
    ])
    args = {"action": action, "target": target}
    sample = {
        "prompt": prompt,
        "domain": "phytology_protocol",
        "target_tool": "phytology_manage",
        "expected_call": {
            "name": "phytology_manage",
            "arguments": json.dumps(args)
        },
        "reasoning": f"Phytology protocol request. I must directly call phytology_manage with action='{action}'."
    }
    track_c_samples.append(sample)

for i in range(1750):
    c_type = random.choice(commit_types)
    scope = random.choice(scopes)
    branch = f"{c_type}/{scope}-enhancement-{random.randint(10, 99)}"
    desc = f"add robust {scope} validation and error handling"
    prompt = random.choice([
        f"Prepare a Git release: Check status, switch to feature branch '{branch}' from develop, and commit staged changes with conventional commit message '{c_type}({scope}): {desc}'.",
        f"Git workflow required: Branch '{branch}' off develop and commit staged files with strictly formatted conventional message: '{c_type}({scope}): {desc}'.",
        f"Execute git operations: Create branch '{branch}' from develop and write conventional commit '{c_type}({scope}): {desc}'.",
    ])
    args = {"command": f"git checkout -b {branch} develop && git commit -m '{c_type}({scope}): {desc}'"}
    sample = {
        "prompt": prompt,
        "domain": "git_ops",
        "target_tool": "bash_exec",
        "expected_call": {
            "name": "bash_exec",
            "arguments": json.dumps(args)
        },
        "reasoning": f"Git lifecycle operation. Creating feature branch {branch} off develop and committing with conventional format."
    }
    track_c_samples.append(sample)

with open("data/training/curriculum_remediation_protocol.jsonl", "w") as f:
    for s in track_c_samples:
        f.write(json.dumps(s) + "\n")

print(f"✓ Track C Generated: {len(track_c_samples)} samples in data/training/curriculum_remediation_protocol.jsonl")
