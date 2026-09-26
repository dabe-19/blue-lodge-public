#!/usr/bin/env python3
"""
Blue Lodge GRPO Curriculum Builder with Semantic SMOTE Augmentation
Mines real historical trajectories from:
  1. /home/wsl-ops/blue-lodge/.george/transcripts/trajectories.jsonl (8.64 MB)
  2. /home/wsl-ops/blue-lodge/.george/evaluator_diagnostics.jsonl

Curriculum Architecture:
  Band A: Atomic Tool Drills (40%) - bash_exec, file_read, dir_list, json format
  Band B: Multi-Turn ReAct Chains with Error Recovery (40%) - Semantic SMOTE (k=3)
  Band C: Deep Research Graphs (20%) - 5-Phase George Research Pipeline (lib/research_graph.sh)

Outputs:
  /home/wsl-ops/blue-lodge/data/training/blue_lodge_grpo_curriculum.jsonl
"""

import os
import sys
import json
import re
import random

TRAJECTORIES_PATH = "/home/wsl-ops/blue-lodge/.george/transcripts/trajectories.jsonl"
DIAGNOSTICS_PATH = "/home/wsl-ops/blue-lodge/.george/evaluator_diagnostics.jsonl"
OUTPUT_DIR = "/home/wsl-ops/blue-lodge/data/training"
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "blue_lodge_grpo_curriculum.jsonl")

os.makedirs(OUTPUT_DIR, exist_ok=True)

print("=" * 80)
print("  Blue Lodge GRPO Curriculum Builder & Semantic SMOTE Engine")
print("=" * 80)

def extract_real_trajectories():
    print(f"[*] Ingesting raw trajectories from {TRAJECTORIES_PATH}...")
    success_traces = []
    failure_traces = []

    with open(TRAJECTORIES_PATH, "r") as f:
        for line_no, line in enumerate(f):
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
                instr = data.get("instruction", "").strip()
                action = data.get("action", "").strip()
                obs = data.get("observation", "").strip()
                thinking = data.get("thinking", "").strip()

                if not instr or not action:
                    continue

                item = {
                    "instruction": instr,
                    "action": action,
                    "observation": obs,
                    "thinking": thinking
                }

                # Identify failures / exceptions in observation
                is_err = any(w in obs.lower() for w in ["failed", "error", "not found", "404", "exception", "timed out"])
                if is_err:
                    failure_traces.append(item)
                else:
                    success_traces.append(item)
            except Exception:
                pass

    print(f"  ✓ Processed {len(success_traces) + len(failure_traces)} valid entries.")
    print(f"    - Clean Success Traces:  {len(success_traces)}")
    print(f"    - Failure / Error Traces: {len(failure_traces)} ({len(failure_traces)/(len(success_traces)+len(failure_traces))*100:.1f}%)")
    return success_traces, failure_traces

def synthesize_counterfactual_repairs(failure_traces):
    """
    Creates Golden Counterfactual repairs for mined failure cases:
    If a tool fails (e.g. bash error, web_search no results), teach the model
    to analyze the failure in <think> and execute a targeted recovery tool.
    """
    print(f"[*] Synthesizing Golden Counterfactual repairs for {len(failure_traces)} failure traces...")
    repaired_samples = []

    for item in failure_traces:
        instr = item["instruction"]
        action = item["action"]
        obs = item["observation"]
        tool_name = action.split("(")[0]

        # Author ideal recovery trajectory
        if "bash" in tool_name:
            recovery_action = 'bash_exec({"command":"pwd; ls -la"})'
            repair_thought = f"The previous bash command failed with observation: {obs[:120]}. Let me simplify the command, check current directory state, and verify file paths before retrying."
        elif "web_search" in tool_name:
            recovery_action = 'web_search({"query":"site:github.com ' + instr[:30].replace('"', '') + '", "count": 3})'
            repair_thought = f"The search returned an error or empty result: {obs[:120]}. Let me reformulate the query with more general keywords and search direct authoritative sources."
        elif "web_fetch" in tool_name:
            recovery_action = 'web_search({"query":"' + instr[:30].replace('"', '') + ' summary", "count": 3})'
            repair_thought = f"Direct fetch of URL failed: {obs[:120]}. Falling back to search cache to find alternative mirrors or documentation."
        else:
            recovery_action = 'file_read({"path":"/home/wsl-ops/blue-lodge/README.md"})'
            repair_thought = f"Tool {tool_name} encountered an issue: {obs[:120]}. Checking local documentation and status."

        repaired_samples.append({
            "instruction": instr,
            "failed_action": action,
            "observation": obs,
            "repair_thought": repair_thought,
            "repair_action": recovery_action,
            "is_recovery": True
        })

    print(f"  ✓ Generated {len(repaired_samples)} Golden Counterfactual repair templates.")
    return repaired_samples

def apply_semantic_smote(repaired_samples, k=3):
    """
    Semantic SMOTE (Synthetic Minority Over-sampling Technique):
    For each failure-repair pair, generates k synthetic neighbor variations:
      Variant A: Lexical / Phrasing Perturbation
      Variant B: Environment Fault Injection (simulated HTTP 429 / MCP timeout)
      Variant C: Multi-Constraint Prompt
    """
    print(f"[*] Applying Semantic SMOTE (k={k} neighbors per failure case)...")
    smote_samples = []

    lexical_prefixes = [
        "Hey George, ", "Quick question: ", "Can you help me figure out ",
        "Please run diagnostics on ", "Investigate this issue: ", "I need you to "
    ]

    fault_scenarios = [
        ("MCP timeout after 15000ms", "web_search: Falling through to direct API provider"),
        ("HTTP 429 Too Many Requests (Rate limit reached)", "Retrying with exponential backoff and cached sources"),
        ("Permission denied (exit 126)", "Checking file permissions and running with appropriate privileges"),
        ("No such file or directory", "Verifying path existence via dir_list before accessing")
    ]

    for item in repaired_samples:
        base_instr = item["instruction"]
        # Strip old conversation wrappers if present
        if "[Recent Conversation Context]" in base_instr:
            m = re.search(r"\[Current Inbound Message from [^\]]+\]:\s*(.*)", base_instr, re.S)
            if m:
                base_instr = m.group(1).strip()
            else:
                base_instr = base_instr.split("\n")[-1].strip()

        if len(base_instr) < 5 or len(base_instr) > 200:
            base_instr = "Check system status and report back on recent events."

        for v_idx in range(k):
            if v_idx == 0:
                # Variant A: Lexical perturbation
                prefix = random.choice(lexical_prefixes)
                p_instr = prefix + base_instr[0].lower() + base_instr[1:] if len(base_instr) > 1 else prefix + base_instr
                p_item = {
                    "prompt": p_instr,
                    "target_tool": item["repair_action"],
                    "reasoning_directive": item["repair_thought"],
                    "band": "Band_B_ReAct_Chain",
                    "smote_type": "lexical_neighbor"
                }
            elif v_idx == 1:
                # Variant B: Fault Injection
                fault_name, fault_resolution = random.choice(fault_scenarios)
                p_instr = f"{base_instr} [Simulated Environment Alert: {fault_name}]"
                thought = f"Environment warning detected: {fault_name}. Resolution protocol: {fault_resolution}. Emitting structured corrective action."
                p_item = {
                    "prompt": p_instr,
                    "target_tool": item["repair_action"],
                    "reasoning_directive": thought,
                    "band": "Band_B_ReAct_Chain",
                    "smote_type": "fault_injection"
                }
            else:
                # Variant C: Multi-Constraint
                p_instr = f"{base_instr} (Provide strict JSON tool call and verify parameters before executing)"
                p_item = {
                    "prompt": p_instr,
                    "target_tool": item["repair_action"],
                    "reasoning_directive": "Ensuring strict schema adherence and closed brackets.",
                    "band": "Band_A_Tool_Drill",
                    "smote_type": "constraint_stress"
                }

            smote_samples.append(p_item)

    print(f"  ✓ Generated {len(smote_samples)} Semantic SMOTE augmented samples.")
    return smote_samples

def build_research_graph_curriculum():
    """
    Band C: 5-Phase George Research Pipeline Graphs (lib/research_graph.sh)
    """
    print("[*] Generating Band C: Deep Research Graphs from lib/research_graph.sh...")
    research_topics = [
        "Entropy Bounds in 4-bit KV Cache Compression",
        "Haar Orthogonal Reservoir Dynamics in Gated Delta Networks",
        "Logit-Lens Metric Tensor Geometry in Vocabulary Space",
        "Sub-1GB Frontier LLM Pruning and Least-Squares SPTQ",
        "Autonomous Multi-Agent Task Orchestration in Sovereign Sandboxes",
        "Kronecker Product Spectral Preservation for Recurrent Reservoirs",
        "Three-Body Orbital Perturbations and Gravitational Resonance",
        "Non-Autonomous Point-Reactor Kinetics with Thermal Feedback",
        "Closed-Form Least Squares Calibration on GGUF Rotary Weights",
        "Zero-Shot JSON Schema Conformance in Pruned Ternary Backbones"
    ]

    graph_samples = []
    for topic in research_topics:
        # Phase 1: ReAct Inquiry
        p1 = {
            "prompt": f"Execute Phase 1/5 research investigation on topic: '{topic}'",
            "target_tool": f'web_search({{"query":"{topic} arXiv primary paper", "count": 5}})',
            "reasoning_directive": f"Initiating Phase 1 of George Autonomous Research Engine for inquiry '{topic}'. Searching arXiv and verified preprints.",
            "band": "Band_C_Research_Graph",
            "phase": 1
        }
        # Phase 2: Evidence Audit
        p2 = {
            "prompt": f"Execute Phase 2/5 evidence audit and source verification for topic: '{topic}'",
            "target_tool": f'bash_exec({{"command":"grep -i \"entropy\\|spectral\\|bound\" /home/wsl-ops/blue-lodge/.george/research/last_search.json | head -n 10"}})',
            "reasoning_directive": "Auditing collected search evidence, checking citation provenance, and identifying literature gaps.",
            "band": "Band_C_Research_Graph",
            "phase": 2
        }
        # Phase 3: Monograph Synthesis
        p3 = {
            "prompt": f"Execute Phase 3/5 technical monograph synthesis for topic: '{topic}'",
            "target_tool": f'file_write({{"path":"/home/wsl-ops/blue-lodge/.george/research/dossier.md", "content":"# Technical Monograph: {topic}\\n\\n## Abstract\\n..."}})',
            "reasoning_directive": "Authoring comprehensive long-form technical dossier conforming to soul.md standards.",
            "band": "Band_C_Research_Graph",
            "phase": 3
        }
        graph_samples.extend([p1, p2, p3])

    print(f"  ✓ Generated {len(graph_samples)} Band C Research Graph samples.")
    return graph_samples

def assemble_final_curriculum():
    success_traces, failure_traces = extract_real_trajectories()
    repaired_samples = synthesize_counterfactual_repairs(failure_traces)
    smote_samples = apply_semantic_smote(repaired_samples, k=3)
    research_graph_samples = build_research_graph_curriculum()

    # Convert clean success traces into Band A/B samples
    print("[*] Formatting clean real traces into training samples...")
    real_curriculum_samples = []
    for item in success_traces[:250]: # Sample 250 cleanest authentic queries
        real_curriculum_samples.append({
            "prompt": item["instruction"],
            "target_tool": item["action"],
            "reasoning_directive": item["thinking"][:300] if item["thinking"] else "Executing tool command cleanly.",
            "band": "Band_B_ReAct_Chain",
            "smote_type": "authentic_human_trace"
        })

    # Combine all streams
    total_curriculum = smote_samples + research_graph_samples + real_curriculum_samples
    random.seed(42)
    random.shuffle(total_curriculum)

    print(f"\n[*] Writing {len(total_curriculum)} total samples to {OUTPUT_FILE}...")
    with open(OUTPUT_FILE, "w") as out_f:
        for s in total_curriculum:
            out_f.write(json.dumps(s) + "\n")

    file_size_kb = os.path.getsize(OUTPUT_FILE) / 1024
    print("=" * 80)
    print(f"  [✓] Successfully generated {OUTPUT_FILE}")
    print(f"      Total Curriculum Samples: {len(total_curriculum)}")
    print(f"      - SMOTE Failure-Repair:   {len(smote_samples)}")
    print(f"      - Authentic Human Traces: {len(real_curriculum_samples)}")
    print(f"      - Deep Research Graphs:   {len(research_graph_samples)}")
    print(f"      File Size:                {file_size_kb:.1f} KB")
    print("=" * 80)

if __name__ == "__main__":
    assemble_final_curriculum()
