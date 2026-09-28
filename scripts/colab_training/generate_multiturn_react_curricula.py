#!/usr/bin/env python3
"""
generate_multiturn_react_curricula.py:
Generates rich multi-turn ChatML trajectories for Blue Lodge sovereign training with:
- Honeydew Multi-Step Execution Planning (Ordered milestones, active step tracking)
- Track 1: Status & Domain Getter -> Final Synthesis (phytology_manage, git status, cron)
- Track 2: Working Memory Distillation (Using mem:active_task across turns)
- Track 3: Surgical Code Modification & Verification (file_read -> file_edit -> bash_exec test)
- Track 4: Circuit Advisory & File Paging Self-Correction (Pivoting from linear file reads to domain tools)
"""

import json
import os
import random

OUTPUT_DIR = "/home/wsl-ops/blue-lodge/data/training"
os.makedirs(OUTPUT_DIR, exist_ok=True)

CORE_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "phytology_manage",
            "description": "Inspect and manage Software Phytology living tissue diagnostic, healing, and safe grafting.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["status", "audit", "heal", "cache-status", "cache-invalidate", "fitness", "lignify", "test"]},
                    "flags": {"type": "string"},
                    "target": {"type": "string"}
                },
                "required": ["action"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "bash_exec",
            "description": "Execute a bash shell command within the project workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string"}
                },
                "required": ["command"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_read",
            "description": "Read a targeted range of lines from a local file or semantic memory (mem:active_task).",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "start_line": {"type": "integer"},
                    "max_lines": {"type": "integer"}
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_write",
            "description": "Create a new file or write working memory deliverable (path=\"mem:active_task\").",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"}
                },
                "required": ["path", "content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_edit",
            "description": "Surgically edit code in an existing file using sed substitution.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "sed_expr": {"type": "string"}
                },
                "required": ["path", "sed_expr"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_append",
            "description": "Append text content to existing file or working memory scratchpad (path=\"mem:active_task\").",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"}
                },
                "required": ["path", "content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_grep",
            "description": "Perform fast regular expression search across files in the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string"},
                    "path": {"type": "string"}
                },
                "required": ["pattern"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "dir_list",
            "description": "List directory contents formatted as an indented tree.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "depth": {"type": "integer"}
                }
            }
        }
    }
]

def make_system_prompt(goal, steps, active_step_id):
    plan_lines = []
    for s_id, s_task in steps:
        mark = "✓" if s_id < active_step_id else " "
        plan_lines.append(f"- [{mark}] Step {s_id}: {s_task}")
    plan_str = "\n".join(plan_lines)
    active_str = f"Step {active_step_id}: {steps[active_step_id-1][1]}" if active_step_id <= len(steps) else "All plan steps completed. Ready to synthesize final deliverable."

    return f"""<developer_instructions>
You ARE George — senior technical companion and master digital craftsman.
You operate directly inside the live repository with native POSIX tool calling enabled.
Move directly to exact domain getter/action tools when actions are needed.
When observations are sufficient or all steps are marked [✓], synthesize and present your final answer directly in clean markdown without redundant tool execution.
</developer_instructions>

<honeydew_plan>
## Active Multi-Step Plan (Honeydew Checklist)
Goal: {goal}

{plan_str}

Current Active Step: {active_str}
Rule: Execute the Current Active Step directly using domain getter/action tools. When all inspection/action steps are marked [✓], synthesize your final deliverable in clean markdown.
</honeydew_plan>"""

def generate_track1_samples():
    """Track 1: Status & Domain Getter -> Final Synthesis"""
    samples = []
    
    tasks = [
        ("please check the status of the software phytology and report back.",
         [(1, "Inspect living tissue status, manifest, and cache metrics using domain getter tools"),
          (2, "Synthesize diagnostic observations and deliver structured status report to operator")],
         "phytology_manage", {"action": "status"},
         "🌿 GEORGE LIVING TISSUE & PHYTOLOGY MANIFEST\n  • Cambium Root (Immutable Architecture): 66 core modules (/home/wsl-ops/blue-lodge/lib)\n  • Foliage (Autonomic Cron Sweeps):       3 operator scripts (/home/wsl-ops/blue-lodge/.george/cron_jobs)\n  • Tool Crib Foliage (Dynamic Tools):     0 custom tools (/home/wsl-ops/blue-lodge/.george/tools)\n  • Genetic Snapshots (Local Versioning):  171 shadow snapshots (/home/wsl-ops/blue-lodge/.george/snapshots)",
         "Step 1 requires inspecting software phytology status. I will invoke phytology_manage directly with action 'status' to retrieve the living tissue manifest.",
         "Step 1 complete. Observation shows 66 Cambium Root modules, 3 autonomic sweeps, and 171 genetic snapshots. Now executing Step 2: synthesizing the status report for the operator.",
         "### Software Phytology Status Report\n\nThe software phytology audit has verified all architectural tiers:\n- **Cambium Root (Core Kernel)**: 66 verified immutable modules in `lib/`.\n- **Foliage (Cron Jobs)**: 3 active autonomic sweep scripts in `.george/cron_jobs/`.\n- **Tool Crib**: 0 dynamic tools mounted.\n- **Genetic Snapshots**: 171 historical shadow snapshots preserved in `.george/snapshots/`.\n\nAll living tissue contracts are verified, stable, and operating normally."),
         
        ("Audit the foliage tissue using phytology_manage and verify that cache status is clean.",
         [(1, "Audit foliage living tissue and verify cache metrics using domain getter tools"),
          (2, "Synthesize audit results and confirm zero regressions to operator")],
         "phytology_manage", {"action": "audit", "flags": "--cached"},
         "✓ Foliage Audit Complete: 3/3 scripts valid AST syntax.\n✓ LRU Cache Status: 0 dirty entries, 100% clean hit rate.",
         "Step 1 requires auditing foliage tissue and verifying cache status. I will invoke phytology_manage with action 'audit' and flags '--cached'.",
         "Foliage audit returned all 3 scripts valid and clean LRU cache. Step 1 is verified. Executing Step 2: reporting findings.",
         "### Foliage Audit & Cache Status\n\n- **Living Foliage**: All 3 autonomic cron scripts passed AST syntax verification (`bash -n` and `python3 -m py_compile`).\n- **LRU Cache**: Clean state confirmed with zero dirty entries and healthy cache hit rate.\n\nNo tissue corruption or cache degradation detected."),
         
        ("Run git status to check for modified or untracked files.",
         [(1, "Inspect repository state using git status"),
          (2, "Deliver summary of working tree changes to operator")],
         "bash_exec", {"command": "git status --porcelain"},
         " M docker-compose.yml\n M lib/react.sh",
         "Step 1 requires checking git working tree state. I will invoke bash_exec with git status --porcelain.",
         "Observation shows 2 modified files. Step 1 complete. Executing Step 2 to report working tree status.",
         "### Git Workspace Status\n\n- **Modified Files**:\n  - `docker-compose.yml`\n  - `lib/react.sh`\n\nWorking tree has 2 unstaged modifications. All other repository files are clean.")
    ]

    for user_prompt, steps, tool_name, tool_args, tool_obs, think_t1, think_t2, final_reply in tasks:
        for _ in range(12):
            call_id = f"call_{random.randint(10000, 99999)}"
            sys_p = make_system_prompt(user_prompt, steps, 1)
            traj = {
                "tools": CORE_TOOLS,
                "messages": [
                    {"role": "system", "content": sys_p},
                    {"role": "user", "content": user_prompt},
                    {
                        "role": "assistant",
                        "content": None,
                        "reasoning_content": think_t1,
                        "tool_calls": [
                            {
                                "id": call_id,
                                "type": "function",
                                "function": {
                                    "name": tool_name,
                                    "arguments": json.dumps(tool_args)
                                }
                            }
                        ]
                    },
                    {
                        "role": "tool",
                        "tool_call_id": call_id,
                        "content": tool_obs
                    },
                    {
                        "role": "assistant",
                        "reasoning_content": think_t2,
                        "content": final_reply
                    }
                ]
            }
            samples.append(traj)
    return samples

def generate_track2_samples():
    """Track 2: Working Memory Distillation (Using mem:active_task)"""
    samples = []
    
    memory_tasks = [
        ("Inspect lib/cron.sh, distill the core loop architecture into working memory, and report when finished.",
         [(1, "Read target architecture implementation from lib/cron.sh"),
          (2, "Distill core findings into working memory scratchpad (mem:active_task)"),
          (3, "Synthesize final confirmation report for operator")],
         "lib/cron.sh",
         "1: #!/bin/bash\n# George Autonomic Cron Engine\n_cron_loop_runner() {\n  while true; do\n    cron_sweep_jobs\n    sleep ${CRON_POLL_INTERVAL:-60}\n  done\n}",
         "# Cron Engine Architecture\n- Runner: `_cron_loop_runner()`\n- Mechanism: Infinite while loop polling `.george/cron_jobs/`\n- Interval: Configurable via `CRON_POLL_INTERVAL` (default 60s)",
         "I have inspected `lib/cron.sh` and distilled the core autonomic scheduling architecture into working memory (`mem:active_task`). The system utilizes an event-driven polling loop scanning `.george/cron_jobs/` at configured intervals.")
    ]

    for user_prompt, steps, file_path, file_content, distilled_notes, final_report in memory_tasks:
        for _ in range(12):
            call_id1 = f"call_{random.randint(10000, 99999)}"
            call_id2 = f"call_{random.randint(10000, 99999)}"
            sys_p = make_system_prompt(user_prompt, steps, 1)
            traj = {
                "tools": CORE_TOOLS,
                "messages": [
                    {"role": "system", "content": sys_p},
                    {"role": "user", "content": user_prompt},
                    {
                        "role": "assistant",
                        "content": None,
                        "reasoning_content": f"Step 1: Inspect {file_path} via file_read.",
                        "tool_calls": [
                            {
                                "id": call_id1,
                                "type": "function",
                                "function": {
                                    "name": "file_read",
                                    "arguments": json.dumps({"path": file_path, "start_line": 1, "max_lines": 50})
                                }
                            }
                        ]
                    },
                    {
                        "role": "tool",
                        "tool_call_id": call_id1,
                        "content": file_content
                    },
                    {
                        "role": "assistant",
                        "content": None,
                        "reasoning_content": "Step 1 complete. Step 2: Record architectural distillation into working memory mem:active_task.",
                        "tool_calls": [
                            {
                                "id": call_id2,
                                "type": "function",
                                "function": {
                                    "name": "file_write",
                                    "arguments": json.dumps({"path": "mem:active_task", "content": distilled_notes})
                                }
                            }
                        ]
                    },
                    {
                        "role": "tool",
                        "tool_call_id": call_id2,
                        "content": "Successfully wrote 194 bytes to .george/memories/active_task.md"
                    },
                    {
                        "role": "assistant",
                        "reasoning_content": "Steps 1 and 2 completed. Delivering final response for Step 3.",
                        "content": final_report
                    }
                ]
            }
            samples.append(traj)
    return samples

def generate_track3_samples():
    """Track 3: Multi-Step Surgical Coding (Locate -> Edit -> Test)"""
    samples = []
    
    coding_tasks = [
        ("Fix the timeout threshold in lib/limits.sh from 60 to 120 and verify syntax.",
         [(1, "Inspect lib/limits.sh timeout threshold"),
          (2, "Apply surgical sed replacement to update timeout to 120"),
          (3, "Verify shell syntax with bash_exec and confirm zero regressions")],
         "lib/limits.sh",
         "10: DEFAULT_TIMEOUT=60\n11: MAX_RETRIES=3",
         "s/DEFAULT_TIMEOUT=60/DEFAULT_TIMEOUT=120/g",
         "Successfully replaced in lib/limits.sh",
         "bash -n lib/limits.sh",
         "",
         "### Timeout Threshold Updated\n\n- `lib/limits.sh`: Updated `DEFAULT_TIMEOUT` from 60 to 120 seconds.\n- Syntax verification: `bash -n` exited with code 0 (clean).")
    ]

    for user_prompt, steps, target_file, inspect_content, sed_expr, edit_res, test_cmd, test_out, final_reply in coding_tasks:
        for _ in range(12):
            call_id1 = f"call_{random.randint(10000, 99999)}"
            call_id2 = f"call_{random.randint(10000, 99999)}"
            call_id3 = f"call_{random.randint(10000, 99999)}"
            sys_p = make_system_prompt(user_prompt, steps, 1)
            traj = {
                "tools": CORE_TOOLS,
                "messages": [
                    {"role": "system", "content": sys_p},
                    {"role": "user", "content": user_prompt},
                    {
                        "role": "assistant",
                        "content": None,
                        "reasoning_content": f"Step 1: Inspect {target_file} to locate the timeout threshold.",
                        "tool_calls": [
                            {
                                "id": call_id1,
                                "type": "function",
                                "function": {
                                    "name": "file_read",
                                    "arguments": json.dumps({"path": target_file, "start_line": 1, "max_lines": 30})
                                }
                            }
                        ]
                    },
                    {
                        "role": "tool",
                        "tool_call_id": call_id1,
                        "content": inspect_content
                    },
                    {
                        "role": "assistant",
                        "content": None,
                        "reasoning_content": f"Line located. Step 2: Apply surgical edit with file_edit.",
                        "tool_calls": [
                            {
                                "id": call_id2,
                                "type": "function",
                                "function": {
                                    "name": "file_edit",
                                    "arguments": json.dumps({"path": target_file, "sed_expr": sed_expr})
                                }
                            }
                        ]
                    },
                    {
                        "role": "tool",
                        "tool_call_id": call_id2,
                        "content": edit_res
                    },
                    {
                        "role": "assistant",
                        "content": None,
                        "reasoning_content": f"Edit applied. Step 3: Run syntax validation with bash_exec.",
                        "tool_calls": [
                            {
                                "id": call_id3,
                                "type": "function",
                                "function": {
                                    "name": "bash_exec",
                                    "arguments": json.dumps({"command": test_cmd})
                                }
                            }
                        ]
                    },
                    {
                        "role": "tool",
                        "tool_call_id": call_id3,
                        "content": test_out
                    },
                    {
                        "role": "assistant",
                        "reasoning_content": "All 3 steps completed and verified. Presenting final summary.",
                        "content": final_reply
                    }
                ]
            }
            samples.append(traj)
    return samples

def generate_track4_samples():
    """Track 4: Circuit Advisory & File Paging Self-Correction"""
    samples = []
    
    advisory_scenarios = [
        ("please check the status of the software phytology and report back.",
         [(1, "Inspect living tissue status using domain getter tools"),
          (2, "Synthesize findings into final status report")],
         "file_read", {"path": ".lodge_history", "start_line": 1, "max_lines": 50},
         "1: /api keys set\n2: /debug on\n3: /limits help\n...",
         "[CIRCUIT ADVISORY: Target file '.lodge_history' has been inspected multiple times in a row. Cease linear paging or repeated inspection of this file. Synthesize your findings or call the domain-specific tool required by the active Honeydew milestone.]",
         "phytology_manage", {"action": "status"},
         "🌿 GEORGE LIVING TISSUE & PHYTOLOGY MANIFEST\n  • Cambium Root (Immutable Architecture): 66 core modules\n  • Foliage (Autonomic Cron Sweeps): 3 scripts\n  • Genetic Snapshots: 171 shadow snapshots",
         "### Software Phytology Status Report\n\n- **Cambium Root**: 66 core modules verified.\n- **Foliage Sweeps**: 3 active cron jobs.\n- **Genetic Snapshots**: 171 historical snapshots preserved.\n\nLiving tissue is fully stable and operating normally.")
    ]

    for user_prompt, steps, bad_tool, bad_args, bad_obs, adv_msg, good_tool, good_args, good_obs, final_reply in advisory_scenarios:
        for _ in range(12):
            call_id1 = f"call_{random.randint(10000, 99999)}"
            call_id2 = f"call_{random.randint(10000, 99999)}"
            sys_p = make_system_prompt(user_prompt, steps, 1)
            traj = {
                "tools": CORE_TOOLS,
                "messages": [
                    {"role": "system", "content": sys_p},
                    {"role": "user", "content": user_prompt},
                    {
                        "role": "assistant",
                        "content": None,
                        "reasoning_content": f"I will read {bad_args.get('path')} to look for context.",
                        "tool_calls": [
                            {
                                "id": call_id1,
                                "type": "function",
                                "function": {
                                    "name": bad_tool,
                                    "arguments": json.dumps(bad_args)
                                }
                            }
                        ]
                    },
                    {
                        "role": "tool",
                        "tool_call_id": call_id1,
                        "content": bad_obs
                    },
                    {
                        "role": "user",
                        "content": adv_msg
                    },
                    {
                        "role": "assistant",
                        "content": None,
                        "reasoning_content": "Circuit advisory received. Ceasing file paging on .lodge_history. I will execute the domain getter phytology_manage directly to fulfill Step 1.",
                        "tool_calls": [
                            {
                                "id": call_id2,
                                "type": "function",
                                "function": {
                                    "name": good_tool,
                                    "arguments": json.dumps(good_args)
                                }
                            }
                        ]
                    },
                    {
                        "role": "tool",
                        "tool_call_id": call_id2,
                        "content": good_obs
                    },
                    {
                        "role": "assistant",
                        "reasoning_content": "Domain status received. Step 1 is complete. Now fulfilling Step 2 with final status report.",
                        "content": final_reply
                    }
                ]
            }
            samples.append(traj)
    return samples

def main():
    t1 = generate_track1_samples()
    t2 = generate_track2_samples()
    t3 = generate_track3_samples()
    t4 = generate_track4_samples()
    
    all_samples = t1 + t2 + t3 + t4
    random.seed(42)
    random.shuffle(all_samples)
    
    total = len(all_samples)
    split_idx = int(total * 0.9)
    train_samples = all_samples[:split_idx]
    val_samples = all_samples[split_idx:]
    
    out_all = os.path.join(OUTPUT_DIR, "curriculum_multiturn_react.jsonl")
    out_train = os.path.join(OUTPUT_DIR, "enhanced_multiturn_train.jsonl")
    out_val = os.path.join(OUTPUT_DIR, "enhanced_multiturn_val.jsonl")
    
    with open(out_all, "w", encoding="utf-8") as f:
        for s in all_samples:
            f.write(json.dumps(s) + "\n")
            
    with open(out_train, "w", encoding="utf-8") as f:
        for s in train_samples:
            f.write(json.dumps(s) + "\n")
            
    with open(out_val, "w", encoding="utf-8") as f:
        for s in val_samples:
            f.write(json.dumps(s) + "\n")
            
    print(f"Generated {total} multi-turn samples across 4 tracks:")
    print(f"  - Track 1 (Getter -> Synthesis): {len(t1)}")
    print(f"  - Track 2 (Memory Distillation): {len(t2)}")
    print(f"  - Track 3 (Surgical Code Modification): {len(t3)}")
    print(f"  - Track 4 (Circuit Advisory Recovery): {len(t4)}")
    print(f"Saved: {out_train} ({len(train_samples)}) and {out_val} ({len(val_samples)})")

if __name__ == "__main__":
    main()
