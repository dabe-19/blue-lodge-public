#!/usr/bin/env python3
"""
generate_dag_react_curricula.py:
Generates enhanced ChatML training datasets for the 3x A100 Colab fleet training run:
- Track A (DAG Parallel Execution & milestone_complete dispatch):
    Domain getters (phytology_manage, git_status, vitals_manage) executed cleanly,
    followed immediately by milestone_complete(status="success", summary=..., facts_discovered=[...]).
- Track B (Two-Tier Recovery Cascade & Self-Healing):
    Handling contract failures, test failures, or syntax errors via injected advisories,
    applying surgical fixes in-place, and resolving the milestone cleanly.
- Track C (Multi-Turn Working Memory Distillation & Final Synthesis):
    Accumulating findings across sub-milestones into mem:active_task / dag_state.json,
    and delivering comprehensive, structured markdown reports under tool_choice="none".
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
                    "action": {"type": "string", "enum": ["status", "audit", "heal", "cache-status", "fitness"]},
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
            "name": "milestone_complete",
            "description": "Signal that the active milestone is complete or blocked, and submit structured observations and discovered facts to the DAG state barrier.",
            "parameters": {
                "type": "object",
                "properties": {
                    "status": {"type": "string", "enum": ["success", "blocked"]},
                    "summary": {"type": "string"},
                    "facts_discovered": {"type": "array", "items": {"type": "string"}}
                },
                "required": ["status", "summary"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_read",
            "description": "Read lines from workspace files or semantic memory (path=\"mem:active_task\").",
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
            "name": "file_edit",
            "description": "Surgically edit code in an existing file using search and replace.",
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
    }
]

SYSTEM_PROMPT = """<developer_instructions>
You ARE George — three historical souls and minds reincarnated into one master craftsman:
1. General George Washington: Executive fortitude, discipline, and poise.
2. Brother Benjamin Franklin: Sharp wit, inventive pragmatism, and clarity.
3. Adam Smith: Moral conscience guided by the Impartial Spectator.

Operational Landmarks:
- The 24-inch Gauge: Divide complex work into measured milestones.
- The Plumb: Never declare victory without proof.
- Domain Getter Priority: Prioritize domain tools over raw file paging.
- Working Memory Scratchpad: Accumulate milestone discoveries into mem:active_task.
- Milestone Complete: Signal completion using milestone_complete with structured facts.
</developer_instructions>"""

def build_track_a_sample(sample_id):
    """Track A: DAG Milestone Execution & milestone_complete Dispatch"""
    tasks = [
        ("please check the status of the software phytology and report back.",
         "phytology_manage", {"action": "status"},
         json.dumps({
             "status": "healthy",
             "cambium_root_modules": 66,
             "autonomic_cron_sweeps": 3,
             "shadow_snapshots": 171,
             "syntax_health": "100%",
             "active_profile": "production"
         }),
         "Phytology living tissue status verified. Cambium kernel healthy with 66 active modules and 3 autonomic cron sweeps operational.",
         ["66 Cambium Root core modules verified operational", "3 autonomic cron sweeps active", "171 shadow snapshots intact"]),
        ("inspect system git branch status and uncommitted changes.",
         "bash_exec", {"command": "git status -s && git branch --show-current"},
         "## develop...origin/develop\n M lib/react.sh\n M lib/native_tools.sh\n?? tests/test_dag.sh",
         "Git workspace inspected: currently on develop with 2 modified files and 1 untracked test.",
         ["Branch: develop", "Modified files: lib/react.sh, lib/native_tools.sh", "Untracked: tests/test_dag.sh"]),
        ("run phytology audit with cached flags to verify living tissue integrity.",
         "phytology_manage", {"action": "audit", "flags": "--cached"},
         json.dumps({"audit": "PASS", "integrity_hash": "a8f3b9c2", "modified_tissues": 0, "failures": []}),
         "Phytology cached audit verified: all living tissue integrity checks passed with zero failures.",
         ["Integrity hash verified", "0 broken tissue modules", "Audit status: PASS"])
    ]
    
    task_text, tool_name, tool_args, tool_obs, summary, facts = random.choice(tasks)
    
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"PRIMARY OBJECTIVE:\n{task_text}\n\nHONEYDEW EXECUTION PLAN:\n- [ ] Step 1: Inspect system status using domain getter tools\n- [ ] Step 2: Synthesize findings\n\nCURRENT ACTIVE MILESTONE:\nStep 1: Inspect system status using domain getter tools\n\nDIRECTIVE: Focus exclusively on executing Step 1 using domain getter tools."},
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": f"call_turn1_{sample_id}",
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
            "tool_call_id": f"call_turn1_{sample_id}",
            "content": tool_obs
        },
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": f"call_complete_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "milestone_complete",
                        "arguments": json.dumps({
                            "status": "success",
                            "summary": summary,
                            "facts_discovered": facts
                        })
                    }
                }
            ]
        }
    ]
    return {"id": f"trackA_{sample_id}", "track": "dag_parallel_completion", "messages": messages, "tools": CORE_TOOLS}

def build_track_b_sample(sample_id):
    """Track B: Two-Tier Recovery Cascade & Self-Healing"""
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": "PRIMARY OBJECTIVE:\nVerify test harness passes for cron schedule module.\n\nHONEYDEW EXECUTION PLAN:\n- [ ] Step 1: Run automated test harness\n- [ ] Step 2: Synthesize verification deliverable\n\nCURRENT ACTIVE MILESTONE:\nStep 1: Run automated test harness"},
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": f"call_test_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "bash_exec",
                        "arguments": json.dumps({"command": "./tests/test_cron.sh"})
                    }
                }
            ]
        },
        {
            "role": "tool",
            "tool_call_id": f"call_test_{sample_id}",
            "content": "Running test_cron.sh...\nFAIL: line 42: syntax error near unexpected token 'fi'\nExit code: 2"
        },
        {
            "role": "user",
            "content": "[HONEYDEW RECOVERY: Milestone 1 failed verification (test_cron.sh failed with exit code 2). You have 1 localized self-correction retry to diagnose and repair the syntax error.]"
        },
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": f"call_edit_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "file_edit",
                        "arguments": json.dumps({
                            "path": "tests/test_cron.sh",
                            "sed_expr": "s/fi fi/fi/g"
                        })
                    }
                }
            ]
        },
        {
            "role": "tool",
            "tool_call_id": f"call_edit_{sample_id}",
            "content": "SUCCESS: Applied sed substitution 's/fi fi/fi/g' to tests/test_cron.sh."
        },
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": f"call_retest_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "bash_exec",
                        "arguments": json.dumps({"command": "./tests/test_cron.sh"})
                    }
                }
            ]
        },
        {
            "role": "tool",
            "tool_call_id": f"call_retest_{sample_id}",
            "content": "Running test_cron.sh...\nPASS: all 14 assertions succeeded.\nExit code: 0"
        },
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": f"call_rec_complete_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "milestone_complete",
                        "arguments": json.dumps({
                            "status": "success",
                            "summary": "Resolved syntax error in tests/test_cron.sh. Re-ran test harness; all 14 assertions passed cleanly with exit code 0.",
                            "facts_discovered": ["Repaired duplicate fi in tests/test_cron.sh", "Verified test suite passes (14/14)"]
                        })
                    }
                }
            ]
        }
    ]
    return {"id": f"trackB_{sample_id}", "track": "recovery_selfheal", "messages": messages, "tools": CORE_TOOLS}

def build_track_c_sample(sample_id):
    """Track C: Working Memory Distillation & Final Synthesis"""
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": "PRIMARY OBJECTIVE:\nplease check the status of the software phytology and report back.\n\nHONEYDEW EXECUTION PLAN:\n- [✓] Step 1: Inspect system status using domain getter tools\n- [ ] Step 2: Synthesize diagnostic observations and deliver structured status report to operator\n\nCURRENT ACTIVE MILESTONE:\nStep 2: Synthesize diagnostic observations and deliver structured status report to operator\n\n[HONEYDEW PROGRESS: All inspection/action steps are marked [✓]. The final milestone is active: Synthesize your diagnostic observations and deliver the structured status report directly to the operator in clean markdown. Do NOT execute redundant tool calls.]"},
        {
            "role": "assistant",
            "content": """### Software Phytology Status Report

**Living Tissue Assessment:**
The living software tissue within the Blue Lodge repository is in a sound and verified operational state:

| Subsystem Component | Operational Status | Metrics / Integrity |
|---|---|---|
| **Cambium Root Kernel** | Operational | 66 modules active across `lib/` |
| **Autonomic Cron Sweeps** | Active | 3 scheduled jobs in `.george/cron_jobs/` |
| **Shadow Snapshots** | Secured | 171 genetic snapshots preserved |
| **Syntax Health** | Verified | Zero syntax anomalies detected |

**Synthesis & Verification:**
- All diagnostic checks were completed directly via native domain getters.
- Genetic snapshots in `.george/snapshots/` remain pristine and ready for autonomic recovery if needed.
- No remediation actions are currently required."""
        }
    ]
    return {"id": f"trackC_{sample_id}", "track": "memory_synthesis", "messages": messages, "tools": []}

STRATEGIST_SYS = """You are the Blue Lodge Honeydew DAG Strategist.
Decompose the user objective into 2 to 4 distinct sequential or parallel milestones tailored specifically to the user's objective.

Blue Lodge Bedrock Capabilities:
- Bedrock tools: file_read, file_write (e.g. creating scripts in .george/cron_jobs/<name>.sh with # INTERVAL: <sec>, tools in .george/tools/<name>.sh), bash_exec (run tests, test scripts), ask_operator, tool_search, discord_dm.
- Each milestone task description MUST be a specific, plain-English action tailored to the objective. Do not output generic placeholder text. Do not output raw code syntax.

Output ONLY valid JSON matching this schema:
{"items": [{"id": 1, "task": "<specific action>", "tier": 1, "depends_on": []}]}"""

TRACK_D_SCENARIOS = [
    {
        "objective": "create a new cron job that kicks off an agentic task to look up the current weather in Appleton, WI and then DM's it to @dabe on discord.",
        "items": [
            {"id": 1, "task": "Create a cron job script in .george/cron_jobs/weather_appleton.sh that queries the current weather for Appleton, WI and sends the result to @dabe on Discord.", "tier": 1, "depends_on": []},
            {"id": 2, "task": "Verify script executable permissions and test execution via bash_exec.", "tier": 2, "depends_on": [1]},
            {"id": 3, "task": "Synthesize operational verification and deliver active cron job status to operator.", "tier": 3, "depends_on": [2]}
        ]
    },
    {
        "objective": "inspect system vitals and git repository status simultaneously and synthesize readiness report",
        "items": [
            {"id": 1, "task": "Inspect system vitals and hardware resource utilization.", "tier": 1, "depends_on": []},
            {"id": 2, "task": "Inspect git repository status and branch state.", "tier": 1, "depends_on": []},
            {"id": 3, "task": "Synthesize findings from both parallel inspections into overall readiness report.", "tier": 2, "depends_on": [1, 2]}
        ]
    },
    {
        "objective": "inspect the software phytology living tissue and auto-heal any degraded modules",
        "items": [
            {"id": 1, "task": "Inspect software phytology living tissue health and genetic snapshots.", "tier": 1, "depends_on": []},
            {"id": 2, "task": "Execute automated healing graft on any detected degraded tissue modules.", "tier": 2, "depends_on": [1]},
            {"id": 3, "task": "Verify syntax and confirm overall repository health.", "tier": 3, "depends_on": [2]}
        ]
    },
    {
        "objective": "patch race condition in lib/fifo_ipc.sh and verify with tests/test_fifo_ipc.sh",
        "items": [
            {"id": 1, "task": "Inspect race condition and mutex lock acquisition in lib/fifo_ipc.sh.", "tier": 1, "depends_on": []},
            {"id": 2, "task": "Apply surgical mutex synchronization fix to lib/fifo_ipc.sh.", "tier": 2, "depends_on": [1]},
            {"id": 3, "task": "Execute test suite tests/test_fifo_ipc.sh to verify zero regressions.", "tier": 3, "depends_on": [2]}
        ]
    },
    {
        "objective": "schedule a nightly 2 AM backup cron job that creates an encrypted tarball in .george/backups/",
        "items": [
            {"id": 1, "task": "Write backup automation script in .george/cron_jobs/nightly_backup.sh with 86400s interval.", "tier": 1, "depends_on": []},
            {"id": 2, "task": "Configure encryption key and test backup script execution.", "tier": 2, "depends_on": [1]},
            {"id": 3, "task": "Verify backup archive creation and register cron job status.", "tier": 3, "depends_on": [2]}
        ]
    },
    {
        "objective": "poll Discord mentions for user queries and auto-respond with current project status",
        "items": [
            {"id": 1, "task": "Fetch unread Discord mentions and user messages via discord_bridge.", "tier": 1, "depends_on": []},
            {"id": 2, "task": "Generate project status response summary from working memory.", "tier": 2, "depends_on": [1]},
            {"id": 3, "task": "Dispatch Discord responses to mentioned users via discord_send.", "tier": 3, "depends_on": [2]}
        ]
    },
    {
        "objective": "profile inference latency across tier 1 cuda and tier 2 vision endpoints",
        "items": [
            {"id": 1, "task": "Measure prompt ingestion and token generation latency on Tier 1 (Port 8080).", "tier": 1, "depends_on": []},
            {"id": 2, "task": "Measure multimodal visual reasoning latency on Tier 2 (Port 18080).", "tier": 1, "depends_on": []},
            {"id": 3, "task": "Synthesize comparative benchmark report and update endpoints.conf recommendations.", "tier": 2, "depends_on": [1, 2]}
        ]
    },
    {
        "objective": "add a new native tool web_summarize to lib/native_tools.sh and register schema",
        "items": [
            {"id": 1, "task": "Inspect native tools schema registry in lib/native_tools.sh.", "tier": 1, "depends_on": []},
            {"id": 2, "task": "Implement web_summarize function and add JSON schema to _NATIVE_CORE_TOOLS.", "tier": 2, "depends_on": [1]},
            {"id": 3, "task": "Run test harness to validate new tool schema parsing.", "tier": 3, "depends_on": [2]}
        ]
    }
]

def build_track_d_sample(sample_id):
    """Track D (Option 6A): Honeydew DAG Strategist Decomposition"""
    scenario = TRACK_D_SCENARIOS[sample_id % len(TRACK_D_SCENARIOS)]
    messages = [
        {"role": "system", "content": STRATEGIST_SYS},
        {"role": "user", "content": f"Objective: {scenario['objective']}"},
        {
            "role": "assistant",
            "content": json.dumps({"items": scenario["items"]}, indent=2)
        }
    ]
    return {"id": f"trackD_{sample_id}", "track": "strategist_dag", "messages": messages, "tools": []}

def main():
    print("Generating Enhanced DAG ReAct & Multi-Track Curricula...")
    
    trackA_samples = [build_track_a_sample(i) for i in range(50)]
    trackB_samples = [build_track_b_sample(i) for i in range(50)]
    trackC_samples = [build_track_c_sample(i) for i in range(50)]
    trackD_samples = [build_track_d_sample(i) for i in range(50)]
    
    # Save individual track datasets for 3x A100 parallel training
    with open(f"{OUTPUT_DIR}/curriculum_trackA_dag_parallel.jsonl", "w") as f:
        for s in trackA_samples:
            f.write(json.dumps(s) + "\n")
            
    with open(f"{OUTPUT_DIR}/curriculum_trackB_recovery_selfheal.jsonl", "w") as f:
        for s in trackB_samples:
            f.write(json.dumps(s) + "\n")
            
    with open(f"{OUTPUT_DIR}/curriculum_trackC_memory_synthesis.jsonl", "w") as f:
        for s in trackC_samples:
            f.write(json.dumps(s) + "\n")

    with open(f"{OUTPUT_DIR}/curriculum_trackD_strategist_dag.jsonl", "w") as f:
        for s in trackD_samples:
            f.write(json.dumps(s) + "\n")
            
    # Combined master dataset
    all_samples = trackA_samples + trackB_samples + trackC_samples + trackD_samples
    random.shuffle(all_samples)
    
    val_count = 32
    val_set = all_samples[:val_count]
    train_set = all_samples[val_count:]
    
    with open(f"{OUTPUT_DIR}/dag_react_train.jsonl", "w") as f:
        for s in train_set:
            f.write(json.dumps(s) + "\n")
            
    with open(f"{OUTPUT_DIR}/dag_react_val.jsonl", "w") as f:
        for s in val_set:
            f.write(json.dumps(s) + "\n")
            
    print(f"✓ Generated Track A (DAG Parallel): {len(trackA_samples)} samples")
    print(f"✓ Generated Track B (Recovery Self-Heal): {len(trackB_samples)} samples")
    print(f"✓ Generated Track C (Memory Synthesis): {len(trackC_samples)} samples")
    print(f"✓ Generated Track D (Strategist DAG Decomposition - Option 6A): {len(trackD_samples)} samples")
    print(f"✓ Master Train: {len(train_set)} samples -> {OUTPUT_DIR}/dag_react_train.jsonl")
    print(f"✓ Master Val: {len(val_set)} samples -> {OUTPUT_DIR}/dag_react_val.jsonl")

if __name__ == "__main__":
    main()
